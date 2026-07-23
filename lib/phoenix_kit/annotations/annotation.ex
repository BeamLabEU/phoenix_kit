defmodule PhoenixKit.Annotations.Annotation do
  @moduledoc """
  Ecto schema for `phoenix_kit_annotations`.

  Stores user-drawn shapes (rectangle, circle, polygon, freehand) tied to
  a `PhoenixKit.Modules.Storage.File` via `file_uuid`. All geometry is
  in image-pixel coordinates; Fresco's coordinate adapter rescales for
  pan/zoom at render time.

  ## Comment thread linkage

  An annotation's discussion lives in `phoenix_kit_comments` anchored to
  the **file** (`resource_type = "file"`, `resource_uuid = file_uuid`)
  with `metadata.annotation_uuid` carrying the back-reference. This lets
  annotation-rooted comments appear in the file's main comments thread
  alongside non-annotated discussion. There is no `comment_uuid` column
  on annotations — the relationship is one-directional from the comment
  side, and a thread is created lazily when the first comment is posted.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @kinds ~w(rectangle circle polygon freehand callout text dimension line marker image)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          file_uuid: UUIDv7.t(),
          creator_uuid: UUIDv7.t() | nil,
          kind: String.t(),
          geometry: map(),
          style: map() | nil,
          metadata: map() | nil,
          position: integer(),
          title: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_annotations" do
    field :file_uuid, UUIDv7
    field :creator_uuid, UUIDv7
    field :kind, :string
    field :geometry, :map
    field :style, :map
    field :metadata, :map
    field :position, :integer, default: 0
    field :title, :string

    timestamps(type: :utc_datetime)
  end

  @cast_fields ~w(uuid file_uuid creator_uuid kind geometry style metadata position title)a
  @required_fields ~w(file_uuid kind geometry)a

  # Fields the storage adapter is allowed to accept from event payloads.
  # `file_uuid` is set server-side from `target_uuid`, not by the client,
  # so it's excluded here — the adapter's `create/1` puts it on the
  # changeset after the whitelist filter. `creator_uuid` is set server-
  # side from the actor (`adapter`'s `create/1` resolves it from the
  # actor opts), so it's excluded for the same reason — a forged event
  # payload shouldn't be able to claim authorship.
  @adapter_writable_fields @cast_fields -- [:file_uuid, :creator_uuid]

  @doc false
  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:title, max: 200)
    |> foreign_key_constraint(:file_uuid)
    |> foreign_key_constraint(:creator_uuid)
    |> check_constraint(:kind, name: :phoenix_kit_annotations_kind_check)
  end

  @doc "List of allowed kind strings."
  def kinds, do: @kinds

  @doc """
  Fields the Etcher storage adapter is allowed to take from event
  payloads. Single source of truth so the adapter's whitelist doesn't
  drift from the schema's `@cast_fields`. `file_uuid` is excluded —
  the adapter sets it server-side from the Etcher `target_uuid`.
  """
  @spec adapter_writable_fields() :: [atom()]
  def adapter_writable_fields, do: @adapter_writable_fields
end
