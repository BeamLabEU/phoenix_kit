defmodule PhoenixKit.Modules.Storage.StorageProfile do
  @moduledoc """
  A storage profile: where a library's bytes live (V205).

  A library points at a profile (`storage_profile_uuid`; NULL means the
  Default, `PhoenixKit.Modules.Storage.Profiles.default_uuid/0`). The profile
  lists its buckets (`PhoenixKit.Modules.Storage.ProfileBucket`: role, what
  each stores, write priority, serve order, status) and says how many copies
  an object gets, counted per kind of bucket:

    * `copies_local` — copies on `local` buckets (0..5);
    * `copies_cloud` — copies on cloud buckets (S3, B2, R2, Tigris) (0..5): two
      on the server's disks and one in the cloud, which survives the server;
    * `min_copies_on_write` — an upload fails unless at least this many
      copies were written (1..total); the rest are made by the reconciler.

  The counts are for every file: an original and what is made from it get the
  same. `copies_originals` is the **total** (`copies_local + copies_cloud`, 1..5,
  held by a CHECK) and `copies_variants` is not used: `changeset/2` keeps both
  equal to it, so the older columns never say something else.

  `revision` goes up on every change to the profile or its buckets. A file
  records the profile and revision it was placed by, and is stale, for the
  reconciler, when either differs from its library's.

  Go through `PhoenixKit.Modules.Storage.Profiles` rather than this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          is_default: boolean(),
          copies_local: non_neg_integer(),
          copies_cloud: non_neg_integer(),
          copies_originals: pos_integer(),
          copies_variants: pos_integer(),
          min_copies_on_write: pos_integer(),
          revision: pos_integer(),
          owner_uuid: UUIDv7.t() | nil,
          buckets:
            [PhoenixKit.Modules.Storage.ProfileBucket.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_storage_profiles" do
    field :name, :string
    field :is_default, :boolean, default: false
    field :copies_local, :integer, default: 1
    field :copies_cloud, :integer, default: 0
    field :copies_originals, :integer, default: 1
    field :copies_variants, :integer, default: 1
    field :min_copies_on_write, :integer, default: 1
    field :revision, :integer, default: 1
    # Whose profile it is (V206). NULL is the site's; a user's is left out of
    # `Profiles.list_profiles/0`. Set only by `Profiles.create_user_profile/3`,
    # never cast from params.
    field :owner_uuid, UUIDv7

    has_many :buckets, PhoenixKit.Modules.Storage.ProfileBucket,
      foreign_key: :profile_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Name and the copy counts. `is_default` and `revision` are never cast.

  `copies_originals` (the total) and `copies_variants` are not cast either: they
  follow `copies_local + copies_cloud` whenever that changes.
  """
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :copies_local, :copies_cloud, :min_copies_on_write])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :copies_local, :copies_cloud, :min_copies_on_write])
    |> validate_length(:name, max: 255)
    |> validate_number(:copies_local, greater_than_or_equal_to: 0, less_than_or_equal_to: 5)
    |> validate_number(:copies_cloud, greater_than_or_equal_to: 0, less_than_or_equal_to: 5)
    |> validate_total()
    |> sync_total()
    |> validate_min_copies()
    |> unique_constraint(:name, name: :phoenix_kit_storage_profiles_name_index)
    |> check_constraint(:min_copies_on_write, name: :phoenix_kit_storage_profiles_copies_check)
    |> check_constraint(:copies_local, name: :phoenix_kit_storage_profiles_local_cloud_check)
  end

  defp total(changeset),
    do: (get_field(changeset, :copies_local) || 0) + (get_field(changeset, :copies_cloud) || 0)

  # At least one copy, and the five the database allows in all.
  defp validate_total(%{valid?: false} = changeset), do: changeset

  defp validate_total(changeset) do
    case total(changeset) do
      n when n < 1 -> add_error(changeset, :copies_local, "needs at least one copy in all")
      n when n > 5 -> add_error(changeset, :copies_local, "allows 5 copies in all")
      _ -> changeset
    end
  end

  # Only when a count changes: a rename must not look like a placement change.
  defp sync_total(%{valid?: false} = changeset), do: changeset

  defp sync_total(changeset) do
    if get_change(changeset, :copies_local) || get_change(changeset, :copies_cloud) do
      total = total(changeset)

      changeset
      |> put_change(:copies_originals, total)
      |> put_change(:copies_variants, total)
    else
      changeset
    end
  end

  defp validate_min_copies(changeset) do
    case total(changeset) do
      copies when copies >= 1 ->
        validate_number(changeset, :min_copies_on_write,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: copies
        )

      _ ->
        changeset
    end
  end
end
