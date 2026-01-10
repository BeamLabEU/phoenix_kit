defmodule PhoenixKit.Modules.Shop.Web.Settings do
  @moduledoc """
  E-Commerce module settings LiveView.

  Allows configuration of e-commerce settings including inventory tracking.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    config = Shop.get_config()

    socket =
      socket
      |> assign(:page_title, "E-Commerce Settings")
      |> assign(:enabled, config.enabled)
      |> assign(:inventory_tracking, config.inventory_tracking)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_enabled", _params, socket) do
    new_enabled = !socket.assigns.enabled

    result =
      if new_enabled do
        Shop.enable_system()
      else
        Shop.disable_system()
      end

    case result do
      {:ok, _} ->
        socket =
          socket
          |> assign(:enabled, new_enabled)
          |> put_flash(
            :info,
            if(new_enabled, do: "E-Commerce module enabled", else: "E-Commerce module disabled")
          )

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update E-Commerce status")}
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
      <div class="p-6 max-w-4xl mx-auto">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-3xl font-bold text-base-content">E-Commerce Settings</h1>
            <p class="text-base-content/70 mt-1">Configure your e-commerce store</p>
          </div>

          <.link navigate={Routes.path("/admin/shop")} class="btn btn-outline">
            <.icon name="hero-arrow-left" class="w-5 h-5 mr-2" /> Back to Dashboard
          </.link>
        </div>

        <%!-- Module Status --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div>
                <h2 class="card-title">Module Status</h2>
                <p class="text-base-content/70">Enable or disable the E-Commerce module</p>
              </div>
              <div class="flex items-center gap-4">
                <span class={[
                  "badge badge-lg",
                  if(@enabled, do: "badge-success", else: "badge-neutral")
                ]}>
                  {if @enabled, do: "Enabled", else: "Disabled"}
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-primary toggle-lg"
                  checked={@enabled}
                  phx-click="toggle_enabled"
                />
              </div>
            </div>
          </div>
        </div>

        <%!-- Inventory Settings --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body">
            <h2 class="card-title mb-4">
              <.icon name="hero-archive-box" class="w-6 h-6" /> Inventory
            </h2>

            <div class="flex items-center justify-between">
              <div>
                <p class="font-medium">Track Inventory</p>
                <p class="text-sm text-base-content/60">
                  Enable stock tracking for products (Phase 2)
                </p>
              </div>
              <input
                type="checkbox"
                class="toggle toggle-primary"
                checked={@inventory_tracking}
                phx-click="toggle_inventory_tracking"
              />
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

        <%!-- Phase 2 Features --%>
        <div class="card bg-base-200/50 border-2 border-dashed border-base-300">
          <div class="card-body text-center">
            <.icon name="hero-clock" class="w-12 h-12 mx-auto text-base-content/50 mb-3" />
            <h3 class="text-lg font-medium text-base-content/70">Coming Soon</h3>
            <p class="text-sm text-base-content/50">
              Variants, inventory management, cart, and checkout will be available in Phase 2
            </p>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
