defmodule PhoenixKitWeb.Routes.PublishingRoutes do
  @moduledoc """
  Publishing module routes.

  Provides route definitions for blog/content management including
  both new publishing routes and legacy blogging redirects.
  """

  @doc """
  Returns quoted code for publishing non-LiveView routes (legacy redirects).
  """
  def generate(url_prefix) do
    quote do
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

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (localized).
  """
  def admin_locale_routes do
    quote do
      live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
        as: :publishing_index_localized

      live "/admin/publishing/:group", PhoenixKit.Modules.Publishing.Web.Listing, :group,
        as: :publishing_group_localized

      live "/admin/publishing/:group/edit", PhoenixKit.Modules.Publishing.Web.Editor, :edit,
        as: :publishing_editor_localized

      live "/admin/publishing/:group/new", PhoenixKit.Modules.Publishing.Web.Editor, :new,
        as: :publishing_new_post_localized

      live "/admin/publishing/:group/preview",
           PhoenixKit.Modules.Publishing.Web.Preview,
           :preview,
           as: :publishing_preview_localized

      # UUID-based routes (param routes — must come AFTER literal routes above)
      live "/admin/publishing/:group/:post_uuid",
           PhoenixKit.Modules.Publishing.Web.PostShow,
           :show,
           as: :publishing_post_show_localized

      live "/admin/publishing/:group/:post_uuid/edit",
           PhoenixKit.Modules.Publishing.Web.Editor,
           :edit_post,
           as: :publishing_post_editor_localized

      live "/admin/publishing/:group/:post_uuid/preview",
           PhoenixKit.Modules.Publishing.Web.Preview,
           :preview_post,
           as: :publishing_post_preview_localized

      live "/admin/settings/publishing", PhoenixKit.Modules.Publishing.Web.Settings, :index,
        as: :publishing_settings_localized

      live "/admin/settings/publishing/new", PhoenixKit.Modules.Publishing.Web.New, :new,
        as: :publishing_new_localized

      live "/admin/settings/publishing/:group/edit",
           PhoenixKit.Modules.Publishing.Web.Edit,
           :edit,
           as: :publishing_edit_localized
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (non-localized).
  """
  def admin_routes do
    quote do
      live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
        as: :publishing_index

      live "/admin/publishing/:group", PhoenixKit.Modules.Publishing.Web.Listing, :group,
        as: :publishing_group

      live "/admin/publishing/:group/edit", PhoenixKit.Modules.Publishing.Web.Editor, :edit,
        as: :publishing_editor

      live "/admin/publishing/:group/new", PhoenixKit.Modules.Publishing.Web.Editor, :new,
        as: :publishing_new_post

      live "/admin/publishing/:group/preview",
           PhoenixKit.Modules.Publishing.Web.Preview,
           :preview,
           as: :publishing_preview

      # UUID-based routes (param routes — must come AFTER literal routes above)
      live "/admin/publishing/:group/:post_uuid",
           PhoenixKit.Modules.Publishing.Web.PostShow,
           :show,
           as: :publishing_post_show

      live "/admin/publishing/:group/:post_uuid/edit",
           PhoenixKit.Modules.Publishing.Web.Editor,
           :edit_post,
           as: :publishing_post_editor

      live "/admin/publishing/:group/:post_uuid/preview",
           PhoenixKit.Modules.Publishing.Web.Preview,
           :preview_post,
           as: :publishing_post_preview

      live "/admin/settings/publishing", PhoenixKit.Modules.Publishing.Web.Settings, :index,
        as: :publishing_settings

      live "/admin/settings/publishing/new", PhoenixKit.Modules.Publishing.Web.New, :new,
        as: :publishing_new

      live "/admin/settings/publishing/:group/edit",
           PhoenixKit.Modules.Publishing.Web.Edit,
           :edit,
           as: :publishing_edit
    end
  end
end
