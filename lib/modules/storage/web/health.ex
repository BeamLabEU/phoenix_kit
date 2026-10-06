defmodule PhoenixKitWeb.Live.Modules.Storage.Health do
  @moduledoc """
  The old address of the media health dashboard
  (`/admin/settings/media/health`), which is now the Health tab of Settings →
  Media (`HealthComponent`). It only sends a saved link there.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: Routes.path("/admin/settings/media?tab=health"))}
  end

  def render(assigns), do: ~H""
end
