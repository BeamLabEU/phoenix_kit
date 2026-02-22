defmodule PhoenixKit.Modules.Publishing.PublishingVersion do
  @moduledoc """
  Schema for publishing post versions.

  Each post can have multiple versions (v1, v2, etc.). Each version contains
  per-language content rows in `PublishingContent`.

  ## Status Flow

  - `draft` - Version is being edited
  - `published` - Version is live
  - `archived` - Version replaced by newer one

  ## Data JSONB Keys

  - `created_from` - Source version number this was created from
  - `notes` - Version notes/changelog
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          post_id: UUIDv7.t(),
          version_number: integer(),
          status: String.t(),
          created_by_uuid: UUIDv7.t() | nil,
          created_by_id: integer() | nil,
          data: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_publishing_versions" do
    field :version_number, :integer
    field :status, :string, default: "draft"
    field :data, :map, default: %{}

    belongs_to :post, PhoenixKit.Modules.Publishing.PublishingPost,
      foreign_key: :post_id,
      references: :uuid,
      type: UUIDv7

    belongs_to :created_by, PhoenixKit.Users.Auth.User,
      foreign_key: :created_by_uuid,
      references: :uuid,
      type: UUIDv7

    field :created_by_id, :integer

    has_many :contents, PhoenixKit.Modules.Publishing.PublishingContent, foreign_key: :version_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a publishing version.
  """
  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :post_id,
      :version_number,
      :status,
      :created_by_uuid,
      :created_by_id,
      :data
    ])
    |> validate_required([:post_id, :version_number, :status])
    |> validate_inclusion(:status, ["draft", "published", "archived"])
    |> validate_number(:version_number, greater_than: 0)
    |> unique_constraint([:post_id, :version_number], name: :idx_publishing_versions_post_number)
    |> foreign_key_constraint(:post_id, name: :fk_publishing_versions_post)
    |> foreign_key_constraint(:created_by_uuid, name: :fk_publishing_versions_created_by)
  end

  # Data JSONB accessors

  @doc "Returns the source version number this was created from."
  def get_created_from(%__MODULE__{data: data}), do: Map.get(data, "created_from")

  @doc "Returns version notes."
  def get_notes(%__MODULE__{data: data}), do: Map.get(data, "notes")
end
