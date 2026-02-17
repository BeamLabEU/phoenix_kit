defmodule PhoenixKit.Modules.Entities.Web.Hooks do
  @moduledoc """
  LiveView hooks for entity module pages.

  Provides common setup and subscriptions for all entity-related LiveViews.
  """

  import Phoenix.LiveView
  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Modules.Entities.Events
  alias PhoenixKit.Users.Auth.Scope

  @doc """
  Subscribes to entity events and tracks user presence when the LiveView is connected.

  Add this to your entity LiveView with:

      on_mount PhoenixKit.Modules.Entities.Web.Hooks

  This automatically:
  - Subscribes to entity creation, update, and deletion events
  - Tracks authenticated user presence for dashboard statistics
  """
  def on_mount(:default, _params, session, socket) do
    if connected?(socket) do
      Events.subscribe_to_entities()
      track_page_visit(socket, session)
    end

    {:cont, socket}
  end

  defp track_page_visit(socket, session) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if scope && Scope.authenticated?(scope) do
      user = %{
        uuid: scope.user.uuid,
        id: Scope.user_id(scope),
        email: Scope.user_email(scope)
      }

      session_id = session["live_socket_id"] || generate_session_id()

      Presence.track_user(user, %{
        connected_at: DateTime.utc_now(),
        session_id: session_id,
        current_page: get_current_page(socket),
        ip_address: extract_ip(socket),
        user_agent: get_connect_info(socket, :user_agent)
      })
    end
  end

  defp get_current_page(socket) do
    # Try to get from socket assigns, fallback to generic entities page
    socket.assigns[:current_path] || "/admin/entities"
  end

  defp extract_ip(socket) do
    case get_connect_info(socket, :peer_data) do
      %{address: {a, b, c, d}} -> "#{a}.#{b}.#{c}.#{d}"
      %{address: address} -> to_string(address)
      _ -> "unknown"
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end
end
