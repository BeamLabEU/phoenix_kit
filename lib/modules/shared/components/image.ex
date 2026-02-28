defmodule PhoenixKit.Modules.Shared.Components.Image do
  @moduledoc """
  Image component with lazy loading and responsive sizing.

  Supports both direct URLs and PhoenixKit Storage file UUIDs with automatic variant selection.

  ## Usage

  ### With direct URL:

      <Image src="/path/to/image.jpg" alt="Description" />

  ### With PhoenixKit Storage file UUID:

      <Image file_uuid="018e3c4a-9f6b-7890-abcd-ef1234567890" alt="Description" />
      <Image file_uuid="018e3c4a-9f6b-7890-abcd-ef1234567890" file_variant="thumbnail" alt="Description" />

  ## Attributes

  - `src` - Direct image URL (takes precedence over file_uuid)
  - `file_uuid` - PhoenixKit Storage file UUID
  - `file_variant` - Storage variant to use (default: "original")
    - Images: "original", "thumbnail", "small", "medium", "large"
  - `alt` - Alt text for accessibility (required)
  - `class` - Additional CSS classes (optional)
  """
  use Phoenix.Component

  alias PhoenixKit.Modules.Storage

  attr :attributes, :map, default: %{}
  attr :variant, :string, default: "default"
  attr :content, :string, default: nil

  def render(assigns) do
    # Extract attributes
    src = Map.get(assigns.attributes, "src")
    file_uuid = Map.get(assigns.attributes, "file_uuid")
    file_variant = Map.get(assigns.attributes, "file_variant", "original")
    alt = Map.get(assigns.attributes, "alt", "")
    custom_class = Map.get(assigns.attributes, "class", "")

    # Determine image source
    image_src =
      cond do
        # Direct src takes precedence
        src && src != "" ->
          src

        # Use file_uuid from PhoenixKit Storage
        file_uuid && file_uuid != "" ->
          get_file_url(file_uuid, file_variant)

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
  defp get_file_url(file_uuid, variant) do
    case Storage.get_public_url_by_uuid(file_uuid, variant) do
      nil ->
        # Try without variant (fallback to original)
        Storage.get_public_url_by_uuid(file_uuid)

      url ->
        url
    end
  rescue
    _ ->
      # Gracefully handle missing repo or file
      nil
  end
end
