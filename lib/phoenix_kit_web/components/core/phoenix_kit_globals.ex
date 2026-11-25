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

  ## Form controls on phones

  iOS zooms the page when a form control under 16px takes focus, and every
  daisyUI control is smaller (`input-sm` more so). A style here lifts
  controls to at least 16px on touch screens under 768px — only inside the
  kit's own markup (the admin drawer and pages marked `data-phoenix-kit`),
  never a host's page. The rule is `max(16px, 1em)`, and `1em` in a
  `font-size` is the *parent's* size, not the control's own: a control whose
  own size is above both (`input-lg`, `text-xl`) is brought down to that
  floor too, and the rule beats a utility class, so it cannot be opted out
  of from the markup. A kit page rendered inside the host's own layout gets neither
  this component nor a kit `<body>`, so `LayoutWrapper` wraps its content in
  a `display: contents` marker carrying `mobile_inputs_style/1` itself.

  ## Usage

      <PhoenixKitWeb.Components.Core.PhoenixKitGlobals.phoenix_kit_globals />
  """
  use Phoenix.Component

  alias PhoenixKit.Utils.Routes

  @doc """
  Renders script tags that set PhoenixKit global variables and clear
  any cached transport fallback preferences.
  """
  attr :rest, :global

  def phoenix_kit_globals(assigns) do
    prefix = Routes.url_prefix()

    assigns = assign(assigns, :prefix, prefix)

    ~H"""
    <.mobile_inputs_style />
    <script nonce={PhoenixKitWeb.CSP.nonce(:script)}>
      window.PHOENIX_KIT_PREFIX = "<%= @prefix %>";
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

  @doc """
  The phone form-control style on its own (see "Form controls on phones"),
  for markup that is the kit's but is not under a kit layout.
  """
  def mobile_inputs_style(assigns) do
    ~H"""
    <style nonce={PhoenixKitWeb.CSP.nonce(:style)} data-pk-mobile-inputs>
      @media (pointer: coarse) and (max-width: 767px) {
        :is(#admin-drawer, [data-phoenix-kit]) :is(input:not([type=checkbox], [type=radio], [type=range], [type=file], [type=color], [type=hidden]), select, textarea) {
          font-size: max(16px, 1em);
        }
      }
    </style>
    """
  end
end
