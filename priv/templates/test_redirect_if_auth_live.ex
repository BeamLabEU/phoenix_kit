defmodule PhoenixKitWeb.TestRedirectIfAuthLive do
  @moduledoc """
  Test component for phoenix_kit_redirect_if_user_is_authenticated authentication level.
  This page redirects authenticated users and is only accessible to anonymous users.
  """
  use PhoenixKitWeb, :live_view

  def render(assigns) do
    ~H"""
    <div class="hero py-8 min-h-[80vh] bg-warning">
      <div class="hero-content text-center">
        <div class="max-w-md">
          <h1 class="text-5xl font-bold text-warning-content">phoenix_kit_redirect_if_user_is_authenticated</h1>
          <div class="py-6 text-warning-content">
            <p class="mb-4">
              This page uses PhoenixKit <code>phoenix_kit_redirect_if_user_is_authenticated</code>.
              Authenticated users are automatically redirected.
            </p>

            <div class="alert alert-warning">
              <div>
                <h3 class="font-bold">No user logged in</h3>
                <p class="text-sm">This page is only accessible to anonymous users.</p>
                <p class="text-xs">Authenticated users will be redirected automatically.</p>
              </div>
            </div>
          </div>
          <div class="badge badge-warning">PhoenixKit Redirect Auth: ANONYMOUS ONLY</div>
        </div>
      </div>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, socket}
  end
end