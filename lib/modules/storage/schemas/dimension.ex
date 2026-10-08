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
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  # The sizes every variant set has (V205): a size's name is part of every
  # file URL, and core and modules ask for these by name. The first three
  # of `@aspect_slots` feed grids and justified layouts, so they keep the
  # aspect ratio; only `thumbnail` may be cropped.
  @crop_modes ~w(center focus)
  @shapes ~w(any wide tall)
  @fit_sides ~w(width height)
  @standard_slots ~w(thumbnail small medium large video_thumbnail)
  @aspect_slots ~w(small medium large)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          name: String.t() | nil,
          width: integer() | nil,
          height: integer() | nil,
          quality: integer() | nil,
          format: String.t() | nil,
          applies_to: String.t() | nil,
          enabled: boolean(),
          maintain_aspect_ratio: boolean(),
          crop_mode: String.t(),
          fit_by: String.t(),
          shape: String.t(),
          alternative_formats: [String.t()],
          order: integer(),
          variant_set_uuid: UUIDv7.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_storage_dimensions" do
    field :name, :string
    field :width, :integer
    field :height, :integer
    field :quality, :integer
    field :format, :string
    field :applies_to, :string
    field :enabled, :boolean, default: true
    field :maintain_aspect_ratio, :boolean, default: true
    # How a fixed rendition is cropped (V210): around the middle, or around the
    # photo's focal point. Does nothing for a rendition that keeps proportions.
    field :crop_mode, :string, default: "center"
    # Which side a rendition that keeps proportions fixes (V211): its `width`, or
    # its `height` for a horizontal panorama (the width is then left empty and
    # follows each photo). A fixed box has both sides and ignores it.
    field :fit_by, :string, default: "width"
    # Which pictures the rendition is made for (V214): every one, only the wide
    # ones (panoramas), or only the tall ones. Not part of the spec hash: it
    # decides whether a file gets the size, not what the size looks like.
    field :shape, :string, default: "any"
    field :alternative_formats, {:array, :string}, default: []
    field :order, :integer, default: 0

    # The variant set the size belongs to (V205). The column defaults to the
    # Default set, so a writer that names none lands there;
    # `read_after_writes` reads the default back.
    field :variant_set_uuid, UUIDv7, read_after_writes: true

    timestamps(type: :utc_datetime)
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
      :crop_mode,
      :fit_by,
      :shape,
      :alternative_formats,
      :order
    ])
    |> validate_required([:name, :applies_to])
    |> validate_format(:name, ~r/^[a-z0-9_]+$/,
      message: "must contain only lowercase letters, numbers, and underscores"
    )
    |> validate_length(:name, min: 1, max: 50)
    |> validate_inclusion(:applies_to, ["image", "video", "both"])
    |> validate_inclusion(:crop_mode, @crop_modes)
    |> validate_inclusion(:fit_by, @fit_sides)
    |> validate_inclusion(:shape, @shapes)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:order, greater_than_or_equal_to: 0)
    |> validate_dimension_size()
    |> clear_width_when_height_fixed()
    |> validate_quality()
    |> validate_format()
    |> validate_alternative_formats()
    |> validate_standard_slot()
    |> validate_standard_fit_side()
    |> validate_standard_shape()
    |> unique_constraint(:name, name: :phoenix_kit_storage_dimensions_name_index)
  end

  @doc "How a fixed rendition can be cropped: around the middle, or around the subject."
  def crop_modes, do: @crop_modes

  @doc """
  Whether `dimension` is cropped around the photo's focal point: a fixed box
  (not one that keeps proportions) whose crop mode is `focus`.
  """
  def focus_crop?(%__MODULE__{maintain_aspect_ratio: false, crop_mode: "focus"}), do: true
  def focus_crop?(_dimension), do: false

  @doc "Which pictures a rendition can be made for: every one, the wide ones, the tall ones."
  def shapes, do: @shapes

  @doc "The side a rendition that keeps proportions can fix: its width, or its height."
  def fit_sides, do: @fit_sides

  @doc """
  Whether `dimension` keeps proportions and fixes its **height** (the width
  follows each photo: a horizontal panorama's thumbnail).
  """
  def fixed_height?(%__MODULE__{maintain_aspect_ratio: true, fit_by: "height"}), do: true
  def fixed_height?(_dimension), do: false

  @doc "The sizes every variant set has; they cannot be renamed or deleted."
  def standard_slots, do: @standard_slots

  @doc "The standard sizes that always keep the aspect ratio."
  def aspect_slots, do: @aspect_slots

  @doc "Whether `dimension` is one of the standard sizes."
  def standard_slot?(%__MODULE__{name: name}), do: name in @standard_slots

  # A standard size keeps its name, and small/medium/large keep the aspect
  # ratio, whatever else an admin changes about them.
  defp validate_standard_slot(changeset) do
    old_name = changeset.data.name
    name = get_field(changeset, :name)

    cond do
      old_name in @standard_slots and name != old_name ->
        add_error(changeset, :name, "is a standard size and cannot be renamed")

      # Checked when the size is made, renamed, or its aspect setting is
      # changed: an install whose `small` was cropped before V205 can still
      # switch it off or change its quality without fixing that first.
      name in @aspect_slots and get_field(changeset, :maintain_aspect_ratio) == false and
          (is_nil(changeset.data.uuid) or Map.has_key?(changeset.changes, :name) or
             Map.has_key?(changeset.changes, :maintain_aspect_ratio)) ->
        add_error(
          changeset,
          :maintain_aspect_ratio,
          "must stay on for %{name}: only thumbnail may be cropped",
          name: name
        )

      true ->
        changeset
    end
  end

  # A rendition that keeps proportions and fixes its height has no width: it follows
  # each photo, and a width left over from before would make the rendition look
  # like a width-picked one (`variant_for/2`).
  defp clear_width_when_height_fixed(changeset) do
    if get_field(changeset, :maintain_aspect_ratio) != false and
         get_field(changeset, :fit_by) == "height",
       do: put_change(changeset, :width, nil),
       else: changeset
  end

  # The standard sizes are picked by width (`variant_for/2`, the stand-in of a size
  # not made yet), so they keep fixing it. Checked when the size is made, renamed,
  # or its fixed side is changed.
  defp validate_standard_fit_side(changeset) do
    name = get_field(changeset, :name)

    if name in @standard_slots and get_field(changeset, :fit_by) == "height" and
         (is_nil(changeset.data.uuid) or Map.has_key?(changeset.changes, :name) or
            Map.has_key?(changeset.changes, :fit_by)) do
      add_error(
        changeset,
        :fit_by,
        "must stay on width for %{name}: the standard sizes are picked by width",
        name: name
      )
    else
      changeset
    end
  end

  # The standard sizes are asked for by name for every picture, so none of them
  # may be limited to wide or tall ones.
  defp validate_standard_shape(changeset) do
    name = get_field(changeset, :name)

    if name in @standard_slots and get_field(changeset, :shape) != "any" and
         (is_nil(changeset.data.uuid) or Map.has_key?(changeset.changes, :name) or
            Map.has_key?(changeset.changes, :shape)) do
      add_error(
        changeset,
        :shape,
        "must stay on any picture for %{name}: the standard sizes are made for every one",
        name: name
      )
    else
      changeset
    end
  end

  # Validate dimensions based on maintain_aspect_ratio setting
  defp validate_dimension_size(changeset) do
    width = get_field(changeset, :width)
    height = get_field(changeset, :height)
    maintain_aspect = get_field(changeset, :maintain_aspect_ratio)
    fit_by = get_field(changeset, :fit_by)

    cond do
      # Keeping proportions with a fixed height: the height is the size, and the
      # width is left to follow each photo.
      maintain_aspect != false and fit_by == "height" and is_nil(height) ->
        add_error(changeset, :height, "height is required when the height is fixed")

      maintain_aspect != false and fit_by == "height" ->
        changeset

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
    format = get_field(changeset, :format)

    cond do
      is_nil(quality) ->
        changeset

      # A video rendition that is a still frame (the video thumbnail) outputs an
      # image, so it uses the image quality scale (1-100), whatever its name
      applies_to == "video" and format in ["jpg", "jpeg", "png", "webp", "gif"] ->
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

  # Validate alternative_formats: must be valid image formats, no duplicates, exclude primary format
  defp validate_alternative_formats(changeset) do
    alt_formats = get_field(changeset, :alternative_formats) || []
    primary_format = get_field(changeset, :format)
    applies_to = get_field(changeset, :applies_to)

    # Filter out empty strings (from hidden checkbox input)
    alt_formats = Enum.reject(alt_formats, &(&1 == ""))
    changeset = put_change(changeset, :alternative_formats, alt_formats)

    cond do
      alt_formats == [] ->
        changeset

      applies_to == "video" ->
        add_error(changeset, :alternative_formats, "not supported for video-only dimensions")

      true ->
        valid = get_valid_image_formats()
        invalid = Enum.reject(alt_formats, &(&1 in valid))
        has_primary = primary_format && primary_format in alt_formats
        has_dupes = length(alt_formats) != length(Enum.uniq(alt_formats))

        changeset
        |> then(fn cs ->
          if invalid != [],
            do:
              add_error(cs, :alternative_formats, "invalid formats: #{Enum.join(invalid, ", ")}"),
            else: cs
        end)
        |> then(fn cs ->
          if has_primary,
            do: add_error(cs, :alternative_formats, "must not include the primary format"),
            else: cs
        end)
        |> then(fn cs ->
          if has_dupes,
            do: add_error(cs, :alternative_formats, "must not contain duplicates"),
            else: cs
        end)
    end
  end

  defp get_valid_image_formats, do: ["jpg", "jpeg", "png", "webp", "avif", "gif"]

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
