defmodule PhoenixKit.Modules.Storage.Libraries do
  @moduledoc """
  Storage libraries: partitions of the file store (V202).

  Every stored file, media folder and folder link belongs to exactly one
  library (`library_uuid`). V202 put everything that existed into one system
  library, **Media**, under a fixed uuid (`media_uuid/0`), and made Media the
  column default — so a writer that names no library, in core or in any
  module, keeps landing there, and an install with a single library behaves
  exactly as it did before libraries existed.

  More system libraries can be created by an admin (`create_system_library/1`).
  Each keeps its own folders (folder names are unique per library and
  parent) and gives the files stored in it an object-key prefix of its own
  (`key_prefix`).

  ## User libraries (V203)

  When the install turns them on (`user_libraries_enabled?/0`), a user with
  the `"storage"` permission uses the libraries they own or are a member of
  (`list_user_libraries/1`), and one with `"storage.create_library"` creates
  them (`create_user_library/2`, up to `user_library_limit/0`). A trashed
  one can be restored by its owner until it is purged (`restore_library/2`). A user
  library is `private` and has an owner and members
  (`PhoenixKit.Modules.Storage.LibraryMember`: manager, contributor,
  viewer; `allows?/2` says who does what). Trashing one frees its name at
  once and purges it, bytes included, after the trash retention period;
  deleting a user trashes the libraries they own first
  (`trash_owned_libraries/1`).

  Dedup is one copy per uploader per library: the same person may keep the
  same bytes in Media and in a library of their own
  (`Storage.calculate_user_file_checksum/3`).

  Per-library storage (profiles, variant sets, user-owned buckets) is a
  later phase of `dev_docs/plans/2026-09-22-storage-libraries.md`.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, Library, LibraryMember, Profiles, VariantSets}
  alias PhoenixKit.Modules.Storage.Providers.S3
  alias PhoenixKit.Modules.Storage.Workers.PurgeLibraryJob
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.{Scope, User}

  @media_uuid "00000000-0000-7000-8000-000000000001"

  @typedoc "A library with what it holds (`list_system_libraries_with_stats/0`)."
  @type stats :: %{
          library: Library.t(),
          files: non_neg_integer(),
          bytes: non_neg_integer(),
          folders: non_neg_integer(),
          holds: boolean()
        }

  @typedoc "What someone is to a library: its owner, a member's role, or nothing."
  @type role :: :owner | :manager | :contributor | :viewer | nil

  @doc """
  The uuid of Media, the default system library every existing file, folder
  and link was put into by V202, and the column default for new ones. Fixed
  on every install.
  """
  @spec media_uuid() :: String.t()
  def media_uuid, do: @media_uuid

  @doc "Whether `uuid` is Media's."
  @spec media?(term()) :: boolean()
  def media?(uuid), do: to_string(uuid) == @media_uuid

  @doc "A library by uuid, or nil (also for anything that is not a uuid)."
  @spec get_library(term()) :: Library.t() | nil
  def get_library(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(Library, uuid)
      :error -> nil
    end
  end

  @doc """
  The live system libraries, the default (Media) first, then by name.
  """
  @spec list_system_libraries() :: [Library.t()]
  def list_system_libraries do
    from(l in Library,
      where: l.kind == "system" and is_nil(l.trashed_at),
      order_by: [desc: l.is_default, asc: fragment("lower(?)", l.name)]
    )
    |> repo().all()
  end

  @doc """
  `list_system_libraries/0` with what each one holds: `files` (live,
  visible files — not trashed, not system-managed tiles or edit backups),
  `bytes` (their total size), `folders` (live folders) and `holds` (any
  file or folder at all, trash and system-managed rows included — what
  `delete_library/1` refuses). The live counts and `holds` are separate
  queries, whatever the number of libraries.
  """
  @spec list_system_libraries_with_stats() :: [stats()]
  def list_system_libraries_with_stats, do: with_stats(list_system_libraries())

  defp with_stats(libraries) do
    uuids = Enum.map(libraries, & &1.uuid)

    files =
      from(f in StorageFile,
        where: f.library_uuid in ^uuids and f.system_managed == false and f.status != "trashed",
        group_by: f.library_uuid,
        select: {f.library_uuid, {count(f.uuid), coalesce(sum(f.size), 0)}}
      )
      |> repo().all()
      |> Map.new()

    folders =
      from(f in Folder,
        where: f.library_uuid in ^uuids and is_nil(f.trashed_at),
        group_by: f.library_uuid,
        select: {f.library_uuid, count(f.uuid)}
      )
      |> repo().all()
      |> Map.new()

    held = libraries_holding(uuids)

    Enum.map(libraries, fn library ->
      {count, bytes} = Map.get(files, library.uuid, {0, 0})

      %{
        library: library,
        files: count,
        bytes: to_integer(bytes),
        folders: Map.get(folders, library.uuid, 0),
        holds: library.uuid in held
      }
    end)
  end

  # Libraries that still have a row `delete_library/1` will refuse on.
  # The live counts above hide trash and system-managed children, which
  # would otherwise offer Delete on a library the database will not drop.
  defp libraries_holding([]), do: []

  defp libraries_holding(uuids) do
    file_uuids =
      from(f in StorageFile,
        where: f.library_uuid in ^uuids,
        group_by: f.library_uuid,
        select: f.library_uuid
      )
      |> repo().all()

    folder_uuids =
      from(f in Folder,
        where: f.library_uuid in ^uuids,
        group_by: f.library_uuid,
        select: f.library_uuid
      )
      |> repo().all()

    Enum.uniq(file_uuids ++ folder_uuids)
  end

  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(_), do: 0

  @doc """
  `list_system_libraries_with_stats/0` for the one live system library with this
  uuid (what a URL-supplied id is checked against), or nil.
  """
  @spec get_system_library_with_stats(term()) :: stats() | nil
  def get_system_library_with_stats(uuid) do
    case get_system_library(uuid) do
      nil -> nil
      library -> library |> List.wrap() |> with_stats() |> hd()
    end
  end

  @doc """
  The live system library with this uuid, or nil — what a URL-supplied
  library id is checked against before anything is listed or stored in it.
  """
  @spec get_system_library(term()) :: Library.t() | nil
  def get_system_library(uuid) do
    case get_library(uuid) do
      %Library{kind: "system", trashed_at: nil} = library -> library
      _ -> nil
    end
  end

  @doc """
  The live system library whose URL slug is `slug`, or nil. The default
  library has no slug (it is the bare `/admin/media`).
  """
  @spec get_system_library_by_slug(term()) :: Library.t() | nil
  def get_system_library_by_slug(slug) when is_binary(slug) do
    repo().one(
      from(l in Library,
        where: l.kind == "system" and is_nil(l.trashed_at) and l.slug == ^slug
      )
    )
  end

  def get_system_library_by_slug(_slug), do: nil

  @doc """
  Creates a system library. `attrs` takes a `"name"` (or `:name`). The URL
  slug comes from the name (`"Brand Assets"` → `"brand-assets"`, then
  `"brand-assets-2"` … while one is taken) and the object-key prefix is
  generated, unless either is given.
  """
  @spec create_system_library(map(), keyword()) ::
          {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def create_system_library(attrs, opts \\ []) do
    Audit.transaction(fn -> do_create_system_library(attrs, opts) end)
  end

  defp do_create_system_library(attrs, opts) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    attrs = Map.put_new_lazy(attrs, "key_prefix", &generate_key_prefix/0)

    with {:ok, storage} <- creation_storage(attrs) do
      case attrs do
        %{"slug" => _} ->
          insert_system_library(attrs, storage)

        _ ->
          insert_with_free_slug(
            attrs,
            Library.slugify(to_string(attrs["name"] || "")),
            1,
            &insert_system_library(&1, storage)
          )
      end
      |> tap(fn
        {:ok, library} ->
          audit_library("storage.library.created", library, opts, %{
            "name" => library.name,
            "profile" => Profiles.profile_name(Profiles.profile_uuid_for(library)),
            "variant_set" => VariantSets.set_name(VariantSets.set_uuid_for(library))
          })

        _error ->
          :ok
      end)
    end
  end

  # Where a new library keeps its bytes and which sizes it gets, chosen once
  # here and not changed from the admin afterwards. Blank or the Default's uuid
  # is the Default (stored as nil); anything else must be a site profile and an
  # existing set, or the create is refused like any bad field.
  defp creation_storage(attrs) do
    profile = blank_to_nil(attrs["storage_profile_uuid"])
    set = blank_to_nil(attrs["variant_set_uuid"])

    cond do
      profile && not site_profile?(profile) ->
        {:error, storage_error(attrs, :storage_profile_uuid, "is not a storage profile")}

      set && is_nil(VariantSets.get_variant_set(set)) ->
        {:error, storage_error(attrs, :variant_set_uuid, "is not a variant set")}

      true ->
        {:ok,
         [
           storage_profile_uuid: profile && not Profiles.default?(profile) && profile,
           variant_set_uuid: set && not VariantSets.default?(set) && set
         ]
         |> Enum.map(fn {key, value} -> {key, value || nil} end)}
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp site_profile?(uuid) do
    match?(%{owner_uuid: nil}, Profiles.get_profile(uuid))
  end

  defp storage_error(attrs, field, message) do
    %Library{}
    |> Library.create_system_changeset(attrs)
    |> Ecto.Changeset.add_error(field, message)
  end

  # The site's libraries are in the history; a user's library is theirs and private.
  defp audit_library(action, %Library{kind: "system"} = library, opts, metadata) do
    Audit.log(action, "storage_library", library.uuid, opts, metadata)
    :ok
  end

  defp audit_library(_action, _library, _opts, _metadata), do: :ok

  # Tries `base`, `base-2`, `base-3` … until the slug is free. Any other
  # error (a taken name, a blank one) is returned as it is.
  defp insert_with_free_slug(attrs, base, n, insert) do
    slug = if n == 1, do: base, else: "#{base}-#{n}"

    case insert.(Map.put(attrs, "slug", slug)) do
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :slug) and not name_error?(changeset) and n < 100,
          do: insert_with_free_slug(attrs, base, n + 1, insert),
          else: {:error, changeset}

      result ->
        result
    end
  end

  defp name_error?(%Ecto.Changeset{errors: errors}), do: Keyword.has_key?(errors, :name)

  defp insert_system_library(attrs, storage) do
    %Library{}
    |> Library.create_system_changeset(attrs)
    |> Ecto.Changeset.change(storage)
    |> repo().insert(mode: :savepoint)
  end

  @doc "Renames a library."
  @spec rename_library(Library.t(), String.t(), keyword()) ::
          {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def rename_library(%Library{} = library, name, opts \\ []) do
    Audit.change(library, &do_rename_library(&1, name, opts))
  end

  defp do_rename_library(library, name, opts) do
    library
    |> Library.rename_changeset(%{name: name})
    |> repo().update()
    |> tap(fn
      {:ok, renamed} when renamed.name != library.name ->
        audit_library("storage.library.renamed", renamed, opts, %{
          "name" => renamed.name,
          PhoenixKit.Activity.changes_key() => %{
            "name" => %{"from" => library.name, "to" => renamed.name}
          }
        })

      _result ->
        :ok
    end)
  end

  @doc """
  Deletes a library that holds nothing. The default library is never
  deleted, and a library that still has a file or a folder — trashed ones
  included — is refused (`:not_empty`); the database refuses it too.
  """
  @spec delete_library(Library.t(), keyword()) ::
          {:ok, Library.t()} | {:error, :default | :not_empty}
  def delete_library(library, opts \\ [])
  def delete_library(%Library{is_default: true}, _opts), do: {:error, :default}

  def delete_library(%Library{} = library, opts) do
    Audit.change(library, &do_delete_library(&1, opts))
  end

  defp do_delete_library(%Library{is_default: true}, _opts), do: {:error, :default}

  defp do_delete_library(%Library{uuid: uuid} = library, opts) do
    holds? =
      repo().exists?(from(f in StorageFile, where: f.library_uuid == ^uuid)) or
        repo().exists?(from(f in Folder, where: f.library_uuid == ^uuid))

    if holds? do
      {:error, :not_empty}
    else
      case repo().delete(library) do
        {:ok, deleted} ->
          audit_library("storage.library.deleted", deleted, opts, %{"name" => deleted.name})
          {:ok, deleted}

        {:error, _changeset} ->
          {:error, :not_empty}
      end
    end
  rescue
    Ecto.ConstraintError -> {:error, :not_empty}
  end

  @doc """
  Whether a library is a system library. Media always is; anything else is
  read. A missing library is not.
  """
  @spec system_library?(term()) :: boolean()
  def system_library?(uuid) do
    media?(uuid) or match?(%Library{kind: "system"}, get_library(uuid))
  end

  @doc """
  Whether files in a library are private (`visibility: "private"`, every
  user library): their URLs carry a time-window token and are never
  answered with a redirect to a public object URL. Media is answered
  without a query; anything that is not a library is not private.
  """
  @spec private?(term()) :: boolean()
  def private?(nil), do: false

  def private?(uuid) do
    if media?(uuid) do
      false
    else
      case Ecto.UUID.cast(uuid) do
        {:ok, uuid} ->
          repo().exists?(from(l in Library, where: l.uuid == ^uuid and l.visibility == "private"))

        :error ->
          false
      end
    end
  end

  @doc """
  Which of `library_uuids` are private, in one query — for a page that
  builds URLs for many files at once.
  """
  @spec private_among([term()]) :: [String.t()]
  def private_among(library_uuids) do
    uuids =
      library_uuids
      |> Enum.reject(&(is_nil(&1) or media?(&1)))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if uuids == [] do
      []
    else
      from(l in Library,
        where: l.uuid in ^uuids and l.visibility == "private",
        select: l.uuid
      )
      |> repo().all()
      |> Enum.map(&to_string/1)
    end
  end

  # ---------------------------------------------------------------------------
  # Per-library settings
  #
  # A library's `settings` is a JSON map, so a setting that belongs to one
  # library needs no column. The keys are listed here and nowhere else: a new
  # one is a line in `@settings`, and nothing outside this module spells the
  # string. `nil` is "not set": the library follows the site-wide default of
  # whatever the setting is.
  #
  # `purging` lives in the same map but is the purge job's own marker, not a
  # setting: it is not listed, so `put_setting/3` refuses it.
  # ---------------------------------------------------------------------------

  @settings %{annotated_thumbnails: {"annotated_thumbnails", :boolean}}

  @typedoc "A per-library setting."
  @type setting :: :annotated_thumbnails

  @doc """
  A library's own value of `key`, or nil when it has none and follows the
  site-wide default. Takes a library or a library uuid (nil is Media).
  """
  @spec setting(Library.t() | term(), setting()) :: term()
  def setting(%Library{settings: settings}, key), do: stored(settings, key)
  def setting(nil, key), do: setting(@media_uuid, key)

  def setting(uuid, key) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Library{} = library <- repo().get(Library, uuid) do
      setting(library, key)
    else
      _ -> nil
    end
  end

  @doc """
  The own value of `key` of each library in `library_uuids`, in one query — for
  a page that decides for many files at once. A library with none is missing
  from the map; nil stands for Media.
  """
  @spec setting_among([term()], setting()) :: %{String.t() => term()}
  def setting_among(library_uuids, key) do
    uuids =
      library_uuids
      |> Enum.map(&(&1 || @media_uuid))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if uuids == [] do
      %{}
    else
      from(l in Library, where: l.uuid in ^uuids, select: {l.uuid, l.settings})
      |> repo().all()
      |> Enum.flat_map(fn {uuid, settings} ->
        case stored(settings, key) do
          nil -> []
          value -> [{to_string(uuid), value}]
        end
      end)
      |> Map.new()
    end
  end

  @doc """
  Sets a library's own value of `key`; nil removes it, so the library follows
  the site-wide default again. Only the key changes (a concurrent change to
  another one is not lost), and a value of the wrong type is refused.
  """
  @spec put_setting(Library.t(), setting(), term(), keyword()) ::
          {:ok, Library.t()} | {:error, :unknown_setting | :invalid_value | :not_found}
  def put_setting(%Library{} = library, key, value, opts \\ []) do
    Audit.change(library, &do_put_setting(&1, key, value, opts))
  end

  defp do_put_setting(%Library{uuid: uuid} = library, key, value, opts) do
    with {name, type} when is_binary(name) <- Map.get(@settings, key, :unknown),
         :ok <- check_type(type, value) do
      {count, _} =
        if is_nil(value) do
          from(l in Library,
            where: l.uuid == ^uuid,
            update: [set: [settings: fragment("? - ?::text", l.settings, ^name)]]
          )
          |> repo().update_all([])
        else
          # A map, not an encoded string: the driver encodes a jsonb parameter
          # itself, and a string would become a JSON string scalar.
          change = %{name => value}

          from(l in Library,
            where: l.uuid == ^uuid,
            update: [set: [settings: fragment("? || ?", l.settings, type(^change, :map))]]
          )
          |> repo().update_all([])
        end

      if count == 1 do
        updated = get_library(uuid)
        audit_setting(library, updated, key, opts)
        {:ok, updated}
      else
        {:error, :not_found}
      end
    else
      :unknown -> {:error, :unknown_setting}
      {:error, _reason} = error -> error
    end
  end

  # A setting of a system library moving from one value to another (nil is "follow the
  # site default").
  defp audit_setting(%Library{} = before, %Library{} = updated, key, opts) do
    old = setting(before, key)
    new = setting(updated, key)

    if old != new do
      audit_library("storage.library.setting_changed", updated, opts, %{
        "library" => updated.name,
        PhoenixKit.Activity.changes_key() => %{
          to_string(key) => %{"from" => setting_label(old), "to" => setting_label(new)}
        }
      })
    end

    :ok
  end

  defp setting_label(nil), do: "site default"
  defp setting_label(value), do: value

  defp check_type(_type, nil), do: :ok
  defp check_type(:boolean, value) when is_boolean(value), do: :ok
  defp check_type(_type, _value), do: {:error, :invalid_value}

  defp stored(settings, key) do
    case Map.get(@settings, key) do
      {name, :boolean} ->
        case Map.get(settings || %{}, name) do
          value when is_boolean(value) -> value
          _ -> nil
        end

      nil ->
        nil
    end
  end

  @doc "Whether `file` (anything with a `library_uuid`) is in a private library."
  @spec private_file?(map()) :: boolean()
  def private_file?(%{library_uuid: library_uuid}), do: private?(library_uuid)
  def private_file?(_file), do: false

  @doc """
  Drops rows whose library is private.

  The file or folder is the query's first binding. Site listings
  (`/admin/media`, the media pickers, orphan cleanup) use this so a user
  library is not mixed into the site's media; pass that library's uuid to
  read it. A private library's files are not orphans: nothing in the site
  references them, and treating them as unreferenced would delete them.
  """
  @spec exclude_private(Ecto.Query.t()) :: Ecto.Query.t()
  def exclude_private(query) do
    private = from(l in Library, where: l.visibility == "private", select: l.uuid)
    where(query, [row], row.library_uuid not in subquery(private))
  end

  @doc """
  Whether `scope` may do `action` to `file`. One predicate for every
  per-file check, so they stop drifting apart:

    * `:read` — the file's info and signed URLs: its uploader, an
      Owner/Admin (`Scope.system_role?/1`), or — for a file in a user
      library — that library's owner or any of its members. Deliberately
      NOT the `"media"` permission: a single permission must not open every
      other user's file metadata (issue #687).
    * `:edit` — change the picture (image editing, annotation burn-in, the
      unedited original): the uploader, an Owner/Admin, a holder of the
      `"media"` permission with `"media.view_all"` when the file is in a system
      library, or the
      owner or a manager of the user library it is in.

  Anything else, and a scope without a user, is refused.
  """
  @spec can?(Scope.t() | nil, map(), :read | :edit) :: boolean()
  def can?(%Scope{} = scope, %{} = file, action) when action in [:read, :edit] do
    library_uuid = Map.get(file, :library_uuid) || @media_uuid

    uploader?(scope, file) or Scope.system_role?(scope) or
      library_grants?(scope, library_uuid, action)
  end

  def can?(_scope, _file, _action), do: false

  defp library_grants?(scope, library_uuid, action) do
    library = if media?(library_uuid), do: :media, else: get_library(library_uuid)
    grants?(scope, library, action)
  end

  # Changing someone else's file in a site library is for a holder of `media` who
  # sees everyone's files (`media.view_all`); a holder of `media` alone changes only
  # their own (the uploader clause of `can?/3`).
  defp grants?(scope, :media, action),
    do:
      action == :edit and Scope.has_module_access?(scope, "media") and
        Scope.can?(scope, "media.view_all")

  defp grants?(scope, %Library{kind: "system"}, action), do: grants?(scope, :media, action)

  defp grants?(scope, %Library{kind: "user", trashed_at: nil} = library, action) do
    role = role(library, Scope.user_uuid(scope))
    if action == :read, do: role != nil, else: role in [:owner, :manager]
  end

  defp grants?(_scope, _library, _action), do: false

  defp uploader?(scope, file) do
    uuid = Scope.user_uuid(scope)
    is_binary(uuid) and to_string(Map.get(file, :user_uuid)) == uuid
  end

  # ============================================================================
  # User libraries (V203)
  # ============================================================================

  @doc """
  Whether user libraries are on for this install (the
  `storage_user_libraries_enabled` setting, off by default). Existing sites
  do not start offering a feature they never planned for.
  """
  @spec user_libraries_enabled?() :: boolean()
  def user_libraries_enabled?,
    do: Settings.get_boolean_setting("storage_user_libraries_enabled", false)

  @doc "How many live libraries one user may own (`storage_user_library_limit`, default 10)."
  @spec user_library_limit() :: non_neg_integer()
  def user_library_limit,
    do: max(Settings.get_integer_setting("storage_user_library_limit", 10), 0)

  @doc """
  Whether `scope` may take part in user libraries at all — use the ones they
  own or are a member of, at `/admin/libraries`: user libraries are on, and
  the scope holds the `"storage"` permission.
  """
  @spec may_use_libraries?(Scope.t() | nil) :: boolean()
  def may_use_libraries?(%Scope{} = scope) do
    user_libraries_enabled?() and Scope.has_module_access?(scope, "storage")
  end

  def may_use_libraries?(_scope), do: false

  @doc """
  Whether Media (`/admin/media`) is where `scope` browses their user libraries:
  they hold `media` and are not an Owner/Admin. Media's switcher then lists their
  own and shared libraries beside the site's (`/admin/media/my/<id>`); everyone
  else (only `storage`, or an Owner/Admin who also opens other people's libraries,
  audit-logged) uses `/admin/libraries`.
  """
  @spec browse_in_media?(Scope.t() | nil) :: boolean()
  def browse_in_media?(%Scope{} = scope),
    do: Scope.has_module_access?(scope, "media") and not Scope.system_role?(scope)

  def browse_in_media?(_scope), do: false

  @doc """
  Whether the sidebar lists a separate "Libraries" entry for `scope`: user
  libraries are on for them, and they do not already have them in Media.
  """
  @spec show_libraries_entry?(Scope.t() | nil) :: boolean()
  def show_libraries_entry?(scope), do: may_use_libraries?(scope) and not browse_in_media?(scope)

  @doc """
  The (canonical, unprefixed) path of the page that browses `library` for
  `scope`: Media's for a holder of `media`, `/admin/libraries` otherwise.
  """
  @spec browse_path(Scope.t() | nil, Library.t()) :: String.t()
  def browse_path(scope, %Library{} = library) do
    id = url_id(library, Scope.user_uuid(scope))

    if browse_in_media?(scope),
      do: "/admin/media/my/#{id}",
      else: "/admin/libraries/#{id}"
  end

  @doc "The path of the page that lists `scope`'s libraries (see `browse_path/2`)."
  @spec browse_index_path(Scope.t() | nil) :: String.t()
  def browse_index_path(scope),
    do: if(browse_in_media?(scope), do: "/admin/media", else: "/admin/libraries")

  @doc """
  Whether the site lets users keep a library on their own bucket (the
  `storage_user_buckets_enabled` setting, off by default: the site answers for
  nothing that lands outside its own storage until it says so).
  """
  @spec user_buckets_enabled?() :: boolean()
  def user_buckets_enabled?,
    do: Settings.get_boolean_setting("storage_user_buckets_enabled", false)

  @doc """
  Whether `scope` may put a new library on their own storage:
  `may_create_library?/1`, the site allowing it (`user_buckets_enabled?/0`), the
  `"storage.own_storage"` permission, and the `"integrations"` permission: the
  bucket's keys are a personal connection, which only a holder of it can make.
  """
  @spec may_use_own_storage?(Scope.t() | nil) :: boolean()
  def may_use_own_storage?(%Scope{} = scope) do
    may_create_library?(scope) and user_buckets_enabled?() and
      Scope.can?(scope, "storage.own_storage") and Scope.has_module_access?(scope, "integrations")
  end

  def may_use_own_storage?(_scope), do: false

  @doc """
  Whether `scope` may create user libraries: `may_use_libraries?/1`, and the
  `"storage.create_library"` permission.
  """
  @spec may_create_library?(Scope.t() | nil) :: boolean()
  def may_create_library?(%Scope{} = scope) do
    may_use_libraries?(scope) and Scope.can?(scope, "storage.create_library")
  end

  def may_create_library?(_scope), do: false

  @doc """
  What `user_uuid` is to `library`: `:owner`, a member's role, or nil. A
  trashed library has no one.
  """
  @spec role(Library.t(), term()) :: role()
  def role(%Library{trashed_at: trashed}, _user_uuid) when not is_nil(trashed), do: nil

  def role(%Library{owner_uuid: owner}, user_uuid)
      when is_binary(user_uuid) and not is_nil(owner) and owner == user_uuid,
      do: :owner

  def role(%Library{kind: "user", uuid: uuid}, user_uuid) when is_binary(user_uuid) do
    case repo().one(
           from(m in LibraryMember,
             where: m.library_uuid == ^uuid and m.user_uuid == ^user_uuid,
             select: m.role
           )
         ) do
      nil -> nil
      role -> String.to_existing_atom(role)
    end
  end

  def role(_library, _user_uuid), do: nil

  @doc """
  Whether `role` may do `action` in a user library:

    * `:read` — see its files: everyone
    * `:upload` — add files: owner, manager, contributor
    * `:edit_any` — change or trash anyone's files: owner, manager
    * `:members` — add, change and remove members: owner, manager
    * `:rename` — owner, manager
    * `:own` — trash the library, make it the default: owner only
  """
  @spec allows?(role(), atom()) :: boolean()
  def allows?(nil, _action), do: false
  def allows?(:owner, _action), do: true
  def allows?(_role, :read), do: true
  def allows?(role, :upload), do: role in [:manager, :contributor]
  def allows?(:manager, action) when action in [:edit_any, :members, :rename], do: true
  def allows?(_role, _action), do: false

  @doc """
  The live user libraries `user_uuid` owns or is a member of, with what
  they are to each: the ones they own first (their default first), then
  the rest, by name.
  """
  @spec list_user_libraries(term()) :: [%{library: Library.t(), role: role()}]
  def list_user_libraries(user_uuid) when is_binary(user_uuid) do
    owned =
      from(l in Library,
        where: l.kind == "user" and l.owner_uuid == ^user_uuid and is_nil(l.trashed_at),
        order_by: [desc: l.is_default, asc: fragment("lower(?)", l.name)]
      )
      |> repo().all()
      |> Enum.map(&%{library: &1, role: :owner})

    member =
      from(l in Library,
        join: m in LibraryMember,
        on: m.library_uuid == l.uuid,
        where: m.user_uuid == ^user_uuid and l.kind == "user" and is_nil(l.trashed_at),
        order_by: fragment("lower(?)", l.name),
        select: {l, m.role}
      )
      |> repo().all()
      |> Enum.map(fn {library, role} ->
        %{library: library, role: String.to_existing_atom(role)}
      end)

    owned ++ member
  end

  def list_user_libraries(_user_uuid), do: []

  @doc """
  A live user library `scope` may see, by its uuid or — for one of their
  own — its slug, with what they are to it. Nil otherwise, whatever the
  reason (missing, trashed, not theirs), so a URL gives nothing away.
  """
  @spec get_user_library(Scope.t() | nil, term()) :: %{library: Library.t(), role: role()} | nil
  def get_user_library(%Scope{} = scope, id) when is_binary(id) do
    user_uuid = Scope.user_uuid(scope)

    library =
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          get_library(uuid)

        :error when is_binary(user_uuid) ->
          repo().one(
            from(l in Library,
              where:
                l.kind == "user" and l.owner_uuid == ^user_uuid and l.slug == ^id and
                  is_nil(l.trashed_at)
            )
          )

        :error ->
          nil
      end

    with %Library{kind: "user", trashed_at: nil} <- library,
         role when not is_nil(role) <- role(library, user_uuid) do
      %{library: library, role: role}
    else
      _ -> nil
    end
  end

  def get_user_library(_scope, _id), do: nil

  @doc """
  How a user library is named in a URL for `user_uuid`: its slug when it is
  theirs, its uuid when it is shared with them (slugs are only unique among
  one owner's libraries).
  """
  @spec url_id(Library.t(), term()) :: String.t()
  def url_id(%Library{owner_uuid: owner, slug: slug}, user_uuid)
      when is_binary(slug) and owner == user_uuid,
      do: slug

  def url_id(%Library{uuid: uuid}, _user_uuid), do: to_string(uuid)

  @doc """
  Creates a user library owned by `scope`'s user. `attrs` takes a `"name"` and
  optionally a `"storage"` (below). The first live library a user has becomes
  their default. Refused with `:not_allowed` without `may_create_library?/1`,
  and `:limit_reached` at `user_library_limit/0` live libraries.

  ## Where the library keeps its files

  By default on the site's storage (the Default profile). With `"storage"` a map
  the user chooses their own instead, and **the choice is final**: the library's
  profile can never be changed afterwards (`Profiles.set_library_profile/2`
  refuses it).

      %{"name" => "Photos",
        "storage" => %{
          "mode" => "only",               # or "backup"
          "integration_uuid" => "…",      # one of the user's own connections
          "provider" => "s3",             # s3 | b2 | r2 | tigris
          "bucket_name" => "my-photos",
          "region" => "eu-central-1",     # and/or
          "endpoint" => "https://…"}}

  `"only"` keeps everything in their bucket; `"backup"` keeps the site's
  storage as it is and copies the originals to theirs (see
  `Profiles.create_user_profile/3`). Needs `may_use_own_storage?/1`
  (`{:error, :not_allowed}` otherwise).

  The bucket is probed first, reading, writing and deleting a small object
  (`:probe`, a function of the bucket params, `Storage.test_connection/1` by
  default): a library that could not store anything is not created, and the
  reason is `{:error, {:storage, message}}`. A bucket, profile or library that
  cannot be created undoes the rest. Problems with the bucket fields are
  `{:error, {:storage, %Ecto.Changeset{}}}`.
  """
  @spec create_user_library(Scope.t() | nil, map(), keyword()) ::
          {:ok, Library.t()}
          | {:error,
             :not_allowed
             | :limit_reached
             | :no_site_storage
             | {:storage, String.t() | Ecto.Changeset.t()}
             | Ecto.Changeset.t()}
  def create_user_library(scope, attrs, opts \\ []) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    {storage, attrs} = Map.pop(attrs, "storage")

    with true <- may_create_library?(scope) || {:error, :not_allowed},
         user_uuid when is_binary(user_uuid) <- Scope.user_uuid(scope) || {:error, :not_allowed},
         {:ok, own} <- own_storage_request(scope, user_uuid, storage, opts) do
      repo().transaction(fn ->
        # One creation per user at a time, so two tabs cannot both pass the
        # limit check.
        lock_user(user_uuid)
        owned = count_owned(user_uuid)

        if owned >= user_library_limit() do
          repo().rollback(:limit_reached)
        else
          library = insert_owned(attrs, user_uuid, owned == 0)
          attach_own_storage(library, user_uuid, own)
        end
      end)
    end
  end

  # No `"storage"` (or the site's own): the library stays on the Default.
  defp own_storage_request(_scope, _user_uuid, nil, _opts), do: {:ok, nil}
  defp own_storage_request(_scope, _user_uuid, %{"mode" => "site"}, _opts), do: {:ok, nil}

  defp own_storage_request(scope, user_uuid, %{} = storage, opts) do
    mode = storage["mode"]

    cond do
      not may_use_own_storage?(scope) ->
        {:error, :not_allowed}

      mode not in ["only", "backup"] ->
        {:error, :not_allowed}

      true ->
        params = Map.take(storage, ~w(integration_uuid provider bucket_name region endpoint))
        probe = Keyword.get(opts, :probe, &Storage.test_connection/1)

        case probe_owned(params, user_uuid, probe) do
          :ok -> {:ok, %{mode: String.to_existing_atom(mode), params: params}}
          {:error, message} -> {:error, {:storage, message}}
        end
    end
  end

  defp own_storage_request(_scope, _user_uuid, _storage, _opts), do: {:error, :not_allowed}

  @doc """
  Checks a bucket for `scope`'s user to put a library on (what the wizard's "Test
  the bucket" asks, and what creating the library asks again): they may use their
  own storage at all, the fields pass `Bucket.owned_changeset/4` (an S3-protocol
  provider, their own connection, a host the server may reach), and a small
  object can be written, read back and deleted.

  Returns `:ok`, `{:error, :not_allowed}`, `{:error, message}` from the bucket, or
  `{:error, %Ecto.Changeset{}}` for the fields. `:probe` replaces the network
  check (a function of the bucket params), for tests.
  """
  @spec probe_own_storage(Scope.t() | nil, map(), keyword()) ::
          :ok | {:error, :not_allowed | String.t() | Ecto.Changeset.t()}
  def probe_own_storage(scope, params, opts \\ []) do
    with true <- may_use_own_storage?(scope) || {:error, :not_allowed},
         user_uuid when is_binary(user_uuid) <- Scope.user_uuid(scope) || {:error, :not_allowed} do
      fields = Map.take(params, ~w(integration_uuid provider bucket_name region endpoint))
      probe_owned(fields, user_uuid, Keyword.get(opts, :probe, &Storage.test_connection/1))
    end
  end

  # The probe runs before anything is written, as the user the bucket would
  # belong to: their connection, the strict endpoint policy. A bucket that does
  # not even pass the changeset is not probed.
  defp probe_owned(params, user_uuid, probe) do
    # The bucket gets the library's name when it is created; the probe only
    # needs one to be valid.
    params = Map.put(params, "name", "probe")

    changeset =
      Storage.Bucket.owned_changeset(%Storage.Bucket{}, params, user_uuid,
        connection_owned?: &Storage.owns_connection?(user_uuid, &1)
      )

    if changeset.valid?,
      do: probe.(Map.put(params, "owner_uuid", user_uuid)),
      else: {:error, changeset}
  end

  # Inside the creation transaction: the bucket, its profile, then the library
  # pointed at it. Any failure rolls the whole library back.
  defp attach_own_storage(library, _user_uuid, nil), do: library

  defp attach_own_storage(library, user_uuid, %{mode: mode, params: params}) do
    attrs = Map.put(params, "name", library.name)

    with {:ok, bucket} <- Storage.create_owned_bucket(user_uuid, attrs),
         {:ok, profile} <- Profiles.create_user_profile(user_uuid, bucket, mode),
         {:ok, library} <- Profiles.assign_user_profile(library, profile) do
      library
    else
      {:error, %Ecto.Changeset{} = changeset} -> repo().rollback({:storage, changeset})
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp insert_owned(attrs, user_uuid, first?) do
    attrs =
      attrs
      |> Map.put("owner_uuid", user_uuid)
      |> Map.put("is_default", first?)
      |> Map.put_new_lazy("key_prefix", &generate_key_prefix/0)

    base = Library.slugify(to_string(attrs["name"] || ""))

    case insert_with_free_slug(attrs, base, 1, &insert_user_library/1) do
      {:ok, library} -> library
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  defp insert_user_library(attrs) do
    # A savepoint per attempt: a taken slug aborts only its own insert.
    repo().transaction(fn ->
      case %Library{} |> Library.create_user_changeset(attrs) |> repo().insert() do
        {:ok, library} -> library
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  defp lock_user(user_uuid) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "phoenix_kit_user_libraries:" <> user_uuid
    ])
  end

  defp count_owned(user_uuid) do
    repo().aggregate(
      from(l in Library,
        where: l.kind == "user" and l.owner_uuid == ^user_uuid and is_nil(l.trashed_at)
      ),
      :count
    )
  end

  @doc "Renames a user library, for its owner or a manager."
  @spec rename_user_library(Scope.t() | nil, Library.t(), String.t()) ::
          {:ok, Library.t()} | {:error, :not_allowed | Ecto.Changeset.t()}
  def rename_user_library(scope, %Library{kind: "user"} = library, name) do
    if allows?(scope_role(scope, library), :rename),
      do: rename_library(library, name),
      else: {:error, :not_allowed}
  end

  def rename_user_library(_scope, _library, _name), do: {:error, :not_allowed}

  @doc "Makes a user library its owner's default, for the owner."
  @spec set_default_library(Scope.t() | nil, Library.t()) ::
          {:ok, Library.t()} | {:error, :not_allowed}
  def set_default_library(scope, %Library{kind: "user", owner_uuid: owner} = library) do
    if scope_role(scope, library) == :owner do
      repo().transaction(fn ->
        repo().update_all(
          from(l in Library, where: l.kind == "user" and l.owner_uuid == ^owner and l.is_default),
          set: [is_default: false]
        )

        library |> Ecto.Changeset.change(is_default: true) |> repo().update!()
      end)
    else
      {:error, :not_allowed}
    end
  end

  def set_default_library(_scope, _library), do: {:error, :not_allowed}

  @doc """
  The user's default library, or nil (they have none yet).
  """
  @spec default_user_library(term()) :: Library.t() | nil
  def default_user_library(user_uuid) when is_binary(user_uuid) do
    repo().one(
      from(l in Library,
        where:
          l.kind == "user" and l.owner_uuid == ^user_uuid and l.is_default and
            is_nil(l.trashed_at)
      )
    )
  end

  def default_user_library(_user_uuid), do: nil

  @doc """
  Trashes a user library, for its owner. Its members lose it at once; its
  files are purged, bytes included, after the trash retention period
  (`Storage.trash_retention_days/0`). Its name and URL are free again right
  away. When it was the default, the owner's next library by name becomes
  the default.
  """
  @spec trash_library(Scope.t() | nil, Library.t()) ::
          {:ok, Library.t()} | {:error, :not_allowed}
  def trash_library(scope, %Library{kind: "user"} = library) do
    if scope_role(scope, library) == :owner,
      do: do_trash(library),
      else: {:error, :not_allowed}
  end

  def trash_library(_scope, _library), do: {:error, :not_allowed}

  defp do_trash(%Library{} = library) do
    repo().transaction(fn ->
      trashed =
        library
        # The slug and the default flag are unique per owner among ALL rows,
        # trashed ones included; a trashed library holds neither, so a new
        # one can take them and the owner's deletion can null `owner_uuid`
        # without colliding with a system library's.
        |> Ecto.Changeset.change(
          trashed_at: DateTime.truncate(DateTime.utc_now(), :second),
          slug: nil,
          is_default: false
        )
        |> repo().update!()

      if library.is_default and library.owner_uuid, do: promote_default(library.owner_uuid)
      trashed
    end)
  end

  defp promote_default(owner_uuid) do
    case repo().one(
           from(l in Library,
             where: l.kind == "user" and l.owner_uuid == ^owner_uuid and is_nil(l.trashed_at),
             order_by: fragment("lower(?)", l.name),
             limit: 1
           )
         ) do
      nil -> :ok
      next -> next |> Ecto.Changeset.change(is_default: true) |> repo().update!()
    end
  end

  @doc """
  The user libraries `user_uuid` owns that are in the trash and not purged
  yet, newest first.
  """
  @spec list_trashed_user_libraries(term()) :: [Library.t()]
  def list_trashed_user_libraries(user_uuid) when is_binary(user_uuid) do
    from(l in Library,
      where: l.kind == "user" and l.owner_uuid == ^user_uuid and not is_nil(l.trashed_at),
      order_by: [desc: l.trashed_at]
    )
    |> repo().all()
  end

  def list_trashed_user_libraries(_user_uuid), do: []

  @doc """
  Takes a trashed user library out of the trash, for its owner, until it is
  purged. It gets a URL slug again (the old one may have been taken), and
  becomes the default when the owner has none. A live library of the owner
  that has taken its name meanwhile refuses it (`{:error, changeset}`).
  """
  @spec restore_library(Scope.t() | nil, Library.t()) ::
          {:ok, Library.t()} | {:error, :not_allowed | :limit_reached | Ecto.Changeset.t()}
  def restore_library(%Scope{} = scope, %Library{kind: "user", trashed_at: trashed} = library)
      when not is_nil(trashed) do
    user_uuid = Scope.user_uuid(scope)

    if is_binary(user_uuid) and library.owner_uuid == user_uuid do
      repo().transaction(fn ->
        lock_user(user_uuid)
        current = locked_library(library.uuid)

        cond do
          # Purged, being purged, or restored meanwhile.
          is_nil(current) or is_nil(current.trashed_at) or
              Map.get(current.settings || %{}, "purging") == true ->
            repo().rollback(:not_allowed)

          count_owned(user_uuid) >= user_library_limit() ->
            repo().rollback(:limit_reached)

          true ->
            restore_owned(current, user_uuid)
        end
      end)
    else
      {:error, :not_allowed}
    end
  end

  def restore_library(_scope, _library), do: {:error, :not_allowed}

  defp locked_library(uuid),
    do: repo().one(from(l in Library, where: l.uuid == ^uuid, lock: "FOR UPDATE"))

  defp restore_owned(library, user_uuid) do
    default? = is_nil(default_user_library(user_uuid))

    case restore_with_free_slug(library, Library.slugify(library.name), 1, default?) do
      {:ok, restored} -> restored
      {:error, changeset} -> repo().rollback(changeset)
    end
  end

  defp restore_with_free_slug(library, base, n, default?) do
    slug = if n == 1, do: base, else: "#{base}-#{n}"

    result =
      repo().transaction(fn ->
        library
        |> Ecto.Changeset.change(trashed_at: nil, slug: slug, is_default: default?)
        |> Ecto.Changeset.unique_constraint(:slug,
          name: :phoenix_kit_storage_libraries_owner_slug_index
        )
        |> Ecto.Changeset.unique_constraint(:name,
          name: :phoenix_kit_storage_libraries_owner_name_index,
          message: "is already the name of another library"
        )
        |> repo().update()
        |> case do
          {:ok, restored} -> restored
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :slug) and not Keyword.has_key?(errors, :name) and n < 100,
          do: restore_with_free_slug(library, base, n + 1, default?),
          else: {:error, changeset}

      other ->
        other
    end
  end

  @doc """
  Trashes every live library `user_uuid` owns and queues their purge — the
  step `Auth.delete_user/2` takes before deleting the user. The database
  refuses to delete a user whose live library still names them (V203), so
  this cannot be skipped. Returns how many were trashed.
  """
  @spec trash_owned_libraries(term()) :: {:ok, non_neg_integer()}
  def trash_owned_libraries(user_uuid) when is_binary(user_uuid) do
    # All at once: no default is passed on, since every one of them goes.
    {_count, uuids} =
      from(l in Library,
        where: l.kind == "user" and l.owner_uuid == ^user_uuid and is_nil(l.trashed_at),
        select: l.uuid
      )
      |> repo().update_all(
        set: [
          trashed_at: DateTime.truncate(DateTime.utc_now(), :second),
          slug: nil,
          is_default: false
        ]
      )

    Enum.each(uuids, &enqueue_purge/1)
    {:ok, length(uuids)}
  end

  def trash_owned_libraries(_user_uuid), do: {:ok, 0}

  # ----------------------------------------------------------------------------
  # Members
  # ----------------------------------------------------------------------------

  @doc "A user library's members with their users, by email."
  @spec list_members(Library.t()) :: [LibraryMember.t()]
  def list_members(%Library{uuid: uuid}) do
    from(m in LibraryMember,
      join: u in assoc(m, :user),
      where: m.library_uuid == ^uuid,
      order_by: u.email,
      preload: [user: u]
    )
    |> repo().all()
  end

  @doc """
  Adds the user with `email` to a user library as `role`, for its owner or
  a manager. `:no_such_user` when nobody has that email, `:owner` when it is
  the owner's own.
  """
  @spec add_member(Scope.t() | nil, Library.t(), String.t(), String.t()) ::
          {:ok, LibraryMember.t()}
          | {:error, :not_allowed | :no_such_user | :owner | Ecto.Changeset.t()}
  def add_member(scope, %Library{kind: "user"} = library, email, role) when is_binary(email) do
    with true <- allows?(scope_role(scope, library), :members) || {:error, :not_allowed},
         %User{} = user <-
           repo().one(from(u in User, where: u.email == ^String.trim(email))) ||
             {:error, :no_such_user},
         true <- user.uuid != library.owner_uuid || {:error, :owner} do
      %LibraryMember{}
      |> LibraryMember.changeset(%{library_uuid: library.uuid, user_uuid: user.uuid, role: role})
      |> repo().insert()
    end
  end

  def add_member(_scope, _library, _email, _role), do: {:error, :not_allowed}

  @doc "Changes a member's role, for the library's owner or a manager."
  @spec update_member_role(Scope.t() | nil, Library.t(), term(), String.t()) ::
          {:ok, LibraryMember.t()} | {:error, :not_allowed | :not_found | Ecto.Changeset.t()}
  def update_member_role(scope, %Library{kind: "user"} = library, user_uuid, role) do
    with true <- allows?(scope_role(scope, library), :members) || {:error, :not_allowed},
         %LibraryMember{} = member <- get_member(library, user_uuid) || {:error, :not_found} do
      member |> LibraryMember.role_changeset(%{role: role}) |> repo().update()
    end
  end

  def update_member_role(_scope, _library, _user_uuid, _role), do: {:error, :not_allowed}

  @doc """
  Removes a member, for the library's owner or a manager, or the member
  themselves (leaving).
  """
  @spec remove_member(Scope.t() | nil, Library.t(), term()) ::
          :ok | {:error, :not_allowed | :not_found}
  def remove_member(scope, %Library{kind: "user"} = library, user_uuid) do
    self? = Scope.user_uuid(scope) == to_string(user_uuid)

    with true <-
           (self? or allows?(scope_role(scope, library), :members)) || {:error, :not_allowed},
         %LibraryMember{} = member <- get_member(library, user_uuid) || {:error, :not_found} do
      repo().delete!(member)
      :ok
    end
  end

  def remove_member(_scope, _library, _user_uuid), do: {:error, :not_allowed}

  defp get_member(%Library{uuid: uuid}, user_uuid) do
    case Ecto.UUID.cast(user_uuid) do
      {:ok, user_uuid} ->
        repo().get_by(LibraryMember, library_uuid: uuid, user_uuid: user_uuid)

      :error ->
        nil
    end
  end

  defp scope_role(%Scope{} = scope, library), do: role(library, Scope.user_uuid(scope))
  defp scope_role(_scope, _library), do: nil

  # ----------------------------------------------------------------------------
  # Admin metadata and purging
  # ----------------------------------------------------------------------------

  @doc """
  Every user library, trashed ones included, with its owner, member count
  and what it holds — what `/admin/storage/libraries` lists. Metadata only:
  nothing here opens a library's files.
  """
  @spec list_user_libraries_for_admin() :: [map()]
  def list_user_libraries_for_admin do
    libraries =
      from(l in Library,
        where: l.kind == "user",
        order_by: [asc: not is_nil(l.trashed_at), asc: fragment("lower(?)", l.name)],
        preload: [:owner]
      )
      |> repo().all()

    uuids = Enum.map(libraries, & &1.uuid)

    members =
      from(m in LibraryMember,
        where: m.library_uuid in ^uuids,
        group_by: m.library_uuid,
        select: {m.library_uuid, count(m.user_uuid)}
      )
      |> repo().all()
      |> Map.new()

    own_storage = Profiles.user_storage_for(libraries)

    libraries
    |> with_stats()
    |> Enum.map(fn row ->
      row
      |> Map.put(:members, Map.get(members, row.library.uuid, 0))
      |> Map.put(:own_storage, Map.get(own_storage, to_string(row.library.uuid)))
    end)
  end

  @doc """
  Purges a trashed library: every file in it (trashed and system-managed
  ones included) through the normal delete path, which deletes the bytes
  no other file still names; then its folders; then the library row (its
  members go with it). A live library is refused.

  A library on a user's own storage (V206) is purged more carefully: each file's
  objects are deleted BEFORE its rows, and a file whose objects could not be
  deleted is left as it was, along with the library, its profile and the bucket
  row (the record of where the objects are and how to reach them). The purge then
  returns `{:error, :objects_remain}`, so the job is retried, and nothing is
  forgotten that could not be cleaned up. If the user's credentials are gone
  (their account was deleted, taking their connections with it) nothing can be
  deleted from their bucket, and the purge goes on without waiting for it.
  """
  @spec purge_library(Library.t() | term()) ::
          :ok | {:error, :not_trashed | :not_found | :objects_remain}
  def purge_library(%Library{trashed_at: nil}), do: {:error, :not_trashed}

  def purge_library(%Library{uuid: uuid} = library) do
    # Claimed first, in one statement that sees the row as it is now: a
    # restore that committed after the caller loaded `library` makes it
    # live, and the claim then finds nothing to purge. Once claimed, a
    # restore refuses (`restore_library/2` checks the mark under a lock).
    case claim_for_purge(uuid) do
      :claimed -> do_purge(library)
      :not_trashed -> {:error, :not_trashed}
    end
  end

  def purge_library(uuid) do
    case get_library(uuid) do
      nil -> {:error, :not_found}
      library -> purge_library(library)
    end
  end

  defp claim_for_purge(uuid) do
    {count, _} =
      from(l in Library,
        where: l.uuid == ^uuid and not is_nil(l.trashed_at),
        update: [
          set: [settings: fragment("? || jsonb_build_object('purging', true)", l.settings)]
        ]
      )
      |> repo().update_all([])

    if count == 1, do: :claimed, else: :not_trashed
  end

  defp do_purge(%Library{uuid: uuid} = library) do
    confirm? = confirm_objects?(library)

    # Parents first: a parent's delete takes its system-managed children
    # (tiles, edit backups) with it.
    remaining =
      from(f in StorageFile,
        where: f.library_uuid == ^uuid,
        order_by: [asc: not is_nil(f.parent_file_uuid)],
        select: f.uuid
      )
      |> repo().all()
      |> Enum.count(fn file_uuid ->
        case repo().get(StorageFile, file_uuid) do
          nil -> false
          file -> not purge_file(file, confirm?)
        end
      end)

    if remaining > 0 do
      Logger.warning(
        "Storage: #{remaining} file(s) of library #{uuid} kept their objects on the user's own bucket; the purge will be retried"
      )

      {:error, :objects_remain}
    else
      finish_purge(library)
    end
  rescue
    error ->
      Logger.error("Storage: purging library #{uuid} failed: #{Exception.message(error)}")
      reraise error, __STACKTRACE__
  end

  # Whether the purge waits for each file's objects to be confirmed deleted: the
  # library is on a user's own bucket, and that bucket can still be reached.
  defp confirm_objects?(%Library{} = library) do
    case Profiles.user_storage_for([library]) do
      %{} = own when map_size(own) == 0 ->
        false

      own ->
        reachable? =
          Enum.all?(own, fn {_uuid, %{bucket: bucket}} ->
            match?(
              {key, secret}
              when is_binary(key) and key != "" and is_binary(secret) and secret != "",
              S3.resolve_credentials(bucket)
            )
          end)

        if not reachable?,
          do:
            Logger.warning(
              "Storage: library #{library.uuid} is on a bucket whose credentials are gone; its objects there cannot be deleted and are left"
            )

        reachable?
    end
  end

  # `true` when the file is gone. With `confirm?`, its objects go first and the
  # rows stay until they have: `false` leaves the file for the retry.
  defp purge_file(file, false) do
    Storage.delete_file_completely(file)
    true
  end

  defp purge_file(file, true) do
    case Storage.delete_file_data(file) do
      result when result == :ok or result == {:error, "No file instances found"} ->
        Storage.delete_file_completely(file)
        true

      {:error, _reason} ->
        false
    end
  end

  defp finish_purge(%Library{uuid: uuid} = library) do
    # Folders go deepest first, so no parent is deleted under a child.
    from(f in Folder, where: f.library_uuid == ^uuid)
    |> repo().all()
    |> Enum.sort_by(&folder_depth/1, :desc)
    |> Enum.each(fn folder -> repo().delete!(folder) end)

    repo().delete!(library)

    # What was left of a user's own storage: their profile, and the buckets
    # only it used. A bucket that cannot be removed (it still holds file
    # locations) stays, and is reported; the purge itself is done.
    with profile when not is_nil(profile) <- library.storage_profile_uuid,
         {:error, reason} <- Profiles.delete_user_profile(profile) do
      Logger.warning(
        "Storage: the own storage of purged library #{uuid} was not fully removed: #{inspect(reason)}"
      )
    end

    :ok
  end

  defp folder_depth(%Folder{} = folder), do: folder_depth(folder, 0)

  defp folder_depth(%Folder{parent_uuid: nil}, depth), do: depth

  defp folder_depth(%Folder{parent_uuid: parent}, depth) when depth < 100 do
    case repo().get(Folder, parent) do
      nil -> depth
      folder -> folder_depth(folder, depth + 1)
    end
  end

  defp folder_depth(_folder, depth), do: depth

  @doc """
  Queues the purge of every user library trashed more than `days` ago, and
  of every one whose owner is gone. Run by the daily trash prune.
  """
  @spec queue_expired_purges(non_neg_integer()) :: non_neg_integer()
  def queue_expired_purges(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    from(l in Library,
      where:
        l.kind == "user" and not is_nil(l.trashed_at) and
          (l.trashed_at < ^cutoff or is_nil(l.owner_uuid)),
      select: l.uuid
    )
    |> repo().all()
    |> Enum.map(&enqueue_purge/1)
    |> length()
  end

  defp enqueue_purge(library_uuid) do
    %{"library_uuid" => to_string(library_uuid)}
    |> PurgeLibraryJob.new()
    |> Oban.insert()
  rescue
    # No Oban (update mode, a bare test): the daily prune picks it up.
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp generate_key_prefix do
    "lib-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
