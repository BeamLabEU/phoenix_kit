defmodule PhoenixKit.Modules.Sync.Web.Index do
  @moduledoc """
  Landing page for DB Sync module.

  Provides access to:
  - Manage Connections: Create and manage permanent connections with other sites
  - Transfer History: View all data transfers with approval workflow
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Sync
  alias PhoenixKit.Modules.Sync.Connections
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    config = Sync.get_config()

    # Get connection stats
    stats = get_connection_stats()

    socket =
      socket
      |> assign(:page_title, "DB Sync")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/sync", locale: locale))
      |> assign(:config, config)
      |> assign(:stats, stats)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp get_connection_stats do
    default_stats = %{
      total_senders: 0,
      total_receivers: 0,
      active_senders: 0,
      active_receivers: 0
    }

    with {:ok, sender_connections} <- safe_list_connections("sender"),
         {:ok, receiver_connections} <- safe_list_connections("receiver") do
      active_senders = Enum.count(sender_connections, &(&1.status == "active"))
      active_receivers = Enum.count(receiver_connections, &(&1.status == "active"))

      %{
        total_senders: length(sender_connections),
        total_receivers: length(receiver_connections),
        active_senders: active_senders,
        active_receivers: active_receivers
      }
    else
      _ -> default_stats
    end
  end

  defp safe_list_connections(direction) do
    {:ok, Connections.list_connections(direction: direction)}
  rescue
    _ -> {:error, :unavailable}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - DB Sync"
      current_path={@current_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-8">
          <.link
            navigate={Routes.path("/admin/modules")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to Modules
          </.link>

          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">DB Sync</h1>
            <p class="text-lg text-base-content/70">
              Sync data between PhoenixKit instances with permanent connections
            </p>
          </div>
        </header>

        <%= if not @config.enabled do %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>
              DB Sync module is disabled. Enable it in
              <.link navigate={Routes.path("/admin/modules")} class="link link-primary">
                Modules
              </.link>
              to use this feature.
            </span>
          </div>
        <% end %>

        <%!-- Stats Overview (commented out for now - will add back later)
        <%= if @config.enabled do %>
          <div class="grid gap-4 md:grid-cols-3 max-w-3xl mx-auto mb-8">
            <div class="stat bg-base-100 rounded-box shadow">
              <div class="stat-figure text-primary">
                <.icon name="hero-arrow-up-tray" class="w-8 h-8" />
              </div>
              <div class="stat-title">Sender Connections</div>
              <div class="stat-value text-primary">{@stats.total_senders}</div>
              <div class="stat-desc">{@stats.active_senders} active</div>
            </div>

            <div class="stat bg-base-100 rounded-box shadow">
              <div class="stat-figure text-secondary">
                <.icon name="hero-arrow-down-tray" class="w-8 h-8" />
              </div>
              <div class="stat-title">Receiver Connections</div>
              <div class="stat-value text-secondary">{@stats.total_receivers}</div>
              <div class="stat-desc">{@stats.active_receivers} active</div>
            </div>

            <div class="stat bg-base-100 rounded-box shadow">
              <div class="stat-figure text-success">
                <.icon name="hero-check-circle" class="w-8 h-8" />
              </div>
              <div class="stat-title">Total Active</div>
              <div class="stat-value text-success">
                {@stats.active_senders + @stats.active_receivers}
              </div>
              <div class="stat-desc">connections ready</div>
            </div>
          </div>
        <% end %>
        --%>

        <%!-- Main Actions --%>
        <div class="grid gap-6 md:grid-cols-2 max-w-4xl mx-auto">
          <%!-- Manage Connections Card --%>
          <div class={[
            "card bg-base-100 shadow-xl",
            if(not @config.enabled, do: "opacity-50 pointer-events-none")
          ]}>
            <div class="card-body items-center text-center">
              <div class="text-6xl mb-4">
                <.icon name="hero-link" class="w-16 h-16 text-primary" />
              </div>
              <h2 class="card-title text-2xl">Manage Connections</h2>
              <p class="text-base-content/70 mb-4">
                Create sender connections to share your data with other sites.
                Receiver connections are created automatically when remote sites connect.
              </p>
              <div class="card-actions">
                <.link
                  navigate={Routes.path("/admin/sync/connections", locale: @current_locale)}
                  class="btn btn-primary btn-lg"
                >
                  <.icon name="hero-cog-6-tooth" class="w-5 h-5" /> Manage Connections
                </.link>
              </div>
            </div>
          </div>

          <%!-- Transfer History Card --%>
          <div class={[
            "card bg-base-100 shadow-xl",
            if(not @config.enabled, do: "opacity-50 pointer-events-none")
          ]}>
            <div class="card-body items-center text-center">
              <div class="text-6xl mb-4">
                <.icon name="hero-clock" class="w-16 h-16 text-secondary" />
              </div>
              <h2 class="card-title text-2xl">Transfer History</h2>
              <p class="text-base-content/70 mb-4">
                View all data transfers and monitor sync activity.
                Track records transferred and connection statistics.
              </p>
              <div class="card-actions">
                <.link
                  navigate={Routes.path("/admin/sync/history", locale: @current_locale)}
                  class="btn btn-secondary btn-lg"
                >
                  <.icon name="hero-queue-list" class="w-5 h-5" /> View History
                </.link>
              </div>
            </div>
          </div>
        </div>

        <%!-- How It Works Section --%>
        <div class="mt-12 max-w-4xl mx-auto">
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title text-lg">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                How Cross-Site Connections Work
              </h3>
              <div class="grid gap-6 md:grid-cols-2 mt-4">
                <div>
                  <h4 class="font-bold text-primary mb-2 flex items-center gap-2">
                    <.icon name="hero-arrow-up-tray" class="w-5 h-5" /> As a Sender
                  </h4>
                  <ol class="list-decimal list-inside space-y-2 text-sm text-base-content/80">
                    <li>Create a <strong>sender connection</strong> with a name</li>
                    <li>Enter the remote site's URL</li>
                    <li>The remote site is <strong>notified automatically</strong></li>
                    <li>They can now pull data from your tables</li>
                  </ol>
                </div>
                <div>
                  <h4 class="font-bold text-secondary mb-2 flex items-center gap-2">
                    <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> As a Receiver
                  </h4>
                  <ol class="list-decimal list-inside space-y-2 text-sm text-base-content/80">
                    <li>When another site creates a connection to you</li>
                    <li>A <strong>receiver connection</strong> appears automatically</li>
                    <li>Use it to sync data from their site</li>
                    <li>Choose conflict strategy when importing</li>
                  </ol>
                </div>
              </div>
              <div class="divider"></div>
              <div class="text-sm text-base-content/70">
                <strong>Security:</strong> All connections use token-based authentication.
              </div>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
