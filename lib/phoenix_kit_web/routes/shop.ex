defmodule PhoenixKitWeb.Routes.ShopRoutes do
  @moduledoc """
  Shop module routes.

  Provides route definitions for e-commerce functionality including
  admin, public catalog, and user dashboard routes.
  """

  @doc """
  Returns quoted `live` route declarations for non-localized shop public pages.

  These declarations are included directly inside the unified `:phoenix_kit_public`
  live_session defined in `phoenix_kit_public_routes/1` in `PhoenixKitWeb.Integration`.
  Routes use full module names (alias: false) and non-localized route aliases.
  """
  def public_live_routes do
    quote do
      live "/shop", PhoenixKit.Modules.Shop.Web.ShopCatalog, :index, as: :shop_catalog

      live "/shop/category/:slug", PhoenixKit.Modules.Shop.Web.CatalogCategory, :show,
        as: :shop_category

      live "/shop/product/:slug", PhoenixKit.Modules.Shop.Web.CatalogProduct, :show,
        as: :shop_product

      live "/cart", PhoenixKit.Modules.Shop.Web.CartPage, :index, as: :shop_cart
      live "/checkout", PhoenixKit.Modules.Shop.Web.CheckoutPage, :index, as: :shop_checkout

      live "/checkout/complete/:uuid", PhoenixKit.Modules.Shop.Web.CheckoutComplete, :show,
        as: :shop_checkout_complete
    end
  end

  @doc """
  Returns quoted `live` route declarations for localized shop public pages.

  These declarations are included directly inside the unified `:phoenix_kit_public_locale`
  live_session defined in `phoenix_kit_public_routes/1` in `PhoenixKitWeb.Integration`.
  Routes use full module names (alias: false) and localized route aliases.
  """
  def public_live_locale_routes do
    quote do
      live "/shop", PhoenixKit.Modules.Shop.Web.ShopCatalog, :index, as: :shop_catalog_localized

      live "/shop/category/:slug", PhoenixKit.Modules.Shop.Web.CatalogCategory, :show,
        as: :shop_category_localized

      live "/shop/product/:slug", PhoenixKit.Modules.Shop.Web.CatalogProduct, :show,
        as: :shop_product_localized

      live "/cart", PhoenixKit.Modules.Shop.Web.CartPage, :index, as: :shop_cart_localized

      live "/checkout", PhoenixKit.Modules.Shop.Web.CheckoutPage, :index,
        as: :shop_checkout_localized

      live "/checkout/complete/:uuid", PhoenixKit.Modules.Shop.Web.CheckoutComplete, :show,
        as: :shop_checkout_complete_localized
    end
  end

  @doc """
  Returns quoted code for shop public routes.

  Shop public routes are now included in the unified `:phoenix_kit_public` live_session
  via `phoenix_kit_public_routes/1` in `PhoenixKitWeb.Integration`. This function
  returns an empty block for backward compatibility.
  """
  def generate_public_routes(_url_prefix) do
    quote do
    end
  end
end
