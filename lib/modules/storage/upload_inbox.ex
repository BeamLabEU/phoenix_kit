defmodule PhoenixKit.Modules.Storage.UploadInbox do
  @moduledoc """
  Where an upload's bytes wait between "the server has them" and "they are
  stored", so a failure in between is something a person can see and act on.

  The media browser used to copy a finished transfer to a temp path, try to
  store it, and delete the temp file either way. A failed store became one
  anonymous count in a flash ("2 failed") and the bytes were gone; a raise
  took the LiveView down with every queued file in it; a page refresh while
  files were queued lost them without a word. Someone who dropped ten
  pictures and found six had no way to learn which four, or to try again.

  Now a received upload is written here first and removed only once it is
  stored. One that fails stays, marked with why; one whose processing never
  finished (the LiveView died, the page was refreshed) stays too, and reads
  as interrupted once it is old enough that nothing can still be working on
  it. `list/1` is what the browser's "Upload problems" panel shows, and it
  survives a refresh because it lives on disk rather than in a socket.

  One directory per user (`<root>/<user_uuid>/`), holding each upload's bytes
  at `<id>` and what is known about it at `<id>.json`. The root defaults to
  the system temp dir — this is a waiting room, not storage — and can be
  moved with `config :phoenix_kit, :upload_inbox_dir, "/path"`. Anything
  older than a week is swept on the next listing.
  """

  require Logger

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # A "received" item younger than this may still be in a drain queue
  # somewhere; older, nothing is working on it any more.
  @interrupted_after_s 120
  @keep_for_s 7 * 24 * 3600

  @type item :: %{
          id: String.t(),
          client_name: String.t(),
          client_type: String.t() | nil,
          client_size: non_neg_integer() | nil,
          status: String.t(),
          error: String.t() | nil,
          received_at: integer()
        }

  @doc "The inbox root."
  def root,
    do:
      Application.get_env(:phoenix_kit, :upload_inbox_dir) ||
        Path.join(System.tmp_dir!(), "phoenix_kit_upload_inbox")

  @doc """
  Moves `src` into `user_uuid`'s inbox as a received upload and returns the
  item. `meta` carries the client's `:client_name`, `:client_type` and
  `:client_size`. `{:error, reason}` when the user is not a uuid or the disk
  refuses — the caller then falls back to its own temp file.
  """
  @spec put(String.t(), Path.t(), map()) :: {:ok, item(), Path.t()} | {:error, term()}
  def put(user_uuid, src, meta) do
    with {:ok, dir} <- user_dir(user_uuid),
         :ok <- File.mkdir_p(dir) do
      id = Ecto.UUID.generate()
      dest = Path.join(dir, id)

      item = %{
        id: id,
        client_name: to_string(meta[:client_name] || "upload"),
        client_type: meta[:client_type],
        client_size: meta[:client_size],
        status: "received",
        error: nil,
        received_at: System.system_time(:second)
      }

      with :ok <- move(src, dest),
           :ok <- write_meta(dir, item) do
        {:ok, item, dest}
      else
        error ->
          File.rm(dest)
          error
      end
    else
      {:error, _} = error -> error
    end
  end

  @doc "The inbox path of `path`'s item as `{user_uuid, id}`, or nil if `path` is not in an inbox."
  @spec locate(Path.t()) :: {String.t(), String.t()} | nil
  def locate(path) when is_binary(path) do
    root = Path.expand(root())
    expanded = Path.expand(path)

    with true <- String.starts_with?(expanded, root <> "/"),
         [user_uuid, id] <- Path.split(Path.relative_to(expanded, root)),
         true <- Regex.match?(@uuid, user_uuid) and Regex.match?(@uuid, id) do
      {user_uuid, id}
    else
      _ -> nil
    end
  end

  def locate(_), do: nil

  @doc "Marks an item failed, keeping its bytes for a retry."
  @spec fail(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def fail(user_uuid, id, reason) do
    update(user_uuid, id, &%{&1 | status: "failed", error: reason})
  end

  @doc "Marks an item as being worked on again (a retry), so it reads as live, not interrupted."
  @spec touch(String.t(), String.t()) :: :ok | {:error, term()}
  def touch(user_uuid, id) do
    update(user_uuid, id, &%{&1 | status: "received", error: nil, received_at: now()})
  end

  @doc "Removes an item — it was stored, or the user discarded it."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(user_uuid, id) do
    case item_paths(user_uuid, id) do
      {:ok, bytes, meta} ->
        File.rm(bytes)
        File.rm(meta)
        :ok

      _ ->
        :ok
    end
  end

  @doc "The bytes of an item, when it is still here."
  @spec path(String.t(), String.t()) :: {:ok, Path.t()} | :error
  def path(user_uuid, id) do
    case item_paths(user_uuid, id) do
      {:ok, bytes, _meta} -> if File.exists?(bytes), do: {:ok, bytes}, else: :error
      _ -> :error
    end
  end

  @doc """
  The items that need the user's attention, oldest first: failed ones, and
  received ones old enough that their processing was clearly interrupted
  (those come back with status `"interrupted"`). Sweeps week-old items.
  """
  @spec list(String.t() | nil) :: [item()]
  def list(user_uuid) do
    case user_dir(user_uuid) do
      {:ok, dir} ->
        now = now()

        dir
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.flat_map(&read_item(&1, dir, now))
        |> Enum.sort_by(& &1.received_at)

      _ ->
        []
    end
  rescue
    error ->
      Logger.warning("[UploadInbox] list failed: #{Exception.message(error)}")
      []
  end

  defp read_item(meta_path, dir, now) do
    with {:ok, json} <- File.read(meta_path),
         {:ok, map} <- Jason.decode(json),
         %{} = item <- decode(map),
         true <- File.exists?(Path.join(dir, item.id)) do
      cond do
        now - item.received_at > @keep_for_s ->
          File.rm(Path.join(dir, item.id))
          File.rm(meta_path)
          []

        item.status == "failed" ->
          [item]

        now - item.received_at > @interrupted_after_s ->
          [%{item | status: "interrupted"}]

        true ->
          []
      end
    else
      # Bytes gone (or the sidecar unreadable): nothing left to retry.
      _ ->
        File.rm(meta_path)
        []
    end
  end

  defp decode(%{"id" => id} = map) when is_binary(id) do
    %{
      id: id,
      client_name: map["client_name"] || "upload",
      client_type: map["client_type"],
      client_size: map["client_size"],
      status: map["status"] || "received",
      error: map["error"],
      received_at: map["received_at"] || 0
    }
  end

  defp decode(_), do: nil

  defp update(user_uuid, id, fun) do
    with {:ok, _bytes, meta_path} <- item_paths(user_uuid, id),
         {:ok, json} <- File.read(meta_path),
         {:ok, map} <- Jason.decode(json),
         %{} = item <- decode(map) do
      write_meta(Path.dirname(meta_path), fun.(item))
    else
      _ -> {:error, :not_found}
    end
  end

  defp item_paths(user_uuid, id) do
    with {:ok, dir} <- user_dir(user_uuid),
         true <- is_binary(id) and Regex.match?(@uuid, id) do
      {:ok, Path.join(dir, id), Path.join(dir, id <> ".json")}
    else
      _ -> :error
    end
  end

  # The uuid check is the path-traversal guard: nothing but a uuid ever
  # becomes a directory or file name here.
  defp user_dir(user_uuid) when is_binary(user_uuid) do
    if Regex.match?(@uuid, user_uuid),
      do: {:ok, Path.join(root(), String.downcase(user_uuid))},
      else: {:error, :invalid_user}
  end

  defp user_dir(_), do: {:error, :invalid_user}

  defp write_meta(dir, item) do
    File.write(Path.join(dir, item.id <> ".json"), Jason.encode!(item))
  end

  # A rename when source and inbox share a filesystem (the usual case — both
  # under the temp dir); a copy otherwise.
  defp move(src, dest) do
    case File.rename(src, dest) do
      :ok ->
        :ok

      {:error, _} ->
        with :ok <- File.cp(src, dest) do
          File.rm(src)
          :ok
        end
    end
  end

  defp now, do: System.system_time(:second)
end
