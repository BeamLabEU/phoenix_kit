defmodule PhoenixKitWeb.Routes.NewslettersRoutes do
  @moduledoc """
  Newsletters module routes.

  Provides route definitions for newsletters admin interfaces and unsubscribe flow.
  Separated to improve compilation time.
  """

  @doc """
  Returns quoted code for newsletters non-LiveView routes (unsubscribe).
  """
  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through [:browser]

        get "/newsletters/unsubscribe",
            PhoenixKit.Modules.Newsletters.Web.UnsubscribeController,
            :unsubscribe

        post "/newsletters/unsubscribe",
             PhoenixKit.Modules.Newsletters.Web.UnsubscribeController,
             :process_unsubscribe
      end
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for inclusion in the shared admin live_session.
  """
  def admin_routes do
    quote do
      live "/admin/newsletters/broadcasts",
           PhoenixKit.Modules.Newsletters.Web.Broadcasts,
           :index,
           as: :newsletters_broadcasts

      live "/admin/newsletters/broadcasts/new",
           PhoenixKit.Modules.Newsletters.Web.BroadcastEditor,
           :new,
           as: :newsletters_broadcast_new

      live "/admin/newsletters/broadcasts/:id/edit",
           PhoenixKit.Modules.Newsletters.Web.BroadcastEditor,
           :edit,
           as: :newsletters_broadcast_edit

      live "/admin/newsletters/broadcasts/:id",
           PhoenixKit.Modules.Newsletters.Web.BroadcastDetails,
           :show,
           as: :newsletters_broadcast_details

      live "/admin/newsletters/lists",
           PhoenixKit.Modules.Newsletters.Web.Lists,
           :index,
           as: :newsletters_lists

      live "/admin/newsletters/lists/new",
           PhoenixKit.Modules.Newsletters.Web.ListEditor,
           :new,
           as: :newsletters_list_new

      live "/admin/newsletters/lists/:id/edit",
           PhoenixKit.Modules.Newsletters.Web.ListEditor,
           :edit,
           as: :newsletters_list_edit

      live "/admin/newsletters/lists/:id/members",
           PhoenixKit.Modules.Newsletters.Web.ListMembers,
           :index,
           as: :newsletters_list_members
    end
  end
end
