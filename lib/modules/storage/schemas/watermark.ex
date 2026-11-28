defmodule PhoenixKit.Modules.Storage.Watermark do
  @moduledoc """
  The watermark of a variant set (V237), kept as one JSON object in
  `phoenix_kit_variant_sets.watermark` and loaded as this struct. A set with
  none (NULL, every set before V237) watermarks nothing.

  The watermark is put on the renditions named in `dimensions` only, when
  they are made (`PhoenixKit.Modules.Storage.WatermarkRenderer`). The original
  is never watermarked, and a size left out (a thumbnail) stays clean. Only
  still image renditions of an image get it: a video, a PDF's thumbnail and an
  animation that stays animated do not.

    * `enabled` — whether the set watermarks at all.
    * `mode` — `"strip"`, a bar along the bottom with the text and/or logo, or
      `"corner"`, a mark (logo and/or text) in one corner.
    * `text` — at most #{200} characters; `{site_url}` is replaced by the site's
      address without its scheme (`example.com`) and `{site_name}` by the
      project title. Blank for a logo alone.
    * `logo_file_uuid` — a stored image (`Storage.File`), drawn from its
      original. None for text alone.
    * `dimensions` — the names of the set's sizes that get the watermark.

  A strip:

    * `strip_position` — `"below"` adds the bar under the picture, so nothing
      of it is covered and the rendition is taller by the bar (Ratelia's
      strip); `"over"` lays it over the bottom of the picture, which keeps the
      size.
    * `strip_height_percent` — the bar's height as a share of the picture's
      width (2-20), at least #{24} px.
    * `background_color` / `background_opacity` — the bar's colour (`#rrggbb`)
      and opacity (0-100). A bar `below` is always opaque.
    * `text_color` — `#rrggbb`, for the strip's text and a corner's.

  A corner mark:

    * `corner` — `"bottom_right"`, `"bottom_left"`, `"top_right"` or `"top_left"`.
    * `mark_size_percent` — the mark's width as a share of the picture's width
      (5-50).
    * `opacity` — the mark's opacity (10-100).
    * `margin_percent` — its distance from the edges, a share of the picture's
      width (0-20).

  Every field but `enabled` and `dimensions` changes the pixels of a
  watermarked size and is part of its spec hash (`hash_text/1`), so a change
  remakes exactly the sizes that carry it, through the reconciler.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @modes ~w(strip corner)
  @strip_positions ~w(below over)
  @corners ~w(bottom_right bottom_left top_right top_left)
  @color ~r/\A#[0-9a-fA-F]{6}\z/
  @max_text 200

  @primary_key false
  embedded_schema do
    field :enabled, :boolean, default: false
    field :mode, :string, default: "strip"
    field :text, :string, default: "{site_url}"
    field :logo_file_uuid, Ecto.UUID
    field :dimensions, {:array, :string}, default: ["large"]
    field :strip_position, :string, default: "below"
    field :strip_height_percent, :integer, default: 6
    field :background_color, :string, default: "#ffffff"
    field :background_opacity, :integer, default: 100
    field :text_color, :string, default: "#333333"
    field :corner, :string, default: "bottom_right"
    field :mark_size_percent, :integer, default: 20
    field :opacity, :integer, default: 70
    field :margin_percent, :integer, default: 3

    # The logo file's content checksum (`Storage.File.file_checksum`), put here
    # by `VariantGenerator` when it reads the set for a file; never stored. It is
    # part of the spec hash, so a logo whose pixels change under the same file
    # (an image edit) reaches the renditions on the next check of the set's files.
    field :logo_checksum, :string, virtual: true
  end

  @type t :: %__MODULE__{}

  @fields [
    :enabled,
    :mode,
    :text,
    :logo_file_uuid,
    :dimensions,
    :strip_position,
    :strip_height_percent,
    :background_color,
    :background_opacity,
    :text_color,
    :corner,
    :mark_size_percent,
    :opacity,
    :margin_percent
  ]

  # What changes the pixels: everything but whether it is on and where.
  @pixel_fields @fields -- [:enabled, :dimensions]

  @doc "The modes."
  def modes, do: @modes

  @doc "The strip positions."
  def strip_positions, do: @strip_positions

  @doc "The corners."
  def corners, do: @corners

  @doc "The longest text."
  def max_text, do: @max_text

  @doc false
  def changeset(watermark, attrs) do
    watermark
    |> cast(normalize(attrs), @fields, empty_values: [])
    |> update_change(:text, &clean_text/1)
    |> update_change(:dimensions, &clean_names/1)
    |> validate_required([:mode, :strip_position, :corner])
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:strip_position, @strip_positions)
    |> validate_inclusion(:corner, @corners)
    |> validate_length(:text, max: @max_text)
    |> validate_format(:background_color, @color, message: "must be a colour like #ffffff")
    |> validate_format(:text_color, @color, message: "must be a colour like #333333")
    |> validate_number(:strip_height_percent,
      greater_than_or_equal_to: 2,
      less_than_or_equal_to: 20
    )
    |> validate_number(:background_opacity,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 100
    )
    |> validate_number(:mark_size_percent, greater_than_or_equal_to: 5, less_than_or_equal_to: 50)
    |> validate_number(:opacity, greater_than_or_equal_to: 10, less_than_or_equal_to: 100)
    |> validate_number(:margin_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 20)
    |> validate_something_to_draw()
    |> validate_some_size()
  end

  # A form posts a blank logo as "" and the sizes as a list with a hidden ""
  # (so that unticking every box still sends the key).
  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, ""} when k in [:logo_file_uuid, "logo_file_uuid"] -> {k, nil}
      {k, v} when k in [:text, "text"] and is_nil(v) -> {k, ""}
      pair -> pair
    end)
  end

  defp normalize(attrs), do: attrs

  # Control characters (a newline included) are dropped: the text is one line.
  defp clean_text(nil), do: ""
  defp clean_text(text), do: text |> String.replace(~r/[[:cntrl:]]/u, "") |> String.trim()

  defp clean_names(names) do
    names |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp validate_something_to_draw(changeset) do
    if get_field(changeset, :enabled) and blank?(get_field(changeset, :text)) and
         is_nil(get_field(changeset, :logo_file_uuid)) do
      add_error(changeset, :text, "give a text or a logo")
    else
      changeset
    end
  end

  defp validate_some_size(changeset) do
    if get_field(changeset, :enabled) and get_field(changeset, :dimensions) in [nil, []],
      do: add_error(changeset, :dimensions, "choose at least one rendition"),
      else: changeset
  end

  defp blank?(text), do: text in [nil, ""]

  @doc """
  The watermark `dimension` (a size, or its name) gets from `watermark`: the
  watermark itself when it is on and names the size, else nil.
  """
  @spec for_size(t() | nil, map() | String.t()) :: t() | nil
  def for_size(%__MODULE__{enabled: true, dimensions: names} = watermark, name)
      when is_binary(name),
      do: if(name in (names || []), do: watermark)

  def for_size(%__MODULE__{} = watermark, %{name: name}), do: for_size(watermark, name)
  def for_size(_watermark, _size), do: nil

  @doc """
  The text of what changes the pixels, in a fixed order: part of the spec hash
  of a watermarked size (`VariantSets.spec_hash/2`). With a logo, its content
  checksum (`logo_checksum`) counts too, not only its file uuid. The text is hashed as
  written, so a new site address reaches the renditions on the next check of
  the set's files (`VariantSets.check_files/2`), not by itself.
  """
  @spec hash_text(t()) :: String.t()
  def hash_text(%__MODULE__{} = watermark) do
    Enum.map_join(@pixel_fields, "|", fn field ->
      "#{field}=#{Map.get(watermark, field)}"
    end) <> logo_part(watermark)
  end

  # The logo's content (`logo_checksum`), when there is a logo: its file uuid alone
  # would not change when its pixels do.
  defp logo_part(%__MODULE__{logo_file_uuid: nil}), do: ""
  defp logo_part(%__MODULE__{logo_checksum: checksum}), do: "|logo_checksum=#{checksum}"

  @doc """
  The text to draw: `{site_url}` and `{site_name}` filled in, control
  characters dropped, cut to #{@max_text} characters.
  """
  @spec render_text(t()) :: String.t()
  def render_text(%__MODULE__{text: text}) when text in [nil, ""], do: ""

  def render_text(%__MODULE__{text: text}) do
    text
    |> replace_placeholder("{site_url}", &site_host/0)
    |> replace_placeholder("{site_name}", &site_name/0)
    |> clean_text()
    |> String.slice(0, @max_text)
  end

  defp replace_placeholder(text, placeholder, value) do
    if String.contains?(text, placeholder),
      do: String.replace(text, placeholder, value.()),
      else: text
  end

  defp site_host do
    Routes.base_url()
    |> to_string()
    |> String.replace(~r{\Ahttps?://}i, "")
    |> String.trim_trailing("/")
  rescue
    _ -> ""
  end

  defp site_name do
    to_string(Settings.get_project_title())
  rescue
    _ -> ""
  end
end
