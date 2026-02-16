defmodule PhoenixKit.Modules.Storage.Dimension do
  @moduledoc """
  Schema for dimension presets for automatic file variant generation.

  Dimensions define target sizes and quality settings for automatically
  generating different versions of uploaded images and videos.

  ## Fields

  - `name` - Unique name for this dimension (e.g., "thumbnail", "medium")
  - `width` - Target width in pixels (nullable = maintain aspect ratio)
  - `height` - Target height in pixels (nullable = maintain aspect ratio)
  - `quality` - Quality setting (1-100 for images, CRF 0-51 for videos)
  - `format` - Output format override (nullable = preserve original)
  - `applies_to` - What this dimension applies to: "image", "video", or "both"
  - `enabled` - Whether this dimension is active
  - `order` - Display order in admin interface

  ## Quality Settings

  ### Images (JPEG, WebP, PNG)
  - Range: 1-100
  - 85 = Good quality (default)
  - 95 = High quality
  - 70 = Medium quality

  ### Videos (MP4, WebM)
  - Range: 0-51 (CRF - Constant Rate Factor)
  - Lower = Higher quality
  - 23 = Good quality (default)
  - 18 = High quality
  - 28 = Medium quality

  ## Examples

      # Image thumbnail
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

      # Video 720p variant
      %Dimension{
        name: "720p",
        width: 1280,
        height: 720,
        quality: 23,
        format: "mp4",
        applies_to: "video",
        enabled: true,
        order: 2
      }

      # Responsive image (maintain aspect ratio)
      %Dimension{
        name: "large",
        width: 1920,
        height: nil,  # Maintain aspect ratio
        quality: 85,
        format: nil,  # Preserve original
        applies_to: "image",
        enabled: true,
        order: 3
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true, source: :id}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_storage_dimensions" do
    field :name, :string
    field :width, :integer
    field :height, :integer
    field :quality, :integer
    field :format, :string
    field :applies_to, :string
    field :enabled, :boolean, default: true
    field :maintain_aspect_ratio, :boolean, default: true
    field :order, :integer, default: 0

    timestamps(type: :naive_datetime)
  end

  @doc """
  Changeset for creating or updating a dimension.

  ## Required Fields

  - `name`
  - `applies_to`
  - `width` - Required when `maintain_aspect_ratio` is true or false

  ## Optional Fields

  - `height` - Required when `maintain_aspect_ratio` is false (fixed dimensions)
  - `maintain_aspect_ratio` - Whether to preserve aspect ratio (default: true)

  ## Validation Rules

  - Name must be unique
  - Width must be specified (always required)
  - Height must be specified when `maintain_aspect_ratio` is false
  - Width and height must be positive integers
  - Quality must be between 1-100 for images or 0-51 for videos
  - Applies to must be one of: "image", "video", "both"
  - Format must be valid if specified
  - Order must be >= 0
  """
  def changeset(dimension, attrs) do
    dimension
    |> cast(attrs, [
      :name,
      :width,
      :height,
      :quality,
      :format,
      :applies_to,
      :enabled,
      :maintain_aspect_ratio,
      :order
    ])
    |> validate_required([:name, :applies_to])
    |> validate_format(:name, ~r/^[a-z0-9_]+$/,
      message: "must contain only lowercase letters, numbers, and underscores"
    )
    |> validate_length(:name, min: 1, max: 50)
    |> validate_inclusion(:applies_to, ["image", "video", "both"])
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:order, greater_than_or_equal_to: 0)
    |> validate_dimension_size()
    |> validate_quality()
    |> validate_format()
    |> unique_constraint(:name, name: :phoenix_kit_storage_dimensions_name_index)
  end

  # Validate dimensions based on maintain_aspect_ratio setting
  defp validate_dimension_size(changeset) do
    width = get_field(changeset, :width)
    height = get_field(changeset, :height)
    maintain_aspect = get_field(changeset, :maintain_aspect_ratio)

    cond do
      is_nil(width) ->
        add_error(changeset, :width, "width is required")

      maintain_aspect == false && is_nil(height) ->
        add_error(changeset, :height, "height is required when not maintaining aspect ratio")

      true ->
        changeset
    end
  end

  # Validate quality based on file type
  defp validate_quality(changeset) do
    quality = get_field(changeset, :quality)
    applies_to = get_field(changeset, :applies_to)
    name = get_field(changeset, :name)
    format = get_field(changeset, :format)

    cond do
      is_nil(quality) ->
        changeset

      # video_thumbnail outputs images, so it uses image quality scale (1-100)
      name == "video_thumbnail" and format in ["jpg", "jpeg", "png", "webp", "gif"] ->
        validate_number(changeset, :quality,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: 100
        )

      applies_to in ["image", "both"] ->
        validate_number(changeset, :quality,
          greater_than_or_equal_to: 1,
          less_than_or_equal_to: 100
        )

      applies_to == "video" ->
        validate_number(changeset, :quality,
          greater_than_or_equal_to: 0,
          less_than_or_equal_to: 51
        )

      true ->
        changeset
    end
  end

  # Validate format is supported
  defp validate_format(changeset) do
    format = get_field(changeset, :format)
    applies_to = get_field(changeset, :applies_to)

    if is_nil(format) do
      changeset
    else
      valid_formats = get_valid_formats(applies_to)

      if format in valid_formats do
        changeset
      else
        add_error(changeset, :format, "must be one of: #{Enum.join(valid_formats, ", ")}")
      end
    end
  end

  defp get_valid_formats("image"), do: ["jpg", "jpeg", "png", "webp", "gif"]
  # Videos can output video formats, but video_thumbnail outputs JPG images
  defp get_valid_formats("video"), do: ["mp4", "webm", "avi", "mov", "jpg", "jpeg", "png", "webp"]

  defp get_valid_formats("both"),
    do: ["jpg", "jpeg", "png", "webp", "gif", "mp4", "webm", "avi", "mov"]

  @doc """
  Returns whether this dimension applies to images.
  """
  def applies_to_images?(%__MODULE__{applies_to: applies_to})
      when applies_to in ["image", "both"],
      do: true

  def applies_to_images?(_), do: false

  @doc """
  Returns whether this dimension applies to videos.
  """
  def applies_to_videos?(%__MODULE__{applies_to: applies_to})
      when applies_to in ["video", "both"],
      do: true

  def applies_to_videos?(_), do: false

  @doc """
  Returns whether this dimension preserves aspect ratio.
  """
  def preserve_aspect_ratio?(%__MODULE__{maintain_aspect_ratio: maintain_aspect}) do
    maintain_aspect == true
  end

  @doc """
  Returns a human-readable description of this dimension.
  """
  def description(%__MODULE__{
        name: name,
        width: width,
        height: height,
        format: format,
        maintain_aspect_ratio: maintain_aspect
      }) do
    size_desc =
      cond do
        maintain_aspect && width -> "#{width}px wide (aspect ratio maintained)"
        width && height -> "#{width}x#{height}"
        width -> "#{width}px wide"
        height -> "#{height}px tall"
        true -> "auto"
      end

    format_desc = if format, do: " (#{format})", else: ""
    "#{name}: #{size_desc}#{format_desc}"
  end
end
