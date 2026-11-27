defmodule PhoenixKitWeb.Components.ThemeBootstrapTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.ThemeBootstrap

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit, :dashboard_themes) end)
  end

  defp render_bootstrap do
    render_component(&ThemeBootstrap.theme_bootstrap/1, %{})
  end

  test "resolves system from the CONFIGURED pair, not hardcoded phoenix-*" do
    # Hardcoding broke system resolution for any host whose pair uses other
    # names — this is the regression the component exists to prevent.
    Application.put_env(:phoenix_kit, :dashboard_themes, ["light", "dark"])

    html = render_bootstrap()

    assert html =~ ~s(var LIGHT = 'light')
    assert html =~ ~s(var DARK = 'dark')
  end

  test "falls back to the built-ins when nothing is configured" do
    html = render_bootstrap()

    assert html =~ ~s(var LIGHT = 'phoenix-light')
    assert html =~ ~s(var DARK = 'phoenix-dark')
  end

  test "a half-configured pair keeps the built-in for the missing half" do
    Application.put_env(:phoenix_kit, :dashboard_themes, ["dark"])

    html = render_bootstrap()

    assert html =~ ~s(var LIGHT = 'phoenix-light')
    assert html =~ ~s(var DARK = 'dark')
  end

  test "reads the shared storage key and syncs across tabs" do
    html = render_bootstrap()

    assert html =~ "phx:theme"
    assert html =~ "addEventListener('storage'"
  end

  test "ships the custom-theme palettes next to the stamp" do
    # A script-only bootstrap on a host layout stamped phoenix-dark
    # before any [data-theme=phoenix-dark] variables existed.
    html = render_bootstrap()

    assert html =~ ~s(data-phoenix-kit-themes)
    assert html =~ "[data-theme=phoenix-dark]"
    assert html =~ "--color-base-100"
  end

  test "promotes the legacy phoenix_kit_theme storage key" do
    html = render_bootstrap()

    assert html =~ "phoenix_kit_theme"
  end

  test "is idempotent when two layouts render it" do
    html = render_bootstrap()

    assert html =~ "window.__pkThemeBootstrap"
  end

  test "unknown configured names cannot smuggle script out through the pair" do
    # system_pair filters to KNOWN names, so config junk never reaches the
    # inline script.
    Application.put_env(:phoenix_kit, :dashboard_themes, ["'\"><script>x</script>"])

    html = render_bootstrap()

    assert html =~ ~s(var LIGHT = 'phoenix-light')
    refute html =~ "<script>x</script>"
  end

  test "stamps the saved choice next to the theme in effect" do
    # What the inline picker's CSS marks the chosen button from: "system" when
    # nothing is saved, else the saved theme's name.
    html = render_bootstrap()

    assert html =~ "data-theme-choice"
    assert html =~ "theme && theme !== 'system' ? theme : 'system'"
  end
end
