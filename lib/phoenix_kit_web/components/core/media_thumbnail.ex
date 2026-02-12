defmodule PhoenixKitWeb.Components.Core.MediaThumbnail do
  @moduledoc """
  Provides a component for resolving and rendering media file thumbnail URLs.

  Handles file type detection (image, video, PDF, document) and selects
  the appropriate thumbnail variant from the file's URL map.
  """

  use Phoenix.Component

  @doc """
  Resolves the best thumbnail URL for a media file.

  Two size modes:
  - `:small` (default) — for selectors and grids: prefers thumbnail/small variants
  - `:medium` — for gallery/preview: prefers medium/thumbnail variants

  ## Attributes

  - `file` - Media file map with `file_type` and `urls` fields (required)
  - `size` - Thumbnail size preference: `:small` or `:medium` (default: `:small`)

  ## Examples

      <.thumbnail_url file={file} :let={url}>
        <img src={url} />
      </.thumbnail_url>

      <.thumbnail_url file={file} size={:medium} :let={url}>
        <img src={url} />
      </.thumbnail_url>
  """
  attr :file, :map, required: true
  attr :size, :atom, default: :small, values: [:small, :medium]
  slot :inner_block, required: true

  def thumbnail_url(assigns) do
    assigns = assign(assigns, :url, resolve_url(assigns.file, assigns.size))

    ~H"""
    {render_slot(@inner_block, @url)}
    """
  end

  @doc """
  Resolves the best thumbnail URL for a media file.

  Returns `nil` when no suitable URL is available.

  ## Examples

      resolve_url(file)           # small thumbnail
      resolve_url(file, :medium)  # medium preview
  """
  @spec resolve_url(map(), :small | :medium) :: String.t() | nil
  def resolve_url(file, size \\ :small)

  def resolve_url(%{file_type: "video", urls: urls}, _size) do
    urls["video_thumbnail"]
  end

  def resolve_url(%{file_type: "image", urls: urls}, :small) do
    urls["thumbnail"] || urls["small"] || urls["original"]
  end

  def resolve_url(%{file_type: "image", urls: urls}, :medium) do
    urls["medium"] || urls["thumbnail"] || urls["original"]
  end

  def resolve_url(%{urls: urls}, :small) do
    urls["thumbnail"] || urls["small"]
  end

  def resolve_url(%{urls: urls}, :medium) do
    urls["thumbnail"] || urls["small"] || urls["medium"]
  end

  def resolve_url(_, _), do: nil
end
