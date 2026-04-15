defmodule PhoenixKit.Modules.Storage.VariantNaming do
  @moduledoc """
  Utilities for naming and parsing storage variant names.

  Variant names follow the convention:
  - Primary: `"medium"` (dimension name only)
  - Alternative format: `"medium_webp"` (dimension name + format suffix)

  The parser splits on the last underscore and checks whether the suffix
  is a known image format. If it is, the variant is an alternative format.
  """

  @known_formats ~w(jpg jpeg png webp avif gif)

  @doc """
  Parses a variant name into `{base_dimension, format}`.

  ## Examples

      iex> parse_variant_name("medium")
      {"medium", nil}

      iex> parse_variant_name("medium_webp")
      {"medium", "webp"}

      iex> parse_variant_name("video_thumbnail")
      {"video_thumbnail", nil}

      iex> parse_variant_name("thumbnail_avif")
      {"thumbnail", "avif"}
  """
  def parse_variant_name(variant_name) when is_binary(variant_name) do
    case String.split(variant_name, "_") do
      [single] ->
        {single, nil}

      parts ->
        suffix = List.last(parts)

        if suffix in @known_formats do
          base = parts |> Enum.drop(-1) |> Enum.join("_")
          {base, suffix}
        else
          {variant_name, nil}
        end
    end
  end

  @doc """
  Builds a variant name from a base dimension name and format.

  ## Examples

      iex> variant_name("medium", nil)
      "medium"

      iex> variant_name("medium", "webp")
      "medium_webp"
  """
  def variant_name(base, nil), do: base
  def variant_name(base, format), do: "#{base}_#{format}"

  @doc """
  Returns the list of known image format suffixes.
  """
  def known_formats, do: @known_formats

  @doc """
  Returns the MIME type for a format string.

  ## Examples

      iex> mime_type_for_format("webp")
      "image/webp"

      iex> mime_type_for_format("avif")
      "image/avif"
  """
  def mime_type_for_format("jpg"), do: "image/jpeg"
  def mime_type_for_format("jpeg"), do: "image/jpeg"
  def mime_type_for_format("png"), do: "image/png"
  def mime_type_for_format("webp"), do: "image/webp"
  def mime_type_for_format("avif"), do: "image/avif"
  def mime_type_for_format("gif"), do: "image/gif"
  def mime_type_for_format(_), do: "application/octet-stream"
end
