defmodule PhoenixKit.Modules.Shop.Web.Settings do
  @moduledoc """
  E-Commerce module settings LiveView.

  Allows configuration of e-commerce settings including inventory tracking.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # Test comment for live reload
  @impl true
  def mount(_params, _session, socket) do
    config = Shop.get_config()

    socket =
      socket
      |> assign(:page_title, "E-Commerce Settings")
      |> assign(:enabled, config.enabled)
      |> assign(:inventory_tracking, config.inventory_tracking)
      |> assign(:billing_enabled, billing_enabled?())

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_enabled", _params, socket) do
    new_enabled = !socket.assigns.enabled

    if new_enabled and not billing_enabled?() do
      # Cannot enable Shop without Billing
      {:noreply,
       socket
       |> assign(:enabled, false)
       |> put_flash(:error, "Please enable Billing module first")}
    else
      result =
        if new_enabled do
          Shop.enable_system()
        else
          Shop.disable_system()
        end

      case result do
        :ok ->
          socket =
            socket
            |> assign(:enabled, new_enabled)
            |> put_flash(
              :info,
              if(new_enabled, do: "E-Commerce module enabled", else: "E-Commerce module disabled")
            )

          {:noreply, socket}

        _ ->
          {:noreply,
           socket
           |> assign(:enabled, false)
           |> put_flash(:error, "Failed to update E-Commerce status")}
      end
    end
  end

  @impl true
  def handle_event("toggle_inventory_tracking", _params, socket) do
    new_value = !socket.assigns.inventory_tracking
    value_str = if(new_value, do: "true", else: "false")

    case Settings.update_setting("shop_inventory_tracking", value_str) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:inventory_tracking, new_value)
         |> put_flash(
           :info,
           if(new_value, do: "Inventory tracking enabled", else: "Inventory tracking disabled")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update inventory setting")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_path={@url_path}
      current_locale={@current_locale}
      page_title={@page_title}
    >
      <div class="container flex-col mx-auto px-4 py-6 max-w-5xl">
        <%!-- Header --%>
        <header class="mb-6">
          <div class="flex items-start gap-4">
            <.link
              navigate={Routes.path("/admin/shop")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">E-Commerce Settings</h1>
              <p class="text-base-content/70 mt-1">Configure your e-commerce store</p>
            </div>
          </div>
        </header>

        <%!-- Module Status Card --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div>
                <h2 class="card-title text-xl">Module Status</h2>
                <p class="text-base-content/70">Enable or disable the E-Commerce module</p>
              </div>
              <div class="flex items-center gap-4">
                <span class={[
                  "badge badge-lg",
                  if(@enabled, do: "badge-success", else: "badge-neutral")
                ]}>
                  {if @enabled, do: "Enabled", else: "Disabled"}
                </span>
                <div class="flex flex-col items-end gap-1">
                  <input
                    type="checkbox"
                    class="toggle toggle-primary toggle-lg"
                    checked={@enabled}
                    disabled={not @billing_enabled}
                    phx-click="toggle_enabled"
                  />
                  <%= if not @billing_enabled do %>
                    <.link
                      navigate={Routes.path("/admin/modules")}
                      class="badge badge-warning badge-sm hover:badge-error"
                    >
                      Billing Required
                    </.link>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Inventory Settings (toggle pattern) --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-6">
              <.icon name="hero-archive-box" class="w-6 h-6" /> Inventory
            </h2>

            <div class="form-control">
              <label class="label cursor-pointer justify-between">
                <span class="label-text text-lg">
                  <span class="font-semibold">Track Inventory</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    Enable stock tracking for products (Phase 2)
                  </div>
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-secondary"
                  checked={@inventory_tracking}
                  phx-click="toggle_inventory_tracking"
                />
              </label>
            </div>
          </div>
        </div>

        <%!-- Info about Billing --%>
        <div class="alert alert-info mb-6">
          <.icon name="hero-information-circle" class="w-6 h-6" />
          <div>
            <h3 class="font-bold">Currency & Tax Settings</h3>
            <p class="text-sm">
              Currency and tax configuration is managed in the
              <.link navigate={Routes.path("/admin/settings/billing")} class="link font-medium">
                Billing module settings
              </.link>
            </p>
          </div>
        </div>

        <%!-- Product Options --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-6">
              <.icon name="hero-tag" class="w-6 h-6" /> Product Options
            </h2>

            <div class="form-control">
              <label class="label cursor-pointer justify-between">
                <span class="label-text text-lg">
                  <span class="font-semibold">Global Product Options</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    Define options that apply to all products (size, color, material, etc.)
                  </div>
                  <div class="text-xs text-base-content/50 mt-1">
                    Price override is configured per-option in the options settings.
                  </div>
                </span>
                <.link
                  navigate={Routes.path("/admin/shop/settings/options")}
                  class="btn btn-primary"
                >
                  <.icon name="hero-cog-6-tooth" class="w-4 h-4 mr-2" /> Configure
                </.link>
              </label>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp billing_enabled? do
    Code.ensure_loaded?(Billing) and
      function_exported?(Billing, :enabled?, 0) and
      Billing.enabled?()
  rescue
    _ -> false
  end
end
