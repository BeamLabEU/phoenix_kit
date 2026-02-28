defmodule PhoenixKitWeb.TestEnsureAuthLive do
  @moduledoc """
  Test component for phoenix_kit_ensure_authenticated authentication level.
  This page requires authentication and redirects to login if not authenticated.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth.Scope

  def render(assigns) do
    ~H"""
    <div class="hero py-8 min-h-[80vh] bg-success">
      <div class="hero-content text-center">
        <div class="max-w-md">
          <h1 class="text-5xl font-bold text-success-content">phoenix_kit_ensure_authenticated</h1>
          <div class="py-6 text-success-content">
            <p class="mb-4">
              This page uses PhoenixKit <code>phoenix_kit_ensure_authenticated</code>.
              User must be authenticated to access this page.
            </p>

            <div class="alert alert-success">
              <div>
                <h3 class="font-bold">User is authenticated!</h3>
                <div class="text-sm">
                  <p><strong>Email:</strong> {Scope.user_email(@phoenix_kit_current_scope)}</p>
                  <p><strong>ID:</strong> {Scope.user_uuid(@phoenix_kit_current_scope)}</p>
                  <%= if Scope.user(@phoenix_kit_current_scope).confirmed_at do %>
                    <p><strong>Status:</strong> Confirmed at {Scope.user(@phoenix_kit_current_scope).confirmed_at}</p>
                  <% else %>
                    <p><strong>Status:</strong> Not confirmed</p>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
          <div class="badge badge-success">PhoenixKit Ensure Auth: REQUIRES LOGIN</div>
        </div>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end