defmodule PhoenixKitWeb.Routes.EmailsRoutes do
  @moduledoc """
  Email module routes.

  Provides route definitions for email webhooks, exports, and admin interfaces.
  Separated to improve compilation time.
  """

  @doc """
  Returns quoted code for email non-LiveView routes (webhooks, exports).
  """
  def generate(url_prefix) do
    quote do
      # Email webhook endpoint (public - no authentication required)
      scope unquote(url_prefix) do
        pipe_through [:browser]

        post "/webhooks/email", PhoenixKit.Modules.Emails.Web.WebhookController, :handle
      end

      # Email export routes (require admin or owner role)
      scope unquote(url_prefix) do
        pipe_through [:browser, :phoenix_kit_auto_setup, :phoenix_kit_admin_only]

        get "/admin/emails/export", PhoenixKit.Modules.Emails.Web.ExportController, :export_logs

        get "/admin/emails/metrics/export",
            PhoenixKit.Modules.Emails.Web.ExportController,
            :export_metrics

        get "/admin/emails/blocklist/export",
            PhoenixKit.Modules.Emails.Web.ExportController,
            :export_blocklist

        get "/admin/emails/:id/export",
            PhoenixKit.Modules.Emails.Web.ExportController,
            :export_email_details
      end
    end
  end

  @doc """
  Returns quoted admin LiveView route declarations for inclusion in the shared admin live_session.
  """
  def admin_routes do
    quote do
      live "/admin/settings/emails", PhoenixKit.Modules.Emails.Web.Settings, :index,
        as: :emails_settings

      live "/admin/emails/dashboard", PhoenixKit.Modules.Emails.Web.Metrics, :index,
        as: :emails_metrics

      live "/admin/emails", PhoenixKit.Modules.Emails.Web.Emails, :index, as: :emails_index

      live "/admin/emails/email/:id", PhoenixKit.Modules.Emails.Web.Details, :show,
        as: :emails_details

      live "/admin/emails/queue", PhoenixKit.Modules.Emails.Web.Queue, :index, as: :emails_queue

      live "/admin/emails/blocklist", PhoenixKit.Modules.Emails.Web.Blocklist, :index,
        as: :emails_blocklist

      live "/admin/modules/emails/templates", PhoenixKit.Modules.Emails.Web.Templates, :index,
        as: :emails_templates

      live "/admin/modules/emails/templates/new",
           PhoenixKit.Modules.Emails.Web.TemplateEditor,
           :new,
           as: :emails_template_new

      live "/admin/modules/emails/templates/:id/edit",
           PhoenixKit.Modules.Emails.Web.TemplateEditor,
           :edit,
           as: :emails_template_edit
    end
  end
end
