defmodule PhoenixKitWeb.ResumableUploadTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias PhoenixKitWeb.ResumableUpload

  @endpoint PhoenixKitWeb.Endpoint
  @salt "phoenix_kit resumable upload"

  setup do
    dir = Path.join(System.tmp_dir!(), "pk_resumable_test_#{System.unique_integer([:positive])}")
    Application.put_env(:phoenix_kit, :resumable_upload_dir, dir)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :resumable_upload_dir)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp token(id, size, owner \\ "u1"),
    do: Phoenix.Token.sign(@endpoint, @salt, %{id: id, size: size, owner: owner})

  defp request(method, id, opts) do
    conn =
      conn(method, "/" <> id, Keyword.get(opts, :body, ""))
      |> put_private(:phoenix_endpoint, @endpoint)
      |> Map.put(:path_info, [id])

    conn =
      case Keyword.fetch(opts, :token) do
        {:ok, nil} -> conn
        {:ok, t} -> put_req_header(conn, "x-upload-token", t)
        :error -> conn
      end

    conn =
      case Keyword.fetch(opts, :offset) do
        {:ok, o} -> put_req_header(conn, "upload-offset", to_string(o))
        :error -> conn
      end

    conn =
      case Keyword.fetch(opts, :sha) do
        {:ok, s} -> put_req_header(conn, "x-chunk-sha256", s)
        :error -> conn
      end

    ResumableUpload.call(conn, [])
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp offset_header(conn), do: conn |> get_resp_header("upload-offset") |> List.first()

  @id String.duplicate("a", 40)

  describe "authorization" do
    test "a request without a token is refused and writes nothing", %{dir: dir} do
      conn = request("PATCH", @id, offset: 0, body: "abc")
      assert conn.status == 401
      refute File.exists?(dir)
    end

    test "a token for another upload is refused" do
      other = String.duplicate("b", 40)
      conn = request("GET", @id, token: token(other, 10))
      assert conn.status == 401
    end

    test "a forged token is refused" do
      conn = request("GET", @id, token: token(@id, 10) <> "x")
      assert conn.status == 401
    end

    test "an expired token is refused" do
      old = Phoenix.Token.sign(@endpoint, @salt, %{id: @id, size: 5, owner: "u1"}, signed_at: 0)
      assert request("GET", @id, token: old).status == 401
    end
  end

  describe "sending a file in chunks" do
    test "an upload that has not started holds nothing" do
      conn = request("GET", @id, token: token(@id, 10))
      assert conn.status == 200
      assert body(conn) == %{"offset" => 0, "size" => 10, "complete" => false}
      assert offset_header(conn) == "0"
    end

    test "chunks add up to the file, and the last one says it is complete" do
      t = token(@id, 10)
      assert (c1 = request("PATCH", @id, token: t, offset: 0, body: "01234")).status == 200
      assert body(c1) == %{"offset" => 5, "size" => 10, "complete" => false}

      c2 = request("PATCH", @id, token: t, offset: 5, body: "56789")
      assert body(c2)["complete"] == true
      assert File.read!(ResumableUpload.part_path(@id)) == "0123456789"
    end

    test "after a break the server says where to carry on" do
      t = token(@id, 10)
      request("PATCH", @id, token: t, offset: 0, body: "01234")
      assert request("HEAD", @id, token: t) |> offset_header() == "5"
      assert body(request("GET", @id, token: t))["offset"] == 5
    end

    test "a chunk that starts elsewhere is refused with the right offset, and writes nothing" do
      t = token(@id, 10)
      request("PATCH", @id, token: t, offset: 0, body: "01234")

      ahead = request("PATCH", @id, token: t, offset: 7, body: "789")
      assert ahead.status == 409
      assert body(ahead)["offset"] == 5

      again = request("PATCH", @id, token: t, offset: 0, body: "01234")
      assert again.status == 409
      assert File.read!(ResumableUpload.part_path(@id)) == "01234"
    end

    test "nothing is written past the declared size" do
      t = token(@id, 4)
      conn = request("PATCH", @id, token: t, offset: 0, body: "too long")
      assert conn.status == 413
      refute File.exists?(ResumableUpload.part_path(@id))
    end

    test "a chunk with the wrong checksum is refused and not written" do
      t = token(@id, 10)

      conn =
        request("PATCH", @id, token: t, offset: 0, body: "01234", sha: String.duplicate("0", 64))

      assert conn.status == 422
      refute File.exists?(ResumableUpload.part_path(@id))

      good = :crypto.hash(:sha256, "01234") |> Base.encode16(case: :lower)
      assert request("PATCH", @id, token: t, offset: 0, body: "01234", sha: good).status == 200
    end

    test "a chunk with no offset is refused" do
      assert request("PATCH", @id, token: token(@id, 5), body: "abc").status == 400
    end

    test "a chunk over the per-request limit is refused" do
      t = token(@id, 40_000_000)
      big = :binary.copy("x", 17 * 1_048_576)
      assert request("PATCH", @id, token: t, offset: 0, body: big).status == 413
    end

    test "an empty file completes with one empty chunk" do
      t = token(@id, 0)
      conn = request("PATCH", @id, token: t, offset: 0, body: "")
      assert body(conn)["complete"] == true
      assert File.exists?(ResumableUpload.part_path(@id))
    end

    test "giving up deletes the partial file" do
      t = token(@id, 10)
      request("PATCH", @id, token: t, offset: 0, body: "01234")
      assert request("DELETE", @id, token: t).status == 204
      refute File.exists?(ResumableUpload.part_path(@id))
    end
  end

  describe "external/1" do
    defp entry(attrs \\ %{}) do
      Map.merge(
        %{client_name: "cat.png", client_size: 10, client_last_modified: 99},
        attrs
      )
    end

    defp socket(user) do
      %Phoenix.LiveView.Socket{
        endpoint: @endpoint,
        assigns: %{__changed__: %{}, phoenix_kit_current_user: user}
      }
    end

    test "names the upload after the person and the file; the same file is the same upload" do
      ext = ResumableUpload.external(base: "/up")
      {:ok, a, _} = ext.(entry(), socket(%{uuid: "u1"}))
      {:ok, b, _} = ext.(entry(), socket(%{uuid: "u1"}))
      {:ok, other_user, _} = ext.(entry(), socket(%{uuid: "u2"}))
      {:ok, other_file, _} = ext.(entry(%{client_last_modified: 100}), socket(%{uuid: "u1"}))

      assert a.id == b.id
      assert a.id != other_user.id
      assert a.id != other_file.id
      assert a.url == "/up/" <> a.id
      assert a.uploader == "PkChunked"
      assert a.offset == 0
    end

    test "tells a returning file how much the server already has" do
      ext = ResumableUpload.external(base: "/up")
      {:ok, first, _} = ext.(entry(), socket(%{uuid: "u1"}))
      t = Phoenix.Token.sign(@endpoint, @salt, %{id: first.id, size: 10, owner: "u1"})
      request("PATCH", first.id, token: t, offset: 0, body: "01234")

      {:ok, again, _} = ext.(entry(), socket(%{uuid: "u1"}))
      assert again.offset == 5
    end

    test "its token is good for that upload" do
      {:ok, meta, _} = ResumableUpload.external(base: "/up").(entry(), socket(%{uuid: "u1"}))
      assert request("GET", meta.id, token: meta.token).status == 200
    end

    test "nobody signed in, no upload" do
      assert {:error, %{reason: "unauthorized"}, _} =
               ResumableUpload.external(base: "/up").(entry(), socket(nil))
    end

    test "an :owner function decides who the upload belongs to" do
      ext = ResumableUpload.external(base: "/up", owner: fn _ -> "guest-7" end)
      assert {:ok, %{id: _}, _} = ext.(entry(), socket(nil))
    end
  end

  describe "consume/3" do
    # A finished external entry on a socket, as LiveView holds it: the meta
    # comes from `external/1`, and it is the browser that marked it done.
    defp finished(size) do
      entry = %Phoenix.LiveView.UploadEntry{
        ref: "0",
        upload_config: :photos,
        done?: true,
        client_name: "cat.png",
        client_size: size,
        client_last_modified: 99
      }

      user_socket = socket(%{uuid: "u1"})
      {:ok, meta, _} = ResumableUpload.external(base: "/up").(entry, user_socket)

      conf = %Phoenix.LiveView.UploadConfig{
        name: :photos,
        ref: "phx-photos",
        external: true,
        entries: [entry],
        entry_refs_to_metas: %{"0" => meta}
      }

      {%{user_socket | assigns: Map.put(user_socket.assigns, :uploads, %{photos: conf})}, entry,
       meta.path}
    end

    defp store(path) do
      send(self(), {:stored, File.read!(path)})
      {:ok, :stored}
    end

    test "every byte held: the callback runs and the assembled file goes", %{dir: dir} do
      {socket, entry, path} = finished(5)
      File.mkdir_p!(dir)
      File.write!(path, "01234")

      assert ResumableUpload.consume(socket, entry, fn %{path: p} -> store(p) end) == :stored
      assert_received {:stored, "01234"}
      refute File.exists?(path)
    end

    test "a partial file is not handed over, and is kept to carry on from", %{dir: dir} do
      {socket, entry, path} = finished(5)
      File.mkdir_p!(dir)
      File.write!(path, "012")

      assert ResumableUpload.consume(socket, entry, fn %{path: p} -> store(p) end) ==
               {:error, :incomplete_upload}

      refute_received {:stored, _}
      assert File.read!(path) == "012"
    end

    @fields %{client_name: "cat.png", client_size: "5", client_last_modified: "99"}

    test "a file handed over is remembered as taken — by the key a browser reports it under",
         %{dir: dir} do
      {socket, entry, path} = finished(5)
      File.mkdir_p!(dir)
      File.write!(path, "01234")
      refute ResumableUpload.taken?("u1", @fields)

      assert ResumableUpload.consume(socket, entry, fn %{path: p} -> store(p) end) == :stored

      assert ResumableUpload.taken?("u1", @fields)

      refute ResumableUpload.taken?("u2", @fields),
             "someone else's file of the same name is not it"

      refute ResumableUpload.taken?("u1", %{@fields | client_last_modified: "100"})
      assert ResumableUpload.taken?("u1", entry), "an upload entry names the same file"
    end

    test "a file the callback refused is not taken", %{dir: dir} do
      {socket, entry, path} = finished(5)
      File.mkdir_p!(dir)
      File.write!(path, "01234")

      ResumableUpload.consume(socket, entry, fn _ -> {:postpone, :later} end)

      refute ResumableUpload.taken?("u1", @fields)
      assert File.exists?(path)
    end

    test "a partial file is not taken", %{dir: dir} do
      {socket, entry, path} = finished(5)
      File.mkdir_p!(dir)
      File.write!(path, "012")

      ResumableUpload.consume(socket, entry, fn %{path: p} -> store(p) end)

      refute ResumableUpload.taken?("u1", @fields)
    end

    test "a marker is judged against when the browser's copy was picked", %{dir: dir} do
      {socket, entry, path} = finished(5)
      File.mkdir_p!(dir)
      File.write!(path, "01234")
      ResumableUpload.consume(socket, entry, fn %{path: p} -> store(p) end)

      assert ResumableUpload.taken?("u1", @fields, 60_000), "taken after the copy was picked"
      assert ResumableUpload.taken?("u1", @fields, 0)

      marker = Path.join(dir, Path.basename(path, ".part") <> ".done")
      File.touch!(marker, System.os_time(:second) - 3600)

      refute ResumableUpload.taken?("u1", @fields, 60_000), "taken before the copy was picked"
      assert ResumableUpload.taken?("u1", @fields, 2 * 3_600_000), "…and after an older copy"
      assert ResumableUpload.taken?("u1", @fields), "no age: any marker counts"
      assert ResumableUpload.taken?("u1", @fields, nil)
      assert ResumableUpload.taken?("u1", @fields, -1)
    end

    test "the tolerance is one second: a marker written in the second of the pick counts, a later pick does not",
         %{dir: dir} do
      {socket, entry, path} = finished(5)
      File.mkdir_p!(dir)
      File.write!(path, "01234")
      ResumableUpload.consume(socket, entry, fn %{path: p} -> store(p) end)

      written = System.os_time(:second) - 100
      File.touch!(Path.join(dir, Path.basename(path, ".part") <> ".done"), written)
      age = fn picked_ms -> System.os_time(:millisecond) - picked_ms end

      # Whole seconds are all the file system tells: a pick 900 ms into the
      # second the marker is stamped with may well have come before it.
      assert ResumableUpload.taken?("u1", @fields, age.(written * 1000 + 900))
      assert ResumableUpload.taken?("u1", @fields, age.(written * 1000))
      assert ResumableUpload.taken?("u1", @fields, age.(written * 1000 - 5000))

      # The next second and a half on: the marker was stamped before the pick.
      refute ResumableUpload.taken?("u1", @fields, age.((written + 1) * 1000 + 500))
      refute ResumableUpload.taken?("u1", @fields, age.((written + 1) * 1000 + 5000))
    end

    test "a marker that cannot be written is logged, and the file is still handed over",
         %{dir: dir} do
      {socket, entry, path} = finished(5)
      File.mkdir_p!(dir)
      File.write!(path, "01234")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :stored ==
                   ResumableUpload.consume(socket, entry, fn %{path: p} ->
                     result = store(p)
                     # The directory turns into a file under it: no marker fits.
                     File.rm_rf!(dir)
                     File.write!(dir, "not a directory")
                     result
                   end)
        end)

      assert log =~ "could not mark an upload as taken"
      refute ResumableUpload.taken?("u1", @fields)
      File.rm(dir)
    end

    test "the same file sent again is no longer taken", %{dir: dir} do
      {socket, entry, path} = finished(5)
      File.mkdir_p!(dir)
      File.write!(path, "01234")
      ResumableUpload.consume(socket, entry, fn %{path: p} -> store(p) end)
      assert ResumableUpload.taken?("u1", @fields)

      {:ok, _meta, _} = ResumableUpload.external(base: "/up").(entry, socket)

      refute ResumableUpload.taken?("u1", @fields),
             "a new upload of it has begun: a copy left behind by it is not stale"
    end

    test "a file already taken by another entry of the same upload is not handed over" do
      {socket, entry, path} = finished(5)
      refute File.exists?(path)

      assert ResumableUpload.consume(socket, entry, fn %{path: p} -> store(p) end) ==
               {:error, :incomplete_upload}

      refute_received {:stored, _}
    end
  end

  describe "external?/1" do
    test "is true for the function external/1 builds, and for no other" do
      assert ResumableUpload.external?(ResumableUpload.external())
      assert ResumableUpload.external?(ResumableUpload.external(base: "/up"))
      refute ResumableUpload.external?(fn _entry, socket -> {:ok, %{}, socket} end)
      refute ResumableUpload.external?(false)
      refute ResumableUpload.external?(nil)
    end
  end

  describe "keeping the disk tidy" do
    test "release/1 deletes the assembled file, and only inside the upload directory", %{dir: dir} do
      File.mkdir_p!(dir)
      path = ResumableUpload.part_path(@id)
      File.write!(path, "x")
      outside = Path.join(System.tmp_dir!(), "pk_outside_#{System.unique_integer([:positive])}")
      File.write!(outside, "keep me")

      ResumableUpload.release(%{uploader: "PkChunked", path: outside})
      assert File.exists?(outside)

      ResumableUpload.release(%{uploader: "PkChunked", path: path})
      refute File.exists?(path)
      File.rm(outside)
    end

    test "sweep/1 keeps the mark of a taken file for a week, not a day", %{dir: dir} do
      File.mkdir_p!(dir)
      a_week = Path.join(dir, "week.done")
      two_days = Path.join(dir, "two-days.done")
      File.write!(a_week, "")
      File.write!(two_days, "")
      File.touch!(a_week, System.os_time(:second) - 8 * 86_400)
      File.touch!(two_days, System.os_time(:second) - 2 * 86_400)

      ResumableUpload.sweep(86_400)

      refute File.exists?(a_week)
      assert File.exists?(two_days)
    end

    test "sweep/1 removes partial files nobody has touched", %{dir: dir} do
      File.mkdir_p!(dir)
      old = Path.join(dir, "old.part")
      fresh = Path.join(dir, "fresh.part")
      File.write!(old, "x")
      File.write!(fresh, "x")
      File.touch!(old, System.os_time(:second) - 3 * 86_400)

      ResumableUpload.sweep(86_400)
      refute File.exists?(old)
      assert File.exists?(fresh)
    end
  end
end
