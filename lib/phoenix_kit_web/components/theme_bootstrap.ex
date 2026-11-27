defmodule PhoenixKitWeb.Components.ThemeBootstrap do
  @moduledoc """
  The pre-paint theme setup — palettes plus the stamp script — renders in
  `<head>`, before (or with) the stylesheets.

  Every page class had its own first-paint story and most of them flashed:
  the dashboard's `<html>` carried no `data-theme` and applied the saved one
  from a script at the end of `<body>`; the standalone admin hardcoded
  `data-theme="light"` and fixed it up on DOMContentLoaded; the kit's own
  root layout hardcoded light and ran no theme JS at all. A dark-mode user
  got a white flash on the first two and permanent light on the third.

  This component is the one shared answer: the custom-theme `<style>`
  (phoenix-* plus host `:theme_definitions`) plus a synchronous script that
  reads the saved choice, resolves `"system"` from `ThemeConfig.system_pair/0`
  — the CONFIGURED pair, not hardcoded `phoenix-*` names — and stamps
  `data-theme` plus `color-scheme` on `<html>` before the first paint, and
  the saved choice itself as `data-theme-choice` (`"system"` or a theme's
  name), which the inline picker's CSS marks the chosen button from. The
  palettes travel with the stamp: a script-only bootstrap on a host layout
  (or the standalone admin shell) used to paint `phoenix-dark` +
  `color-scheme: dark` over daisyUI's light variables until a later `<style>`
  in the body arrived.

  It also subscribes to the `storage` event, so a theme picked in one tab
  follows into the others.

  Host root layouts can render it too (`PhoenixKitWeb.Components.ThemeBootstrap`
  is public API); a host with its own equivalent script loses nothing by
  keeping it.
  """

  use Phoenix.Component

  alias PhoenixKit.ThemeConfig

  @doc """
  The blocking head setup (palettes + stamp script). Render in `<head>`.
  """
  def theme_bootstrap(assigns) do
    {light, dark} = ThemeConfig.system_pair()

    assigns =
      assigns
      |> assign(:light, light)
      |> assign(:dark, dark)
      |> assign(:custom_css, ThemeConfig.custom_theme_css())
      |> assign(
        :base_map_json,
        # :html_safe escapes < and > so no config-derived name can close
        # this <script> tag. Names are validated upstream too; this is the
        # sink-side half of that defense.
        Jason.encode!(ThemeConfig.base_map(), escape: :html_safe)
      )

    ~H"""
    <style nonce={PhoenixKitWeb.CSP.nonce(:style)} data-phoenix-kit-themes>
      <%= Phoenix.HTML.raw(@custom_css) %>
    </style>
    <script nonce={PhoenixKitWeb.CSP.nonce(:script)}>
      (function () {
        // One instance per page — a host layout and a kit layout can
        // both render this; a second copy would double the storage listener.
        if (window.__pkThemeBootstrap) return;
        window.__pkThemeBootstrap = true;

        var KEY = 'phx:theme';
        var LEGACY_KEY = 'phoenix_kit_theme';
        var LIGHT = '<%= @light %>';
        var DARK = '<%= @dark %>';
        var BASES = <%= Phoenix.HTML.raw(@base_map_json) %>;

        function resolve(theme) {
          if (!theme || theme === 'system') {
            return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches
              ? DARK
              : LIGHT;
          }
          return theme;
        }

        function apply(theme) {
          var resolved = resolve(theme);
          var el = document.documentElement;
          el.setAttribute('data-theme', resolved);
          // The saved CHOICE next to the theme in effect: a picker that lists
          // "system" beside the themes marks the chosen one with CSS from this.
          el.setAttribute('data-theme-choice', theme && theme !== 'system' ? theme : 'system');
          el.style.colorScheme = BASES[resolved] || 'light';
        }

        var saved = null;
        try {
          saved = localStorage.getItem(KEY);
          // The deleted static phoenix_kit_themes.js wrote this older key.
          // Promote it once so an upgrade does not reset the saved choice.
          if (!saved) {
            var legacy = localStorage.getItem(LEGACY_KEY);
            if (legacy) {
              saved = legacy;
              localStorage.setItem(KEY, legacy);
            }
          }
        } catch (e) {
          /* storage blocked: fall through to system */
        }

        apply(saved);

        // A theme picked in another tab follows into this one.
        window.addEventListener('storage', function (e) {
          if (e.key === KEY || e.key === LEGACY_KEY) apply(e.newValue);
        });
      })();
    </script>
    """
  end
end
