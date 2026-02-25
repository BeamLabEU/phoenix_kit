defmodule PhoenixKit.Modules.Shop.Web.Components.ShopLayouts do
  @moduledoc """
  Shared layout components for the shop storefront public pages.

  Provides two components:
  - `shop_public_layout/1` - Public navbar + flash + main content wrapper for guest users
  - `shop_layout/1` - Top-level layout dispatcher: dashboard for authenticated, public/app for guests
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Flash, only: [flash_group: 1]
  import PhoenixKitWeb.Components.Core.LanguageSwitcher, only: [language_switcher_dropdown: 1]
  import PhoenixKitWeb.LayoutHelpers, only: [dashboard_assigns: 1]

  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @doc """
  Public shop layout with navbar, flash messages, and main content area.

  Used for guest users on catalog/category/product pages.
  """
  slot :inner_block, required: true
  attr :current_language, :string, required: true
  attr :current_path, :string, required: true
  attr :flash, :map, required: true

  def shop_public_layout(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <%!-- Simple navbar for shop --%>
      <nav class="navbar bg-base-100 shadow-sm border-b border-base-200">
        <div class="navbar-start">
          <.link navigate="/" class="btn btn-ghost text-xl">
            <.icon name="hero-home" class="w-5 h-5" />
          </.link>
        </div>
        <div class="navbar-center">
          <.link navigate={Shop.catalog_url(@current_language)} class="btn btn-ghost text-xl">
            <.icon name="hero-shopping-bag" class="w-5 h-5 mr-2" /> Shop
          </.link>
        </div>
        <div class="navbar-end gap-2">
          <.language_switcher_dropdown
            current_locale={@current_language}
            current_path={@current_path}
          />
          <.link navigate={Shop.cart_url(@current_language)} class="btn btn-ghost btn-circle">
            <.icon name="hero-shopping-cart" class="w-5 h-5" />
          </.link>
          <.link navigate={Routes.path("/users/log-in")} class="btn btn-primary btn-sm">
            Sign In
          </.link>
        </div>
      </nav>

      <%!-- Flash messages --%>
      <.flash_group flash={@flash} />

      <%!-- Wide content area --%>
      <main class="py-6">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  @doc """
  Top-level layout wrapper for shop pages.

  Routes to:
  - Dashboard layout for authenticated users
  - `shop_public_layout` for guests when `show_sidebar` is true (catalog/category/product pages)
  - `LayoutWrapper.app_layout` for guests when `show_sidebar` is false (cart/checkout pages)
  """
  slot :inner_block, required: true
  attr :authenticated, :boolean, required: true
  attr :show_sidebar, :boolean, default: false
  attr :flash, :map, required: true
  attr :phoenix_kit_current_scope, :any, required: true
  attr :url_path, :string, required: true
  attr :current_locale, :string, required: true
  attr :page_title, :string, required: true
  attr :sidebar_after_shop, :any, default: nil
  # Used when show_sidebar is true (catalog/category/product pages)
  attr :current_language, :string, default: nil
  attr :current_path, :string, default: nil

  def shop_layout(assigns) do
    ~H"""
    <%= if @authenticated do %>
      <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
        {render_slot(@inner_block)}
      </PhoenixKitWeb.Layouts.dashboard>
    <% else %>
      <%= if @show_sidebar do %>
        <.shop_public_layout
          flash={@flash}
          current_language={@current_language}
          current_path={@current_path}
        >
          {render_slot(@inner_block)}
        </.shop_public_layout>
      <% else %>
        <PhoenixKitWeb.Components.LayoutWrapper.app_layout
          flash={@flash}
          phoenix_kit_current_scope={@phoenix_kit_current_scope}
          current_path={@url_path}
          current_locale={@current_locale}
          page_title={@page_title}
        >
          {render_slot(@inner_block)}
        </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
      <% end %>
    <% end %>
    """
  end
end
