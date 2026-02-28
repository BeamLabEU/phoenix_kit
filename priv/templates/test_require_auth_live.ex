defmodule PhoenixKitWeb.TestRequireAuthLive do
  @moduledoc """
  Test component for phoenix_kit_mount_current_scope authentication level.
  This page shows current scope information without requiring authentication.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope

  def render(assigns) do
    ~H"""
    <div class="hero py-8 min-h-[80vh] bg-info">
      <div class="hero-content text-center">
        <div class="max-w-md">
          <h1 class="text-5xl font-bold text-info-content">phoenix_kit_mount_current_scope</h1>
          <div class="py-6 text-info-content">
            <p class="mb-4">
              This page uses PhoenixKit <code>phoenix_kit_mount_current_scope</code>.
              Modern scope system that mounts current scope without requiring authentication.
            </p>

            <div class={"alert #{if Scope.authenticated?(@phoenix_kit_current_scope), do: "alert-success", else: "alert-warning"}"}>
              <div>
                <h3 class="font-bold">
                  {if Scope.authenticated?(@phoenix_kit_current_scope), do: "User is logged in!", else: "No user logged in"}
                </h3>
                <div class="text-sm">
                  <p><strong>Scope Status:</strong> authenticated? = {Scope.authenticated?(@phoenix_kit_current_scope)}</p>
                  <p><strong>User Status:</strong> anonymous? = {Scope.anonymous?(@phoenix_kit_current_scope)}</p>
                  <%= if Scope.authenticated?(@phoenix_kit_current_scope) do %>
                    <p><strong>Email:</strong> {Scope.user_email(@phoenix_kit_current_scope)}</p>
                    <p><strong>ID:</strong> {Scope.user_uuid(@phoenix_kit_current_scope)}</p>
                    <%= if Scope.user(@phoenix_kit_current_scope).confirmed_at do %>
                      <p><strong>Status:</strong> Confirmed at {Scope.user(@phoenix_kit_current_scope).confirmed_at}</p>
                    <% else %>
                      <p><strong>Status:</strong> Not confirmed</p>
                    <% end %>
                  <% else %>
                    <p class="text-sm">Page is accessible but scope is anonymous</p>
                    <p class="text-xs">Both @phoenix_kit_current_scope and @phoenix_kit_current_user available</p>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
          <div class="badge badge-info">PhoenixKit Scope Mount: ALWAYS ACCESSIBLE</div>
        </div>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end