defmodule PhoenixKitWeb.Test.UserSettingsApiKeysHostLive do
  @moduledoc """
  Stand-in for a host page that embeds `UserSettings` with the `:api_keys` section, backing
  test/phoenix_kit_web/live/components/user_settings_api_keys_test.exs.

  The session decides what the host passes: `"user_uuid"` (required); `"scope"` (`false`
  leaves the `scope` assign out); `"impersonated"` (absent leaves that assign out); and
  `"scope_of"` (the uuid of another person whose scope is handed in).
  Not routed; rendered with `Phoenix.LiveViewTest.live_isolated/3`.
  """
  use Phoenix.LiveView

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @impl true
  def mount(_params, session, socket) do
    user = Auth.get_user(session["user_uuid"])

    extra =
      %{}
      |> put_unless(session["scope"] == false, :scope, scope_for(session, user))
      |> put_unless(
        not Map.has_key?(session, "impersonated"),
        :impersonated,
        session["impersonated"]
      )

    {:ok, socket |> assign(:user, user) |> assign(:extra, extra), layout: false}
  end

  # `"scope_of"` hands the scope of another person, as a page showing someone else's profile.
  defp scope_for(%{"scope_of" => uuid}, _user), do: Scope.for_user(Auth.get_user(uuid))
  defp scope_for(_session, user), do: Scope.for_user(user)

  defp put_unless(map, true, _key, _value), do: map
  defp put_unless(map, false, key, value), do: Map.put(map, key, value)

  @impl true
  def handle_event("clear_scope", _params, socket) do
    {:noreply, assign(socket, :extra, Map.put(socket.assigns.extra, :scope, nil))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={PhoenixKitWeb.Live.Components.UserSettings}
      id="user-settings"
      user={@user}
      sections={[:api_keys]}
      {@extra}
    />
    """
  end
end
