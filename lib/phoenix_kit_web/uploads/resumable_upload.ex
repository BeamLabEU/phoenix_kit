defmodule PhoenixKitWeb.ResumableUpload do
  @moduledoc """
  Resumable, chunked uploads for LiveView, in one file: a `Plug` that receives
  the pieces, the store that keeps the partial file, and the `external:`
  function that hands a LiveView upload to them.

  The upload manager (`PhoenixKitWeb.Components.Core.UploadManager`) uses it
  to pause a file and carry on from where it stopped, and to carry on after a
  dropped connection or a reloaded page. Without it, LiveView's own uploader
  sends a file in one go and a stopped file starts again from the beginning.
  It is optional: an upload that does not name `external:` is unchanged.

  ## Using it

      # mount
      socket
      |> allow_upload(:photos,
        accept: :any,
        max_entries: 100,
        auto_upload: true,
        external: PhoenixKitWeb.ResumableUpload.external(),
        progress: &handle_progress/3
      )
      |> PhoenixKitWeb.Components.Core.UploadManager.attach()

      # template
      <.upload_manager id="photos" upload={@uploads.photos} resumable />

      # progress callback: the meta has the assembled file's `path`
      PhoenixKitWeb.ResumableUpload.consume(socket, entry, fn %{path: path} ->
        File.cp!(path, dest)
        {:ok, dest}
      end)

  The router must reach the plug. PhoenixKit does this itself; anywhere else:

      forward "/uploads", PhoenixKitWeb.ResumableUpload

  and `external/1` takes `base: "/uploads"` to match. The endpoint's
  `Plug.Parsers` must let an `application/octet-stream` body through
  (`pass: ["*/*"]`, which `mix phx.new` sets up).

  ## How a file travels

  `external/1` runs when LiveView registers an entry. It names the upload
  after the signed-in user and the file's name, size and modified time, so
  *the same file picked again is the same upload*, and signs a token for it.
  The browser asks the plug how much it already has (`GET`), sends the rest in
  chunks (`PATCH` with the byte offset they start at), and finishes when the
  server holds every byte. A chunk is written only if it starts exactly where
  the file ends, so a repeated or late chunk cannot corrupt it; the answer to
  a wrong offset is `409` with the right one. The file's bytes are kept in
  `dir/0`; a partial file nobody touches for a day is swept away.

  Once `consume/3` has handed a file over, a small marker is left for a week
  (`taken?/2`) and the partial file goes. A browser that kept its own copy,
  and whose page closed before it heard the file had arrived, asks the marker
  before it sends the copy again. A new upload of the same file removes it.

  ## Security

  Every request carries the token (`x-upload-token`), which names the upload,
  its size and its owner and expires after a day. The plug does nothing else
  for a request without a good one, never writes past the declared size, and
  reads at most `#{div(16_777_216, 1_048_576)} MiB` per request.
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKit.Utils.Routes

  @salt "phoenix_kit resumable upload"
  @token_max_age 86_400
  @chunk_size 2 * 1_048_576
  @max_chunk 16 * 1_048_576
  @keep_seconds 86_400
  @done_keep_seconds 7 * 86_400
  @sweep_every_seconds 600
  @uploader "PkChunked"

  # --------------------------------------------------------------------------
  # LiveView side
  # --------------------------------------------------------------------------

  @doc """
  The function for `allow_upload(..., external: ...)`.

  Options:

    * `:owner` — `(socket -> term | nil)`, who the upload belongs to. Defaults
      to the signed-in PhoenixKit user's uuid. No owner, no upload.
    * `:base` — the URL the plug is mounted at. Defaults to PhoenixKit's own
      route.
    * `:chunk_size` — bytes per request (default #{@chunk_size}).
  """
  @spec external(keyword()) :: (map(), Phoenix.LiveView.Socket.t() ->
                                  {:ok | :error, map(), term()})
  def external(opts \\ []) do
    fn entry, socket ->
      case owner(socket, opts) do
        nil ->
          {:error, %{reason: "unauthorized"}, socket}

        owner ->
          sweep_now_and_then()
          id = upload_id(owner, entry)
          # Picked or sent again: whatever was taken before is not this one.
          File.rm(done_path(id))

          token =
            Phoenix.Token.sign(socket.endpoint, @salt, %{
              id: id,
              size: entry.client_size,
              owner: to_string(owner)
            })

          meta = %{
            uploader: @uploader,
            id: id,
            url: base(opts) <> "/" <> id,
            token: token,
            chunk_size: Keyword.get(opts, :chunk_size, @chunk_size),
            offset: received(id, entry.client_size),
            path: part_path(id)
          }

          {:ok, meta, socket}
      end
    end
  end

  @doc """
  `Phoenix.LiveView.consume_uploaded_entry/3` for an entry that came through
  `external/1`: the assembled file is deleted once `fun` returns `{:ok, _}`
  (it has been copied or stored by then), kept on `{:postpone, _}`.

  For such an entry it is the browser that says the file is done, so `fun`
  runs only when the server holds every declared byte. Otherwise the entry
  is dropped, `fun` is not called, the partial file is kept (picked again,
  the file carries on from it) and the answer is
  `{:error, :incomplete_upload}`. That happens when the same file (the same
  name, size and date, so the same upload) was in flight twice and the other
  entry was consumed first, or when a client claims a finish it did not send.
  """
  def consume(socket, entry, fun) when is_function(fun, 1) do
    Phoenix.LiveView.consume_uploaded_entry(socket, entry, fn meta ->
      if assembled?(meta, entry) do
        result = fun.(meta)

        if match?({:ok, _}, result) do
          mark_taken(meta)
          release(meta)
        end

        result
      else
        {:ok, {:error, :incomplete_upload}}
      end
    end)
  end

  # LiveView takes an external upload's progress from the browser, so the
  # bytes are counted here. Any other upload's file is LiveView's own.
  defp assembled?(%{uploader: @uploader, path: path}, %{client_size: size})
       when is_binary(path) do
    match?({:ok, %{size: ^size}}, File.stat(path))
  end

  defp assembled?(_meta, _entry), do: true

  @doc "Deletes the assembled file named by a consumed entry's meta."
  def release(%{uploader: @uploader, path: path}) when is_binary(path) do
    if inside_dir?(path), do: File.rm(path)
    :ok
  end

  def release(_meta), do: :ok

  @doc """
  Whether the server has already taken this person's file, the one named by
  `client_name`, `client_size` and `client_last_modified` (an upload entry's
  fields, or the same three in a map of strings): its bytes were handed over
  by `consume/3` and it has not been picked or sent again since.

  A browser that kept its own copy of a file in case the transfer was cut
  short asks this before sending the copy again — the page it was told on may
  have gone before the news arrived.
  """
  def taken?(owner, fields) when is_map(fields) do
    File.exists?(done_path(upload_id(to_string(owner), fields)))
  end

  # A marker, not a copy: kept for as long as the browser may keep its own.
  defp mark_taken(%{uploader: @uploader, id: id}) when is_binary(id) do
    File.mkdir_p(dir())
    File.write(done_path(id), "")
  end

  defp mark_taken(_meta), do: :ok

  defp done_path(id), do: Path.join(dir(), id <> ".done")

  defp owner(socket, opts) do
    case Keyword.get(opts, :owner) do
      fun when is_function(fun, 1) ->
        fun.(socket)

      _ ->
        case socket.assigns[:phoenix_kit_current_user] do
          %{uuid: uuid} -> uuid
          _ -> nil
        end
    end
  end

  defp base(opts) do
    case Keyword.get(opts, :base) do
      nil -> Routes.path("/api/resumable-uploads")
      base -> String.trim_trailing(base, "/")
    end
  end

  # The same file from the same person is the same upload.
  defp upload_id(owner, entry) do
    :crypto.hash(
      :sha256,
      Enum.join(
        [owner, entry.client_name, entry.client_size, entry.client_last_modified],
        "\0"
      )
    )
    |> Base.encode16(case: :lower)
    |> binary_part(0, 40)
  end

  # --------------------------------------------------------------------------
  # Store
  # --------------------------------------------------------------------------

  @doc "The directory partial files are kept in."
  def dir do
    Application.get_env(:phoenix_kit, :resumable_upload_dir) ||
      Path.join(System.tmp_dir!(), "phoenix_kit_resumable")
  end

  @doc "The path of an upload's file, whole or not."
  def part_path(id), do: Path.join(dir(), id <> ".part")

  defp inside_dir?(path), do: String.starts_with?(Path.expand(path), Path.expand(dir()) <> "/")

  # Bytes held, never more than the declared size.
  defp received(id, size) do
    case File.stat(part_path(id)) do
      {:ok, %{size: held}} -> min(held, size)
      _ -> 0
    end
  end

  @doc """
  Deletes partial files nobody has touched for `max_age` seconds, and the
  markers of taken files a week after they were written.
  """
  def sweep(max_age \\ @keep_seconds) do
    now = System.os_time(:second)

    case File.ls(dir()) do
      {:ok, names} ->
        for name <- names, limit = mtime_limit(name, now, max_age) do
          path = Path.join(dir(), name)

          case File.stat(path, time: :posix) do
            {:ok, %{mtime: mtime}} when mtime < limit -> File.rm(path)
            _ -> :ok
          end
        end

        :ok

      _ ->
        :ok
    end
  end

  defp mtime_limit(name, now, max_age) do
    cond do
      String.ends_with?(name, ".part") -> now - max_age
      String.ends_with?(name, ".done") -> now - @done_keep_seconds
      true -> nil
    end
  end

  # At most every few minutes, in the process that is already doing the work.
  defp sweep_now_and_then do
    now = System.monotonic_time(:second)
    last = :persistent_term.get({__MODULE__, :swept}, nil)

    if is_nil(last) or now - last > @sweep_every_seconds do
      :persistent_term.put({__MODULE__, :swept}, now)
      sweep()
    end
  end

  # --------------------------------------------------------------------------
  # Plug
  # --------------------------------------------------------------------------

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: [id]} = conn, _opts) do
    case authorize(conn, id) do
      {:ok, claims} -> handle(conn, conn.method, claims)
      :error -> reply(conn, 401, %{error: "unauthorized"})
    end
  end

  def call(conn, _opts), do: reply(conn, 404, %{error: "not_found"})

  defp authorize(conn, id) do
    case get_req_header(conn, "x-upload-token") do
      [token] ->
        case Phoenix.Token.verify(conn, @salt, token, max_age: @token_max_age) do
          {:ok, %{id: ^id} = claims} -> {:ok, claims}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  # How much the server has.
  defp handle(conn, method, %{id: id, size: size}) when method in ["GET", "HEAD"] do
    offset = received(id, size)

    conn
    |> put_resp_header("upload-offset", Integer.to_string(offset))
    |> put_resp_header("cache-control", "no-store")
    |> reply(200, %{offset: offset, size: size, complete: offset == size})
  end

  # One chunk, starting at `upload-offset`.
  defp handle(conn, "PATCH", %{id: id, size: size}) do
    with {:ok, start} <- start_offset(conn),
         {:ok, body, conn} <- read_chunk(conn) do
      write_chunk(conn, id, size, start, body)
    else
      :bad_offset -> reply(conn, 400, %{error: "bad_offset"})
      :too_large -> reply(conn, 413, %{error: "chunk_too_large"})
      {:error, _} -> reply(conn, 400, %{error: "unreadable_body"})
    end
  end

  # The upload is given up: its partial file goes.
  defp handle(conn, "DELETE", %{id: id}) do
    File.rm(part_path(id))
    send_resp(conn, 204, "")
  end

  defp handle(conn, _method, _claims), do: reply(conn, 405, %{error: "method_not_allowed"})

  # The lock is this node's only: the partial file is on this node's disk, and
  # a cluster-wide lock would cost a round trip to every node for each chunk.
  defp write_chunk(conn, id, size, start, body) do
    :global.trans(
      {{__MODULE__, id}, self()},
      fn ->
        File.mkdir_p!(dir())
        held = received(id, size)
        len = byte_size(body)

        cond do
          start + len > size ->
            reply(conn, 413, %{error: "past_declared_size"})

          # Nothing to write twice: an offset that does not match is told where
          # the file really ends.
          start != held ->
            conn
            |> put_resp_header("upload-offset", Integer.to_string(held))
            |> reply(409, %{error: "offset_mismatch", offset: held})

          not chunk_intact?(conn, body) ->
            reply(conn, 422, %{error: "checksum_mismatch"})

          true ->
            :ok = File.write(part_path(id), body, [:append, :binary])
            done = held + len

            conn
            |> put_resp_header("upload-offset", Integer.to_string(done))
            |> reply(200, %{offset: done, size: size, complete: done == size})
        end
      end,
      [node()]
    )
  end

  defp start_offset(conn) do
    with [value] <- get_req_header(conn, "upload-offset"),
         {offset, ""} when offset >= 0 <- Integer.parse(value) do
      {:ok, offset}
    else
      _ -> :bad_offset
    end
  end

  # `x-chunk-sha256`, when sent, is checked; a browser without Web Crypto
  # (an insecure origin) sends none, and the size checks still hold.
  defp chunk_intact?(conn, body) do
    case get_req_header(conn, "x-chunk-sha256") do
      [expected] ->
        :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) == String.downcase(expected)

      _ ->
        true
    end
  end

  defp read_chunk(conn) do
    case read_body(conn, length: @max_chunk, read_length: 1_048_576, read_timeout: 30_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _, _} -> :too_large
      {:error, reason} -> {:error, reason}
    end
  end

  defp reply(conn, status, body) do
    if conn.method == "HEAD" do
      send_resp(conn, status, "")
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end
  end
end
