defmodule PhoenixKit.Modules.Storage do
  @moduledoc """
  Storage context for managing files, buckets, and dimensions.

  Provides a distributed file storage system with support for multiple storage providers
  (local filesystem, AWS S3, Backblaze B2, Cloudflare R2) with automatic redundancy
  and failover capabilities.

  ## Features

  - Multi-location storage with configurable redundancy (1-5 copies)
  - Support for local, S3, B2, and R2 storage providers
  - Automatic variant generation for images and videos
  - Priority-based storage selection
  - Built-in usage tracking and statistics
  - PostgreSQL-backed file registry

  ## Folder conventions for modules

  Modules that keep one folder per record (catalogue items, warehouse
  documents, CRM records, machines, …) build on
  `PhoenixKit.Modules.Storage.ResourceFolders`, which holds the convention:
  the `:attachments_parent_folder` / `:attachments_folder_name` host hooks
  (`fun(kind, actor_uuid, subject)`, with the `fun/2` fallback), the lookup
  order (stored pointer → host name under the parent → deterministic
  `<module>-<kind>-<uuid>` name under the parent, at the root, anywhere),
  race-safe find-or-create, and attaching, listing and detaching files.
  Moving or renaming existing folders stays with the host (adoption is a
  host concern), and nothing creates folders for people's own use.

  Hosts typically group containers (`Warehouse/Supplier orders`, `CRM/Contacts`)
  and may re-parent a container that was created elsewhere; `update_folder/3`
  with `parent_uuid` moves a folder (with cycle check), and the
  `(name, parent_uuid)` unique index means the same name can exist under
  different parents.

  ## Protecting host-owned files

  Orphan detection (`find_orphaned_files/1`, `count_orphaned_files/1`,
  `file_orphaned?/1`, and the `mix phoenix_kit.cleanup_orphaned_files` /
  `DeleteOrphanedFileJob` pipeline built on them) only knows about the
  references core itself ships with. A host whose own tables point at
  files — an order, a project, any record with an image or attachment
  column — is one cleanup run away from losing them unless it registers
  itself through one of two hooks:

  - `config :phoenix_kit, :protected_file_uuids, [...]` — a fixed list, a
    zero-arity function, or an `{module, function, args}` MFA returning the
    uuids that must never be treated as orphans. Simple, but the host has
    to enumerate every referenced uuid on every query.
  - `config :phoenix_kit, :file_reference_sources, [...]` — a list of
    `{module, function}` / `{module, function, args}` entries, each
    returning a list of `Ecto.Query.dynamic/2` expressions over the file
    binding `f`. Every expression is ANDed onto the orphan query's
    `where` verbatim, so **each one must itself be the negative test** —
    a `NOT EXISTS (...)` fragment, the same shape core's own catalogue
    and shop checks use (see the example below). Core does not wrap or
    negate anything: a positively-phrased `EXISTS (...)` expression
    inverts the meaning and marks exactly the referenced files as the
    orphans.
    A plain `{table, column}` tuple is shorthand for a native column
    reference, and `{table, :jsonb_key, key}` for a `data->>'key'` pointer.
    A source that cannot be built — its table does not exist, its function
    raises, the entry is malformed — **fails closed**: a `Logger.error/1`
    names it and no file is treated as orphaned until it is fixed. Skipping
    it would drop that source's guard and hand cleanup every file only the
    host references.

  Example:

      config :phoenix_kit, :file_reference_sources, [
        {MyApp.Media, :file_reference_sources}
      ]

      def file_reference_sources do
        [
          dynamic(
            [f],
            fragment(
              "NOT EXISTS (SELECT 1 FROM my_app_orders o WHERE o.data->>'featured_image_uuid' = ?::text)",
              f.uuid
            )
          )
        ]
      end

  ## Module Status

  This module is **always enabled** and cannot be disabled. It provides core
  functionality for file management across PhoenixKit.
  """

  use PhoenixKit.Module

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Integrations.Probe
  alias PhoenixKit.Utils.Date, as: UtilsDate

  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.BucketLog
  alias PhoenixKit.Modules.Storage.CaptureDate
  alias PhoenixKit.Modules.Storage.Dimension
  alias PhoenixKit.Modules.Storage.Endpoint
  alias PhoenixKit.Modules.Storage.FileDetails
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.FileLocation
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKit.Modules.Storage.FolderLink
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Library
  alias PhoenixKit.Modules.Storage.Locations
  alias PhoenixKit.Modules.Storage.Manager
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Modules.Storage.ProviderRegistry
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.Modules.Storage.RemoteFetch
  alias PhoenixKit.Modules.Storage.Shape
  alias PhoenixKit.Modules.Storage.Sniff
  alias PhoenixKit.Modules.Storage.StorageProfile
  # NOTE: Temporary helper for Publishing component system.
  # The dedicated storage/media APIs under development should replace this fallback once available.
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Modules.Storage.VariantSet
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Modules.Storage.Workers.ReconcileJob
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.TreeQuery

  @default_path "priv/uploads"

  # PubSub topic for file lifecycle events (see subscribe_to_file_events/0).
  @files_topic "phoenix_kit:media:files"

  # ===== MODULE STATUS =====

  @doc """
  What a downloaded copy of `file` should be called, for `variant`.

  Every variant of a picture used to answer with the uploader's own
  filename, so a browser saving three of them ended up with `photo.jpg`,
  `photo (1).jpg`, `photo (2).jpg` — three files whose only difference was
  a number the desktop assigned, and nothing to say which was which.

  The name says which copy it is: `photo-large.jpg`, `photo-original.jpg`,
  and for the copies with the annotations drawn in,
  `photo-large-annotated.jpg`. `ext` comes from the stored instance rather
  than from the URL — a signed URL ends in a token, and a burn is a JPEG
  even where the picture it was drawn on is a PNG.
  """
  @spec download_name(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def download_name(file_name, variant, ext) do
    base =
      (file_name || "download")
      |> Path.basename()
      |> Path.rootname()

    ext =
      case ext do
        "." <> _ = dotted -> dotted
        e when is_binary(e) and e != "" -> "." <> e
        _ -> Path.extname(file_name || "")
      end

    base <> download_suffix(variant) <> ext
  end

  # The burn slots are named by what they are — a size, with the markup in
  # it — rather than by the slot that holds them.
  defp download_suffix("burned"), do: "-medium-annotated"
  defp download_suffix("burned_large"), do: "-large-annotated"
  defp download_suffix("thumbnail_annotated"), do: "-thumbnail-annotated"
  defp download_suffix(variant) when is_binary(variant) and variant != "", do: "-" <> variant
  defp download_suffix(_), do: ""

  @doc """
  Checks if the Storage module is enabled.

  This module is always enabled and cannot be disabled.

  ## Examples

      iex> PhoenixKit.Modules.Storage.module_enabled?()
      true
  """
  def module_enabled?, do: true

  # ===== FILE EVENTS (PubSub) =====

  @doc """
  Subscribes the current process to file lifecycle events.

  Messages delivered:

    * `{:phoenix_kit_file_processed, file_uuid}` — background processing
      finished for the file (dimensions extracted, variants generated —
      or processing failed; reload the row to see which). Broadcast by
      `PhoenixKit.Modules.Storage.ProcessFileJob` so open UIs can refresh
      a just-uploaded file without a page reload.

    * `{:phoenix_kit_file_thumbnail_updated, file_uuid}` — how the file's
      thumbnail should render changed: its baked annotated variant was
      regenerated/removed (`AnnotationThumbnailJob`), or its saved
      rotation moved (`MediaCanvasViewer`, which thumbnails apply as a CSS
      transform). Lighter than `file_processed`: consumers should refresh
      thumbnails only, not remount open viewers — the user is usually
      still working in one, and it is what emitted the change.

    * `{:phoenix_kit_file_trashed, file_uuid}` — the file was moved to
      trash (`trash_file/1`, or a `trash_folder/2` that swept it up).
      Consumers showing the active (non-trash) view should stop showing
      it; an open viewer on it should close.

    * `{:phoenix_kit_file_restored, file_uuid}` — the file was taken out
      of trash (`restore_file/1`, or a `restore_folder/2`). Consumers
      showing the trash view should stop showing it.

    * `{:phoenix_kit_file_deleted, file_uuid}` — the file was permanently
      deleted (`delete_file_completely/1`). Consumers should drop it
      wherever it is rendered and close an open viewer on it.

    * `{:phoenix_kit_files_trashed | :phoenix_kit_files_restored |
      :phoenix_kit_files_deleted, [file_uuid]}` — the same three, for every
      file a FOLDER operation swept up at once (`trash_folder/2`,
      `restore_folder/2`, `delete_folder_completely/2`), sent once per
      operation rather than once per file: a folder of thousands of files
      would otherwise be thousands of messages, and as many re-renders, for
      every subscriber. A consumer that reacts to one file must match both
      shapes (`uuid in uuids` for the bulk one).
  """
  def subscribe_to_file_events do
    PhoenixKit.PubSub.Manager.subscribe(@files_topic)
  end

  @doc """
  Broadcasts that background processing finished for `file_uuid`.

  See `subscribe_to_file_events/0` for the message shape.
  """
  def broadcast_file_processed(file_uuid) when is_binary(file_uuid) do
    PhoenixKit.PubSub.Manager.broadcast(@files_topic, {:phoenix_kit_file_processed, file_uuid})
  end

  @doc """
  Broadcasts that how `file_uuid`'s thumbnail should render changed (a
  rebaked annotated variant, or a new saved rotation).

  See `subscribe_to_file_events/0` for the message shape.
  """
  def broadcast_file_thumbnail_updated(file_uuid) when is_binary(file_uuid) do
    PhoenixKit.PubSub.Manager.broadcast(
      @files_topic,
      {:phoenix_kit_file_thumbnail_updated, file_uuid}
    )
  end

  @doc """
  Broadcasts that `file_uuid` was moved to trash.

  See `subscribe_to_file_events/0` for the message shape.
  """
  def broadcast_file_trashed(file_uuid) when is_binary(file_uuid) do
    PhoenixKit.PubSub.Manager.broadcast(@files_topic, {:phoenix_kit_file_trashed, file_uuid})
  end

  @doc """
  Broadcasts that `file_uuid` was taken out of trash.

  See `subscribe_to_file_events/0` for the message shape.
  """
  def broadcast_file_restored(file_uuid) when is_binary(file_uuid) do
    PhoenixKit.PubSub.Manager.broadcast(@files_topic, {:phoenix_kit_file_restored, file_uuid})
  end

  @doc """
  Broadcasts that `file_uuid` was permanently deleted.

  See `subscribe_to_file_events/0` for the message shape.
  """
  def broadcast_file_deleted(file_uuid) when is_binary(file_uuid) do
    PhoenixKit.PubSub.Manager.broadcast(@files_topic, {:phoenix_kit_file_deleted, file_uuid})
  end

  @doc """
  Broadcasts that the files in `file_uuids` were moved to trash by one folder
  operation. Nothing is sent for an empty list.

  See `subscribe_to_file_events/0` for the message shape.
  """
  def broadcast_files_trashed(file_uuids),
    do: broadcast_files(:phoenix_kit_files_trashed, file_uuids)

  @doc """
  Broadcasts that the files in `file_uuids` were taken out of trash by one
  folder operation. Nothing is sent for an empty list.
  """
  def broadcast_files_restored(file_uuids),
    do: broadcast_files(:phoenix_kit_files_restored, file_uuids)

  @doc """
  Broadcasts that the files in `file_uuids` were permanently deleted by one
  folder operation. Nothing is sent for an empty list.
  """
  def broadcast_files_deleted(file_uuids),
    do: broadcast_files(:phoenix_kit_files_deleted, file_uuids)

  defp broadcast_files(_event, []), do: :ok

  defp broadcast_files(event, file_uuids) when is_list(file_uuids),
    do: PhoenixKit.PubSub.Manager.broadcast(@files_topic, {event, file_uuids})

  # ===== BUCKETS =====

  @doc """
  Returns the site's storage buckets, ordered by name.

  A user's own bucket (V206, `owner_uuid` set) is **not** here: everything
  that enumerates the site's storage (placement, the read fallback, the
  location backfill, Health, the admin list) goes through this function or
  `list_enabled_buckets/0`, so a user's bucket never reaches any of it. Use
  `list_owned_buckets/1` for a user's own.
  """
  def list_buckets do
    Bucket
    |> where([b], is_nil(b.owner_uuid))
    |> order_by([b], asc: fragment("lower(?)", b.name), asc: b.inserted_at)
    |> repo().all()
  end

  @doc """
  A user's own buckets (V206), oldest first.
  """
  @spec list_owned_buckets(String.t() | nil) :: [Bucket.t()]
  def list_owned_buckets(owner_uuid) when is_binary(owner_uuid) do
    Bucket
    |> where([b], b.owner_uuid == ^owner_uuid)
    |> order_by(asc: :inserted_at)
    |> repo().all()
  end

  def list_owned_buckets(_owner_uuid), do: []

  @doc """
  The buckets with these uuids, whoever owns them. For resolving the buckets a
  file's location rows name: the read path must reach a user's own bucket
  although the site's listings leave it out.
  """
  @spec get_buckets([String.t()]) :: [Bucket.t()]
  def get_buckets([]), do: []

  def get_buckets(uuids) when is_list(uuids) do
    Bucket |> where([b], b.uuid in ^uuids) |> repo().all()
  end

  @doc """
  Gets a single bucket by ID.

  Returns `nil` if bucket does not exist. `secret_access_key` is returned
  as stored (encrypted, see `PhoenixKit.Integrations.Encryption`) — this
  accessor does not decrypt it. Decrypt only where the plaintext is
  actually needed (e.g. `Providers.S3.resolve_credentials/1`).
  """
  def get_bucket(id), do: repo().get(Bucket, id)

  @doc """
  Gets a site bucket by id, or nil: a user's own bucket (V206) is not one, and is
  not found here. The site's bucket screens load through this, so an id of a
  user's bucket cannot be edited, toggled or deleted from them.
  """
  @spec get_site_bucket(term()) :: Bucket.t() | nil
  def get_site_bucket(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        repo().one(from(b in Bucket, where: b.uuid == ^uuid and is_nil(b.owner_uuid)))

      :error ->
        nil
    end
  end

  @doc """
  Gets a bucket by name.
  """
  def get_bucket_by_name(name) do
    repo().get_by(Bucket, name: name)
  end

  @doc """
  How many buckets use each Integrations connection, as `%{connection_uuid => count}`.

  Removing a connection does not check who uses it (a missing one fails loudly
  at the next use), so the Integrations pages read this to say so before it
  happens.
  """
  @spec bucket_counts_by_connection() :: %{String.t() => pos_integer()}
  def bucket_counts_by_connection do
    Bucket
    |> where([b], not is_nil(b.integration_uuid))
    |> group_by([b], b.integration_uuid)
    |> select([b], {b.integration_uuid, count(b.uuid)})
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Whether any enabled bucket exists, the site's or a user's own (V206): what
  the upload screens ask before offering an upload. A site with no bucket of
  its own may still let users keep libraries on their own storage. (The upload
  that follows still picks the library's own buckets; this only answers "is
  there anywhere at all".)
  """
  @spec buckets_available?() :: boolean()
  def buckets_available? do
    repo().exists?(from(b in Bucket, where: b.enabled == true))
  end

  @doc """
  Gets the site's enabled buckets, ordered by priority. A user's own bucket is
  not here (see `list_buckets/0`).
  """
  def list_enabled_buckets do
    Bucket
    |> where([b], b.enabled == true and is_nil(b.owner_uuid))
    |> order_by(asc: :priority)
    |> repo().all()
  end

  @doc """
  Creates a new bucket.

  Option `:profile` says where the bucket is placed: `:default` (when not given)
  puts it in the Default storage profile; `nil` leaves it in no profile, so it is
  known to the system but receives and serves nothing until a profile lists it;
  a uuid puts it in that site profile as a primary (`Profiles.add_bucket/3`,
  recorded in the history). The settings form offers the choice, defaulting to none.
  The other options are the audit's (`:actor_uuid`).

  ## Examples

      iex> create_bucket(%{name: "Local Storage", provider: "local"})
      {:ok, %Bucket{}}

      iex> create_bucket(%{name: "Cold", provider: "local"}, profile: nil)
      {:ok, %Bucket{}}

      iex> create_bucket(%{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_bucket(attrs \\ %{}, opts \\ []) do
    Audit.transaction(fn -> do_create_bucket(attrs, opts) end)
  end

  defp do_create_bucket(attrs, opts) do
    # Where the new bucket is placed is the caller's choice (`:profile`); with
    # none given it joins the Default storage profile, as every new bucket
    # joined the one pool before profiles (V205).
    {profile, opts} = Keyword.pop(opts, :profile, :default)

    repo().transaction(fn ->
      with {:ok, bucket} <- %Bucket{} |> Bucket.changeset(attrs) |> repo().insert(),
           :ok <- place_new_bucket(bucket, profile, opts) do
        bucket
      else
        {:error, %Ecto.Changeset{} = changeset} -> repo().rollback(changeset)
      end
    end)
    |> tap(&bucket_changed/1)
    |> tap(fn
      {:ok, bucket} ->
        audit_bucket("storage.bucket.created", bucket, opts, %{
          "name" => bucket.name,
          "provider" => bucket.provider,
          "enabled" => bucket.enabled
        })

      _error ->
        :ok
    end)
  end

  # `:default` joins the Default profile (the long-standing behaviour); nil or ""
  # leaves the bucket in no profile (known to the system, nothing written to
  # it); a uuid puts it in that site profile, on the record.
  defp place_new_bucket(bucket, :default, _opts), do: Profiles.add_to_default(bucket)
  defp place_new_bucket(_bucket, profile, _opts) when profile in [nil, ""], do: :ok

  defp place_new_bucket(bucket, profile_uuid, opts) do
    case Profiles.add_bucket(profile_uuid, bucket, opts) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:error,
         bucket
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:profile, "is not one of the site's storage profiles")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  # The site's buckets are in the history; a user's own bucket is theirs and private.
  # Never a key or a secret: `Audit.bucket_fields/0` is the whole list of what is named.
  defp audit_bucket(action, %Bucket{owner_uuid: nil} = bucket, opts, metadata) do
    Audit.log(action, "storage_bucket", bucket.uuid, opts, metadata)
    :ok
  end

  defp audit_bucket(_action, _bucket, _opts, _metadata), do: :ok

  @doc """
  Creates a user's own bucket (V206).

  Through `Bucket.owned_changeset/4`, which fixes everything a user must not
  choose: the owner (this function's argument, never `attrs`), an S3-protocol
  provider, `signed` access, the owner's own connection for the keys. The
  bucket does **not** join the Default storage profile (it is nobody's but its
  owner's); put it in one with `Profiles.create_user_profile/3`.
  """
  @spec create_owned_bucket(String.t(), map()) :: {:ok, Bucket.t()} | {:error, Ecto.Changeset.t()}
  def create_owned_bucket(owner_uuid, attrs) when is_binary(owner_uuid) do
    %Bucket{}
    |> Bucket.owned_changeset(attrs, owner_uuid,
      connection_owned?: &owns_connection?(owner_uuid, &1)
    )
    |> repo().insert()
    |> tap(&bucket_changed/1)
  end

  # Whether `owner_uuid` owns the Object Storage connection `uuid`: the lookup
  # is owner-scoped, so another user's (or a site) connection is "not found".
  @doc false
  def owns_connection?(owner_uuid, uuid) do
    match?(
      {:ok, %{provider: "object_storage"}},
      PhoenixKit.Integrations.get_integration_by_uuid(uuid, {:user, owner_uuid})
    )
  end

  @doc """
  Updates a bucket.

  Disabling one of the site's buckets is refused with
  `{:error, {:in_use, usage}}` while any storage profile lists it
  (`Profiles.bucket_usage/1` describes `usage`): a disabled bucket is neither
  written nor read, which would strand the libraries on those profiles. Take it
  out of the profiles first. Enabling is always allowed.

  ## Examples

      iex> update_bucket(bucket, %{name: "New Name"})
      {:ok, %Bucket{}}

      iex> update_bucket(bucket, %{name: nil})
      {:error, %Ecto.Changeset{}}

      iex> update_bucket(bucket_in_a_profile, %{enabled: false})
      {:error, {:in_use, [%{name: "Default", ...}]}}

  """
  @spec update_bucket(Bucket.t(), map(), keyword()) ::
          {:ok, Bucket.t()} | {:error, Ecto.Changeset.t() | :not_found | {:in_use, [map()]}}
  def update_bucket(%Bucket{} = bucket, attrs, opts \\ []) do
    Audit.change(bucket, &do_update_bucket(&1, attrs, opts))
  end

  defp do_update_bucket(bucket, attrs, opts) do
    changeset = bucket_update_changeset(bucket, attrs)

    with :ok <- refuse_disable_while_in_profiles(bucket, changeset) do
      update_bucket_row(changeset, opts)
    end
  end

  # A disabled bucket is neither written nor read, whatever its profiles say,
  # so disabling one a profile lists would strand the libraries on it. Refused
  # until the admin has taken it out of every profile. Only the site's buckets:
  # a user's own bucket belongs to their library and goes with it. Enabling is
  # always allowed.
  defp refuse_disable_while_in_profiles(
         %Bucket{enabled: true, owner_uuid: nil} = bucket,
         changeset
       ) do
    if Map.get(changeset.changes, :enabled) == false,
      do: refuse_while_in_profiles(bucket),
      else: :ok
  end

  defp refuse_disable_while_in_profiles(_bucket, _changeset), do: :ok

  defp update_bucket_row(changeset, opts) do
    repo().transaction(fn ->
      case repo().update(changeset) do
        {:ok, updated} ->
          updated

        {:error, changeset} ->
          repo().rollback(changeset)
      end
    end)
    |> tap(&bucket_changed/1)
    |> tap(fn
      {:ok, updated} ->
        changes = Audit.changes(changeset, Audit.bucket_fields())

        unless changes == %{},
          do:
            audit_bucket("storage.bucket.updated", updated, opts, %{
              "name" => updated.name,
              PhoenixKit.Activity.changes_key() => changes
            })

      _error ->
        :ok
    end)
  end

  # A user's own bucket is edited under the rules it was created under (its
  # owner's connection, the personal endpoint policy, an S3-protocol provider),
  # not the site's: the general changeset knows none of them.
  defp bucket_update_changeset(%Bucket{owner_uuid: owner} = bucket, attrs)
       when is_binary(owner) do
    Bucket.owned_changeset(bucket, attrs, owner, connection_owned?: &owns_connection?(owner, &1))
  end

  defp bucket_update_changeset(%Bucket{} = bucket, attrs), do: Bucket.changeset(bucket, attrs)

  @doc """
  Deletes a bucket.

  Refused with `{:error, {:in_use, usage}}` while any storage profile lists it
  (`Profiles.bucket_usage/1` describes `usage`), and with a changeset error on
  `:file_locations` while it still holds files. Nothing is removed from a
  profile on the way: the bucket has to be freed first.

  ## Examples

      iex> delete_bucket(bucket)
      {:ok, %Bucket{}}

      iex> delete_bucket(bucket_in_a_profile)
      {:error, {:in_use, [%{name: "Default", ...}]}}

      iex> delete_bucket(bucket_with_files)
      {:error, %Ecto.Changeset{}}

  """
  @spec delete_bucket(Bucket.t(), keyword()) ::
          {:ok, Bucket.t()} | {:error, Ecto.Changeset.t() | :not_found | {:in_use, [map()]}}
  def delete_bucket(%Bucket{} = bucket, opts \\ []) do
    Audit.change(bucket, &do_delete_bucket(&1, opts))
  end

  defp do_delete_bucket(bucket, opts) do
    # A bucket a storage profile still lists is refused, and so is one that
    # still holds files (V204: the location FK is RESTRICT); before, deleting
    # it dropped every location row it had and left its objects behind, and an
    # empty one was silently taken out of every profile, which could leave a
    # library with nowhere to write. The admin frees it from its profiles
    # first, on purpose and on the record. The profile-row FK is RESTRICT too,
    # so a profile that takes the bucket in between is refused by the database.
    with :ok <- refuse_while_in_profiles(bucket) do
      repo().transaction(fn ->
        bucket
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.no_assoc_constraint(:file_locations,
          name: :phoenix_kit_file_locations_bucket_id_fkey,
          message: "still holds files"
        )
        |> Ecto.Changeset.foreign_key_constraint(:uuid,
          name: :phoenix_kit_storage_profile_buckets_bucket_fkey,
          message: "is used by a storage profile"
        )
        |> repo().delete()
        |> case do
          {:ok, deleted} -> deleted
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)
      |> tap(&bucket_changed/1)
      |> tap(fn
        {:ok, deleted} ->
          audit_bucket("storage.bucket.deleted", deleted, opts, %{"name" => deleted.name})
          BucketLog.delete_for_bucket(deleted.uuid)

        _error ->
          :ok
      end)
    end
  end

  # `{:error, {:in_use, usage}}` while any storage profile has a row for the
  # bucket (`Profiles.bucket_usage/1` says which, and how many libraries stand
  # behind each).
  defp refuse_while_in_profiles(%Bucket{uuid: uuid}) do
    case Map.get(Profiles.bucket_usage([uuid]), to_string(uuid), []) do
      [] -> :ok
      usage -> {:error, {:in_use, usage}}
    end
  end

  # The manager keeps the enabled buckets in a cache; a bucket that was
  # added, edited or removed must apply at once, not when it expires.
  defp bucket_changed({:ok, _bucket}),
    do: Audit.after_commit(&Manager.invalidate_bucket_cache/0)

  defp bucket_changed(_result), do: :ok

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking bucket changes.
  """
  def change_bucket(%Bucket{} = bucket, attrs \\ %{}) do
    Bucket.changeset(bucket, attrs)
  end

  @doc """
  Tests connectivity for a bucket configuration.

  Builds a temporary Bucket struct from the given params and delegates
  to the appropriate provider's `test_connection/1` callback.

  Returns `:ok` or `{:error, reason}`.
  """
  def test_connection(bucket_params) when is_map(bucket_params) do
    bucket = build_probe_bucket(bucket_params)

    with :ok <- check_probe_provider(bucket),
         :ok <- check_endpoint(bucket),
         {:ok, provider_module} <- ProviderRegistry.get_provider(bucket.provider) do
      probe(provider_module, bucket)
    end
  rescue
    error -> {:error, "Connection test failed: #{Exception.message(error)}"}
  end

  @doc """
  Probes a saved bucket: the same write, read and delete of a real object as
  `test_connection/1`, run from the stored row so no secret passes through the
  caller's assigns. Returns `:ok` or `{:error, reason}`. The result and how long
  it took go to the bucket's log (`Storage.BucketLog`) when it is a site bucket.
  """
  @spec probe_bucket(Bucket.t()) :: :ok | {:error, term()}
  def probe_bucket(%Bucket{} = bucket) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        with :ok <- check_probe_provider(bucket),
             :ok <- check_endpoint(bucket),
             {:ok, provider_module} <- ProviderRegistry.get_provider(bucket.provider) do
          probe(provider_module, bucket)
        end
      rescue
        error -> {:error, BucketLog.safe_message(error)}
      catch
        :exit, _ -> {:error, "Connection test exited"}
      end

    BucketLog.record(bucket, "probe", result == :ok,
      latency_ms: System.monotonic_time(:millisecond) - started,
      message: probe_message(result)
    )

    result
  end

  defp probe_message(:ok), do: nil
  defp probe_message({:error, reason}), do: BucketLog.safe_message(reason)
  defp probe_message(other), do: BucketLog.safe_message(other)

  # A local bucket's check is a few file operations; a remote one talks to the
  # network, through a client that retries, so it runs in `Integrations.Probe`:
  # isolated from the caller and under a hard deadline.
  defp probe(provider_module, %Bucket{provider: "local"} = bucket),
    do: provider_module.test_connection(bucket)

  defp probe(provider_module, bucket),
    do: Probe.run(fn -> provider_module.test_connection(bucket) end)

  # A user's own bucket is an S3-protocol bucket or nothing: the `local` provider
  # would create and delete files in a directory of the server's choosing. The
  # owner is set by the caller from the signed-in user, never from a form.
  defp check_probe_provider(%Bucket{owner_uuid: owner, provider: provider})
       when is_binary(owner) and provider not in ~w(s3 b2 r2 tigris),
       do: {:error, "Your own storage must be an S3-compatible bucket"}

  defp check_probe_provider(_bucket), do: :ok

  # The endpoint a probe is about to connect to, looked up and checked here (a
  # hostname is resolved: this is a save/test path, not a per-request one). A
  # local bucket's endpoint is a filesystem path, not a URL.
  defp check_endpoint(%Bucket{provider: "local"}), do: :ok

  defp check_endpoint(%Bucket{endpoint: endpoint, owner_uuid: owner_uuid}) do
    policy = if is_binary(owner_uuid), do: :personal, else: :system

    case Endpoint.check(endpoint, policy, resolve: true) do
      :ok -> :ok
      {:error, reason} -> {:error, "The endpoint " <> Endpoint.error_message(reason)}
    end
  end

  # Builds the throwaway %Bucket{} test_connection/1 probes with, before any
  # of it is saved. Threads every field `Providers.S3.resolve_credentials/1`
  # reads — including `integration_uuid`, so a bucket bound to an
  # Integrations connection is testable too, not just one with direct keys.
  #
  # Public and `@doc false` purely so this mapping is unit-testable without
  # the network call `test_connection/1` makes right after — same rationale
  # as `Providers.S3.resolve_credentials/1`.
  @doc false
  @spec build_probe_bucket(map()) :: Bucket.t()
  def build_probe_bucket(bucket_params) do
    %Bucket{
      name: bucket_params["name"] || "(unsaved bucket)",
      provider: bucket_params["provider"],
      region: bucket_params["region"],
      endpoint: bucket_params["endpoint"],
      bucket_name: bucket_params["bucket_name"],
      access_key_id: bucket_params["access_key_id"],
      secret_access_key: bucket_params["secret_access_key"],
      integration_uuid: bucket_params["integration_uuid"],
      # Set by the caller from the signed-in user, never from a form: it picks
      # the connections the probe may read and how strictly the endpoint is
      # checked.
      owner_uuid: bucket_params["owner_uuid"]
    }
  end

  @doc """
  Calculates storage usage for a bucket in MB.

  Returns total size of all files stored in this bucket by summing up all
  file instances that have locations in this bucket.
  """
  def calculate_bucket_usage(bucket_uuid) do
    # Each object once: a key shared by cross-user copies has one location
    # row per copy, but one object on the bucket.
    objects =
      from(fl in FileLocation,
        join: fi in FileInstance,
        on: fl.file_instance_uuid == fi.uuid,
        where: fl.bucket_uuid == ^bucket_uuid and fl.status == "active",
        distinct: fl.path,
        select: %{size: fi.size}
      )

    from(o in subquery(objects), select: fragment("SUM(?) / (1024.0 * 1024)", o.size))
    |> repo().one()
    |> case do
      nil -> 0
      total -> Decimal.to_float(total)
    end
  end

  @doc """
  Calculates free space for a bucket.

  For local storage, checks actual disk space.
  For cloud storage, returns the configured max_size_mb minus usage.
  """
  def calculate_bucket_free_space(%Bucket{} = bucket) do
    used_mb = calculate_bucket_usage(bucket.uuid)

    case bucket.provider do
      "local" ->
        calculate_local_free_space(bucket)

      _ ->
        # For cloud storage, use the configured max size
        max(bucket.max_size_mb - used_mb, 0)
    end
  end

  def calculate_bucket_free_space(bucket_uuid) when is_binary(bucket_uuid) do
    bucket = get_bucket(bucket_uuid)
    if bucket, do: calculate_bucket_free_space(bucket), else: 0
  end

  @doc """
  What a bucket holds, from its active location rows: `%{files, objects,
  bytes, original_objects, original_bytes, derived_objects, derived_bytes,
  libraries, personal}`.

  An object is counted once however many location rows name its key (cross-user
  copies share one). `libraries` lists the site's libraries that have files
  here (`%{uuid, name, files, objects, bytes}`, largest first). Shared keys
  count once in each library using them, but only once in the bucket totals.
  A user's libraries are private to them, so they are only counted in `personal`
  (`%{libraries, files, objects, bytes}`), never named.

  Reads every location row of the bucket: call it off the render path.
  """
  @spec bucket_contents(term()) :: map()
  def bucket_contents(bucket_uuid) do
    locations =
      from(fl in FileLocation,
        join: fi in FileInstance,
        on: fl.file_instance_uuid == fi.uuid,
        join: f in PhoenixKit.Modules.Storage.File,
        on: f.uuid == fi.file_uuid,
        where: fl.bucket_uuid == ^bucket_uuid and fl.status == "active",
        select: %{
          path: fl.path,
          size: fi.size,
          original: fi.variant_name == "original",
          file_uuid: f.uuid,
          library_uuid: f.library_uuid
        }
      )

    # Logical files must be counted before shared physical keys are collapsed.
    files_by_library =
      from(o in subquery(locations),
        group_by: o.library_uuid,
        select: {o.library_uuid, count(o.file_uuid, :distinct)}
      )
      |> repo().all()
      |> Map.new()

    objects =
      from(o in subquery(locations),
        group_by: [o.library_uuid, o.path],
        select: %{
          library_uuid: o.library_uuid,
          path: o.path,
          size: max(o.size),
          original: fragment("bool_or(?)", o.original)
        }
      )

    rows =
      objects
      |> bucket_object_totals(true)
      |> Enum.map(fn row ->
        Map.put(row, :files, Map.fetch!(files_by_library, row.library_uuid))
      end)

    # A shared key can belong to several libraries. Their rows describe each
    # library's usage; the bucket total counts the bytes on disk only once.
    totals =
      from(o in subquery(locations),
        group_by: o.path,
        select: %{
          path: o.path,
          size: max(o.size),
          original: fragment("bool_or(?)", o.original)
        }
      )
      |> bucket_object_totals(false)
      |> hd()

    libraries =
      from(l in Library,
        where: l.uuid in ^Enum.map(rows, & &1.library_uuid),
        select: {l.uuid, %{name: l.name, kind: l.kind}}
      )
      |> repo().all()
      |> Map.new(fn {uuid, info} -> {to_string(uuid), info} end)

    {personal, site} =
      Enum.split_with(rows, fn row ->
        match?(%{kind: "user"}, Map.get(libraries, to_string(row.library_uuid)))
      end)

    sum = fn rows, key -> rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end

    %{
      files: sum.(rows, :files),
      objects: totals.objects,
      bytes: totals.bytes,
      original_objects: totals.original_objects,
      original_bytes: totals.original_bytes,
      derived_objects: totals.objects - totals.original_objects,
      derived_bytes: totals.bytes - totals.original_bytes,
      libraries:
        site
        |> Enum.map(fn row ->
          %{
            uuid: row.library_uuid && to_string(row.library_uuid),
            name: get_in(libraries, [to_string(row.library_uuid), :name]),
            files: row.files,
            objects: row.objects,
            bytes: row.bytes
          }
        end)
        |> Enum.sort_by(&{-&1.bytes, &1.name || ""}),
      personal: %{
        libraries: length(personal),
        files: sum.(personal, :files),
        objects: sum.(personal, :objects),
        bytes: sum.(personal, :bytes)
      }
    }
  end

  @doc """
  The headline numbers of several buckets at once, for a list: `%{bucket_uuid
  => %{files, objects, bytes}}`, from active location rows, counted like
  `bucket_contents/1` (a file once however many of its variants are here, an
  object once however many rows name its key). A bucket holding nothing is
  absent from the map. Two queries however many buckets there are.
  """
  @spec bucket_totals([term()]) :: %{optional(String.t()) => map()}
  def bucket_totals([]), do: %{}

  def bucket_totals(bucket_uuids) when is_list(bucket_uuids) do
    from(fl in FileLocation,
      join: fi in FileInstance,
      on: fl.file_instance_uuid == fi.uuid,
      where: fl.bucket_uuid in ^bucket_uuids and fl.status == "active",
      select: %{
        bucket_uuid: fl.bucket_uuid,
        path: fl.path,
        size: fi.size,
        file_uuid: fi.file_uuid
      }
    )
    |> totals_by_bucket()
  end

  @doc """
  What one library holds in each bucket: `%{bucket_uuid => %{files, objects,
  bytes}}`, counted like `bucket_totals/1` over the library's files only. A
  bucket that holds nothing of it is absent. Two queries; call it off the
  render path.
  """
  @spec library_bucket_totals(term()) :: %{optional(String.t()) => map()}
  def library_bucket_totals(library_uuid) do
    from(fl in FileLocation,
      join: fi in FileInstance,
      on: fl.file_instance_uuid == fi.uuid,
      join: f in PhoenixKit.Modules.Storage.File,
      on: f.uuid == fi.file_uuid,
      where: f.library_uuid == ^library_uuid and fl.status == "active",
      select: %{
        bucket_uuid: fl.bucket_uuid,
        path: fl.path,
        size: fi.size,
        file_uuid: fi.file_uuid
      }
    )
    |> totals_by_bucket()
  end

  # `locations`: rows of `%{bucket_uuid, path, size, file_uuid}`.
  defp totals_by_bucket(locations) do
    files =
      from(l in subquery(locations),
        group_by: l.bucket_uuid,
        select: {l.bucket_uuid, count(l.file_uuid, :distinct)}
      )
      |> repo().all()
      |> Map.new(fn {uuid, count} -> {to_string(uuid), count} end)

    objects =
      from(l in subquery(locations),
        group_by: [l.bucket_uuid, l.path],
        select: %{bucket_uuid: l.bucket_uuid, size: max(l.size)}
      )

    from(o in subquery(objects),
      group_by: o.bucket_uuid,
      select: {o.bucket_uuid, count(), coalesce(sum(o.size), 0)}
    )
    |> repo().all()
    |> Map.new(fn {uuid, objects, bytes} ->
      key = to_string(uuid)
      {key, %{files: Map.get(files, key, 0), objects: objects, bytes: to_int(bytes)}}
    end)
  end

  defp bucket_object_totals(objects, by_library?) do
    query =
      from(o in subquery(objects),
        select: %{
          objects: count(o.path),
          bytes: coalesce(sum(o.size), 0),
          original_objects: filter(count(o.path), o.original),
          original_bytes: coalesce(filter(sum(o.size), o.original), 0)
        }
      )

    query =
      if by_library?,
        do:
          query
          |> group_by([o], o.library_uuid)
          |> select_merge([o], %{library_uuid: o.library_uuid}),
        else: query

    query
    |> repo().all()
    |> Enum.map(fn row ->
      %{row | bytes: to_int(row.bytes), original_bytes: to_int(row.original_bytes)}
    end)
  end

  @doc """
  How a bucket's location rows stand: `%{active, syncing, failed, deleted,
  last_verified_at}` (`last_verified_at` is the newest verification stamp of
  any row, or nil). A `failed` row is a copy that was not made.
  """
  @spec bucket_location_health(term()) :: map()
  def bucket_location_health(bucket_uuid) do
    by_status =
      from(fl in FileLocation,
        where: fl.bucket_uuid == ^bucket_uuid,
        group_by: fl.status,
        select: {fl.status, count(fl.uuid)}
      )
      |> repo().all()
      |> Map.new()

    last =
      repo().one(
        from(fl in FileLocation,
          where: fl.bucket_uuid == ^bucket_uuid,
          select: max(fl.last_verified_at)
        )
      )

    %{
      active: Map.get(by_status, "active", 0),
      syncing: Map.get(by_status, "syncing", 0),
      failed: Map.get(by_status, "failed", 0),
      deleted: Map.get(by_status, "deleted", 0),
      last_verified_at: last
    }
  end

  defp to_int(%Decimal{} = value), do: Decimal.to_integer(Decimal.round(value))
  defp to_int(value) when is_integer(value), do: value
  defp to_int(_value), do: 0

  # ===== DIMENSIONS =====

  @doc """
  Returns the dimensions (sizes) of a variant set, the Default when none is
  given, ordered by size (width x height).
  """
  def list_dimensions(variant_set_uuid \\ VariantSets.default_uuid()) do
    Dimension
    |> where([d], d.variant_set_uuid == ^variant_set_uuid)
    |> order_by(asc: :width, asc: :height)
    |> repo().all()
  end

  @doc """
  Returns the enabled dimensions of a variant set (the Default when none is
  given) for a specific file type.
  """
  def list_dimensions_for_type(file_type, variant_set_uuid \\ VariantSets.default_uuid())

  def list_dimensions_for_type(file_type, variant_set_uuid)
      when file_type in ["image", "video"] do
    Dimension
    |> where([d], d.variant_set_uuid == ^variant_set_uuid)
    |> where([d], d.enabled == true and (d.applies_to == ^file_type or d.applies_to == "both"))
    |> order_by(asc: :width, asc: :height)
    |> repo().all()
  end

  def list_dimensions_for_type(_, _), do: []

  @doc """
  Gets a single dimension by ID.
  """
  def get_dimension(id), do: repo().get(Dimension, id)

  @doc """
  Gets a dimension by name in a variant set (the Default when none is given).
  """
  def get_dimension_by_name(name, variant_set_uuid \\ VariantSets.default_uuid()) do
    repo().get_by(Dimension, name: name, variant_set_uuid: variant_set_uuid)
  end

  @doc """
  Resets the Default variant set's dimensions to the seeded values.
  Deletes its current dimensions and recreates the 14 default ones (4 image
  sizes that keep proportions, 3 smart-square image sizes, 3 panorama sizes made
  only for wide pictures, 4 video sizes). Other variant sets are left alone.
  """
  def reset_dimensions_to_defaults(opts \\ []) do
    Audit.transaction(fn -> do_reset_dimensions_to_defaults(opts) end)
  end

  defp do_reset_dimensions_to_defaults(opts) do
    repo().transaction(fn ->
      # Delete the Default set's dimensions; its files are checked against
      # the sizes put back (a size whose spec changed is remade, one that is
      # gone is removed).
      Dimension
      |> where([d], d.variant_set_uuid == ^VariantSets.default_uuid())
      |> repo().delete_all()

      VariantSets.bump_revision(VariantSets.default_uuid())

      # Insert default dimensions
      now = UtilsDate.utc_now()

      default_dimensions = [
        # Image dimensions
        %{
          name: "thumbnail",
          width: 150,
          height: 150,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          enabled: true,
          order: 1,
          alternative_formats: [],
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "small",
          width: 300,
          height: 300,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          enabled: true,
          alternative_formats: [],
          order: 2,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "medium",
          width: 800,
          height: 600,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          enabled: true,
          alternative_formats: [],
          order: 3,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "large",
          width: 1920,
          height: 1080,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          enabled: true,
          alternative_formats: [],
          order: 4,
          inserted_at: now,
          updated_at: now
        },
        # Video dimensions
        %{
          name: "360p",
          width: 640,
          height: 360,
          quality: 28,
          format: "mp4",
          applies_to: "video",
          enabled: true,
          alternative_formats: [],
          order: 5,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "720p",
          width: 1280,
          height: 720,
          quality: 25,
          format: "mp4",
          applies_to: "video",
          enabled: true,
          alternative_formats: [],
          order: 6,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "1080p",
          width: 1920,
          height: 1080,
          quality: 23,
          format: "mp4",
          applies_to: "video",
          enabled: true,
          alternative_formats: [],
          order: 7,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "video_thumbnail",
          width: 640,
          height: 360,
          quality: 85,
          format: "jpg",
          applies_to: "video",
          enabled: true,
          alternative_formats: [],
          order: 8,
          inserted_at: now,
          updated_at: now
        },
        # Smart squares: the proportion-keeping sizes above are for grids that
        # justify rows or stack columns; these are for the cells that must be
        # square (a list row, a picker, an avatar, a tile grid). A photo is
        # cropped around its subject, not its middle (`Storage.FocalPoint`); a
        # host without libvips crops at the middle. Not standard slots: a set
        # may drop them.
        %{
          name: "thumbnail_square",
          width: 150,
          height: 150,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          maintain_aspect_ratio: false,
          crop_mode: "focus",
          enabled: true,
          alternative_formats: [],
          order: 9,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "small_square",
          width: 300,
          height: 300,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          maintain_aspect_ratio: false,
          crop_mode: "focus",
          enabled: true,
          alternative_formats: [],
          order: 10,
          inserted_at: now,
          updated_at: now
        },
        # For the zoomed-out views (a month, a year), where a cell is a few dozen
        # pixels: small and light, cropped around the subject like the others.
        %{
          name: "mini_square",
          width: 64,
          height: 64,
          quality: 70,
          format: "jpg",
          applies_to: "image",
          maintain_aspect_ratio: false,
          crop_mode: "focus",
          enabled: true,
          alternative_formats: [],
          order: 11,
          inserted_at: now,
          updated_at: now
        },
        # Panoramas: a fixed height and the width the picture needs (`fit_by`
        # height), made only for wide pictures (`shape`), so an ordinary photo is
        # not given a second near-copy of `thumbnail`, `small` and `medium`.
        %{
          name: "thumbnail_wide",
          height: 150,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          fit_by: "height",
          shape: "wide",
          enabled: true,
          alternative_formats: [],
          order: 12,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "small_wide",
          height: 300,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          fit_by: "height",
          shape: "wide",
          enabled: true,
          alternative_formats: [],
          order: 13,
          inserted_at: now,
          updated_at: now
        },
        %{
          name: "medium_wide",
          height: 800,
          quality: 85,
          format: "jpg",
          applies_to: "image",
          fit_by: "height",
          shape: "wide",
          enabled: true,
          alternative_formats: [],
          order: 14,
          inserted_at: now,
          updated_at: now
        }
      ]

      # Insert all default dimensions
      Enum.each(default_dimensions, fn dim ->
        %Dimension{}
        |> Dimension.changeset(dim)
        |> repo().insert!()
      end)
    end)
    |> tap(fn
      {:ok, _} ->
        Audit.log(
          "storage.variant_set.sizes_reset",
          "storage_variant_set",
          VariantSets.default_uuid(),
          opts,
          %{"variant_set" => "Default"}
        )

      _error ->
        :ok
    end)
  end

  @doc """
  Repairs the storage module: puts back what it cannot work without, and
  resets the Default variant set's sizes.

  Safe on an install with one bucket or many, and non-destructive:

  1. Creates a default local bucket if no buckets exist.
  2. Adds the enabled buckets to the Default storage profile when it has
     no enabled, active bucket to write to (a bucket already in it keeps
     its role and order).
  3. Brings the Default profile's copy count within the buckets it can
     write to — lowered only when it asks for more copies than there are
     buckets, never reset — so a multi-bucket install keeps its
     redundancy.
  4. Clears the default bucket setting when it points at a bucket that is
     gone or disabled.
  5. Resets the Default variant set's dimensions to the 14 defaults
     (10 image + 4 video) and turns automatic variants back on.

  All existing files are preserved.

  ## Returns

  - `{:ok, repairs}` - List of repairs performed
  - `{:error, reason}` - If repair failed

  ## Examples

      iex> repair_storage_module()
      {:ok, [{:bucket_created, "Local Storage"}, {:dimensions_reset, 14}]}

  """
  def repair_storage_module do
    repo().transaction(fn ->
      bucket_repairs =
        case ensure_default_bucket_exists() do
          {:created, bucket} -> [{:bucket_created, bucket.name}]
          :exists -> []
        end

      repairs =
        bucket_repairs ++
          repair_default_profile_buckets() ++
          repair_default_profile_copies() ++ repair_default_bucket_setting()

      case reset_dimensions_to_defaults() do
        {:ok, _} -> :ok
        {:error, reason} -> repo().rollback(reason)
      end

      set_auto_generate_variants(true)

      repairs ++
        [{:dimensions_reset, length(VariantSets.list_dimensions(VariantSets.default_uuid()))}]
    end)
  end

  # The Default profile needs a bucket it can write to; with none, every
  # enabled bucket not in it joins (as a new bucket would).
  defp repair_default_profile_buckets do
    case Profiles.default_profile() do
      %StorageProfile{buckets: rows} ->
        if Enum.any?(rows, &writable_profile_bucket?/1) do
          []
        else
          present = MapSet.new(rows, &to_string(&1.bucket_uuid))

          missing =
            Enum.filter(
              list_buckets(),
              &(&1.enabled and not MapSet.member?(present, to_string(&1.uuid)))
            )

          Enum.each(missing, &Profiles.add_to_default/1)

          if missing == [], do: [], else: [{:buckets_added_to_default, length(missing)}]
        end

      nil ->
        []
    end
  end

  # More copies of a kind than the Default has buckets of it leaves every upload
  # short; each count is lowered to what fits, never raised or reset.
  defp repair_default_profile_copies do
    with %StorageProfile{} = profile <- Profiles.default_profile(),
         true <- Enum.any?(profile.buckets, &writable_profile_bucket?/1),
         fit = Profiles.fit_copies(profile),
         true <- fit != Map.take(profile, [:copies_local, :copies_cloud]),
         total = fit.copies_local + fit.copies_cloud,
         {:ok, _} <-
           Profiles.update_profile(
             profile,
             Map.put(fit, :min_copies_on_write, min(profile.min_copies_on_write, total))
           ) do
      [{:copies_lowered, total}]
    else
      _ -> []
    end
  end

  defp repair_default_bucket_setting do
    case get_default_bucket_uuid() do
      uuid when uuid in [nil, ""] ->
        []

      uuid ->
        case Ecto.UUID.cast(uuid) do
          {:ok, uuid} ->
            case get_bucket(uuid) do
              %Bucket{enabled: true} -> []
              _ -> clear_default_bucket_setting()
            end

          :error ->
            clear_default_bucket_setting()
        end
    end
  end

  defp clear_default_bucket_setting do
    Settings.update_setting("storage_default_bucket_uuid", nil)
    [:default_bucket_cleared]
  end

  defp writable_profile_bucket?(%{status: "active", bucket: %Bucket{enabled: true}}), do: true
  defp writable_profile_bucket?(_row), do: false

  @doc """
  Ensures at least one default bucket exists.

  If no buckets exist, creates a default local storage bucket.

  ## Returns

  - `{:created, bucket}` - If a new bucket was created
  - `:exists` - If buckets already exist

  ## Examples

      iex> ensure_default_bucket_exists()
      {:created, %Bucket{name: "Local Storage"}}

      iex> ensure_default_bucket_exists()
      :exists

  """
  def ensure_default_bucket_exists do
    if Enum.empty?(list_buckets()) do
      {:ok, bucket} =
        create_bucket(%{
          name: "Local Storage",
          provider: "local",
          endpoint: "priv/media",
          enabled: true,
          priority: 0
        })

      {:created, bucket}
    else
      :exists
    end
  end

  @doc """
  Resets storage settings to their default values.

  Resets:
  - `storage_redundancy_copies` to "1"
  - `storage_auto_generate_variants` to "true"
  - `storage_default_bucket_uuid` to nil

  ## Returns

  - `:ok`

  """
  def reset_settings_to_defaults do
    set_redundancy_copies(1)
    set_auto_generate_variants(true)
    Settings.update_setting("storage_default_bucket_uuid", nil)
    :ok
  end

  @doc """
  Creates a new dimension.

  ## Examples

      iex> create_dimension(%{name: "thumbnail", width: 150, height: 150})
      {:ok, %Dimension{}}

      iex> create_dimension(%{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def create_dimension(
        attrs \\ %{},
        variant_set_uuid \\ VariantSets.default_uuid(),
        opts \\ []
      ) do
    Audit.transaction(fn -> do_create_dimension(attrs, variant_set_uuid, opts) end)
  end

  defp do_create_dimension(attrs, variant_set_uuid, opts) do
    %Dimension{variant_set_uuid: variant_set_uuid}
    |> Dimension.changeset(attrs)
    |> repo().insert()
    |> tap(&size_changed/1)
    |> tap(&audit_size(&1, "storage.variant_set.size_created", opts))
  end

  # The fields of a size whose change is written to the history (not its order).
  @audited_size_fields [
    :name,
    :width,
    :height,
    :quality,
    :format,
    :applies_to,
    :enabled,
    :maintain_aspect_ratio,
    :alternative_formats
  ]

  @doc """
  Updates a dimension.

  ## Examples

      iex> update_dimension(dimension, %{name: "New Name"})
      {:ok, %Dimension{}}

      iex> update_dimension(dimension, %{name: nil})
      {:error, %Ecto.Changeset{}}

  """
  def update_dimension(%Dimension{} = dimension, attrs, opts \\ []) do
    Audit.change(dimension, &do_update_dimension(&1, attrs, opts))
  end

  defp do_update_dimension(dimension, attrs, opts) do
    changeset = Dimension.changeset(dimension, attrs)

    # Reordering the list changes no pixels.
    changeset
    |> repo().update()
    |> tap(&if(Map.drop(changeset.changes, [:order]) != %{}, do: size_changed(&1)))
    |> tap(fn
      {:ok, updated} ->
        Audit.log_update(
          "storage.variant_set.size_updated",
          "storage_variant_set",
          updated.variant_set_uuid,
          opts,
          Audit.changes(changeset, @audited_size_fields),
          size_metadata(updated)
        )

      _error ->
        :ok
    end)
  end

  @doc """
  Deletes a dimension.

  ## Examples

      iex> delete_dimension(dimension)
      {:ok, %Dimension{}}

      iex> delete_dimension(dimension)
      {:error, %Ecto.Changeset{}}

  """
  def delete_dimension(%Dimension{} = dimension, opts \\ []) do
    Audit.change(dimension, &do_delete_dimension(&1, opts))
  end

  defp do_delete_dimension(dimension, opts) do
    if Dimension.standard_slot?(dimension) do
      {:error, :standard_slot}
    else
      dimension
      |> repo().delete()
      |> tap(&size_changed/1)
      |> tap(&audit_size(&1, "storage.variant_set.size_deleted", opts))
    end
  end

  defp audit_size({:ok, %Dimension{} = dimension}, action, opts) do
    Audit.log(
      action,
      "storage_variant_set",
      dimension.variant_set_uuid,
      opts,
      size_metadata(dimension)
    )

    :ok
  end

  defp audit_size(_result, _action, _opts), do: :ok

  defp size_metadata(%Dimension{} = dimension) do
    set = dimension.variant_set_uuid && VariantSets.get_variant_set(dimension.variant_set_uuid)

    %{
      "size" => dimension.name,
      "variant_set" => set && set.name,
      "width" => dimension.width,
      "height" => dimension.height
    }
  end

  # A size was added, changed or removed: every file of its set is stale,
  # and the reconciler makes, remakes or deletes that size (G15).
  defp size_changed({:ok, %Dimension{variant_set_uuid: set_uuid}}) when not is_nil(set_uuid),
    do: VariantSets.bump_revision(set_uuid)

  defp size_changed(_result), do: :ok

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking dimension changes.
  """
  def change_dimension(%Dimension{} = dimension, attrs \\ %{}) do
    Dimension.changeset(dimension, attrs)
  end

  # ===== FOLDERS =====

  @doc """
  Returns all non-trashed folders as a flat list ordered by name, for
  building a tree. Trashed folders are excluded — they live in the
  trash bucket alongside trashed files and are read via
  `list_trashed_folders/2`.
  """
  def list_all_folders do
    from(f in Folder, where: is_nil(f.trashed_at), order_by: [asc: f.name])
    |> repo().all()
  end

  @doc "Builds a folder tree structure from a flat list of folders."
  def build_folder_tree(folders) do
    by_parent = Enum.group_by(folders, & &1.parent_uuid)
    build_tree_nodes(by_parent, nil)
  end

  defp build_tree_nodes(by_parent, parent_uuid) do
    (Map.get(by_parent, parent_uuid) || [])
    |> Enum.map(fn folder ->
      %{folder: folder, children: build_tree_nodes(by_parent, folder.uuid)}
    end)
  end

  @doc """
  Returns folder tree rooted at scope_folder_id (exclusive of scope itself).
  For nil scope, returns the real-root tree.
  """
  def list_folder_tree(scope_folder_id \\ nil, opts \\ []) do
    all_folders =
      list_all_folders()
      |> in_library(opts[:library_uuid])
      |> only_viewer_folders(opts)

    by_parent = Enum.group_by(all_folders, & &1.parent_uuid)

    if scope_folder_id do
      build_tree_nodes(by_parent, scope_folder_id)
    else
      build_tree_nodes(by_parent, nil)
    end
  end

  @doc """
  Lists folders within a parent folder (nil = root).

  When parent_uuid is nil and scope_folder_id is set, returns children of
  scope_folder_id instead of real root.

  `opts[:library_uuid]` narrows the real root to one storage library (a
  folder's children are always in its library). Omitted leaves out private
  libraries.
  """
  def list_folders(parent_uuid \\ nil, scope_folder_id \\ nil, opts \\ [])

  def list_folders(nil, nil, opts) do
    from(f in Folder,
      where: is_nil(f.parent_uuid) and is_nil(f.trashed_at),
      order_by: [asc: f.name]
    )
    |> where_library(opts[:library_uuid])
    |> where_viewer_folders(opts)
    |> repo().all()
  end

  def list_folders(nil, scope_folder_id, opts) do
    from(f in Folder,
      where: f.parent_uuid == ^scope_folder_id and is_nil(f.trashed_at),
      order_by: [asc: f.name]
    )
    |> where_viewer_folders(opts)
    |> repo().all()
  end

  def list_folders(parent_uuid, _scope_folder_id, opts) do
    from(f in Folder,
      where: f.parent_uuid == ^parent_uuid and is_nil(f.trashed_at),
      order_by: [asc: f.name]
    )
    |> where_viewer_folders(opts)
    |> repo().all()
  end

  @doc """
  Lists non-trashed folders whose name matches `search` (case-insensitive
  `ilike`), within the same scope the media-browser file search uses:

    * a specific `folder_uuid` → its direct child folders
    * scope root (scope set, no `folder_uuid`) → folders anywhere under the scope
    * real root (no scope, no `folder_uuid`) → all folders

  Returns `[]` for a blank search.
  """
  def search_folders(search, folder_uuid \\ nil, scope_folder_id \\ nil, opts \\ [])

  def search_folders(search, _folder_uuid, _scope, _opts) when search in [nil, ""], do: []

  def search_folders(search, folder_uuid, scope_folder_id, opts) do
    base =
      cond do
        folder_uuid not in [nil, ""] ->
          from(f in Folder, where: f.parent_uuid == ^folder_uuid)

        scope_folder_id ->
          # The scope folder itself isn't a listable result — only its descendants.
          subtree = folder_subtree_uuids(scope_folder_id)
          from(f in Folder, where: f.uuid in ^subtree and f.uuid != ^scope_folder_id)

        true ->
          from(f in Folder)
      end

    base
    |> where([f], is_nil(f.trashed_at))
    |> where_library(opts[:library_uuid])
    |> where_viewer_folders(opts)
    |> where([f], ilike(f.name, ^"%#{search}%"))
    |> order_by([f], asc: f.name)
    |> repo().all()
  end

  @doc "Gets a single folder by UUID."
  def get_folder(nil), do: nil
  def get_folder(uuid), do: repo().get(Folder, uuid)

  @doc """
  Creates a new folder.

  When scope_folder_id is set:
  - If attrs.parent_uuid is outside scope, returns `{:error, :out_of_scope}`.
  - If attrs.parent_uuid is nil, rewrites to scope_folder_id (new folder at scope root).
  """
  def create_folder(attrs, scope_folder_id \\ nil)

  def create_folder(attrs, nil) do
    insert_folder(attrs)
  end

  def create_folder(attrs, scope_folder_id) do
    parent_uuid = attrs[:parent_uuid] || attrs["parent_uuid"]

    cond do
      is_nil(parent_uuid) ->
        attrs |> put_attr(:parent_uuid, scope_folder_id) |> insert_folder()

      within_scope?(parent_uuid, scope_folder_id) ->
        insert_folder(attrs)

      true ->
        {:error, :out_of_scope}
    end
  end

  # A subfolder is in its parent's library, whatever `attrs` says; a root
  # folder is in the library `attrs` names, or Media.
  defp insert_folder(attrs) do
    attrs =
      case attrs[:parent_uuid] || attrs["parent_uuid"] do
        nil ->
          attrs

        parent_uuid ->
          case repo().one(
                 from(f in Folder, where: f.uuid == ^parent_uuid, select: f.library_uuid)
               ) do
            nil -> attrs
            library_uuid -> put_attr(attrs, :library_uuid, library_uuid)
          end
      end

    %Folder{} |> Folder.changeset(attrs) |> repo().insert()
  end

  # Sets `key` in an attrs map whichever key style it uses (Ecto refuses a
  # map that mixes atom and string keys).
  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_binary/1),
      do: attrs |> Map.delete(key) |> Map.put(to_string(key), value),
      else: attrs |> Map.delete(to_string(key)) |> Map.put(key, value)
  end

  defp folder_in_library?(folder_uuid, library_uuid) do
    folder_library =
      repo().one(from(f in Folder, where: f.uuid == ^folder_uuid, select: f.library_uuid))

    to_string(folder_library) ==
      to_string(library_uuid || Libraries.media_uuid())
  end

  @doc """
  Updates a folder (rename, color change, move).

  Returns `{:error, :cycle}` if the move would create a circular reference.
  Returns `{:error, :out_of_scope}` if the folder or new parent is outside scope.

  **`parent_uuid` semantics under scope:** omit `:parent_uuid` from `attrs`
  for rename/recolor (no move is attempted). Pass an explicit value to
  move — including `nil`, which means "move to the system's true root."
  Under a non-nil scope, an explicit `parent_uuid: nil` fails with
  `:out_of_scope` because the system root is outside the scope subtree.
  """
  def update_folder(folder, attrs, scope_folder_id \\ nil)

  def update_folder(%Folder{} = folder, attrs, nil) do
    new_parent = attrs[:parent_uuid] || attrs["parent_uuid"]

    in_folder_tree(moving?(folder, new_parent), fn ->
      case move_refusal(folder, new_parent) do
        nil -> write_folder(folder, attrs)
        refusal -> refusal
      end
    end)
  end

  def update_folder(%Folder{} = folder, attrs, scope_folder_id) do
    # Distinguish "attrs omits parent_uuid entirely" (rename/recolor —
    # no move attempted) from "attrs has parent_uuid: nil" (an explicit
    # move to the system root). The previous `new_parent &&` short-circuit
    # treated both the same, letting a caller silently reparent a folder
    # out of the scope subtree by passing `%{parent_uuid: nil}`. Now any
    # explicit parent_uuid in attrs runs the scope check, and
    # `within_scope?(nil, scope)` is false when scope is set, so a
    # move-to-true-root attempt fails with `:out_of_scope`.
    moving_parent? = Map.has_key?(attrs, :parent_uuid) or Map.has_key?(attrs, "parent_uuid")
    new_parent = attrs[:parent_uuid] || attrs["parent_uuid"]

    # A scoped update runs under the tree lock even when it is only a
    # rename: the scope is about where the folder SITS, and a move
    # committing between the check and the write would take it outside.
    in_folder_tree(moving?(folder, new_parent) or not is_nil(scope_folder_id), fn ->
      cond do
        not within_scope?(folder.uuid, scope_folder_id) ->
          {:error, :out_of_scope}

        moving_parent? and not within_scope?(new_parent, scope_folder_id) ->
          {:error, :out_of_scope}

        refusal = move_refusal(folder, new_parent) ->
          refusal

        true ->
          write_folder(folder, attrs)
      end
    end)
  end

  # Why a folder may not move under `new_parent` (nil for no move): a cycle,
  # a trashed parent, or a parent in another library. nil when it may.
  defp move_refusal(folder, new_parent) do
    cond do
      new_parent && new_parent != folder.parent_uuid && ancestor_of?(folder.uuid, new_parent) ->
        {:error, :cycle}

      moving_into_trash?(folder, new_parent) ->
        {:error, :folder_unavailable}

      new_parent && not folder_in_library?(new_parent, folder.library_uuid) ->
        {:error, :other_library}

      true ->
        nil
    end
  end

  # A folder's library is fixed: an update never moves it to another one.
  defp write_folder(folder, attrs) do
    folder
    |> Folder.changeset(Map.drop(attrs, [:library_uuid, "library_uuid"]))
    |> repo().update()
  end

  @doc """
  Deletes a folder.

  Moves child folders and home files to the deleted folder's parent.
  Folder links are cascade-deleted by the database FK.
  Returns `{:error, :out_of_scope}` if the folder is outside scope.
  """
  def delete_folder(folder, scope_folder_id \\ nil)

  def delete_folder(%Folder{} = folder, scope_folder_id) when not is_nil(scope_folder_id) do
    if within_scope?(folder.uuid, scope_folder_id) do
      do_delete_folder(folder)
    else
      {:error, :out_of_scope}
    end
  end

  def delete_folder(%Folder{} = folder, nil) do
    do_delete_folder(folder)
  end

  defp do_delete_folder(%Folder{} = folder) do
    repo().transaction(fn ->
      # Move child folders to parent
      from(f in Folder, where: f.parent_uuid == ^folder.uuid)
      |> repo().update_all(set: [parent_uuid: folder.parent_uuid])

      # Move home files to parent. A file the parent ALREADY links to would
      # arrive both homed there and linked there, and a folder holds a file
      # once — the same pair `set_home/2` refuses to make, by a different
      # door: the parent is a folder these files may well be attached to.
      moved =
        repo().all(
          from(f in PhoenixKit.Modules.Storage.File,
            where: f.folder_uuid == ^folder.uuid,
            select: f.uuid
          )
        )

      from(f in PhoenixKit.Modules.Storage.File, where: f.folder_uuid == ^folder.uuid)
      |> repo().update_all(set: [folder_uuid: folder.parent_uuid])

      if folder.parent_uuid && moved != [] do
        from(l in FolderLink,
          where: l.folder_uuid == ^folder.parent_uuid and l.file_uuid in ^moved
        )
        |> repo().delete_all()
      end

      # Delete folder (links cascade via FK)
      case repo().delete(folder) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  @doc """
  Soft-deletes a folder and everything underneath it (descendant folders +
  files in the subtree). All affected rows get `trashed_at = now`; files
  also get `status = "trashed"` to match the existing file-trash convention.
  Restore via `restore_folder/2`, permanent delete via
  `delete_folder_completely/2`.

  Scope-guarded: returns `{:error, :out_of_scope}` if the folder is outside
  the provided scope.
  """
  def trash_folder(folder, scope_folder_id \\ nil)

  def trash_folder(%Folder{} = folder, scope_folder_id) when not is_nil(scope_folder_id) do
    if within_scope?(folder.uuid, scope_folder_id) do
      do_trash_folder(folder)
    else
      {:error, :out_of_scope}
    end
  end

  def trash_folder(%Folder{} = folder, nil), do: do_trash_folder(folder)

  defp do_trash_folder(%Folder{} = folder) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      repo().transaction(fn ->
        # Under the tree lock, and the subtree read inside it: a move
        # committing between the read and the trash would otherwise leave
        # the folder it moved live under a trashed parent, listed nowhere.
        lock_folder_tree()
        subtree_uuids = folder_subtree_uuids(folder.uuid)
        # Trash every folder in the subtree (including the root) — except one
        # already in the trash, which keeps its own stamp. `restore_folder/2`
        # restores exactly the rows carrying THIS operation's stamp, so a row
        # trashed on its own earlier must not be re-stamped here, or restoring
        # the folder would also undo that earlier, unrelated trashing.
        from(f in Folder, where: f.uuid in ^subtree_uuids and is_nil(f.trashed_at))
        |> repo().update_all(set: [trashed_at: now, updated_at: now])

        # A file homed in the subtree but ALSO linked into a folder outside it
        # is shown there too (a product's attachment, say — content de-dup
        # links the second upload): re-home it there instead of trashing it,
        # exactly as `delete_folder_completely/2` does. Trashing it hid the
        # attachment from every reader outside this folder (2026-09-12).
        from(f in PhoenixKit.Modules.Storage.File, where: f.folder_uuid in ^subtree_uuids)
        |> repo().all()
        |> Enum.filter(&linked_outside_subtree?(&1.uuid, subtree_uuids, :live))
        |> Enum.each(&promote_out_of_subtree(&1, subtree_uuids, :live))

        # Trash every file still homed in the subtree. Files use both
        # `status: "trashed"` and `trashed_at` (the V99 convention) so the
        # existing file-listing filters (`status != "trashed"`) already
        # hide them without further changes. `select` captures the affected
        # uuids so callers can broadcast per-file trash events for them too.
        {_count, trashed_uuids} =
          from(f in PhoenixKit.Modules.Storage.File,
            where: f.folder_uuid in ^subtree_uuids and is_nil(f.trashed_at),
            select: f.uuid
          )
          |> repo().update_all(set: [status: "trashed", trashed_at: now, updated_at: now])

        {:ok, folder, trashed_uuids}
      end)

    case result do
      {:ok, {:ok, f, trashed_uuids}} ->
        broadcast_files_trashed(trashed_uuids)
        {:ok, f}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Restores a previously trashed folder and everything underneath it.
  Reverses `trash_folder/2` — clears `trashed_at` on all subtree folders
  and resets `status: "active", trashed_at: nil` on all files in the
  subtree.
  """
  def restore_folder(folder, scope_folder_id \\ nil)

  def restore_folder(%Folder{} = folder, scope_folder_id) when not is_nil(scope_folder_id) do
    if within_scope?(folder.uuid, scope_folder_id) do
      do_restore_folder(folder)
    else
      {:error, :out_of_scope}
    end
  end

  def restore_folder(%Folder{} = folder, nil), do: do_restore_folder(folder)

  defp do_restore_folder(%Folder{} = folder) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    subtree_uuids = folder_subtree_uuids(folder.uuid)

    # Only what THIS folder's trashing trashed comes back: the rows carrying
    # its own `trashed_at`. Everything in the subtree used to be restored —
    # a file trashed on its own before or after the folder, and even files
    # that were never trashed (a broadcast `restored` for each). The stamp is
    # read inside the transaction, from the row as it is now.
    result =
      repo().transaction(fn ->
        case repo().one(from(f in Folder, where: f.uuid == ^folder.uuid, select: f.trashed_at)) do
          nil ->
            {:ok, folder, []}

          stamp ->
            from(f in Folder, where: f.uuid in ^subtree_uuids and f.trashed_at == ^stamp)
            |> repo().update_all(set: [trashed_at: nil, updated_at: now])

            {_count, restored_uuids} =
              from(f in PhoenixKit.Modules.Storage.File,
                where: f.folder_uuid in ^subtree_uuids and f.trashed_at == ^stamp,
                select: f.uuid
              )
              |> repo().update_all(
                # Sizes are not kept up to date in the trash (V205): a
                # restored file is checked against its variant set again.
                set: [
                  status: "active",
                  trashed_at: nil,
                  updated_at: now,
                  placed_variant_revision: 0
                ]
              )

            {:ok, folder, restored_uuids}
        end
      end)

    case result do
      {:ok, {:ok, f, restored_uuids}} ->
        if restored_uuids != [], do: ReconcileJob.enqueue()
        broadcast_files_restored(restored_uuids)
        {:ok, f}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Permanently deletes a (presumably trashed) folder and everything
  underneath it. Files are removed via `delete_file_completely/1` so
  backend storage cleanup runs; folders are deleted from the DB in
  bottom-up order so foreign-key constraints stay happy.
  """
  def delete_folder_completely(folder, scope_folder_id \\ nil)

  def delete_folder_completely(%Folder{} = folder, scope_folder_id)
      when not is_nil(scope_folder_id) do
    if within_scope?(folder.uuid, scope_folder_id) do
      do_delete_folder_completely(folder)
    else
      {:error, :out_of_scope}
    end
  end

  def delete_folder_completely(%Folder{} = folder, nil), do: do_delete_folder_completely(folder)

  defp do_delete_folder_completely(%Folder{} = folder) do
    subtree_uuids = folder_subtree_uuids(folder.uuid)

    # Pull files home in the subtree, then delete bottom-up.
    files =
      from(f in PhoenixKit.Modules.Storage.File, where: f.folder_uuid in ^subtree_uuids)
      |> repo().all()

    # A file that is ALSO linked (via `FolderLink`) into a folder OUTSIDE this
    # subtree lives in another folder too — re-home it there (consuming that one
    # link) so it survives, instead of hard-deleting it. Without this, deleting a
    # folder silently destroys a file shared into an unrelated folder (and the
    # `FolderLink.file_uuid` cascade strips it from there). Only files confined
    # to the subtree are deleted.
    {to_promote, to_delete} =
      Enum.split_with(files, &linked_outside_subtree?(&1.uuid, subtree_uuids))

    # A promotion with nowhere live to go lands in a trashed folder and is
    # trashed with it — say so, the same way a trashing does.
    to_promote
    |> Enum.map(&promote_out_of_subtree(&1, subtree_uuids))
    |> Enum.flat_map(fn
      {:trashed, uuid} -> [uuid]
      :ok -> []
    end)
    |> broadcast_files_trashed()

    # One `files_deleted` for the whole folder, not one event per file.
    to_delete
    |> Enum.flat_map(fn file ->
      case delete_file_and_objects(file) do
        {:ok, deleted} -> [deleted.uuid]
        {:error, _} -> []
      end
    end)
    |> broadcast_files_deleted()

    # Delete folders from deepest first so parent_uuid foreign keys
    # don't break. `folder_subtree_uuids/1` walks breadth-first; reverse
    # gives us leaves-first ordering.
    Enum.each(Enum.reverse(subtree_uuids), fn uuid ->
      case repo().get(Folder, uuid) do
        nil -> :ok
        f -> repo().delete(f)
      end
    end)

    {:ok, folder}
  end

  # `{link, folder_trashed_at}` for every `FolderLink` of `file_uuid` that
  # points at a folder OUTSIDE `subtree_uuids` — live folders first, oldest
  # link first within each.
  #
  # `:live` keeps live folders only, which is what TRASHING wants: a file
  # linked only into an already-trashed folder is not shown anywhere, so it
  # goes to the trash with its home and comes back when that is restored.
  # Re-homing it there instead left an `active` file inside a trashed folder —
  # in no trash listing, not restored with its old home, and hard-deleted the
  # day the other folder was emptied.
  defp links_outside_subtree(file_uuid, subtree_uuids, which) do
    query =
      from(fl in FolderLink,
        join: fo in Folder,
        on: fo.uuid == fl.folder_uuid,
        where: fl.file_uuid == ^file_uuid and fl.folder_uuid not in ^subtree_uuids,
        order_by: [asc: not is_nil(fo.trashed_at), asc: fl.inserted_at],
        select: {fl, fo.trashed_at}
      )

    query =
      case which do
        :live -> where(query, [_fl, fo], is_nil(fo.trashed_at))
        :any -> query
      end

    repo().all(query)
  end

  defp linked_outside_subtree?(file_uuid, subtree_uuids, which \\ :any),
    do: links_outside_subtree(file_uuid, subtree_uuids, which) != []

  # Re-home a file to the first folder that links it from outside the deleted
  # subtree (consuming that link), so it survives. Any remaining external links
  # keep pointing at the now-rehomed file; links to subtree folders cascade away
  # when those folders are deleted.
  #
  # A PERMANENT delete (`:any`) may have nowhere live to put the file. It then
  # moves into the trashed folder that links it and takes that folder's trash
  # stamp, so it shares the folder's fate: restored with it (restore matches on
  # `trashed_at`), emptied with it.
  defp promote_out_of_subtree(
         %PhoenixKit.Modules.Storage.File{} = file,
         subtree_uuids,
         which \\ :any
       ) do
    case links_outside_subtree(file.uuid, subtree_uuids, which) do
      [{%FolderLink{folder_uuid: new_home} = link, folder_trashed_at} | _] ->
        changes =
          case folder_trashed_at do
            nil -> [folder_uuid: new_home]
            at -> [folder_uuid: new_home, status: "trashed", trashed_at: at]
          end

        repo().transaction(fn ->
          file |> Ecto.Changeset.change(changes) |> repo().update!()
          repo().delete!(link)
        end)

        if folder_trashed_at, do: {:trashed, file.uuid}, else: :ok

      [] ->
        :ok
    end
  end

  @doc """
  Walks the folder tree from `root_uuid` down and returns every descendant
  folder uuid, including the root itself.

  Used by trash, restore, and permanent-delete to determine the affected
  subtree in one pass, and by scoped media listings that should include
  files in nested folders.
  """
  def folder_subtree_uuids(root_uuid) do
    # A folder seen once is not walked again, so a parent loop in the data
    # (it should never exist) ends the walk instead of hanging it.
    Stream.unfold({[root_uuid], MapSet.new([root_uuid])}, fn
      {[], _seen} ->
        nil

      {pending, seen} ->
        children =
          from(f in Folder, where: f.parent_uuid in ^pending, select: f.uuid)
          |> repo().all()
          |> Enum.reject(&MapSet.member?(seen, &1))

        {pending, {children, Enum.into(children, seen)}}
    end)
    |> Enum.to_list()
    |> List.flatten()
  end

  @doc "Returns trashed folders ordered by trashed_at descending, with optional scope."
  def list_trashed_folders(scope_folder_id \\ nil, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(f in Folder,
      where: not is_nil(f.trashed_at),
      order_by: [desc: f.trashed_at],
      limit: ^limit,
      offset: ^offset
    )
    |> scope_trashed_folders(scope_folder_id)
    |> where_library(opts[:library_uuid])
    |> where_viewer_folders(opts)
    |> repo().all()
  end

  @doc "Counts trashed folders (with optional scope and `:library_uuid`)."
  def count_trashed_folders(scope_folder_id \\ nil, opts \\ []) do
    from(f in Folder, where: not is_nil(f.trashed_at), select: count(f.uuid))
    |> scope_trashed_folders(scope_folder_id)
    |> where_library(opts[:library_uuid])
    |> where_viewer_folders(opts)
    |> repo().one()
    |> Kernel.||(0)
  end

  # Restrict trashed folders to the scope folder's own subtree — the folders
  # trashed *under* it — so a folder's Trash never shows folders trashed in a
  # sibling root. nil scope = all trashed folders (the top-level view).
  # `folder_subtree_uuids/1` walks children by parent_uuid without filtering
  # trashed_at, so a trashed subfolder's trashed children are still reachable.
  # The subtree includes the scope folder itself; drop it — the scope folder
  # is where you're standing, not a trashed row.
  defp scope_trashed_folders(query, nil), do: query

  defp scope_trashed_folders(query, scope_folder_id) do
    descendants = folder_subtree_uuids(scope_folder_id) -- [scope_folder_id]
    from(f in query, where: f.uuid in ^descendants)
  end

  @doc """
  Returns the ancestor chain from root to the given folder (for breadcrumbs).

  When scope_folder_id is set, the chain stops before scope (scope itself not included —
  it is the virtual root).
  """
  def folder_breadcrumbs(folder_uuid, scope_folder_id \\ nil)

  def folder_breadcrumbs(folder_uuid, nil) do
    do_folder_breadcrumbs(folder_uuid, 50)
  end

  def folder_breadcrumbs(folder_uuid, scope_folder_id) do
    folder_uuid
    |> do_folder_breadcrumbs(50)
    |> Enum.drop_while(fn f -> f.uuid != scope_folder_id end)
    |> case do
      [] -> []
      [_ | rest] -> rest
    end
  end

  defp do_folder_breadcrumbs(nil, _limit), do: []
  defp do_folder_breadcrumbs(_uuid, 0), do: []

  defp do_folder_breadcrumbs(folder_uuid, limit) do
    case get_folder(folder_uuid) do
      nil -> []
      folder -> do_folder_breadcrumbs(folder.parent_uuid, limit - 1) ++ [folder]
    end
  end

  @doc """
  Returns true if `folder_uuid` is `target_uuid` or one of its ancestors
  (and `target_uuid` exists). One recursive query, whatever the depth — a
  walk that gave up after 50 levels let a deeper move make a cycle and
  put a deep folder outside its own scope.
  """
  def ancestor_of?(_folder_uuid, nil), do: false

  def ancestor_of?(folder_uuid, target_uuid) do
    # Compared as cast uuids: the same folder spelled in upper case must not
    # read as another one.
    case {Ecto.UUID.cast(folder_uuid), Ecto.UUID.cast(target_uuid)} do
      {{:ok, same}, {:ok, same}} -> get_folder(same) != nil
      {{:ok, folder}, {:ok, target}} -> folder in TreeQuery.ancestor_uuids(Folder, target)
      _ -> false
    end
  end

  @doc false
  # The lock every folder move holds before its cycle check. A caller that
  # also locks a folder row takes this first, so no two moves wait on each
  # other in opposite orders.
  def lock_folder_tree do
    repo().query!("SELECT pg_advisory_xact_lock(hashtext('phoenix_kit_storage:folder_tree'))")
    :ok
  end

  # A live folder under a trashed one is in no listing: the move is
  # refused rather than hiding it.
  defp moving_into_trash?(%Folder{parent_uuid: current}, new_parent)
       when is_binary(new_parent) and new_parent != current do
    case get_folder(new_parent) do
      %Folder{trashed_at: nil} -> false
      _ -> true
    end
  end

  defp moving_into_trash?(_folder, _new_parent), do: false

  defp moving?(%Folder{parent_uuid: current}, new_parent),
    do: new_parent not in [nil, ""] and to_string(new_parent) != to_string(current)

  # A move runs under one lock on the whole folder tree, so its cycle check
  # reads the tree after any other move has committed — two moves at once
  # in opposite directions otherwise both passed and committed a loop.
  defp in_folder_tree(false, fun), do: fun.()

  defp in_folder_tree(true, fun) do
    repo().transaction(fn ->
      lock_folder_tree()

      case fun.() do
        {:ok, folder} -> folder
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  @doc """
  Returns true if folder_uuid is within the given scope.

  - When scope_folder_id is nil, always returns true (no scope restriction).
  - When folder_uuid equals scope_folder_id, returns true (scope is the virtual root).
  - When scope_folder_id is an ancestor of folder_uuid, returns true (folder is a descendant).
  - Returns false otherwise, including when folder_uuid is nil and scope is set
    (real root is outside any non-nil scope).
  """
  def within_scope?(_folder_uuid, nil), do: true
  def within_scope?(folder_uuid, scope_folder_id) when folder_uuid == scope_folder_id, do: true
  def within_scope?(folder_uuid, scope_folder_id), do: ancestor_of?(scope_folder_id, folder_uuid)

  @doc "Counts files in a folder (home files + linked files)."
  def count_folder_contents(nil) do
    home =
      from(f in PhoenixKit.Modules.Storage.File, where: is_nil(f.folder_uuid), select: count())
      |> repo().one()

    home || 0
  end

  def count_folder_contents(folder_uuid) do
    home =
      from(f in PhoenixKit.Modules.Storage.File,
        where: f.folder_uuid == ^folder_uuid,
        select: count()
      )
      |> repo().one()

    links =
      from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid, select: count())
      |> repo().one()

    (home || 0) + (links || 0)
  end

  @doc """
  Lists files within the given scope with optional folder filter, search, and pagination.

  ## Options
    - `:folder_uuid` — specific folder within scope; returns `{:error, :out_of_scope}` if outside.
    - `:search` — ilike search on original_file_name; restricted to scope descendants when scope set.
    - `:include_orphaned` — boolean (default false); only meaningful when scope is nil.
      When true, returns only files with folder_uuid IS NULL.
      `include_orphaned: true` is ignored when `scope_folder_id` is non-nil (orphans are always outside any scope).
    - `:page` — page number (default 1).
    - `:per_page` — page size (default 20).
    - `:library_uuid` — only files in this storage library. Omitted means
      every library that is not private (`Libraries.exclude_private/1`).
    - `:shape` — `:wide` or `:tall` (or `"wide"` / `"tall"`): only pictures of that
      shape (`PhoenixKit.Modules.Storage.Shape`). Omitted, nil or `"all"` is every shape.

  ## Returns
    `{files, total_count}` or `{:error, :out_of_scope}`.

  When `scope_folder_id == nil` and no `folder_uuid` is specified, ALL files are returned (not
  just orphans). To fetch orphans only at real root, pass `include_orphaned: true` AND use a
  dedicated orphan-only branch. Task 4 callers must preserve the current `/admin/media` behavior
  (list orphans only when `filter_orphaned` is on) via a separate code path.
  """
  def list_files_in_scope(scope_folder_id, opts \\ []) do
    folder_uuid = opts[:folder_uuid]
    search = opts[:search]
    include_orphaned = Keyword.get(opts, :include_orphaned, false)
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)
    # Optional UI sort + file-type filter (media browser toolbar).
    sort = opts[:sort] || "newest"
    file_type = opts[:file_type]

    if not is_nil(folder_uuid) and not is_nil(scope_folder_id) and
         not within_scope?(folder_uuid, scope_folder_id) do
      {:error, :out_of_scope}
    else
      query =
        build_scope_file_query(scope_folder_id, folder_uuid, search, include_orphaned)
        |> where([f], f.status != "trashed")
        |> exclude_system_managed()
        |> maybe_filter_file_type(file_type)
        |> Shape.filter(opts[:shape])
        |> where_library(opts[:library_uuid])
        |> where_viewer(opts[:viewer_uuid])

      total = repo().aggregate(query, :count, :uuid)

      files =
        query
        |> apply_file_sort(sort)
        |> offset(^((page - 1) * per_page))
        |> limit(^per_page)
        |> repo().all()

      {files, total}
    end
  end

  # Narrows the listing to a single file_type ("image", "video", "document",
  # "audio", "archive", "other"); "all"/nil leaves it unfiltered.
  defp maybe_filter_file_type(query, type) when type in [nil, "all", ""], do: query
  defp maybe_filter_file_type(query, type), do: where(query, [f], f.file_type == ^type)

  # Sort whitelist for the media browser toolbar — defaults to newest first.
  # Every order carries `f.uuid` as a stable tiebreaker so equal values
  # (same size, same name, same insert time) can't shuffle across pages.
  # Name sorts compare case-insensitively (lower/?) so "apple" and "Zebra"
  # order naturally instead of uppercase-before-lowercase.
  defp apply_file_sort(query, "oldest"),
    do: order_by(query, [f], asc: f.inserted_at, asc: f.uuid)

  defp apply_file_sort(query, "name_asc"),
    do: order_by(query, [f], asc: fragment("lower(?)", f.original_file_name), asc: f.uuid)

  defp apply_file_sort(query, "name_desc"),
    do: order_by(query, [f], desc: fragment("lower(?)", f.original_file_name), asc: f.uuid)

  defp apply_file_sort(query, "largest"), do: order_by(query, [f], desc: f.size, asc: f.uuid)
  defp apply_file_sort(query, "smallest"), do: order_by(query, [f], asc: f.size, asc: f.uuid)
  defp apply_file_sort(query, _newest), do: order_by(query, [f], desc: f.inserted_at, asc: f.uuid)

  defp build_scope_file_query(nil, nil, nil, false) do
    from(f in PhoenixKit.Modules.Storage.File)
  end

  defp build_scope_file_query(nil, nil, nil, true) do
    from(f in PhoenixKit.Modules.Storage.File, where: is_nil(f.folder_uuid))
  end

  defp build_scope_file_query(nil, folder_uuid, search, _orphaned) when not is_nil(folder_uuid) do
    folder_contents_query(folder_uuid)
    |> apply_file_search(search)
  end

  defp build_scope_file_query(nil, nil, search, _orphaned) when not is_nil(search) do
    from(f in PhoenixKit.Modules.Storage.File)
    |> apply_file_search(search)
  end

  defp build_scope_file_query(scope_folder_id, folder_uuid, search, _orphaned) do
    cond do
      folder_uuid ->
        # Specific folder already validated within scope — no CTE needed
        folder_contents_query(folder_uuid)

      search && search != "" ->
        # Search: walk the full scope subtree via recursive CTE
        scope_subtree_query(scope_folder_id)

      true ->
        # Scope root without search: the scope folder's own contents
        # (home files plus files linked into it), not the subtree.
        folder_contents_query(scope_folder_id)
    end
    |> apply_file_search(search)
  end

  # A folder's contents are its home files PLUS the files linked into it
  # via `FolderLink` — the shape `assign_file_to_folder/2` produces when a
  # file that already lives elsewhere is attached here (a content
  # duplicate, a media-selector pick). `count_folder_contents/1` has
  # always counted both; the listing read the home rows only, so a
  # linked file showed in the sidebar count and not in the grid (found
  # from the catalogue's item attachments, 2026-09-12).
  defp folder_contents_query(folder_uuid) do
    linked =
      from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid, select: fl.file_uuid)

    from(f in PhoenixKit.Modules.Storage.File,
      where: f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked)
    )
  end

  defp scope_subtree_query(scope_folder_id) do
    cte_base =
      from(f in Folder,
        where: f.uuid == ^scope_folder_id,
        select: %{uuid: f.uuid}
      )

    cte_recursive =
      from(f in Folder,
        join: d in "scope_descendants",
        on: f.parent_uuid == d.uuid,
        select: %{uuid: f.uuid}
      )

    cte = union_all(cte_base, ^cte_recursive)

    from(f in PhoenixKit.Modules.Storage.File,
      join: d in "scope_descendants",
      on: f.folder_uuid == d.uuid,
      select: f
    )
    |> recursive_ctes(true)
    |> with_cte("scope_descendants", as: ^cte)
  end

  defp apply_file_search(query, nil), do: query
  defp apply_file_search(query, ""), do: query

  defp apply_file_search(query, search) do
    term = "%#{search}%"

    where(
      query,
      [f],
      ilike(f.original_file_name, ^term) or
        fragment("CAST(? AS TEXT) ILIKE ?", f.uuid, ^term)
    )
  end

  @doc "Moves a file's home folder."
  def move_file_to_folder(file_uuid, target_folder_uuid, scope_folder_id \\ nil)

  def move_file_to_folder(file_uuid, target_folder_uuid, nil) do
    case repo().get(PhoenixKit.Modules.Storage.File, file_uuid) do
      nil -> {:error, :not_found}
      file -> set_home(file, target_folder_uuid)
    end
  end

  def move_file_to_folder(file_uuid, target_folder_uuid, scope_folder_id) do
    file = repo().get(PhoenixKit.Modules.Storage.File, file_uuid)

    cond do
      is_nil(file) ->
        {:error, :not_found}

      not within_scope?(file.folder_uuid, scope_folder_id) ->
        {:error, :out_of_scope}

      not within_scope?(target_folder_uuid, scope_folder_id) ->
        {:error, :out_of_scope}

      true ->
        set_home(file, target_folder_uuid)
    end
  end

  # A file's home is a folder of its own library (or none).
  #
  # Taking the link to the destination with it is the whole of the write: a
  # folder holds a file ONCE, as its home or through a link, never both.
  # Leaving both behind is invisible in a listing — `folder_uuid = $1 OR
  # linked` answers once either way — and then bites on the next move, which
  # asks the link table what to do and re-points a link while the home stays
  # put. That is the file appearing in two folders at once.
  #
  # A file picks up the link that sets this off by being attached somewhere:
  # `ResourceFolders.attach/2` (a post's featured image, a product's gallery)
  # and the uploader's content-duplicate path both LINK a file that already
  # has a home, and a later move into that same folder used to make the pair.
  defp set_home(file, target_folder_uuid) do
    if is_nil(target_folder_uuid) or same_library?(file, target_folder_uuid) do
      repo().transaction(fn ->
        drop_folder_link(target_folder_uuid, file.uuid)

        case file
             |> Ecto.Changeset.change(%{folder_uuid: target_folder_uuid})
             |> repo().update() do
          {:ok, updated} -> updated
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)
    else
      {:error, :other_library}
    end
  end

  # No link, or none to drop: both are `:ok`, and the root has no links.
  defp drop_folder_link(nil, _file_uuid), do: :ok

  defp drop_folder_link(folder_uuid, file_uuid) do
    from(l in FolderLink, where: l.folder_uuid == ^folder_uuid and l.file_uuid == ^file_uuid)
    |> repo().delete_all()

    :ok
  end

  @doc """
  Moves a file as SEEN in `from_folder_uuid` to `target_folder_uuid`.

  Where the file LIVES decides what the gesture means, in this order:

    * trashed → restored into `target_folder_uuid`, because moving a file
      into a folder is how a trash listing puts it back (`{:error, …}` if
      the target is out of scope, trashed, or another library's);
    * home is `from_folder_uuid` (or it is viewed outside any folder) → it
      moves, as `move_file_to_folder/3` always has, and the folder it left
      keeps nothing: any link it had there goes with it;
    * merely linked into `from_folder_uuid` (its home is another folder) →
      the LINK is re-pointed at the target. The file stays where it lives
      and every other folder holding it keeps it.

  Home before links, because a file can hold both and asking the link
  table first moved the link while leaving the home behind — one file in
  two folders. Folder listings show linked files (2026-09-12), so a move
  from a folder must act on what that folder holds, not only on the home.
  """
  def move_file_between_folders(file_uuid, from_folder_uuid, target_folder_uuid, scope_folder_id) do
    file = repo().get(PhoenixKit.Modules.Storage.File, file_uuid)

    cond do
      is_nil(file) ->
        {:error, :not_found}

      # Moving a trashed file INTO a folder is how a listing takes it back
      # out of the trash, so restore it there. Re-homing a trashed row
      # instead — which is what this did — reported success, left the file
      # in the trash, never showed it in the folder it was dropped on, and
      # quietly changed the home it would come back to whenever somebody
      # did find the way to restore it.
      file.status == "trashed" ->
        restore_into_target(file, target_folder_uuid, scope_folder_id)

      # The file LIVES in the folder it was dragged out of, so this is a home
      # move — whatever links it also carries. Asking the link table first
      # sent a file holding both a home and a link to the same folder down
      # the link path: the link moved to the target and the home stayed
      # behind, which is the file "duplicating" into the folder it was
      # dropped on while remaining in the one it came from.
      to_string(file.folder_uuid) == to_string(from_folder_uuid) ->
        with {:ok, _} = moved <-
               move_file_to_folder(file_uuid, target_folder_uuid, scope_folder_id) do
          # …and the folder it left keeps nothing: a link to the source is
          # the other half of the pair `set_home/2` now refuses to make.
          drop_folder_link(from_folder_uuid, file_uuid)
          moved
        end

      true ->
        move_linked_file(file_uuid, from_folder_uuid, target_folder_uuid, scope_folder_id)
    end
  end

  # The same guards a live move gets: inside the scope, into a folder that
  # is really there, and of the file's own library.
  defp restore_into_target(file, target_folder_uuid, scope_folder_id) do
    cond do
      not within_scope?(target_folder_uuid, scope_folder_id) ->
        {:error, :out_of_scope}

      not is_nil(target_folder_uuid) and not live_folder?(target_folder_uuid) ->
        {:error, :folder_unavailable}

      not is_nil(target_folder_uuid) and not same_library?(file, target_folder_uuid) ->
        {:error, :other_library}

      true ->
        restore_file_into(file, target_folder_uuid)
    end
  end

  defp move_linked_file(file_uuid, from_folder_uuid, target_folder_uuid, scope_folder_id) do
    case folder_link(from_folder_uuid, file_uuid) do
      %FolderLink{} = link ->
        cond do
          not within_scope?(target_folder_uuid, scope_folder_id) ->
            {:error, :out_of_scope}

          to_string(target_folder_uuid) == to_string(from_folder_uuid) ->
            {:ok, link}

          true ->
            relink(link, file_uuid, target_folder_uuid)
        end

      nil ->
        move_file_to_folder(file_uuid, target_folder_uuid, scope_folder_id)
    end
  end

  @doc """
  Removes a file from `folder_uuid`'s view — what "trash" means when
  done FROM a folder listing, now that listings show linked files:

    * linked into `folder_uuid` (home elsewhere) → the link is deleted;
      the file and every other folder holding it are untouched
      (`{:ok, :unlinked, file}`);
    * home is `folder_uuid` and another folder links to it → the file is
      re-homed to that folder (consuming the link) rather than trashed
      out from under it (`{:ok, :rehomed, file}`);
    * home is `folder_uuid` and nothing else holds it, or the file is
      viewed outside any folder (`nil`) → soft-trashed
      (`{:ok, :trashed, file}`).

  Trashing the record directly from a folder that only LINKED it would
  destroy it for its owner — the same rule the catalogue's own attachment
  removal has always applied.

  The decision is made from the file's row read fresh under a lock, not
  from `file`: a listing's struct can be stale (the file re-homed since),
  and a second removal deciding from the old home would trash a file
  another folder now holds. The lock is also what
  `ResourceFolders.point_at/6` holds while it checks a folder still has a
  file.
  """
  def remove_file_from_folder(%PhoenixKit.Modules.Storage.File{} = file, folder_uuid)
      when is_binary(folder_uuid) do
    repo().transaction(fn ->
      case repo().one(
             from(f in PhoenixKit.Modules.Storage.File,
               where: f.uuid == ^file.uuid,
               lock: "FOR UPDATE"
             )
           ) do
        nil -> {:error, :not_in_folder}
        fresh -> remove_locked(fresh, folder_uuid)
      end
    end)
    |> case do
      # Announced only once committed: a subscriber reloads the row and
      # must see it trashed.
      {:ok, {:ok, :trashed, trashed} = result} ->
        broadcast_file_trashed(trashed.uuid)
        result

      {:ok, result} ->
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  def remove_file_from_folder(%PhoenixKit.Modules.Storage.File{} = file, _no_folder) do
    with {:ok, trashed} <- trash_file(file), do: {:ok, :trashed, trashed}
  end

  defp remove_locked(file, folder_uuid) do
    cond do
      to_string(file.folder_uuid) == to_string(folder_uuid) ->
        case other_folder_links(file.uuid, folder_uuid) do
          [] ->
            with {:ok, trashed} <- mark_trashed(file), do: {:ok, :trashed, trashed}

          links ->
            rehome_into_first_live(file, links)
        end

      link = folder_link(folder_uuid, file.uuid) ->
        with {:ok, _} <- repo().delete(link), do: {:ok, :unlinked, file}

      # Neither homed nor linked here: a stale or forged row. Refuse
      # rather than trash a file this folder never held.
      true ->
        {:error, :not_in_folder}
    end
  end

  # The candidates were read without locking their folders, so one can be
  # mid-trash: each folder is checked before the file is homed there, and a
  # trashed one is skipped for the next candidate. (Locking the folder here
  # instead would take it AFTER the file's row — the opposite of the order
  # folder moves take, which is a deadlock.) This narrows the race rather
  # than closing it: a folder trashed between the check and this commit can
  # still end up holding the file live, since `trash_folder/1`'s file sweep
  # reads the file's old home. The earlier write-then-check form had the
  # same window.
  #
  # Runs inside `remove_file_from_folder/2`'s transaction, so no transaction
  # of its own: a nested rollback would poison the outer one, and every
  # later query in it would raise. Nothing left to rehome into: the file is
  # trashed.
  defp rehome_into_first_live(file, []) do
    with {:ok, trashed} <- mark_trashed(file), do: {:ok, :trashed, trashed}
  end

  defp rehome_into_first_live(file, [%FolderLink{} = link | rest]) do
    case get_folder(link.folder_uuid) do
      %Folder{trashed_at: nil} ->
        with {:ok, rehomed} <-
               file
               |> Ecto.Changeset.change(%{folder_uuid: link.folder_uuid})
               |> repo().update(),
             {:ok, _} <- repo().delete(link) do
          {:ok, :rehomed, rehomed}
        else
          {:error, reason} -> repo().rollback(reason)
        end

      _ ->
        rehome_into_first_live(file, rest)
    end
  end

  @doc """
  Puts an existing file into `folder_uuid` the way every attach surface
  should: a file with no home is adopted (its `folder_uuid` is set); a
  file already homed there is left alone; a file homed ELSEWHERE gets a
  `FolderLink` into `folder_uuid` (idempotent) rather than being moved
  out from under whatever holds it. This is the rule the catalogue's
  attachments and the media selector already followed; the media
  browser's own upload path used to MOVE a content-duplicate's home
  instead, silently emptying the folder that owned it.
  """
  def attach_file_to_folder(%PhoenixKit.Modules.Storage.File{} = file, folder_uuid)
      when is_binary(folder_uuid) do
    cond do
      # Not into a trashed folder, whichever surface asks: the file would
      # be active and listed nowhere.
      not live_folder?(folder_uuid) ->
        {:error, :folder_unavailable}

      # A folder holds only its own library's files.
      not same_library?(file, folder_uuid) ->
        {:error, :other_library}

      to_string(file.folder_uuid) == to_string(folder_uuid) ->
        {:ok, file}

      is_nil(file.folder_uuid) ->
        adopt_or_link(file, folder_uuid)

      true ->
        %FolderLink{}
        |> FolderLink.changeset(link_attrs(folder_uuid, file))
        |> repo().insert(on_conflict: :nothing)
        |> case do
          {:ok, _} -> {:ok, file}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  # A link carries its file's library (the composite FK insists).
  defp link_attrs(folder_uuid, file) do
    put_library(%{folder_uuid: folder_uuid, file_uuid: file.uuid}, file.library_uuid)
  end

  # Whether `folder_uuid` is in `file`'s library. A file struct built before
  # V202 (no `library_uuid`) is Media's.
  defp same_library?(file, folder_uuid) do
    folder_library =
      repo().one(from(f in Folder, where: f.uuid == ^folder_uuid, select: f.library_uuid))

    file_library =
      Map.get(file, :library_uuid) || Libraries.media_uuid()

    to_string(folder_library) == to_string(file_library)
  end

  defp live_folder?(folder_uuid) do
    case get_folder(folder_uuid) do
      %Folder{trashed_at: nil} -> true
      _ -> false
    end
  end

  # Adopts a file with no home — only if it still has none: the caller's
  # struct can be stale, and a file another upload adopted in the meantime
  # is linked here instead of having its home taken.
  defp adopt_or_link(file, folder_uuid) do
    from(f in PhoenixKit.Modules.Storage.File,
      where: f.uuid == ^file.uuid and is_nil(f.folder_uuid)
    )
    |> repo().update_all(set: [folder_uuid: folder_uuid, updated_at: UtilsDate.utc_now()])
    |> case do
      {1, _} ->
        {:ok, %{file | folder_uuid: folder_uuid}}

      {0, _} ->
        case get_file(file.uuid) do
          nil -> {:error, :not_found}
          %{folder_uuid: nil} -> {:error, :not_found}
          fresh -> attach_file_to_folder(fresh, folder_uuid)
        end
    end
  end

  @doc "The `FolderLink` holding `file_uuid` in `folder_uuid`, or nil."
  def folder_link(folder_uuid, file_uuid) when is_binary(folder_uuid) and is_binary(file_uuid) do
    repo().get_by(FolderLink, folder_uuid: folder_uuid, file_uuid: file_uuid)
  end

  def folder_link(_, _), do: nil

  # One transaction: the source link goes only if the target attach
  # lands. A link cannot live at the root (nil target), so moving a
  # linked appearance to the root simply drops it; landing on the file's
  # own home, or on a folder that already links it, adds nothing
  # (`attach_file_to_folder/2` is idempotent) — never a self-link
  # counted twice.
  defp relink(link, file_uuid, target_folder_uuid) do
    repo().transaction(fn ->
      with {:ok, _} <- repo().delete(link),
           %PhoenixKit.Modules.Storage.File{} = file <-
             repo().get(PhoenixKit.Modules.Storage.File, file_uuid),
           {:ok, result} <- attach_to_target(file, target_folder_uuid) do
        result
      else
        nil -> repo().rollback(:not_found)
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp attach_to_target(file, nil), do: {:ok, file}

  defp attach_to_target(file, target_folder_uuid),
    do: attach_file_to_folder(file, target_folder_uuid)

  # The folder itself if it is live, else the closest ancestor that is, else
  # the root. Bounded: a tree deeper than this is a cycle, and the walk is
  # not the place to discover that.
  defp nearest_live_folder(folder_uuid, depth \\ 0)
  defp nearest_live_folder(nil, _depth), do: nil
  defp nearest_live_folder(_folder_uuid, depth) when depth > 50, do: nil

  defp nearest_live_folder(folder_uuid, depth) do
    case repo().get(Folder, folder_uuid) do
      %Folder{trashed_at: nil} -> folder_uuid
      %Folder{parent_uuid: parent} -> nearest_live_folder(parent, depth + 1)
      nil -> nil
    end
  end

  # Links into LIVE folders only: re-homing a file into a trashed folder
  # would strand it — listed nowhere, and not in the file trash either.
  defp other_folder_links(file_uuid, except_folder_uuid) do
    from(fl in FolderLink,
      join: fo in Folder,
      on: fo.uuid == fl.folder_uuid,
      where: fl.file_uuid == ^file_uuid and fl.folder_uuid != ^except_folder_uuid,
      where: is_nil(fo.trashed_at),
      order_by: [asc: fl.inserted_at]
    )
    |> repo().all()
  end

  @doc "Creates a link (shortcut) of a file in a folder."
  def create_folder_link(folder_uuid, file_uuid, scope_folder_id \\ nil)

  def create_folder_link(folder_uuid, file_uuid, nil) do
    case repo().get(PhoenixKit.Modules.Storage.File, file_uuid) do
      nil -> {:error, :not_found}
      file -> insert_folder_link(folder_uuid, file)
    end
  end

  def create_folder_link(folder_uuid, file_uuid, scope_folder_id) do
    file = repo().get(PhoenixKit.Modules.Storage.File, file_uuid)

    cond do
      not within_scope?(folder_uuid, scope_folder_id) ->
        {:error, :out_of_scope}

      is_nil(file) ->
        {:error, :not_found}

      not within_scope?(file.folder_uuid, scope_folder_id) ->
        {:error, :out_of_scope}

      true ->
        insert_folder_link(folder_uuid, file)
    end
  end

  defp insert_folder_link(folder_uuid, file) do
    if same_library?(file, folder_uuid) do
      %FolderLink{}
      |> FolderLink.changeset(link_attrs(folder_uuid, file))
      |> repo().insert()
    else
      {:error, :other_library}
    end
  end

  @doc "Removes a folder link."
  def delete_folder_link(link_uuid) do
    case repo().get(FolderLink, link_uuid) do
      nil -> {:error, :not_found}
      link -> repo().delete(link)
    end
  end

  # ===== FILES =====

  @doc """
  Returns a list of files, optionally filtered by bucket.

  ## Options

  - `:bucket_uuid` - Only files with a copy in this bucket (an active location
    of any of their instances)
  - `:limit` - Maximum number of results
  - `:offset` - Number of results to skip
  - `:order_by` - Ordering (default: `[desc: :inserted_at]`)

  """
  def list_files(opts \\ []) do
    PhoenixKit.Modules.Storage.File
    |> where([f], f.status != "trashed")
    |> exclude_system_managed()
    |> maybe_filter_by_bucket(opts[:bucket_uuid])
    |> maybe_order_by(opts[:order_by])
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> repo().all()
  end

  # Narrows a file or folder query to one storage library. nil is every
  # library that is not private: a private library (every user library) is
  # read by passing its uuid. Leaving nil unfiltered put those files on
  # /admin/media, in host embeds that name no library, and in orphan
  # cleanup — which would then delete them, since nothing in the site
  # references a user library's files.
  defp where_library(query, nil), do: Libraries.exclude_private(query)
  defp where_library(query, library_uuid), do: where(query, [r], r.library_uuid == ^library_uuid)

  # A restricted viewer's view of a site library (`:viewer_uuid`, see
  # `viewer_folder_uuids/2`): only the files they uploaded, only the folders they
  # created, hold a file of theirs in, or that lead to one of those. `nil` (every
  # caller that does not pass it) is unrestricted.
  defp where_viewer(query, nil), do: query
  defp where_viewer(query, viewer_uuid), do: where(query, [r], r.user_uuid == ^viewer_uuid)

  defp where_viewer_folders(query, opts) do
    case opts[:viewer_uuid] do
      nil ->
        query

      viewer_uuid ->
        visible = viewer_folder_uuids(viewer_uuid, opts[:library_uuid])
        where(query, [f], f.uuid in ^visible)
    end
  end

  defp only_viewer_folders(folders, opts) do
    case opts[:viewer_uuid] do
      nil ->
        folders

      viewer_uuid ->
        visible =
          viewer_uuid |> viewer_folder_uuids(opts[:library_uuid]) |> MapSet.new(&to_string/1)

        Enum.filter(folders, &MapSet.member?(visible, to_string(&1.uuid)))
    end
  end

  @doc """
  The folders of a library that a restricted viewer may see (`:viewer_uuid`): the
  ones they created, the ones that hold a file they uploaded (whatever its status,
  so the path to a trashed file of theirs reads), and every ancestor of those, so
  a path reads from the root. `library_uuid` narrows it to one library; `nil`
  leaves out the private ones, as the other listings do.

  An ancestor's name is visible, as in any breadcrumb; nothing else of it is.
  """
  @spec viewer_folder_uuids(String.t(), term()) :: [String.t()]
  def viewer_folder_uuids(viewer_uuid, library_uuid \\ nil) when is_binary(viewer_uuid) do
    created =
      from(f in Folder, where: f.user_uuid == ^viewer_uuid, select: f.uuid)
      |> where_library(library_uuid)
      |> repo().all()

    homes =
      from(f in PhoenixKit.Modules.Storage.File,
        where: f.user_uuid == ^viewer_uuid and not is_nil(f.folder_uuid),
        distinct: true,
        select: f.folder_uuid
      )
      |> where_library(library_uuid)
      |> repo().all()

    (created ++ homes) |> Enum.map(&to_string/1) |> Enum.uniq() |> with_ancestors()
  end

  # Adds the ancestors of `uuids`, level by level (a folder tree is a few levels
  # deep; the depth guard is for a cycle that should not exist).
  defp with_ancestors(uuids), do: with_ancestors(uuids, MapSet.new(uuids), uuids, 0)

  defp with_ancestors(_all, seen, [], _depth), do: MapSet.to_list(seen)
  defp with_ancestors(_all, seen, _frontier, depth) when depth >= 100, do: MapSet.to_list(seen)

  defp with_ancestors(all, seen, frontier, depth) do
    parents =
      from(f in Folder,
        where: f.uuid in ^frontier and not is_nil(f.parent_uuid),
        select: f.parent_uuid
      )
      |> repo().all()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.uniq()

    with_ancestors(all, Enum.reduce(parents, seen, &MapSet.put(&2, &1)), parents, depth + 1)
  end

  @doc """
  Whether a restricted viewer (`:viewer_uuid`) may see `file`: only a file they
  uploaded. `nil` for the viewer is unrestricted.
  """
  @spec viewer_can_see_file?(String.t() | nil, map()) :: boolean()
  def viewer_can_see_file?(nil, _file), do: true

  def viewer_can_see_file?(viewer_uuid, %{user_uuid: uploader}),
    do: to_string(uploader) == viewer_uuid

  def viewer_can_see_file?(_viewer_uuid, _file), do: false

  @doc """
  Whether a restricted viewer may see the folder `folder_uuid` of `library_uuid`
  (`viewer_folder_uuids/2`). `nil` for the viewer is unrestricted.
  """
  @spec viewer_can_see_folder?(String.t() | nil, term(), term()) :: boolean()
  def viewer_can_see_folder?(nil, _folder_uuid, _library_uuid), do: true

  def viewer_can_see_folder?(viewer_uuid, folder_uuid, library_uuid),
    do: to_string(folder_uuid) in viewer_folder_uuids(viewer_uuid, library_uuid)

  defp in_library(folders, nil) do
    private = folders |> Enum.map(& &1.library_uuid) |> Libraries.private_among()
    Enum.reject(folders, &(to_string(&1.library_uuid) in private))
  end

  defp in_library(folders, library_uuid) do
    library_uuid = to_string(library_uuid)
    Enum.filter(folders, &(to_string(&1.library_uuid) == library_uuid))
  end

  # Filters out system-managed File rows (Tessera tile chunks + manifests)
  # so they never appear in user-facing listings. Use this in every
  # `list_*` / `count_*` query that powers the MediaBrowser.
  defp exclude_system_managed(query) do
    where(query, [f], f.system_managed == false)
  end

  @doc """
  Gets a single file by ID.
  """
  def get_file(id) when is_binary(id),
    do: repo().get(PhoenixKit.Modules.Storage.File, id)

  @doc """
  Fetches multiple files by UUID in a single query and returns them ordered to
  match `uuids`. Missing UUIDs are silently omitted from the result.
  """
  def get_files(uuids) when is_list(uuids) do
    if uuids == [] do
      []
    else
      rows =
        from(f in PhoenixKit.Modules.Storage.File, where: f.uuid in ^uuids)
        |> repo().all()

      # Preserve the caller's ordering: uuids may carry semantic order (e.g. drag-drop).
      # Duplicate UUIDs in the input produce duplicate structs in the output — callers
      # are responsible for deduplicating if uniqueness is required.
      uuid_index = Map.new(rows, &{&1.uuid, &1})
      Enum.flat_map(uuids, fn id -> if f = uuid_index[id], do: [f], else: [] end)
    end
  end

  @doc """
  Calculates user-specific file checksum (salted with user_uuid).

  This creates a unique checksum per user+file combination for duplicate detection,
  while preserving the original file checksum for popularity queries.

  ## Parameters
    - user_uuid: The user UUID
    - file_checksum: The SHA256 checksum of the file content

    - library_uuid: The library the file is in (optional; nil or Media's
      uuid is Media)

  ## Returns
    String representing the SHA256 checksum of "user_uuid + file_checksum"
    for a file in Media, and of the uploader, the library and the checksum
    for a file in any other library.

  This is the dedup key, and the unique index on it is what holds one copy
  per uploader: a file in Media keeps the key every file has had since
  before libraries existed, and a file in another library folds its library
  in, so the same person may keep the same bytes in Media and in a library
  of their own — one copy in each, never two in one.
  """
  def calculate_user_file_checksum(user_uuid, file_checksum, library_uuid \\ nil) do
    if is_nil(library_uuid) or Libraries.media?(library_uuid) do
      "#{user_uuid}#{file_checksum}"
    else
      "#{user_uuid}:library:#{library_uuid}:#{file_checksum}"
    end
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Gets a file by its user-specific checksum.

  This checks for duplicates for a specific user.
  """
  def get_file_by_user_checksum(user_file_checksum) do
    repo().get_by(PhoenixKit.Modules.Storage.File, user_file_checksum: user_file_checksum)
  end

  @doc """
  Gets a file by its original content checksum (file_checksum).

  This can find files uploaded by any user with the same content.
  Useful for popularity queries.
  """
  def get_file_by_checksum(file_checksum) do
    repo().get_by(PhoenixKit.Modules.Storage.File, file_checksum: file_checksum)
  end

  @doc """
  Creates a new file record.

  This only creates the database record. Use `store_file/4` to actually
  store the file data in storage buckets.
  """
  def create_file(attrs \\ %{}) do
    %PhoenixKit.Modules.Storage.File{}
    |> PhoenixKit.Modules.Storage.File.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Persists a system-managed chunk (e.g. a Tessera DZI tile or manifest)
  into every configured bucket *and* into the storage DB as a File row
  with a single `"original"` FileInstance.

  System-managed Files:

    * have `system_managed: true`
    * carry a `parent_file_uuid` pointing at the source File that this
      chunk was derived from — used for cascade cleanup (the FK in V112
      is `ON DELETE :delete_all`)
    * have no `user_uuid` (the changeset's `validate_system_managed_invariants`
      requires the parent instead)
    * skip the variant pipeline (see `VariantGenerator.should_generate_variants?/1`)
    * are excluded from MediaBrowser listings

  ## Required opts

    * `:parent_file_uuid` — the source image's UUID
    * `:mime_type` — content type
    * `:size` — content size in bytes (taken from disk if omitted)

  ## Optional opts

    * `:file_type` — defaults to `"tile"`
    * `:width` / `:height` — dimensions, if known
    * `:metadata` — JSONB payload (e.g. tile coords)

  Returns `{:ok, %{file: file, instance: instance}}` or `{:error, reason}`.
  """
  def store_system_file(content_path, key, opts) do
    parent_file_uuid = Keyword.fetch!(opts, :parent_file_uuid)
    mime_type = Keyword.fetch!(opts, :mime_type)
    file_type = Keyword.get(opts, :file_type, "tile")

    # Short-circuit when a prior concurrent generation already produced
    # the row. V113's `phoenix_kit_files_system_dedup_index` makes
    # `(parent_file_uuid, file_name)` unique-where-system_managed, so this
    # SELECT is the cheap path of the double-checked-locking pattern that
    # `FileController.serve_tile/2` uses (mutex + re-check + insert).
    case existing_system_file(parent_file_uuid, key) do
      # The row outlived its object (a deletion raced a late write): write
      # the object again, or the chunk would stay missing for good — callers
      # decide to generate by the object's absence.
      {:ok, file, instance} ->
        if Manager.file_exists?(key) do
          {:ok, %{file: file, instance: instance}}
        else
          with {:ok, info} <-
                 store_by_profile(content_path, file.library_uuid, :derived, path_prefix: key) do
            Locations.record_all(key, info.bucket_ids)
            unless info.complete?, do: mark_placement_stale(file.uuid)
            {:ok, %{file: file, instance: instance}}
          end
        end

      :not_found ->
        do_store_system_file(content_path, key, parent_file_uuid, mime_type, file_type, opts)
    end
  end

  defp do_store_system_file(content_path, key, parent_file_uuid, mime_type, file_type, opts) do
    # A tile or manifest is derived from its parent and follows the parent's
    # library (G13).
    library_uuid = parent_library_uuid(parent_file_uuid)

    with {:ok, info} <-
           store_by_profile(content_path, library_uuid, :derived, path_prefix: key),
         {:ok, size} <- file_size(content_path, opts),
         checksum <- calculate_file_hash(content_path),
         file_attrs = %{
           original_file_name: Path.basename(key),
           file_name: key,
           file_path: Path.dirname(key),
           mime_type: mime_type,
           file_type: file_type,
           ext: Path.extname(key),
           file_checksum: checksum,
           user_file_checksum: checksum,
           size: size,
           width: Keyword.get(opts, :width),
           height: Keyword.get(opts, :height),
           status: "active",
           metadata: Keyword.get(opts, :metadata),
           system_managed: true,
           parent_file_uuid: parent_file_uuid
         },
         file_attrs = put_library(file_attrs, library_uuid),
         {:ok, file} <- insert_or_fetch_system_file(file_attrs, parent_file_uuid, key),
         instance_attrs = %{
           variant_name: "original",
           file_name: key,
           mime_type: mime_type,
           ext: Path.extname(key),
           checksum: checksum,
           size: size,
           width: Keyword.get(opts, :width),
           height: Keyword.get(opts, :height),
           processing_status: "completed",
           file_uuid: file.uuid
         },
         {:ok, instance} <- insert_or_fetch_system_instance(instance_attrs, file.uuid) do
      Locations.record_all(key, info.bucket_ids)
      record_placement(file.uuid, info)
      {:ok, %{file: file, instance: instance}}
    else
      # The object may be stored with no row for it (the parent went
      # meanwhile, an insert failed): delete it unless something references
      # the key after all.
      error ->
        _ = delete_stored_objects([key])
        error
    end
  end

  # A system child (a tile, a manifest) lives in its parent's library.
  defp parent_library_uuid(parent_file_uuid) do
    repo().one(
      from(f in PhoenixKit.Modules.Storage.File,
        where: f.uuid == ^parent_file_uuid,
        select: f.library_uuid
      )
    )
  end

  defp existing_system_file(parent_file_uuid, file_name) do
    query =
      from(f in PhoenixKit.Modules.Storage.File,
        where:
          f.system_managed == true and
            f.parent_file_uuid == ^parent_file_uuid and
            f.file_name == ^file_name,
        limit: 1
      )

    case repo().one(query) do
      nil ->
        :not_found

      file ->
        instance =
          repo().one(
            from(i in PhoenixKit.Modules.Storage.FileInstance,
              where: i.file_uuid == ^file.uuid and i.variant_name == "original",
              limit: 1
            )
          )

        {:ok, file, instance}
    end
  end

  defp insert_or_fetch_system_file(attrs, parent_file_uuid, file_name) do
    case create_file(attrs) do
      {:ok, file} ->
        {:ok, file}

      {:error, %Ecto.Changeset{errors: errors}} = err ->
        # Lost the race against a concurrent writer — the dedup index
        # surfaces as a unique-constraint violation on the changeset.
        # Re-fetch the row the other writer just inserted.
        if has_unique_violation?(errors) do
          case existing_system_file(parent_file_uuid, file_name) do
            {:ok, file, _instance} -> {:ok, file}
            :not_found -> err
          end
        else
          err
        end
    end
  end

  defp insert_or_fetch_system_instance(attrs, file_uuid) do
    case create_file_instance(attrs) do
      {:ok, instance} ->
        {:ok, instance}

      {:error, %Ecto.Changeset{errors: errors}} = err ->
        if has_unique_violation?(errors) do
          instance =
            repo().one(
              from(i in PhoenixKit.Modules.Storage.FileInstance,
                where: i.file_uuid == ^file_uuid and i.variant_name == "original",
                limit: 1
              )
            )

          if instance, do: {:ok, instance}, else: err
        else
          err
        end
    end
  end

  defp has_unique_violation?(errors) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  defp file_size(path, opts) do
    case Keyword.get(opts, :size) do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      _ ->
        case Elixir.File.stat(path) do
          {:ok, %{size: size}} when size > 0 -> {:ok, size}
          _ -> {:error, :invalid_size}
        end
    end
  end

  @doc """
  Updates a file.
  """
  def update_file(%PhoenixKit.Modules.Storage.File{} = file, attrs) do
    file
    |> PhoenixKit.Modules.Storage.File.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a file.

  This only removes the database record. Use `delete_file_data/1` to
  remove the actual file data from storage buckets.
  """
  def delete_file(%PhoenixKit.Modules.Storage.File{} = file) do
    repo().delete(file)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking file changes.
  """
  def change_file(%PhoenixKit.Modules.Storage.File{} = file, attrs \\ %{}) do
    PhoenixKit.Modules.Storage.File.changeset(file, attrs)
  end

  @doc """
  Changes a file's `metadata` map from the row as it is NOW.

  `fun` receives the current map and returns the new one, or `:unchanged`.
  The row is re-read and held (`FOR UPDATE`) around it, so two writers of
  different keys — a rotation, the tags, the title copy — cannot overwrite
  each other with the map they each loaded earlier. Every read-modify-write
  of `metadata` belongs here; `update_file/2` with a `metadata:` built from a
  struct in hand is the lost update.

  Returns `{:ok, file}`, `{:error, changeset}` or `{:error, :not_found}`.
  """
  def update_file_metadata(%PhoenixKit.Modules.Storage.File{uuid: uuid}, fun),
    do: update_file_metadata(uuid, fun)

  def update_file_metadata(file_uuid, fun) when is_binary(file_uuid) and is_function(fun, 1) do
    repo().transaction(fn ->
      row =
        from(f in PhoenixKit.Modules.Storage.File,
          where: f.uuid == ^file_uuid,
          lock: "FOR UPDATE"
        )
        |> repo().one()

      with %PhoenixKit.Modules.Storage.File{} <- row,
           %{} = metadata <- fun.(row.metadata || %{}),
           {:ok, updated} <-
             row
             |> PhoenixKit.Modules.Storage.File.details_changeset(%{metadata: metadata})
             |> repo().update() do
        updated
      else
        nil -> repo().rollback(:not_found)
        :unchanged -> row
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  # ===== TRANSLATABLE DETAILS (title, alt text, description) =====

  @doc """
  Returns a changeset for a file's title, alt text and description in one
  language — the form data of the media editors. See
  `PhoenixKit.Modules.Storage.FileDetails`.

  ## Options

    - `:lang` - the language the text is in (default: the primary language)
    - `:primary` - the site's primary language (default: the current one)
  """
  def change_file_details(%PhoenixKit.Modules.Storage.File{} = file, attrs \\ %{}, opts \\ []) do
    file |> FileDetails.from_file(opts[:lang], opts) |> FileDetails.changeset(attrs)
  end

  @doc """
  Saves a file's title, alt text and description in one language.

  `attrs` holds `"title"`, `"alt"` and `"description"`; an absent key keeps
  its current value. The row is re-read and held for the write, and only
  that language's text changes — so another language saved at the same
  time, or a rotation or tag saved since `file` was loaded, survives.

  Takes the options of `change_file_details/3`, and `:metadata` — other
  `metadata` keys to set in the same held write (the detail page's tags), so
  a form that saves both does not need a second, unlocked one. The three
  text keys cannot be set through it.

  Returns `{:ok, file}`,
  `{:error, changeset}` (a `FileDetails` changeset, for the form) or
  `{:error, :not_found}`.
  """
  def update_file_details(%PhoenixKit.Modules.Storage.File{uuid: uuid}, attrs, opts \\ []) do
    # Resolved once, outside the transaction: the default is a settings read.
    opts = Keyword.put_new_lazy(opts, :primary, &PhoenixKit.Utils.Multilang.primary_language/0)

    repo().transaction(fn ->
      row =
        from(f in PhoenixKit.Modules.Storage.File, where: f.uuid == ^uuid, lock: "FOR UPDATE")
        |> repo().one()

      with %PhoenixKit.Modules.Storage.File{} <- row,
           {:ok, details} <-
             row
             |> FileDetails.from_file(opts[:lang], opts)
             |> FileDetails.changeset(attrs)
             |> Ecto.Changeset.apply_action(:update),
           {:ok, updated} <-
             row
             |> PhoenixKit.Modules.Storage.File.details_changeset(
               row
               |> FileDetails.file_attrs(details, opts[:lang], opts)
               |> Map.update!(:metadata, &Map.merge(&1, extra_metadata(opts)))
             )
             |> repo().update() do
        updated
      else
        nil -> repo().rollback(:not_found)
        {:error, changeset} -> repo().rollback(changeset)
      end
    end)
  end

  defp extra_metadata(opts) do
    case opts[:metadata] do
      %{} = extra -> Map.drop(extra, FileDetails.fields())
      _ -> %{}
    end
  end

  @doc "A file's title in `locale` — else the primary language's, else any — or `nil`."
  defdelegate translated_title(file, locale \\ nil, opts \\ []), to: FileDetails

  @doc "A file's alt text in `locale`, ready for an `alt` attribute — `\"\"` when it has none."
  defdelegate translated_alt(file, locale \\ nil, opts \\ []), to: FileDetails

  @doc "A file's description in `locale` — else the primary language's, else any — or `nil`."
  defdelegate translated_description(file, locale \\ nil, opts \\ []), to: FileDetails

  @doc """
  The alt text of many files at once, for a page that renders a list of
  images: `%{file_uuid => alt}` in `locale`, one query. A uuid with no row —
  or naming a system-managed file, which is never listed — is absent; a file
  with no alt text maps to `""`.

  Takes the `:primary` option of `translated_alt/3`.
  """
  def translated_alts(file_uuids, locale \\ nil, opts \\ []) when is_list(file_uuids) do
    opts = Keyword.put_new_lazy(opts, :primary, &PhoenixKit.Utils.Multilang.primary_language/0)

    uuids =
      file_uuids
      |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
      |> Enum.uniq()

    from(f in PhoenixKit.Modules.Storage.File,
      where: f.uuid in ^uuids and f.system_managed == false,
      select: struct(f, [:uuid, :metadata, :data])
    )
    |> repo().all()
    |> Map.new(&{&1.uuid, FileDetails.translated_alt(&1, locale, opts)})
  end

  @doc """
  The alt text of the file `file_uuid` names, in `locale` — `""` when the
  file has none, does not exist or is system-managed.
  """
  def translated_alt_by_uuid(file_uuid, locale \\ nil, opts \\ []) do
    [file_uuid] |> translated_alts(locale, opts) |> Map.get(file_uuid, "")
  end

  # ===== ORPHAN DETECTION =====

  @doc """
  Returns a list of orphaned files (files not referenced by any known entity).

  ## Options

    - `:limit` - Maximum number of results
    - `:offset` - Number of results to skip

  """
  def find_orphaned_files(opts \\ []) do
    orphaned_files_query()
    |> where_library(opts[:library_uuid])
    |> where_viewer(opts[:viewer_uuid])
    |> order_by([f], desc: f.inserted_at)
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> repo().all()
  end

  @doc """
  Returns the count of orphaned files.

  When scope_folder_id is set, returns 0 because orphaned files (folder_uuid IS NULL)
  are always outside any non-nil scope.
  """
  def count_orphaned_files(scope_folder_id \\ nil, opts \\ [])

  def count_orphaned_files(scope_folder_id, _opts) when not is_nil(scope_folder_id), do: 0

  def count_orphaned_files(nil, opts) do
    orphaned_files_query()
    |> where_library(opts[:library_uuid])
    |> where_viewer(opts[:viewer_uuid])
    |> repo().aggregate(:count, :uuid)
  end

  @doc """
  Returns true if the given file UUID is not referenced by any known entity.
  """
  def file_orphaned?(file_uuid) when is_binary(file_uuid) do
    # `orphaned_files_query/0` already leaves private libraries out.
    orphaned_files_query()
    |> where([f], f.uuid == ^file_uuid)
    |> repo().exists?()
  end

  @doc """
  Queues a list of file UUIDs for orphan cleanup via Oban.

  Each file is moved to the trash, never deleted, after a 60-second delay
  that protects against race conditions (another entity may reference the
  file), and only if it is still orphaned then. From the trash it can be
  restored until the daily prune deletes it after `trash_retention_days`.
  """
  def queue_file_cleanup(file_uuids) when is_list(file_uuids) do
    alias PhoenixKit.Modules.Storage.Workers.DeleteOrphanedFileJob

    file_uuids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn uuid ->
      %{"file_uuid" => uuid}
      |> DeleteOrphanedFileJob.new(schedule_in: 60)
      |> Oban.insert()
    end)
  end

  defp orphaned_files_query do
    existing = existing_optional_tables()
    protected_uuids = protected_file_uuids()

    # Core check — phoenix_kit_users always exists; exclude trashed files
    # and system-managed media (tile chunks never count as orphans).
    base =
      from(f in PhoenixKit.Modules.Storage.File,
        where:
          f.status != "trashed" and f.system_managed == false and
            fragment(
              "NOT EXISTS (SELECT 1 FROM phoenix_kit_users u WHERE u.custom_fields->>'avatar_file_uuid' = ?::text)",
              f.uuid
            )
      )

    # A private library's files (every user library) are never orphans,
    # whatever library a caller names: nothing in the site references them,
    # so every file at a user library's root would look unreferenced and
    # "Delete all orphaned" inside that library would delete them all.
    base = Libraries.exclude_private(base)

    # Exclude UUIDs that the parent app has explicitly marked as protected
    base =
      if protected_uuids == [] do
        base
      else
        where(base, [f], f.uuid not in ^protected_uuids)
      end

    # Optional module tables — only included if the table exists
    optional_checks = [
      # Portal submissions hold their attachments in a JSONB array rather
      # than an FK column, so the reference is invisible to a plain join —
      # which would make every PUBLISHED issue image look like an orphan
      # and hand it to the delete job. `?` is the file uuid as text; the
      # `jsonb` cast is what lets `?` match an element of the array.
      {"phoenix_kit_project_portal_submissions",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_project_portal_submissions ps WHERE ps.file_uuids @> to_jsonb(ARRAY[?::text]))",
           f.uuid
         )
       )},
      {"phoenix_kit_post_media",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_post_media pm WHERE pm.file_uuid = ?)",
           f.uuid
         )
       )},
      {"phoenix_kit_ticket_attachments",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_ticket_attachments ta WHERE ta.file_uuid = ?)",
           f.uuid
         )
       )},
      {"phoenix_kit_post_groups",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_post_groups pg WHERE pg.cover_image_uuid = ?)",
           f.uuid
         )
       )},
      {"phoenix_kit_shop_products",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_products sp WHERE sp.featured_image_uuid = ?) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_products sp WHERE ? = ANY(sp.image_uuids)) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_products sp WHERE sp.file_uuid = ?)",
           f.uuid,
           f.uuid,
           f.uuid
         )
       )},
      {"phoenix_kit_shop_categories",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_categories sc WHERE sc.image_uuid = ?)",
           f.uuid
         )
       )},
      # The catalogue module (phoenix_kit_catalogue) stores its image
      # references inside the JSONB `data` column rather than dedicated
      # columns — a plain join would miss them entirely, and a
      # live catalogue item, category, or catalogue-record image would
      # look orphaned and get queued for deletion by DeleteOrphanedFileJob.
      #
      # `media_order` is expanded into its elements and matched by equality,
      # never tested per file with `data->'media_order' @> …`: `@>` against
      # the file can't be hashed, so Postgres ran it for every file × every
      # row, unpacking each row's whole `data` every time — 8 s for 3k files
      # and 700 items on a live shop, on every media page load and folder
      # click. Expanded, the rows are read once and hash-anti-joined (0.15 s).
      # The CASE keeps a non-array `media_order` from raising, and only a
      # top-level string element matches — the same answer `@>` gave. The
      # single-file check (`file_orphaned?/1`, run by DeleteOrphanedFileJob)
      # pays for this: it expands every row too, ~5 ms instead of ~2.6 ms at
      # 700 items — a background job, against 8 s on every media page.
      {"phoenix_kit_cat_items",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_items ci WHERE ci.data->>'featured_image_uuid' = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_items ci CROSS JOIN LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(ci.data->'media_order') = 'array' THEN ci.data->'media_order' ELSE '[]'::jsonb END) AS mo(file_uuid) WHERE mo.file_uuid = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_items ci WHERE ci.data->'ecommerce'->>'file_uuid' = ?::text)",
           f.uuid,
           f.uuid,
           f.uuid
         )
       )},
      {"phoenix_kit_cat_categories",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_categories cc WHERE cc.data->>'featured_image_uuid' = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_categories cc CROSS JOIN LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(cc.data->'media_order') = 'array' THEN cc.data->'media_order' ELSE '[]'::jsonb END) AS mo(file_uuid) WHERE mo.file_uuid = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_categories cc WHERE cc.data->'ecommerce'->>'image_uuid' = ?::text)",
           f.uuid,
           f.uuid,
           f.uuid
         )
       )},
      {"phoenix_kit_cat_catalogues",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_catalogues ct WHERE ct.data->>'featured_image_uuid' = ?::text) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_catalogues ct CROSS JOIN LATERAL jsonb_array_elements_text(CASE WHEN jsonb_typeof(ct.data->'media_order') = 'array' THEN ct.data->'media_order' ELSE '[]'::jsonb END) AS mo(file_uuid) WHERE mo.file_uuid = ?::text)",
           f.uuid,
           f.uuid
         )
       )},
      # Unlike the three JSONB-backed tables above, cat_pdfs references its
      # source file through a plain NOT NULL `file_uuid` FK with
      # ON DELETE RESTRICT — the same shape as phoenix_kit_post_media. Missing
      # this entry would let DeleteOrphanedFileJob delete the physical file
      # data for a PDF still in active use, then crash on the FK-RESTRICT
      # violation while deleting the phoenix_kit_files row, leaving a
      # dangling record and a broken PDF.
      {"phoenix_kit_cat_pdfs",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_cat_pdfs cp WHERE cp.file_uuid = ?)",
           f.uuid
         )
       )},
      {"phoenix_kit_publishing_contents",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_publishing_contents pc WHERE pc.data->>'featured_image_uuid' = ?::text)",
           f.uuid
         )
       )},
      {"phoenix_kit_publishing_versions",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_publishing_versions pv WHERE pv.data->>'featured_image_uuid' = ?::text)",
           f.uuid
         )
       )},
      {"phoenix_kit_posts",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_posts p WHERE p.metadata->>'featured_image_uuid' = ?::text)",
           f.uuid
         )
       )},
      {"phoenix_kit_entity_data",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_entity_data ed WHERE ed.data::text LIKE '%' || ?::text || '%')",
           f.uuid
         )
       )}
    ]

    query =
      Enum.reduce(optional_checks, base, fn {table, condition}, query ->
        if table in existing do
          where(query, ^condition)
        else
          query
        end
      end)

    Enum.reduce(file_reference_sources(), query, &apply_reference_source(&2, &1))
  end

  defp existing_optional_tables do
    repo = repo()

    %{rows: rows} =
      repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE 'phoenix_kit_%'"
      )

    List.flatten(rows)
  end

  # Returns UUIDs that should never be considered orphans, as configured by the parent app.
  #
  # Parent apps can register protected file UUIDs in their config:
  #
  #   config :phoenix_kit, :protected_file_uuids, ["uuid1", "uuid2", ...]
  #
  # Or via a zero-arity function/MFA for dynamic resolution:
  #
  #   config :phoenix_kit, :protected_file_uuids, {MyApp.Media, :all_uuids, []}
  #   config :phoenix_kit, :protected_file_uuids, fn -> MyApp.Media.all_uuids() end
  #
  defp protected_file_uuids do
    case Application.get_env(:phoenix_kit, :protected_file_uuids, []) do
      uuids when is_list(uuids) -> uuids
      fun when is_function(fun, 0) -> fun.()
      {mod, fun, args} -> apply(mod, fun, args)
    end
  end

  # Host-registered sources for the orphan-file check, as configured by the
  # parent app (see the "Protecting host-owned files" section of this
  # module's moduledoc):
  #
  #   config :phoenix_kit, :file_reference_sources, [
  #     {MyApp.Media, :file_reference_sources}
  #   ]
  #
  #   def file_reference_sources do
  #     [
  #       dynamic(
  #         [f],
  #         fragment(
  #           "NOT EXISTS (SELECT 1 FROM my_app_orders o WHERE o.data->>'featured_image_uuid' = ?::text)",
  #           f.uuid
  #         )
  #       )
  #     ]
  #   end
  #
  # Each entry is `{module, function}` / `{module, function, args}`, called
  # for a list of `Ecto.Query.dynamic/2` expressions that are ANDed onto the
  # orphan query verbatim — each one is expected to BE a `NOT EXISTS` test,
  # nothing here negates it. A plain `{table, column}` tuple is shorthand for
  # a native column reference and `{table, :jsonb_key, key}` for a
  # `data->>'key'` pointer; those two build their own `NOT EXISTS`.
  defp file_reference_sources do
    Application.get_env(:phoenix_kit, :file_reference_sources, [])
  end

  defp apply_reference_source(query, {table, column})
       when is_binary(table) and (is_binary(column) or is_atom(column)) do
    if host_table_exists?(table) do
      where(query, ^shorthand_column_dynamic(table, to_string(column)))
    else
      reference_source_failed(query, "table #{table} does not exist")
    end
  end

  defp apply_reference_source(query, {table, :jsonb_key, key})
       when is_binary(table) and is_binary(key) do
    if host_table_exists?(table) do
      where(query, ^shorthand_jsonb_dynamic(table, key))
    else
      reference_source_failed(query, "table #{table} does not exist")
    end
  end

  defp apply_reference_source(query, {module, fun}) when is_atom(module) and is_atom(fun) do
    apply_reference_source_mfa(query, module, fun, [])
  end

  defp apply_reference_source(query, {module, fun, args})
       when is_atom(module) and is_atom(fun) and is_list(args) do
    apply_reference_source_mfa(query, module, fun, args)
  end

  defp apply_reference_source(query, other) do
    reference_source_failed(query, "invalid entry #{inspect(other)}")
  end

  defp apply_reference_source_mfa(query, module, fun, args) do
    dynamics = apply(module, fun, args)
    Enum.reduce(dynamics, query, fn condition, acc -> where(acc, ^condition) end)
  rescue
    error ->
      reference_source_failed(
        query,
        "#{inspect(module)}.#{fun}/#{length(args)} raised: #{Exception.message(error)}"
      )
  catch
    kind, reason ->
      reference_source_failed(
        query,
        "#{inspect(module)}.#{fun}/#{length(args)} #{kind}: #{inspect(reason)}"
      )
  end

  # A source that cannot be built FAILS CLOSED: the orphan query matches
  # nothing until the source is fixed. Skipping it would drop that host's
  # `NOT EXISTS` guard, and every file only the host references would read as
  # an orphan — one cleanup run from losing its row and its bytes. A cleanup
  # that finds nothing is the recoverable side of that choice.
  defp reference_source_failed(query, reason) do
    Logger.error(
      "phoenix_kit: file_reference_sources #{reason} — no file is treated as orphaned " <>
        "until this source is fixed"
    )

    where(query, [f], false)
  end

  # Resolved through the search path, the way the shorthand's unqualified
  # table name resolves when the query runs — a host table in a named schema
  # on the path counts, one Postgres cannot see does not.
  defp host_table_exists?(table) do
    %{rows: [[exists?]]} =
      repo().query!("SELECT to_regclass(quote_ident($1)) IS NOT NULL", [table])

    exists?
  end

  defp shorthand_column_dynamic(table, column) do
    dynamic(
      [f],
      fragment(
        "NOT EXISTS (SELECT 1 FROM ? WHERE ?.?::text = ?::text)",
        identifier(^table),
        identifier(^table),
        identifier(^column),
        f.uuid
      )
    )
  end

  defp shorthand_jsonb_dynamic(table, key) do
    dynamic(
      [f],
      fragment(
        "NOT EXISTS (SELECT 1 FROM ? WHERE (?.data->>?) = ?::text)",
        identifier(^table),
        identifier(^table),
        ^key,
        f.uuid
      )
    )
  end

  # ===== FILE INSTANCES =====

  @doc """
  Returns a list of file instances for a given file.
  """
  def list_file_instances(file_uuid) do
    FileInstance
    |> where([fi], fi.file_uuid == ^file_uuid)
    |> order_by(asc: :variant_name)
    |> repo().all()
  end

  @doc """
  Gets a single file instance by ID.
  """
  def get_file_instance(id), do: repo().get(FileInstance, id)

  @doc """
  Gets a file instance by file UUID and variant name.
  """
  def get_file_instance_by_name(file_uuid, variant_name) do
    repo().get_by(FileInstance, file_uuid: file_uuid, variant_name: variant_name)
  end

  @doc """
  Gets the bucket UUIDs where a file instance is stored.

  Returns a list of bucket UUIDs from the file_locations for the given file instance.
  """
  def get_file_instance_bucket_uuids(file_instance_uuid) do
    FileLocation
    |> where([fl], fl.file_instance_uuid == ^file_instance_uuid and fl.status == "active")
    |> select([fl], fl.bucket_uuid)
    |> repo().all()
  end

  @doc """
  Creates a new file instance.
  """
  def create_file_instance(attrs \\ %{}) do
    %FileInstance{}
    |> FileInstance.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a file instance.
  """
  def update_file_instance(%FileInstance{} = instance, attrs) do
    instance
    |> FileInstance.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a file instance.
  """
  def delete_file_instance(%FileInstance{} = instance) do
    repo().delete(instance)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking file instance changes.
  """
  def change_file_instance(%FileInstance{} = instance, attrs \\ %{}) do
    FileInstance.changeset(instance, attrs)
  end

  @doc """
  Updates a file instance's processing status.
  """
  def update_instance_status(instance, status)
      when status in ["pending", "processing", "completed", "failed"] do
    update_file_instance(instance, %{processing_status: status})
  end

  @doc """
  Updates a file instance with file information after processing.
  """
  def update_instance_with_file_info(instance, file_path, dimensions \\ nil) do
    {:ok, stat} = Elixir.File.stat(file_path)
    size = stat.size
    checksum = calculate_file_hash(file_path)

    attrs = %{
      checksum: checksum,
      size: size
    }

    attrs =
      case dimensions do
        {width, height} ->
          Map.merge(attrs, %{width: width, height: height})

        _ ->
          attrs
      end

    update_file_instance(instance, attrs)
  end

  # ===== CONFIGURATION =====

  @impl PhoenixKit.Module
  @doc """
  Gets the current storage configuration.
  """
  def get_config do
    buckets = list_buckets()
    active_count = Enum.count(buckets, & &1.enabled)

    %{
      module_enabled: true,
      default_path: get_default_path(),
      redundancy_copies: redundancy_copies(),
      auto_generate_variants: get_auto_generate_variants(),
      default_bucket_uuid: get_default_bucket_uuid(),
      buckets_count: length(buckets),
      active_buckets_count: active_count
    }
  end

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @impl PhoenixKit.Module
  def module_key, do: "storage"

  @impl PhoenixKit.Module
  def job_kinds do
    [
      PhoenixKit.Modules.Storage.Jobs.CaptureDateBackfill,
      PhoenixKit.Modules.Storage.Jobs.ChecksumBackfill,
      PhoenixKit.Modules.Storage.Jobs.LocationBackfill,
      PhoenixKit.Modules.Storage.Jobs.PurgeLibrary,
      PhoenixKit.Modules.Storage.Jobs.Reconcile
    ]
  end

  @impl PhoenixKit.Module
  def module_name, do: "Storage"

  @impl PhoenixKit.Module
  def enabled?, do: module_enabled?()

  @impl PhoenixKit.Module
  def enable_system, do: {:ok, :always_enabled}

  @impl PhoenixKit.Module
  def disable_system, do: {:ok, :always_enabled}

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "storage",
      label: "Storage",
      icon: "hero-circle-stack",
      description:
        "Distributed file storage with multi-location redundancy. Holders use the " <>
          "storage libraries they own or are a member of, when user libraries are on.",
      sub_permissions: [
        %{
          key: "create_library",
          label: "Create libraries",
          description: "Create storage libraries of their own (up to the per-user limit)"
        },
        %{
          key: "own_storage",
          label: "Use their own storage",
          description:
            "Keep a library they create on their own S3-compatible bucket, when the site allows it (also needs the Integrations permission, for the bucket's keys)"
        }
      ]
    }
  end

  @doc """
  Gets the default storage path for local file uploads (relative path).

  Returns the configured relative path or the default "priv/uploads" if not set.
  """
  def get_default_path do
    Settings.get_setting_cached("storage_default_path", @default_path)
  end

  @doc """
  Gets the absolute path for local storage.
  """
  def get_absolute_path, do: Local.resolve_path(get_default_path())

  @doc """
  What a local storage path comes to on disk.

  A relative path is taken from the directory the application started in, the
  same one the local provider writes under (`Local.resolve_path/1`).

  Returns `{:ok, absolute}` for a writable directory, `{:missing, absolute}`
  when nothing is there yet, `{:not_directory, absolute}` for a file and
  `{:not_writable, absolute}` for a directory that cannot be written to.
  """
  @spec local_path_status(String.t()) ::
          {:ok | :missing | :not_directory | :not_writable, String.t()}
  def local_path_status(path) when is_binary(path) do
    expanded_path = Local.resolve_path(path)

    cond do
      not Elixir.File.exists?(expanded_path) -> {:missing, expanded_path}
      not Elixir.File.dir?(expanded_path) -> {:not_directory, expanded_path}
      not writable?(expanded_path) -> {:not_writable, expanded_path}
      true -> {:ok, expanded_path}
    end
  end

  @doc """
  Validates and normalizes a storage path.

  Returns `{:ok, relative_path}` if valid, or error tuple if invalid.
  """
  def validate_and_normalize_path(path) when is_binary(path) do
    case local_path_status(path) do
      {:ok, expanded_path} ->
        {:ok, Path.relative_to(expanded_path, Local.resolve_path("."))}

      {:missing, expanded_path} ->
        {:error, :does_not_exist, expanded_path}

      {:not_directory, expanded_path} ->
        {:error, "Path is not a directory: #{expanded_path}"}

      {:not_writable, expanded_path} ->
        {:error, "Directory is not writable: #{expanded_path}"}
    end
  end

  def validate_and_normalize_path(_path), do: {:error, :invalid_path}

  @doc """
  Updates the default storage path.
  """
  def update_default_path(relative_path) when is_binary(relative_path) do
    Settings.update_setting("storage_default_path", relative_path)
  end

  @doc """
  Creates a directory if it doesn't exist.
  """
  def create_directory(path) when is_binary(path) do
    case Elixir.File.mkdir_p(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_directory(_path), do: {:error, :invalid_path}

  # ===== FILE STORAGE OPERATIONS =====

  @doc """
  Stores a file in the storage system.

  This will:
  1. Store the file in multiple buckets based on redundancy settings
  2. Generate variants if enabled
  3. Create database records for the file and its variants

  ## Options

  - `:filename` - Original filename (required)
  - `:content_type` - MIME type (required)
  - `:size_bytes` - File size in bytes (required)
  - `:user_uuid` - **Required unless the file is system-owned.** The changeset
    rejects a non-system file with no owner, so omitting this returns a
    changeset error rather than an unowned file.
  - `:metadata` - Additional metadata map

  ## ⚠️ How to actually serve the stored file

  This is where hosts get stuck and hand-roll their own uploads instead.

  **`public_url/2` returns `nil` for the local provider.** That is not a bug or
  a missing feature — local files are deliberately not served from a public
  directory. Serve them through the signed route instead:

      PhoenixKit.Modules.Storage.URLSigner.signed_url(file.uuid, "original")
      #=> "/phoenix_kit/file/<uuid>/original/<token>"

  which the router answers at `/file/:uuid/:variant/:token`. Pass a variant
  name (`"original"`, `"medium"`, …) to get that rendition.

  ### What the signature is and is not

  Treat these URLs as *obscured*, **not** as capability URLs, and do not use
  them for material where unauthorized access matters:

  - the token is the first 4 hex characters of an MD5 — a ~65k space, and
    brute-forceable for a targeted file;
  - tokens **never expire**, though the 401 says "Invalid or expired token";
  - with no `secret_key_base` the token degrades to a predictable no-secret hash.

  `/api/files/:uuid/info` no longer hands these URLs out anonymously — it now
  requires authentication and only answers for a file the caller owns (or an
  Owner/Admin). The token-strength and expiry points above remain open.

  These are recorded as known work in core's `AGENTS.md` under "Signed file-URL
  hardening". Current usage (public images) is within what the scheme actually
  provides; sensitive files are not.
  """
  def store_file(source_path, opts \\ []) do
    filename = Keyword.fetch!(opts, :filename)
    content_type = Keyword.fetch!(opts, :content_type)
    size_bytes = Keyword.fetch!(opts, :size_bytes)
    user_uuid = Keyword.get(opts, :user_uuid)
    metadata = Keyword.get(opts, :metadata, %{})

    # Validate required fields
    if Elixir.File.exists?(source_path) do
      # Calculate file checksum
      file_checksum = calculate_file_hash(source_path)

      # Calculate user-specific checksum for duplicate detection
      user_file_checksum = calculate_user_file_checksum(user_uuid, file_checksum)

      # Check if this user already uploaded this file
      case get_file_by_user_checksum(user_file_checksum) do
        %PhoenixKit.Modules.Storage.File{} = existing_file ->
          # File already exists for this user, return existing file
          {:ok, existing_file}

        nil ->
          # New file for this user, proceed with storage
          store_new_file(
            source_path,
            file_checksum,
            user_file_checksum,
            filename,
            content_type,
            size_bytes,
            user_uuid,
            metadata
          )
      end
    else
      {:error, "Source file does not exist"}
    end
  end

  @doc """
  Retrieves a file from storage by file UUID.

  Will try buckets in priority order until the file is found.
  """
  def retrieve_file(file_uuid) do
    case retrieve_original(file_uuid) do
      {:ok, path, file, _instance} -> {:ok, path, file}
      error -> error
    end
  end

  @doc """
  Like `retrieve_file/1`, and also returns the `"original"` instance the
  bytes were read from: `{:ok, temp_path, file, instance}`.

  An image edit can replace a file's original at any moment, and the file
  row and the instance are two reads. Something derived from the bytes (a
  variant, the dimensions) belongs to the file only while
  `instance.file_name` is still its original — check that when recording
  the result (`original_key?/2`).
  """
  def retrieve_original(file_uuid) do
    case get_file(file_uuid) do
      %PhoenixKit.Modules.Storage.File{} = file ->
        # Look up the original variant path from file_instances table
        case get_file_instance_by_name(file_uuid, "original") do
          %FileInstance{file_name: file_path} = instance ->
            # Keep a media extension: ImageMagick identifies some formats
            # (ICO among them) by extension alone, so an extensionless copy
            # fails every variant with "no decode delegate". Non-media
            # extensions are dropped — see `Manager.temp_extension/1`.
            destination_path = generate_temp_path() <> Manager.temp_extension(file_path)

            case Manager.retrieve_file(file_path,
                   destination_path: destination_path
                 ) do
              {:ok, _path} -> {:ok, destination_path, file, instance}
              error -> error
            end

          nil ->
            {:error, "Original file instance not found"}
        end

      nil ->
        {:error, "File not found"}
    end
  end

  @doc false
  # Whether `key` is still the object `file_uuid`'s original instance points
  # at. Call it in a transaction holding the file row (`FOR SHARE` or
  # stronger), which an image edit's swap needs `FOR UPDATE`.
  def original_key?(file_uuid, key) do
    from(fi in FileInstance,
      where: fi.file_uuid == ^file_uuid and fi.variant_name == "original" and fi.file_name == ^key
    )
    |> repo().exists?()
  end

  @doc """
  Retrieves a file by its hash.
  """
  def retrieve_file_by_hash(hash) do
    case get_file_by_checksum(hash) do
      %PhoenixKit.Modules.Storage.File{} = file ->
        retrieve_file(file.uuid)

      nil ->
        {:error, "File not found"}
    end
  end

  @doc """
  Deletes the stored objects of a file's instances from every bucket —
  except an object another file's instance row still references (a
  cross-user deduplicated copy, an edited image's backup), which stays.
  The rows themselves are left alone; see `delete_file_completely/1`.
  """
  def delete_file_data(%PhoenixKit.Modules.Storage.File{} = file) do
    case list_file_instances(file.uuid) do
      [] ->
        {:error, "No file instances found"}

      instances ->
        instances
        |> Enum.map(& &1.file_name)
        |> delete_stored_objects(exclude_file_uuids: [file.uuid])
    end
  end

  @doc false
  # Of `keys`, those no instance row references — optionally ignoring the rows
  # of `:exclude_file_uuids` (files about to go). Call it in the transaction
  # that removes the rows, after the removal, under `lock_storage_paths/1`.
  def unreferenced_keys(keys, opts \\ []) do
    keys = keys |> Enum.reject(&is_nil/1) |> Enum.uniq()
    excluded = Keyword.get(opts, :exclude_file_uuids, [])

    if keys == [] do
      []
    else
      referenced =
        from(fi in FileInstance,
          where: fi.file_name in ^keys and fi.file_uuid not in ^excluded,
          distinct: true,
          select: fi.file_name
        )
        |> repo().all()
        |> MapSet.new()

      Enum.reject(keys, &MapSet.member?(referenced, &1))
    end
  end

  @doc false
  # Serialises everything that adds or removes references to the objects
  # under these storage directories (deletion, a cross-user clone, an image
  # edit's swap) for the rest of the current transaction. Without it a clone
  # could reference a key in the moment between "nobody references it" and
  # the object's deletion.
  def lock_storage_paths(paths) do
    paths
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn path ->
      repo().query!(
        "SELECT pg_advisory_xact_lock(hashtext('phoenix_kit_storage_path:' || $1))",
        [path],
        log: false
      )
    end)
  end

  @doc false
  # Deletes the objects at `keys` from every bucket — each only if no instance
  # row references it (ignoring the rows of `:exclude_file_uuids`). The check
  # and the deletion happen together under the key's directory lock, because
  # keys are content-addressed and can be written again: a job that stores
  # the same bytes and publishes a row for them takes the same lock and
  # checks the object still exists, so it either sees the deletion or keeps
  # the key referenced.
  #
  # Callers pass the keys whose rows they removed, after their transaction
  # committed. Best-effort: a failure is logged and the rest still go. `:ok`
  # when every unreferenced key went (or there were none).
  def delete_stored_objects(keys, opts \\ []) do
    excluded = Keyword.get(opts, :exclude_file_uuids, [])

    results =
      keys
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.group_by(&Path.dirname/1)
      |> Enum.flat_map(fn {dir, dir_keys} -> delete_unreferenced(dir, dir_keys, excluded) end)

    if Enum.all?(results, &(&1 == :ok)),
      do: :ok,
      else: {:error, "Failed to delete some objects"}
  end

  defp delete_unreferenced(dir, keys, excluded) do
    repo().transaction(
      fn ->
        lock_storage_paths([dir])

        owned = owned_buckets_for_dir(dir)

        keys
        |> unreferenced_keys(exclude_file_uuids: excluded)
        |> Enum.map(&delete_stored_object(&1, owned))
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, results} ->
        results

      {:error, reason} ->
        Logger.warning("Storage: could not delete objects under #{dir}: #{inspect(reason)}")
        [{:error, reason}]
    end
  end

  @doc false
  # Removes `instance`'s location on `bucket` (V205, the reconciler), and the
  # object there when nothing else on that bucket still needs it: no other
  # active location on that bucket names the key, and no instance stored
  # under the key is still unchecked (its buckets are not all known yet).
  # Only that bucket is touched (G11): a key is shared by cross-user copies
  # and the same key may rightly stay on other buckets. Under the key's
  # directory lock, like every other deletion.
  def unlink_location(%FileInstance{} = instance, %Bucket{} = bucket) do
    key = instance.file_name

    repo().transaction(
      fn ->
        lock_storage_paths([Path.dirname(key)])

        # Re-read under the lock: an image edit may have moved this row to
        # another key since it was read; then there is nothing to unlink.
        if repo().exists?(
             from(i in FileInstance, where: i.uuid == ^instance.uuid and i.file_name == ^key)
           ) do
          from(l in FileLocation,
            where:
              l.file_instance_uuid == ^instance.uuid and l.bucket_uuid == ^bucket.uuid and
                l.path == ^key
          )
          |> repo().delete_all()

          if key_needed_on?(key, bucket), do: :kept, else: delete_from(bucket, key)
        else
          :kept
        end
      end,
      timeout: :infinity
    )
  end

  # Whether the object at `key` must stay on `bucket`: another active
  # location there names it, an instance under the key is unchecked (its
  # buckets are not all known), or an upload into the key's directory is in
  # flight (`upload_in_flight?/2`).
  defp key_needed_on?(key, bucket) do
    repo().exists?(
      from(l in FileLocation,
        where: l.path == ^key and l.bucket_uuid == ^bucket.uuid and l.status == "active"
      )
    ) or
      repo().exists?(from(i in Locations.unchecked_query(), where: i.file_name == ^key)) or
      upload_in_flight?(key, nil)
  end

  # An upload into the key's directory whose row exists and whose instance
  # does not yet: an upload writes the object before it records it. Its own
  # row (`own_file_uuid`) does not count.
  defp upload_in_flight?(key, own_file_uuid) do
    dir = Path.dirname(key)

    query =
      from(f in PhoenixKit.Modules.Storage.File,
        as: :file,
        where:
          f.file_path == ^dir and f.status == "processing" and
            not exists(
              from(i in FileInstance,
                where: i.file_uuid == parent_as(:file).uuid and i.file_name == ^key,
                select: 1
              )
            )
      )

    query = if own_file_uuid, do: where(query, [f], f.uuid != ^own_file_uuid), else: query
    repo().exists?(query)
  end

  @doc false
  # Undoes a write that made fewer copies than required: deletes `key` from
  # `bucket_uuids`, under the key's directory lock, and only when nothing
  # else needs the object there (keys are content-addressed: a row may name
  # it, or another upload of the same bytes be writing it).
  def undo_store(key, bucket_uuids, own_file_uuid) do
    repo().transaction(
      fn ->
        lock_storage_paths([Path.dirname(key)])

        if unreferenced_keys([key]) != [] and not upload_in_flight?(key, own_file_uuid) do
          for uuid <- bucket_uuids, %Bucket{} = bucket <- [get_bucket(uuid)] do
            Manager.delete_from_bucket(bucket, key)
          end
        end

        :ok
      end,
      timeout: :infinity
    )

    :ok
  end

  defp delete_from(bucket, key) do
    case Manager.delete_from_bucket(bucket, key) do
      :ok ->
        :deleted

      error ->
        # The row is gone either way: the object is no longer this file's
        # copy. A leftover object is only space, never a wrong answer.
        Logger.warning("Storage: could not delete #{key} from #{bucket.name}: #{inspect(error)}")
        :left_behind
    end
  end

  @doc false
  # Deletes `instances` of `file` (sizes its variant set no longer has,
  # V205) and every object they referenced that nothing references any
  # more, the way `delete_file_completely/1` deletes a file's.
  def remove_instances(%PhoenixKit.Modules.Storage.File{} = file, instances) do
    uuids = Enum.map(instances, & &1.uuid)
    keys = Enum.map(instances, & &1.file_name)

    repo().transaction(fn ->
      lock_storage_paths(Enum.map(keys, &Path.dirname/1))

      from(i in FileInstance, where: i.uuid in ^uuids and i.file_uuid == ^file.uuid)
      |> repo().delete_all()

      unreferenced_keys(keys)
    end)
    |> case do
      {:ok, keys} -> delete_stored_objects(keys)
      {:error, reason} -> {:error, reason}
    end
  end

  # The object goes from every bucket of the site, and from the owner's own
  # buckets when the key belongs to a user's library (V206). `Manager.delete_file/1`
  # only reaches the site's pool, and by the time a key is deleted its location
  # rows are gone, so a user's bucket is found through the library that owns the
  # key's first segment (`owned_buckets_for_dir/1`).
  defp delete_stored_object(key, owned) do
    results = [Manager.delete_file(key) | Enum.map(owned, &delete_from_owned(&1, key))]

    case Enum.find(results, &(&1 != :ok)) do
      nil ->
        :ok

      error ->
        Logger.warning("Storage: could not delete #{key}: #{inspect(error)}")
        error
    end
  end

  defp delete_from_owned(%Bucket{} = bucket, key) do
    case Manager.delete_from_bucket(bucket, key) do
      :ok -> :ok
      error -> {:error, {bucket.name, error}}
    end
  end

  # The user's own buckets in the storage profile of the library whose
  # `key_prefix` is the first segment of `dir`: where that library's objects may
  # live besides the site's buckets. Found through the library's profile, not its
  # owner: a library of a deleted user has no owner left (its purge is what runs
  # then), and a user with two libraries on two buckets must only touch the right
  # one. Nothing for a key of a site library (no user library has its prefix).
  # One query per directory.
  @doc false
  def owned_buckets_for_dir(dir) do
    case dir |> String.split("/", parts: 2) |> hd() do
      prefix when prefix in ["", "."] ->
        []

      prefix ->
        from(l in Library,
          join: pb in PhoenixKit.Modules.Storage.ProfileBucket,
          on: pb.profile_uuid == l.storage_profile_uuid,
          join: b in Bucket,
          on: b.uuid == pb.bucket_uuid,
          where: l.kind == "user" and l.key_prefix == ^prefix and not is_nil(b.owner_uuid),
          distinct: true,
          select: b
        )
        |> repo().all()
    end
  end

  # ===== TRASH =====

  @doc "Moves a file to trash (soft-delete). Sets status to 'trashed' and records timestamp."
  def trash_file(%PhoenixKit.Modules.Storage.File{} = file) do
    case mark_trashed(file) do
      {:ok, updated} = result ->
        broadcast_file_trashed(updated.uuid)
        result

      error ->
        error
    end
  end

  def trash_file(file_uuid) when is_binary(file_uuid) do
    case get_file(file_uuid) do
      nil -> {:error, :not_found}
      file -> trash_file(file)
    end
  end

  # The trash write without the announcement, for a caller inside a
  # transaction that broadcasts once it commits.
  defp mark_trashed(file) do
    file
    |> Ecto.Changeset.change(%{
      status: "trashed",
      trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> repo().update()
  end

  # Sizes are not made or remade for a file in the trash (V205): a restored
  # file is checked against its library's variant set again.
  defp variants_stale_after_restore(file_uuids) do
    from(f in PhoenixKit.Modules.Storage.File, where: f.uuid in ^file_uuids)
    |> repo().update_all(set: [placed_variant_revision: 0])

    ReconcileJob.enqueue()
  end

  @doc """
  Restores a trashed file back to active status.

  Back into a folder that is still there: the file's home may itself have
  been trashed (trashing a folder trashes what is in it), and an active file
  in a trashed folder is listed nowhere a person can reach — not in the
  trash, and not in a folder tree that no longer shows its folder. It comes
  back to the nearest live ancestor instead, or to the root, which is the
  same rule `attach_file_to_folder/2` already applies to links.

  Sizes are checked against the library's variant set again: they are not
  made while the file is in the trash.
  """
  def restore_file(%PhoenixKit.Modules.Storage.File{} = file) do
    file
    |> Ecto.Changeset.change(%{
      status: "active",
      trashed_at: nil,
      folder_uuid: nearest_live_folder(file.folder_uuid)
    })
    |> repo().update()
    |> case do
      {:ok, updated} = result ->
        variants_stale_after_restore([updated.uuid])
        broadcast_file_restored(updated.uuid)
        result

      error ->
        error
    end
  end

  def restore_file(file_uuid) when is_binary(file_uuid) do
    case get_file(file_uuid) do
      nil -> {:error, :not_found}
      file -> restore_file(file)
    end
  end

  @doc """
  Restores a trashed file into `folder_uuid`, or into no folder (`nil`) —
  for bytes someone trashed and is now uploading again: they are wanted
  where they are being uploaded, not back in the folder they were removed
  from. `{:error, :not_trashed}` when the row is not trashed any more:
  someone else restored it, and it keeps the home they gave it.
  """
  @spec restore_file_into(PhoenixKit.Modules.Storage.File.t(), String.t() | nil) ::
          {:ok, PhoenixKit.Modules.Storage.File.t()} | {:error, :not_trashed}
  def restore_file_into(%PhoenixKit.Modules.Storage.File{} = file, folder_uuid) do
    # Only while the row is still trashed: two uploads of the same trashed
    # bytes both hold the trashed struct, and the second must not take the
    # home the first just gave it.
    from(f in PhoenixKit.Modules.Storage.File,
      where: f.uuid == ^file.uuid and f.status == "trashed"
    )
    |> repo().update_all(
      set: [
        status: "active",
        trashed_at: nil,
        folder_uuid: folder_uuid,
        updated_at: UtilsDate.utc_now()
      ]
    )
    |> case do
      {1, _} ->
        variants_stale_after_restore([file.uuid])
        # The same announcement `restore_file/1` makes: a trash badge, an
        # open listing and another browser all have a row to bring back.
        broadcast_file_restored(file.uuid)
        {:ok, %{file | status: "active", trashed_at: nil, folder_uuid: folder_uuid}}

      {0, _} ->
        {:error, :not_trashed}
    end
  end

  @doc "Returns trashed files ordered by trashed_at descending, with pagination and optional scope."
  def list_trashed_files(scope \\ nil, opts \\ []) do
    query =
      build_trashed_query(scope)
      |> where_library(opts[:library_uuid])
      |> where_viewer(opts[:viewer_uuid])
      |> order_by([f], desc: f.trashed_at)

    query = if opts[:limit], do: limit(query, ^opts[:limit]), else: query
    query = if opts[:offset], do: offset(query, ^opts[:offset]), else: query
    repo().all(query)
  end

  @doc "Returns the count of trashed files, optionally scoped (and `:library_uuid`)."
  def count_trashed_files(scope \\ nil, opts \\ []) do
    build_trashed_query(scope)
    |> where_library(opts[:library_uuid])
    |> where_viewer(opts[:viewer_uuid])
    |> repo().aggregate(:count, :uuid)
  end

  defp build_trashed_query(nil) do
    from(f in PhoenixKit.Modules.Storage.File,
      where: f.status == "trashed" and f.system_managed == false
    )
  end

  defp build_trashed_query(scope_folder_id) do
    cte_base =
      from(f in Folder,
        where: f.uuid == ^scope_folder_id,
        select: %{uuid: f.uuid}
      )

    cte_recursive =
      from(f in Folder,
        join: d in "scope_descendants",
        on: f.parent_uuid == d.uuid,
        select: %{uuid: f.uuid}
      )

    cte = union_all(cte_base, ^cte_recursive)

    from(f in PhoenixKit.Modules.Storage.File,
      join: d in "scope_descendants",
      on: f.folder_uuid == d.uuid,
      where: f.status == "trashed" and f.system_managed == false
    )
    |> with_cte("scope_descendants", as: ^cte)
    |> recursive_ctes(true)
  end

  @doc """
  Permanently deletes all trashed files, optionally scoped — to a folder's
  subtree, and with `library_uuid:` to one storage library.
  """
  def empty_trash(scope \\ nil, opts \\ []) do
    trashed = list_trashed_files(scope, Keyword.take(opts, [:library_uuid, :viewer_uuid]))
    Enum.each(trashed, &delete_file_completely/1)
    {:ok, length(trashed)}
  end

  @doc "Permanently deletes trashed files older than the given number of days."
  def prune_trash(days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second)

    expired =
      PhoenixKit.Modules.Storage.File
      |> where([f], f.status == "trashed" and f.trashed_at < ^cutoff)
      |> repo().all()

    Enum.each(expired, &delete_file_completely/1)
    {:ok, length(expired)}
  end

  @doc "Returns the configured trash retention period in days (default 30)."
  def trash_retention_days do
    Settings.get_setting("trash_retention_days", "30")
    |> to_string()
    |> Integer.parse()
    |> case do
      {n, _} -> n
      :error -> 30
    end
  rescue
    _ -> 30
  end

  @doc """
  Deletes a file completely - physical data from all storage buckets and database record.

  ## Examples

      iex> delete_file_completely(file)
      {:ok, %File{}}

  """
  def delete_file_completely(%PhoenixKit.Modules.Storage.File{} = file) do
    case delete_file_and_objects(file) do
      {:ok, deleted} = ok ->
        broadcast_file_deleted(deleted.uuid)
        ok

      error ->
        error
    end
  end

  def delete_file_completely(file_uuid) when is_binary(file_uuid) do
    case get_file(file_uuid) do
      nil -> {:error, :not_found}
      file -> delete_file_completely(file)
    end
  end

  # `delete_file_completely/1` without its event, for a caller that deletes
  # many files and announces them together (`delete_folder_completely/2`).
  defp delete_file_and_objects(%PhoenixKit.Modules.Storage.File{} = file) do
    # The row goes first (instances, locations and system-managed children —
    # an edited image's backup, tile chunks — cascade with it); then every
    # object those rows referenced that no remaining row still references.
    # Deciding per key, rather than skipping the whole file when any other
    # file shares its directory, is what lets an edited image and its backup
    # (same directory, different keys) delete their own bytes, and keeps a
    # deduplicated copy's shared keys.
    result =
      repo().transaction(fn ->
        # The row before the directories, the order an image edit's swap
        # takes them in.
        from(f in PhoenixKit.Modules.Storage.File,
          where: f.uuid == ^file.uuid,
          lock: "FOR UPDATE"
        )
        |> repo().one()
        |> case do
          nil -> repo().rollback(:not_found)
          _ -> :ok
        end

        family = [file | list_system_children(file.uuid)]
        lock_storage_paths(Enum.map(family, & &1.file_path))

        keys =
          from(fi in FileInstance,
            where: fi.file_uuid in ^Enum.map(family, & &1.uuid),
            select: fi.file_name
          )
          |> repo().all()

        case delete_file(file) do
          {:ok, deleted} -> {deleted, unreferenced_keys(keys)}
          {:error, changeset} -> repo().rollback(changeset)
        end
      end)

    case result do
      {:ok, {deleted, keys}} ->
        case delete_stored_objects(keys) do
          :ok -> Logger.info("Storage: #{length(keys)} objects deleted for #{file.uuid}")
          {:error, reason} -> Logger.warning("Storage: #{file.uuid}: #{reason}")
        end

        {:ok, deleted}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Gets a public URL for a file.

  `nil` for a system-managed file (an edited image's hidden unedited
  original is never handed out). While an image edit is rendering or has
  failed, the signed route is returned even for a public bucket: it answers
  a placeholder, where the bucket would serve the bytes the edit replaces.

  A file in a private library has no public object URL. This returns the
  permanent app token, which the file route refuses; a viewer who may see
  the file uses `authorized_url/4`.
  """
  def get_public_url(%PhoenixKit.Modules.Storage.File{} = file),
    do: public_instance_url(file, "original")

  defp public_instance_url(%PhoenixKit.Modules.Storage.File{system_managed: true}, _variant),
    do: nil

  defp public_instance_url(%PhoenixKit.Modules.Storage.File{} = file, variant_name) do
    case get_file_instance_by_name(file.uuid, variant_name) do
      %FileInstance{} = instance ->
        # Skip the bucket lookup when its URL cannot be used: a private
        # file must not be handed the object URL, and an edit in progress
        # must be served by the app (the placeholder).
        bucket_url =
          if ImageEditing.edit_in_progress?(file) or Libraries.private_file?(file),
            do: nil,
            else: Manager.public_url(instance.file_name, file_uuid: instance.file_uuid)

        public_listing_url(file, variant_name, instance, bucket_url)

      nil ->
        nil
    end
  end

  @doc false
  # `bucket_url` is what the bucket would hand out (`Manager.public_url/1`).
  # A private library never uses it, even when the caller already has one:
  # the permanent app token is what the file route refuses. Public so the
  # decision is testable without a bucket that answers `public_url`.
  def public_listing_url(file, variant_name, instance, bucket_url) do
    cond do
      ImageEditing.edit_in_progress?(file) ->
        signed_file_url(file.uuid, variant_name, nil)

      Libraries.private_file?(file) ->
        signed_file_url(file.uuid, variant_name, instance)

      true ->
        bucket_url || signed_file_url(file.uuid, variant_name, instance)
    end
  end

  @doc """
  Gets a public URL for a specific file variant.

  ## Variants

  For images: "original", "thumbnail", "small", "medium", "large"
  For videos: "original", "360p", "720p", "1080p", "video_thumbnail"

  ## Examples

      iex> get_public_url_by_variant(file, "thumbnail")
      "https://cdn.example.com/12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_thumbnail.jpg"

      iex> get_public_url_by_variant(file, "medium")
      "https://cdn.example.com/12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_medium.jpg"

  """
  def get_public_url_by_variant(%PhoenixKit.Modules.Storage.File{} = file, variant_name) do
    # Falls back to the original when the variant doesn't exist.
    public_instance_url(file, variant_name) || get_public_url(file)
  end

  @doc """
  Gets a public URL for a file by file ID.

  Convenience function that fetches the file and returns its URL.

  ## Examples

      iex> get_public_url_by_uuid("018e3c4a-9f6b-7890-abcd-ef1234567890")
      "https://cdn.example.com/12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_original.jpg"

      iex> get_public_url_by_uuid("invalid-uuid")
      nil

  """
  def get_public_url_by_uuid(file_uuid) when is_binary(file_uuid) do
    case get_file(file_uuid) do
      %PhoenixKit.Modules.Storage.File{} = file ->
        get_public_url(file)

      nil ->
        nil
    end
  end

  def get_public_url_by_uuid(_), do: nil

  @doc """
  Gets a public URL for a specific file variant by file ID.

  ## Examples

      iex> get_public_url_by_uuid("018e3c4a-9f6b-7890-abcd-ef1234567890", "thumbnail")
      "https://cdn.example.com/12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_thumbnail.jpg"

  """
  def get_public_url_by_uuid(file_uuid, variant_name) when is_binary(file_uuid) do
    case get_file(file_uuid) do
      %PhoenixKit.Modules.Storage.File{} = file ->
        get_public_url_by_variant(file, variant_name)

      nil ->
        nil
    end
  end

  @doc """
  Returns variant data for building an `<.image_set>` `<picture>` element.

  Returns a list of maps with `:variant_name`, `:mime_type`, `:width`, and `:url`
  for all completed image instances of the given file.
  """
  def list_image_set_variants(file_uuid) when is_binary(file_uuid) do
    repo = repo()

    FileInstance
    |> where([fi], fi.file_uuid == ^file_uuid)
    |> where([fi], fi.processing_status == "completed")
    |> where([fi], like(fi.mime_type, ^"image/%"))
    |> repo.all()
    |> Enum.map(fn fi ->
      %{
        variant_name: fi.variant_name,
        mime_type: fi.mime_type,
        width: fi.width,
        height: fi.height,
        url: URLSigner.signed_url(file_uuid, fi.variant_name, locale: :none, version: fi)
      }
    end)
  end

  @doc """
  Bulk version of `list_image_set_variants/1` for multiple files.

  Returns a map of `%{file_uuid => [variant_maps]}`. Uses a single DB query.
  """
  def list_image_set_variants_for_files(file_uuids) when is_list(file_uuids) do
    if file_uuids == [] do
      %{}
    else
      repo = repo()

      FileInstance
      |> where([fi], fi.file_uuid in ^file_uuids)
      |> where([fi], fi.processing_status == "completed")
      |> where([fi], like(fi.mime_type, ^"image/%"))
      |> repo.all()
      |> Enum.group_by(& &1.file_uuid, fn fi ->
        %{
          variant_name: fi.variant_name,
          mime_type: fi.mime_type,
          width: fi.width,
          height: fi.height,
          url: URLSigner.signed_url(fi.file_uuid, fi.variant_name, locale: :none, version: fi)
        }
      end)
    end
  end

  @doc """
  The URL of `file`'s `variant` for `scope`, or nil when `scope` may not
  see the file (`Libraries.can?(scope, file, :read)`). A file in a private
  library gets a time-window URL (`URLSigner.signed_url/3`'s `:private`);
  any other the permanent one. Options go to `URLSigner.signed_url/3`
  (`:version`, `:locale`).

  This is how a module shows a file from a user library: the other URL
  helpers here (`get_public_url*`, `list_image_set_variants*`) mint the
  permanent token, which the file route refuses for a private file.
  """
  @spec authorized_url(PhoenixKit.Users.Auth.Scope.t() | nil, map(), String.t(), keyword()) ::
          String.t() | nil
  def authorized_url(scope, %{uuid: uuid} = file, variant, opts \\ []) when is_binary(variant) do
    if Libraries.can?(scope, file, :read) do
      URLSigner.signed_url(
        to_string(uuid),
        variant,
        Keyword.put(opts, :private, Libraries.private_file?(file))
      )
    end
  end

  defp signed_file_url(file_uuid, variant_name, instance) do
    URLSigner.signed_url(file_uuid, variant_name, locale: :none, version: instance)
  rescue
    _ -> nil
  end

  @doc """
  Checks if a file exists in storage.
  """
  def file_exists?(%PhoenixKit.Modules.Storage.File{} = file) do
    # Look up the actual file path from file_instances where "original" variant is stored
    case get_file_instance_by_name(file.uuid, "original") do
      %PhoenixKit.Modules.Storage.FileInstance{file_name: file_path} ->
        Manager.file_exists?(file_path)

      nil ->
        false
    end
  end

  @doc """
  Stores a file in buckets with hierarchical path structure.

  ## Path Structure

  Files are stored using the pattern:
  `{user_uuid[0..1]}/{hash[0..1]}/{full_hash}/{full_hash}_{variant}.{format}`

  ## Options

    * `:mime_type` — the mime type the caller actually observed (a browser
      upload's `client_type`, a multipart `content_type`). Pass it whenever
      you have it: it is stored verbatim on the row, where omitting it falls
      back to guessing from the extension — which is how every mp3 in the
      wild ended up as `application/octet-stream`. A blank or octet-stream
      value is treated as absent.
    * `:library_uuid` — the storage library the new file goes into
      (`PhoenixKit.Modules.Storage.Libraries`); omitted means Media. A
      library with a `key_prefix` keys the file's objects under it
      (`{key_prefix}/{hash[0..1]}/{full_hash}/…`) instead of the uploader's
      prefix. A duplicate the same uploader already has is returned as it
      is, in whatever library it is in — compare `library_uuid` if that
      matters to you.

  Whatever `file_type` the caller claims is cross-checked against the mime
  evidence before the row is written (see `determine_file_type/2`) — a
  contradicted generic claim is corrected, so no single call site can poison
  the `file_type` column for every surface that filters on it.

  ## Examples

  User ID: "12345678"
  File hash: "a1b2c3d4e5f6..."
  Original: "12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_original.jpg"
  Thumbnail: "12/a1/a1b2c3d4e5f6/a1b2c3d4e5f6_thumbnail.jpg"
  """
  def store_file_in_buckets(
        source_path,
        file_type,
        user_uuid,
        file_checksum,
        ext,
        original_filename \\ nil,
        opts \\ []
      ) do
    # Check if any enabled bucket exists, a user's own included (V206): the
    # library's profile then decides which of them this file goes to.
    case buckets_available?() do
      false ->
        {:error, :no_buckets_configured}

      true ->
        # Proceed with storage
        store_file_with_buckets_available(
          source_path,
          file_type,
          user_uuid,
          file_checksum,
          ext,
          original_filename,
          opts
        )
    end
  end

  defp store_file_with_buckets_available(
         source_path,
         file_type,
         user_uuid,
         file_checksum,
         ext,
         original_filename,
         opts
       ) do
    # The dedup key: one copy per uploader per library.
    user_file_checksum =
      calculate_user_file_checksum(user_uuid, file_checksum, opts[:library_uuid])

    # Check if this user already uploaded this file
    case get_file_by_user_checksum(user_file_checksum) do
      %PhoenixKit.Modules.Storage.File{} = existing_file ->
        Logger.info("=== DUPLICATE FILE DETECTED ===")
        Logger.info("File ID: #{existing_file.uuid}, Checksum: #{file_checksum}")
        Logger.info("File path: #{existing_file.file_path}")

        # File already exists, but check if instances and actual files are healthy
        case get_file_instance_by_name(existing_file.uuid, "original") do
          %FileInstance{file_name: stored_file_path} ->
            Logger.info("Original instance record found: #{stored_file_path}")

            # Instance record exists, verify actual file exists in storage
            case verify_file_in_storage(stored_file_path) do
              :exists ->
                Logger.info("Duplicate file is healthy in storage. Queueing variant generation.")
                # File is healthy in storage, ensure other variants are generated
                _ = queue_variant_generation(existing_file, user_uuid, original_filename)
                {:ok, existing_file, :duplicate}

              :missing ->
                # File record exists but actual file is missing from storage
                # Need to re-store the file and recreate instances
                Logger.warning(
                  "Duplicate file detected but missing from storage: #{existing_file.uuid}"
                )

                restore_missing_file(
                  existing_file,
                  source_path,
                  file_checksum,
                  user_uuid,
                  original_filename
                )
            end

          nil ->
            # File record exists but instance record is missing
            # Need to recreate instances from the stored file
            Logger.warning(
              "Duplicate file detected but missing instance record: #{existing_file.uuid}"
            )

            Logger.info("Attempting to recreate instances...")

            recreate_file_instances(
              existing_file,
              source_path,
              file_checksum,
              user_uuid,
              original_filename
            )
        end

      nil ->
        # No per-user match — check for cross-user duplicate (same file uploaded by another user)
        case get_active_file_by_checksum(file_checksum, opts[:library_uuid]) do
          %PhoenixKit.Modules.Storage.File{} = donor_file ->
            Logger.info("=== CROSS-USER DUPLICATE DETECTED ===")
            Logger.info("Donor file: #{donor_file.uuid} (user: #{donor_file.user_uuid})")

            case clone_file_for_user(
                   donor_file,
                   user_uuid,
                   file_checksum,
                   ext,
                   original_filename,
                   opts
                 ) do
              # The donor went (or changed) before it could be shared: store
              # this upload's own bytes instead.
              {:error, :donor_changed} ->
                store_new_file_in_buckets(
                  source_path,
                  file_type,
                  user_uuid,
                  file_checksum,
                  user_file_checksum,
                  ext,
                  original_filename,
                  opts
                )

              result ->
                result
            end

          nil ->
            Logger.info("New file detected (no existing hash match). Proceeding with storage.")

            store_new_file_in_buckets(
              source_path,
              file_type,
              user_uuid,
              file_checksum,
              user_file_checksum,
              ext,
              original_filename,
              opts
            )
        end
    end
  end

  defp store_new_file_in_buckets(
         source_path,
         file_type,
         user_uuid,
         file_checksum,
         user_file_checksum,
         ext,
         original_filename,
         opts
       ) do
    # Calculate MD5 hash for path structure
    md5_hash =
      source_path
      |> Elixir.File.read!()
      |> then(fn data -> :crypto.hash(:md5, data) end)
      |> Base.encode16(case: :lower)

    # Generate UUIDv7 for file UUID
    file_uuid = UUIDv7.generate()

    # Build hierarchical path - organized by key_prefix/hash_prefix/md5_hash,
    # where the key prefix is the library's own when it has one and the
    # uploader's first two characters otherwise (the historical layout).
    library_uuid = opts[:library_uuid]
    key_prefix = library_key_prefix(library_uuid) || String.slice(to_string(user_uuid), 0, 2)
    hash_prefix = String.slice(md5_hash, 0, 2)
    file_path = "#{key_prefix}/#{hash_prefix}/#{md5_hash}"

    # Use provided original filename or fall back to source basename
    orig_filename = original_filename || Path.basename(source_path)

    # The caller's observed mime (browser `client_type` etc.) beats guessing
    # from the extension; the guess is only the fallback. Then the claimed
    # `file_type` is reconciled against that evidence — this is the single
    # point every upload path funnels through, so a defence here covers
    # call sites that don't exist yet (a live example: an external module
    # stored every board upload, .mov and .mp3 included, as `"image"`, and
    # the media page trusted the column everywhere).
    claimed_mime = resolve_mime_type(opts[:mime_type], ext)
    mime_type = content_mime_type(claimed_mime, source_path, orig_filename)
    file_type = reconcile_file_type(file_type, mime_type, orig_filename)

    ext =
      if mime_type == claimed_mime, do: stored_ext(ext, mime_type), else: ext_for(mime_type, ext)

    # Create file record
    file_attrs = %{
      uuid: file_uuid,
      file_name: md5_hash <> "." <> ext,
      original_file_name: orig_filename,
      file_path: file_path,
      mime_type: mime_type,
      file_type: file_type,
      ext: ext,
      file_checksum: file_checksum,
      user_file_checksum: user_file_checksum,
      size: get_file_size(source_path),
      status: "processing",
      user_uuid: user_uuid
    }

    file_attrs = put_library(file_attrs, library_uuid)

    case create_file(file_attrs) do
      {:ok, file} ->
        # Store in buckets with redundancy - use MD5 hash for organized structure
        original_path = "#{file_path}/#{md5_hash}_original.#{ext}"

        case store_by_profile(source_path, library_uuid, :original,
               path_prefix: original_path,
               file_uuid: file.uuid
             ) do
          {:ok, storage_info} ->
            record_placement(file.uuid, storage_info)

            # Create file instance for original
            original_instance_attrs = %{
              variant_name: "original",
              file_name: original_path,
              mime_type: file.mime_type,
              ext: ext,
              checksum: file_checksum,
              size: get_file_size(source_path),
              processing_status: "completed",
              file_uuid: file.uuid
            }

            case create_file_instance(original_instance_attrs) do
              {:ok, instance} ->
                # Create file location records for each bucket where the file was stored
                _ = create_file_locations(instance.uuid, storage_info.bucket_ids, original_path)

                # Queue background job for variant processing
                _ = queue_variant_generation(file, user_uuid, orig_filename)

                {:ok, file}

              {:error, changeset} ->
                # Clean up if instance creation fails
                # Only if nothing else names the key (content-addressed).
                delete_stored_objects([original_path])
                {:error, changeset}
            end

          {:error, reason} ->
            # Clean up file record if storage fails
            repo().delete(file)
            {:error, reason}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # ===== CROSS-USER DEDUPLICATION =====

  # Find any active file with the given checksum (regardless of user) for
  # cross-user dedup. Never a system-managed file (an edited image's hidden
  # backup, a tile chunk) and never a file whose edit is still rendering.
  #
  # Only a file of the SAME library (nil is Media): a library is a library, and
  # shares no stored objects, variants or placement with another one, however
  # alike their profile and variant set are. A clone across libraries used to be
  # made when the two were placed alike; it tied the second library's files to
  # the first one's objects, and reported a file that was added as a duplicate.
  defp get_active_file_by_checksum(file_checksum, library_uuid) do
    library_uuid = library_uuid || Libraries.media_uuid()

    from(f in PhoenixKit.Modules.Storage.File,
      where:
        f.file_checksum == ^file_checksum and f.status == "active" and
          f.system_managed == false and is_nil(f.edit_state) and
          f.library_uuid == ^library_uuid,
      limit: 1
    )
    |> repo().one()
  end

  # The object-key prefix of a library that has one; nil keeps the
  # historical per-uploader layout (Media, and no library given).
  defp library_key_prefix(nil), do: nil

  defp library_key_prefix(library_uuid) do
    case Libraries.get_library(library_uuid) do
      %{key_prefix: prefix} when is_binary(prefix) and prefix != "" -> prefix
      _ -> nil
    end
  end

  # Names the library only when one is given: a nil `library_uuid` is left
  # out of the insert, so the column default (Media) applies.
  defp put_library(attrs, nil), do: attrs
  defp put_library(attrs, library_uuid), do: Map.put(attrs, :library_uuid, library_uuid)

  # ===== PLACEMENT (V205) =====

  @doc false
  # Stores `source_path` by the storage profile of `library_uuid` (nil is
  # Media) as an object of `kind` (`:original` or `:derived`). The result
  # carries the profile it was placed by, for `record_placement/2`.
  def store_by_profile(source_path, library_uuid, kind, opts \\ []) do
    profile = Profiles.for_library(library_uuid)
    placement = if profile, do: [profile: profile, kind: kind], else: [kind: kind]

    with {:ok, info} <- Manager.store_file(source_path, placement ++ opts) do
      {:ok, Map.put(info, :profile, profile)}
    end
  end

  @doc false
  # Records the profile (and its revision) that placed a file's original:
  # every copy it wanted was made, or the file is stale (revision 0) and
  # the reconciler makes the rest.
  def record_placement(file_uuid, %{profile: %StorageProfile{} = profile} = info) do
    revision = if Map.get(info, :complete?, true), do: profile.revision, else: 0

    from(f in PhoenixKit.Modules.Storage.File, where: f.uuid == ^file_uuid)
    |> repo().update_all(set: [placed_profile_uuid: profile.uuid, placed_revision: revision])

    if revision == 0, do: ReconcileJob.enqueue()
    :ok
  end

  def record_placement(_file_uuid, _info), do: :ok

  @doc false
  # Marks a file stale for the reconciler: something of it (a variant, a
  # tile) has fewer copies than its profile wants.
  def mark_placement_stale(file_uuid) do
    from(f in PhoenixKit.Modules.Storage.File, where: f.uuid == ^file_uuid)
    |> repo().update_all(set: [placed_revision: 0])

    ReconcileJob.enqueue()
    :ok
  end

  # Create a new File record for a different user, reusing the same storage path
  # (the donor's objects, whatever library it is in). The clone goes into the
  # library the upload asked for.
  defp clone_file_for_user(donor_file, user_uuid, file_checksum, ext, original_filename, opts) do
    user_file_checksum =
      calculate_user_file_checksum(user_uuid, file_checksum, opts[:library_uuid])

    file_attrs = %{
      file_name: donor_file.file_name,
      original_file_name: original_filename || donor_file.original_file_name,
      file_path: donor_file.file_path,
      mime_type: donor_file.mime_type,
      file_type: donor_file.file_type,
      # An upload with no extension of its own takes the clone's type's,
      # as a first copy would (`ext` is required).
      ext: stored_ext(ext, donor_file.mime_type),
      file_checksum: file_checksum,
      user_file_checksum: user_file_checksum,
      size: donor_file.size,
      width: donor_file.width,
      height: donor_file.height,
      status: "active",
      user_uuid: user_uuid
    }

    file_attrs = put_library(file_attrs, opts[:library_uuid])

    # Under the donor's path lock, so the keys being copied cannot be deleted
    # (a delete, an edit's swap) between reading and referencing them. The
    # donor is re-read inside: gone or changed means no clone.
    repo().transaction(fn ->
      lock_storage_paths([donor_file.file_path])

      with %PhoenixKit.Modules.Storage.File{} = donor <-
             get_active_file_by_checksum(file_checksum, opts[:library_uuid]),
           true <- donor.uuid == donor_file.uuid,
           {:ok, new_file} <- create_file(Map.merge(file_attrs, capture_date_copy(donor))) do
        clone_file_instances(donor.uuid, new_file.uuid)
        copy_placement(donor, new_file.uuid)
        Logger.info("Cross-user clone created: #{new_file.uuid} from donor #{donor.uuid}")
        {new_file, :duplicate}
      else
        {:error, changeset} -> repo().rollback(changeset)
        _ -> repo().rollback(:donor_changed)
      end
    end)
    |> case do
      {:ok, {new_file, :duplicate}} ->
        {:ok, new_file, :duplicate}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error("Failed to clone file for user: #{inspect(changeset.errors)}")
        {:error, changeset}

      {:error, :donor_changed} ->
        {:error, :donor_changed}
    end
  end

  # The donor was dated when it became active. The clone shares those bytes
  # and is inserted already `active`, so it does not pass through
  # `ProcessFileJob` — copy the date in the same locked read as the rest of
  # the row, or the copy stays undated after the one-shot backfill.
  defp capture_date_copy(donor) do
    Map.take(donor, CaptureDate.fields())
  end

  # The clone holds the donor's objects and variants, so it is placed
  # exactly as the donor is.
  defp copy_placement(donor, file_uuid) do
    from(f in PhoenixKit.Modules.Storage.File, where: f.uuid == ^file_uuid)
    |> repo().update_all(
      set: [
        placed_profile_uuid: donor.placed_profile_uuid,
        placed_revision: donor.placed_revision,
        placed_variant_set_uuid: donor.placed_variant_set_uuid,
        placed_variant_revision: donor.placed_variant_revision
      ]
    )
  end

  # Copy all FileInstance records from one file to another (same storage paths)
  defp clone_file_instances(donor_file_uuid, new_file_uuid) do
    donor_instances = list_file_instances(donor_file_uuid)

    Enum.each(donor_instances, fn instance ->
      attrs = %{
        variant_name: instance.variant_name,
        file_name: instance.file_name,
        mime_type: instance.mime_type,
        ext: instance.ext,
        checksum: instance.checksum,
        size: instance.size,
        width: instance.width,
        height: instance.height,
        processing_status: instance.processing_status,
        spec_hash: instance.spec_hash,
        file_uuid: new_file_uuid
      }

      %FileInstance{}
      |> FileInstance.changeset(attrs)
      |> repo().insert()
    end)

    # Also clone file locations for each new instance
    clone_file_locations(donor_file_uuid, new_file_uuid)
  end

  # Copy FileLocation records from donor instances to new instances
  defp clone_file_locations(donor_file_uuid, new_file_uuid) do
    donor_instances = list_file_instances(donor_file_uuid)
    new_instances = list_file_instances(new_file_uuid)

    # Match instances by variant_name and copy their locations
    Enum.each(new_instances, fn new_inst ->
      donor_inst = Enum.find(donor_instances, &(&1.variant_name == new_inst.variant_name))

      if donor_inst do
        FileLocation
        |> where([fl], fl.file_instance_uuid == ^donor_inst.uuid and fl.status == "active")
        |> repo().all()
        |> Enum.each(fn loc ->
          %FileLocation{}
          |> FileLocation.changeset(%{
            path: loc.path,
            status: "active",
            priority: loc.priority,
            file_instance_uuid: new_inst.uuid,
            bucket_uuid: loc.bucket_uuid
          })
          |> repo().insert()
        end)

        # The copy is where the donor is: checked if the donor was.
        case repo().get(PhoenixKit.Modules.Storage.LocationCheck, donor_inst.uuid) do
          nil -> :ok
          check -> Locations.mark_checked([new_inst.uuid], check.found_in)
        end
      end
    end)
  end

  @doc false
  # The system-managed files hanging off `file_uuid`: an edited image's
  # unedited backup and its tile chunks.
  def list_system_children(file_uuid) do
    from(f in PhoenixKit.Modules.Storage.File,
      where: f.parent_file_uuid == ^file_uuid and f.system_managed == true
    )
    |> repo().all()
  end

  # ===== HELPER FUNCTIONS =====

  @doc false
  # Queue variant generation so every declared variant exists for this file —
  # the one enqueue every upload and variant-fallback path goes through.
  #
  # Inline rather than in a `Task`: the payload is a single local insert, and a
  # detached task inherits the caller's DB connection — under a host's test
  # sandbox that surfaces as "DBConnection owner exited" after the test has
  # finished, in a library the host cannot fix from the outside.
  #
  # Best-effort: an upload must still succeed when Oban is unavailable, so a
  # raise (bad config, no Oban instance), an exit (dead repo) and an error
  # result are all logged and answered `:error`. `ProcessFileJob` is unique per
  # file while incomplete, so a re-upload of the same file collapses into the
  # run already queued.
  @spec queue_variant_generation(map(), String.t() | nil, String.t() | nil) :: :ok | :error
  def queue_variant_generation(file, user_uuid, original_filename) do
    %{file_uuid: file.uuid, user_uuid: user_uuid, filename: original_filename}
    |> ProcessFileJob.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Could not enqueue variant generation for #{file.uuid}: #{inspect(reason)}"
        )

        :error
    end
  rescue
    error ->
      Logger.warning("Could not enqueue variant generation for #{file.uuid}: #{inspect(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("Could not enqueue variant generation for #{file.uuid}: #{inspect(reason)}")
      :error
  end

  defp verify_file_in_storage(stored_file_path) do
    # Check if file actually exists in storage buckets
    Logger.info("Verifying file in storage: #{stored_file_path}")
    exists = Manager.file_exists?(stored_file_path)
    Logger.info("File exists? #{exists}")
    if exists, do: :exists, else: :missing
  end

  defp restore_missing_file(existing_file, source_path, file_hash, user_uuid, original_filename) do
    # File record exists but actual file is missing from storage
    # Delete broken instances and recreate them (which will also store the file)

    Logger.warning("=== RECOVERING MISSING FILE ===")
    Logger.warning("File ID: #{existing_file.uuid}")
    Logger.warning("File path: #{existing_file.file_path}")
    Logger.warning("Source path: #{source_path}")

    # First, delete all broken instances for this file
    deleted_count = delete_file_instances_for_file(existing_file.uuid)
    Logger.info("Deleted #{deleted_count} broken instances for file: #{existing_file.uuid}")

    # Recreate instance and store the file (combined in one operation)
    Logger.info("Recreating instances for file #{existing_file.uuid}")
    recreate_file_instances(existing_file, source_path, file_hash, user_uuid, original_filename)
  end

  defp delete_file_instances_for_file(file_uuid) do
    # Delete all file instances for a file (to clean up broken ones)
    {deleted_count, _} =
      from(fi in FileInstance, where: fi.file_uuid == ^file_uuid)
      |> repo().delete_all()

    Logger.info("Deleted #{deleted_count} file instances for file_uuid: #{file_uuid}")
    deleted_count
  end

  defp recreate_file_instances(file, source_path, file_checksum, user_uuid, original_filename) do
    # File record exists but instances are missing or broken
    # First store the file in buckets, then recreate the instance record

    Logger.info(
      "Starting recreate_file_instances for file: #{file.uuid}, file_path: #{file.file_path}"
    )

    {:ok, stat} = Elixir.File.stat(source_path)
    file_size = stat.size

    # Reconstruct the full storage path for the original instance
    # file.file_path is "user_prefix/hash_prefix/md5_hash"
    # We need to extract md5_hash and build the original path
    [_user_prefix, _hash_prefix, md5_hash | _rest] = String.split(file.file_path, "/")
    original_path = "#{file.file_path}/#{md5_hash}_original.#{file.ext}"

    Logger.info("Reconstructed original path for instance: #{original_path}")

    Logger.info(
      "About to store file from source_path: #{source_path} to storage path: #{original_path}"
    )

    # First, store the file in buckets using Manager
    case store_by_profile(source_path, file.library_uuid, :original,
           path_prefix: original_path,
           file_uuid: file.uuid
         ) do
      {:ok, storage_info} ->
        Logger.info(
          "File stored in buckets: #{original_path}, bucket_ids: #{inspect(storage_info.bucket_ids)}"
        )

        record_placement(file.uuid, storage_info)

        # Now create the file instance record pointing to the stored file
        original_instance_attrs = %{
          variant_name: "original",
          file_name: original_path,
          mime_type: file.mime_type,
          ext: file.ext,
          checksum: file_checksum,
          size: file_size,
          processing_status: "completed",
          file_uuid: file.uuid
        }

        case create_file_instance(original_instance_attrs) do
          {:ok, _instance} ->
            Locations.record_all(original_path, storage_info.bucket_ids)

            Logger.info(
              "Recreated original instance for file: #{file.uuid}, path: #{original_path}"
            )

            # Delete any remaining broken variant instances BEFORE queuing ProcessFileJob
            # This ensures ProcessFileJob creates fresh instances with correct paths
            deleted_variants = delete_variant_instances(file.uuid)

            Logger.info(
              "Deleted #{deleted_variants} broken variant instances before regeneration"
            )

            # Queue variant generation for the recovered file
            _ = queue_variant_generation(file, user_uuid, original_filename)
            {:ok, file, :duplicate}

          {:error, reason} ->
            # Instance creation failed, might be duplicate constraint
            # Try deleting old broken instances and recreating
            Logger.warning(
              "Instance creation failed for file #{file.uuid}: #{inspect(reason)}, attempting cleanup and retry"
            )

            _ = delete_file_instances_for_file(file.uuid)

            case create_file_instance(original_instance_attrs) do
              {:ok, _instance} ->
                Logger.info(
                  "Recreated original instance for file (after cleanup): #{file.uuid}, path: #{original_path}"
                )

                # Delete any remaining broken variant instances
                deleted_variants = delete_variant_instances(file.uuid)

                Logger.info(
                  "Deleted #{deleted_variants} broken variant instances before regeneration"
                )

                _ = queue_variant_generation(file, user_uuid, original_filename)
                {:ok, file, :duplicate}

              {:error, final_reason} ->
                Logger.error(
                  "Failed to recreate instance for file #{file.uuid}: #{inspect(final_reason)}"
                )

                {:error, final_reason}
            end
        end

      {:error, store_error} ->
        Logger.error(
          "Failed to store file in buckets for recreate_file_instances: #{inspect(store_error)}"
        )

        {:error, store_error}
    end
  end

  defp delete_variant_instances(file_uuid) do
    # Delete only the variant instances (not the original), to clean up broken ones
    {deleted_count, _} =
      from(fi in FileInstance,
        where: fi.file_uuid == ^file_uuid and fi.variant_name != "original"
      )
      |> repo().delete_all()

    deleted_count
  end

  defp get_file_size(source_path) do
    case Elixir.File.stat(source_path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  # `ext` is part of every stored key and a required column, so a file whose
  # name has no extension (a README, a dotfile) takes its type's — or "bin"
  # — instead of failing the upload.
  defp stored_ext(ext, mime_type) when ext in [nil, ""] do
    case MIME.extensions(mime_type) do
      [ext | _] -> ext
      [] -> "bin"
    end
  end

  defp stored_ext(ext, _mime_type), do: ext

  # The raster image types the image pipeline (ImageMagick) processes.
  @raster_mimes ~w(image/png image/jpeg image/pjpeg image/jpg image/gif image/webp image/tiff
                   image/bmp image/heic image/heif image/avif)

  @doc """
  Downloads `url` and stores it like an upload, returning what
  `store_file_in_buckets/7` returns.

  The download is `PhoenixKit.Modules.Storage.RemoteFetch.download/2`: https
  only by default, never to a non-public address (redirects and DNS
  rebinding included), streamed to a temporary file with a size cap and an
  overall timeout. The stored type comes from the bytes (`Storage.Sniff`),
  not the response's `Content-Type`, and must be one of `:allowed_types`.
  The temporary file is always removed.

  This blocks for as long as the download takes; call it from a Task or a
  job, not a LiveView's event handler.

  ## Options

    * `:user_uuid` (required) — the uploader.
    * `:library_uuid` — the library to store into (default: Media).
    * `:allowed_types` — MIME types or prefixes (`"image/"`) the sniffed
      type must match. Default `["image/"]`.
    * `:filename` — the stored original name (default: the URL's last
      path segment).
    * `:max_bytes`, `:timeout`, `:max_redirects`, `:allow_http`,
      `:allowed_ports` — see `RemoteFetch`.

  Errors: RemoteFetch's reasons, `:unsupported_type` (bytes of no known
  type, or one not allowed), or `store_file_in_buckets/7`'s.
  """
  @spec store_from_url(String.t(), keyword()) ::
          {:ok, term()} | {:ok, term(), atom()} | {:error, term()}
  def store_from_url(url, opts) do
    user_uuid = Keyword.fetch!(opts, :user_uuid)
    allowed = Keyword.get(opts, :allowed_types, ["image/"])

    with {:ok, %{path: path, filename: name}} <- RemoteFetch.download(url, opts) do
      try do
        with {:ok, %{mime: mime}} <- Sniff.sniff(path),
             true <- Enum.any?(allowed, &String.starts_with?(mime, &1)) do
          filename = opts[:filename] || name
          ext = mime |> MIME.extensions() |> List.first() || "bin"

          checksum =
            :sha256 |> :crypto.hash(Elixir.File.read!(path)) |> Base.encode16(case: :lower)

          store_file_in_buckets(
            path,
            determine_file_type(mime, filename),
            user_uuid,
            checksum,
            ext,
            filename,
            mime_type: mime,
            library_uuid: opts[:library_uuid]
          )
        else
          _ -> {:error, :unsupported_type}
        end
      after
        Elixir.File.rm(path)
      end
    end
  end

  # The bytes, not the name or the browser, decide what a raster image is:
  #
  #   * a file whose first bytes are a raster image is stored as THAT type,
  #     whatever it was called (a PNG named .jpg, a HEIC the browser said was
  #     JPEG) — the variant pipeline then decodes it with the right coder;
  #   * a file that CLAIMS to be a raster image but whose bytes are something
  #     else (an SVG, a PDF, a script renamed .png) is stored as what it is,
  #     or as octet-stream when unrecognised, so it never reaches ImageMagick
  #     as an "image".
  #
  # Every other claim (documents, audio, video, archives) is left as it was —
  # sniffing only corrects the image path, which is the one that decodes.
  @doc false
  def content_mime_type(claimed, source_path, filename) do
    case Sniff.sniff(source_path) do
      {:ok, %{format: format, mime: sniffed}} ->
        cond do
          Sniff.raster?(format) and sniffed != claimed ->
            log_mime_mismatch(filename, claimed, sniffed)
            sniffed

          claimed in @raster_mimes and not Sniff.raster?(format) ->
            log_mime_mismatch(filename, claimed, sniffed)
            sniffed

          true ->
            claimed
        end

      # Bytes nothing recognises are not an image, whatever the claim —
      # raster or not (an `image/svg+xml` claim over unknown bytes too).
      :unknown ->
        if claimed in @raster_mimes or image_claim?(claimed) do
          log_mime_mismatch(filename, claimed, "application/octet-stream")
          "application/octet-stream"
        else
          claimed
        end
    end
  end

  defp image_claim?(claimed) when is_binary(claimed), do: String.starts_with?(claimed, "image/")
  defp image_claim?(_claimed), do: false

  defp log_mime_mismatch(filename, claimed, actual) do
    Logger.warning(
      "Storage: #{inspect(filename)} claimed #{claimed} but its bytes are #{actual}; storing #{actual}"
    )
  end

  # The extension that goes with a corrected mime type (`image/png` → "png").
  defp ext_for(mime_type, fallback) do
    case MIME.extensions(mime_type) do
      [ext | _] -> ext
      [] -> stored_ext(fallback, mime_type)
    end
  end

  # The caller's observed mime wins when it carries information; blank and
  # octet-stream carry none, so they fall through to the extension guess
  # rather than being enshrined on the row.
  defp resolve_mime_type(mime_type, ext) do
    case mime_type do
      nil -> determine_mime_type(ext)
      "" -> determine_mime_type(ext)
      "application/octet-stream" -> determine_mime_type(ext)
      observed -> observed
    end
  end

  # Extension→mime for callers that didn't observe a mime themselves. The
  # `mime` library, not a hand-rolled map: the map this replaces had no audio
  # entries at all, so every mp3/m4a/wav landed as `application/octet-stream`
  # even when the upload path had the browser's own `audio/mpeg` in hand —
  # and the display side then needed extension-sniffing fallbacks to undo it.
  # `MIME.type/1` knows the same types the rest of the stack does (including
  # anything the host adds via `config :mime`); `@audio_mime_fallbacks` fills
  # only the holes it answers octet-stream for — the same known-blind audio
  # set `@audio_extensions` exists for (`.m4a`, `.flac`, `.ogg`…), listed in
  # full so a host's older `mime` still resolves all of them.
  #
  # The leading dot is trimmed because callers disagree about it — some pass
  # `"mp3"`, `Path.extname/1`-based ones pass `".mp3"` — and the old map
  # recognized only the bare form, so a dotted extension always fell to
  # octet-stream.
  @audio_mime_fallbacks %{
    "mp3" => "audio/mpeg",
    "wav" => "audio/wav",
    "ogg" => "audio/ogg",
    "oga" => "audio/ogg",
    "m4a" => "audio/mp4",
    "aac" => "audio/aac",
    "flac" => "audio/flac",
    "opus" => "audio/opus",
    "weba" => "audio/webm",
    "mid" => "audio/midi",
    "midi" => "audio/midi"
  }

  # Public (@doc false) so the unit suite can pin the audio fallbacks and the
  # dot-tolerance without standing up buckets for a full store call.
  @doc false
  def determine_mime_type(ext) do
    ext = ext |> String.downcase() |> String.trim_leading(".")

    case MIME.type(ext) do
      "application/octet-stream" ->
        Map.get(@audio_mime_fallbacks, ext, "application/octet-stream")

      mime ->
        mime
    end
  end

  # The generic classes `determine_file_type/2` can produce — the only claims
  # the write boundary is entitled to correct. Anything else ("tile") is a
  # system type deliberately chosen by internal machinery; the classifier
  # knows nothing about those, so its opinion doesn't apply.
  @generic_file_types ~w(image video audio document archive other)

  # Cross-checks the caller's claimed `file_type` against the actual mime
  # evidence before the row is written. A contradicted generic claim is
  # replaced, loudly, because a wrong value in this column breaks the file on
  # every surface that trusts it — thumbnail grid, type filters, typed
  # pickers, variant processing.
  defp reconcile_file_type(claimed, mime_type, filename) do
    resolved = resolve_claimed_type(claimed, determine_file_type(mime_type, filename))

    if resolved != claimed do
      Logger.warning(
        "Storage: caller claimed file_type #{inspect(claimed)} for " <>
          "#{inspect(filename)} (#{mime_type}); storing #{inspect(resolved)}"
      )
    end

    resolved
  end

  @doc """
  The `file_type` a display surface should trust for a stored file.

  Same evidence-over-claim rule the write boundary applies (see
  `store_file_in_buckets/7`), but usable on rows written before that rule
  existed: the column wins only when the row's own mime type and filename
  don't contradict it. A row stored as `"image"` that is demonstrably a
  `video/quicktime` renders as a video — a play-button tile instead of a
  broken `<img>` pointed at a `.mov`.

  Accepts a `File` struct or any map carrying `:file_type` / `:mime_type`
  plus a filename under `:original_file_name`, `:filename` or `:file_name`.
  System types (`"tile"`) pass through untouched, as does anything the
  evidence can't improve on.

  This corrects what the user *sees*; the column itself is corrected by the
  repair migration, and `file_type`-filtered queries answer from the column.
  """
  def display_file_type(file) do
    claimed = Map.get(file, :file_type)
    mime_type = Map.get(file, :mime_type)

    filename =
      Map.get(file, :original_file_name) || Map.get(file, :filename) ||
        Map.get(file, :file_name)

    resolve_claimed_type(claimed, determine_file_type(mime_type, filename))
  end

  # The claim survives when the evidence agrees, when there is no evidence
  # (`"other"` — the caller may know more than the classifier), or when it
  # isn't a generic class at all ("tile" — chosen by internal machinery the
  # classifier knows nothing about).
  defp resolve_claimed_type(claimed, derived) do
    cond do
      is_binary(claimed) and claimed not in @generic_file_types -> claimed
      derived == "other" -> claimed || "other"
      true -> derived
    end
  end

  @doc """
  How many copies of an original the Default storage profile keeps: what
  the `storage_redundancy_copies` setting was before profiles (V205).
  """
  @spec redundancy_copies() :: pos_integer()
  def redundancy_copies, do: Profiles.default_copies()

  @doc """
  Sets the Default storage profile's copy count, for every file (as the one
  redundancy setting did), split over its buckets, local first
  (`Profiles.split_copies/2`), and keeps the
  `storage_redundancy_copies` setting row in step for code that still
  reads it.
  """
  @spec set_redundancy_copies(pos_integer() | String.t()) ::
          {:ok, term()} | {:error, term()}
  def set_redundancy_copies(copies) when is_binary(copies),
    do: set_redundancy_copies(String.to_integer(copies))

  def set_redundancy_copies(copies) when is_integer(copies) do
    with %StorageProfile{} = profile <- Profiles.default_profile() || {:error, :no_default} do
      Profiles.update_profile(
        profile,
        Map.put(
          Profiles.split_copies(profile, copies),
          :min_copies_on_write,
          min(profile.min_copies_on_write, copies)
        )
      )
    end
  end

  @doc """
  The name of the size of `file`'s variant set that fits a purpose, rather
  than one picked by name: `variant_for(file, min_width: 300, aspect:
  :preserve)`. See `VariantSets.variant_for/2`.
  """
  defdelegate variant_for(file, opts \\ []), to: VariantSets

  @doc """
  Whether the Default variant set makes sizes automatically: what the
  `storage_auto_generate_variants` setting was before variant sets (V205).
  A file follows its own library's set (`VariantSets.variants_for?/1`).
  """
  def get_auto_generate_variants, do: VariantSets.default_flag(:generate_variants, true)

  @doc """
  Whether any HEIC or HEIF photo (an iPhone's format) has been uploaded: what the
  notice about ImageMagick being unable to read HEIC needs, so a host that never
  sees one is not told about it.
  """
  @spec heic_files_exist?() :: boolean()
  def heic_files_exist? do
    from(f in PhoenixKit.Modules.Storage.File,
      where:
        f.mime_type in ["image/heic", "image/heif"] or
          fragment("lower(?)", f.ext) in ["heic", "heif"]
    )
    |> repo().exists?()
  end

  @doc """
  Whether any library has deep zoom (zoomable tiles) on. It was the Default
  variant set's flag (`storage_tile_generation_enabled`) before the choice moved
  to each library; what needs it (the ImageMagick notice) asks whether any does.
  """
  def tile_generation_enabled?, do: VariantSets.tiles_anywhere?()

  @doc """
  Turns the Default variant set's automatic sizes on or off, and keeps the
  `storage_auto_generate_variants` setting row in step.
  """
  def set_auto_generate_variants(enabled?) when is_boolean(enabled?),
    do: set_default_flag(:generate_variants, enabled?)

  @doc """
  Turns the Default variant set's tiles on or off, and keeps the
  `storage_tile_generation_enabled` setting row in step.
  """
  def set_tile_generation(enabled?) when is_boolean(enabled?),
    do: set_default_flag(:generate_tiles, enabled?)

  defp set_default_flag(flag, enabled?) do
    with %VariantSet{} = set <- VariantSets.default_variant_set() || {:error, :no_default} do
      VariantSets.update_variant_set(set, %{flag => enabled?})
    end
  end

  defp get_default_bucket_uuid do
    Settings.get_setting_cached("storage_default_bucket_uuid", nil)
  end

  defp calculate_local_free_space(bucket) do
    # For local storage, return configured max_size_mb or default 1000 MB
    # Note: Real disk space monitoring should be implemented via System.cmd("df")
    # or external monitoring tools, as :disksup is not reliably available
    bucket.max_size_mb || 1000
  end

  # Check if directory is writable
  defp writable?(path) do
    test_file = Path.join(path, ".phoenix_kit_write_test")

    case Elixir.File.write(test_file, "test") do
      :ok ->
        Elixir.File.rm(test_file)
        true

      {:error, _} ->
        false
    end
  end

  # ===== REPO HELPERS =====

  defp repo do
    PhoenixKit.Config.get_repo()
  end

  # Query builders for file listing
  defp maybe_filter_by_bucket(query, nil), do: query

  # A file is in a bucket when one of its instances has an active location
  # there.
  defp maybe_filter_by_bucket(query, bucket_uuid) do
    in_bucket =
      from(fl in FileLocation,
        join: fi in FileInstance,
        on: fi.uuid == fl.file_instance_uuid,
        where: fl.bucket_uuid == ^bucket_uuid and fl.status == "active",
        select: fi.file_uuid
      )

    where(query, [f], f.uuid in subquery(in_bucket))
  end

  defp maybe_order_by(query, nil), do: order_by(query, [f], desc: f.inserted_at)
  defp maybe_order_by(query, order_by), do: order_by(query, [f], ^order_by)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  # ===== FILE STORAGE HELPERS =====

  defp store_new_file(
         source_path,
         file_checksum,
         user_file_checksum,
         filename,
         content_type,
         size_bytes,
         user_uuid,
         metadata
       ) do
    content_type = content_mime_type(content_type, source_path, filename)

    # Store file using manager
    case store_by_profile(source_path, nil, :original) do
      {:ok, storage_info} ->
        file_attrs =
          build_file_attrs(
            storage_info,
            filename,
            content_type,
            file_checksum,
            user_file_checksum,
            size_bytes,
            metadata,
            user_uuid
          )

        case create_file(file_attrs) do
          {:ok, file} ->
            record_placement(file.uuid, storage_info)

            # Create original instance and variants (non-critical operations)
            create_original_instance_and_variants(
              file,
              file_checksum,
              size_bytes,
              storage_info.bucket_ids
            )

            {:ok, record_new_capture_date(file, source_path, storage_info.destination_path)}

          {:error, changeset} ->
            # Clean up stored files if database creation fails
            delete_stored_objects([storage_info.destination_path])
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_file_attrs(
         storage_info,
         filename,
         content_type,
         file_checksum,
         user_file_checksum,
         size_bytes,
         metadata,
         user_uuid
       ) do
    # Extract file_path (directory) from destination_path
    # destination_path is like "01/ab/0123456789abcdef_original.jpg"
    # file_path should be "01/ab/0123456789abcdef" (without filename)
    file_path = Path.dirname(storage_info.destination_path)

    %{
      original_file_name: filename,
      file_name: storage_info.destination_path,
      file_path: file_path,
      mime_type: content_type,
      file_type: determine_file_type(content_type, filename),
      ext: Path.extname(filename),
      file_checksum: file_checksum,
      user_file_checksum: user_file_checksum,
      size: size_bytes,
      # Convert to MB
      size_mb: size_bytes / (1024 * 1024),
      status: "active",
      metadata: metadata,
      user_uuid: user_uuid
    }
  end

  # `store_file/2` (comment attachments) inserts the row already `active` and
  # generates variants inline, so `ProcessFileJob` never dates it. Read the
  # date from the bytes just stored, and write it only while that key is
  # still the original.
  defp record_new_capture_date(%{file_type: type} = file, source_path, key)
       when type in ["image", "video"] do
    attrs = CaptureDate.resolve(source_path, file)

    repo().transaction(fn ->
      current =
        repo().one(
          from(f in PhoenixKit.Modules.Storage.File,
            where: f.uuid == ^file.uuid,
            lock: "FOR UPDATE"
          )
        )

      cond do
        is_nil(current) ->
          file

        not original_key?(file.uuid, key) ->
          file

        true ->
          case update_file(current, CaptureDate.admit(attrs, current)) do
            {:ok, updated} -> updated
            {:error, changeset} -> repo().rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, updated} -> updated
      _ -> file
    end
  end

  defp record_new_capture_date(file, _source_path, _key), do: file

  defp create_original_instance_and_variants(file, file_checksum, size_bytes, bucket_ids) do
    original_instance_attrs = %{
      variant_name: "original",
      file_name: file.file_name,
      mime_type: file.mime_type,
      ext: file.ext,
      checksum: file_checksum,
      size: size_bytes,
      # Will be populated if we can detect dimensions
      width: nil,
      # Will be populated if we can detect dimensions
      height: nil,
      processing_status: "completed",
      file_uuid: file.uuid
    }

    case create_file_instance(original_instance_attrs) do
      {:ok, original_instance} ->
        # Where the object went, now that its instance exists (V204).
        Locations.record_all(original_instance.file_name, bucket_ids)

        # Generate variants if enabled (failure is non-critical)
        case VariantGenerator.generate_variants(file) do
          {:ok, _variants} -> :ok
          {:error, _reason} -> :ok
        end

      {:error, _changeset} ->
        # Original instance creation failed, but file was stored (non-critical)
        :ok
    end
  end

  defp calculate_file_hash(file_path) do
    file_path
    |> Elixir.File.read!()
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
  end

  # Extensions the browser and `MIME.from_path/1` both routinely hand back as
  # `application/octet-stream` — `.m4a` (what an iPhone records), `.flac`,
  # `.ogg`. Mirrors `MediaBrowser`'s `@audio_extensions`, which exists for the
  # same reason on the display side: without them a file the picker's `accept`
  # list explicitly invited is stored as "other" and then hidden by the very
  # filter that asked for it.
  @audio_extensions ~w(.mp3 .wav .ogg .oga .m4a .aac .flac .opus .weba .mid .midi)

  @doc """
  Classifies a file into the `file_type` the `File` schema stores:
  `"image"`, `"video"`, `"audio"`, `"document"`, `"archive"` or `"other"`.

  Every upload path must classify through here. Each surface used to carry its
  own copy of this `cond` and the copies drifted — three of them had no
  `audio/` clause at all, so an mp3 uploaded through the media browser was
  stored as `"document"` while the audio filter, a plain
  `file_type == "audio"` query, never saw it.

  `filename` is the second line of defence, for the extensions whose mime type
  neither the browser nor `MIME.from_path/1` knows.

      iex> determine_file_type("audio/mpeg")
      "audio"
      iex> determine_file_type("application/octet-stream", "song.m4a")
      "audio"
  """
  def determine_file_type(mime_type, filename \\ nil) do
    case classify_mime(mime_type || "") do
      "other" -> classify_by_filename(filename)
      type -> type
    end
  end

  defp classify_by_filename(nil), do: "other"

  defp classify_by_filename(filename) do
    case classify_mime(MIME.from_path(filename)) do
      "other" ->
        if String.ends_with?(String.downcase(filename), @audio_extensions),
          do: "audio",
          else: "other"

      type ->
        type
    end
  end

  defp classify_mime(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") ->
        "image"

      String.starts_with?(mime_type, "video/") ->
        "video"

      String.starts_with?(mime_type, "audio/") ->
        "audio"

      String.starts_with?(mime_type, "text/") ->
        "document"

      mime_type in ["application/pdf"] ->
        "document"

      mime_type in [
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      ] ->
        "document"

      String.contains?(mime_type, "zip") or String.contains?(mime_type, "archive") ->
        "archive"

      true ->
        "other"
    end
  end

  @doc """
  Creates file locations for a file instance across specified buckets.

  Returns `{:ok, locations}` on success or `{:error, :file_locations_failed, errors}` if any insertions fail.

  ## Parameters

    * `file_instance_uuid` - The UUID of the file instance
    * `bucket_uuids` - List of bucket UUIDs to create locations for
    * `file_path` - The storage path for the file

  ## Examples

      iex> create_file_locations_for_instance(instance_uuid, [bucket_uuid], "path/to/file")
      {:ok, [%FileLocation{}]}

      iex> create_file_locations_for_instance(instance_uuid, [invalid_bucket], "path")
      {:error, :file_locations_failed, [{bucket_uuid, changeset}]}

  """
  def create_file_locations_for_instance(file_instance_uuid, bucket_uuids, file_path) do
    create_file_locations(file_instance_uuid, bucket_uuids, file_path)
  end

  defp generate_temp_path do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_#{random_name}")
  end

  defp create_file_locations(file_instance_uuid, bucket_uuids, file_path) do
    results =
      Enum.map(bucket_uuids, fn bucket_uuid ->
        location_attrs = %{
          path: file_path,
          status: "active",
          priority: 0,
          file_instance_uuid: file_instance_uuid,
          bucket_uuid: bucket_uuid
        }

        case repo().insert(%FileLocation{} |> FileLocation.changeset(location_attrs)) do
          {:ok, location} -> {:ok, location}
          {:error, changeset} -> {:error, bucket_uuid, changeset}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _, _}, &1))

    if errors == [] do
      locations = Enum.map(results, fn {:ok, loc} -> loc end)
      # The writer knows every bucket it stored in: the instance is checked.
      Locations.mark_checked([file_instance_uuid], length(Enum.uniq(bucket_uuids)))
      {:ok, locations}
    else
      error_details =
        Enum.map(errors, fn {:error, bucket_uuid, changeset} -> {bucket_uuid, changeset} end)

      {:error, :file_locations_failed, error_details}
    end
  end
end
