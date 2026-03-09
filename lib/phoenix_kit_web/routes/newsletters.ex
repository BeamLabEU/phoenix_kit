defmodule PhoenixKitWeb.Routes.MailingRoutes do
  @moduledoc """
  Mailing module routes.

  Provides route definitions for mailing admin interfaces and unsubscribe flow.
  Separated to improve compilation time.
  """

  @doc """
  Returns quoted code for mailing non-LiveView routes (unsubscribe).
  """
  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through [:browser]

        get "/mailing/unsubscribe",
            PhoenixKit.Modules.Mailing.Web.UnsubscribeController,
            :unsubscribe

        post "/mailing/unsubscribe",
             PhoenixKit.Modules.Mailing.Web.UnsubscribeController,
             :process_unsubscribe
      end
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for inclusion in the shared admin live_session.
  """
  def admin_routes do
    quote do
      live "/admin/mailing/broadcasts", PhoenixKit.Modules.Mailing.Web.Broadcasts, :index,
        as: :mailing_broadcasts

      live "/admin/mailing/broadcasts/new", PhoenixKit.Modules.Mailing.Web.BroadcastEditor, :new,
        as: :mailing_broadcast_new

      live "/admin/mailing/broadcasts/:id/edit",
           PhoenixKit.Modules.Mailing.Web.BroadcastEditor,
           :edit,
           as: :mailing_broadcast_edit

      live "/admin/mailing/broadcasts/:id",
           PhoenixKit.Modules.Mailing.Web.BroadcastDetails,
           :show,
           as: :mailing_broadcast_details

      live "/admin/mailing/lists", PhoenixKit.Modules.Mailing.Web.Lists, :index,
        as: :mailing_lists

      live "/admin/mailing/lists/new", PhoenixKit.Modules.Mailing.Web.ListEditor, :new,
        as: :mailing_list_new

      live "/admin/mailing/lists/:id/edit", PhoenixKit.Modules.Mailing.Web.ListEditor, :edit,
        as: :mailing_list_edit

      live "/admin/mailing/lists/:id/members", PhoenixKit.Modules.Mailing.Web.ListMembers, :index,
        as: :mailing_list_members
    end
  end
end
