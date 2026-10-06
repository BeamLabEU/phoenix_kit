defmodule PhoenixKit.Modules.Storage.Profiles do
  @moduledoc """
  Storage profiles: where a library's bytes live (V205).

  A library points at a profile (`PhoenixKit.Modules.Storage.StorageProfile`),
  and the profile lists its buckets with how it uses each
  (`PhoenixKit.Modules.Storage.ProfileBucket`: role, write priority, serve
  order, status) and how many copies an object gets, on local buckets and on
  cloud ones. A
  library with no profile uses the **Default**, seeded by V205 from the
  install's buckets and `storage_redundancy_copies` under a fixed uuid
  (`default_uuid/0`), so an install that never touches profiles behaves as
  it did before.

  Every change to a profile or its buckets bumps its `revision`
  (`bump_revision/1`). A file records the profile and revision it was
  placed by (`placed_profile_uuid` / `placed_revision`, NULL meaning the
  Default at revision 1), which is how the reconciler finds the files that
  are not where their library's profile wants them.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.{Library, ProfileBucket, StorageProfile}
  alias PhoenixKit.Modules.Storage.Workers.ReconcileJob
  alias PhoenixKit.Settings

  @default_uuid "00000000-0000-7000-8000-000000000002"

  @doc "The uuid of the Default profile, fixed on every install."
  @spec default_uuid() :: String.t()
  def default_uuid, do: @default_uuid

  @doc "Whether `uuid` is the Default profile's."
  @spec default?(term()) :: boolean()
  def default?(%StorageProfile{uuid: uuid}), do: default?(uuid)
  def default?(uuid), do: to_string(uuid) == @default_uuid

  @doc """
  The site's profiles, the Default first, each with its buckets. A user's own
  profile (V206) is not here: the site's profile editor and pickers read this,
  and a user's storage is not something an admin assigns or edits.
  """
  @spec list_profiles() :: [StorageProfile.t()]
  def list_profiles do
    from(p in StorageProfile,
      where: is_nil(p.owner_uuid),
      order_by: [desc: p.is_default, asc: fragment("lower(?)", p.name)]
    )
    |> repo().all()
    |> preload_buckets()
  end

  @doc "A profile with its buckets, or nil (also for anything not a uuid)."
  @spec get_profile(term()) :: StorageProfile.t() | nil
  def get_profile(uuid) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %StorageProfile{} = profile <- repo().get(StorageProfile, uuid) do
      preload_buckets(profile)
    else
      _ -> nil
    end
  end

  @doc "The Default profile, with its buckets."
  @spec default_profile() :: StorageProfile.t() | nil
  def default_profile, do: get_profile(@default_uuid)

  @doc """
  How many copies of an original the Default keeps (1 when there is no
  Default yet, as `storage_redundancy_copies` defaulted to).
  """
  @spec default_copies() :: pos_integer()
  def default_copies do
    from(p in StorageProfile, where: p.uuid == ^@default_uuid, select: p.copies_originals)
    |> repo().one() || 1
  end

  @doc """
  The uuid of the profile `library` uses: its own, or the Default. Takes a
  library, a library uuid, or nil (a file with no library is in Media).
  """
  @spec profile_uuid_for(Library.t() | term()) :: String.t()
  def profile_uuid_for(%Library{storage_profile_uuid: nil}), do: @default_uuid
  def profile_uuid_for(%Library{storage_profile_uuid: uuid}), do: to_string(uuid)
  def profile_uuid_for(nil), do: profile_uuid_for(Libraries.media_uuid())

  def profile_uuid_for(library_uuid) do
    case Libraries.get_library(library_uuid) do
      %Library{} = library -> profile_uuid_for(library)
      nil -> @default_uuid
    end
  end

  @doc """
  The profile `library` uses, with its buckets (see `profile_uuid_for/1`).
  Falls back to the Default when the library's own is gone.
  """
  @spec for_library(Library.t() | term()) :: StorageProfile.t() | nil
  def for_library(library) do
    library |> profile_uuid_for() |> get_profile() || default_profile()
  end

  @doc "The profile a file's library uses."
  @spec for_file(StorageFile.t()) :: StorageProfile.t() | nil
  def for_file(%StorageFile{library_uuid: library_uuid}), do: for_library(library_uuid)

  @doc """
  The copies `profile` wants on one kind of bucket: `:local` (the server's
  disks) or `:cloud`. Every file, an original and what is made from it, gets the
  same.
  """
  @spec copies(StorageProfile.t(), :local | :cloud) :: non_neg_integer()
  def copies(%StorageProfile{copies_local: n}, :local), do: n
  def copies(%StorageProfile{copies_cloud: n}, :cloud), do: n

  @doc "How many copies of a file `profile` wants in all: local plus cloud."
  @spec copies_total(StorageProfile.t()) :: pos_integer()
  def copies_total(%StorageProfile{copies_local: local, copies_cloud: cloud}), do: local + cloud

  @doc """
  `total` copies split over the profile's buckets, local first: the cloud share
  is what the local buckets cannot take, up to the cloud buckets it has (active
  and enabled); the rest is local. `%{copies_local: n, copies_cloud: m}` with
  `n + m == total`. How a count that knows no kinds (the old redundancy setting)
  becomes the two.
  """
  @spec split_copies(StorageProfile.t(), pos_integer()) :: %{
          copies_local: non_neg_integer(),
          copies_cloud: non_neg_integer()
        }
  def split_copies(%StorageProfile{buckets: rows}, total) do
    writable = Enum.filter(rows, &(&1.status == "active" and &1.bucket.enabled))
    local = Enum.count(writable, &(Bucket.group(&1.bucket) == :local))
    cloud = Enum.count(writable, &(Bucket.group(&1.bucket) == :cloud))
    share = min(cloud, max(total - local, 0))

    %{copies_local: total - share, copies_cloud: share}
  end

  @doc """
  The counts `profile` can actually keep: each kind's count lowered to the
  writable buckets (active, enabled) it has of that kind, never raised. When that
  leaves nothing (it wants only a kind it has no bucket of), the total is split
  over the buckets it has instead (`split_copies/2`).
  """
  @spec fit_copies(StorageProfile.t()) :: %{
          copies_local: non_neg_integer(),
          copies_cloud: non_neg_integer()
        }
  def fit_copies(%StorageProfile{} = profile) do
    %{local: local, cloud: cloud} = copies_advice(profile)

    fitted = %{
      copies_local: min(profile.copies_local, local.buckets),
      copies_cloud: min(profile.copies_cloud, cloud.buckets)
    }

    if fitted.copies_local + fitted.copies_cloud >= 1 do
      fitted
    else
      split_copies(profile, min(copies_total(profile), max(local.buckets + cloud.buckets, 1)))
    end
  end

  @doc """
  What a profile's copy counts mean for the buckets it has now, for the screens
  that tell an admin and the one place that must agree with what they say.

  A file is written to the first `copies_local` writable local buckets and the
  first `copies_cloud` writable cloud buckets, each in role order — primaries,
  then replicas, then backups — so a count says how many of them get it. For
  each kind (`local`, `cloud`):

    * `buckets` — how many can take a new file (active in the profile, enabled);
    * `primaries` — how many of those are primaries;
    * `copies` — the profile's count for it;
    * `idle` — the names of the replicas and backups the count never reaches (it
      does not exceed the primaries), which hold nothing unless a write to a
      primary fails.

  `writable` is the buckets of both kinds. Takes a profile with its buckets
  loaded.
  """
  @spec copies_advice(StorageProfile.t()) :: %{
          writable: non_neg_integer(),
          copies: non_neg_integer(),
          local: map(),
          cloud: map()
        }
  def copies_advice(%StorageProfile{} = profile) do
    rows = Enum.filter(profile.buckets, &(&1.status == "active" and &1.bucket.enabled))

    %{
      writable: length(rows),
      copies: copies_total(profile),
      local: kind_advice(rows, :local, profile.copies_local),
      cloud: kind_advice(rows, :cloud, profile.copies_cloud)
    }
  end

  defp kind_advice(rows, kind, copies) do
    rows = Enum.filter(rows, &(Bucket.group(&1.bucket) == kind))
    {primaries, others} = Enum.split_with(rows, &(&1.role == "primary"))

    %{
      buckets: length(rows),
      primaries: length(primaries),
      copies: copies,
      # The upload order only decides anything when there are more writable
      # buckets than copies to make: otherwise every one of them is written.
      order_matters: copies > 0 and length(rows) > copies,
      idle:
        if(copies > 0 and copies <= length(primaries),
          do: Enum.map(others, & &1.bucket.name),
          else: []
        )
    }
  end

  @doc """
  Creates a profile with no buckets. `opts` (`:actor_uuid`, `:mode`) say who did it,
  for the history (`Storage.Audit`).
  """
  @spec create_profile(map(), keyword()) ::
          {:ok, StorageProfile.t()} | {:error, Ecto.Changeset.t()}
  def create_profile(attrs, opts \\ []) do
    Audit.transaction(fn -> do_create_profile(attrs, opts) end)
  end

  defp do_create_profile(attrs, opts) do
    %StorageProfile{}
    |> StorageProfile.changeset(attrs)
    |> repo().insert()
    |> case do
      {:ok, profile} ->
        audit_profile(profile, "storage.profile.created", opts, %{"name" => profile.name})
        {:ok, preload_buckets(profile)}

      error ->
        error
    end
  end

  # A user's own profile is theirs and private: only the site's are in the history.
  defp audit_profile(%StorageProfile{owner_uuid: nil} = profile, action, opts, metadata) do
    Audit.log(action, "storage_profile", profile.uuid, opts, metadata)
    :ok
  end

  defp audit_profile(_profile, _action, _opts, _metadata), do: :ok

  @doc "Updates a profile's name or copy counts; a real change bumps its revision."
  @spec update_profile(StorageProfile.t(), map(), keyword()) ::
          {:ok, StorageProfile.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(%StorageProfile{} = profile, attrs, opts \\ []) do
    Audit.change(profile, fn current -> do_update_profile(current, attrs, opts) end)
  end

  defp do_update_profile(profile, attrs, opts) do
    changeset = StorageProfile.changeset(profile, attrs)

    transact(fn ->
      with {:ok, updated} <- repo().update(changeset) do
        if placement_changed?(changeset), do: bump_revision(updated.uuid)
        {:ok, updated.uuid}
      end
    end)
    |> reload(opts)
    |> tap(fn
      {:ok, updated} ->
        changes =
          Audit.changes(changeset, [
            :name,
            :copies_local,
            :copies_cloud,
            :min_copies_on_write
          ])

        unless changes == %{},
          do:
            audit_profile(updated, "storage.profile.updated", opts, %{
              "name" => updated.name,
              PhoenixKit.Activity.changes_key() => changes
            })

      _error ->
        :ok
    end)
  end

  # A rename moves no bytes, and neither does how many copies an upload
  # needs (it applies to the next upload): neither makes every file stale.
  defp placement_changed?(changeset),
    do: Map.drop(changeset.changes, [:name, :min_copies_on_write]) != %{}

  @doc """
  Deletes a profile. The Default cannot be deleted
  (`{:error, :default}`), nor a profile a library uses
  (`{:error, :in_use}`).
  """
  @spec delete_profile(StorageProfile.t(), keyword()) ::
          {:ok, StorageProfile.t()} | {:error, :default | :in_use | Ecto.Changeset.t()}
  def delete_profile(%StorageProfile{} = profile, opts \\ []) do
    Audit.change(profile, &do_delete_profile(&1, opts))
  end

  defp do_delete_profile(profile, opts) do
    cond do
      default?(profile) ->
        {:error, :default}

      libraries_using(profile.uuid) > 0 ->
        {:error, :in_use}

      true ->
        profile
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.foreign_key_constraint(:uuid,
          name: :phoenix_kit_storage_libraries_profile_fkey,
          message: "is used by a library"
        )
        |> repo().delete()
        |> tap(fn
          {:ok, deleted} ->
            audit_profile(deleted, "storage.profile.deleted", opts, %{"name" => deleted.name})

          _error ->
            :ok
        end)
    end
  end

  @doc """
  How many libraries (trashed ones included) use `profile_uuid`. For the Default
  that is the libraries that name it and those that name no profile at all,
  which use it too (`profile_uuid_for/1`).
  """
  @spec libraries_using(term()) :: non_neg_integer()
  def libraries_using(profile_uuid) do
    query =
      if default?(profile_uuid),
        do:
          from(l in Library,
            where: is_nil(l.storage_profile_uuid) or l.storage_profile_uuid == ^profile_uuid
          ),
        else: from(l in Library, where: l.storage_profile_uuid == ^profile_uuid)

    repo().one(from(l in query, select: count()))
  end

  @doc """
  Adds `bucket_uuid` to `profile`, or changes how the profile uses it, and
  bumps the profile's revision.
  """
  @spec put_bucket(StorageProfile.t(), term(), map(), keyword()) ::
          {:ok, ProfileBucket.t()} | {:error, Ecto.Changeset.t()}
  def put_bucket(%StorageProfile{} = profile, bucket_uuid, attrs, opts \\ []) do
    Audit.change(profile, fn current ->
      with :ok <- check_same_owner(current.uuid, bucket_uuid) do
        do_put_bucket(current, bucket_uuid, attrs, opts)
      end
    end)
  end

  # A user's bucket is only ever in its owner's profile, and a user's profile
  # holds only the site's buckets and its owner's own: nobody's storage is
  # reachable through somebody else's profile.
  defp check_same_owner(profile_uuid, bucket_uuid) do
    profile_owner =
      repo().one(from(p in StorageProfile, where: p.uuid == ^profile_uuid, select: p.owner_uuid))

    bucket_owner =
      repo().one(
        from(b in PhoenixKit.Modules.Storage.Bucket,
          where: b.uuid == ^bucket_uuid,
          select: b.owner_uuid
        )
      )

    if is_nil(bucket_owner) or bucket_owner == profile_owner,
      do: :ok,
      else: {:error, :foreign_bucket}
  end

  defp do_put_bucket(%StorageProfile{uuid: profile_uuid} = profile, bucket_uuid, attrs, opts) do
    row =
      repo().get_by(ProfileBucket, profile_uuid: profile_uuid, bucket_uuid: bucket_uuid) ||
        %ProfileBucket{profile_uuid: profile_uuid, bucket_uuid: bucket_uuid}

    changeset = ProfileBucket.changeset(row, attrs)
    added? = row.__meta__.state == :built

    transact(fn ->
      with {:ok, saved} <- repo().insert_or_update(changeset) do
        if added? or moves_bytes?(changeset), do: bump_revision(profile_uuid)

        {:ok, saved}
      end
    end)
    |> tap(fn
      {:ok, saved} -> audit_bucket_row(profile, saved, changeset, added?, opts)
      _error -> :ok
    end)
  end

  # Adding a bucket to a profile, or changing how the profile uses it. Only the
  # row's own fields are named, with their old and new values.
  @row_fields [:role, :status, :serve_order, :write_priority, :storage_class]

  defp audit_bucket_row(profile, saved, changeset, added?, opts) do
    bucket = bucket_name(saved.bucket_uuid)

    base = %{
      "profile" => profile.name,
      "bucket" => bucket,
      "bucket_uuid" => to_string(saved.bucket_uuid)
    }

    if added? do
      detail =
        Map.new(@row_fields, fn field ->
          {Atom.to_string(field), loggable_row(Map.get(saved, field))}
        end)

      audit_profile(profile, "storage.profile.bucket_added", opts, Map.merge(base, detail))
    else
      changes = Audit.changes(changeset, @row_fields)

      if changes != %{},
        do:
          audit_profile(
            profile,
            "storage.profile.bucket_changed",
            opts,
            Map.put(base, PhoenixKit.Activity.changes_key(), changes)
          )
    end

    :ok
  end

  defp loggable_row(nil), do: nil

  defp loggable_row(value) when is_atom(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp loggable_row(value), do: value

  defp bucket_name(bucket_uuid) do
    repo().one(
      from(b in PhoenixKit.Modules.Storage.Bucket, where: b.uuid == ^bucket_uuid, select: b.name)
    )
  end

  # What a file's placement depends on: a bucket's status and its role (a file
  # needs a copy it may serve). The serve order is read
  # when a request is served, and a write priority or storage class only
  # applies to the next write: changing them makes no file stale.
  defp moves_bytes?(changeset),
    do: Map.take(changeset.changes, [:status, :role]) != %{}

  @doc "Takes `bucket_uuid` out of `profile` and bumps the profile's revision."
  @spec remove_bucket(StorageProfile.t(), term(), keyword()) :: :ok | {:error, term()}
  def remove_bucket(%StorageProfile{} = profile, bucket_uuid, opts \\ []) do
    Audit.change(profile, &do_remove_bucket(&1, bucket_uuid, opts))
  end

  defp do_remove_bucket(%StorageProfile{uuid: profile_uuid} = profile, bucket_uuid, opts) do
    {:ok, count} =
      transact(fn ->
        {count, _} =
          from(r in ProfileBucket,
            where: r.profile_uuid == ^profile_uuid and r.bucket_uuid == ^bucket_uuid
          )
          |> repo().delete_all()

        if count > 0, do: bump_revision(profile_uuid)
        {:ok, count}
      end)

    if count > 0 do
      audit_profile(profile, "storage.profile.bucket_removed", opts, %{
        "profile" => profile.name,
        "bucket" => bucket_name(bucket_uuid),
        "bucket_uuid" => to_string(bucket_uuid)
      })
    end

    :ok
  end

  @doc """
  Puts a newly created bucket into the Default profile, the way every new
  bucket joined the pool before profiles: primary, active, no fixed write priority (it is in the shuffled pool),
  served after the Default's other buckets (a local one before the remote
  ones). The default of `Storage.create_bucket/2`; a caller that wants none or
  another profile says so there (`:profile`).
  """
  @spec add_to_default(PhoenixKit.Modules.Storage.Bucket.t()) :: :ok
  def add_to_default(bucket) do
    # Profiles are seeded by V205; before that (or on a database repair has
    # not reached yet) there is no Default to add to.
    if repo().get(StorageProfile, @default_uuid) do
      :ok = add_bucket(@default_uuid, bucket, audit: false)
    end

    :ok
  end

  @doc """
  Puts `bucket` into one of the site's profiles as a primary that stores
  everything, active, with no fixed write priority (the shuffled pool), served after the
  profile's other buckets, and bumps the profile's revision (its files are
  placed again). Change the role, order or status afterwards with
  `put_bucket/4`.

  `{:error, :not_found}` for a uuid that is no site profile: a user's own
  profile is never one an admin adds a site bucket to. `opts` are `put_bucket/4`'s
  (`:actor_uuid`, `audit: false`).
  """
  @spec add_bucket(term(), PhoenixKit.Modules.Storage.Bucket.t(), keyword()) ::
          :ok | {:error, :not_found | Ecto.Changeset.t()}
  def add_bucket(profile_uuid, bucket, opts \\ []) do
    case get_profile(profile_uuid) do
      %StorageProfile{owner_uuid: nil} = profile ->
        serve_order =
          from(r in ProfileBucket,
            where: r.profile_uuid == ^profile.uuid,
            select: coalesce(max(r.serve_order), 0)
          )
          |> repo().one()

        attrs = %{
          role: "primary",
          status: "active",
          write_priority: nil,
          serve_order: serve_order + 1
        }

        with {:ok, _row} <- put_bucket(profile, bucket.uuid, attrs, opts), do: :ok

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Which profiles use each of `bucket_uuids`, and how many libraries stand
  behind each one: `%{bucket_uuid => [usage]}`, a bucket no profile uses
  absent from the map. Every profile row counts, whatever its role or status
  (`draining` and `read_only` still hold or serve objects), and a user's own
  profile counts too — a site bucket may be one half of their backup.

  A `usage` is `%{profile_uuid, name, is_default, owner_uuid, role, status,
  libraries}`, the Default first. `libraries` counts the libraries on the
  profile, trashed ones included, and for the Default those that name no
  profile. Callers that show it must not name a user's profile or library
  (`owner_uuid` is set on the first; count the second).

  This is what refuses deleting or disabling a bucket (`Storage.delete_bucket/2`,
  `Storage.update_bucket/3`) and what the Buckets list shows.
  """
  @spec bucket_usage([term()]) :: %{optional(String.t()) => [map()]}
  def bucket_usage([]), do: %{}

  def bucket_usage(bucket_uuids) when is_list(bucket_uuids) do
    rows =
      from(r in ProfileBucket,
        join: p in StorageProfile,
        on: p.uuid == r.profile_uuid,
        where: r.bucket_uuid in ^bucket_uuids,
        order_by: [desc: p.is_default, asc: fragment("lower(?)", p.name), asc: p.uuid],
        select: %{
          bucket_uuid: r.bucket_uuid,
          profile_uuid: p.uuid,
          name: p.name,
          is_default: p.is_default,
          owner_uuid: p.owner_uuid,
          role: r.role,
          status: r.status
        }
      )
      |> repo().all()

    counts = rows |> Enum.map(& &1.profile_uuid) |> Enum.uniq() |> library_counts()

    rows
    |> Enum.map(fn row ->
      row
      |> Map.update!(:bucket_uuid, &to_string/1)
      |> Map.update!(:profile_uuid, &to_string/1)
      |> Map.put(:libraries, Map.get(counts, to_string(row.profile_uuid), 0))
    end)
    |> Enum.group_by(& &1.bucket_uuid)
  end

  # Libraries per profile, as `libraries_using/1` counts them, in one pass.
  defp library_counts([]), do: %{}

  defp library_counts(profile_uuids) do
    explicit =
      from(l in Library,
        where: l.storage_profile_uuid in ^profile_uuids,
        group_by: l.storage_profile_uuid,
        select: {l.storage_profile_uuid, count()}
      )
      |> repo().all()
      |> Map.new(fn {uuid, count} -> {to_string(uuid), count} end)

    if Enum.any?(profile_uuids, &default?/1) do
      unnamed =
        repo().one(from(l in Library, where: is_nil(l.storage_profile_uuid), select: count()))

      Map.update(explicit, @default_uuid, unnamed, &(&1 + unnamed))
    else
      explicit
    end
  end

  @doc """
  The names of the site libraries on `profile_uuid` (the Default's include
  those that name no profile), and how many user libraries are on it besides.
  A user's library is private to its owner, so it is counted, never named.
  """
  @spec library_names_using(term()) :: %{names: [String.t()], user_libraries: non_neg_integer()}
  def library_names_using(profile_uuid) do
    base =
      if default?(profile_uuid),
        do:
          from(l in Library,
            where: is_nil(l.storage_profile_uuid) or l.storage_profile_uuid == ^profile_uuid
          ),
        else: from(l in Library, where: l.storage_profile_uuid == ^profile_uuid)

    names =
      from(l in base,
        where: l.kind != "user",
        order_by: fragment("lower(?)", l.name),
        select: l.name
      )
      |> repo().all()

    users = repo().one(from(l in base, where: l.kind == "user", select: count()))

    %{names: names, user_libraries: users}
  end

  @doc """
  Points `library` at `profile_uuid` (nil for the Default). Its files
  become stale unless the new profile is the one they were placed by.
  """
  @spec set_library_profile(Library.t(), term(), keyword()) ::
          {:ok, Library.t()}
          | {:error, Ecto.Changeset.t() | :not_found | :user_storage_locked}
  def set_library_profile(%Library{} = library, profile_uuid, opts \\ []) do
    Audit.change(library, &do_change_library_profile(&1, profile_uuid, opts))
  end

  defp do_change_library_profile(%Library{uuid: uuid} = library, profile_uuid, opts) do
    profile_uuid = if default?(profile_uuid), do: nil, else: profile_uuid
    before = profile_uuid_for(library)

    # Decided on the library as it is NOW, under a row lock: the struct the
    # caller holds may be stale (another request may have put the library on a
    # user's storage since), and two callers must not both pass the check.
    locked_library_update(uuid, fn current ->
      target = profile_uuid && get_profile(profile_uuid)

      cond do
        is_nil(current) -> {:error, :not_found}
        profile_uuid && is_nil(target) -> {:error, :not_found}
        # Where a user library keeps its bytes is chosen when it is created and
        # does not change: not off the user's own storage, and not onto anyone's.
        user_profile?(current.storage_profile_uuid) -> {:error, :user_storage_locked}
        target && target.owner_uuid != nil -> {:error, :user_storage_locked}
        true -> do_set_library_profile(current, profile_uuid)
      end
    end)
    |> tap(fn
      {:ok, updated} -> audit_library_profile(updated, before, opts)
      _error -> :ok
    end)
  end

  # A system library moving to another profile: from and to, by name. A user's
  # library is theirs and private, and is not in the history.
  defp audit_library_profile(%Library{kind: "system"} = library, before_uuid, opts) do
    now = profile_uuid_for(library)

    if now != before_uuid do
      Audit.log("storage.library.profile_changed", "storage_library", library.uuid, opts, %{
        "library" => library.name,
        PhoenixKit.Activity.changes_key() => %{
          "profile" => %{"from" => profile_name(before_uuid), "to" => profile_name(now)}
        }
      })
    end

    :ok
  end

  defp audit_library_profile(_library, _before, _opts), do: :ok

  defp profile_name(uuid) do
    case get_profile(uuid) do
      %StorageProfile{name: name} -> name
      nil -> to_string(uuid)
    end
  end

  @doc false
  # Points a NEW user library at its own profile (V206): the one way a library
  # gets a user's profile, and only a library that has none yet (the row as it
  # is now, under a lock): anything else is `{:error, :user_storage_locked}`.
  # `set_library_profile/2` refuses a user's profile altogether.
  def assign_user_profile(
        %Library{kind: "user", owner_uuid: owner, uuid: uuid},
        %StorageProfile{
          owner_uuid: owner
        } = profile
      )
      when is_binary(owner) do
    locked_library_update(uuid, fn
      %Library{kind: "user", owner_uuid: ^owner, storage_profile_uuid: nil} = current ->
        do_set_library_profile(current, profile.uuid)

      %Library{} ->
        {:error, :user_storage_locked}

      nil ->
        {:error, :not_found}
    end)
  end

  # Runs `fun` with the library row as it is now, locked for the rest of the
  # transaction (`FOR NO KEY UPDATE`: other rows reference it by foreign key).
  defp locked_library_update(uuid, fun) do
    repo().transaction(fn ->
      current =
        repo().one(from(l in Library, where: l.uuid == ^uuid, lock: "FOR NO KEY UPDATE"))

      case fun.(current) do
        {:ok, library} -> library
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp user_profile?(nil), do: false

  defp user_profile?(uuid),
    do:
      repo().exists?(
        from(p in StorageProfile, where: p.uuid == ^uuid and not is_nil(p.owner_uuid))
      )

  defp do_set_library_profile(library, profile_uuid) do
    library
    |> Ecto.Changeset.change(storage_profile_uuid: profile_uuid)
    |> Ecto.Changeset.foreign_key_constraint(:storage_profile_uuid,
      name: :phoenix_kit_storage_libraries_profile_fkey
    )
    |> repo().update()
    |> tap(&if(match?({:ok, _}, &1), do: ReconcileJob.enqueue()))
  end

  # ===== A user's own storage (V206) =====

  @doc """
  Creates the profile of a user's own storage, in one of two modes:

    * `:only` — the user's bucket is the profile's one `primary`: everything
      the library stores lives there.
    * `:backup` — the site's buckets stay and the user's bucket is a `backup`
      of every file, including sizes and tiles. The site buckets are a
      **snapshot of the Default profile taken now**: a site bucket added later
      is not used by this library (removing or disabling one already reaches
      every profile). Every file gets a copy on each writable site bucket,
      counted per kind, plus one cloud copy for the user's backup. There are at
      most 5 copies in all, so the site rows are limited to four, active first.
      An upload succeeds on the Default's terms, counting the site's copies
      only; the reconciler makes a backup copy the write missed. A site with
      no writable bucket has nothing to back up: `{:error, :no_site_storage}`.

  The profile is the user's (`owner_uuid`), named by its own uuid (the name is
  never shown), and `bucket` must be theirs. Returns `{:error, :no_site_storage}`
  for `:backup` on a site with no site bucket to back up.
  """
  @spec create_user_profile(String.t(), PhoenixKit.Modules.Storage.Bucket.t(), :only | :backup) ::
          {:ok, StorageProfile.t()} | {:error, :no_site_storage | :foreign_bucket | term()}
  def create_user_profile(owner_uuid, %{owner_uuid: owner_uuid} = bucket, mode)
      when is_binary(owner_uuid) and mode in [:only, :backup] do
    transact(fn ->
      with {:ok, rows, copies} <- user_profile_plan(mode, bucket),
           {:ok, profile} <- insert_user_profile(owner_uuid, copies),
           :ok <- insert_user_profile_rows(profile, rows) do
        {:ok, profile.uuid}
      end
    end)
    |> case do
      {:ok, uuid} -> {:ok, get_profile(uuid)}
      error -> error
    end
  end

  def create_user_profile(_owner_uuid, _bucket, _mode), do: {:error, :foreign_bucket}

  defp user_profile_plan(:only, bucket) do
    row = %{
      bucket_uuid: bucket.uuid,
      role: "primary",
      write_priority: nil,
      serve_order: 1,
      status: "active"
    }

    {:ok, [row], %{copies_local: 0, copies_cloud: 1, min_copies_on_write: 1}}
  end

  # Placement writes every primary before any backup, up to the copy count, so
  # a backup only gets a copy when the profile wants MORE copies than it has
  # writable primaries and replicas. The profile therefore wants a copy on every
  # writable site bucket, local ones on local and cloud ones on cloud, plus one
  # more cloud copy for the backup (at most 5 copies, so four site buckets, kept:
  # active before read-only, then by serve order). An upload succeeds on the
  # Default's terms: `min_copies_on_write` counts the site's copies only
  # (`Manager`), because a backup is never served; a backup the write missed is
  # made by the reconciler.
  @max_site_rows 4

  defp user_profile_plan(:backup, bucket) do
    case default_profile() do
      %StorageProfile{buckets: [_ | _] = rows} = default ->
        site_rows =
          rows
          |> Enum.filter(&(&1.status in ["active", "read_only"] and &1.bucket.owner_uuid == nil))
          |> Enum.sort_by(&{&1.status != "active", &1.serve_order})
          |> Enum.take(@max_site_rows)

        writable = Enum.filter(site_rows, &(&1.status == "active"))

        # Without a bucket a file can be WRITTEN to, the backup alone would
        # hold it: never served, and gone if the backup is. A read-only site
        # bucket does not count.
        if writable == [] do
          {:error, :no_site_storage}
        else
          backup = %{
            bucket_uuid: bucket.uuid,
            role: "backup",
            write_priority: nil,
            serve_order: Enum.max(Enum.map(site_rows, & &1.serve_order)) + 1,
            status: "active"
          }

          {:ok, Enum.map(site_rows, &site_row/1) ++ [backup],
           %{
             copies_local: Enum.count(writable, &(Bucket.group(&1.bucket) == :local)),
             # The user's bucket is S3-compatible: the backup is a cloud copy.
             copies_cloud: Enum.count(writable, &(Bucket.group(&1.bucket) == :cloud)) + 1,
             min_copies_on_write: min(default.min_copies_on_write, length(writable))
           }}
        end

      _ ->
        {:error, :no_site_storage}
    end
  end

  defp site_row(row) do
    %{
      bucket_uuid: row.bucket_uuid,
      role: row.role,
      write_priority: row.write_priority,
      serve_order: row.serve_order,
      status: row.status
    }
  end

  defp insert_user_profile(owner_uuid, copies) do
    %StorageProfile{}
    |> StorageProfile.changeset(Map.put(copies, :name, "user-storage-#{Ecto.UUID.generate()}"))
    |> Ecto.Changeset.put_change(:owner_uuid, owner_uuid)
    |> repo().insert()
  end

  defp insert_user_profile_rows(profile, rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      {bucket_uuid, attrs} = Map.pop!(row, :bucket_uuid)

      case put_bucket(profile, bucket_uuid, attrs) do
        {:ok, _row} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  What each of these libraries keeps its files on, for the ones on a user's own
  storage (V206): `%{library_uuid => %{mode: :only | :backup, bucket: Bucket.t()}}`.
  A library on the site's storage has no entry. One query.
  """
  @spec user_storage_for([Library.t()]) :: %{
          String.t() => %{mode: :only | :backup, bucket: PhoenixKit.Modules.Storage.Bucket.t()}
        }
  def user_storage_for([]), do: %{}

  def user_storage_for(libraries) do
    uuids = Enum.map(libraries, & &1.uuid)

    from(l in Library,
      join: p in StorageProfile,
      on: p.uuid == l.storage_profile_uuid and not is_nil(p.owner_uuid),
      join: pb in ProfileBucket,
      on: pb.profile_uuid == p.uuid,
      join: b in PhoenixKit.Modules.Storage.Bucket,
      on: b.uuid == pb.bucket_uuid and not is_nil(b.owner_uuid),
      where: l.uuid in ^uuids,
      select: {l.uuid, pb.role, b}
    )
    |> repo().all()
    |> Enum.group_by(fn {library_uuid, _role, _bucket} -> to_string(library_uuid) end)
    |> Map.new(fn {library_uuid, rows} ->
      {_uuid, role, bucket} = hd(rows)
      {library_uuid, %{mode: if(role == "backup", do: :backup, else: :only), bucket: bucket}}
    end)
  end

  @doc """
  Removes a user's own profile (V206) and the buckets that were in it and are
  in no profile now: what is left of a user's storage once their library is
  purged. A site profile, or one a library still uses, is left alone.

  Returns `:ok`, or `{:error, reason}` for the first bucket that could not go
  (one that still holds file locations cannot be deleted).
  """
  @spec delete_user_profile(term()) :: :ok | {:error, term()}
  def delete_user_profile(profile_uuid) do
    case get_profile(profile_uuid) do
      %StorageProfile{owner_uuid: owner} = profile when is_binary(owner) ->
        if libraries_using(profile.uuid) > 0,
          do: {:error, :in_use},
          else: remove_user_profile(profile)

      _ ->
        :ok
    end
  end

  defp remove_user_profile(profile) do
    bucket_uuids = Enum.map(profile.buckets, & &1.bucket_uuid)

    {:ok, _} =
      repo().transaction(fn ->
        from(r in ProfileBucket, where: r.profile_uuid == ^profile.uuid) |> repo().delete_all()
        repo().delete!(profile)
      end)

    bucket_uuids
    |> Storage.get_buckets()
    |> Enum.filter(&(is_binary(&1.owner_uuid) and not in_any_profile?(&1.uuid)))
    |> each_ok(fn bucket ->
      case Storage.delete_bucket(bucket) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp in_any_profile?(bucket_uuid),
    do: repo().exists?(from(r in ProfileBucket, where: r.bucket_uuid == ^bucket_uuid))

  defp each_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Bumps a profile's revision: every file it placed is stale, and the
  reconciler is queued to bring them up to date.
  """
  @spec bump_revision(term()) :: :ok
  def bump_revision(profile_uuid) do
    from(p in StorageProfile, where: p.uuid == ^profile_uuid)
    |> repo().update_all(
      inc: [revision: 1],
      set: [updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )

    ReconcileJob.enqueue()
    :ok
  end

  defp preload_buckets(profile_or_profiles) do
    rows = from(r in ProfileBucket, order_by: [asc: r.serve_order, asc: r.inserted_at])
    repo().preload(profile_or_profiles, buckets: {rows, :bucket})
  end

  defp reload({:ok, uuid}, opts) do
    profile = get_profile(uuid)

    # The Default's copy count is what `storage_redundancy_copies` was; the
    # row is kept in step for code that still reads it.
    if profile.is_default do
      Audit.after_commit(fn ->
        Settings.update_setting(
          "storage_redundancy_copies",
          to_string(profile.copies_originals),
          opts
        )
      end)
    end

    {:ok, profile}
  end

  defp reload(error, _opts), do: error

  defp transact(fun) do
    repo().transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
