defmodule PhoenixKitWeb.Live.Modules.Maintenance.Page do
  @moduledoc """
  Standalone maintenance page LiveView for admin preview and direct access.

  The main maintenance enforcement is handled by the layout override in
  `check_maintenance_mode/1` (auth.ex) — non-admin users see the maintenance
  layout on whatever page they're on, without a URL change.

  This LiveView serves as:
  - Admin preview at `/maintenance` (with banner + settings link)
  - Fallback target for the plug's 503 response on non-LiveView controller routes

  Supports countdown timer, PubSub status updates, and admin preview.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    is_admin = scope && (Scope.admin?(scope) || Scope.owner?(scope))

    # If maintenance is not active and user is not admin, redirect away
    if Maintenance.active?() or is_admin do
      if connected?(socket) do
        Maintenance.subscribe()
      end

      config = Maintenance.get_config()
      scheduled_end = Maintenance.get_scheduled_end()

      # Calculate ISO 8601 end time string for the JS countdown hook
      end_iso =
        case scheduled_end do
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          _ -> nil
        end

      socket =
        socket
        |> assign(:page_title, config.header)
        |> assign(:header, config.header)
        |> assign(:subtext, config.subtext)
        |> assign(:is_admin, is_admin)
        |> assign(:is_active, config.active)
        |> assign(:scheduled_end_iso, end_iso)

      {:ok, socket, layout: false}
    else
      {:ok, push_navigate(socket, to: Routes.path("/"))}
    end
  end

  # PubSub: maintenance status changed
  @impl true
  def handle_info({:maintenance_status_changed, %{active: false}}, socket) do
    if socket.assigns.is_admin do
      # Admins stay — update the status indicator
      {:noreply, assign(socket, :is_active, false)}
    else
      {:noreply, push_navigate(socket, to: Routes.path("/"))}
    end
  end

  def handle_info({:maintenance_status_changed, %{active: true}}, socket) do
    {:noreply, assign(socket, :is_active, true)}
  end

  # Catch-all for unexpected messages (e.g. other PubSub topics, system messages)
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  # JS countdown reached zero — verify server-side and redirect if maintenance ended
  @impl true
  def handle_event("check_status", _params, socket) do
    if Maintenance.active?() do
      {:noreply, socket}
    else
      if socket.assigns.is_admin do
        {:noreply, assign(socket, :is_active, false)}
      else
        {:noreply, push_navigate(socket, to: Routes.path("/"))}
      end
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-base-200 flex items-center justify-center p-4 z-50">
      <div class="max-w-2xl w-full space-y-6">
        <%!-- Admin preview banner --%>
        <%= if @is_admin do %>
          <div class="alert alert-info shadow-lg">
            <.icon name="hero-eye" class="w-5 h-5" />
            <div class="flex-1">
              <p class="font-semibold">{gettext("Admin Preview")}</p>
              <p class="text-sm">
                <%= if @is_active do %>
                  {gettext("Maintenance is active — regular users see this page.")}
                <% else %>
                  {gettext("Maintenance is not active — this is a preview of the page.")}
                <% end %>
              </p>
            </div>
            <.link navigate={Routes.path("/admin/settings/maintenance")} class="btn btn-sm btn-ghost">
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" /> {gettext("Settings")}
            </.link>
          </div>
        <% end %>

        <%!-- Main maintenance card --%>
        <div class="card bg-base-100 shadow-2xl border-2 border-dashed border-base-300">
          <div class="card-body text-center py-12 px-6">
            <div class="text-8xl mb-6 opacity-70">
              🚧
            </div>
            <h1 class="text-5xl font-bold text-base-content mb-6">
              {@header}
            </h1>
            <p class="text-xl text-base-content/70 mb-8 leading-relaxed">
              {@subtext}
            </p>

            <%!-- Countdown timer --%>
            <%= if @scheduled_end_iso do %>
              <div class="divider"></div>
              <div
                id="maintenance-countdown"
                phx-hook="MaintenanceCountdown"
                data-end={@scheduled_end_iso}
                class="text-base-content/50"
              >
                <p class="text-sm">
                  {gettext("Expected back in")}
                  <span id="countdown-value" class="font-mono font-semibold text-base-content/70">
                  </span>
                </p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
