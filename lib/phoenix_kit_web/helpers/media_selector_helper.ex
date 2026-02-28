defmodule PhoenixKitWeb.Helpers.MediaSelectorHelper do
  @moduledoc """
  Helper functions for integrating the media selector component.

  Provides convenience functions to generate media selector URLs,
  parse returned selections, and handle media selector integration
  from any LiveView or controller.

  ## Examples

      # In a LiveView template
      <.link navigate={MediaSelectorHelper.media_selector_url(@current_path, mode: :single)}>
        Select Featured Image
      </.link>

      # In handle_params to receive selection
      def handle_params(params, _uri, socket) do
        case MediaSelectorHelper.parse_selected_media(params) do
          {:ok, [file_id]} ->
            socket
            |> assign(:featured_image_uuid, file_id)
            |> put_flash(:info, "Image selected!")

          {:ok, file_ids} ->
            socket
            |> assign(:gallery_ids, file_ids)
            |> put_flash(:info, "\#{length(file_ids)} images selected!")

          :none ->
            socket
        end
      end
  """

  alias PhoenixKit.Utils.Routes

  @doc """
  Generates a URL to the media selector page.

  ## Parameters

    - `return_to` - The URL to return to after selection (required)
    - `opts` - Keyword list of options:
      - `:mode` - Selection mode: `:single` or `:multiple` (default: `:single`)
      - `:filter` - File type filter: `:image`, `:video`, or `:all` (default: `:all`)
      - `:selected` - List of pre-selected file IDs (optional)

  ## Examples

      # Single image selection
      media_selector_url("/admin/blog/edit", mode: :single, filter: :image)
      #=> "/admin/media/selector?return_to=%2Fadmin%2Fblog%2Fedit&mode=single&filter=image"

      # Multiple selection with pre-selected files
      media_selector_url("/admin/gallery", mode: :multiple, selected: ["id1", "id2"])
      #=> "/admin/media/selector?return_to=%2Fadmin%2Fgallery&mode=multiple&selected=id1%2Cid2"

  """
  def media_selector_url(return_to, opts \\ []) do
    mode = Keyword.get(opts, :mode, :single)
    filter = Keyword.get(opts, :filter, :all)
    selected = Keyword.get(opts, :selected, [])

    base_url = Routes.path("/admin/media/selector")
    params = build_query_params(return_to, mode, filter, selected)

    "#{base_url}?#{params}"
  end

  @doc """
  Parses the selected media from LiveView params.

  Returns `{:ok, [file_ids]}` if media was selected, or `:none` if no selection.

  ## Examples

      parse_selected_media(%{"selected_media" => "id1,id2,id3"})
      #=> {:ok, ["id1", "id2", "id3"]}

      parse_selected_media(%{"selected_media" => "single-id"})
      #=> {:ok, ["single-id"]}

      parse_selected_media(%{})
      #=> :none

  """
  def parse_selected_media(%{"selected_media" => selected_media})
      when is_binary(selected_media) do
    file_ids =
      selected_media
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case file_ids do
      [] -> :none
      ids -> {:ok, ids}
    end
  end

  def parse_selected_media(_params), do: :none

  @doc """
  Extracts the first file ID from selected media.

  Useful for single-selection scenarios where you only need one file ID.

  ## Examples

      get_first_selected(%{"selected_media" => "id1,id2,id3"})
      #=> {:ok, "id1"}

      get_first_selected(%{"selected_media" => "single-id"})
      #=> {:ok, "single-id"}

      get_first_selected(%{})
      #=> :none

  """
  def get_first_selected(params) do
    case parse_selected_media(params) do
      {:ok, [first_id | _]} -> {:ok, first_id}
      :none -> :none
    end
  end

  # Private Functions

  defp build_query_params(return_to, mode, filter, selected) do
    params = [
      {"return_to", return_to},
      {"mode", to_string(mode)},
      {"filter", to_string(filter)}
    ]

    params =
      if Enum.any?(selected) do
        selected_string = Enum.join(selected, ",")
        params ++ [{"selected", selected_string}]
      else
        params
      end

    URI.encode_query(params)
  end
end
