defmodule PhoenixKitWeb.Components.Blogging.Image do
  @moduledoc """
  Image component with lazy loading and responsive sizing.

  Supports both direct URLs and PhoenixKit Storage file IDs with automatic variant selection.

  ## Usage

  ### With direct URL:

      <Image src="/path/to/image.jpg" alt="Description" />

  ### With PhoenixKit Storage file ID:

      <Image file_id="018e3c4a-9f6b-7890-abcd-ef1234567890" alt="Description" />
      <Image file_id="018e3c4a-9f6b-7890-abcd-ef1234567890" file_variant="thumbnail" alt="Description" />

  ## Attributes

  - `src` - Direct image URL (takes precedence over file_id)
  - `file_id` - PhoenixKit Storage file ID
  - `file_variant` - Storage variant to use (default: "original")
    - Images: "original", "thumbnail", "small", "medium", "large"
  - `alt` - Alt text for accessibility (required)
  - `class` - Additional CSS classes (optional)
  """
  use Phoenix.Component

  attr :attributes, :map, default: %{}
  attr :variant, :string, default: "default"
  attr :content, :string, default: nil

  def render(assigns) do
    # Extract attributes
    src = Map.get(assigns.attributes, "src")
    file_id = Map.get(assigns.attributes, "file_id")
    file_variant = Map.get(assigns.attributes, "file_variant", "original")
    alt = Map.get(assigns.attributes, "alt", "")
    custom_class = Map.get(assigns.attributes, "class", "")

    # Determine image source
    image_src =
      cond do
        # Direct src takes precedence
        src && src != "" ->
          src

        # Use file_id from PhoenixKit Storage
        file_id && file_id != "" ->
          get_file_url(file_id, file_variant)

        # No source provided
        true ->
          nil
      end

    assigns =
      assigns
      |> assign(:src, image_src)
      |> assign(:alt, alt)
      |> assign(:custom_class, custom_class)

    ~H"""
    <%= if @src do %>
      <img
        src={@src}
        alt={@alt}
        loading="lazy"
        class={["h-auto rounded-lg shadow-lg", @custom_class]}
      />
    <% else %>
      <%!-- Fallback for missing image --%>
      <div class="w-full h-48 bg-base-200 rounded-lg flex items-center justify-center">
        <span class="text-base-content/50">Image not available</span>
      </div>
    <% end %>
    """
  end

  # Helper function to get file URL from Storage
  defp get_file_url(file_id, variant) do
    case PhoenixKit.Storage.get_public_url_by_id(file_id, variant) do
      nil ->
        # Try without variant (fallback to original)
        PhoenixKit.Storage.get_public_url_by_id(file_id)

      url ->
        url
    end
  rescue
    _ ->
      # Gracefully handle missing repo or file
      nil
  end
end
