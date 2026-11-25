defmodule PhoenixKitWeb.Components.Core.ThemeControllerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.ThemeController

  defp render_picker(themes) do
    render_component(&ThemeController.theme_controller/1, themes: themes, id: "t")
  end

  describe "exactly two concrete themes" do
    test "renders a toggle, not a dropdown" do
      html = render_picker(["phoenix-light", "phoenix-dark"])

      assert html =~ ~s(data-theme-role="toggle")
      refute html =~ ~s(data-theme-role="dropdown-option")
    end

    test "one persistent button — activating it never removes the focused element" do
      html = render_picker(["phoenix-light", "phoenix-dark"])

      # The first design hid the active theme's button, which dropped keyboard
      # focus to <body> on every activation. One button, aria-pressed, both
      # icons present with one hidden.
      assert length(String.split(html, "<button")) == 2
      assert html =~ ~s(aria-pressed="false")
      assert html =~ "hero-sun"
      assert html =~ "hero-moon"
      assert html =~ ~s(data-theme-light="phoenix-light")
      assert html =~ ~s(data-theme-dark="phoenix-dark")
      assert html =~ ~s(data-phx-theme="phoenix-dark")
    end

    test "the click is a real dispatch, not a kit-script-only listener" do
      # Same phx:set-theme + data-phx-theme contract as the dropdown options
      # and the stock Phoenix root-layout script — so the toggle works in
      # host layouts that never render ThemeControllerScript. Without this
      # the button was silently dead outside the kit's own layouts.
      html = render_picker(["phoenix-light", "phoenix-dark"])

      assert html =~ "phx-click"
      assert html =~ "phx:set-theme"
    end

    test "order in the config does not decide which half is dark" do
      html = render_picker(["phoenix-dark", "phoenix-light"])

      assert html =~ ~s(data-theme-dark="phoenix-dark")
      assert html =~ ~s(data-theme-light="phoenix-light")
    end
  end

  describe "mode attr" do
    defp render_mode(themes, mode) do
      render_component(&ThemeController.theme_controller/1,
        themes: themes,
        mode: mode,
        id: "t"
      )
    end

    test ":dropdown forces the menu even for a pair" do
      html = render_mode(["phoenix-light", "phoenix-dark"], :dropdown)

      assert html =~ ~s(data-theme-role="dropdown-option")
      refute html =~ ~s(data-theme-role="toggle")
    end

    test ":toggle raises unless the list is exactly two concrete themes" do
      assert_raise ArgumentError, ~r/needs exactly two concrete themes/, fn ->
        render_mode(["system", "phoenix-light", "phoenix-dark"], :toggle)
      end
    end

    test "the toggle's style tag carries the page's nonce, never a literal expression" do
      html = render_mode(["phoenix-light", "phoenix-dark"], :toggle)
      assert html =~ "<style>"
      refute html =~ "PhoenixKitWeb.CSP"

      Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :csp_nonce_assign_key) end)

      PhoenixKitWeb.CSP.put_nonces(
        Plug.Conn.assign(Phoenix.ConnTest.build_conn(), :csp_nonce, "n1")
      )

      assert render_mode(["phoenix-light", "phoenix-dark"], :toggle) =~ ~s(<style nonce="n1">)
    end

    test ":toggle on a pair renders the toggle" do
      html = render_mode(["phoenix-light", "phoenix-dark"], :toggle)

      assert html =~ ~s(data-theme-role="toggle")
    end
  end

  describe "a same-base pair is not a toggle" do
    test ":auto falls back to the dropdown for two lights" do
      # Sun/moon icons and aria-pressed "dark on" semantics are false over
      # two themes of the same base.
      html = render_picker(["light", "cupcake"])

      assert html =~ ~s(data-theme-role="dropdown-option")
      refute html =~ ~s(data-theme-role="toggle")
    end

    test ":toggle raises for two darks" do
      assert_raise ArgumentError, ~r/one light and one dark/, fn ->
        render_component(&ThemeController.theme_controller/1,
          themes: ["dark", "night"],
          mode: :toggle,
          id: "t"
        )
      end
    end
  end

  describe "toggle icon visibility is CSS, correct from first paint" do
    test "renders rules keyed off html[data-theme], scoped to the pair" do
      # The JS-swapped version flashed the sun at dark-mode users until the
      # end-of-body script initialized; CSS keyed off the pre-paint stamp
      # cannot be wrong. Scoped by [data-theme-dark] so multiple toggles
      # coexist without id requirements.
      html = render_picker(["phoenix-light", "phoenix-dark"])

      assert html =~
               "html[data-theme=\"phoenix-dark\"] [data-theme-dark=\"phoenix-dark\"] [data-toggle-icon=\"light\"]"

      assert html =~ "html:not([data-theme=\"phoenix-dark\"])"
      # neither icon is JS-hidden anymore
      refute html =~ "data-toggle-icon=\"dark\" class=\"hidden\""
    end
  end

  describe "anything other than a pure pair keeps the dropdown" do
    test "three themes" do
      html = render_picker(["phoenix-light", "phoenix-dark", "nord"])

      assert html =~ ~s(data-theme-role="dropdown-option")
      refute html =~ ~s(data-theme-role="toggle")
    end

    test "dropdown options carry data-phx-theme so a stock phx:theme script works" do
      # The toggle had this; the options only put the name in JS.dispatch
      # detail. phx.new 1.8's script reads e.target.dataset.phxTheme and
      # falls back to "system" — every dropdown click would reset the theme
      # on a host that kept that script.
      html = render_picker(["phoenix-light", "nord", "dracula"])

      assert html =~ ~s(data-phx-theme="phoenix-light")
      assert html =~ ~s(data-phx-theme="nord")
      assert html =~ ~s(data-phx-theme="dracula")
    end

    test "a pair plus system — three states need a menu" do
      html = render_picker(["system", "phoenix-light", "phoenix-dark"])

      assert html =~ ~s(data-theme-role="dropdown-option")
      refute html =~ ~s(data-theme-role="toggle")
    end

    test ":all" do
      html = render_picker(:all)

      assert html =~ ~s(data-theme-role="dropdown-option")
    end

    test "a single theme is not a toggle either" do
      html = render_picker(["phoenix-dark"])

      assert html =~ ~s(data-theme-role="dropdown-option")
    end
  end
end
