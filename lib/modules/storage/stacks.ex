defmodule PhoenixKit.Modules.Storage.Stacks do
  @moduledoc """
  Stacks: two or more files of one library that a person wants seen as one thing, such
  as the pages of a document photographed one by one, or a burst (V232,
  `PhoenixKit.Modules.Storage.FileStack`).

  A file is in one stack at most (`File.stack_uuid`), at a place in it
  (`File.stack_position`, lowest first). A stack has an optional title and description
  and nothing else: its date is its files' capture dates (to move a stack in time, date
  its files, `PhoenixKit.Modules.Storage.ManualDate`), and its **cover** is not stored.
  A listing works out the cover as the first of the stack's files that the reader may
  see, so a trashed cover hands over to the next file and comes back when restored,
  with nothing renumbered (`PhoenixKitPhotos.Timeline` does this for the timeline).

  Who may: someone who may edit every file involved (`Libraries.can?/3` with `:edit`:
  a library's owner and managers, a contributor for their own uploads), and every file
  must be in the same library. Each change is announced on the file-changes topic
  (`Storage.subscribe_to_file_changes/0`).

  A stack whose files drop below two (one removed, the rest moved away) is dissolved:
  a stack of one is just a file.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileStack
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope

  @min_files 2
  @max_files 200

  @type reason ::
          :too_few
          | :too_many
          | :not_found
          | :not_stackable
          | :mixed_libraries
          | :forbidden
          | Ecto.Changeset.t()

  @doc "The fewest files a stack has."
  def min_files, do: @min_files

  @doc "The most files a stack may have."
  def max_files, do: @max_files

  @doc """
  Makes one stack of `file_uuids`.

  A file already in a stack brings its whole stack along, so stacking a stack with more
  photos, or two stacks together, merges them into one new stack; the old ones are
  deleted. The files are ordered by capture date, then by name with numbers read as
  numbers ("page 2" before "page 10"); the first is the cover. A merge keeps the order
  of the stack whose files come first, cover included, and puts the other files in
  among its own by date (as `add/3` does).

  `attrs` may give a `:title` and a `:description`; one left out or `nil` is not given.
  Without them a merge keeps the text of the stack whose files come first.

  With `keep_order: true` in `opts` the files stay in the order given (for copies of a
  stack, made in another library in their stack's order).

  Returns `{:ok, stack}`, or `{:error, reason}`: `:too_few` (fewer than two files),
  `:too_many` (more than `max_files/0`), `:not_found` (a file does not exist),
  `:not_stackable` (a trashed file, or one that is not a user's image or video),
  `:mixed_libraries`, `:forbidden`, or a changeset for a title or description that is
  too long.
  """
  @spec create([String.t()], Scope.t() | nil, map(), keyword()) ::
          {:ok, FileStack.t()} | {:error, reason()}
  def create(file_uuids, scope, attrs \\ %{}, opts \\ []) do
    uuids = file_uuids |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

    repo().transaction(fn ->
      with {:ok, chosen} <- load(uuids),
           :ok <- check_stackable(chosen),
           files = with_their_stacks(chosen),
           :ok <- check_count(files),
           {:ok, library_uuid} <- one_library(files),
           :ok <- check_edit(files, scope),
           old = old_stacks(files),
           {:ok, stack} <- insert_stack(library_uuid, scope, merged_text(old, files, attrs)) do
        if(opts[:keep_order], do: in_given_order(files, uuids), else: merged_order(old, files))
        |> place(stack.uuid)

        delete_stacks(Enum.map(old, & &1.uuid))
        {stack, Enum.map(files, & &1.uuid)}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> announce()
  end

  @doc """
  Adds `file_uuids` to the stack `stack_uuid`: one file or many. A file in another stack
  brings that whole stack along, and that stack is gone (as in `create/4`); files already
  in this stack stay as they are.

  The stack keeps its order and its cover: each new file goes in among the others by
  capture date (then name), never before the cover. A title or description the stack has
  none of is taken from a stack that came along.

  Returns `{:ok, stack}`, or `{:error, reason}` as `create/4` does (`:not_found` also for
  a stack that is not there).
  """
  @spec add(String.t(), [String.t()], Scope.t() | nil) ::
          {:ok, FileStack.t()} | {:error, reason()}
  def add(stack_uuid, file_uuids, scope) do
    uuids = file_uuids |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

    repo().transaction(fn ->
      with %FileStack{} = stack <- get(stack_uuid) || {:error, :not_found},
           [_ | _] = members <- members_for_update(stack.uuid),
           {:ok, chosen} <- load(uuids),
           chosen = Enum.reject(chosen, &(&1.stack_uuid == stack.uuid)),
           :ok <- check_stackable(chosen),
           newcomers = with_their_stacks(chosen),
           files = members ++ newcomers,
           :ok <- check_count(files),
           {:ok, _library_uuid} <- one_library(files),
           :ok <- check_edit(files, scope) do
        if newcomers == [] do
          {stack, []}
        else
          old = old_stacks(newcomers)
          members |> arrange(newcomers) |> place(stack.uuid)
          delete_stacks(Enum.map(old, & &1.uuid))
          fill_text(stack, old, newcomers)
          {touch(stack.uuid), Enum.map(files, & &1.uuid)}
        end
      else
        [] -> repo().rollback(:not_found)
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> announce()
  end

  @doc """
  Takes a stack apart: its files become single files again, where they are, and its
  title and description go. Returns `{:ok, file_uuids}`.
  """
  @spec unstack(String.t(), Scope.t() | nil) :: {:ok, [String.t()]} | {:error, reason()}
  def unstack(stack_uuid, scope) do
    repo().transaction(fn ->
      files = members_for_update(stack_uuid)

      with :ok <- if(files == [], do: {:error, :not_found}, else: :ok),
           :ok <- check_edit(files, scope) do
        dissolve(stack_uuid)
        uuids = Enum.map(files, & &1.uuid)
        {uuids, uuids}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> announce()
  end

  @doc """
  Takes one file out of its stack; it stays where it is in the library. A stack left
  with fewer than two files is taken apart. Returns `{:ok, file_uuids}`: the files whose
  stack changed.
  """
  @spec remove(String.t(), Scope.t() | nil) :: {:ok, [String.t()]} | {:error, reason()}
  def remove(file_uuid, scope) do
    repo().transaction(fn ->
      with {:ok, [file]} <- load([to_string(file_uuid)]),
           stack_uuid when is_binary(stack_uuid) <- file.stack_uuid || {:error, :not_found},
           files = members_for_update(stack_uuid),
           :ok <- check_edit([file], scope) do
        rest = Enum.reject(files, &(&1.uuid == file.uuid))

        changed =
          if length(rest) < @min_files do
            dissolve(stack_uuid)
            Enum.map(files, & &1.uuid)
          else
            unplace([file.uuid])
            touch(stack_uuid)
            [file.uuid]
          end

        {changed, changed}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> announce()
  end

  @doc """
  Makes `file_uuid` its stack's cover: it moves to the front, the others keep their
  order. Returns `{:ok, stack}`.
  """
  @spec make_cover(String.t(), Scope.t() | nil) :: {:ok, FileStack.t()} | {:error, reason()}
  def make_cover(file_uuid, scope) do
    repo().transaction(fn ->
      with {:ok, [file]} <- load([to_string(file_uuid)]),
           stack_uuid when is_binary(stack_uuid) <- file.stack_uuid || {:error, :not_found},
           files = members_for_update(stack_uuid),
           :ok <- check_edit(files, scope) do
        lowest = files |> Enum.map(& &1.stack_position) |> Enum.min()

        if file.stack_position > lowest or Enum.count(files, &(&1.stack_position == lowest)) > 1 do
          from(f in StorageFile, where: f.uuid == ^file.uuid)
          |> repo().update_all(set: [stack_position: lowest - 1])
        end

        {touch(stack_uuid), Enum.map(files, & &1.uuid)}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> announce()
  end

  @doc """
  Changes a stack's `:title` and `:description` (either may be blank, which clears it;
  one left out or `nil` stays as it is).
  Returns `{:ok, stack}`, or `{:error, changeset}` when one is too long.
  """
  @spec update(String.t(), map(), Scope.t() | nil) :: {:ok, FileStack.t()} | {:error, reason()}
  def update(stack_uuid, attrs, scope) do
    repo().transaction(fn ->
      with %FileStack{} = stack <- get(stack_uuid) || {:error, :not_found},
           files = members_for_update(stack_uuid),
           :ok <- check_edit(files, scope),
           {:ok, stack} <- stack |> FileStack.changeset(text(attrs)) |> repo().update() do
        {stack, Enum.map(files, & &1.uuid)}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> announce()
  end

  @doc "The stack with this uuid, or `nil`."
  @spec get(String.t() | nil) :: FileStack.t() | nil
  def get(nil), do: nil

  def get(stack_uuid) do
    case Ecto.UUID.cast(stack_uuid) do
      {:ok, uuid} -> repo().get(FileStack, uuid)
      :error -> nil
    end
  end

  @doc """
  Every file of a stack in its order, trashed ones included. What a reader may see of
  them is the caller's business (`PhoenixKitPhotos.Timeline` lists stacks for readers).
  """
  @spec files(String.t()) :: [StorageFile.t()]
  def files(stack_uuid) do
    from(f in StorageFile,
      where: f.stack_uuid == ^stack_uuid,
      order_by: [asc: f.stack_position, asc: f.uuid]
    )
    |> repo().all()
  end

  @doc """
  The order files go in when they are stacked: capture date (undated last), then name
  with numbers read as numbers, then uuid, so the same files always stack the same way.
  """
  @spec order([StorageFile.t()]) :: [StorageFile.t()]
  def order(files), do: Enum.sort_by(files, &sort_key/1)

  defp sort_key(file) do
    {is_nil(file.taken_at), file.taken_at && DateTime.to_unix(file.taken_at, :microsecond),
     natural_key(file.original_file_name), file.uuid}
  end

  @doc """
  A sort key that reads runs of digits as numbers, case-insensitively: `"page 2"`
  before `"page 10"`, `"IMG_9"` before `"img_10"`.
  """
  @spec natural_key(String.t() | nil) :: [{0, integer()} | {1, String.t()}]
  def natural_key(nil), do: []

  def natural_key(name) do
    ~r/\d+|\D+/u
    |> Regex.scan(String.downcase(name))
    |> Enum.map(fn [part] ->
      case Integer.parse(part) do
        {n, ""} -> {0, n}
        _ -> {1, part}
      end
    end)
  end

  # ---------------------------------------------------------------------------

  defp load(uuids) do
    valid = for u <- uuids, {:ok, uuid} <- [Ecto.UUID.cast(u)], do: uuid

    files =
      from(f in StorageFile, where: f.uuid in ^valid, lock: "FOR UPDATE")
      |> repo().all()

    if valid != [] and length(files) == length(uuids),
      do: {:ok, files},
      else: {:error, :not_found}
  end

  # What a person can see and stack: their own pictures and videos, not a system file, a
  # derived child (a tile, an edit's backup) or something in the trash.
  defp check_stackable(files) do
    if Enum.all?(files, &stackable?/1), do: :ok, else: {:error, :not_stackable}
  end

  defp stackable?(%StorageFile{} = file) do
    file.file_type in ["image", "video"] and not file.system_managed and
      is_nil(file.parent_file_uuid) and is_nil(file.trashed_at)
  end

  # The chosen files and every file of the stacks they are in.
  defp with_their_stacks(chosen) do
    stack_uuids = chosen |> Enum.map(& &1.stack_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    others =
      if stack_uuids == [] do
        []
      else
        chosen_uuids = Enum.map(chosen, & &1.uuid)

        from(f in StorageFile,
          where: f.stack_uuid in ^stack_uuids and f.uuid not in ^chosen_uuids,
          lock: "FOR UPDATE"
        )
        |> repo().all()
      end

    chosen ++ others
  end

  # The files named, in the order named; any brought along by their stacks after them, in
  # the usual order.
  defp in_given_order(files, uuids) do
    at = uuids |> Enum.with_index() |> Map.new()
    {named, others} = Enum.split_with(files, &Map.has_key?(at, &1.uuid))
    Enum.sort_by(named, &at[&1.uuid]) ++ order(others)
  end

  # A merge's order: the files of the stack that comes first in their stack's order, the
  # others in among them by date (`arrange/2`); with no stack among them, `order/1`.
  defp merged_order(old, files) do
    case first_stack(old, files) do
      nil ->
        order(files)

      base ->
        {members, others} = Enum.split_with(files, &(&1.stack_uuid == base.uuid))
        members |> Enum.sort_by(&{&1.stack_position, &1.uuid}) |> arrange(others)
    end
  end

  # `base` in its order, its cover first and staying first; each of `newcomers` goes in
  # before the first of the rest that sorts after it (`sort_key/1`), or at the end.
  defp arrange([], newcomers), do: order(newcomers)
  defp arrange([cover | rest], newcomers), do: [cover | merge_in(rest, order(newcomers))]

  defp merge_in(rest, []), do: rest
  defp merge_in([], newcomers), do: newcomers

  defp merge_in([file | rest] = base, [new | newcomers] = all) do
    if sort_key(new) < sort_key(file),
      do: [new | merge_in(base, newcomers)],
      else: [file | merge_in(rest, all)]
  end

  defp check_count(files) when length(files) < @min_files, do: {:error, :too_few}
  defp check_count(files) when length(files) > @max_files, do: {:error, :too_many}
  defp check_count(_files), do: :ok

  defp one_library(files) do
    case files |> Enum.map(& &1.library_uuid) |> Enum.uniq() do
      [library_uuid] -> {:ok, library_uuid}
      _ -> {:error, :mixed_libraries}
    end
  end

  defp check_edit(files, scope) do
    if Enum.all?(files, &Libraries.can?(scope, &1, :edit)), do: :ok, else: {:error, :forbidden}
  end

  defp old_stacks(files) do
    case files |> Enum.map(& &1.stack_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> []
      uuids -> repo().all(from(s in FileStack, where: s.uuid in ^uuids))
    end
  end

  # Of the stacks `old`, the one whose files come first (`order/1`), or nil.
  defp first_stack([], _files), do: nil

  defp first_stack(old, files) do
    files
    |> order()
    |> Enum.find_value(fn file -> Enum.find(old, &(&1.uuid == file.stack_uuid)) end)
  end

  # The new stack's title and description: what the person gave, else those of the old
  # stack whose files come first in the new order.
  defp merged_text(old, files, attrs) do
    inherited =
      case first_stack(old, files) do
        nil -> %{}
        stack -> %{title: stack.title, description: stack.description}
      end

    Map.merge(inherited, text(attrs))
  end

  # What a stack that was added to has none of, from the stacks that came along.
  defp fill_text(stack, old, newcomers) do
    missing =
      for {key, value} <- merged_text(old, newcomers, %{}),
          value not in [nil, ""],
          Map.get(stack, key) in [nil, ""],
          into: %{},
          do: {key, value}

    if missing != %{}, do: stack |> FileStack.changeset(missing) |> repo().update!()
  end

  # The title and description given; one left out or nil is not given (a blank one is,
  # and clears it).
  defp text(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.take(["title", "description"])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
  end

  defp insert_stack(library_uuid, scope, text) do
    %FileStack{}
    |> FileStack.changeset(
      Map.merge(text, %{library_uuid: library_uuid, created_by_uuid: Scope.user_uuid(scope)})
    )
    |> repo().insert()
  end

  defp place(files, stack_uuid) do
    files
    |> Enum.with_index()
    |> Enum.each(fn {file, position} ->
      from(f in StorageFile, where: f.uuid == ^file.uuid)
      |> repo().update_all(set: [stack_uuid: stack_uuid, stack_position: position])
    end)
  end

  defp unplace(file_uuids) do
    from(f in StorageFile, where: f.uuid in ^file_uuids)
    |> repo().update_all(set: [stack_uuid: nil, stack_position: nil])
  end

  defp dissolve(stack_uuid) do
    from(f in StorageFile, where: f.stack_uuid == ^stack_uuid)
    |> repo().update_all(set: [stack_uuid: nil, stack_position: nil])

    delete_stacks([stack_uuid])
  end

  defp delete_stacks([]), do: :ok

  defp delete_stacks(uuids) do
    repo().delete_all(from(s in FileStack, where: s.uuid in ^uuids))
    :ok
  end

  defp touch(stack_uuid) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(s in FileStack, where: s.uuid == ^stack_uuid)
    |> repo().update_all(set: [updated_at: now])

    get(stack_uuid)
  end

  defp members_for_update(stack_uuid) do
    case Ecto.UUID.cast(stack_uuid) do
      {:ok, uuid} ->
        from(f in StorageFile,
          where: f.stack_uuid == ^uuid,
          order_by: [asc: f.stack_position, asc: f.uuid],
          lock: "FOR UPDATE"
        )
        |> repo().all()

      :error ->
        []
    end
  end

  # After the transaction (each returns `{result, changed file uuids}`): say which files
  # changed, then answer with the result.
  defp announce({:ok, {result, file_uuids}}) do
    Storage.broadcast_files_changed(file_uuids)
    {:ok, result}
  end

  defp announce({:error, _reason} = error), do: error

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
