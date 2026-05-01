defmodule PhoenixKitWeb.Components.Core.PhoenixKitFavicon do
  @moduledoc """
  Renders a `<link rel="icon">` tag driven by the PhoenixKit `site_icon_file_uuid`
  setting.

  Parent applications should include this component inside their root layout's
  `<head>` so the site icon uploaded via PhoenixKit Settings actually reaches
  the browser tab. PhoenixKit's standalone admin layout already includes it.

  If the setting is empty, the component renders nothing so the parent app's
  static favicon keeps working.

  ## Usage

      <head>
        ...
        <PhoenixKitWeb.Components.Core.PhoenixKitFavicon.phoenix_kit_favicon />
      </head>
  """

  use Phoenix.Component

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings

  attr :variant, :string,
    default: "thumbnail",
    doc: "Storage variant name to serve as favicon (defaults to `thumbnail`)"

  attr :type, :string,
    default: "image/png",
    doc: "MIME type emitted on the <link> tag"

  def phoenix_kit_favicon(assigns) do
    site_icon_uuid = Settings.get_setting_cached("site_icon_file_uuid", "")

    assigns = assign(assigns, :site_icon_uuid, site_icon_uuid)

    ~H"""
    <%= if @site_icon_uuid != "" do %>
      <link rel="icon" type={@type} href={URLSigner.signed_url(@site_icon_uuid, @variant)} />
    <% end %>
    """
  end
end
