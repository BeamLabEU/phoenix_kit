defmodule PhoenixKitWeb.Live.Modules.Storage.Dimensions do
  @moduledoc """
  The old address of the rendition sets (`/admin/settings/media/dimensions`,
  `?set=<uuid>`), which is now the Renditions tab of Settings → Media
  (`RenditionsComponent`). It only sends a saved link there.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    to =
      case params["set"] do
        set when is_binary(set) and set != "" ->
          Routes.path("/admin/settings/media?tab=renditions&set=#{URI.encode_www_form(set)}")

        _ ->
          Routes.path("/admin/settings/media?tab=renditions")
      end

    {:ok, push_navigate(socket, to: to)}
  end

  def render(assigns), do: ~H""
end
