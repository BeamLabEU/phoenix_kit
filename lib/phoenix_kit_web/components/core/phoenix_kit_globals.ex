defmodule PhoenixKitWeb.Components.Core.PhoenixKitGlobals do
  @moduledoc """
  Component that sets PhoenixKit JavaScript global variables.

  This ensures a single source of truth for all PhoenixKit globals
  across different layouts (admin, dashboard, root).

  ## Globals Set

  - `window.PHOENIX_KIT_PREFIX` - URL prefix for PhoenixKit routes

  ## Usage

      <PhoenixKitWeb.Components.Core.PhoenixKitGlobals.phoenix_kit_globals />
  """
  use Phoenix.Component

  @doc """
  Renders script tags that set PhoenixKit global variables.
  """
  def phoenix_kit_globals(assigns) do
    ~H"""
    <script>
      window.PHOENIX_KIT_PREFIX = "{PhoenixKit.Utils.Routes.url_prefix()}";
    </script>
    """
  end
end
