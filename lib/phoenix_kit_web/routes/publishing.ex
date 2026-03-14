defmodule PhoenixKitWeb.Routes.PublishingRoutes do
  @moduledoc """
  Publishing module routes.

  Provides route definitions for content management (publishing groups and posts).
  """

  @doc """
  Returns quoted code for publishing non-LiveView routes.
  Currently a no-op — reserved for future non-LiveView routes.
  """
  def generate(_url_prefix) do
    quote do
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (localized).
  """
  def admin_locale_routes do
    quote do
      live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
        as: :publishing_index_localized

      # Literal path routes MUST come before :group param routes
      live "/admin/publishing/new-group", PhoenixKit.Modules.Publishing.Web.New, :new,
        as: :publishing_new_group_localized

      live "/admin/publishing/edit-group/:group",
           PhoenixKit.Modules.Publishing.Web.Edit,
           :edit,
           as: :publishing_edit_group_localized

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
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for the shared admin live_session (non-localized).
  """
  def admin_routes do
    quote do
      live "/admin/publishing", PhoenixKit.Modules.Publishing.Web.Index, :index,
        as: :publishing_index

      # Literal path routes MUST come before :group param routes
      live "/admin/publishing/new-group", PhoenixKit.Modules.Publishing.Web.New, :new,
        as: :publishing_new_group

      live "/admin/publishing/edit-group/:group",
           PhoenixKit.Modules.Publishing.Web.Edit,
           :edit,
           as: :publishing_edit_group

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
    end
  end
end
