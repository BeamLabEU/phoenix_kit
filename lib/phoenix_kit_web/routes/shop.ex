defmodule PhoenixKitWeb.Routes.ShopRoutes do
  @moduledoc """
  Shop module routes.

  Provides route definitions for e-commerce functionality including
  admin, public catalog, and user dashboard routes.
  """

  @doc """
  Returns quoted code for shop public routes.
  """
  def generate_public_routes(url_prefix) do
    quote do
      # Localized shop routes (with :locale prefix)
      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [
          :browser,
          :phoenix_kit_auto_setup,
          :phoenix_kit_shop_session,
          :phoenix_kit_locale_validation
        ]

        live_session :phoenix_kit_shop_public_localized,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
          live "/shop", PhoenixKit.Modules.Shop.Web.ShopCatalog, :index,
            as: :shop_catalog_localized

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

      # Non-localized shop routes (default language - no prefix)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_shop_session]

        live_session :phoenix_kit_shop_public,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}] do
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
    end
  end
end
