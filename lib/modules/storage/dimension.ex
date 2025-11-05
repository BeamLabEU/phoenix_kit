defmodule PhoenixKit.Storage.Dimension do
  @moduledoc """
  Schema for admin-configurable dimension presets.

  Dimensions define the target sizes for automatic variant generation.
  The migration seeds 8 default dimensions:
  - 4 image dimensions (thumbnail, small, medium, large)
  - 3 video quality variants (360p, 720p, 1080p)
  - 1 video thumbnail

  Admins can add custom dimensions, disable defaults, or modify settings.

  ## Fields

  - `name` - Unique name for the dimension
  - `width` - Target width in pixels (nullable for aspect ratio)
  - `height` - Target height in pixels (nullable for aspect ratio)
  - `quality` - Compression quality 1-100 for images, CRF 0-51 for video
  - `format` - Target format (jpg, png, webp, mp4, null = keep original)
  - `applies_to` - "image", "video", or "both"
  - `enabled` - Whether this dimension is active
  - `order` - Display order in admin interface

  ## Examples

      # Image dimension
      %Dimension{
        name: "thumbnail",
        width: 150,
        height: 150,
        quality: 85,
        format: "jpg",
        applies_to: "image",
        enabled: true,
        order: 1
      }

      # Video quality variant
      %Dimension{
        name: "720p",
        width: 1280,
        height: 720,
        quality: 28,  # CRF value for FFmpeg
        format: "mp4",
        applies_to: "video",
        enabled: true,
        order: 6
      }

      # Custom dimension (admin-created)
      %Dimension{
        name: "square_small",
        width: 500,
        height: 500,
        quality: 90,
        format: "webp",
        applies_to: "image",
        enabled: true,
        order: 10
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_storage_dimensions" do
    field :name, :string
    field :width, :integer
    field :height, :integer
    field :quality, :integer, default: 85
    field :format, :string
    field :applies_to, :string
    field :enabled, :boolean, default: true
    field :order, :integer, default: 0

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating or updating a dimension.

  ## Required Fields

  - `name`
  - `applies_to` (must be: "image", "video", "both")

  ## Validation Rules

  - Name must be unique
  - Applies_to must be valid
  - Quality must be 1-100 for images, 0-51 for video
  - Width/height must be positive (if provided)
  - Order must be >= 0
  """
  def changeset(dimension, attrs) do
    dimension
    |> cast(attrs, [:name, :width, :height, :quality, :format, :applies_to, :enabled, :order])
    |> validate_required([:name, :applies_to])
    |> validate_inclusion(:applies_to, ["image", "video", "both"])
    |> validate_quality()
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:order, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
  end

  defp validate_quality(changeset) do
    applies_to = get_field(changeset, :applies_to)
    quality = get_field(changeset, :quality)

    cond do
      is_nil(quality) ->
        changeset

      applies_to in ["image", "both"] ->
        validate_number(changeset, :quality, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)

      applies_to == "video" ->
        validate_number(changeset, :quality, greater_than_or_equal_to: 0, less_than_or_equal_to: 51)

      true ->
        changeset
    end
  end

  @doc """
  Returns whether this dimension applies to images.
  """
  def for_images?(%__MODULE__{applies_to: applies_to}) when applies_to in ["image", "both"],
    do: true

  def for_images?(_), do: false

  @doc """
  Returns whether this dimension applies to videos.
  """
  def for_videos?(%__MODULE__{applies_to: applies_to}) when applies_to in ["video", "both"],
    do: true

  def for_videos?(_), do: false

  @doc """
  Returns whether this dimension is enabled.
  """
  def enabled?(%__MODULE__{enabled: true}), do: true
  def enabled?(_), do: false
end
