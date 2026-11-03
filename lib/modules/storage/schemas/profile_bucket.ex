defmodule PhoenixKit.Modules.Storage.ProfileBucket do
  @moduledoc """
  One bucket of a storage profile (V205), and how the profile uses it.

    * `role` — `primary` (written and served), `replica` (written; served
      when no primary has the object) or `backup` (written; read only by
      repair and the reconciler, never served).
    * `write_priority` — writes go to buckets with a fixed priority first
      (lowest first), then to the rest in random order (`nil`).
    * `serve_order` — among the buckets that hold an object and may serve
      it, the lowest is served from.
    * `status` — `active`, `read_only` (keeps serving, gets no new writes)
      or `draining` (the reconciler copies its objects to the profile's
      other buckets, then unlinks them).
    * `storage_class` and `encryption` are reserved for later (G10);
      `storage_class` is allowed only on a `backup` row, because archive
      tiers need a restore before a read.

    * `stores` — `all` (the default: an original and everything made from it)
      or, on a `backup` row only, `originals`: an off-site copy of what cannot
      be made again, without the sizes, tiles and renders that can. Placement
      and the reconciler leave such a bucket out for derived objects
      (`takes?/2`), so the copies a profile wants of them are capped at the
      buckets that take them, and derived copies already there are removed.
      Any other value (`derived`, left from before 2.53, or `originals` on a
      row that is not a backup) is treated as `all`.

  A bucket's global `enabled` flag is still the stop: a disabled bucket is
  neither written nor read, whatever its profile rows say. Because that would
  strand the libraries on the profile, `Storage.update_bucket/3` refuses to
  disable a bucket while any profile has a row for it, and `Storage.delete_bucket/2`
  refuses to delete it (`Profiles.bucket_usage/1` says which profiles); a row
  is removed first, on purpose.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type UUIDv7

  @roles ~w(primary replica backup)
  @statuses ~w(active read_only draining)
  @stores ~w(all originals)

  @type t :: %__MODULE__{
          profile_uuid: UUIDv7.t() | nil,
          bucket_uuid: UUIDv7.t() | nil,
          role: String.t(),
          write_priority: integer() | nil,
          serve_order: integer(),
          status: String.t(),
          stores: String.t(),
          storage_class: String.t() | nil,
          encryption: map() | nil,
          bucket: PhoenixKit.Modules.Storage.Bucket.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_storage_profile_buckets" do
    belongs_to :profile, PhoenixKit.Modules.Storage.StorageProfile,
      foreign_key: :profile_uuid,
      references: :uuid,
      primary_key: true

    belongs_to :bucket, PhoenixKit.Modules.Storage.Bucket,
      foreign_key: :bucket_uuid,
      references: :uuid,
      primary_key: true

    field :role, :string, default: "primary"
    field :write_priority, :integer
    field :serve_order, :integer, default: 0
    field :status, :string, default: "active"
    field :stores, :string, default: "all"
    field :storage_class, :string
    field :encryption, :map

    timestamps(type: :utc_datetime)
  end

  @doc "The roles, in the order buckets are written and served."
  def roles, do: @roles

  @doc "The statuses."
  def statuses, do: @statuses

  @doc """
  Whether a profile sends this bucket objects of `kind` (`:original` or
  `:derived`): every bucket takes originals, and every one but a backup that
  stores originals only takes what is made from them.
  """
  @spec takes?(%{optional(:role) => String.t(), optional(:stores) => String.t()}, atom()) ::
          boolean()
  def takes?(%{role: "backup", stores: "originals"}, :derived), do: false
  def takes?(_row, _kind), do: true

  @doc "How a profile uses a bucket. The keys are set by the caller."
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:role, :write_priority, :serve_order, :status, :stores, :storage_class])
    |> validate_required([:role, :serve_order, :status])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> normalize_stores()
    |> validate_number(:write_priority, greater_than_or_equal_to: 1)
    |> validate_number(:serve_order, greater_than_or_equal_to: 0)
    |> validate_length(:storage_class, max: 64)
    |> validate_storage_class()
    |> assoc_constraint(:bucket, name: :phoenix_kit_storage_profile_buckets_bucket_fkey)
    |> unique_constraint([:profile_uuid, :bucket_uuid],
      name: :phoenix_kit_storage_profile_buckets_pkey
    )
  end

  # Only a backup may store originals alone: a primary or replica is served
  # from, and must hold what is served. Leaving the backup role stores
  # everything again rather than failing the save.
  defp normalize_stores(changeset) do
    cond do
      get_field(changeset, :role) != "backup" and get_field(changeset, :stores) != "all" ->
        put_change(changeset, :stores, "all")

      get_field(changeset, :stores) in [nil, ""] ->
        put_change(changeset, :stores, "all")

      true ->
        validate_inclusion(changeset, :stores, @stores)
    end
  end

  defp validate_storage_class(changeset) do
    if get_field(changeset, :storage_class) not in [nil, ""] and
         get_field(changeset, :role) != "backup" do
      add_error(changeset, :storage_class, "is only allowed on a backup copy")
    else
      changeset
    end
  end
end
