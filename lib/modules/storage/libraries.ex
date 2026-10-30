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

  ## Hidden system libraries

  A module that keeps files of its own (a chat's attachments, say) can create a
  **hidden** one: `create_system_library(attrs, hidden: true)` with a `"slug"`
  of its own. It is a system library with `visibility: "private"`, and the site
  neither lists it nor opens it:

    * it is not listed with the site's libraries (`list_system_libraries/0`, so
      not in Media's switcher nor in Settings), and `get_system_library/1` and
      `get_system_library_by_slug/1`, which check a URL, do not find it; the
      module finds it again with `get_hidden_library_by_slug/1` or
      `get_library/1`;
    * its files and folders are left out of every listing that names no library
      (`exclude_user_libraries/1`: the media pickers, orphan cleanup) and are only
      browsed where the module names the library;
    * the Settings pages that name libraries (Health's stale files, a bucket's
      contents, a storage profile's libraries) and the job titles count it with
      the private libraries and never name it;
    * its files are private (`private?/1`): their URLs carry a time-window token
      and the permanent one is refused, and the repair log writes nothing about
      them;
    * `can?/3` grants its files to their uploader and to an Owner/Admin
      (`Scope.system_role?/1`) only: `media.view_all` opens none of them. An
      Owner/Admin reads any file of Storage by design, a hidden one included.

  ## A hidden library shown in Media, and a managed one

  A module whose files the site's people should find in Media (a mail
  client's attachments, say) can make its hidden library **visible there**
  without making it public, and **read-only**:

      create_system_library(attrs, hidden: true, media_listing: :uploaders, managed: true)
      update_system_library_listing(library, media_listing: :uploaders, managed: true)

  Both live in `Library.settings` (no migration). The library stays
  `visibility: "private"`: its files keep their expiring URLs, are never
  orphans, and stay out of every listing that names no library.

    * `media_listing` says who finds it in Media's switcher and opens it at
      `/admin/media/library/<slug>` (`list_system_libraries_for/1`):

      | `media_listing` | Owner/Admin       | other holder of `media` |
      |-----------------|-------------------|-------------------------|
      | `:none`         | no one            | no one                  |
      | `:admins`       | every file        | no one                  |
      | `:uploaders`    | every file        | only the files they uploaded |
      | `:own_only`     | only their own    | only their own          |

      "Only their own" is the page's `viewer_uuid` for this library, `media.view_all`
      or not. It limits what Media's browser lists; `can?/3` is unchanged.
    * `managed: true` makes every **user operation** on its files and folders
      `{:error, :managed}` (`check_managed/2`), and `can?(scope, file, :edit)`
      false for all, Owner included: trash, delete, move, rename, folder
      links, annotations, burn, image editing, a file's details. A managed
      library has no trash and no image editing at all. The module that owns
      the library passes `managed: :owner` to the other functions
      (`Storage.delete_file_completely/2`, `Storage.create_folder/3`,
      `Storage.move_file_to_folder/4`, `Storage.create_folder_link/4`, …) and
      they work. `Storage.update_file/2` and `update_file_instance/2` are not
      user operations and stay open: the processing job, the capture date and
      the reconciler write through them. Media's browser is read-only for the
      library whoever opens it.

  Its name and slug are not secret: the Storage history records its creation by
  name (unless the module passes `audit: false`), and they are taken in the one
  namespace all system libraries share (see `create_system_library/2`).

  Dedup keys fold the library in (`Storage.calculate_user_file_checksum/3`), so
  an upload outside the hidden library never comes back as one of its files.
  Without a hidden library, nothing about Storage changes.

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

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.ConnectionLock
  alias PhoenixKit.Integrations.{ObjectStorageServices, Probe}
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.Endpoint
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
  The live system libraries, the default (Media) first, then by name. A hidden
  one (`hidden?/1`) is not among them.
  """
  @spec list_system_libraries() :: [Library.t()]
  def list_system_libraries do
    from(l in Library,
      where: l.kind == "system" and l.visibility == "site" and is_nil(l.trashed_at),
      order_by: [desc: l.is_default, asc: fragment("lower(?)", l.name)]
    )
    |> repo().all()
  end

  @doc """
  Whether a library is a hidden system library (`create_system_library/2` with
  `hidden: true`). Takes a library or a uuid; Media and anything that is not a
  library are not.
  """
  @spec hidden?(Library.t() | term()) :: boolean()
  def hidden?(%Library{kind: "system", visibility: "private"}), do: true
  def hidden?(%Library{}), do: false
  def hidden?(nil), do: false

  def hidden?(uuid) when is_binary(uuid) do
    if media?(uuid), do: false, else: hidden?(get_library(uuid))
  end

  def hidden?(_), do: false

  @doc """
  The live hidden system library whose slug is `slug`, or nil — how the module
  that created it finds it again.
  """
  @spec get_hidden_library_by_slug(term()) :: Library.t() | nil
  def get_hidden_library_by_slug(slug) when is_binary(slug) do
    repo().one(
      from(l in Library,
        where:
          l.kind == "system" and l.visibility == "private" and is_nil(l.trashed_at) and
            l.slug == ^slug
      )
    )
  end

  def get_hidden_library_by_slug(_slug), do: nil

  @listings [:none, :admins, :uploaders, :own_only]

  @doc """
  How a hidden system library is shown in Media (`:none`, `:admins`,
  `:uploaders` or `:own_only`, see the moduledoc). Takes a library or a uuid;
  `:none` for anything that is not a hidden library or has not chosen.
  """
  @spec media_listing(Library.t() | term()) :: :none | :admins | :uploaders | :own_only
  def media_listing(%Library{kind: "system", visibility: "private", settings: settings}) do
    case Map.get(settings || %{}, "media_listing") do
      "admins" -> :admins
      "uploaders" -> :uploaders
      "own_only" -> :own_only
      _ -> :none
    end
  end

  def media_listing(%Library{}), do: :none
  def media_listing(uuid) when is_binary(uuid), do: media_listing(get_library(uuid))
  def media_listing(_), do: :none

  @doc """
  Whether a library is managed (`managed: true` among its settings: nobody
  changes or deletes its files from Media, see the moduledoc). Takes a
  library, a uuid, or a file or folder (anything with a `library_uuid`; none
  is Media's). Media and anything unknown are not.
  """
  @spec managed?(term()) :: boolean()
  def managed?(%Library{kind: "system", settings: %{"managed" => true}}), do: true
  def managed?(%Library{}), do: false
  def managed?(nil), do: false
  def managed?(%{library_uuid: library_uuid}), do: managed?(library_uuid)

  def managed?(uuid) when is_binary(uuid) do
    with false <- media?(uuid),
         {:ok, uuid} <- Ecto.UUID.cast(uuid) do
      repo().exists?(
        from(l in Library,
          where:
            l.uuid == ^uuid and l.kind == "system" and
              fragment("(?->'managed') = 'true'::jsonb", l.settings)
        )
      )
    else
      _ -> false
    end
  end

  def managed?(_), do: false

  @doc """
  `:ok` unless `target` (a library, uuid, file or folder, see `managed?/1`) is
  in a managed library and the caller did not pass `managed: :owner` among
  `opts` — then `{:error, :managed}`. What every user operation of
  `Storage` asks first.
  """
  @spec check_managed(term(), keyword()) :: :ok | {:error, :managed}
  def check_managed(target, opts \\ []) do
    if Keyword.get(opts, :managed) == :owner or not managed?(target),
      do: :ok,
      else: {:error, :managed}
  end

  @doc """
  The system libraries Media offers `scope`: the site's libraries, and the
  hidden ones whose `media_listing` shows them to this viewer. The default
  (Media) first, then by name. `list_system_libraries/0` is the same without
  the hidden ones and without a viewer.
  """
  @spec list_system_libraries_for(Scope.t() | nil) :: [Library.t()]
  def list_system_libraries_for(scope) do
    from(l in Library,
      where:
        l.kind == "system" and is_nil(l.trashed_at) and
          (l.visibility == "site" or
             (l.visibility == "private" and
                fragment(
                  "(?->>'media_listing') = ANY(?)",
                  l.settings,
                  ^~w(admins uploaders own_only)
                ))),
      order_by: [desc: l.is_default, asc: fragment("lower(?)", l.name)]
    )
    |> repo().all()
    |> Enum.filter(&listed_for?(scope, &1))
  end

  @doc """
  Whether Media offers the system library to `scope` (it is one of
  `list_system_libraries_for/1`).
  """
  @spec listed_for?(Scope.t() | nil, Library.t() | term()) :: boolean()
  def listed_for?(_scope, %Library{kind: "system", visibility: "site", trashed_at: nil}),
    do: true

  def listed_for?(
        %Scope{} = scope,
        %Library{kind: "system", visibility: "private", trashed_at: nil, slug: slug} = library
      )
      when is_binary(slug) do
    case media_listing(library) do
      :none -> false
      :admins -> Scope.system_role?(scope)
      _ -> Scope.system_role?(scope) or Scope.has_module_access?(scope, "media")
    end
  end

  def listed_for?(_scope, _library), do: false

  @doc """
  Whose files Media's browser lists for `scope` in `library`, as the
  browser's `viewer_uuid`: `nil` for all of them, else the viewer's uuid (only
  what they uploaded, and the folders leading to it). A site library follows
  the viewer's rights (an Owner/Admin and a holder of `media.view_all` see
  all); a hidden one shown in Media follows its `media_listing`, where
  `media.view_all` does not widen "only their own".
  """
  @spec media_viewer_uuid(Scope.t(), Library.t()) :: String.t() | nil
  def media_viewer_uuid(%Scope{} = scope, %Library{visibility: "private"} = library) do
    case media_listing(library) do
      :own_only ->
        Scope.user_uuid(scope)

      _ ->
        if Scope.system_role?(scope), do: nil, else: Scope.user_uuid(scope)
    end
  end

  def media_viewer_uuid(%Scope{} = scope, %Library{}) do
    if Scope.system_role?(scope) or Scope.can?(scope, "media.view_all"),
      do: nil,
      else: Scope.user_uuid(scope)
  end

  @doc """
  Sets how a hidden system library is shown in Media and whether it is
  managed (see the moduledoc), whichever of `media_listing:` and `managed:`
  is given. For a library made before the module asked for either, or to
  change its mind; idempotent. Only the keys given change.

  `{:error, :not_hidden}` for any other library, `{:error, :invalid_value}`
  for a listing outside `:none | :admins | :uploaders | :own_only` or a
  `managed` that is not a boolean.
  """
  @spec update_system_library_listing(Library.t(), keyword()) ::
          {:ok, Library.t()} | {:error, :not_hidden | :invalid_value | :not_found}
  def update_system_library_listing(library, opts)

  def update_system_library_listing(
        %Library{kind: "system", visibility: "private", uuid: uuid},
        opts
      ) do
    with {:ok, change} <- listing_settings(opts) do
      {count, _} =
        from(l in Library,
          where: l.uuid == ^uuid,
          update: [
            set: [
              settings: fragment("? || ?", l.settings, type(^change, :map)),
              updated_at: ^DateTime.truncate(DateTime.utc_now(), :second)
            ]
          ]
        )
        |> repo().update_all([])

      if count == 1, do: {:ok, get_library(uuid)}, else: {:error, :not_found}
    end
  end

  def update_system_library_listing(_library, _opts), do: {:error, :not_hidden}

  defp listing_settings(opts) do
    Enum.reduce_while([:media_listing, :managed], {:ok, %{}}, fn key, {:ok, acc} ->
      case Keyword.fetch(opts, key) do
        :error -> {:cont, {:ok, acc}}
        {:ok, value} -> listing_setting(key, value, acc)
      end
    end)
  end

  defp listing_setting(:media_listing, value, acc) when value in @listings,
    do: {:cont, {:ok, Map.put(acc, "media_listing", Atom.to_string(value))}}

  defp listing_setting(:managed, value, acc) when is_boolean(value),
    do: {:cont, {:ok, Map.put(acc, "managed", value)}}

  defp listing_setting(_key, _value, _acc), do: {:halt, {:error, :invalid_value}}

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
  A hidden one (`hidden?/1`) is nil here.
  """
  @spec get_system_library(term()) :: Library.t() | nil
  def get_system_library(uuid) do
    case get_library(uuid) do
      %Library{kind: "system", visibility: "site", trashed_at: nil} = library -> library
      _ -> nil
    end
  end

  @doc """
  The live system library whose URL slug is `slug`, or nil. The default
  library has no slug (it is the bare `/admin/media`). A hidden one is not
  found here (`get_hidden_library_by_slug/1`).
  """
  @spec get_system_library_by_slug(term()) :: Library.t() | nil
  def get_system_library_by_slug(slug) when is_binary(slug) do
    repo().one(
      from(l in Library,
        where:
          l.kind == "system" and l.visibility == "site" and is_nil(l.trashed_at) and
            l.slug == ^slug
      )
    )
  end

  def get_system_library_by_slug(_slug), do: nil

  @doc """
  Creates a system library. `attrs` takes a `"name"` (or `:name`). The URL
  slug comes from the name (`"Brand Assets"` → `"brand-assets"`, then
  `"brand-assets-2"` … while one is taken) and the object-key prefix is
  generated, unless either is given.

  `hidden: true` among the options makes it a hidden library (see "Hidden
  system libraries" above), for a module's own files. Only this option hides
  one: a `"visibility"` in `attrs` is ignored. A hidden library needs its
  `"slug"` in `attrs`: it is not derived, and a taken one is an error (on
  `:slug`), never `"<slug>-2"`, so the module finds the library again with
  `get_hidden_library_by_slug/1`. System libraries share one namespace of
  names and of slugs, so give both a prefix of the module's own
  (`"phoenix-kit-ai"`, say); a site library cannot then take that name later
  without "is already the name of another library". `audit: false` among the
  options leaves the creation out of the Storage history, which names it.

  A hidden library may also be born shown in Media and read-only:
  `media_listing:` (`:none` by default, `:admins`, `:uploaders`, `:own_only`) and
  `managed: true` (see "A hidden library shown in Media, and a managed one"
  above). A site library ignores both. Anything else for either is an error
  on `:settings`.
  """
  @spec create_system_library(map(), keyword()) ::
          {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def create_system_library(attrs, opts \\ []) do
    Audit.transaction(fn -> do_create_system_library(attrs, opts) end)
  end

  defp do_create_system_library(attrs, opts) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    attrs = Map.put_new_lazy(attrs, "key_prefix", &generate_key_prefix/0)

    hidden? = Keyword.get(opts, :hidden) == true

    with {:ok, storage} <- creation_storage(attrs),
         {:ok, listing} <- creation_listing(attrs, opts, hidden?) do
      storage = if hidden?, do: Keyword.put(storage, :visibility, "private"), else: storage
      storage = if listing == %{}, do: storage, else: Keyword.put(storage, :settings, listing)

      case attrs do
        %{"slug" => _} ->
          insert_system_library(attrs, storage)

        # A hidden one is found again by its slug: none is made up for it.
        _ when hidden? ->
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

  # What a hidden library is born with in Media: `media_listing:` and `managed:`
  # among the options (ignored for a site library, which is always listed).
  defp creation_listing(attrs, opts, true) do
    case listing_settings(Keyword.take(opts, [:media_listing, :managed])) do
      {:ok, listing} ->
        {:ok, listing}

      {:error, :invalid_value} ->
        {:error, storage_error(attrs, :settings, "is not a valid listing")}
    end
  end

  defp creation_listing(_attrs, _opts, false), do: {:ok, %{}}

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
  # A hidden one is named only when it is created (and `audit: false` skips that).
  defp audit_library(
         action,
         %Library{kind: "system", visibility: "private"} = library,
         opts,
         metadata
       )
       when action == "storage.library.created" do
    Audit.log(action, "storage_library", library.uuid, opts, metadata)
    :ok
  end

  defp audit_library(_action, %Library{kind: "system", visibility: "private"}, _opts, _metadata),
    do: :ok

  defp audit_library(action, %Library{kind: "system"} = library, opts, metadata) do
    Audit.log(action, "storage_library", library.uuid, opts, metadata)
    :ok
  end

  defp audit_library(_action, _library, _opts, _metadata), do: :ok

  # Tries `base`, `base-2`, `base-3` … until the slug is free. Any other
  # error (a taken name, a blank one) is returned as it is.
  defp insert_with_free_slug(attrs, base, n, insert) do
    slug = if n == 1, do: base, else: "#{base}-#{n}"

    if reserved_slug?(slug) and n < 100 do
      insert_with_free_slug(attrs, base, n + 1, insert)
    else
      insert_with_free_slug_attempt(attrs, base, n, slug, insert)
    end
  end

  defp insert_with_free_slug_attempt(attrs, base, n, slug, insert) do
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
  Whether files in a library are private (`visibility: "private"`, every user
  library except a public one, a hidden system library, and a public one while
  it is suspended or in the trash): their
  URLs carry a time-window token and are never answered with a redirect to a
  public object URL. Media is answered without a query; anything that is not a
  library is not private.
  """
  @spec private?(term()) :: boolean()
  def private?(nil), do: false

  def private?(uuid) do
    if media?(uuid) do
      false
    else
      case Ecto.UUID.cast(uuid) do
        {:ok, uuid} ->
          repo().exists?(
            from(l in Library, where: ^dynamic([l], l.uuid == ^uuid and ^private_condition()))
          )

        :error ->
          false
      end
    end
  end

  # A library is private when it says so, or while it is a public one an admin has
  # suspended or its owner has trashed: it then answers as private until it is
  # restored. Trashing a library leaves its files `active`, so without this the
  # permanent links of a trashed public library would keep serving.
  defp private_condition do
    dynamic(
      [l],
      l.visibility == "private" or
        fragment("(?->>'public_audience') = 'authenticated'", l.settings) or
        not is_nil(l.trashed_at) or
        fragment("(?->>'suspended') = 'true'", l.settings)
    )
  end

  @doc """
  Which of `library_uuids` are private, in one query — for a page that
  builds URLs for many files at once.
  """
  @spec private_among([term()]) :: [String.t()]
  def private_among(library_uuids), do: among(library_uuids, private_condition())

  @doc """
  Which of `library_uuids` a site listing leaves out, in one query: user
  libraries and private ones (hidden system libraries, trashed, suspended) —
  the rule of `exclude_user_libraries/1`. The site's folder tree and the media
  browser's event checks use it.
  """
  @spec user_or_hidden_among([term()]) :: [String.t()]
  def user_or_hidden_among(library_uuids),
    do: among(library_uuids, dynamic([l], l.kind == "user" or ^private_condition()))

  defp among(library_uuids, condition) do
    uuids =
      library_uuids
      |> Enum.reject(&(is_nil(&1) or media?(&1)))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if uuids == [] do
      []
    else
      from(l in Library, where: ^dynamic([l], l.uuid in ^uuids and ^condition), select: l.uuid)
      |> repo().all()
      |> Enum.map(&to_string/1)
    end
  end

  @doc """
  Which of `library_uuids` are user libraries (private or public), in one query —
  for a site listing that must not mix them in.
  """
  @spec user_among([term()]) :: [String.t()]
  def user_among(library_uuids) do
    uuids =
      library_uuids
      |> Enum.reject(&(is_nil(&1) or media?(&1)))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    if uuids == [] do
      []
    else
      from(l in Library, where: l.uuid in ^uuids and l.kind == "user", select: l.uuid)
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

  # `deep_zoom`: whether the library's images may be viewed as zoomable tiles.
  # A library that has not chosen follows its rendition profile's old
  # `generate_tiles` flag (`VariantSets.deep_zoom_for_library?/1`), so nothing
  # turned off or on by a set stops or starts when this setting appeared.
  @settings %{
    annotated_thumbnails: {"annotated_thumbnails", :boolean},
    deep_zoom: {"deep_zoom", :boolean}
  }

  @typedoc "A per-library setting."
  @type setting :: :annotated_thumbnails | :deep_zoom

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
  its default again (the site setting for annotated thumbnails, the rendition
  set for deep zoom). Only the key changes (a concurrent change to
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

  # A system library's setting changing; name the default it inherits when unset.
  defp audit_setting(%Library{} = before, %Library{} = updated, key, opts) do
    old = setting(before, key)
    new = setting(updated, key)

    if old != new do
      audit_library("storage.library.setting_changed", updated, opts, %{
        "library" => updated.name,
        PhoenixKit.Activity.changes_key() => %{
          to_string(key) => %{"from" => setting_label(key, old), "to" => setting_label(key, new)}
        }
      })
    end

    :ok
  end

  defp setting_label(:annotated_thumbnails, nil), do: "site default"
  defp setting_label(:deep_zoom, nil), do: "rendition profile"
  defp setting_label(_key, value), do: value

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

  # ---------------------------------------------------------------------------
  # A module's own per-library settings
  #
  # A module that is not core (a package: photos, say) has settings of its own for a
  # library, and core must not have to name them. They live in the same `settings` map,
  # under `"modules"` and the module's namespace: `settings["modules"]["photos"]["viewer"]`.
  # Core keeps the namespacing, the update of only that key, the lock and the history; it
  # knows no key and checks no value beyond being a plain scalar. Which keys exist, what
  # they may be, and what none means is the module's to say.
  # ---------------------------------------------------------------------------

  @module_namespace ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @module_key ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @module_value_bytes 255

  @typedoc "A module setting's value: a boolean, a number, or a string of at most 255 bytes."
  @type module_value :: boolean() | number() | String.t()

  @doc """
  A module's own value of `key` for a library, or nil when it has none. `namespace` is
  the module's (`"photos"`); a library, a library uuid, or nil for Media.
  """
  @spec module_setting(Library.t() | term(), String.t(), String.t()) :: module_value() | nil
  def module_setting(%Library{settings: settings}, namespace, key),
    do: stored_module_value(settings, namespace, key)

  def module_setting(nil, namespace, key), do: module_setting(@media_uuid, namespace, key)

  def module_setting(uuid, namespace, key) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Library{} = library <- repo().get(Library, uuid) do
      module_setting(library, namespace, key)
    else
      _ -> nil
    end
  end

  @doc """
  Sets a module's own value of `key` for a library; nil removes it. Only that key
  changes (another key of the module, or another module's, is not lost). The value is
  a boolean, a number or a string of at most 255 bytes; the namespace and the key are
  lowercase words (`[a-z][a-z0-9_]*`, up to 32 and 64 characters).

  Returns `{:error, :invalid_namespace | :invalid_key | :invalid_value | :not_found}`
  and changes nothing when refused.
  """
  @spec put_module_setting(Library.t(), String.t(), String.t(), module_value() | nil, keyword()) ::
          {:ok, Library.t()}
          | {:error, :invalid_namespace | :invalid_key | :invalid_value | :not_found}
  def put_module_setting(%Library{} = library, namespace, key, value, opts \\ []) do
    with :ok <- check_module_namespace(namespace),
         :ok <- check_module_key(key),
         :ok <- check_module_value(value) do
      Audit.change(library, &do_put_module_setting(&1, namespace, key, value, opts))
    end
  end

  defp do_put_module_setting(%Library{uuid: uuid} = library, namespace, key, value, opts) do
    {count, _} =
      if is_nil(value) do
        from(l in Library,
          where: l.uuid == ^uuid,
          update: [
            set: [
              settings:
                fragment("? #- array['modules', ?::text, ?::text]", l.settings, ^namespace, ^key)
            ]
          ]
        )
        |> repo().update_all([])
      else
        patch = %{key => value}

        from(l in Library,
          where: l.uuid == ^uuid,
          update: [
            set: [
              # First make sure `modules` exists, then set the module's map to itself merged with the patch.
              # credo:disable-for-next-line Credo.Check.Readability.MaxLineLength
              settings:
                fragment(
                  "jsonb_set(jsonb_set(?, '{modules}', coalesce(? -> 'modules', '{}'::jsonb)), array['modules', ?::text], coalesce(? #> array['modules', ?::text], '{}'::jsonb) || ?)",
                  l.settings,
                  l.settings,
                  ^namespace,
                  l.settings,
                  ^namespace,
                  type(^patch, :map)
                )
            ]
          ]
        )
        |> repo().update_all([])
      end

    if count == 1 do
      if is_nil(value), do: prune_module_namespace(uuid, namespace)
      updated = get_library(uuid)
      audit_module_setting(library, updated, namespace, key, opts)
      {:ok, updated}
    else
      {:error, :not_found}
    end
  end

  # A module whose last key was removed leaves nothing behind.
  defp prune_module_namespace(uuid, namespace) do
    from(l in Library,
      where: l.uuid == ^uuid,
      where: fragment("(? #> array['modules', ?::text]) = '{}'::jsonb", l.settings, ^namespace),
      update: [
        set: [settings: fragment("? #- array['modules', ?::text]", l.settings, ^namespace)]
      ]
    )
    |> repo().update_all([])

    from(l in Library,
      where: l.uuid == ^uuid,
      where: fragment("(? -> 'modules') = '{}'::jsonb", l.settings),
      update: [set: [settings: fragment("? - 'modules'", l.settings)]]
    )
    |> repo().update_all([])
  end

  defp audit_module_setting(%Library{} = before, %Library{} = updated, namespace, key, opts) do
    old = module_setting(before, namespace, key)
    new = module_setting(updated, namespace, key)

    if old != new do
      audit_library("storage.library.setting_changed", updated, opts, %{
        "library" => updated.name,
        PhoenixKit.Activity.changes_key() => %{
          "#{namespace}.#{key}" => %{"from" => old || "not set", "to" => new || "not set"}
        }
      })
    end

    :ok
  end

  defp check_module_namespace(namespace) when is_binary(namespace),
    do:
      if(Regex.match?(@module_namespace, namespace), do: :ok, else: {:error, :invalid_namespace})

  defp check_module_namespace(_namespace), do: {:error, :invalid_namespace}

  defp check_module_key(key) when is_binary(key),
    do: if(Regex.match?(@module_key, key), do: :ok, else: {:error, :invalid_key})

  defp check_module_key(_key), do: {:error, :invalid_key}

  defp check_module_value(nil), do: :ok
  defp check_module_value(value) when is_boolean(value) or is_number(value), do: :ok

  defp check_module_value(value) when is_binary(value) do
    if byte_size(value) <= @module_value_bytes and String.valid?(value),
      do: :ok,
      else: {:error, :invalid_value}
  end

  defp check_module_value(_value), do: {:error, :invalid_value}

  defp stored_module_value(settings, namespace, key) do
    with :ok <- check_module_namespace(namespace),
         :ok <- check_module_key(key),
         %{} = modules <- Map.get(settings || %{}, "modules"),
         %{} = own <- Map.get(modules, namespace),
         value when not is_nil(value) <- Map.get(own, key),
         :ok <- check_module_value(value) do
      value
    else
      _ -> nil
    end
  end

  @doc "Whether `file` (anything with a `library_uuid`) is in a private library."
  @spec private_file?(map()) :: boolean()
  def private_file?(%{library_uuid: library_uuid}), do: private?(library_uuid)
  def private_file?(_file), do: false

  @doc """
  Drops rows whose library is a user library, private or public, or a hidden
  system library (any private library).

  The file or folder is the query's first binding. Site listings
  (`/admin/media`, the media pickers, orphan cleanup) use this so a user
  library is not mixed into the site's media; pass that library's uuid to
  read it. A user library's files are not orphans: nothing in the site
  references them, and treating them as unreferenced would delete them. A
  public library is not private, but it is still its owner's, not the site's.
  """
  @spec exclude_user_libraries(Ecto.Query.t()) :: Ecto.Query.t()
  def exclude_user_libraries(query) do
    user =
      from(l in Library,
        where: ^dynamic([l], l.kind == "user" or ^private_condition()),
        select: l.uuid
      )

    where(query, [row], row.library_uuid not in subquery(user))
  end

  @doc "The old name of `exclude_user_libraries/1`, from when every user library was private."
  @spec exclude_private(Ecto.Query.t()) :: Ecto.Query.t()
  def exclude_private(query), do: exclude_user_libraries(query)

  @doc """
  Whether `scope` may do `action` to `file`. One predicate for every
  per-file check, so they stop drifting apart:

    * `:read` — the file's info and signed URLs: its uploader, an
      Owner/Admin (`Scope.system_role?/1`, whatever library the file is in, a
      hidden one included), or — for a file in a user
      library — that library's owner or any of its members, or **anyone**,
      signed in or not, when the library is public (`public?/1`). Deliberately
      NOT the `"media"` permission: a single permission must not open every
      other user's file metadata (issue #687).
    * `:edit` — change the picture (image editing, annotation burn-in, the
      unedited original): the uploader, an Owner/Admin, a holder of the
      `"media"` permission with `"media.view_all"` when the file is in a system
      library that is not hidden (`hidden?/1`), or the
      owner or a manager of the user library it is in. Nobody, whoever they
      are, may edit a file of a managed library (`managed?/1`).

  Anything else is refused, and a scope without a user, or none at all (`nil`),
  can only read a file of a public library.
  """
  @spec can?(Scope.t() | nil, map(), :read | :edit) :: boolean()
  def can?(%Scope{} = scope, %{} = file, action) when action in [:read, :edit] do
    library_uuid = Map.get(file, :library_uuid) || @media_uuid

    # A managed library's files are changed by no one from here, an Owner included.
    if action == :edit and managed?(library_uuid) do
      false
    else
      uploader?(scope, file) or Scope.system_role?(scope) or
        library_grants?(scope, library_uuid, action)
    end
  end

  def can?(nil, %{} = file, :read),
    do: audience_allows?(nil, get_library(Map.get(file, :library_uuid)))

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

  # A hidden library is a module's own: nothing beyond its uploader and an Owner/Admin.
  defp grants?(_scope, %Library{kind: "system", visibility: "private"}, _action), do: false
  defp grants?(scope, %Library{kind: "system"}, action), do: grants?(scope, :media, action)

  defp grants?(scope, %Library{kind: "user", trashed_at: nil} = library, action) do
    role = role(library, Scope.user_uuid(scope))

    if action == :read,
      do: role != nil or audience_allows?(scope, library),
      else: role in [:owner, :manager]
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
  Whether `slug` is one the host keeps for its own pages: `config :phoenix_kit,
  :reserved_library_slugs, ["admin", "photos"]`. A library's slug is a segment of a URL the
  host may route (`/<username>/<slug>`), and a library called "Admin" would then be reached
  at an address another page owns. A name that slugs to a reserved word is given the next
  free slug (`photos-2`), and `change_library_slug/2` refuses it. Case does not matter.
  """
  @spec reserved_slug?(term()) :: boolean()
  def reserved_slug?(slug) when is_binary(slug) do
    slug = String.downcase(slug)

    Enum.any?(
      Application.get_env(:phoenix_kit, :reserved_library_slugs, []),
      &(String.downcase(to_string(&1)) == slug)
    )
  end

  def reserved_slug?(_slug), do: false

  @doc """
  Changes the URL slug of a user library, for a host that names its pages by it. Unscoped like
  `rename_library/3` (the host decides who may call it), and written to the history. Returns
  `{:ok, library}` or `{:error, changeset}`: the slug is badly shaped, reserved, or the owner
  has a library with it already (a trashed one holds none).
  """
  @spec change_library_slug(Library.t(), String.t(), keyword()) ::
          {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def change_library_slug(%Library{kind: "user"} = library, slug, opts \\ []) do
    Audit.change(library, fn library ->
      library
      |> Library.slug_changeset(%{slug: slug})
      |> repo().update()
      |> tap(fn
        {:ok, changed} when changed.slug != library.slug ->
          audit_library("storage.library.slug_changed", changed, opts, %{
            "name" => changed.name,
            PhoenixKit.Activity.changes_key() => %{
              "slug" => %{"from" => library.slug, "to" => changed.slug}
            }
          })

        _result ->
          :ok
      end)
    end)
  end

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
          "targets" => [
            %{"integration_uuid" => "…",  # one of the user's own integrations
              "bucket_name" => "my-photos"},
            %{"integration_uuid" => "…",  # optional: a copy on a second one
              "bucket_name" => "my-photos-copy"}]}}

  Each target is a bucket on one of the user's Object Storage integrations. The
  provider, region and endpoint are the integration's own and need not be sent
  (one sent anyway wins). A single bucket may also be given flat, as
  `"integration_uuid"` and `"bucket_name"` beside `"mode"`.

  `"only"` keeps everything in the first bucket and copies it to the others;
  `"backup"` keeps the site's storage as it is and copies the originals to every
  target (see `Profiles.create_user_profile/3`). Up to `Profiles.max_user_buckets/0`
  targets. Needs `may_use_own_storage?/1` (`{:error, :not_allowed}` otherwise).

  Every bucket is probed first, reading, writing and deleting a small object
  (`:probe`, a function of the bucket params, `Storage.test_connection/1` by
  default): a library that could not store anything is not created, and the
  reason is `{:error, {:storage, message}}`. A bucket, profile or library that
  cannot be created undoes the rest. Problems with the bucket fields are
  `{:error, {:storage, %Ecto.Changeset{}}}`. A connection that changes between
  the probe and its row lock is `{:error, :storage_changed}`, and nothing is
  left behind.
  """
  @spec create_user_library(Scope.t() | nil, map(), keyword()) ::
          {:ok, Library.t()}
          | {:error,
             :not_allowed
             | :limit_reached
             | :no_site_storage
             | :storage_changed
             | :foreign_bucket
             | :too_many_buckets
             | {:storage, String.t() | Ecto.Changeset.t()}
             | Ecto.Changeset.t()}
  def create_user_library(scope, attrs, opts \\ []) do
    scope = fresh_storage_scope(scope)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    {storage, attrs} = Map.pop(attrs, "storage")
    {visibility, attrs} = Map.pop(attrs, "visibility")

    with true <- may_create_library?(scope) || {:error, :not_allowed},
         user_uuid when is_binary(user_uuid) <- Scope.user_uuid(scope) || {:error, :not_allowed},
         {:ok, visibility} <- visibility_request(scope, visibility),
         {:ok, own} <- own_storage_request(scope, user_uuid, storage, opts) do
      repo().transaction(fn ->
        # One creation per user at a time, so two tabs cannot both pass the
        # limit check.
        lock_user(user_uuid)
        owned = count_owned(user_uuid)

        if owned >= user_library_limit() do
          repo().rollback(:limit_reached)
        else
          library = insert_owned(Map.put(attrs, "visibility", visibility), user_uuid, owned == 0)
          attach_own_storage(library, user_uuid, own)
        end
      end)
      |> tap(fn result -> log_published(result, scope) end)
    end
  end

  @doc """
  Adds backup storage to an existing library on its owner's own storage.

  Only the owner with the current own-storage permission may act. Existing
  primary buckets, copy counts and minimum writes are preserved. Every target
  is probed before any database change; connection snapshots are checked again
  under the same lock as credential edits and removal. Profile revisions queue
  the reconciler, which verifies copies of existing files in the background.
  """
  def add_user_storage(scope, %Library{uuid: uuid}, params, opts \\ []) do
    scope = fresh_storage_scope(scope)
    user_uuid = Scope.user_uuid(scope)

    with true <- may_use_own_storage?(scope) || {:error, :not_allowed},
         %Library{kind: "user", owner_uuid: ^user_uuid, trashed_at: nil} = listed <-
           get_library(uuid),
         %{} <- Profiles.user_storage_for([listed])[to_string(uuid)],
         {:ok, targets} <- storage_targets(stringify(params), user_uuid),
         :ok <- additional_targets_allowed(listed, targets),
         :ok <- probe_targets(targets, user_uuid, Keyword.get(opts, :probe)) do
      repo().transaction(fn ->
        library =
          repo().one(from(l in Library, where: l.uuid == ^uuid, lock: "FOR NO KEY UPDATE"))

        with true <- may_use_own_storage?(fresh_storage_scope(scope)),
             %Library{kind: "user", owner_uuid: ^user_uuid, trashed_at: nil} <- library,
             %{} <- Profiles.user_storage_for([library])[to_string(uuid)],
             :ok <- additional_targets_allowed(library, targets),
             {:ok, buckets} <- create_owned_buckets(library, user_uuid, targets),
             {:ok, _profile} <-
               Profiles.add_user_backups(library.storage_profile_uuid, user_uuid, buckets) do
          library
        else
          {:error, reason} -> repo().rollback(reason)
          _ -> repo().rollback(:not_allowed)
        end
      end)
    else
      {:error, _} = error -> error
      _ -> {:error, :not_allowed}
    end
  end

  defp fresh_storage_scope(scope), do: __MODULE__.Preferences.fresh_scope(scope)

  # The cap counts the user's own buckets. The duplicate check counts every
  # bucket already on the profile, including a site primary that backup mode
  # keeps: two rows for one physical bucket would both pass a copy check.
  defp additional_targets_allowed(%Library{storage_profile_uuid: uuid}, targets)
       when is_binary(uuid) do
    case Profiles.get_profile(uuid) do
      %{buckets: rows} ->
        user_buckets = Enum.count(rows, &(not is_nil(&1.bucket.owner_uuid)))
        occupied = Enum.map(rows, &destination_target(&1.bucket))

        cond do
          user_buckets + length(targets) > Profiles.max_user_buckets() ->
            {:error, :too_many_buckets}

          duplicate_targets?(occupied ++ targets) ->
            {:error, :duplicate_bucket}

          true ->
            :ok
        end

      _ ->
        {:error, :not_allowed}
    end
  end

  defp additional_targets_allowed(_library, _targets), do: {:error, :not_allowed}

  # What the user asked for. Private is the default and needs nothing; public
  # needs the `storage.public_library` permission, and anything else is refused.
  defp visibility_request(_scope, nil), do: {:ok, "private"}
  defp visibility_request(_scope, "private"), do: {:ok, "private"}

  defp visibility_request(scope, "public"),
    do: if(may_create_public_library?(scope), do: {:ok, "site"}, else: {:error, :not_allowed})

  defp visibility_request(_scope, _other), do: {:error, :not_allowed}

  # Making a library public is written to the history: who, which, when.
  defp log_published({:ok, %Library{visibility: "site"} = library}, scope) do
    Audit.log(
      "storage.library_published",
      "library",
      library.uuid,
      [actor_uuid: Scope.user_uuid(scope)],
      %{"name" => library.name}
    )

    :ok
  end

  defp log_published(_result, _scope), do: :ok

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
        with {:ok, targets} <- storage_targets(storage, user_uuid),
             :ok <- distinct_from_site_backup(mode, targets),
             :ok <- probe_targets(targets, user_uuid, Keyword.get(opts, :probe)) do
          {:ok, %{mode: String.to_existing_atom(mode), targets: targets}}
        else
          {:error, %Ecto.Changeset{}} = error -> wrap_storage_error(error)
          {:error, message} when is_binary(message) -> {:error, {:storage, message}}
        end
    end
  end

  defp own_storage_request(_scope, _user_uuid, _storage, _opts), do: {:error, :not_allowed}

  defp wrap_storage_error({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, {:storage, changeset}}

  @target_fields ~w(integration_uuid provider bucket_name region endpoint)

  # The buckets a `"storage"` map asks for, as the params of a bucket each:
  # `"targets"` (a list, or the map a form posts as `targets[0]`, `targets[1]`),
  # else the map itself as the one target. What an integration already knows
  # (its service, region, endpoint) fills what is left blank. A target with
  # neither an integration nor a bucket is an empty row of the form and is left
  # out.
  defp storage_targets(storage, user_uuid) do
    targets =
      storage
      |> raw_targets()
      |> Enum.map(&Map.take(stringify(&1), @target_fields))
      |> drop_empty_rows(storage)
      |> Enum.map(&fill_from_integration(&1, user_uuid))

    cond do
      targets == [] ->
        {:error, "Choose an integration and a bucket"}

      length(targets) > Profiles.max_user_buckets() ->
        {:error,
         "A library can use at most #{Profiles.max_user_buckets()} integrations (one main, the rest copies)"}

      duplicate_targets?(targets) ->
        {:error, "The same bucket is chosen twice"}

      true ->
        {:ok, targets}
    end
  end

  # Empty rows only exist in the form's list; a single bucket given flat is kept
  # as it is so the bucket's own validation says what is missing from it.
  defp drop_empty_rows(targets, %{"targets" => _}),
    do: Enum.reject(targets, &(blank?(&1["integration_uuid"]) and blank?(&1["bucket_name"])))

  defp drop_empty_rows(targets, _flat), do: targets

  defp raw_targets(%{"targets" => targets}) when is_list(targets), do: targets

  defp raw_targets(%{"targets" => %{} = targets}) do
    targets
    |> Enum.sort_by(fn {key, _} -> sort_index(key) end)
    |> Enum.map(fn {_key, target} -> target end)
  end

  defp raw_targets(storage), do: [storage]

  defp sort_index(key) do
    case Integer.parse(to_string(key)) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_other), do: %{}

  defp blank?(value), do: value in [nil, ""]

  # Backup mode copies site buckets onto the new profile. A target that is
  # the same place as one of those rows would count twice.
  defp distinct_from_site_backup("backup", targets) do
    site =
      Profiles.site_rows_for_backup(length(targets))
      |> Enum.map(&destination_target(&1.bucket))

    if duplicate_targets?(site ++ targets),
      do: {:error, "The same bucket is chosen twice"},
      else: :ok
  end

  defp distinct_from_site_backup(_mode, _targets), do: :ok

  defp destination_target(bucket) do
    %{
      "integration_uuid" => bucket.integration_uuid,
      "bucket_name" => bucket.bucket_name,
      "endpoint" => bucket.endpoint
    }
  end

  defp duplicate_targets?(targets) do
    # A missing integration is not a connection. Site buckets often have none,
    # and several of those must not look like the same choice.
    connections =
      targets
      |> Enum.filter(&(not blank?(&1["integration_uuid"])))
      |> Enum.map(&{&1["integration_uuid"], &1["bucket_name"]})

    destinations = Enum.map(targets, &storage_destination/1)

    length(Enum.uniq(connections)) != length(connections) or
      length(Enum.uniq(destinations)) != length(destinations)
  end

  # Different credential rows pointing at the same bucket are one physical
  # destination, so they cannot count as independent backup copies. A blank
  # endpoint is plain AWS, and bucket names there are global, so any
  # `amazonaws.com` host on the standard port is that same destination.
  # China (`.amazonaws.com.cn`) is another partition and stays distinct.
  @doc "Whether two bucket descriptions point at the same physical storage destination."
  def same_storage_destination?(left, right) do
    storage_destination(stringify(Map.take(left, [:endpoint, :bucket_name]))) ==
      storage_destination(stringify(Map.take(right, [:endpoint, :bucket_name])))
  end

  defp storage_destination(target) do
    {physical_endpoint(target["endpoint"]), target["bucket_name"]}
  end

  defp physical_endpoint(endpoint) do
    case Endpoint.parse(endpoint) do
      nil ->
        :amazon_s3

      %{host: host, port: port} ->
        host = String.downcase(host)

        if port == 443 and aws_commercial_host?(host),
          do: :amazon_s3,
          else: {host, port}

      _ ->
        endpoint
    end
  end

  defp aws_commercial_host?(host) do
    host == "amazonaws.com" or String.ends_with?(host, ".amazonaws.com")
  end

  # What the user's integration says about itself, for the fields the target
  # left blank. A connection that cannot be read here is not an error: the
  # bucket changeset refuses a connection that is not the user's.
  defp fill_from_integration(%{"integration_uuid" => uuid} = target, user_uuid)
       when is_binary(uuid) and uuid != "" do
    case Integrations.get_integration_by_uuid(uuid, {:user, user_uuid}) do
      {:ok, %{provider: "object_storage", data: data}} ->
        summary = integration_details(data)

        target
        |> put_blank("provider", summary.provider)
        |> put_blank("region", summary.region)
        |> put_blank("endpoint", summary.endpoint)
        |> Map.put("__connection_snapshot", connection_digest(data))

      _ ->
        Map.put(target, "__connection_snapshot", nil)
    end
  end

  defp fill_from_integration(target, _user_uuid),
    do: Map.put(target, "__connection_snapshot", nil)

  defp put_blank(target, key, value) do
    if blank?(target[key]) and not blank?(value), do: Map.put(target, key, value), else: target
  end

  @doc """
  What one of `user_uuid`'s Object Storage integrations says about itself, for the
  form that picks it: `%{provider: …, service: …, region: …, endpoint: …}`
  (`provider` is the bucket provider the service is created as), or nil when it is
  not theirs. Nothing secret.
  """
  @spec integration_summary(String.t(), term()) ::
          %{
            provider: String.t(),
            service: String.t() | nil,
            label: String.t() | nil,
            region: String.t() | nil,
            endpoint: String.t() | nil
          }
          | nil
  def integration_summary(user_uuid, uuid) when is_binary(user_uuid) and is_binary(uuid) do
    case Integrations.get_integration_by_uuid(uuid, {:user, user_uuid}) do
      {:ok, %{provider: "object_storage", data: data}} ->
        integration_details(data)

      _ ->
        nil
    end
  end

  def integration_summary(_user_uuid, _uuid), do: nil

  defp integration_details(data) do
    service = ObjectStorageServices.current(data)

    %{
      provider: ObjectStorageServices.bucket_provider(service),
      service: service,
      label: ObjectStorageServices.label(data),
      region: presence(data["region"]),
      endpoint: presence(data["endpoint"])
    }
  end

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(_value), do: nil

  # Every bucket is probed, in order, and the first that fails ends it. With
  # several, the message names the bucket.
  defp probe_targets(targets, user_uuid, probe) do
    probe = probe || (&Storage.test_connection/1)

    Enum.reduce_while(targets, :ok, fn target, :ok ->
      case probe_owned(target, user_uuid, probe) do
        :ok -> {:cont, :ok}
        {:error, %Ecto.Changeset{}} = error -> {:halt, error}
        {:error, message} -> {:halt, {:error, label_failure(message, target, targets)}}
      end
    end)
  end

  defp label_failure(message, _target, [_single]), do: message

  defp label_failure(message, target, _several) when is_binary(message),
    do: "#{target["bucket_name"]}: #{message}"

  defp label_failure(message, _target, _several), do: message

  @doc """
  Checks the buckets for `scope`'s user to put a library on (what the form's "Test"
  asks, and what creating the library asks again): they may use their own
  storage at all, the fields pass `Bucket.owned_changeset/4` (an S3-protocol
  provider, their own integration, a host the server may reach), and a small
  object can be written, read back and deleted in each.

  `params` is what `create_user_library/3` takes under `"storage"`: a `"targets"`
  list, or one bucket flat. Returns `:ok`, `{:error, :not_allowed}`,
  `{:error, message}` from the bucket, or `{:error, %Ecto.Changeset{}}` for the
  fields. `:probe` replaces the network check (a function of the bucket params),
  for tests.
  """
  @spec probe_own_storage(Scope.t() | nil, map(), keyword()) ::
          :ok | {:error, :not_allowed | String.t() | Ecto.Changeset.t()}
  def probe_own_storage(scope, params, opts \\ []) do
    with true <- may_use_own_storage?(scope) || {:error, :not_allowed},
         user_uuid when is_binary(user_uuid) <- Scope.user_uuid(scope) || {:error, :not_allowed},
         {:ok, targets} <- storage_targets(stringify(params), user_uuid) do
      probe_targets(targets, user_uuid, Keyword.get(opts, :probe))
    end
  end

  @doc """
  The names of the buckets one of the user's integrations can see (S3's
  `ListBuckets`), for the form's "List buckets" button: `{:ok, names}` or
  `{:error, message}`. A key limited to one bucket is usually refused, and the
  message then says to type the name instead; that is not a broken integration.
  `:list` replaces the network call (a function of the bucket description), for
  tests.
  """
  @spec list_own_buckets(Scope.t() | nil, term(), keyword()) ::
          {:ok, [String.t()]} | {:error, :not_allowed | String.t()}
  def list_own_buckets(scope, integration_uuid, opts \\ []) do
    with true <- may_use_own_storage?(scope) || {:error, :not_allowed},
         user_uuid when is_binary(user_uuid) <- Scope.user_uuid(scope) || {:error, :not_allowed},
         %{} = summary <-
           integration_summary(user_uuid, integration_uuid) ||
             {:error, "That integration is not yours"} do
      described = %Storage.Bucket{
        name: "list",
        provider: summary.provider,
        region: summary.region,
        endpoint: summary.endpoint,
        integration_uuid: integration_uuid,
        owner_uuid: user_uuid
      }

      list = Keyword.get(opts, :list, &list_with_deadline/1)
      list.(described)
    end
  end

  # Under the same hard deadline as every connection check
  # (`Integrations.Probe`), which only carries text back: the names go through it
  # one to a line (a bucket name cannot hold a newline).
  defp list_with_deadline(bucket) do
    check = fn ->
      case S3.list_remote_buckets(bucket) do
        {:ok, names} -> {:ok, Enum.join(names, "\n")}
        {:error, _} = error -> error
      end
    end

    case Probe.run(check) do
      {:ok, names} when is_binary(names) -> {:ok, String.split(names, "\n", trim: true)}
      {:error, message} when is_binary(message) -> {:error, message}
      other -> {:error, "Could not list the buckets: #{inspect(other, limit: 3)}"}
    end
  end

  defp connection_snapshot(uuid, user_uuid) do
    case Integrations.get_integration_by_uuid(uuid, {:user, user_uuid}) do
      {:ok, %{provider: "object_storage", data: data}} ->
        connection_digest(data)

      _ ->
        nil
    end
  end

  defp connection_digest(data) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        Map.take(data, ~w(service access_key secret_key endpoint region account_id jurisdiction))
      )
    )
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

  # Inside the creation transaction: the buckets, their profile, then the library
  # pointed at it. Any failure rolls the whole library back.
  defp attach_own_storage(library, _user_uuid, nil), do: library

  defp attach_own_storage(library, user_uuid, %{mode: mode, targets: targets}) do
    with {:ok, buckets} <- create_owned_buckets(library, user_uuid, targets),
         {:ok, profile} <- Profiles.create_user_profile(user_uuid, buckets, mode),
         {:ok, library} <- Profiles.assign_user_profile(library, profile) do
      library
    else
      {:error, %Ecto.Changeset{} = changeset} -> repo().rollback({:storage, changeset})
      {:error, reason} -> repo().rollback(reason)
    end
  end

  # One bucket row per target, in order. The first carries the library's name;
  # the others a number after it (the name is never shown to the user).
  defp create_owned_buckets(library, user_uuid, targets) do
    uuids = targets |> Enum.map(& &1["integration_uuid"]) |> Enum.uniq() |> Enum.sort()

    with_connection_locks(uuids, fn ->
      unchanged? = Enum.all?(targets, &unchanged_connection?(&1, user_uuid))

      if unchanged? do
        insert_owned_buckets(library, user_uuid, targets)
      else
        {:error, :storage_changed}
      end
    end)
  end

  defp unchanged_connection?(target, user_uuid) do
    snapshot = connection_snapshot(target["integration_uuid"], user_uuid)
    snapshot != nil and snapshot == target["__connection_snapshot"]
  end

  defp with_connection_locks([], fun), do: fun.()

  defp with_connection_locks([uuid | rest], fun) do
    ConnectionLock.run(uuid, fn -> with_connection_locks(rest, fun) end)
  end

  defp insert_owned_buckets(library, user_uuid, targets) do
    targets
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {params, n}, {:ok, acc} ->
      name = if n == 1, do: library.name, else: "#{library.name} (#{n})"

      case Storage.create_owned_bucket(user_uuid, Map.put(params, "name", name)) do
        {:ok, bucket} -> {:cont, {:ok, [bucket | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, buckets} -> {:ok, Enum.reverse(buckets)}
      error -> error
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

  # ===== Public user libraries =====

  @doc """
  Whether a library is **public without sign-in**: a user library published for anonymous readers (`visibility: "site"`), not in the trash and not suspended. Anyone,
  signed in or not, may read what is in it (`can?/3` with `:read`,
  `can_read_library?/2`). Media is the site's own library, not a public one in this
  sense: its files have ordinary links but only their uploader and the admins may
  list them.

  Takes a library or a uuid.
  """
  @spec public?(Library.t() | term()) :: boolean()
  def public?(%Library{} = library),
    do: published?(library) and library.settings["public_audience"] != "authenticated"

  def public?(nil), do: false
  def public?(uuid), do: public?(get_library(uuid))

  @doc "Whether a user library is published, for anonymous or signed-in readers."
  def published?(%Library{kind: "user", visibility: "site", trashed_at: nil} = library),
    do: not suspended?(library)

  def published?(%Library{}), do: false
  def published?(nil), do: false
  def published?(uuid), do: published?(get_library(uuid))

  @doc "Whether a published library admits this visitor, including its signed-in-only audience."
  def audience_allows?(scope, %Library{} = library) do
    published?(library) and
      (library.settings["public_audience"] != "authenticated" or authenticated_reader?(scope))
  end

  def audience_allows?(_scope, _library), do: false

  @doc false
  def authenticated_reader?(%Scope{user: %{uuid: uuid, is_active: true}}) when is_binary(uuid),
    do: true

  def authenticated_reader?(_scope), do: false

  @doc "Whether an admin has suspended a (public) library: it then answers as private."
  @spec suspended?(Library.t() | nil) :: boolean()
  def suspended?(%Library{settings: %{"suspended" => true}}), do: true
  def suspended?(_library), do: false

  @doc """
  Whether `scope` may create a **public** library: `may_create_library?/1` and the
  `"storage.public_library"` permission. Nobody has that until the site grants it.
  """
  @spec may_create_public_library?(Scope.t() | nil) :: boolean()
  def may_create_public_library?(%Scope{} = scope) do
    may_create_library?(scope) and Scope.can?(scope, "storage.public_library")
  end

  def may_create_public_library?(_scope), do: false

  @doc """
  Whether `scope` (or nobody, `nil`) may see the library as a whole, to list it:
  anyone for a public library, otherwise an Owner/Admin or one of its members. The
  one question a feature built on a library (timeline, albums, map…) asks before it
  shows a library's contents; `can?/3` is the same question for one file.
  """
  @spec can_read_library?(Scope.t() | nil, Library.t() | nil) :: boolean()
  def can_read_library?(_scope, nil), do: false

  def can_read_library?(scope, %Library{} = library) do
    (is_nil(library.trashed_at) and audience_allows?(scope, library)) or
      (is_nil(library.trashed_at) and match?(%Scope{}, scope) and
         (Scope.system_role?(scope) or role(library, Scope.user_uuid(scope)) != nil))
  end

  @doc """
  Suspends a public library, for an Owner or Admin: it answers as private (expiring
  links, no anonymous reading) until `unsuspend_library/2`, with nothing deleted.
  The reason is kept with the entry in the history.
  """
  @spec suspend_library(Scope.t() | nil, Library.t(), String.t() | nil) ::
          {:ok, Library.t()} | {:error, :not_allowed}
  def suspend_library(scope, %Library{} = library, reason \\ nil) do
    if Scope.system_role?(scope) and library.kind == "user" and library.visibility == "site" do
      set_suspended(scope, library, true, reason, "storage.library_suspended")
    else
      {:error, :not_allowed}
    end
  end

  @doc "Lifts a suspension, for an Owner or Admin."
  @spec unsuspend_library(Scope.t() | nil, Library.t()) ::
          {:ok, Library.t()} | {:error, :not_allowed}
  def unsuspend_library(scope, %Library{} = library) do
    if Scope.system_role?(scope) and suspended?(library),
      do: set_suspended(scope, library, false, nil, "storage.library_unsuspended"),
      else: {:error, :not_allowed}
  end

  defp set_suspended(scope, library, suspended?, reason, action) do
    settings =
      if suspended? do
        Map.merge(library.settings || %{}, %{"suspended" => true, "suspended_reason" => reason})
      else
        Map.drop(library.settings || %{}, ["suspended", "suspended_reason"])
      end

    Audit.transaction(fn ->
      with {:ok, updated} <-
             library |> Ecto.Changeset.change(settings: settings) |> repo().update(),
           {:ok, _entry} <-
             Audit.log(
               action,
               "library",
               library.uuid,
               [actor_uuid: Scope.user_uuid(scope)],
               %{
                 "name" => library.name,
                 "owner_uuid" => to_string(library.owner_uuid),
                 "reason" => reason
               }
             ) do
        {:ok, updated}
      end
    end)
  end

  # ===== A personal library, made by the system for a host that wants one =====

  @personal_key "personal"
  @personal_name_default "My library"
  @public_key "personal_public"
  @public_name_default "Public"

  @doc """
  Gives `user_uuid` a private library of their own, once, on behalf of the host.

  **Nothing in PhoenixKit calls this**: whether accounts get such a library, when,
  and what it is called is the host's decision (a photo app may make one for every
  new account; most apps do not need it). This is only the part a host cannot do
  with the public API, because `create_user_library/3` is the user's own act and
  needs their permission and room under their limit.

  It is governed by the same switch as every user library
  (`user_libraries_enabled?/0`, off by default): while that is off it makes nothing
  and returns `{:error, :user_libraries_off}`.

  The system acts here, so it needs neither `may_create_library?/1` nor
  `user_library_limit/0`. The library is marked as the personal one, and a user is
  never given a second: one they have since renamed, or trashed, still counts, so
  deleting it is final. It is the user's default when they have no library yet, a
  private library on the site's storage like any made without a choice.

  `:name` is its name (default "My library"); when the user already has a live
  library of that name, a number is added.

  Returns `{:ok, %Library{}}` when one was made, `{:ok, :exists}` when the user
  already had theirs, or `{:error, reason}`.
  """
  @spec ensure_personal_library(String.t(), keyword()) ::
          {:ok, Library.t() | :exists} | {:error, :user_libraries_off | term()}
  def ensure_personal_library(user_uuid, opts \\ []) when is_binary(user_uuid) do
    if user_libraries_enabled?(),
      do: do_ensure_marked(user_uuid, @personal_key, "private", personal_name(opts[:name])),
      else: {:error, :user_libraries_off}
  end

  @doc """
  Gives `user_uuid` a **public** library of their own, once, on behalf of the host: the
  counterpart of `ensure_personal_library/2`, with the same rules (the host's decision, the
  `user_libraries_enabled?/0` switch, no permission and no room under the limit, never a second
  one, not even after the user trashed theirs), except:

    * it is public (`visibility: "site"`, `public?/1`): everything put in it is for anyone to
      see. The host that makes one for every account accepts that, and says so where the user
      uploads (the Photos uploader does);
    * it is never the user's default library. Make the personal one first, so that the user
      has a default that is private.

  `:name` is its name (default "Public"). Returns `{:ok, %Library{}}`, `{:ok, :exists}` or
  `{:error, reason}`. Making one is written to the history (`storage.library_published`), the
  same entry as a user publishing a library, with `"by" => "system"`.
  """
  @spec ensure_public_library(String.t(), keyword()) ::
          {:ok, Library.t() | :exists} | {:error, :user_libraries_off | term()}
  def ensure_public_library(user_uuid, opts \\ []) when is_binary(user_uuid) do
    if user_libraries_enabled?(),
      do:
        user_uuid
        |> do_ensure_marked(@public_key, "site", public_name(opts[:name]))
        |> tap(&log_published_by_system/1),
      else: {:error, :user_libraries_off}
  end

  defp log_published_by_system({:ok, %Library{} = library}) do
    Audit.log("storage.library_published", "library", library.uuid, [], %{
      "name" => library.name,
      "by" => "system"
    })

    :ok
  end

  defp log_published_by_system(_result), do: :ok

  # `key` marks the library in its settings; `visibility` is "private" or "site". The
  # personal one is the user's default when they have no library yet, the public one never.
  defp do_ensure_marked(user_uuid, key, visibility, base) do
    repo().transaction(fn ->
      lock_user(user_uuid)

      if marked_library?(user_uuid, key) do
        :exists
      else
        owned = count_owned(user_uuid)
        name = free_library_name(user_uuid, base)

        library =
          insert_owned(
            %{"name" => name, "visibility" => visibility},
            user_uuid,
            owned == 0 and key == @personal_key
          )

        library
        |> Ecto.Changeset.change(settings: Map.put(library.settings || %{}, key, true))
        |> repo().update!()
      end
    end)
  end

  defp personal_name(name) when is_binary(name) do
    if String.trim(name) == "", do: @personal_name_default, else: String.trim(name)
  end

  defp personal_name(_name), do: @personal_name_default

  defp public_name(name) when is_binary(name) do
    if String.trim(name) == "", do: @public_name_default, else: String.trim(name)
  end

  defp public_name(_name), do: @public_name_default

  defp marked_library?(user_uuid, key) do
    repo().exists?(
      from(l in Library,
        where:
          l.kind == "user" and l.owner_uuid == ^user_uuid and
            fragment("(?->>?) = 'true'", l.settings, ^key)
      )
    )
  end

  # `base`, or `base 2`, `base 3`… when the user already has a live library of that name.
  defp free_library_name(user_uuid, base) do
    taken =
      from(l in Library,
        where: l.kind == "user" and l.owner_uuid == ^user_uuid and is_nil(l.trashed_at),
        select: fragment("lower(?)", l.name)
      )
      |> repo().all()
      |> MapSet.new()

    Enum.find_value(Stream.concat([base], Stream.map(2..1000, &"#{base} #{&1}")), base, fn name ->
      not MapSet.member?(taken, String.downcase(name)) && name
    end)
  end

  @doc """
  `ensure_personal_library/2` for every active, non-guest, non-API account, for a
  host that wants the accounts that existed before it started making them to have
  one too. Safe to repeat. Takes the same `:name`. Returns the counts
  `%{created: n, existing: n, failed: n}`, or `{:error, :user_libraries_off}` while
  user libraries are off (nothing is made).
  """
  @spec backfill_personal_libraries(keyword()) ::
          %{created: non_neg_integer(), existing: non_neg_integer(), failed: non_neg_integer()}
          | {:error, :user_libraries_off}
  def backfill_personal_libraries(opts \\ []) do
    if user_libraries_enabled?(),
      do: do_backfill(&ensure_personal_library/2, opts),
      else: {:error, :user_libraries_off}
  end

  @doc """
  `ensure_public_library/2` for every active, non-guest, non-API account: the counterpart of
  `backfill_personal_libraries/1`, with the same counts and the same `:name` option. Safe to repeat.
  """
  @spec backfill_public_libraries(keyword()) ::
          %{created: non_neg_integer(), existing: non_neg_integer(), failed: non_neg_integer()}
          | {:error, :user_libraries_off}
  def backfill_public_libraries(opts \\ []) do
    if user_libraries_enabled?(),
      do: do_backfill(&ensure_public_library/2, opts),
      else: {:error, :user_libraries_off}
  end

  defp do_backfill(ensure, opts) do
    from(u in User,
      where:
        u.is_active and not u.api_only and
          fragment("coalesce(?->>'source', '') <> 'guest_checkout'", u.custom_fields),
      select: u.uuid
    )
    |> repo().all()
    |> Enum.reduce(%{created: 0, existing: 0, failed: 0}, fn uuid, counts ->
      case ensure.(uuid, opts) do
        {:ok, :exists} -> Map.update!(counts, :existing, &(&1 + 1))
        {:ok, %Library{}} -> Map.update!(counts, :created, &(&1 + 1))
        {:error, _reason} -> Map.update!(counts, :failed, &(&1 + 1))
      end
    end)
  end

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

    if reserved_slug?(slug) and n < 100,
      do: restore_with_free_slug(library, base, n + 1, default?),
      else: restore_with_slug(library, base, n, slug, default?)
  end

  defp restore_with_slug(library, base, n, slug, default?) do
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
          Enum.all?(own, fn {_uuid, %{buckets: buckets}} ->
            Enum.all?(buckets, fn %{bucket: bucket} ->
              match?(
                {key, secret}
                when is_binary(key) and key != "" and is_binary(secret) and secret != "",
                S3.resolve_credentials(bucket)
              )
            end)
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
  defp purge_file(file, false), do: purge_row(file)

  defp purge_file(file, true) do
    case Storage.delete_file_data(file) do
      result when result == :ok or result == {:error, "No file instances found"} ->
        purge_row(file)

      {:error, _reason} ->
        false
    end
  end

  # A file that is gone already counts as deleted; a refusal (a managed file,
  # a failed delete) does not, or the library would be removed under a live row.
  defp purge_row(file) do
    case Storage.delete_file_completely(file) do
      {:ok, _} ->
        true

      {:error, :not_found} ->
        true

      {:error, reason} ->
        Logger.warning("Storage: purging file #{file.uuid} refused: #{inspect(reason)}")
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
