defmodule PhoenixKitWeb.Components.LayoutWrapper do
  @moduledoc """
  Dynamic layout wrapper component for Phoenix v1.7- and v1.8+ compatibility.

  This component automatically detects the Phoenix version and layout configuration
  to provide seamless integration with parent applications while maintaining
  backward compatibility.

  ## Usage

  Replace direct layout calls with the wrapper:

      <%!-- OLD (Phoenix v1.7-) --%>
      <%!-- Templates relied on router-level layout config --%>

      <%!-- NEW (Phoenix v1.8+) --%>
      <PhoenixKitWeb.Components.LayoutWrapper.app_layout flash={@flash}>
        <%!-- content --%>
      </PhoenixKitWeb.Components.LayoutWrapper.app_layout>

  ## Configuration

  Configure parent layout in config.exs:

      config :phoenix_kit,
        layout: {MyAppWeb.Layouts, :app}

  """
  use Phoenix.Component
  use PhoenixKitWeb, :verified_routes
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Flash, only: [flash_group: 1]
  import PhoenixKitWeb.Components.Core.CookieConsent, only: [cookie_consent: 1]
  import PhoenixKitWeb.Components.AdminNav
  import PhoenixKitWeb.Components.Dashboard.AdminSidebar, only: [admin_sidebar: 1]

  alias Phoenix.HTML
  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Legal

  alias PhoenixKit.Modules.SEO
  alias PhoenixKit.ThemeConfig
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.PhoenixVersion

  @doc """
  Renders content with the appropriate layout based on configuration and Phoenix version.

  Automatically handles:
  - Phoenix v1.8+ function component layouts
  - Phoenix v1.7- legacy layout configuration
  - Fallback to PhoenixKit layouts when no parent configured
  - Parent layout compatibility with PhoenixKit assigns

  ## Attributes

  - `flash` - Flash messages (required)
  - `phoenix_kit_current_scope` - Current authentication scope (optional)
  - `phoenix_kit_current_user` - Current user (optional, for backwards compatibility)

  ## Inner Block

  - `inner_block` - Content to render within the layout
  """
  attr :flash, :map, default: %{}
  attr :phoenix_kit_current_scope, :any, default: nil
  attr :phoenix_kit_current_user, :any, default: nil
  attr :page_title, :string, default: nil
  attr :current_path, :string, default: nil
  attr :inner_content, :string, default: nil
  attr :project_title, :string, default: nil
  attr :current_locale, :string, default: nil

  slot :inner_block, required: false

  def app_layout(assigns) do
    # Batch load all page settings in a single operation for optimal database performance
    assigns =
      assigns
      |> assign_new(:content_language, fn ->
        # Use the current locale from LiveView, falling back to content language setting
        # Extract base code from full dialect if necessary (e.g., "en-US" -> "en")
        case assigns[:current_locale] do
          nil ->
            PhoenixKit.Settings.get_content_language()

          locale when is_binary(locale) ->
            DialectMapper.extract_base(locale)

          _ ->
            PhoenixKit.Settings.get_content_language()
        end
      end)
      |> assign_new(:seo_no_index, fn -> SEO.no_index_enabled?() end)

    # Handle both inner_content (Phoenix 1.7-) and inner_block (Phoenix 1.8+)
    assigns = normalize_content_assigns(assigns)

    # For admin pages, render simplified layout without parent headers
    if admin_page?(assigns) do
      render_admin_only_layout(assigns)
    else
      case get_layout_config() do
        {module, function} when is_atom(module) and is_atom(function) ->
          render_with_parent_layout(assigns, module, function)

        nil ->
          render_with_phoenix_kit_layout(assigns)
      end
    end
  end

  ## Private Implementation

  # Normalize content assigns to handle both inner_content and inner_block
  defp normalize_content_assigns(assigns) do
    if needs_inner_block_conversion?(assigns) do
      convert_inner_content_to_block(assigns)
    else
      assigns
    end
  end

  defp needs_inner_block_conversion?(assigns) do
    has_inner_content?(assigns) and not has_inner_block?(assigns)
  end

  defp has_inner_content?(assigns), do: assigns[:inner_content] != nil
  defp has_inner_block?(assigns), do: assigns[:inner_block] && assigns[:inner_block] != []

  defp convert_inner_content_to_block(assigns) do
    inner_content = assigns[:inner_content]
    inner_block = build_synthetic_inner_block(inner_content)
    Map.put(assigns, :inner_block, inner_block)
  end

  defp build_synthetic_inner_block(inner_content) do
    [
      %{
        inner_block: fn _slot_assigns, _index ->
          Phoenix.HTML.raw(inner_content)
        end
      }
    ]
  end

  # Check if current page is an admin page that needs navigation.
  # Strips URL prefix first, then locale prefix, to handle paths like
  # /phoenix_kit/uk/admin/users where the locale sits between prefix and /admin.
  defp admin_page?(assigns) do
    case assigns[:current_path] do
      nil ->
        false

      path when is_binary(path) ->
        prefix = PhoenixKit.Config.get_url_prefix()

        normalized =
          if prefix == "/", do: path, else: String.replace_prefix(path, prefix, "")

        # Strip locale prefix (e.g., /uk/admin → /admin) for localized admin routes
        normalized = strip_locale_prefix(normalized)

        normalized == "/admin" or String.starts_with?(normalized, "/admin/")

      _ ->
        false
    end
  end

  defp strip_locale_prefix(path) do
    case Regex.run(~r/^\/[a-z]{2}(-[A-Z]{2})?(\/.*)?$/, path) do
      [_, _locale, rest] when is_binary(rest) -> rest
      [_, _locale] -> "/"
      _ -> path
    end
  end

  # Wrap inner_block with admin navigation if needed
  defp wrap_inner_block_with_admin_nav_if_needed(assigns) do
    if admin_page?(assigns) do
      # Create new inner_block slot that wraps original content with admin navigation
      original_inner_block = assigns[:inner_block]

      new_inner_block = [
        %{
          inner_block: fn _slot_assigns, _index ->
            # Create template assigns with needed values
            template_assigns = %{
              original_inner_block: original_inner_block,
              current_path: assigns[:current_path],
              phoenix_kit_current_scope: assigns[:phoenix_kit_current_scope],
              project_title: assigns[:project_title] || PhoenixKit.Settings.get_project_title(),
              current_locale: assigns[:current_locale],
              current_locale_base:
                assigns[:current_locale] && DialectMapper.extract_base(assigns[:current_locale]),
              scope: assigns[:phoenix_kit_current_scope]
            }

            assigns = template_assigns

            ~H"""
            <%!-- PhoenixKit Admin Layout following EZNews pattern --%>
            <style data-phoenix-kit-themes>
              <%= HTML.raw(ThemeConfig.custom_theme_css()) %>
            </style>
            <style>
              /* Custom sidebar control for desktop - override lg:drawer-open grid layout when closed */
              @media (min-width: 1024px) {
                /* Override the grid to collapse sidebar column when closed */
                #admin-drawer.sidebar-closed {
                  grid-template-columns: 0 1fr !important;
                  transition: grid-template-columns 300ms ease-in-out;
                }
                #admin-drawer.sidebar-closed .drawer-side {
                  transform: translateX(-16rem); /* -256px (w-64) */
                  transition: transform 300ms ease-in-out;
                  overflow: hidden;
                }
                #admin-drawer:not(.sidebar-closed) {
                  transition: grid-template-columns 300ms ease-in-out;
                }
                #admin-drawer:not(.sidebar-closed).drawer.lg\:drawer-open .drawer-side {
                  transform: translateX(0);
                  transition: transform 300ms ease-in-out;
                }
              }
            </style>
            <%!-- Top Bar Navbar (always visible, spans full width) --%>
            <header class="bg-base-100 shadow-sm border-b border-base-300 fixed top-0 left-0 right-0 z-50">
              <div class="flex items-center justify-between h-16 px-4">
                <%!-- Left: Burger Menu, Logo and Title --%>
                <div class="flex items-center gap-3">
                  <%!-- Burger Menu Button (Far left) --%>
                  <label for="admin-mobile-menu" class="btn btn-square btn-primary drawer-button p-0">
                    <PhoenixKitWeb.Components.Core.Icons.icon_menu />
                  </label>

                  <%!-- Logo --%>
                  <div class="w-8 h-8 bg-primary rounded-lg flex items-center justify-center">
                    <PhoenixKitWeb.Components.Core.Icons.icon_shield />
                  </div>

                  <%!-- Project title and Admin label grouped together --%>
                  <div class="flex items-center gap-1 min-w-0">
                    <.link
                      href="/"
                      class="font-bold text-base-content hover:opacity-80 transition-opacity hidden sm:inline truncate"
                    >
                      {@project_title}
                    </.link>
                    <span class="font-bold text-base-content shrink-0">{gettext("Admin")}</span>
                  </div>
                </div>

                <%!-- Right: Theme Switcher, Language Dropdown, and User Dropdown --%>
                <div class="flex items-center gap-3">
                  <.admin_theme_controller mobile={true} />
                  <.admin_language_dropdown
                    current_path={@current_path}
                    current_locale={@current_locale}
                  />
                  <.admin_user_dropdown
                    scope={@phoenix_kit_current_scope}
                    current_path={@current_path}
                    current_locale={@current_locale}
                  />
                </div>
              </div>
            </header>

            <div id="admin-drawer" class="drawer lg:drawer-open">
              <input id="admin-mobile-menu" type="checkbox" class="drawer-toggle" />

              <%!-- Main content --%>
              <div class="drawer-content flex min-h-screen flex-col bg-base-100 transition-colors pt-16">
                <%!-- Page content from parent layout --%>
                <div class="flex-1">
                  {render_slot(@original_inner_block)}
                </div>
              </div>

              <%!-- Desktop/Mobile Sidebar --%>
              <div class="drawer-side">
                <label for="admin-mobile-menu" class="drawer-overlay lg:hidden"></label>
                <aside class="min-h-full w-64 bg-base-100 shadow-lg border-r border-base-300 flex flex-col pt-16">
                  <%!-- Navigation (fills available space) --%>
                  <div class="px-4 py-6 flex-1">
                    <.admin_sidebar
                      current_path={@current_path || ""}
                      scope={@scope}
                      locale={@current_locale_base}
                    />
                  </div>
                </aside>
              </div>
            </div>

            <%!-- Auto-close mobile drawer on navigation --%>
            <script>
              // Mobile drawer and burger menu navigation
              document.addEventListener('DOMContentLoaded', function() {
                const drawerToggle = document.getElementById('admin-mobile-menu');
                const adminDrawer = document.getElementById('admin-drawer');
                const burgerMenuButton = document.querySelector('label[for="admin-mobile-menu"]');

                // Close mobile drawer on navigation
                const mainNavLinks = document.querySelectorAll('.drawer-side a');

                mainNavLinks.forEach(link => {
                  link.addEventListener('click', () => {
                    if (drawerToggle && window.innerWidth < 1024) {
                      drawerToggle.checked = false;
                    }
                  });
                });

                // Handle burger menu toggle for desktop
                if (burgerMenuButton && adminDrawer) {
                  burgerMenuButton.addEventListener('click', () => {
                    // On desktop (>= 1024px), toggle the sidebar-closed class
                    if (window.innerWidth >= 1024) {
                      adminDrawer.classList.toggle('sidebar-closed');
                    }
                    // On mobile, default checkbox behavior handles it
                  });
                }
              });

              // Theme configuration and controller
              const themeBaseMap = <%= ThemeConfig.base_map() |> Phoenix.json_library().encode!() |> Phoenix.HTML.raw() %>;
              const themeLabels = <%= ThemeConfig.label_map() |> Phoenix.json_library().encode!() |> Phoenix.HTML.raw() %>;

              // Admin theme controller for PhoenixKit with animated slider
              const adminThemeController = {
                init() {
                  // Safely query for dropdown controllers with null checks
                  const dropdownContainers = document.querySelectorAll('[data-theme-dropdown]');

                  this.dropdownControllers = Array.from(dropdownContainers).map((container) => ({
                    container,
                    button: container.querySelector('[data-theme-toggle]'),
                    panel: container.querySelector('[data-theme-dropdown-panel]'),
                    label: container.querySelector('[data-theme-current-label]')
                  }));

                  this.registerDropdownAccessibility();

                  this.systemMediaQuery =
                    typeof window.matchMedia === 'function'
                      ? window.matchMedia('(prefers-color-scheme: dark)')
                      : null;

                  if (this.systemMediaQuery) {
                    this.systemMediaQuery.addEventListener('change', () => {
                      if ((localStorage.getItem('phx:theme') || 'system') === 'system') {
                        this.applyThemeAttributes('system');
                      }
                    });
                  }

                  const savedTheme = localStorage.getItem('phx:theme') || 'system';
                  this.setTheme(savedTheme);
                  this.setupListeners();
                },

                setTheme(theme) {
                  const resolvedTheme = this.applyThemeAttributes(theme, themeBaseMap);

                  if (theme === 'system') {
                    localStorage.removeItem('phx:theme');
                  } else {
                    localStorage.setItem('phx:theme', theme);
                  }

                  if (this.dropdownControllers?.length) {
                    this.dropdownControllers.forEach((entry) => {
                      if (entry.label) {
                        entry.label.textContent = themeLabels[theme] || this.toTitle(theme);
                      }
                      this.setDropdownState(entry, false);
                    });
                  }

                  // Update active state for all theme buttons
                  const themeButtons = document.querySelectorAll('[data-theme-target]');

                  themeButtons.forEach((btn) => {
                    const targets = (btn.dataset.themeTarget || '')
                      .split(',')
                      .map((value) => value.trim())
                      .filter(Boolean);
                    const isActive = targets.includes(theme);

                    if (btn.dataset.themeRole === 'dropdown-option') {
                      btn.classList.toggle('bg-base-200', isActive);
                      btn.classList.toggle('ring-2', isActive);
                      btn.classList.toggle('ring-primary/70', isActive);
                      btn.setAttribute('aria-selected', String(isActive));
                      btn
                        .querySelectorAll('[data-theme-active-indicator]')
                        .forEach((icon) => {
                          icon.classList.toggle('opacity-100', isActive);
                          icon.classList.toggle('scale-100', isActive);
                          icon.classList.toggle('scale-75', !isActive);
                        });
                    } else if (btn.dataset.themeRole === 'slider-button') {
                      btn.classList.toggle('text-primary', isActive);
                      btn.setAttribute('aria-pressed', String(isActive));
                    }
                  });

                  // Notify global PhoenixKit theme listeners
                  // Dispatch from a fake element with data-phx-theme attribute for compatibility with parent app listeners
                  // The event bubbles up to window, allowing window-level listeners to work correctly
                  try {
                    const fakeTarget = document.createElement('div');
                    fakeTarget.dataset.phxTheme = theme;
                    const event = new CustomEvent('phx:set-theme', {
                      detail: { theme },
                      bubbles: true
                    });
                    fakeTarget.dispatchEvent(event);
                  } catch (error) {
                    console.warn('PhoenixKit admin theme controller: unable to dispatch phx:set-theme', error);
                  }

                  if (window.PhoenixKitTheme && typeof window.PhoenixKitTheme.setTheme === 'function') {
                    try {
                      window.PhoenixKitTheme.setTheme(theme);
                    } catch (error) {
                      console.warn('PhoenixKit admin theme controller: unable to sync PhoenixKitTheme', error);
                    }
                  }
                },

                setupListeners() {
                  // Listen to Phoenix LiveView theme events (both variants)
                  document.addEventListener('phx:set-admin-theme', (e) => {
                    if (e?.detail?.theme) {
                      this.setTheme(e.detail.theme);
                    }
                  });

                  // Also listen for phx:set-theme from theme_controller component
                  window.addEventListener('phx:set-theme', (e) => {
                    if (e?.detail?.theme) {
                      this.setTheme(e.detail.theme);
                    }
                  });
                },

                registerDropdownAccessibility() {
                  if (!this.dropdownControllers?.length) return;

                  this.dropdownControllers.forEach((entry) => {
                    this.setDropdownState(entry, false);

                    if (!entry.button || !entry.panel) return;

                    entry.button.addEventListener('click', (event) => {
                      event.preventDefault();
                      event.stopPropagation();
                      const expanded = entry.button.getAttribute('aria-expanded') === 'true';
                      this.setDropdownState(entry, !expanded);
                    });

                    entry.panel.addEventListener('click', (event) => {
                      event.stopPropagation();
                    });
                  });

                  document.addEventListener('click', (event) => {
                    const clickedInside = this.dropdownControllers.some((entry) =>
                      entry.container?.contains(event.target)
                    );

                    if (!clickedInside) {
                      this.dropdownControllers.forEach((entry) => this.setDropdownState(entry, false));
                    }
                  });
                },

                toTitle(value) {
                  return value
                    .split('-')
                    .map((segment) => segment.charAt(0).toUpperCase() + segment.slice(1))
                    .join(' ');
                },

                setDropdownState(entry, isOpen) {
                  if (!entry?.button || !entry?.panel) return;

                  entry.button.setAttribute('aria-expanded', String(!!isOpen));
                  entry.panel.setAttribute('aria-hidden', String(!isOpen));
                  entry.panel.classList.toggle('pointer-events-auto', !!isOpen);
                  entry.panel.classList.toggle('pointer-events-none', !isOpen);
                  entry.panel.classList.toggle('opacity-100', !!isOpen);
                  entry.panel.classList.toggle('opacity-0', !isOpen);
                  entry.panel.classList.toggle('-translate-y-2', !isOpen);
                  entry.panel.classList.toggle('translate-y-0', !!isOpen);
                },

                applyThemeAttributes(theme, baseMap = {}) {
                  const resolvedTheme =
                    theme === 'system'
                      ? this.systemMediaQuery && this.systemMediaQuery.matches
                        ? 'phoenix-dark'
                        : 'phoenix-light'
                      : theme;

                  if (document.documentElement) {
                    document.documentElement.setAttribute('data-theme', resolvedTheme);
                    document.documentElement.dataset.theme = resolvedTheme;
                    document.documentElement.setAttribute(
                      'data-admin-theme-base',
                      theme === 'system' ? 'system' : baseMap[resolvedTheme] || resolvedTheme
                    );
                  }

                  if (document.body) {
                    document.body.setAttribute('data-theme', resolvedTheme);
                    document.body.dataset.theme = resolvedTheme;
                    document.body.setAttribute(
                      'data-admin-theme-base',
                      theme === 'system' ? 'system' : baseMap[resolvedTheme] || resolvedTheme
                    );
                    document.body.classList.add('bg-base-100', 'transition-colors');
                  }

                  return resolvedTheme;
                }
              };

              // Always initialize after DOM is fully loaded to avoid race conditions
              if (document.readyState === 'loading' || document.readyState === 'interactive') {
                // DOM still loading, wait for DOMContentLoaded
                document.addEventListener('DOMContentLoaded', () => {
                  adminThemeController.init();
                });
              } else {
                // DOM already loaded (readyState === 'complete'), safe to init immediately
                adminThemeController.init();
              }
            </script>
            """
          end
        }
      ]

      # Return assigns with new inner_block
      assign(assigns, :inner_block, new_inner_block)
    else
      # Not an admin page, return assigns unchanged
      assigns
    end
  end

  # Render with parent application layout (Phoenix v1.8+ function component approach)
  defp render_with_parent_layout(assigns, module, function) do
    # Prepare assigns for parent layout compatibility
    assigns = prepare_parent_layout_assigns(assigns)

    # Dynamically call the parent layout function based on Phoenix version
    case PhoenixVersion.get_strategy() do
      :modern ->
        render_modern_parent_layout(assigns, module, function)

      :legacy ->
        render_legacy_parent_layout(assigns, module, function)
    end
  end

  # Phoenix v1.8+ approach - function components
  defp render_modern_parent_layout(assigns, module, function) do
    # Wrap inner content with admin navigation if needed
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    # Use apply/3 to dynamically call the parent layout function
    apply(module, function, [assigns])
  rescue
    UndefinedFunctionError ->
      # Fallback to PhoenixKit layout if parent function doesn't exist
      render_with_phoenix_kit_layout(assigns)
  end

  # Phoenix v1.7- approach - templates (legacy support)
  defp render_legacy_parent_layout(assigns, _module, _function) do
    # For legacy Phoenix, layouts are handled at router level
    # Wrap inner content with admin navigation if needed
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    # Just render content without wrapper - layout comes from router
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  # Render admin pages with simplified layout (no parent headers)
  defp render_admin_only_layout(assigns) do
    # Wrap inner content with admin navigation
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    ~H"""
    <!DOCTYPE html>
    <html
      lang={@content_language || "en"}
      data-theme="light"
      data-admin-theme-base="system"
      class="[scrollbar-gutter:stable]"
    >
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <meta name="phoenix-kit-prefix" content={PhoenixKit.Utils.Routes.url_prefix()} />
        <.live_title default={"#{assigns[:project_title] || PhoenixKit.Settings.get_project_title()} Admin"}>
          {assigns[:page_title] || "Admin"}
        </.live_title>
        <%= if assigns[:seo_no_index] do %>
          <meta name="robots" content="noindex,nofollow" />
          <meta name="googlebot" content="noindex,nofollow" />
        <% end %>
        <link phx-track-static rel="stylesheet" href="/assets/css/app.css" />
        <script defer src="/assets/phoenix_kit_consent.js">
        </script>
      </head>
      <body class="bg-base-100 antialiased transition-colors" data-admin-theme-base="system">
        <%!-- Admin pages without parent headers --%>
        <main class="min-h-screen bg-base-100 transition-colors">
          <.flash_group flash={@flash} />
          {render_slot(@inner_block)}
        </main>

        <%!-- Cookie Consent Widget --%>
        <%= if Legal.consent_widget_enabled?() do %>
          <% config = Legal.get_consent_widget_config() %>
          <.cookie_consent
            frameworks={config.frameworks}
            consent_mode={config.consent_mode}
            icon_position={config.icon_position}
            policy_version={config.policy_version}
            cookie_policy_url={config.cookie_policy_url}
            privacy_policy_url={config.privacy_policy_url}
            google_consent_mode={config.google_consent_mode}
          />
        <% end %>
      </body>
    </html>
    """
  end

  # Fallback to PhoenixKit's own layout
  defp render_with_phoenix_kit_layout(assigns) do
    # Wrap inner content with admin navigation if needed
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    ~H"""
    <PhoenixKitWeb.Layouts.root {prepare_phoenix_kit_assigns(assigns)}>
      {render_slot(@inner_block)}
    </PhoenixKitWeb.Layouts.root>
    """
  end

  # Prepare assigns for parent layout compatibility
  defp prepare_parent_layout_assigns(assigns) do
    assigns
    |> Map.put_new(:current_user, get_current_user_for_parent(assigns))
    |> Map.put_new(:phoenix_kit_integrated, true)
    |> Map.put_new(:phoenix_kit_version, get_phoenix_kit_version())
    |> Map.put_new(:phoenix_version_info, PhoenixVersion.get_version_info())
    |> Map.put_new(:seo_no_index, assigns[:seo_no_index] || false)
  end

  # Prepare assigns specifically for PhoenixKit layout
  defp prepare_phoenix_kit_assigns(assigns) do
    assigns
    |> Map.put_new(:phoenix_kit_standalone, true)
    |> Map.put_new(:seo_no_index, assigns[:seo_no_index] || false)
  end

  # Extract current user from scope for parent layout compatibility
  defp get_current_user_for_parent(assigns) do
    case assigns[:phoenix_kit_current_scope] do
      nil -> assigns[:phoenix_kit_current_user]
      scope -> Scope.user(scope)
    end
  end

  # Get layout configuration from PhoenixKit.Config with Phoenix version compatibility
  defp get_layout_config do
    case Config.get(:phoenix_version_strategy, nil) do
      :modern ->
        # Phoenix v1.8+ - get layouts_module and assume :app function
        case Config.get(:layouts_module, nil) do
          nil -> nil
          module -> {module, :app}
        end

      :legacy ->
        # Phoenix v1.7- - use legacy layout config
        Config.get(:layout, nil)

      nil ->
        # Fallback - check for legacy layout config first
        Config.get(:layout, nil)
    end
  end

  # Get PhoenixKit version
  defp get_phoenix_kit_version do
    case Application.spec(:phoenix_kit) do
      nil ->
        "unknown"

      spec ->
        spec
        |> Keyword.get(:vsn, "unknown")
        |> to_string()
    end
  end

  # Used in HEEX template - compiler cannot detect usage
  def get_language_flag(code) when is_binary(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      nil -> "🌐"
    end
  end

  # Build URL with base code - expects base code directly (e.g., "en" not "en-US")
  # Used by admin language switcher where language["code"] is already the base code
  def build_locale_url(current_path, base_code) do
    # Get enabled codes for locale detection in path
    enabled_language_codes = Languages.get_enabled_language_codes()
    enabled_base_codes = Enum.map(enabled_language_codes, &DialectMapper.extract_base/1)

    # Remove PhoenixKit prefix if present (use dynamic config, not hardcoded)
    url_prefix = PhoenixKit.Config.get_url_prefix()
    prefix_to_remove = if url_prefix == "/", do: "", else: url_prefix
    normalized_path = String.replace_prefix(current_path || "", prefix_to_remove, "")

    # Remove existing locale prefix from path
    clean_path =
      case String.split(normalized_path, "/", parts: 3) do
        ["", potential_locale, rest] ->
          if potential_locale in enabled_language_codes or potential_locale in enabled_base_codes do
            "/" <> rest
          else
            normalized_path
          end

        ["", potential_locale] ->
          if potential_locale in enabled_language_codes or potential_locale in enabled_base_codes do
            "/"
          else
            normalized_path
          end

        _ ->
          normalized_path
      end

    # Build URL with base code
    url_prefix = PhoenixKit.Config.get_url_prefix()
    base_prefix = if url_prefix == "/", do: "", else: url_prefix

    "#{base_prefix}/#{base_code}#{clean_path}"
  end

  # Legacy function - kept for backward compatibility
  def generate_language_switch_url(current_path, new_locale) do
    base_code = DialectMapper.extract_base(new_locale)
    build_locale_url(current_path, base_code)
  end
end
