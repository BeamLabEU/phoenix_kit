defmodule PhoenixKitWeb.Routes.PublishingRoutes do
  @moduledoc """
  Publishing module routes.

  Provides route definitions for blog/content management including
  both new publishing routes and legacy blogging redirects.
  """

  @doc """
  Returns quoted code for publishing routes.
  """
  def generate(url_prefix) do
    quote do
      # Localized publishing routes
      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_publishing_localized,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
            as: :publishing_index_localized

          live "/admin/publishing/:blog", PhoenixKit.Modules.Publishing.Web.Listing, :blog,
            as: :publishing_blog_localized

          live "/admin/publishing/:blog/edit", PhoenixKit.Modules.Publishing.Web.Editor, :edit,
            as: :publishing_editor_localized

          live "/admin/publishing/:blog/preview",
               PhoenixKit.Modules.Publishing.Web.Preview,
               :preview,
               as: :publishing_preview_localized

          live "/admin/settings/publishing", PhoenixKit.Modules.Publishing.Web.Settings, :index,
            as: :publishing_settings_localized

          live "/admin/settings/publishing/new", PhoenixKit.Modules.Publishing.Web.New, :new,
            as: :publishing_new_localized

          live "/admin/settings/publishing/:blog/edit",
               PhoenixKit.Modules.Publishing.Web.Edit,
               :edit,
               as: :publishing_edit_localized
        end
      end

      # Non-localized publishing routes
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        live_session :phoenix_kit_publishing,
          on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}] do
          live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
            as: :publishing_index

          live "/admin/publishing/:blog", PhoenixKit.Modules.Publishing.Web.Listing, :blog,
            as: :publishing_blog

          live "/admin/publishing/:blog/edit", PhoenixKit.Modules.Publishing.Web.Editor, :edit,
            as: :publishing_editor

          live "/admin/publishing/:blog/preview",
               PhoenixKit.Modules.Publishing.Web.Preview,
               :preview,
               as: :publishing_preview

          live "/admin/settings/publishing", PhoenixKit.Modules.Publishing.Web.Settings, :index,
            as: :publishing_settings

          live "/admin/settings/publishing/new", PhoenixKit.Modules.Publishing.Web.New, :new,
            as: :publishing_new

          live "/admin/settings/publishing/:blog/edit",
               PhoenixKit.Modules.Publishing.Web.Edit,
               :edit,
               as: :publishing_edit
        end
      end

      # Legacy blogging redirects (localized)
      alias PhoenixKitWeb.Controllers.Redirects.PublishingRedirectController

      scope "#{unquote(url_prefix)}/:locale" do
        pipe_through [:browser]
        get "/admin/blogging", PublishingRedirectController, :index
        get "/admin/blogging/:blog", PublishingRedirectController, :blog
        get "/admin/blogging/:blog/edit", PublishingRedirectController, :edit
        get "/admin/blogging/:blog/preview", PublishingRedirectController, :preview
        get "/admin/settings/blogging", PublishingRedirectController, :settings
        get "/admin/settings/blogging/new", PublishingRedirectController, :new
        get "/admin/settings/blogging/:blog/edit", PublishingRedirectController, :settings_edit
      end

      # Legacy blogging redirects (non-localized)
      scope unquote(url_prefix) do
        pipe_through [:browser]
        get "/admin/blogging", PublishingRedirectController, :index
        get "/admin/blogging/:blog", PublishingRedirectController, :blog
        get "/admin/blogging/:blog/edit", PublishingRedirectController, :edit
        get "/admin/blogging/:blog/preview", PublishingRedirectController, :preview
        get "/admin/settings/blogging", PublishingRedirectController, :settings
        get "/admin/settings/blogging/new", PublishingRedirectController, :new
        get "/admin/settings/blogging/:blog/edit", PublishingRedirectController, :settings_edit
      end
    end
  end
end
