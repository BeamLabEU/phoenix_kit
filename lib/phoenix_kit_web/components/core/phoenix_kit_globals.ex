defmodule PhoenixKitWeb.Components.Core.PhoenixKitGlobals do
  @moduledoc """
  Component that sets PhoenixKit JavaScript global variables.

  This ensures a single source of truth for all PhoenixKit globals
  across different layouts (admin, dashboard, root).

  ## Globals Set

  - `window.PHOENIX_KIT_PREFIX` - URL prefix for PhoenixKit routes

  ## Transport Cache Clearing

  Phoenix LiveView caches transport fallback preferences (WebSocket → LongPoll)
  in browser storage. If WebSocket fails once, the browser permanently uses
  LongPoll for all subsequent page loads — even after the issue is resolved.

  LongPoll causes duplicate LiveView mounts on page refresh due to stale HTTP
  requests from previous pages completing on the server after navigation.

  The inline script clears this cache on every page load so WebSocket is always
  tried first, providing clean disconnect semantics and preventing double mounts.

  ## Usage

      <PhoenixKitWeb.Components.Core.PhoenixKitGlobals.phoenix_kit_globals />
  """
  use Phoenix.Component

  @doc """
  Renders script tags that set PhoenixKit global variables and clear
  any cached transport fallback preferences.
  """
  attr :rest, :global

  def phoenix_kit_globals(assigns) do
    ~H"""
    <script>
      window.PHOENIX_KIT_PREFIX = "{PhoenixKit.Utils.Routes.url_prefix()}";
      try{["localStorage","sessionStorage"].forEach(function(s){var t=window[s];Object.keys(t).filter(function(k){return k.indexOf("phx")!==-1&&k.indexOf("phx:")!==0}).forEach(function(k){t.removeItem(k)})})}catch(e){}
      // Suppress topbar on initial WebSocket connect — the dead render already shows
      // all content, so the connect-phase topbar is just visual noise. LiveView fires
      // page-loading-start with kind:"initial" for the connect and kind:"redirect"/"patch"
      // for actual navigations. We only suppress "initial" start events; the stop event
      // must NOT be suppressed since the topbar was never shown and suppressing stop
      // could prevent the parent app's topbar.hide() from running.
      window.addEventListener("phx:page-loading-start",function(e){if(e.detail&&e.detail.kind==="initial")e.stopImmediatePropagation()},true);
    </script>
    """
  end
end
