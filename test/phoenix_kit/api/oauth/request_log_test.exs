defmodule PhoenixKit.API.OAuth.RequestLogTest do
  @moduledoc """
  What the Logger filter of `PhoenixKit.API.OAuth.RequestLog` does to an event, and that the kit
  registers it when its supervisor starts (a host's endpoint needs no option for it).
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.API.OAuth.RequestLog

  @token String.duplicate("a", 43)

  defp event(message), do: %{level: :info, msg: {:string, message}, meta: %{}}
  defp conn(path), do: %Plug.Conn{request_path: path}

  describe "filter/2" do
    test "hides the token of a consent path in the request line, with and without a prefix" do
      for prefix <- ["", "/phoenix_kit"] do
        line = ["GET", ?\s, prefix <> "/oauth/consent/" <> @token]

        assert %{msg: {:string, ["GET", ?\s, redacted]}} = RequestLog.filter(event(line), [])
        assert redacted == prefix <> "/oauth/consent/[FILTERED]"
      end
    end

    test "hides the token of a consent path that carries a language, and drops the query" do
      assert RequestLog.redact("/oauth/consent/" <> @token <> "?lang=ru") ==
               "/oauth/consent/[FILTERED]?[FILTERED]"

      line = ["GET", ?\s, "/oauth/consent/" <> @token <> "?lang=ru"]

      assert %{msg: {:string, ["GET", ?\s, redacted]}} = RequestLog.filter(event(line), [])
      refute redacted =~ @token
    end

    test "hides it in the disconnect form's path and keeps the rest of the path" do
      line = ["POST", ?\s, "/oauth/consent/" <> @token <> "/revoke"]

      assert %{msg: {:string, ["POST", ?\s, "/oauth/consent/[FILTERED]/revoke"]}} =
               RequestLog.filter(event(line), [])
    end

    test "drops the query of any /oauth/ path (a code, a state)" do
      for path <- ["/oauth/authorize", "/oauth/token", "/oauth/callback"] do
        line = ["GET", ?\s, path <> "?code=SECRETCODE&state=SECRETSTATE"]

        assert %{msg: {:string, ["GET", ?\s, redacted]}} = RequestLog.filter(event(line), [])
        assert redacted == path <> "?[FILTERED]"
      end
    end

    test "hides the token in a plain text message" do
      assert %{msg: {:string, text}} =
               RequestLog.filter(event("could not render /oauth/consent/#{@token} for x"), [])

      assert text == "could not render /oauth/consent/[FILTERED] for x"
    end

    test "reads a message written as other chardata as one text" do
      token = @token

      # The request line nested another way, and with the path as a charlist.
      for line <- [
            [["GET", " "], ["/oauth/consent/", token]],
            ~c"GET /oauth/consent/" ++ String.to_charlist(token),
            ["GET ", ~c"/oauth/authorize?code=SECRETCODE"]
          ] do
        assert %{msg: {:string, redacted}} = RequestLog.filter(event(line), [])
        assert is_binary(redacted)
        refute redacted =~ token
        refute redacted =~ "SECRETCODE"
      end

      assert %{msg: {:string, "could not render /oauth/consent/[FILTERED] for x"}} =
               RequestLog.filter(
                 event(["could not render ", ["/oauth/consent/", token], " for x"]),
                 []
               )

      # Not chardata at all: as it is.
      odd = event([:not_chardata, "/oauth/consent/" <> token])
      assert RequestLog.filter(odd, []) == odd
    end

    test "leaves every other event as it is" do
      for line <- [
            ["GET", ?\s, "/users/log-in?return_to=%2Foauth"],
            ["GET", ?\s, "/oauth"],
            ["Sent", ?\s, "200", " in ", "3ms"],
            "plain message"
          ] do
        assert RequestLog.filter(event(line), []) == event(line)
      end

      report = %{level: :info, msg: {:report, %{path: "/oauth/consent/" <> @token}}, meta: %{}}
      assert RequestLog.filter(report, []) == report
    end
  end

  describe "path/1" do
    test "is the path with the consent token hidden" do
      assert RequestLog.path(conn("/oauth/consent/" <> @token)) == "/oauth/consent/[FILTERED]"
      assert RequestLog.path(conn("/mcp/admin")) == "/mcp/admin"
    end
  end

  describe "install/0" do
    setup do
      on_exit(fn -> RequestLog.install() end)
      _ = :logger.remove_primary_filter(:phoenix_kit_oauth_request_log)
      :ok
    end

    defp registered? do
      Enum.any?(
        :logger.get_primary_config().filters,
        &match?({:phoenix_kit_oauth_request_log, _}, &1)
      )
    end

    test "registers the filter once, and again is not an error" do
      refute registered?()
      assert RequestLog.install() == :ok
      assert RequestLog.install() == :ok
      assert registered?()
    end

    test "the kit's supervisor registers it when it starts" do
      refute registered?()
      assert {:ok, _spec} = PhoenixKit.Supervisor.init([])
      assert registered?()
    end
  end
end
