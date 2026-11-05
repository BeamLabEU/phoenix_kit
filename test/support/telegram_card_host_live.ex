defmodule PhoenixKitWeb.Test.TelegramCardHostLive do
  @moduledoc """
  Stand-in for a host page that embeds `TelegramNotificationsCard`, backing
  test/integration/phoenix_kit_web/live/users/telegram_notifications_card_test.exs.

  The session decides what the host passes: `"user_uuid"` (required) and `"impersonated"`
  (absent leaves that assign out). Not routed; rendered with
  `Phoenix.LiveViewTest.live_isolated/3`.
  """
  use Phoenix.LiveView

  alias PhoenixKit.Users.Auth

  @impl true
  def mount(_params, session, socket) do
    extra =
      if Map.has_key?(session, "impersonated"),
        do: %{impersonated: session["impersonated"]},
        else: %{}

    {:ok,
     socket
     |> assign(:user, Auth.get_user(session["user_uuid"]))
     |> assign(:extra, extra), layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={PhoenixKitWeb.Live.Components.TelegramNotificationsCard}
      id="telegram-notifications-card"
      user={@user}
      {@extra}
    />
    """
  end
end
