defmodule PhoenixKitWeb.Components.Core.MessageTagBadge do
  @moduledoc """
  Provides message tag badge component for email system.

  Displays email type tag from message_tags JSONB field.
  Used in email list view to show categorization tags.
  """

  use Phoenix.Component

  @doc """
  Renders a message tag badge if email_type exists in message_tags.

  ## Attributes
  - `message_tags` - JSONB map with email metadata (required)
  - `class` - Additional CSS classes (default: "badge-secondary badge-xs")

  ## Examples

      <.message_tag_badge message_tags={%{"email_type" => "marketing"}} />
      <.message_tag_badge message_tags={log.message_tags} class="badge-primary badge-sm" />
      <.message_tag_badge message_tags={nil} />  <%!-- No badge rendered --%>
  """
  attr :message_tags, :map, required: true
  attr :class, :string, default: "badge-secondary badge-xs"

  def message_tag_badge(assigns) do
    ~H"""
    <%= if get_tag(@message_tags) do %>
      <div class={"badge #{@class}"}>
        {get_tag(@message_tags)}
      </div>
    <% end %>
    """
  end

  # Private helper functions

  # Extract email_type from message_tags
  defp get_tag(message_tags) when is_map(message_tags) do
    Map.get(message_tags, "email_type")
  end

  defp get_tag(_), do: nil
end
