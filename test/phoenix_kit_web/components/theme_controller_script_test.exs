defmodule PhoenixKitWeb.Components.ThemeControllerScriptTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.ThemeControllerScript

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :dashboard_themes)
      Application.delete_env(:phoenix_kit, :theme_definitions)
      :persistent_term.erase({PhoenixKit.ThemeConfig, :theme_variables})
      :persistent_term.erase({PhoenixKit.ThemeConfig, :host_theme_meta})
    end)
  end

  defp render_script do
    render_component(&ThemeControllerScript.theme_controller_script/1, %{})
  end

  test "every data literal is generated from ThemeConfig, none hand-written" do
    # The predecessor scripts each carried their own base-map literal, which
    # drifted on every theme addition and never knew host-defined themes.
    html = render_script()

    assert html =~ ~s("phoenix-dark":"dark")
    assert html =~ ~s("phoenix-light":"light")
    # labels come from translated_label_map, not a JS-side title-caser
    assert html =~ ~s("nord":)
  end

  test "system resolves from the CONFIGURED pair, not hardcoded phoenix-*" do
    Application.put_env(:phoenix_kit, :dashboard_themes, ["light", "dark"])

    html = render_script()

    assert html =~ ~s(systemPair = { light: 'light', dark: 'dark' })
  end

  test "runs once per page even if two layouts render it" do
    html = render_script()

    assert html =~ "window.__pkThemeController"
  end

  test "falls back to the legacy phoenix_kit_theme storage key" do
    html = render_script()

    assert html =~ "phoenix_kit_theme"
  end

  test "carries every consumer the two deleted copies served" do
    html = render_script()

    # pair toggle contract (theme_controller.ex :toggle mode)
    assert html =~ "themeRole === 'toggle'"
    assert html =~ "phxTheme"
    # dropdown option indicators
    assert html =~ "themeRole === 'dropdown-option'"
    assert html =~ "data-theme-active-indicator"
    # cross-tab + OS-change + LiveView event listeners
    assert html =~ "addEventListener('storage'"
    assert html =~ "prefers-color-scheme"
    assert html =~ "phx:set-theme"
    # LiveView patches wipe client-written picker state; the script re-stamps
    assert html =~ "phx:page-loading-stop"
    # legacy host event, kept for compatibility
    assert html =~ "phx:set-admin-theme"
  end

  test "consuming a window event never re-announces it to hosts" do
    # Hosts used to hear every dropdown selection twice: once from the
    # option's own JS.dispatch bubbling, once from the script's synthetic
    # re-dispatch. Consumed events now pass announce=false.
    html = render_script()

    assert html =~ "setTheme(theme, false)"
    # the legacy phx:set-admin-theme translation is the one announced path
    assert html =~ "setTheme(e.detail.theme, true)"
  end

  test "a hostile host-theme LABEL cannot close the script tag" do
    # Labels are free text by design — the sink escapes them (:html_safe),
    # so </script> arrives as \u003C/script\u003E.
    Application.put_env(:phoenix_kit, :theme_definitions, %{
      "brand" => %{label: "</script><script>alert(1)</script>", base: :light}
    })

    html = render_script()

    refute html =~ "</script><script>"
    assert html =~ "u003C"
  end

  test "unknown configured names cannot smuggle script out through the pair" do
    Application.put_env(:phoenix_kit, :dashboard_themes, ["'\"><script>x</script>"])

    html = render_script()

    assert html =~ "systemPair = { light: 'phoenix-light', dark: 'phoenix-dark' }"
    refute html =~ "<script>x</script>"
  end

  test "keeps the saved choice stamped and tells inline options apart by it" do
    html = render_script()

    assert html =~ "setAttribute('data-theme-choice', theme)"
    # aria-pressed follows the choice, not what "system" resolves to.
    assert html =~ "inline-option"
    assert html =~ "String(targets.includes(theme))"
    # A picker patched in later asks to be synced; the script answers.
    assert html =~ "addEventListener('phoenix_kit:theme-sync'"
  end
end
