defmodule PhoenixKit.Modules.Shop.Web.Dashboard do
  @moduledoc """
  E-Commerce module dashboard LiveView.

  Displays e-commerce statistics and quick access to management features.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(30_000, self(), :refresh_stats)

    stats = Shop.get_dashboard_stats()

    socket =
      socket
      |> assign(:page_title, "E-Commerce")
      |> assign(:stats, stats)
      |> assign(:enabled, Shop.enabled?())

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_stats, socket) do
    stats = Shop.get_dashboard_stats()
    {:noreply, assign(socket, :stats, stats)}
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
      <div class="p-6 max-w-7xl mx-auto">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-3xl font-bold text-base-content">E-Commerce</h1>
            <p class="text-base-content/70 mt-1">Manage your e-commerce store</p>
          </div>

          <div class="flex items-center gap-3">
            <.link
              navigate={Routes.path("/admin/shop/products/new")}
              class="btn btn-primary"
            >
              <.icon name="hero-plus" class="w-5 h-5 mr-2" /> Add Product
            </.link>
          </div>
        </div>

        <%!-- Stats Grid --%>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6 mb-8">
          <%!-- Total Products --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <div>
                  <p class="text-base-content/70 text-sm">Total Products</p>
                  <p class="text-3xl font-bold text-base-content">{@stats.total_products}</p>
                </div>
                <div class="bg-primary/10 p-3 rounded-lg">
                  <.icon name="hero-cube" class="w-8 h-8 text-primary" />
                </div>
              </div>
            </div>
          </div>

          <%!-- Active Products --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <div>
                  <p class="text-base-content/70 text-sm">Active Products</p>
                  <p class="text-3xl font-bold text-success">{@stats.active_products}</p>
                </div>
                <div class="bg-success/10 p-3 rounded-lg">
                  <.icon name="hero-check-circle" class="w-8 h-8 text-success" />
                </div>
              </div>
            </div>
          </div>

          <%!-- Draft Products --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <div>
                  <p class="text-base-content/70 text-sm">Draft Products</p>
                  <p class="text-3xl font-bold text-warning">{@stats.draft_products}</p>
                </div>
                <div class="bg-warning/10 p-3 rounded-lg">
                  <.icon name="hero-pencil-square" class="w-8 h-8 text-warning" />
                </div>
              </div>
            </div>
          </div>

          <%!-- Categories --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <div class="flex items-center justify-between">
                <div>
                  <p class="text-base-content/70 text-sm">Categories</p>
                  <p class="text-3xl font-bold text-base-content">{@stats.total_categories}</p>
                </div>
                <div class="bg-info/10 p-3 rounded-lg">
                  <.icon name="hero-folder" class="w-8 h-8 text-info" />
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Product Types Grid --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
          <%!-- Physical Products --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title">
                <.icon name="hero-truck" class="w-6 h-6" /> Physical Products
              </h2>
              <p class="text-4xl font-bold text-primary">{@stats.physical_products}</p>
              <p class="text-base-content/70">Products requiring shipping</p>
            </div>
          </div>

          <%!-- Digital Products --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title">
                <.icon name="hero-arrow-down-tray" class="w-6 h-6" /> Digital Products
              </h2>
              <p class="text-4xl font-bold text-secondary">{@stats.digital_products}</p>
              <p class="text-base-content/70">Downloadable products</p>
            </div>
          </div>
        </div>

        <%!-- Quick Actions --%>
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <h2 class="card-title mb-4">Quick Actions</h2>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <.link
                navigate={Routes.path("/admin/shop/products")}
                class="btn btn-outline btn-lg justify-start"
              >
                <.icon name="hero-cube" class="w-5 h-5 mr-2" /> Manage Products
              </.link>

              <.link
                navigate={Routes.path("/admin/shop/categories")}
                class="btn btn-outline btn-lg justify-start"
              >
                <.icon name="hero-folder" class="w-5 h-5 mr-2" /> Manage Categories
              </.link>

              <.link
                navigate={Routes.path("/admin/shop/settings")}
                class="btn btn-outline btn-lg justify-start"
              >
                <.icon name="hero-cog-6-tooth" class="w-5 h-5 mr-2" /> Settings
              </.link>
            </div>
          </div>
        </div>

        <%!-- Phase 2 Placeholder --%>
        <div class="mt-8 p-6 border-2 border-dashed border-base-300 rounded-lg text-center text-base-content/50">
          <.icon name="hero-rocket-launch" class="w-12 h-12 mx-auto mb-3" />
          <p class="text-lg font-medium">Coming in Phase 2</p>
          <p class="text-sm">Variants, Inventory, Cart, Orders</p>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
