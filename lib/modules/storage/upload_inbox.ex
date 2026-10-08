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
  older than a week is swept on the next listing, and all users' inboxes are
  swept at most once an hour when an upload arrives.

  ## Where an upload belongs

  An item remembers the destination it was dropped on (`library_uuid` and
  `folder_uuid`, recorded by the first browser that claims it) and who is
  working on it (`owner`, the LiveView's pid). A retry goes to the recorded
  destination, never to whichever browser the click happened in — a private
  library's file must not land in Media — and a panel lists only the items of
  its own library. An item whose owner is still alive is live, whatever its
  age; one whose owner is gone reads as interrupted at once. Retry and
  Discard from a panel that has gone stale go through `claim/4` and
  `discard/2`, which refuse an item another process is working on.

  ## Persistence

  The default root is node-local temporary storage: a multi-node deployment,
  or a container with an ephemeral filesystem, loses "survives a refresh"
  when the reconnect lands elsewhere or the host restarts. Point
  `:upload_inbox_dir` at storage every node shares if that matters. Directories
  are created `0700`. There is no per-user quota yet.
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
          received_at: integer(),
          dest: %{library_uuid: String.t() | nil, folder_uuid: String.t() | nil} | nil,
          owner: String.t() | nil
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
  refuses — the caller then falls back to its own temp file, which is still
  where it was: a failure here never costs the bytes.

  `copy: true` leaves `src` in place (a second browser's own item).
  """
  @spec put(String.t(), Path.t(), map(), keyword()) ::
          {:ok, item(), Path.t()} | {:error, term()}
  def put(user_uuid, src, meta, opts \\ []) do
    with {:ok, dir} <- user_dir(user_uuid),
         :ok <- File.mkdir_p(dir) do
      File.chmod(root(), 0o700)
      File.chmod(dir, 0o700)
      maybe_sweep_all()

      id = Ecto.UUID.generate()
      dest = Path.join(dir, id)

      item = %{
        id: id,
        client_name: to_string(meta[:client_name] || "upload"),
        client_type: meta[:client_type],
        client_size: meta[:client_size],
        status: "received",
        error: nil,
        received_at: System.system_time(:second),
        dest: nil,
        owner: nil
      }

      store = if opts[:copy], do: &File.cp/2, else: &move/2

      with :ok <- store.(src, dest),
           :ok <- write_meta(dir, item) do
        {:ok, item, dest}
      else
        error ->
          give_back(src, dest, opts[:copy])
          error
      end
    else
      {:error, _} = error -> error
    end
  end

  # The bytes are in the inbox but their record could not be written: put them
  # back where they came from, and only then forget the inbox copy. When that is
  # not possible the inbox copy stays — a copy without a record still beats no
  # copy — and the caller carries on with the error.
  defp give_back(_src, dest, true), do: File.rm(dest)

  defp give_back(src, dest, _copy) do
    if File.exists?(src) do
      File.rm(dest)
    else
      move(dest, src)
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
    update(user_uuid, id, &%{&1 | status: "failed", error: reason, owner: nil})
  end

  @doc """
  Takes an item to work on, for the calling process: it reads as live while
  this process is, and `dest` (`%{library_uuid: _, folder_uuid: _}`) becomes
  its destination unless it already has one. `{:ok, item}` carries the item as
  it now stands — a retry stores it at `item.dest`, not where the click was.

  `{:error, :busy}` when another live process holds it (a stale panel retried
  an item a second tab has already taken), `{:error, :not_found}` when its
  bytes are gone.
  """
  @spec claim(String.t(), String.t(), map() | nil, pid()) :: {:ok, item()} | {:error, term()}
  def claim(user_uuid, id, dest, owner \\ self()) do
    with_lock(id, fn ->
      with {:ok, item} <- read(user_uuid, id),
           false <- busy?(item, owner),
           claimed = %{
             item
             | status: "received",
               error: nil,
               received_at: now(),
               owner: encode_owner(owner),
               dest: item.dest || dest
           },
           :ok <- write_item(user_uuid, claimed) do
        {:ok, claimed}
      else
        true -> {:error, :busy}
        {:error, _} = error -> error
      end
    end)
  end

  @doc """
  An item as it stands, or `nil` when it is gone. Its `dest` is where a retry
  must put it.
  """
  @spec get(String.t(), String.t()) :: item() | nil
  def get(user_uuid, id) do
    case read(user_uuid, id) do
      {:ok, item} -> item
      _ -> nil
    end
  end

  @doc """
  Removes an item the user let go of. `{:error, :busy}` — and nothing removed —
  while another live process is working on it: a panel that went stale must not
  delete bytes a second tab is storing.
  """
  @spec discard(String.t(), String.t(), pid()) :: :ok | {:error, :busy}
  def discard(user_uuid, id, owner \\ self()) do
    with_lock(id, fn ->
      case read(user_uuid, id) do
        {:ok, item} ->
          if busy?(item, owner), do: {:error, :busy}, else: delete(user_uuid, id)

        _ ->
          :ok
      end
    end)
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

  @doc """
  Whether an upload is in somebody's hands right now: received, and either
  claimed by a live process or too young to call abandoned. A page uses it to
  keep looking while that is so (see `list/1`).
  """
  @spec waiting?(String.t() | nil) :: boolean()
  def waiting?(user_uuid) do
    case user_dir(user_uuid) do
      {:ok, dir} ->
        now = now()

        dir
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.any?(&live_meta?(&1, now))

      _ ->
        false
    end
  end

  defp live_meta?(meta_path, now) do
    with {:ok, json} <- File.read(meta_path),
         {:ok, map} <- Jason.decode(json),
         %{status: "received"} = item <- decode(map) do
      if item.owner,
        do: owner_state(item, now) == :alive,
        else: now - item.received_at <= @interrupted_after_s
    else
      _ -> false
    end
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

        # Claimed: live while its owner is, interrupted the moment it is not —
        # a refresh or a crash does not make anyone wait two minutes.
        item.owner != nil ->
          case owner_state(item, now) do
            :alive -> []
            :gone -> [%{item | status: "interrupted"}]
          end

        # Not claimed by anyone yet: it may be on its way to a browser.
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

  # An owner on this node is checked; one on another node cannot be, so it is
  # taken as alive until the item is old enough that nothing could still be
  # working on it.
  defp owner_state(%{owner: owner, received_at: received_at}, now) do
    case decode_owner(owner) do
      pid when is_pid(pid) and node(pid) == node() ->
        if Process.alive?(pid), do: :alive, else: :gone

      pid when is_pid(pid) ->
        if now - received_at > @interrupted_after_s, do: :gone, else: :alive

      _ ->
        :gone
    end
  end

  defp busy?(%{owner: nil}, _me), do: false

  defp busy?(%{owner: owner} = item, me) do
    case decode_owner(owner) do
      ^me -> false
      _ -> item.status == "received" and owner_state(item, now()) == :alive
    end
  end

  defp encode_owner(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp decode_owner(owner) when is_binary(owner) do
    owner |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  defp decode_owner(_), do: nil

  defp decode(%{"id" => id} = map) when is_binary(id) do
    %{
      id: id,
      client_name: map["client_name"] || "upload",
      client_type: map["client_type"],
      client_size: map["client_size"],
      status: map["status"] || "received",
      error: map["error"],
      received_at: map["received_at"] || 0,
      dest: decode_dest(map["dest"]),
      owner: if(is_binary(map["owner"]), do: map["owner"])
    }
  end

  defp decode(_), do: nil

  defp decode_dest(%{} = dest),
    do: %{library_uuid: dest["library_uuid"], folder_uuid: dest["folder_uuid"]}

  defp decode_dest(_), do: nil

  defp read(user_uuid, id) do
    with {:ok, _bytes, meta_path} <- item_paths(user_uuid, id),
         {:ok, json} <- File.read(meta_path),
         {:ok, map} <- Jason.decode(json),
         %{} = item <- decode(map) do
      {:ok, item}
    else
      _ -> {:error, :not_found}
    end
  end

  defp update(user_uuid, id, fun) do
    with {:ok, item} <- read(user_uuid, id) do
      write_item(user_uuid, fun.(item))
    end
  end

  defp write_item(user_uuid, item) do
    with {:ok, dir} <- user_dir(user_uuid), do: write_meta(dir, item)
  end

  # One claim at a time per item, across nodes.
  defp with_lock(id, fun), do: :global.trans({{__MODULE__, id}, self()}, fun)

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
    # Written beside and renamed over: a reader (`list/1`) must never see a
    # half-written sidecar, which it would take for a broken one and remove.
    meta = Path.join(dir, item.id <> ".json")
    tmp = meta <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(tmp, Jason.encode!(item)),
         :ok <- File.rename(tmp, meta) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  # Every user's inbox, swept at most once an hour — a user who never comes
  # back has no listing of their own to do it.
  defp maybe_sweep_all do
    key = {__MODULE__, :last_sweep}
    last = :persistent_term.get(key, 0)

    if now() - last > 3600 do
      :persistent_term.put(key, now())

      for dir <- Path.wildcard(Path.join(root(), "*")), File.dir?(dir) do
        dir |> Path.join("*.json") |> Path.wildcard() |> Enum.each(&read_item(&1, dir, now()))
        sweep_orphans(dir)
      end
    end
  rescue
    _ -> :ok
  end

  # Bytes with no record (a record that could not be written, or an old-format
  # copy): nothing can show or retry them, so they go once a week has passed.
  defp sweep_orphans(dir) do
    cutoff = now() - @keep_for_s

    for path <- Path.wildcard(Path.join(dir, "*")),
        Regex.match?(@uuid, Path.basename(path)),
        not File.exists?(path <> ".json"),
        {:ok, %{mtime: mtime}} <- [File.stat(path, time: :posix)],
        mtime < cutoff do
      File.rm(path)
    end
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
