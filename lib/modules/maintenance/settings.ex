defmodule PhoenixKitWeb.Live.Modules.Maintenance.Settings do
  @moduledoc """
  Settings page for the Maintenance module.

  Allows admins to customize the maintenance page header and subtext.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    # Get current path for navigation
    current_path =
      Routes.path("/admin/settings/maintenance", locale: socket.assigns.current_locale_base)

    # Get current settings
    config = Maintenance.get_config()

    socket =
      socket
      |> assign(:page_title, "Maintenance Mode Settings")
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:current_path, current_path)
      |> assign(:header, config.header)
      |> assign(:subtext, config.subtext)
      |> assign(:enabled, config.enabled)
      |> assign(:saved, false)

    {:ok, socket}
  end

  def handle_event("update_header", %{"header" => header}, socket) do
    {:noreply, assign(socket, :header, header)}
  end

  def handle_event("update_subtext", %{"subtext" => subtext}, socket) do
    {:noreply, assign(socket, :subtext, subtext)}
  end

  def handle_event("save", _params, socket) do
    # Save header and subtext to database
    Maintenance.update_header(socket.assigns.header)
    Maintenance.update_subtext(socket.assigns.subtext)

    socket =
      socket
      |> assign(:saved, true)
      |> put_flash(:info, "Maintenance mode settings saved successfully")

    # Reset saved flag after 2 seconds
    Process.send_after(self(), :reset_saved, 2000)

    {:noreply, socket}
  end

  def handle_event("cancel", _params, socket) do
    # Reload settings from database
    config = Maintenance.get_config()

    socket =
      socket
      |> assign(:header, config.header)
      |> assign(:subtext, config.subtext)
      |> put_flash(:info, "Changes discarded")

    {:noreply, socket}
  end

  def handle_event("toggle_maintenance_mode", _params, socket) do
    # Toggle actual maintenance mode
    new_enabled = !socket.assigns.enabled

    result =
      if new_enabled do
        Maintenance.enable_system()
      else
        Maintenance.disable_system()
      end

    case result do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled,
              do: "Maintenance mode activated - non-admin users will see the maintenance page",
              else: "Maintenance mode deactivated - site is now accessible to all users"
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to toggle maintenance mode")
        {:noreply, socket}
    end
  end

  def handle_info(:reset_saved, socket) do
    {:noreply, assign(socket, :saved, false)}
  end

  @doc """
  Renders the maintenance settings LiveView.
  """
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Maintenance Mode Settings"
      current_path={@current_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="container mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button --%>
          <.link
            navigate={PhoenixKit.Utils.Routes.path("/admin/modules")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to Modules
          </.link>
          <%!-- Title Section --%>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">Maintenance Mode Settings</h1>
            <p class="text-lg text-base-content/70">Customize the maintenance page message</p>
          </div>
        </header>

        <%!-- Maintenance Mode Toggle --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div class="flex-1">
                <h2 class="card-title mb-2">
                  <.icon name="hero-power" class="w-5 h-5" /> Maintenance Mode Status
                </h2>
                <p class="text-sm text-base-content/70">
                  {if @enabled,
                    do:
                      "Site is currently in maintenance mode - non-admin users see the maintenance page",
                    else: "Site is operating normally - all users have access"}
                </p>
              </div>
              <div class="flex-shrink-0 ml-4">
                <input
                  type="checkbox"
                  class="toggle toggle-lg toggle-warning"
                  checked={@enabled}
                  phx-click="toggle_maintenance_mode"
                />
              </div>
            </div>
            <%= if @enabled do %>
              <div class="alert alert-warning mt-4">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <span>
                  <strong>Active:</strong>
                  Non-admin users are currently seeing the maintenance page below.
                </span>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Two Column Layout: Settings + Preview --%>
        <div class="grid gap-6 lg:grid-cols-2">
          <%!-- Settings Form (Left Column) --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title mb-4">
                <.icon name="hero-cog-6-tooth" class="w-5 h-5" /> Configuration
              </h2>
              <form phx-submit="save" class="space-y-4">
                <%!-- Header Input --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-semibold">Header Text</span>
                  </label>
                  <input
                    type="text"
                    name="header"
                    value={@header}
                    phx-change="update_header"
                    phx-debounce="300"
                    class="input input-bordered w-full"
                    placeholder="Maintenance Mode"
                    required
                  />
                  <label class="label">
                    <span class="label-text-alt">Main heading shown on maintenance page</span>
                  </label>
                </div>

                <%!-- Subtext Input --%>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-semibold">Message Text</span>
                  </label>
                  <textarea
                    name="subtext"
                    phx-change="update_subtext"
                    phx-debounce="300"
                    class="textarea textarea-bordered w-full h-32"
                    placeholder="We'll be back soon..."
                    required
                  >{@subtext}</textarea>
                  <label class="label">
                    <span class="label-text-alt">Detailed message shown below the header</span>
                  </label>
                </div>

                <%!-- Action Buttons --%>
                <div class="flex gap-2">
                  <button
                    type="submit"
                    class={"btn btn-primary flex-1 #{if @saved, do: "btn-success"}"}
                  >
                    <.icon
                      name={if @saved, do: "hero-check", else: "hero-arrow-down-tray"}
                      class="w-5 h-5"
                    />
                    {if @saved, do: "Saved!", else: "Save Changes"}
                  </button>
                  <button
                    type="button"
                    phx-click="cancel"
                    class="btn btn-outline"
                    disabled={@saved}
                  >
                    <.icon name="hero-x-mark" class="w-5 h-5" /> Cancel
                  </button>
                </div>
              </form>
            </div>
          </div>

          <%!-- Live Preview (Right Column) --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title mb-4">
                <.icon name="hero-eye" class="w-5 h-5" /> Live Preview
              </h2>
              <div class="bg-base-200 rounded-lg p-8 min-h-[400px] flex items-center justify-center">
                <div class="card bg-base-100 shadow-2xl border-2 border-dashed border-base-300 w-full">
                  <div class="card-body text-center py-8">
                    <%!-- Icon --%>
                    <div class="text-6xl mb-4 opacity-70">
                      🚧
                    </div>
                    <%!-- Header --%>
                    <h1 class="text-3xl font-bold text-base-content mb-3">
                      {@header}
                    </h1>
                    <%!-- Subtext --%>
                    <p class="text-base text-base-content/70 mb-6">
                      {@subtext}
                    </p>
                  </div>
                </div>
              </div>
              <div class="alert alert-info mt-4">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                <span class="text-sm">This is how non-admin users will see the maintenance page</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
