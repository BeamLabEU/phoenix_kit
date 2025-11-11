defmodule PhoenixKitWeb.Components.Core.MaintenancePage do
  @moduledoc """
  Displays a full-page maintenance message.

  This component is shown to non-admin users when the Maintenance
  module is enabled, replacing the normal page content.
  """

  use Phoenix.Component
  use PhoenixKitWeb, :verified_routes

  alias PhoenixKit.Modules.Maintenance

  @doc """
  Renders a full-page maintenance message.

  ## Attributes
  - `header` - Main heading text (default: loaded from settings)
  - `subtext` - Descriptive text (default: loaded from settings)

  ## Examples

      <.maintenance_page />
      <.maintenance_page header="Coming Soon" subtext="Check back later!" />
  """
  attr :header, :string, default: nil
  attr :subtext, :string, default: nil

  def maintenance_page(assigns) do
    # Load from settings if not provided
    assigns =
      assigns
      |> assign_new(:header, fn ->
        Maintenance.get_header()
      end)
      |> assign_new(:subtext, fn ->
        Maintenance.get_subtext()
      end)

    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>{@header}</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
      </head>
      <body class="h-full bg-base-200">
        <div class="flex items-center justify-center min-h-screen p-4">
          <div class="card bg-base-100 shadow-2xl border-2 border-dashed border-base-300 max-w-2xl w-full">
            <div class="card-body text-center py-12 px-6">
              <%!-- Icon --%>
              <div class="text-8xl mb-6 opacity-70">
                🚧
              </div>
              <%!-- Header --%>
              <h1 class="text-5xl font-bold text-base-content mb-6">
                {@header}
              </h1>
              <%!-- Subtext --%>
              <p class="text-xl text-base-content/70 mb-8 leading-relaxed">
                {@subtext}
              </p>
            </div>
          </div>
        </div>
      </body>
    </html>
    """
  end

  defp get_csrf_token, do: Phoenix.Controller.get_csrf_token()
end
