defmodule PhoenixKitWeb.Routes.BlogRoutes do
  @moduledoc """
  Blog/Publishing catch-all routes.

  Provides route definitions for serving published blog content.
  """

  @doc """
  Returns quoted code for blog catch-all routes.
  """
  def generate(url_prefix) do
    quote do
      # Multi-language blog routes with language prefix
      blog_scope_multi =
        case unquote(url_prefix) do
          "/" -> "/:language"
          prefix -> "#{prefix}/:language"
        end

      scope blog_scope_multi do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        get "/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{
            "group" => ~r/^(?!admin$|assets$|images$|fonts$|js$|css$|favicon)/,
            "language" => ~r/^[a-z]{2}$/
          }

        get "/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{
            "group" => ~r/^(?!admin$|assets$|images$|fonts$|js$|css$|favicon)/,
            "language" => ~r/^[a-z]{2}$/
          }
      end

      # Non-localized blog routes (for when url_prefix is "/")
      blog_scope_non_localized =
        case unquote(url_prefix) do
          "/" -> "/"
          prefix -> prefix
        end

      scope blog_scope_non_localized do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_locale_validation]

        get "/:group", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{"group" => ~r/^(?!admin$|assets$|images$|fonts$|js$|css$|favicon)/}

        get "/:group/*path", PhoenixKit.Modules.Publishing.Web.Controller, :show,
          constraints: %{"group" => ~r/^(?!admin$|assets$|images$|fonts$|js$|css$|favicon)/}
      end
    end
  end
end
