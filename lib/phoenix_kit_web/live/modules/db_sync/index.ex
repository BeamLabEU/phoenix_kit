defmodule PhoenixKitWeb.Live.Modules.DBSync.Index do
  @moduledoc """
  Landing page for DB Sync module.

  Presents two options:
  - Send Data: Generate a code and host an endpoint to share your data
  - Receive Data: Connect to another site to browse and pull their data
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.DBSync
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    config = DBSync.get_config()

    socket =
      socket
      |> assign(:page_title, "DB Sync")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/db-sync", locale: locale))
      |> assign(:config, config)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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
              Transfer data between PhoenixKit instances
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

        <%!-- Main Options --%>
        <div class="grid gap-6 md:grid-cols-2 max-w-4xl mx-auto">
          <%!-- Send Data Card --%>
          <div class={[
            "card bg-base-100 shadow-xl",
            if(not @config.enabled, do: "opacity-50 pointer-events-none")
          ]}>
            <div class="card-body items-center text-center">
              <div class="text-6xl mb-4">📤</div>
              <h2 class="card-title text-2xl">Send Data</h2>
              <p class="text-base-content/70 mb-4">
                Generate a connection code and share your data with another site.
                They will connect to you and pull the data they need.
              </p>
              <div class="card-actions">
                <.link
                  navigate={Routes.path("/admin/db-sync/send", locale: @current_locale)}
                  class="btn btn-primary btn-lg"
                >
                  <.icon name="hero-arrow-up-tray" class="w-5 h-5" /> Share My Data
                </.link>
              </div>
            </div>
          </div>

          <%!-- Receive Data Card --%>
          <div class={[
            "card bg-base-100 shadow-xl",
            if(not @config.enabled, do: "opacity-50 pointer-events-none")
          ]}>
            <div class="card-body items-center text-center">
              <div class="text-6xl mb-4">📥</div>
              <h2 class="card-title text-2xl">Receive Data</h2>
              <p class="text-base-content/70 mb-4">
                Connect to another site using their URL and connection code
                to browse and pull their data into this site.
              </p>
              <div class="card-actions">
                <.link
                  navigate={Routes.path("/admin/db-sync/receive", locale: @current_locale)}
                  class="btn btn-secondary btn-lg"
                >
                  <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> Pull Data
                </.link>
              </div>
            </div>
          </div>
        </div>

        <%!-- Info Section --%>
        <div class="mt-12 max-w-4xl mx-auto">
          <div class="card bg-base-200">
            <div class="card-body">
              <h3 class="card-title text-lg">
                <.icon name="hero-information-circle" class="w-5 h-5" /> How it works
              </h3>
              <div class="grid gap-4 md:grid-cols-3 mt-4">
                <div class="flex items-start gap-3">
                  <div class="badge badge-primary badge-lg">1</div>
                  <div>
                    <p class="font-semibold">Sender Opens API</p>
                    <p class="text-sm text-base-content/70">
                      The site with data generates a connection code and shares it
                    </p>
                  </div>
                </div>
                <div class="flex items-start gap-3">
                  <div class="badge badge-primary badge-lg">2</div>
                  <div>
                    <p class="font-semibold">Receiver Connects</p>
                    <p class="text-sm text-base-content/70">
                      The site wanting data enters the URL and code to connect
                    </p>
                  </div>
                </div>
                <div class="flex items-start gap-3">
                  <div class="badge badge-primary badge-lg">3</div>
                  <div>
                    <p class="font-semibold">Browse & Transfer</p>
                    <p class="text-sm text-base-content/70">
                      Browse tables, select what to import, and configure conflict handling
                    </p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Active Sessions --%>
        <%= if @config.active_sessions > 0 do %>
          <div class="mt-6 max-w-4xl mx-auto">
            <div class="alert alert-info">
              <.icon name="hero-signal" class="w-5 h-5" />
              <span>
                <strong>{@config.active_sessions}</strong> active transfer session(s)
              </span>
            </div>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
