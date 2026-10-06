defmodule PhoenixKit.Modules.Storage.VariantSet do
  @moduledoc """
  A variant set: which derived files a library's uploads get (V205).

  A library points at a set (`variant_set_uuid`; NULL means the Default,
  `PhoenixKit.Modules.Storage.VariantSets.default_uuid/0`). The set's sizes
  are its `PhoenixKit.Modules.Storage.Dimension` rows. Sets are defined by
  admins only; a user library may choose a set marked `selectable`.

    * `generate_variants` — sizes are made automatically after an upload
      (what the `storage_auto_generate_variants` setting was);
    * `generate_tiles` — zoomable tiles are made on request (what
      `storage_tile_generation_enabled` was). Legacy: deep zoom is a library
      setting now (`Libraries.setting(library, :deep_zoom)`), and this flag is
      only what a library that has not chosen follows.

  `revision` goes up on every change to the set or its sizes. A file
  records the set and revision its variants were made by, and is stale,
  for the reconciler, when either differs from its library's.

  Go through `PhoenixKit.Modules.Storage.VariantSets` rather than this
  schema.
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
          selectable: boolean(),
          generate_variants: boolean(),
          generate_tiles: boolean(),
          revision: pos_integer(),
          dimensions: [PhoenixKit.Modules.Storage.Dimension.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_variant_sets" do
    field :name, :string
    field :is_default, :boolean, default: false
    field :selectable, :boolean, default: false
    field :generate_variants, :boolean, default: true
    field :generate_tiles, :boolean, default: false
    field :revision, :integer, default: 1

    has_many :dimensions, PhoenixKit.Modules.Storage.Dimension,
      foreign_key: :variant_set_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc "Name and flags. `is_default` and `revision` are never cast."
  def changeset(set, attrs) do
    set
    |> cast(attrs, [:name, :selectable, :generate_variants, :generate_tiles])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> unique_constraint(:name, name: :phoenix_kit_variant_sets_name_index)
  end
end
