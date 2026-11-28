defmodule PhoenixKitWeb.Test.PageAttrHostLayout do
  @moduledoc """
  Stand-in for a host app's `Layouts` module whose `:app` layout declares an
  attr named like an assign kit pages commonly set: `:page`. Here it means the
  host's own nav section (an atom), where a kit list page uses `:page` for its
  pagination number (an integer) — the collision reported from a host in
  2026-09.

  `nav_label/1` only accepts the host's atoms, so if the kit ever handed the
  layout its page's own `:page`, the render would raise `FunctionClauseError`
  exactly as a real host layout would.

  `capture/1` (the `:capture` layout) sends the assigns it was called with to
  the calling process, so a test can pin exactly what a host layout receives.

  Backs `test/phoenix_kit_web/components/layout_wrapper_host_assigns_test.exs`.
  """
  use Phoenix.Component

  attr :flash, :map, default: %{}
  attr :page, :atom, default: :home, values: [:home, :pricing, :about]
  attr :current_scope, :any, default: nil
  slot :inner_block

  def app(assigns) do
    ~H"""
    <div id="host-shell" data-host-page={nav_label(assigns[:page] || :home)}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  def capture(assigns) do
    send(self(), {:host_layout_assigns, assigns})

    ~H"""
    <div id="host-shell">{@inner_content}</div>
    """
  end

  defp nav_label(:home), do: "home"
  defp nav_label(:pricing), do: "pricing"
  defp nav_label(:about), do: "about"
end
