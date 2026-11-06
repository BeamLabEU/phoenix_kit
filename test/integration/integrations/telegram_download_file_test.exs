defmodule PhoenixKit.Integration.Integrations.TelegramDownloadFileTest do
  @moduledoc """
  `Telegram.download_file/3` — `getFile` and then the file itself, through a
  stored connection. Telegram is stubbed with `Req.Test`
  (`:telegram_req_options`); nothing here opens a socket. The bot token must
  appear in no returned error and no log line.
  """

  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Telegram

  @stub __MODULE__.Telegram
  @token "123:SECRETTOKEN"
  @file_path "voice/file_7.oga"

  setup do
    Application.put_env(:phoenix_kit, :telegram_req_options, plug: {Req.Test, @stub})
    on_exit(fn -> Application.delete_env(:phoenix_kit, :telegram_req_options) end)

    {:ok, %{uuid: uuid}} = Integrations.add_connection("telegram", "download bot")
    {:ok, _} = Integrations.save_setup(uuid, %{"bot_token" => @token})

    %{connection: uuid}
  end

  # getFile answers `file`; the file path answers `file_fun`.
  defp stub_bot(file, file_fun, test_pid \\ self()) do
    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:telegram, conn.method, conn.request_path})

      if String.ends_with?(conn.request_path, "/getFile") do
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:get_file_body, Jason.decode!(raw)})
        Req.Test.json(conn, %{"ok" => true, "result" => file})
      else
        file_fun.(conn)
      end
    end)
  end

  defmodule LeakyError do
    @moduledoc false
    defexception [:message, :url, :reason]
  end

  # Makes the Req.Test adapter answer with this exception, as a failed request.
  defp raise_in_adapter(conn, exception),
    do: put_in(conn.private[:req_test_exception], exception)

  defp send_chunks(conn, sizes) do
    Enum.reduce(sizes, Plug.Conn.send_chunked(conn, 200), fn size, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("x", size))
      conn
    end)
  end

  defp file(extra \\ %{}), do: Map.merge(%{"file_id" => "F1", "file_path" => @file_path}, extra)

  describe "download_file/3" do
    test "returns the bytes of the file", %{connection: connection} do
      stub_bot(file(%{"file_size" => 5}), &Plug.Conn.send_resp(&1, 200, "ab\0cd"))

      assert {:ok, "ab\0cd"} = Telegram.download_file(connection, "F1")

      assert_received {:get_file_body, %{"file_id" => "F1"}}
      assert_received {:telegram, "POST", "/bot" <> @token <> "/getFile"}
      assert_received {:telegram, "GET", "/file/bot" <> @token <> "/" <> @file_path}
    end

    test "a file whose size getFile does not tell is read within the limit",
         %{connection: connection} do
      stub_bot(file(), &Plug.Conn.send_resp(&1, 200, "abc"))

      assert {:ok, "abc"} = Telegram.download_file(connection, "F1")
    end

    test "a body of exactly max_bytes is accepted", %{connection: connection} do
      stub_bot(file(%{"file_size" => 4}), &Plug.Conn.send_resp(&1, 200, "abcd"))

      assert {:ok, "abcd"} = Telegram.download_file(connection, "F1", max_bytes: 4)
    end

    test "a size over max_bytes in getFile is refused before the file is requested",
         %{connection: connection} do
      stub_bot(file(%{"file_size" => 101}), fn _conn ->
        flunk("the file must not be requested")
      end)

      assert {:error, {:file_too_large, 101, 100}} =
               Telegram.download_file(connection, "F1", max_bytes: 100)

      refute_received {:telegram, "GET", _}
    end

    test "the default limit is 20 MB", %{connection: connection} do
      stub_bot(file(%{"file_size" => 20 * 1024 * 1024 + 1}), fn _ -> flunk("requested") end)

      assert {:error, {:file_too_large, size, max}} = Telegram.download_file(connection, "F1")
      assert size == 20 * 1024 * 1024 + 1
      assert max == 20 * 1024 * 1024
    end

    test "a server that lies about the size cannot make it read more than max_bytes",
         %{connection: connection} do
      stub_bot(file(%{"file_size" => 10}), fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("a", 60))
        {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("b", 60))
        {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("c", 60))
        conn
      end)

      # Stops at the chunk that crosses the limit: 60, then 120 > 100.
      assert {:error, {:file_too_large, 120, 100}} =
               Telegram.download_file(connection, "F1", max_bytes: 100)
    end

    test "a body in several chunks that sums to exactly max_bytes is accepted",
         %{connection: connection} do
      stub_bot(file(), &send_chunks(&1, [40, 40, 20]))

      assert {:ok, body} = Telegram.download_file(connection, "F1", max_bytes: 100)
      assert byte_size(body) == 100
    end

    test "one byte over max_bytes with no size from getFile is too large",
         %{connection: connection} do
      stub_bot(file(), &send_chunks(&1, [40, 40, 21]))

      assert {:error, {:file_too_large, 101, 100}} =
               Telegram.download_file(connection, "F1", max_bytes: 100)
    end

    test "a download past the deadline is a :timeout", %{connection: connection} do
      stub_bot(file(), fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, "a")
        Process.sleep(30)
        {:ok, conn} = Plug.Conn.chunk(conn, "b")
        conn
      end)

      assert {:error, :timeout} = Telegram.download_file(connection, "F1", deadline_ms: 5)
    end

    test "a redirect is not followed (the Location would be sent the token)",
         %{connection: connection} do
      stub_bot(file(), fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.test/leak")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, "Telegram error 302"} = Telegram.download_file(connection, "F1")

      assert_received {:telegram, "GET", "/file/bot" <> _}
      refute_received {:telegram, "GET", "/leak"}
    end

    test "getFile's description is returned when Telegram refuses", %{connection: connection} do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"ok" => false, "description" => "Bad Request: invalid file_id"})
      end)

      assert {:error, "Bad Request: invalid file_id"} = Telegram.download_file(connection, "F1")
    end

    test "a getFile answer without a file_path is an error", %{connection: connection} do
      stub_bot(%{"file_id" => "F1"}, fn _ -> flunk("requested") end)

      assert {:error, :no_file_path} = Telegram.download_file(connection, "F1")
    end

    test "an HTTP error of the file download is an error without the body",
         %{connection: connection} do
      stub_bot(file(%{"file_size" => 3}), &Plug.Conn.send_resp(&1, 404, "not found"))

      assert {:error, "Telegram error 404"} = Telegram.download_file(connection, "F1")
    end

    test "an unreachable server is :unreachable", %{connection: connection} do
      stub_bot(file(%{"file_size" => 3}), &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, :unreachable} = Telegram.download_file(connection, "F1")
    end

    test "a connection without a token is :not_configured" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("telegram", "no token")

      assert {:error, :not_configured} = Telegram.download_file(uuid, "F1")
    end

    test "an owner that does not own the connection gets an error and no request",
         %{connection: connection} do
      stub_bot(file(), &Plug.Conn.send_resp(&1, 200, "x"))

      assert {:error, _} =
               Telegram.download_file(connection, "F1", owner: {:user, Ecto.UUID.generate()})

      refute_received {:telegram, _, _}
    end
  end

  describe "download_file/3 arguments" do
    test "a file_id that is empty, not a string or too long is refused with no request",
         %{connection: connection} do
      stub_bot(file(), &Plug.Conn.send_resp(&1, 200, "x"))

      for bad <- ["", nil, 12, :atom, String.duplicate("a", 1025)] do
        assert {:error, :invalid_file_id} = Telegram.download_file(connection, bad)
      end

      refute_received {:telegram, _, _}
    end

    test "a file_path with .. or a leading / is refused and not requested",
         %{connection: connection} do
      for bad <- ["../etc/passwd", "voice/../../x", "/voice/f.oga", "voice/a?x=1", "", 5] do
        stub_bot(file(%{"file_path" => bad}), fn _ -> flunk("requested") end)

        assert {:error, :invalid_file_path} = Telegram.download_file(connection, "F1")
        refute_received {:telegram, "GET", _}
      end
    end

    test "a file_id that is not valid UTF-8 is refused (it would not encode)",
         %{connection: connection} do
      stub_bot(file(), &Plug.Conn.send_resp(&1, 200, "x"))

      assert {:error, :invalid_file_id} = Telegram.download_file(connection, <<0xFF, 0xFE>>)
      refute_received {:telegram, _, _}
    end

    test "a max_bytes that is not a positive integer is refused with no request",
         %{connection: connection} do
      stub_bot(file(%{"file_size" => 3}), &Plug.Conn.send_resp(&1, 200, "abc"))

      for bad <- [0, -1, 1.5, "100", :infinity] do
        assert {:error, :invalid_max_bytes} =
                 Telegram.download_file(connection, "F1", max_bytes: bad)
      end

      refute_received {:telegram, _, _}
    end

    test "no max_bytes, or nil, is the default", %{connection: connection} do
      stub_bot(file(%{"file_size" => 3}), &Plug.Conn.send_resp(&1, 200, "abc"))

      assert {:ok, "abc"} = Telegram.download_file(connection, "F1")
      assert {:ok, "abc"} = Telegram.download_file(connection, "F1", max_bytes: nil)
    end
  end

  describe "the token" do
    test "is in no error term and no log line, whatever fails", %{connection: connection} do
      failures = [
        fn conn -> Plug.Conn.send_resp(conn, 500, "boom #{@token}") end,
        fn conn -> Plug.Conn.send_resp(conn, 404, "") end,
        fn conn -> Req.Test.transport_error(conn, :econnrefused) end,
        fn conn -> Req.Test.transport_error(conn, :timeout) end,
        fn conn ->
          conn = Plug.Conn.send_chunked(conn, 200)
          {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("a", 500))
          conn
        end
      ]

      for fail <- failures do
        stub_bot(file(%{"file_size" => 3}), fail)

        log =
          capture_log([level: :debug], fn ->
            result = Telegram.download_file(connection, "F1", max_bytes: 100)
            send(self(), {:result, result})
          end)

        assert_received {:result, {:error, _} = result}
        refute inspect(result) =~ "SECRETTOKEN"
        refute log =~ "SECRETTOKEN"
      end
    end

    test "is in no error term or log line when the request error carries the URL",
         %{connection: connection} do
      leaky = %LeakyError{
        message: "request to https://api.telegram.org/file/bot#{@token}/#{@file_path} failed",
        url: "https://api.telegram.org/file/bot#{@token}/#{@file_path}",
        reason: "bot#{@token}"
      }

      stub_bot(file(%{"file_size" => 3}), &raise_in_adapter(&1, leaky))

      log =
        capture_log([level: :debug], fn ->
          send(self(), {:result, Telegram.download_file(connection, "F1")})
        end)

      assert_received {:result, {:error, :unreachable} = result}
      refute inspect(result) =~ "SECRETTOKEN"
      assert log =~ "downloadFile failed"
      refute log =~ "SECRETTOKEN"
    end

    test "is in no log line when getFile fails with an error that carries the URL",
         %{connection: connection} do
      leaky = %LeakyError{
        message: "request to https://api.telegram.org/bot#{@token}/getFile failed",
        url: "https://api.telegram.org/bot#{@token}/getFile"
      }

      Req.Test.stub(@stub, &raise_in_adapter(&1, leaky))

      log =
        capture_log([level: :debug], fn ->
          send(self(), {:result, Telegram.download_file(connection, "F1")})
        end)

      assert_received {:result, {:error, :unreachable}}
      assert log =~ "getFile failed"
      refute log =~ "SECRETTOKEN"
    end

    test "is in no log line when getFile itself fails", %{connection: connection} do
      Req.Test.stub(@stub, &Req.Test.transport_error(&1, :econnrefused))

      log =
        capture_log([level: :debug], fn ->
          assert {:error, :unreachable} = Telegram.download_file(connection, "F1")
        end)

      refute log =~ "SECRETTOKEN"
    end
  end
end
