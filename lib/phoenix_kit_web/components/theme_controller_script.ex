defmodule PhoenixKitWeb.Components.ThemeControllerScript do
  @moduledoc """
  The one theme-controller script — the behavior behind every element the
  `PhoenixKitWeb.Components.Core.ThemeController` picker renders.

  Before this module the same behavior existed three times: a hand-written
  script in the dashboard layout, a near-copy inside the admin layout
  wrapper, and the deleted static `phoenix_kit_themes.js`. They drifted —
  the dashboard copy carried its own hardcoded base map that missed newer
  themes and could never know host-defined ones, and both resolved
  `"system"` to hardcoded `phoenix-*` names, wrong for any host whose
  configured pair uses other names (see `PhoenixKit.ThemeConfig.system_pair/0`).

  Everything data-shaped is generated from `PhoenixKit.ThemeConfig` at
  render time, so host `:theme_definitions` flow through with zero JS
  changes. The script is idempotent per page (`window.__pkThemeController`
  guard) and every DOM hook is optional — a page with no label element or
  no toggle simply skips those branches.

  Event contract: picker elements dispatch `phx:set-theme` themselves (a
  `JS.dispatch` bubbling to `window`), so hosts hear each selection exactly
  once whether or not this script is present. The script CONSUMES that
  event to persist and reflect; it re-announces only changes that did not
  arrive as a window event (the legacy `phx:set-admin-theme` translation).

  Renders at the end of `<body>`; the pre-paint half of the story is
  `PhoenixKitWeb.Components.ThemeBootstrap` in `<head>`.
  """

  use Phoenix.Component

  alias PhoenixKit.ThemeConfig

  @doc """
  The shared theme controller. Render once, at the end of `<body>`.
  """
  def theme_controller_script(assigns) do
    {light, dark} = ThemeConfig.system_pair()

    # :html_safe turns < and > into \\u003C/\\u003E so no config- or
    # translation-derived string can close this <script> tag. The theme
    # NAMES are validated upstream (ThemeConfig), but labels are free text.
    assigns =
      assigns
      |> assign(:light, light)
      |> assign(:dark, dark)
      |> assign(:base_map_json, Jason.encode!(ThemeConfig.base_map(), escape: :html_safe))
      |> assign(
        :labels_json,
        Jason.encode!(ThemeConfig.translated_label_map(), escape: :html_safe)
      )

    ~H"""
    <script nonce={PhoenixKitWeb.CSP.nonce(:script)}>
      (function () {
        // One instance per page, whichever layout renders first.
        if (window.__pkThemeController) return;
        window.__pkThemeController = true;

        const STORAGE_KEY = 'phx:theme';
        const themeBaseMap = <%= Phoenix.HTML.raw(@base_map_json) %>;
        const themeLabels = <%= Phoenix.HTML.raw(@labels_json) %>;
        // The CONFIGURED light/dark pair "system" resolves to.
        const systemPair = { light: '<%= @light %>', dark: '<%= @dark %>' };
        const media = window.matchMedia?.('(prefers-color-scheme: dark)') || null;

        let dispatching = false;

        // localStorage can throw wholesale (sandboxed iframes, storage-blocked
        // modes). Guarded here so a throw degrades to non-persistent theming
        // instead of killing init before any listener attaches.
        const LEGACY_KEY = 'phoenix_kit_theme';

        const storage = {
          get() {
            try {
              return localStorage.getItem(STORAGE_KEY) || localStorage.getItem(LEGACY_KEY);
            } catch (e) {
              return null;
            }
          },
          set(value) {
            try {
              localStorage.setItem(STORAGE_KEY, value);
            } catch (e) {}
          },
          remove() {
            try {
              localStorage.removeItem(STORAGE_KEY);
            } catch (e) {}
          }
        };

        function resolve(theme) {
          if (theme !== 'system') return theme;
          return media && media.matches ? systemPair.dark : systemPair.light;
        }

        function toTitle(value) {
          return value
            .split('-')
            .map((s) => s.charAt(0).toUpperCase() + s.slice(1))
            .join(' ');
        }

        // Stamp the theme on the document and mirror it into every picker —
        // labels, dropdown option indicators, and the pair toggle. Does NOT
        // persist or dispatch; that is setTheme's half.
        function apply(theme) {
          const resolved = resolve(theme);

          [document.documentElement, document.body].forEach((el) => {
            if (!el) return;
            el.setAttribute('data-theme', resolved);
            el.style.colorScheme = themeBaseMap[resolved] || 'light';
          });

          // The choice itself ("system" or a theme's name), as ThemeBootstrap
          // stamps it before the first paint: the inline picker's CSS marks
          // the chosen button from it, which no LiveView patch can undo.
          document.documentElement.setAttribute('data-theme-choice', theme);

          document.querySelectorAll('[data-theme-current-label]').forEach((el) => {
            el.textContent = themeLabels[theme] || toTitle(theme);
          });

          document.querySelectorAll('[data-theme-target]').forEach((btn) => {
            const targets = (btn.dataset.themeTarget || '')
              .split(',')
              .map((s) => s.trim())
              .filter(Boolean);
            const isActive = targets.includes(theme) || targets.includes(resolved);

            if (btn.dataset.themeRole === 'toggle') {
              // The persistent pair toggle: aria-pressed = dark half on, and
              // data-phx-theme always points at the OTHER theme — it is what
              // the button's JS.dispatch carries, so the click needs no
              // state of its own. Icon visibility is CSS (keyed off
              // html[data-theme], rendered next to the button), correct from
              // the first paint with no JS involved.
              const isDark = resolved === btn.dataset.themeDark;
              btn.setAttribute('aria-pressed', String(isDark));
              btn.dataset.phxTheme = isDark ? btn.dataset.themeLight : btn.dataset.themeDark;
            } else if (btn.dataset.themeRole === 'inline-option') {
              // The choice, not what it resolves to: with "system" chosen on
              // a dark OS, "dark" is in effect but was not picked.
              btn.setAttribute('aria-pressed', String(targets.includes(theme)));
            } else if (btn.dataset.themeRole === 'dropdown-option') {
              btn.classList.toggle('bg-base-200', isActive);
              btn.classList.toggle('ring-2', isActive);
              btn.classList.toggle('ring-primary/70', isActive);
              btn.setAttribute('aria-selected', String(isActive));
              btn.querySelectorAll('[data-theme-active-indicator]').forEach((icon) => {
                icon.classList.toggle('opacity-100', isActive);
                icon.classList.toggle('scale-100', isActive);
                icon.classList.toggle('scale-75', !isActive);
              });
            }
          });
        }

        // announce=false when the change arrived as a window event: it
        // already bubbled past every host listener, and re-dispatching made
        // hosts hear each selection twice.
        function setTheme(theme, announce) {
          apply(theme);

          if (theme === 'system') {
            storage.remove();
          } else {
            storage.set(theme);
          }

          if (announce && !dispatching) {
            dispatching = true;
            try {
              window.dispatchEvent(new CustomEvent('phx:set-theme', { detail: { theme } }));
            } catch (error) {
              console.warn('PhoenixKit theme controller: unable to dispatch phx:set-theme', error);
            } finally {
              dispatching = false;
            }
          }
        }

        function init() {
          // apply, not setTheme: initialization reflects the saved choice
          // into the UI but should neither rewrite storage nor announce a
          // change nobody made.
          apply(storage.get() || 'system');

          // Follow the OS while in system mode.
          media?.addEventListener('change', () => {
            if ((storage.get() || 'system') === 'system') apply('system');
          });

          // A theme picked in another tab: ThemeBootstrap already restamps
          // the attribute pre-paint on fresh loads; this keeps LIVE pages'
          // pickers in sync too. apply, not setTheme — the other tab
          // already persisted.
          window.addEventListener('storage', (e) => {
            if (e.key === STORAGE_KEY) apply(e.newValue || 'system');
          });

          // LiveView patches rebuild picker markup mid-session, wiping the
          // client-written state (aria-pressed, data-phx-theme, icon
          // visibility) back to its SSR defaults. Re-stamp after every
          // completed navigation/patch.
          window.addEventListener('phx:page-loading-stop', () => apply(storage.get() || 'system'));

          // A picker that arrived in a patch, after all of the above ran: its
          // elements ask for the saved choice to be reflected into them.
          window.addEventListener('phoenix_kit:theme-sync', () => apply(storage.get() || 'system'));

          // Theme selections: every picker element (dropdown options and the
          // pair toggle alike) dispatches phx:set-theme itself via
          // JS.dispatch, carrying the theme in detail or data-phx-theme.
          // Skip our own re-dispatches — see the guard in setTheme.
          window.addEventListener('phx:set-theme', (e) => {
            const theme = e?.detail?.theme ?? e?.target?.dataset?.phxTheme;
            if (theme && !dispatching) setTheme(theme, false);
          });

          // Legacy event name — nothing in the kit emits it anymore, kept
          // only so hosts that adopted it keep working. Announced, so host
          // listeners for the modern event still hear the change.
          document.addEventListener('phx:set-admin-theme', (e) => {
            if (e?.detail?.theme) setTheme(e.detail.theme, true);
          });
        }

        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', init);
        } else {
          init();
        }
      })();
    </script>
    """
  end
end
