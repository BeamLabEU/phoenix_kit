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

  import PhoenixKitWeb.Components.Core.Flash, only: [flash_group: 1]
  import PhoenixKitWeb.Components.AdminNav
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias Phoenix.HTML
  alias PhoenixKit.Module.Languages
  alias PhoenixKit.ThemeConfig
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.PhoenixVersion
  alias PhoenixKit.Utils.Routes

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
  attr :project_title, :string, default: "PhoenixKit"
  attr :current_locale, :string, default: "en"

  slot :inner_block, required: false
  slot :admin_popup, required: false

  def app_layout(assigns) do
    # Ensure content_language is available in assigns
    assigns =
      assigns
      |> assign_new(:content_language, fn ->
        PhoenixKit.Settings.get_content_language()
      end)

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
    # If we have inner_content but no inner_block, create inner_block from inner_content
    if assigns[:inner_content] && (!assigns[:inner_block] || assigns[:inner_block] == []) do
      inner_content = assigns[:inner_content]

      # Create a synthetic inner_block slot
      inner_block = [
        %{
          inner_block: fn _slot_assigns, _index ->
            Phoenix.HTML.raw(inner_content)
          end
        }
      ]

      Map.put(assigns, :inner_block, inner_block)
    else
      # If we have inner_block but no inner_content, leave as is
      assigns
    end
  end

  # Check if current page is an admin page that needs navigation
  defp admin_page?(assigns) do
    case assigns[:current_path] do
      nil -> false
      path when is_binary(path) -> String.contains?(path, "/admin")
      _ -> false
    end
  end

  defp render_admin_popup_debug(assigns) do
    admin_popup_slots = length(assigns[:admin_popup] || [])
    inner_block_slots = length(assigns[:inner_block] || [])
    original_inner_block_slots = length(assigns[:original_inner_block] || [])

    debug_assigns =
      assigns
      |> Map.drop([:__changed__])
      |> Map.put(:admin_popup_slots, admin_popup_slots)
      |> Map.put(:inner_block_slots, inner_block_slots)
      |> Map.put(:original_inner_block_slots, original_inner_block_slots)
      |> Map.delete(:admin_popup)
      |> Map.delete(:inner_block)
      |> Map.delete(:original_inner_block)
      |> inspect(pretty: true, printable_limit: :infinity, limit: :infinity)

    assigns = %{debug_dump: debug_assigns}

    ~H"""
    <pre class="rounded-xl border border-base-300 bg-base-200/60 p-4 font-mono text-[11px] leading-relaxed text-base-content/80 shadow-inner whitespace-pre w-fit"><%= @debug_dump %></pre>
    """
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
              project_title: assigns[:project_title] || "PhoenixKit",
              current_locale: assigns[:current_locale] || "en",
              admin_popup: assigns[:admin_popup] || []
            }

            assigns = template_assigns

            ~H"""
            <%!-- PhoenixKit Admin Layout following EZNews pattern --%>
            <style data-phoenix-kit-themes>
              <%= HTML.raw(ThemeConfig.custom_theme_css()) %>
            </style>
            <style>
              /* Custom sidebar control for desktop - override lg:drawer-open when closed */
              @media (min-width: 1024px) {
                #admin-drawer.sidebar-closed .drawer-side {
                  transform: translateX(-16rem); /* -256px (w-64) */
                  transition: transform 300ms ease-in-out;
                }
                #admin-drawer:not(.sidebar-closed).drawer.lg\:drawer-open .drawer-side {
                  transform: translateX(0);
                  transition: transform 300ms ease-in-out;
                }
              }

              #admin-generic-popup [data-popup-panel] {
                left: var(--phoenix-kit-popup-left, auto);
                top: var(--phoenix-kit-popup-top, auto);
                width: var(--phoenix-kit-popup-width, auto);
                height: var(--phoenix-kit-popup-height, auto);
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

                  <div class="w-8 h-8 bg-primary rounded-lg flex items-center justify-center">
                    <PhoenixKitWeb.Components.Core.Icons.icon_shield />
                  </div>
                  <span class="font-bold text-base-content">{@project_title} Admin</span>
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

                <div
                  id="admin-generic-popup"
                  class="fixed inset-0 z-[70] pointer-events-none"
                  aria-hidden="true"
                  style="display: none;"
                >
                  <section
                    data-popup-panel
                    role="dialog"
                    aria-modal="true"
                    aria-label="Popup"
                    tabindex="-1"
                    class="absolute flex flex-col rounded-2xl border border-base-300 bg-base-100 shadow-2xl pointer-events-auto"
                  >
                    <header
                      data-popup-handle
                      class="cursor-grab select-none rounded-t-2xl border-b border-base-200 bg-gradient-to-r from-primary/10 to-primary/5 px-6 py-4 text-base-content flex-shrink-0"
                    >
                      <div class="flex w-full justify-center">
                        <span class="h-2 w-16 rounded-full bg-primary/30"></span>
                      </div>
                    </header>

                    <div
                      id="admin-popup-content"
                      data-popup-content
                      class="px-6 py-5 space-y-4 text-sm text-base-content/80 min-h-0 flex-1 overflow-auto"
                    >
                      <%= if @admin_popup == [] do %>
                        <%= render_admin_popup_debug(assigns) %>
                      <% else %>
                        <%= render_slot(@admin_popup) %>
                      <% end %>
                    </div>

                    <footer class="flex items-center justify-end border-t border-base-200 px-6 py-4 gap-3 flex-shrink-0">
                      <button
                        type="button"
                        data-popup-close
                        class="btn btn-ghost btn-sm"
                      >
                        Close
                      </button>
                    </footer>

                    <div
                      data-popup-resize-handle
                      class="absolute -bottom-2 -right-2 flex h-8 w-8 cursor-se-resize items-center justify-center rounded-full border border-base-200 bg-base-100/90 text-primary/70 shadow-md transition hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50"
                      aria-hidden="true"
                    >
                      <svg class="w-4 h-4" viewBox="0 0 16 16" fill="currentColor">
                        <circle cx="3" cy="3" r="1.5"/>
                        <circle cx="8" cy="3" r="1.5"/>
                        <circle cx="13" cy="3" r="1.5"/>
                        <circle cx="3" cy="8" r="1.5"/>
                        <circle cx="8" cy="8" r="1.5"/>
                        <circle cx="13" cy="8" r="1.5"/>
                        <circle cx="3" cy="13" r="1.5"/>
                        <circle cx="8" cy="13" r="1.5"/>
                        <circle cx="13" cy="13" r="1.5"/>
                      </svg>
                    </div>
                  </section>
                </div>
              </div>

              <%!-- Desktop/Mobile Sidebar --%>
              <div class="drawer-side">
                <label for="admin-mobile-menu" class="drawer-overlay lg:hidden"></label>
                <aside class="min-h-full w-64 bg-base-100 shadow-lg border-r border-base-300 flex flex-col pt-16">
                  <%!-- Navigation (fills available space) --%>
                  <nav class="px-4 py-6 space-y-2 flex-1">
                    <.admin_nav_item
                      href={Routes.locale_aware_path(assigns, "/admin/dashboard")}
                      icon="dashboard"
                      label="Dashboard"
                      current_path={@current_path || ""}
                    />

                    <%!-- Users section with direct link and conditional submenu --%>
                    <.admin_nav_item
                      href={Routes.locale_aware_path(assigns, "/admin/users")}
                      icon="users"
                      label="Users"
                      current_path={@current_path || ""}
                      disable_active={true}
                    />

                    <%= if submenu_open?(@current_path, ["/admin/users", "/admin/users/live_sessions", "/admin/users/sessions", "/admin/users/roles", "/admin/users/referral-codes"]) do %>
                      <%!-- Submenu items --%>
                      <div class="mt-1">
                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/users")}
                          icon="users"
                          label="Manage Users"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/users/live_sessions")}
                          icon="live_sessions"
                          label="Live Sessions"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/users/sessions")}
                          icon="sessions"
                          label="Sessions"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/users/roles")}
                          icon="roles"
                          label="Roles"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <%= if PhoenixKit.ReferralCodes.enabled?() do %>
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/users/referral-codes")}
                            icon="referral_codes"
                            label="Referral Codes"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>
                      </div>
                    <% end %>

                    <%= if PhoenixKit.Emails.enabled?() do %>
                      <%!-- Email section with direct link and conditional submenu --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/emails/dashboard")}
                        icon="email"
                        label="Emails"
                        current_path={@current_path || ""}
                        disable_active={true}
                      />

                      <%= if submenu_open?(@current_path, ["/admin/emails", "/admin/emails/dashboard", "/admin/modules/emails/templates", "/admin/emails/queue", "/admin/emails/blocklist"]) do %>
                        <%!-- Email submenu items --%>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails/dashboard")}
                            icon="email"
                            label="Dashboard"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails")}
                            icon="email"
                            label="Emails"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.path("/admin/modules/emails/templates")}
                            icon="email"
                            label="Templates"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails/queue")}
                            icon="email"
                            label="Queue"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails/blocklist")}
                            icon="email"
                            label="Blocklist"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        </div>
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Entities.enabled?() do %>
                      <%!-- Entities section with direct link and conditional submenu --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/entities")}
                        icon="entities"
                        label="Entities"
                        current_path={@current_path || ""}
                        disable_active={true}
                      />

                      <%= if submenu_open?(@current_path, ["/admin/entities"]) do %>
                        <%!-- Entities submenu items --%>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/entities")}
                            icon="entities"
                            label="Entities"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <%!-- Dynamically list each published entity (one level deeper) --%>
                          <div class="pl-4">
                            <%= for entity <- PhoenixKit.Entities.list_entities() do %>
                              <%= if entity.status == "published" do %>
                                <.admin_nav_item
                                  href={
                                    Routes.locale_aware_path(assigns, "/admin/entities/#{entity.name}/data")
                                  }
                                  icon={entity.icon || "hero-cube"}
                                  label={entity.display_name_plural || entity.display_name}
                                  current_path={@current_path || ""}
                                  nested={true}
                                />
                              <% end %>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Pages.enabled?() do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/pages")}
                        icon="document"
                        label="Pages"
                        current_path={@current_path || ""}
                      />
                    <% end %>

                    <.admin_nav_item
                      href={Routes.locale_aware_path(assigns, "/admin/modules")}
                      icon="modules"
                      label="Modules"
                      current_path={@current_path || ""}
                    />

                    <div class="mt-6 pt-6 border-t border-base-300">
                      <button
                        id="admin-generic-popup-button"
                        type="button"
                        aria-controls="admin-generic-popup"
                        aria-expanded="false"
                        class="group relative flex w-full items-center gap-4 rounded-2xl border border-primary/20 bg-primary/10 px-4 py-3 text-left transition hover:-translate-y-0.5 hover:bg-primary/15 hover:shadow-lg focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/60"
                      >
                        <span class="flex h-11 w-11 items-center justify-center rounded-xl bg-primary text-primary-content shadow-sm transition group-hover:scale-105">
                          <.icon name="hero-sparkles" class="w-5 h-5" />
                        </span>

                        <span class="text-base-content text-sm font-semibold tracking-wide">
                          Open Popup
                        </span>

                        <span class="pointer-events-none absolute inset-y-0 right-3 flex items-center text-primary/70 transition group-hover:text-primary">
                          <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
                        </span>
                      </button>
                    </div>

                    <%!-- Settings section with direct link and conditional submenu --%>
                    <.admin_nav_item
                      href={Routes.locale_aware_path(assigns, "/admin/settings")}
                      icon="settings"
                      label="Settings"
                      current_path={@current_path || ""}
                      disable_active={true}
                    />

                    <%= if submenu_open?(@current_path, ["/admin/settings", "/admin/settings/users", "/admin/settings/referral-codes", "/admin/settings/emails", "/admin/settings/languages", "/admin/settings/entities"]) do %>
                      <%!-- Settings submenu items --%>
                      <div class="mt-1">
                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/settings")}
                          icon="settings"
                          label="General"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <.admin_nav_item
                          href={Routes.locale_aware_path(assigns, "/admin/settings/users")}
                          icon="users"
                          label="Users"
                          current_path={@current_path || ""}
                          nested={true}
                        />

                        <%= if PhoenixKit.ReferralCodes.enabled?() do %>
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/settings/referral-codes")}
                            icon="referral_codes"
                            label="Referrals"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>

                        <%= if PhoenixKit.Emails.enabled?() do %>
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/settings/emails")}
                            icon="email"
                            label="Emails"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>

                        <%= if Languages.enabled?() do %>
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/settings/languages")}
                            icon="language"
                            label="Languages"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>

                        <%= if PhoenixKit.Modules.Maintenance.module_enabled?() do %>
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/settings/maintenance")}
                            icon="maintenance"
                            label="Maintenance"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>

                        <%= if PhoenixKit.Entities.enabled?() do %>
                          <.admin_nav_item
                            href={Routes.path("/admin/settings/entities")}
                            icon="entities"
                            label="Entities"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        <% end %>
                      </div>
                    <% end %>
                  </nav>
                </aside>
              </div>
            </div>

            <%!-- Auto-close mobile drawer on navigation --%>
            <script>
              // Popup state persistence (designed for multiple popups)
              // ============================================================================
              // POPUP STATE MANAGEMENT
              // ============================================================================
              // The popup system uses sessionStorage to persist state across LiveView
              // navigation and page refreshes. This allows the popup to maintain its
              // position, size, scroll, and open/closed state seamlessly.

              const POPUP_STORAGE_KEY = 'phoenix_kit_popups';
              const DEFAULT_POPUP_ID = 'admin-generic-popup';

              // Debounce helper to limit how often we save state during drag/resize
              // This prevents excessive writes to sessionStorage
              function debounce(func, wait) {
                let timeout;
                return function executedFunction(...args) {
                  const later = () => {
                    clearTimeout(timeout);
                    func(...args);
                  };
                  clearTimeout(timeout);
                  timeout = setTimeout(later, wait);
                };
              }

              // Load popup state from sessionStorage
              // Returns: { isOpen, position: {left, top}, size: {width, height}, scroll }
              function getPopupState(popupId) {
                try {
                  const allPopups = JSON.parse(sessionStorage.getItem(POPUP_STORAGE_KEY) || '{}');
                  return allPopups[popupId] || null;
                } catch (e) {
                  console.warn('[Popup] Failed to load state:', e);
                  return null;
                }
              }

              // Save popup state to sessionStorage and apply CSS variables
              // This is called during drag, resize, open/close, and scroll
              function savePopupState(popupId, state) {
                try {
                  const allPopups = JSON.parse(sessionStorage.getItem(POPUP_STORAGE_KEY) || '{}');
                  allPopups[popupId] = { ...allPopups[popupId], ...state };
                  sessionStorage.setItem(POPUP_STORAGE_KEY, JSON.stringify(allPopups));
                  console.log('[Popup] Saved state:', popupId, state);
                  applyPopupCssVars(allPopups[popupId]);
                } catch (e) {
                  console.warn('[Popup] Failed to save state:', e);
                }
              }

              // Apply popup state to CSS custom properties on document root
              // These CSS vars allow the template to access popup state for styling
              function applyPopupCssVars(state) {
                if (!state) return;

                const root = document.documentElement;

                if (state.position) {
                  root.style.setProperty('--phoenix-kit-popup-left', `${state.position.left}px`);
                  root.style.setProperty('--phoenix-kit-popup-top', `${state.position.top}px`);
                }

                if (state.size) {
                  root.style.setProperty('--phoenix-kit-popup-width', `${state.size.width}px`);
                  root.style.setProperty('--phoenix-kit-popup-height', `${state.size.height}px`);
                }

                if (state.isOpen !== undefined) {
                  root.style.setProperty('--phoenix-kit-popup-open', state.isOpen ? '1' : '0');
                }
              }


              // ============================================================================
              // SCROLL RESTORATION HELPERS
              // ============================================================================
              // These functions manage scroll position and overflow locking during
              // state restoration to prevent content from jumping or shifting

              // Lock content overflow during state restore to prevent layout shifts
              function lockContentOverflow(content) {
                if (!content) return;

                if (!content.dataset.originalOverflow) {
                  content.dataset.originalOverflow = content.style.overflow || '';
                }

                content.style.overflow = 'hidden';
                console.log('[Popup] Locked overflow on popup content during restore');
              }

              // Restore original overflow after state restore completes
              function unlockContentOverflow(content) {
                if (!content) return;

                const original = content.dataset.originalOverflow;

                if (original !== undefined) {
                  content.style.overflow = original;
                  delete content.dataset.originalOverflow;
                } else {
                  content.style.removeProperty('overflow');
                }
                console.log('[Popup] Restored overflow on popup content after animation');
              }


              // Apply saved popup state to CSS vars immediately on page load
              applyPopupCssVars(getPopupState('admin-generic-popup'));

              // Queue scroll restoration with retry logic
              // LiveView DOM updates can take multiple frames to settle, so we retry
              // until scroll position is stable for 2 consecutive frames
              function queueScrollRestore(target, popupId = DEFAULT_POPUP_ID, onComplete) {
                if (!target) {
                  console.log('[Popup] Scroll restore skipped - missing content target');
                  if (typeof onComplete === 'function') {
                    onComplete();
                  }
                  return;
                }

                const maxAttempts = 10;
                const minStableFrames = 2;
                let attempts = 0;
                let completed = false;
                let stableFrames = 0;
                console.log('[Popup] Scroll restore started', { popupId, maxAttempts, minStableFrames });

                const finish = () => {
                  if (!completed) {
                    completed = true;
                    console.log('[Popup] Scroll restore finished', { popupId, attempts, stableFrames });
                    if (typeof onComplete === 'function') {
                      onComplete();
                    }
                  }
                };

                const applyScroll = () => {
                  const savedState = getPopupState(popupId);

                  if (!savedState || !savedState.scroll) {
                    console.log('[Popup] Scroll restore aborted - no scroll data');
                    finish();
                    return;
                  }

                  const desiredTop = savedState.scroll.scrollTop || 0;
                  const desiredLeft = savedState.scroll.scrollLeft || 0;

                  console.log('[Popup] Applying scroll:', JSON.stringify({
                    desired: { top: desiredTop, left: desiredLeft },
                    before: { top: target.scrollTop, left: target.scrollLeft }
                  }));

                  target.scrollTop = desiredTop;
                  target.scrollLeft = desiredLeft;

                  console.log('[Popup] After setting scroll:', JSON.stringify({
                    actual: { top: target.scrollTop, left: target.scrollLeft }
                  }));

                  attempts += 1;

                  const withinTolerance =
                    Math.abs(target.scrollTop - desiredTop) <= 1 &&
                    Math.abs(target.scrollLeft - desiredLeft) <= 1;

                  if (withinTolerance) {
                    stableFrames += 1;

                    if (stableFrames >= minStableFrames || attempts >= maxAttempts) {
                      finish();
                      return;
                    }
                  } else {
                    stableFrames = 0;
                  }

                  if (!completed && attempts < maxAttempts) {
                    requestAnimationFrame(applyScroll);
                  } else {
                    finish();
                  }
                };

                applyScroll();
              }

              // ============================================================================
              // GLOBAL STATE FLAGS
              // ============================================================================
              // These window-level flags persist across LiveView DOM replacements
              // allowing us to maintain popup state during navigation

              window.__popupIsInitialized = window.__popupIsInitialized || false;
              window.__popupIsInteracting = false; // Prevents restore during drag/resize
              window.__popupFullInitObserver = window.__popupFullInitObserver || null;
              window.__popupSkipReinitObserver = window.__popupSkipReinitObserver || null;

              // ============================================================================
              // MAIN INITIALIZATION FUNCTION
              // ============================================================================
              // This function runs on initial page load AND after each LiveView navigation
              // It handles two paths:
              // 1. First-time init: Sets up all event listeners and observers
              // 2. Re-init after navigation: Updates DOM references and event listeners

              function initAdminPopup() {
                const container = document.getElementById('admin-generic-popup');
                const openButton = document.getElementById('admin-generic-popup-button');

                // Can't initialize without required elements
                // This happens when navigating to pages without a popup (e.g., Emails page)
                // We mark as not initialized and exit gracefully - the popup state is preserved
                // in sessionStorage so when user navigates back to a page with popup, it reopens
                if (!container || !openButton) {
                  console.warn('[Popup] Skipping init - missing elements (popup state preserved)', {
                    container: !!container,
                    openButton: !!openButton,
                    preservedState: getPopupState('admin-generic-popup')
                  });
                  window.__popupIsInitialized = false;
                  return;
                }

                const panel = container.querySelector('[data-popup-panel]');
                const handle = container.querySelector('[data-popup-handle]');
                const closeButtons = container.querySelectorAll('[data-popup-close]');
                const resizeHandle = container.querySelector('[data-popup-resize-handle]');
                const content = container.querySelector('[data-popup-content]');
                const popupId = container.id;

                // Apply saved state immediately to prevent flash of unstyled content
                applyPopupCssVars(getPopupState(popupId));

                // ========================================================================
                // RE-INITIALIZATION PATH (after navigation)
                // ========================================================================
                // When LiveView navigates, phx:page-loading-stop calls initAdminPopup()
                // The DOM is replaced but our global flags remain
                // We need to re-attach event listeners to the new DOM elements

                const wasAlreadyInitialized = window.__popupIsInitialized;
                if (wasAlreadyInitialized) {
                  console.log('[Popup] Re-running initialization for new DOM elements after navigation');

                  // Clean up old observers that are watching the old (removed) DOM
                  if (window.__popupFullInitObserver) {
                    window.__popupFullInitObserver.disconnect();
                    window.__popupFullInitObserver = null;
                    console.log('[Popup] Disconnected full-init observer after DOM replace');
                  }

                  if (window.__popupSkipReinitObserver) {
                    window.__popupSkipReinitObserver.disconnect();
                    window.__popupSkipReinitObserver = null;
                  }

                  if (panel) {
                    // Mark this panel as initialized
                    panel.style.setProperty('--popup-initialized', '1');

                    // Create a restore function that gets FRESH DOM references
                    // This is critical because after navigation, the old DOM elements
                    // are gone and we need to work with the new ones
                    window.__popupRestoreState = function() {
                      // Don't interfere with active drag/resize operations
                      if (window.__popupIsInteracting) {
                        console.log('[Popup] Skipping restore - user is interacting');
                        return;
                      }

                      // Get fresh references - the old ones are invalid after navigation
                      const currentContainer = document.getElementById(popupId);
                      const currentPanel = currentContainer?.querySelector('[data-popup-panel]');
                      const currentOpenButton = document.getElementById(popupId + '-button');

                      console.log('[Popup] __popupRestoreState invoked', {
                        interacting: window.__popupIsInteracting,
                        containerInDom: !!currentContainer,
                        panelInDom: !!currentPanel,
                        buttonInDom: !!currentOpenButton
                      });

                      // Bail if elements don't exist (we might be on a different page)
                      if (!currentContainer || !currentPanel || !currentOpenButton) {
                        console.log('[Popup] Skipping restore - popup elements not found in current DOM');
                        return;
                      }

                      const savedState = getPopupState(popupId);
                      if (!savedState) {
                        console.log('[Popup] No saved state available for restore; skipping');
                        return;
                      }

                      console.log('[Popup] Restoring state to new panel after navigation:', savedState);

                      const currentContent = currentPanel.querySelector('[data-popup-content]');

                      applyPopupCssVars(savedState);

                      // Restore position (where user dragged it to)
                      if (savedState.position) {
                        currentPanel.style.left = `${savedState.position.left}px`;
                        currentPanel.style.top = `${savedState.position.top}px`;
                      }

                      // Restore size (what user resized it to)
                      if (savedState.size) {
                        currentPanel.style.width = `${savedState.size.width}px`;
                        currentPanel.style.height = `${savedState.size.height}px`;
                      }

                      let shouldAnimate = false;

                      if (savedState.isOpen) {
                        // Restore open state without animation
                        // ANTI-FLICKER: Don't animate - popup should just stay where it was
                        currentContainer.style.display = 'block';
                        currentContainer.setAttribute('aria-hidden', 'false');
                        currentOpenButton.setAttribute('aria-expanded', 'true');

                        shouldAnimate = false;
                        currentPanel.style.removeProperty('visibility');
                        currentPanel.style.removeProperty('opacity');
                        currentPanel.style.removeProperty('transform');
                        console.log('[Popup] Skip-reinit: keeping popup open without animation');
                      } else {
                        // Popup was closed - keep it closed
                        currentContainer.style.display = 'none';
                        console.log('[Popup] Restoring popup as closed (skip path)');
                      }

                      // Lock overflow during scroll restore to prevent jumps
                      lockContentOverflow(currentContent);

                      // Restore scroll position and complete the restore process
                      queueScrollRestore(currentContent, popupId, () => {
                        currentPanel.style.removeProperty('visibility');

                        if (savedState.isOpen) {
                          if (shouldAnimate) {
                            // Fade in animation (currently never used - shouldAnimate is always false)
                            currentPanel.style.transition = 'opacity 120ms ease, transform 120ms ease';
                            currentPanel.style.opacity = '1';
                            currentPanel.style.transform = 'translateY(0)';

                            setTimeout(() => {
                              currentPanel.style.removeProperty('transition');
                            }, 150);
                          } else {
                            // No animation - just ensure clean state
                            currentPanel.style.removeProperty('opacity');
                            currentPanel.style.removeProperty('transform');
                            currentPanel.style.removeProperty('transition');
                          }
                        } else {
                          // Popup closed - clean up any animation styles
                          currentPanel.style.removeProperty('opacity');
                          currentPanel.style.removeProperty('transform');
                          currentPanel.style.removeProperty('transition');
                        }

                        unlockContentOverflow(currentContent);
                        window.__popupRestoredDuringInit = false;
                      });
                    };

                    // Run restore immediately if we have the function defined
                    if (typeof window.__popupRestoreState === 'function') {
                      window.__popupRestoreState();
                    }

                    // ================================================================
                    // MUTATION OBSERVER (Re-init path)
                    // ================================================================
                    // Watch for LiveView clearing our styles and restore them
                    // This is a safety net for small DOM updates that don't trigger
                    // full navigation (like phx-update patches)

                    const skipObserver = new MutationObserver((mutations) => {
                      for (const mutation of mutations) {
                        if (mutation.type === 'attributes' && mutation.attributeName === 'style') {
                          const timestamp = new Date().toISOString().split('T')[1];
                          const hasMarker = panel.style.getPropertyValue('--popup-initialized');
                          const currentStyles = {
                            left: panel.style.left,
                            top: panel.style.top,
                            width: panel.style.width,
                            height: panel.style.height
                          };

                          // LiveView might clear inline styles during patches
                          const stylesCleared = !panel.style.left && !panel.style.top;

                          console.log(`[${timestamp}] [Popup] Observer (skip-reinit) detected style change, marker:`, !!hasMarker, 'styles cleared:', stylesCleared, 'styles:', currentStyles);

                          // Restore if LiveView cleared our styles
                          if (!hasMarker || stylesCleared) {
                            console.log(`[${timestamp}] [Popup] LiveView cleared styles - RESTORING NOW`);
                            const savedState = getPopupState(popupId);
                            if (savedState) {
                              skipObserver.disconnect();

                              if (savedState.position) {
                                panel.style.left = `${savedState.position.left}px`;
                                panel.style.top = `${savedState.position.top}px`;
                              }
                              if (savedState.size) {
                                panel.style.width = `${savedState.size.width}px`;
                                panel.style.height = `${savedState.size.height}px`;
                              }

                              panel.style.setProperty('--popup-initialized', '1');

                              // Reconnect to catch future patches
                              skipObserver.observe(panel, {
                                attributes: true,
                                attributeFilter: ['style']
                              });
                            }
                          }
                        }
                      }
                    });

                    skipObserver.observe(panel, {
                      attributes: true,
                      attributeFilter: ['style']
                    });
                    window.__popupSkipReinitObserver = skipObserver;
                    console.log('[Popup] Skip-reinit observer started watching panel element:', panel);
                  }
                  // IMPORTANT: Fall through to re-run full initialization
                  // This re-attaches all event listeners to the new DOM elements
                }

                // ========================================================================
                // FIRST-TIME INITIALIZATION PATH (and re-init continuation)
                // ========================================================================
                // Both first load and after navigation reach this point
                // The difference: wasAlreadyInitialized determines if we skip animations

                if (!panel || !handle) {
                  console.warn('[Popup] Missing panel or handle', { hasPanel: !!panel, hasHandle: !!handle });
                  return;
                }

                if (wasAlreadyInitialized) {
                  console.log('[Popup] Re-initializing popup after navigation - will skip animations');
                }

                console.log(wasAlreadyInitialized ? '[Popup] Re-initialization after navigation:' : '[Popup] First-time initialization:', popupId);

                // ================================================================
                // DRAG/RESIZE STATE VARIABLES
                // ================================================================
                // These are stored globally and ONLY initialized once
                // During navigation, we keep these values so drag/resize state persists
                // This prevents the popup from resetting during active drag operations

                if (!window.__popupState) {
                  window.__popupState = {
                    isOpen: false,
                    isDragging: false,
                    dragPointerId: null,
                    dragOffsetX: 0,
                    dragOffsetY: 0,
                    isResizing: false,
                    resizePointerId: null,
                    startWidth: 0,
                    startHeight: 0,
                    startX: 0,
                    startY: 0
                  };
                }

                // Destructure global state into local variables for initial reference
                // NOTE: These are NOT used by event handlers - handlers read directly from window.__popupState
                // This destructuring only provides initial values for logic below
                // Event handlers MUST read window.__popupState to get current values (not stale copies)
                let { isOpen, isDragging, dragPointerId, dragOffsetX, dragOffsetY, isResizing, resizePointerId, startWidth, startHeight, startX, startY } = window.__popupState;

                // ================================================================
                // STATE RESTORE FUNCTION (First initialization only)
                // ================================================================
                // Restores popup state from sessionStorage on initial page load
                // This is NOT called on re-init after navigation (that uses window.__popupRestoreState)

                const restoreState = () => {
                  const savedState = getPopupState(popupId);
                  console.log('[Popup] Restoring state from sessionStorage:', savedState);

                  if (!savedState) {
                    console.log('[Popup] No saved state found on initial load; leaving popup closed');
                    return false;
                  }

                  applyPopupCssVars(savedState);

                  // Restore position (where user dragged it to)
                  if (savedState.position) {
                    panel.style.left = `${savedState.position.left}px`;
                    panel.style.top = `${savedState.position.top}px`;
                  }

                  // Restore size (what user resized it to)
                  if (savedState.size) {
                    panel.style.width = `${savedState.size.width}px`;
                    panel.style.height = `${savedState.size.height}px`;
                  }

                  let shouldAnimate = false;

                  if (savedState.isOpen) {
                    // Restore open state
                    container.style.display = 'block';
                    container.setAttribute('aria-hidden', 'false');
                    openButton.setAttribute('aria-expanded', 'true');
                    window.__popupState.isOpen = true;

                    // ANTI-FLICKER: No animation on page refresh - popup should appear
                    // instantly in its saved state
                    shouldAnimate = false;
                    panel.style.removeProperty('visibility');
                    panel.style.removeProperty('opacity');
                    panel.style.removeProperty('transform');
                    console.log('[Popup] Full-init: restoring popup as open without animation');
                  } else {
                    // Popup was closed - keep it closed
                    container.style.display = 'none';
                    console.log('[Popup] Restoring popup as closed (init path)');
                  }

                  // Lock overflow during scroll restore
                  lockContentOverflow(content);

                  // Restore scroll position
                  queueScrollRestore(content, popupId, () => {
                    panel.style.removeProperty('visibility');

                    if (savedState.isOpen) {
                      if (shouldAnimate) {
                        // Fade in animation (currently never used - shouldAnimate is always false)
                        panel.style.transition = 'opacity 120ms ease, transform 120ms ease';
                        panel.style.opacity = '1';
                        panel.style.transform = 'translateY(0)';

                        setTimeout(() => {
                          panel.style.removeProperty('transition');
                        }, 150);
                      } else {
                        // No animation - just ensure clean state
                        panel.style.removeProperty('opacity');
                        panel.style.removeProperty('transform');
                        panel.style.removeProperty('transition');
                      }
                    } else {
                      // Popup closed - clean up any animation styles
                      panel.style.removeProperty('opacity');
                      panel.style.removeProperty('transform');
                      panel.style.removeProperty('transition');
                    }

                    unlockContentOverflow(content);
                  });

                  return savedState;
                };

                // ================================================================
                // HELPER FUNCTIONS
                // ================================================================

                // Center the popup panel within the container
                // Used when showing popup for the first time
                const centerPanel = () => {
                  console.log('[Popup] Center panel - start');
                  panel.style.width = '';
                  panel.style.height = '';

                  const containerRect = container.getBoundingClientRect();
                  const panelRect = panel.getBoundingClientRect();

                  const containerWidth = containerRect.width || window.innerWidth || panelRect.width || 448;
                  const containerHeight = containerRect.height || window.innerHeight || panelRect.height || 320;
                  const width = panelRect.width || 448;
                  const height = panelRect.height || 320;

                  const left = Math.max(0, Math.round((containerWidth - width) / 2));
                  const top = Math.max(0, Math.round(containerHeight * 0.2));

                  console.log('[Popup] Center panel - calculated', {
                    containerRect: { width: containerRect.width, height: containerRect.height, left: containerRect.left, top: containerRect.top },
                    panelRect: { width: panelRect.width, height: panelRect.height, left: panelRect.left, top: panelRect.top },
                    calculated: { containerWidth, containerHeight, panelWidth: width, panelHeight: height },
                    finalPosition: { left, top },
                    calculation: `(${containerWidth} - ${width}) / 2 = ${left}`
                  });

                  panel.style.transform = '';
                  panel.style.left = `${left}px`;
                  panel.style.top = `${top}px`;
                };

                // Ensure popup stays within container bounds
                // Prevents dragging popup completely off-screen
                const clampPosition = (left, top) => {
                  const containerRect = container.getBoundingClientRect();
                  const panelRect = panel.getBoundingClientRect();
                  const maxLeft = Math.max(0, containerRect.width - panelRect.width);
                  const maxTop = Math.max(0, containerRect.height - panelRect.height);

                  const clamped = {
                    left: Math.min(Math.max(0, left), maxLeft),
                    top: Math.min(Math.max(0, top), maxTop)
                  };
                  console.log('[Popup] Clamp position', { left, top, clamped, maxLeft, maxTop });
                  return clamped;
                };

                // Clean up drag operation - release pointer capture and remove event listeners
                const stopDragging = () => {
                  // Read from window.__popupState to get current values (not stale local copies)
                  if (!window.__popupState.isDragging) {
                    return;
                  }

                  console.log('[Popup] Stop dragging');

                  // Release pointer capture
                  if (handle.releasePointerCapture && window.__popupState.dragPointerId !== null) {
                    try {
                      handle.releasePointerCapture(window.__popupState.dragPointerId);
                    } catch (_error) {}
                  }

                  // Update global state
                  window.__popupState.isDragging = false;
                  window.__popupState.dragPointerId = null;
                  window.removeEventListener('pointermove', handleDragMove);
                  window.removeEventListener('pointerup', endDrag);
                  window.removeEventListener('pointercancel', endDrag);

                  // Save final position to sessionStorage
                  const currentPosition = {
                    left: parseInt(panel.style.left) || 0,
                    top: parseInt(panel.style.top) || 0
                  };
                  savePopupState(popupId, { position: currentPosition });

                  // Clear interaction flag
                  const timestamp = new Date().toISOString().split('T')[1];
                  console.log(`[${timestamp}] [Popup] Clearing interaction flag after drag`);
                  window.__popupIsInteracting = false;

                  // Force restore position in case LiveView changed it during drag
                  requestAnimationFrame(() => {
                    panel.style.left = `${currentPosition.left}px`;
                    panel.style.top = `${currentPosition.top}px`;
                    console.log('[Popup] Re-applied position after drag to override any LiveView changes');
                  });
                };

                // Clean up resize operation - release pointer capture and remove event listeners
                const stopResizing = () => {
                  // Read from window.__popupState to get current values (not stale local copies)
                  if (!window.__popupState.isResizing) {
                    return;
                  }

                  console.log('[Popup] Stop resizing');

                  // Release pointer capture
                  if (resizeHandle && resizeHandle.releasePointerCapture && window.__popupState.resizePointerId !== null) {
                    try {
                      resizeHandle.releasePointerCapture(window.__popupState.resizePointerId);
                    } catch (_error) {}
                  }

                  // Update global state
                  window.__popupState.isResizing = false;
                  window.__popupState.resizePointerId = null;
                  window.removeEventListener('pointermove', handleResizeMove);
                  window.removeEventListener('pointerup', endResize);
                  window.removeEventListener('pointercancel', endResize);

                  // Save final size to sessionStorage
                  const currentSize = {
                    width: parseInt(panel.style.width) || panel.offsetWidth,
                    height: parseInt(panel.style.height) || panel.offsetHeight
                  };
                  savePopupState(popupId, { size: currentSize });

                  // Clear interaction flag to allow state restore
                  const timestamp = new Date().toISOString().split('T')[1];
                  console.log(`[${timestamp}] [Popup] Clearing interaction flag after resize`);
                  window.__popupIsInteracting = false;

                  // Re-apply size to override any LiveView changes during resize
                  requestAnimationFrame(() => {
                    panel.style.width = `${currentSize.width}px`;
                    panel.style.height = `${currentSize.height}px`;
                    console.log('[Popup] Re-applied size after resize to override any LiveView changes');
                  });
                };

                // Local show/hide functions (used during first initialization)
                // Note: Global versions (window.__popupShowPopup, etc.) are defined later
                // and are used after navigation
                const showPopup = () => {
                  centerPanel();
                  console.log('[Popup] Show');
                  container.style.display = 'block';
                  container.setAttribute('aria-hidden', 'false');
                  openButton.setAttribute('aria-expanded', 'true');
                  window.__popupState.isOpen = true;
                  panel.focus({ preventScroll: true });
                  document.addEventListener('keydown', handleKeydown);

                  savePopupState(popupId, { isOpen: true });
                };

                const hidePopup = () => {
                  // Read from window.__popupState to get current value (not stale local copy)
                  if (!window.__popupState.isOpen) {
                    return;
                  }

                  console.log('[Popup] Hide');

                  // Stop any active drag/resize operations
                  stopDragging();
                  stopResizing();

                  container.setAttribute('aria-hidden', 'true');
                  openButton.setAttribute('aria-expanded', 'false');
                  container.style.display = 'none';
                  window.__popupState.isOpen = false;

                  document.removeEventListener('keydown', handleKeydown);

                  savePopupState(popupId, { isOpen: false });
                };

                // Store functions globally that work with current DOM elements
                // ================================================================
                // POPUP OPEN/CLOSE/TOGGLE FUNCTIONS
                // ================================================================
                // These global functions are called by the toggle button and close buttons
                // They're global so they persist across navigation and can be called
                // from anywhere (including onclick handlers in the template)

                window.__popupShowPopup = function() {
                  const container = document.getElementById('admin-generic-popup');
                  const openButton = document.getElementById('admin-generic-popup-button');
                  const panel = container?.querySelector('[data-popup-panel]');
                  const content = container?.querySelector('[data-popup-content]');
                  if (!container || !panel || !openButton) return;

                  console.log('[Popup] Show - resetting to default size and centered position');

                  // RESET FIX: Clear all custom size/position when manually opening
                  // This prevents the "tiny popup" bug from bad saved state
                  panel.style.removeProperty('left');
                  panel.style.removeProperty('top');
                  panel.style.removeProperty('width');
                  panel.style.removeProperty('height');

                  // Center the popup with default size
                  const containerRect = container.getBoundingClientRect();
                  const panelRect = panel.getBoundingClientRect();
                  const containerWidth = containerRect.width || window.innerWidth || panelRect.width || 448;
                  const containerHeight = containerRect.height || window.innerHeight || panelRect.height || 320;
                  const width = panelRect.width || 448;
                  const height = panelRect.height || 320;
                  const left = Math.max(0, Math.round((containerWidth - width) / 2));
                  const top = Math.max(0, Math.round(containerHeight * 0.2));

                  panel.style.left = `${left}px`;
                  panel.style.top = `${top}px`;

                  container.style.display = 'block';
                  container.setAttribute('aria-hidden', 'false');
                  openButton.setAttribute('aria-expanded', 'true');
                  panel.focus({ preventScroll: true });

                  // Save the clean centered state
                  savePopupState('admin-generic-popup', {
                    isOpen: true,
                    position: { left, top },
                    size: { width, height }
                  });

                  queueScrollRestore(content, 'admin-generic-popup');
                };

                window.__popupHidePopup = function() {
                  const container = document.getElementById('admin-generic-popup');
                  const openButton = document.getElementById('admin-generic-popup-button');
                  if (!container || !openButton) return;

                  console.log('[Popup] Hide');
                  container.setAttribute('aria-hidden', 'true');
                  openButton.setAttribute('aria-expanded', 'false');
                  container.style.display = 'none';

                  savePopupState('admin-generic-popup', { isOpen: false });
                };

                window.__popupToggle = function() {
                  console.log('[Popup] Toggle button clicked');
                  const container = document.getElementById('admin-generic-popup');
                  if (!container) return;

                  const isCurrentlyOpen = container.style.display !== 'none';
                  if (isCurrentlyOpen) {
                    window.__popupHidePopup();
                  } else {
                    window.__popupShowPopup();
                  }
                };

                // ================================================================
                // DRAG & RESIZE EVENT HANDLERS
                // ================================================================
                // These handlers use pointer events for smooth dragging/resizing
                // with pointer capture to prevent losing the mouse during fast movements
                // They save state periodically to sessionStorage during the operation
                //
                // CRITICAL: All handlers read state from window.__popupState directly
                // to get current values (not stale local copies from destructuring)

                const endDrag = (event) => {
                  console.log('[Popup] End drag');
                  // Read from window.__popupState to get current values (not stale local copies)
                  if (!window.__popupState.isDragging || (window.__popupState.dragPointerId !== null && event.pointerId !== window.__popupState.dragPointerId)) {
                    return;
                  }

                  stopDragging();
                };

                // Debounced save during drag to avoid excessive writes to sessionStorage
                let dragSaveTimeout = null;
                const saveDragState = () => {
                  if (dragSaveTimeout) {
                    clearTimeout(dragSaveTimeout);
                  }
                  dragSaveTimeout = setTimeout(() => {
                    savePopupState(popupId, {
                      position: {
                        left: parseInt(panel.style.left) || 0,
                        top: parseInt(panel.style.top) || 0
                      }
                    });
                  }, 100); // Save every 100ms during drag
                };

                const handleDragMove = (event) => {
                  // Read from window.__popupState to get current values (not stale local copies)
                  if (!window.__popupState.isDragging) {
                    return;
                  }

                  const containerRect = container.getBoundingClientRect();
                  const mouseXInContainer = event.clientX - containerRect.left;
                  const mouseYInContainer = event.clientY - containerRect.top;
                  const nextLeft = mouseXInContainer - window.__popupState.dragOffsetX;
                  const nextTop = mouseYInContainer - window.__popupState.dragOffsetY;
                  const clamped = clampPosition(nextLeft, nextTop);

                  console.log('[Popup] Drag move', {
                    pointer: { x: event.clientX, y: event.clientY },
                    mouseInContainer: { x: mouseXInContainer, y: mouseYInContainer },
                    containerLeft: containerRect.left,
                    containerTop: containerRect.top,
                    dragOffsetX: window.__popupState.dragOffsetX,
                    dragOffsetY: window.__popupState.dragOffsetY,
                    nextLeft,
                    nextTop,
                    clamped
                  });

                  panel.style.left = `${clamped.left}px`;
                  panel.style.top = `${clamped.top}px`;

                  // Save state periodically during drag (debounced)
                  saveDragState();
                };

                // Initialize drag operation when user grabs the handle
                const startDrag = (event) => {
                  // Only respond to left mouse button
                  if (event.button !== undefined && event.button !== 0) {
                    return;
                  }

                  console.log('[Popup] Start drag', { pointer: { x: event.clientX, y: event.clientY } });

                  event.preventDefault();
                  window.__popupIsInteracting = true; // Prevent state restore during drag

                  // Get fresh DOM references (important after navigation)
                  const container = document.getElementById('admin-generic-popup');
                  const panel = container?.querySelector('[data-popup-panel]');
                  const handle = container?.querySelector('[data-popup-handle]');
                  if (!container || !panel || !handle) return;

                  const containerRect = container.getBoundingClientRect();

                  // Clear any transform and get current position
                  panel.style.transform = '';
                  const panelRect = panel.getBoundingClientRect();
                  const handleRect = handle.getBoundingClientRect();

                  const currentLeft = panelRect.left - containerRect.left;
                  const currentTop = panelRect.top - containerRect.top;
                  panel.style.left = `${currentLeft}px`;
                  panel.style.top = `${currentTop}px`;

                  // Store drag state globally
                  window.__popupState.isDragging = true;
                  window.__popupState.dragPointerId = event.pointerId;

                  // Calculate offset between mouse and panel corner
                  // This keeps the panel from jumping when drag starts
                  const mouseXInContainer = event.clientX - containerRect.left;
                  const mouseYInContainer = event.clientY - containerRect.top;
                  window.__popupState.dragOffsetX = mouseXInContainer - currentLeft;
                  window.__popupState.dragOffsetY = mouseYInContainer - currentTop;

                  console.log('[Popup] Start drag - Initial state', {
                    mouse: { clientX: event.clientX, clientY: event.clientY },
                    mouseInContainer: { x: mouseXInContainer, y: mouseYInContainer },
                    panelPosition: { left: currentLeft, top: currentTop },
                    container: { left: containerRect.left, top: containerRect.top },
                    calculatedOffset: { x: window.__popupState.dragOffsetX, y: window.__popupState.dragOffsetY },
                    verification: {
                      shouldEqual_mouseX: `${mouseXInContainer} should equal ${currentLeft} + ${window.__popupState.dragOffsetX} = ${currentLeft + window.__popupState.dragOffsetX}`,
                      matches: mouseXInContainer === currentLeft + window.__popupState.dragOffsetX
                    }
                  });

                  // Capture pointer to this element for smooth dragging
                  if (handle.setPointerCapture) {
                    try {
                      handle.setPointerCapture(event.pointerId);
                    } catch (_error) {}
                  }

                  // Attach global event listeners for drag operation
                  window.addEventListener('pointermove', handleDragMove);
                  window.addEventListener('pointerup', endDrag);
                  window.addEventListener('pointercancel', endDrag);
                };

                // End resize operation (called on pointerup/pointercancel)
                const endResize = (event) => {
                  // Read from window.__popupState to get current values (not stale local copies)
                  if (!window.__popupState.isResizing || (window.__popupState.resizePointerId !== null && event.pointerId !== window.__popupState.resizePointerId)) {
                    return;
                  }

                  stopResizing();
                };

                // Debounced save during resize to handle LiveView updates
                let resizeSaveTimeout = null;
                const saveResizeState = () => {
                  if (resizeSaveTimeout) {
                    clearTimeout(resizeSaveTimeout);
                  }
                  resizeSaveTimeout = setTimeout(() => {
                    savePopupState(popupId, {
                      size: {
                        width: parseInt(panel.style.width) || panel.offsetWidth,
                        height: parseInt(panel.style.height) || panel.offsetHeight
                      }
                    });
                  }, 100); // Save every 100ms during resize
                };

                const handleResizeMove = (event) => {
                  // Read from window.__popupState to get current values (not stale local copies)
                  if (!window.__popupState.isResizing) {
                    return;
                  }

                  // MINIMUM SIZE CONSTRAINT: Prevent popup from being resized smaller than 200x200px
                  // This prevents the "tiny popup" issue and ensures usability
                  const nextWidth = Math.max(200, window.__popupState.startWidth + (event.clientX - window.__popupState.startX));
                  const nextHeight = Math.max(200, window.__popupState.startHeight + (event.clientY - window.__popupState.startY));

                  console.log('[Popup] Resize move', { nextWidth, nextHeight });

                  panel.style.width = `${nextWidth}px`;
                  panel.style.height = `${nextHeight}px`;

                  // Save state periodically during resize (debounced)
                  saveResizeState();
                };

                // Initialize resize operation when user grabs the resize handle
                const startResize = (event) => {
                  // Only respond to left mouse button
                  if (!resizeHandle || (event.button !== undefined && event.button !== 0)) {
                    return;
                  }

                  console.log('[Popup] Start resize', { x: event.clientX, y: event.clientY });

                  event.preventDefault();
                  window.__popupIsInteracting = true; // Prevent state restore during resize

                  const containerRect = container.getBoundingClientRect();

                  // Clear any transform and lock position during resize
                  panel.style.transform = '';
                  const panelRect = panel.getBoundingClientRect();
                  panel.style.left = `${panelRect.left - containerRect.left}px`;
                  panel.style.top = `${panelRect.top - containerRect.top}px`;

                  // Store resize state globally
                  window.__popupState.isResizing = true;
                  window.__popupState.resizePointerId = event.pointerId;
                  window.__popupState.startWidth = panelRect.width;
                  window.__popupState.startHeight = panelRect.height;
                  window.__popupState.startX = event.clientX;
                  window.__popupState.startY = event.clientY;

                  // Capture pointer for smooth resizing
                  if (resizeHandle.setPointerCapture) {
                    try {
                      resizeHandle.setPointerCapture(event.pointerId);
                    } catch (_error) {}
                  }

                  // Attach global event listeners for resize operation
                  window.addEventListener('pointermove', handleResizeMove);
                  window.addEventListener('pointerup', endResize);
                  window.addEventListener('pointercancel', endResize);
                };

                // Handle Escape key to close popup
                const handleKeydown = (event) => {
                  console.log('[Popup] Keydown', event.key);
                  // Read from window.__popupState to get current value (not stale local copy)
                  if (!window.__popupState.isOpen) {
                    return;
                  }

                  if (event.key === 'Escape') {
                    event.preventDefault();
                    hidePopup();
                  }
                };

                // ================================================================
                // STATE RESTORATION (Different behavior for first-init vs re-init)
                // ================================================================
                // First-time: Restore from sessionStorage and set display accordingly
                // Re-init: Skip restore (already handled by skip-reinit path above)
                //
                // WHY: The skip-reinit path (window.__popupRestoreState) runs BEFORE
                // this full-init code and already restored position/size/open state.
                // Running restore logic again here would override that and close the popup.

                console.log('[Popup] About to restore state, current panel styles:', {
                  left: panel.style.left,
                  top: panel.style.top,
                  width: panel.style.width,
                  height: panel.style.height
                });

                let restored = false;
                if (!wasAlreadyInitialized) {
                  // ============================================================
                  // FIRST-TIME INITIALIZATION PATH
                  // ============================================================
                  // Restore from sessionStorage and set display/listeners

                  restored = restoreState();
                  window.__popupRestoredDuringInit = !!restored;
                  console.log('[Popup] restoreState result (first init)', {
                    restored: !!restored,
                    restoredDuringInit: window.__popupRestoredDuringInit
                  });

                  console.log('[Popup] After restore, panel styles:', {
                    left: panel.style.left,
                    top: panel.style.top,
                    width: panel.style.width,
                    height: panel.style.height,
                    restored: !!restored
                  });

                  // Set display and listeners based on restored state
                  if (!restored) {
                    // No saved state in sessionStorage, popup starts closed
                    console.log('[Popup] No saved state, using defaults');
                    container.style.display = 'none';
                  } else if (restored.isOpen) {
                    // Popup was previously open, restore as open and add keydown listener
                    console.log('[Popup] Popup restored as open, container display:', container.style.display);
                    document.addEventListener('keydown', handleKeydown);
                  } else {
                    // Saved state exists but popup was closed
                    console.log('[Popup] Popup restored as closed');
                    container.style.display = 'none';
                  }
                } else {
                  // ============================================================
                  // RE-INITIALIZATION AFTER NAVIGATION PATH
                  // ============================================================
                  // Skip all restore logic - the skip-reinit path already restored state
                  // We only need to re-attach the keydown listener if popup is open

                  console.log('[Popup] Skipping restoreState on re-init - state already restored via skip-reinit');

                  // Re-attach keydown listener if popup is currently open
                  const savedState = getPopupState(popupId);
                  if (savedState?.isOpen) {
                    console.log('[Popup] Re-init: popup is open, re-attaching keydown listener');
                    document.addEventListener('keydown', handleKeydown);
                  }
                }

                // Add marker to detect when LiveView strips inline styles
                // This custom property will disappear when LiveView resets the panel
                panel.style.setProperty('--popup-initialized', '1');
                console.log('[Popup] Marker set, initialization about to complete');

                // ================================================================
                // EVENT LISTENER ATTACHMENT
                // ================================================================
                // Attach all event listeners to the current DOM elements
                // On re-init after navigation, we remove old listeners first to avoid duplicates

                // Store handlers globally for reattachment after navigation
                window.__popupStartDrag = startDrag;
                window.__popupStartResize = startResize;

                // Drag handle - remove old listener first (for re-init)
                handle.removeEventListener('pointerdown', window.__popupStartDrag);
                handle.addEventListener('pointerdown', startDrag);

                // Close buttons - remove old listeners first (for re-init)
                closeButtons.forEach((button) => {
                  button.removeEventListener('click', window.__popupHidePopup);
                  button.addEventListener('click', window.__popupHidePopup);
                });

                // Resize handle - remove old listener first (for re-init)
                if (resizeHandle) {
                  resizeHandle.removeEventListener('pointerdown', window.__popupStartResize);
                  resizeHandle.addEventListener('pointerdown', startResize);
                }

                // Toggle button - remove old listener first (for re-init)
                openButton.removeEventListener('click', window.__popupToggle);
                openButton.addEventListener('click', window.__popupToggle);

                // ================================================================
                // SCROLL POSITION SAVING
                // ================================================================
                // Save scroll position to sessionStorage as user scrolls
                // Re-attach listener when LiveView updates content (to handle fresh DOM)

                if (content) {
                  let scrollListener = null;

                  const attachScrollListener = () => {
                    // Remove old listener if it exists (cleanup for re-attachment)
                    if (scrollListener) {
                      content.removeEventListener('scroll', scrollListener);
                    }

                    // Create new debounced scroll handler (prevents excessive saves)
                    scrollListener = debounce(() => {
                      savePopupState(popupId, {
                        scroll: {
                          scrollTop: content.scrollTop,
                          scrollLeft: content.scrollLeft
                        }
                      });
                    }, 250);

                    content.addEventListener('scroll', scrollListener);
                    console.log('[Popup] Scroll listener attached/re-attached');
                  };

                  // Store globally for reattachment after navigation
                  window.__popupAttachScrollListener = attachScrollListener;

                  // Initial attachment
                  attachScrollListener();

                  // Re-attach scroll listener when LiveView updates content
                  // This ensures scroll saving works even after LiveView patches
                  const contentObserver = new MutationObserver(() => {
                    console.log('[Popup] Content changed, re-attaching scroll listener');
                    attachScrollListener();

                    queueScrollRestore(content, popupId);
                  });

                  contentObserver.observe(content, {
                    childList: true,
                    subtree: true
                  });
                }

                // ================================================================
                // MUTATION OBSERVER (Full-init path)
                // ================================================================
                // Watch for LiveView stripping our --popup-initialized marker
                // This indicates LiveView did a full style reset and we need to restore
                // More efficient than watching every style change

                const panelObserver = new MutationObserver((mutations) => {
                  // This observer is our safety net for catching any LiveView patches
                  // that strip our position/size styles

                  for (const mutation of mutations) {
                    if (mutation.type === 'attributes' && mutation.attributeName === 'style') {
                      const timestamp = new Date().toISOString().split('T')[1];
                      // Check if our marker disappeared (LiveView stripped all inline styles)
                      const hasMarker = panel.style.getPropertyValue('--popup-initialized');
                      const currentStyles = {
                        left: panel.style.left,
                        top: panel.style.top,
                        width: panel.style.width,
                        height: panel.style.height
                      };

                      // Check if styles were cleared (set to empty strings by LiveView)
                      const stylesCleared = !panel.style.left && !panel.style.top;

                      console.log(`[${timestamp}] [Popup] Observer (full-init) detected style change, marker:`, !!hasMarker, 'styles cleared:', stylesCleared, 'styles:', currentStyles);

                      if (!hasMarker || stylesCleared) {
                        console.log(`[${timestamp}] [Popup] LiveView cleared styles - RESTORING NOW`);
                        const savedState = getPopupState(popupId);
                        if (savedState) {
                          // Temporarily disconnect to prevent loop
                          panelObserver.disconnect();

                          // Restore position
                          if (savedState.position) {
                            panel.style.left = `${savedState.position.left}px`;
                            panel.style.top = `${savedState.position.top}px`;
                          }
                          // Restore size
                          if (savedState.size) {
                            panel.style.width = `${savedState.size.width}px`;
                            panel.style.height = `${savedState.size.height}px`;
                          }

                          // CRITICAL: Also restore open/closed state
                          // Without this, popup gets position/size back but stays closed
                          if (savedState.isOpen) {
                            container.style.display = 'block';
                            container.setAttribute('aria-hidden', 'false');
                            openButton.setAttribute('aria-expanded', 'true');
                            console.log(`[${timestamp}] [Popup] Restored as OPEN`);
                          } else {
                            container.style.display = 'none';
                            container.setAttribute('aria-hidden', 'true');
                            openButton.setAttribute('aria-expanded', 'false');
                            console.log(`[${timestamp}] [Popup] Restored as CLOSED`);
                          }

                          // Re-add marker
                          panel.style.setProperty('--popup-initialized', '1');

                          // Reconnect observer immediately to catch any subsequent changes
                          panelObserver.observe(panel, {
                            attributes: true,
                            attributeFilter: ['style']
                          });
                        }
                      }
                      // If marker exists, this is just our own drag/resize code - ignore it
                    }
                  }
                });

                panelObserver.observe(panel, {
                  attributes: true,
                  attributeFilter: ['style']
                });
                window.__popupFullInitObserver = panelObserver;
                console.log('[Popup] Full-init observer started watching panel element:', panel);

                // ================================================================
                // CONTAINER OBSERVER (Watch for DOM removal during drag/resize)
                // ================================================================
                // If LiveView replaces the popup while user is interacting with it,
                // we need to stop the drag/resize operation to avoid errors

                const containerObserver = new MutationObserver((mutations) => {
                  for (const mutation of mutations) {
                    if (mutation.type === 'childList') {
                      // Check if our panel was removed from the DOM
                      for (const removedNode of mutation.removedNodes) {
                        if (removedNode === panel || removedNode.contains(panel)) {
                          console.log('[Popup] Panel removed from DOM during interaction, stopping drag/resize');

                          // Force stop any active interaction since the old panel is gone
                          // Read from window.__popupState to get current values (not stale local copies)
                          if (window.__popupState.isDragging) {
                            stopDragging();
                          }
                          if (window.__popupState.isResizing) {
                            stopResizing();
                          }

                          // Re-initialization will handle the new panel
                          // (triggered by phx:page-loading-stop)
                          break;
                        }
                      }
                    }
                  }
                });

                containerObserver.observe(container, {
                  childList: true,
                  subtree: false // Only watch direct children
                });

                // ================================================================
                // GLOBAL RESTORE FUNCTION (Full-init path)
                // ================================================================
                // This function is called by initAdminPopup() during first load
                // After navigation, it's recreated in the re-init path above (line ~979)
                // Gets fresh DOM references to work with new elements after LiveView patches
                // Same pattern used in both init and re-init paths

                window.__popupRestoreState = function() {
                  // Don't interfere with active drag/resize operations
                  if (window.__popupIsInteracting) {
                    console.log('[Popup] Skipping restore - user is interacting');
                    return;
                  }

                  // Get fresh references - old ones are invalid after LiveView replaces DOM
                  const currentContainer = document.getElementById(popupId);
                  const currentPanel = currentContainer?.querySelector('[data-popup-panel]');
                  const currentOpenButton = document.getElementById(popupId + '-button');
                  const currentContent = currentPanel?.querySelector('[data-popup-content]');

                  // Bail if elements don't exist (might be on a different page)
                  if (!currentContainer || !currentPanel || !currentOpenButton) {
                    console.log('[Popup] Skipping restore - popup elements no longer exist on current page');
                    return;
                  }

                  const savedState = getPopupState(popupId);
                  if (!savedState) {
                    return;
                  }

                  console.log('[Popup Hook] Restoring state after LiveView update:', savedState);

                  applyPopupCssVars(savedState);

                  // Restore position (where user dragged it to)
                  if (savedState.position) {
                    currentPanel.style.left = `${savedState.position.left}px`;
                    currentPanel.style.top = `${savedState.position.top}px`;
                  }

                  // Restore size (what user resized it to)
                  if (savedState.size) {
                    currentPanel.style.width = `${savedState.size.width}px`;
                    currentPanel.style.height = `${savedState.size.height}px`;
                  }

                  let shouldAnimate = false;

                  if (savedState.isOpen) {
                    // Restore open state without animation
                    currentContainer.style.display = 'block';
                    currentContainer.setAttribute('aria-hidden', 'false');
                    currentOpenButton.setAttribute('aria-expanded', 'true');
                    window.__popupState.isOpen = true;

                    // Never animate during global restore - popup state should persist without flicker
                    shouldAnimate = false;
                    currentPanel.style.removeProperty('visibility');
                    currentPanel.style.removeProperty('opacity');
                    currentPanel.style.removeProperty('transform');
                    console.log('[Popup] Global restore: keeping popup open without animation');
                  } else {
                    currentContainer.style.display = 'none';
                  }

                  lockContentOverflow(currentContent);

                  queueScrollRestore(currentContent, popupId, () => {
                    currentPanel.style.removeProperty('visibility');

                    if (savedState.isOpen) {
                      if (shouldAnimate) {
                        currentPanel.style.transition = 'opacity 120ms ease, transform 120ms ease';
                        currentPanel.style.opacity = '1';
                        currentPanel.style.transform = 'translateY(0)';

                        setTimeout(() => {
                          currentPanel.style.removeProperty('transition');
                        }, 150);
                      } else {
                        currentPanel.style.removeProperty('opacity');
                        currentPanel.style.removeProperty('transform');
                        currentPanel.style.removeProperty('transition');
                      }
                    } else {
                      currentPanel.style.removeProperty('opacity');
                      currentPanel.style.removeProperty('transform');
                      currentPanel.style.removeProperty('transition');
                    }

                    unlockContentOverflow(currentContent);
                  });
                };

                // Mark initialization complete
                // This flag prevents duplicate initialization and enables navigation handling
                openButton.dataset.popupEnhanced = 'true';
                window.__popupIsInitialized = true;
                console.log('[Popup] Initialization complete, global flag set');
              }
              // END OF initAdminPopup FUNCTION

              // ============================================================================
              // LIVEVIEW NAVIGATION EVENT LISTENERS
              // ============================================================================
              // These listeners handle popup persistence across LiveView navigation
              //
              // NAVIGATION FLOW (when popup elements exist on new page):
              // 1. phx:page-loading-start fires → save scroll position
              // 2. LiveView replaces DOM with new elements (popup appears with default attrs)
              // 3. phx:page-loading-stop fires → call initAdminPopup() via requestAnimationFrame
              // 4. requestAnimationFrame runs BEFORE next paint → restores state (no flicker)
              // 5. initAdminPopup() checks for elements:
              //    - If found: detects wasAlreadyInitialized = true, continues to step 6
              //    - If not found: sets window.__popupIsInitialized = false, exits
              // 6. Re-init path: recreate window.__popupRestoreState with fresh DOM refs
              // 7. Call window.__popupRestoreState() immediately to restore state
              // 8. Fall through to full init: re-attach all event listeners to new DOM
              // 9. Popup works perfectly with drag/resize/scroll on new page
              //
              // Key events:
              // - phx:page-loading-start: Save scroll position before navigation
              // - phx:page-loading-stop: Re-run initAdminPopup() before next paint (via rAF)
              // - phx:update: Minor DOM updates (we ignore these for popup restore)

              let restoreTimeout = null;

              // Track initial page load completion
              // This prevents restore logic from running before first initialization
              if (window.__popupInitialLoadComplete === undefined) {
                window.__popupInitialLoadComplete = false;
              }

              // Track if we already restored during init (prevents double-restore)
              if (window.__popupRestoredDuringInit === undefined) {
                window.__popupRestoredDuringInit = false;
              }

              // Debug logging for LiveView updates (not used for restore)
              window.addEventListener('phx:update', function(e) {
                const timestamp = new Date().toISOString().split('T')[1];
                console.log(`[${timestamp}] [LiveView Update] Interacting: ${window.__popupIsInteracting}`, e.detail);

                // DO NOT restore on phx:update - these fire constantly for timers, presence, etc.
                // Only restore on phx:page-loading-stop (actual navigation)
              });

              // NAVIGATION START: Save scroll position before LiveView replaces DOM
              window.addEventListener('phx:page-loading-start', function(event) {
                const kind = event?.detail?.kind || 'unknown';
                const isInitialKind = kind === 'initial';
                const isErrorKind = kind === 'error';
                const readyForNavigation = window.__popupIsInitialized && window.__popupInitialLoadComplete;

                // Ignore if not ready yet or if this is initial page load
                if (!readyForNavigation || isInitialKind || isErrorKind) {
                  console.log('[Popup] Page loading start ignored (kind:', kind, ') - initial load not finished yet or error state');
                  return;
                }

                console.log('[Popup] Navigation started (kind:', kind, ')');

                // Save current scroll position BEFORE navigation
                // Scroll persists across all pages - position/size/scroll all maintained globally
                const container = document.getElementById(DEFAULT_POPUP_ID);
                const content = container?.querySelector('[data-popup-content]');
                if (content) {
                  const scrollState = {
                    scrollTop: content.scrollTop || 0,
                    scrollLeft: content.scrollLeft || 0
                  };
                  console.log('[Popup] Saving scroll before navigation:', JSON.stringify(scrollState));
                  savePopupState(DEFAULT_POPUP_ID, {
                    scroll: scrollState
                  });
                }


                // CRITICAL: Don't reset __popupInitialLoadComplete or __popupRestoredDuringInit here!
                // Resetting them breaks the restore logic on subsequent navigations
              });

              // NAVIGATION COMPLETE: Re-initialize popup and restore state
              window.addEventListener('phx:page-loading-stop', function(event) {
                const kind = event?.detail?.kind || 'unknown';
                const isInitialKind = kind === 'initial';

                if (restoreTimeout) {
                  clearTimeout(restoreTimeout);
                }

                if (isInitialKind) {
                  window.__popupInitialLoadComplete = true;

                  if (window.__popupRestoredDuringInit) {
                    console.log('[Popup] Initial load complete (kind: initial), skipping extra restore');
                  } else {
                    console.log('[Popup] Initial load complete (kind: initial), no prior restore to replay');
                  }

                  window.__popupRestoredDuringInit = false;
                  return;
                }

                console.log('[Popup] Page loading stopped (kind:', kind, '), initialized:', window.__popupIsInitialized, 'restored during init:', window.__popupRestoredDuringInit);

                window.__popupInitialLoadComplete = true;

                // Always try to initialize after navigation
                // Use requestAnimationFrame to restore state before next paint (prevents flicker)
                // This runs after LiveView DOM updates but before browser renders the frame
                console.log('[Popup] Running initAdminPopup after navigation (before next paint)');
                requestAnimationFrame(() => {
                  initAdminPopup();
                });
              });

              // ============================================================================
              // INITIALIZATION TRIGGERS
              // ============================================================================
              // Try immediate init if elements already exist (prevents flicker)
              // Otherwise DOMContentLoaded will trigger init

              if (document.getElementById('admin-generic-popup') && !window.__popupIsInitialized) {
                console.log('[Popup] Elements available, initializing immediately');
                initAdminPopup();
              }

              // ============================================================================
              // MOBILE DRAWER AUTO-CLOSE
              // ============================================================================
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

                // Initialize popup if not already done
                if (!window.__popupIsInitialized) {
                  console.log('[Popup] DOMContentLoaded - initializing popup');
                  initAdminPopup();
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
                  // Listen to Phoenix LiveView theme events
                  document.addEventListener('phx:set-admin-theme', (e) => {
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

  # Check if a submenu should be open based on current path
  defp submenu_open?(current_path, paths) when is_binary(current_path) do
    # Remove PhoenixKit prefix first
    normalized_path = String.replace_prefix(current_path, "/phoenix_kit", "")

    # Remove locale prefix (e.g., /es, /fr, etc.) - keep leading slash
    normalized_path =
      case String.split(normalized_path, "/", parts: 3) do
        ["", locale, rest] when locale != "" and rest != "" ->
          # Check if locale looks like a locale code (2-3 chars)
          if String.length(locale) <= 3 do
            "/" <> rest
          else
            normalized_path
          end

        _ ->
          normalized_path
      end

    Enum.any?(paths, fn path -> String.starts_with?(normalized_path, path) end)
  end

  defp submenu_open?(_, _), do: false

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
        <.live_title default={"#{assigns[:project_title] || "PhoenixKit"} Admin"}>
          {assigns[:page_title] || "Admin"}
        </.live_title>
        <link phx-track-static rel="stylesheet" href="/assets/css/app.css" />
      </head>
      <body class="bg-base-100 antialiased transition-colors" data-admin-theme-base="system">
        <%!-- Admin pages without parent headers --%>
        <main class="min-h-screen bg-base-100 transition-colors">
          <.flash_group flash={@flash} />
          {render_slot(@inner_block)}
        </main>
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
  end

  # Prepare assigns specifically for PhoenixKit layout
  defp prepare_phoenix_kit_assigns(assigns) do
    assigns
    |> Map.put_new(:phoenix_kit_standalone, true)
  end

  # Extract current user from scope for parent layout compatibility
  defp get_current_user_for_parent(assigns) do
    case assigns[:phoenix_kit_current_scope] do
      nil -> assigns[:phoenix_kit_current_user]
      scope -> Scope.user(scope)
    end
  end

  # Get layout configuration from application environment with Phoenix version compatibility
  defp get_layout_config do
    case Application.get_env(:phoenix_kit, :phoenix_version_strategy) do
      :modern ->
        # Phoenix v1.8+ - get layouts_module and assume :app function
        case Application.get_env(:phoenix_kit, :layouts_module) do
          nil -> nil
          module -> {module, :app}
        end

      :legacy ->
        # Phoenix v1.7- - use legacy layout config
        Application.get_env(:phoenix_kit, :layout)

      nil ->
        # Fallback - check for legacy layout config first
        Application.get_env(:phoenix_kit, :layout)
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

  # Language switcher component for admin sidebar
  attr :current_path, :string, required: true
  attr :current_locale, :string, default: "en"

  defp admin_language_switcher(assigns) do
    # Only show if languages are enabled and there are enabled languages
    if Languages.enabled?() do
      enabled_languages = Languages.get_enabled_languages()

      # Only show if there are multiple languages (more than current one)
      if length(enabled_languages) > 1 do
        current_language =
          Enum.find(enabled_languages, &(&1["code"] == assigns.current_locale)) ||
            %{"code" => assigns.current_locale, "name" => String.upcase(assigns.current_locale)}

        other_languages = Enum.reject(enabled_languages, &(&1["code"] == assigns.current_locale))

        assigns =
          assigns
          |> assign(:enabled_languages, enabled_languages)
          |> assign(:current_language, current_language)
          |> assign(:other_languages, other_languages)

        ~H"""
        <div class="dropdown dropdown-end w-full" style="position: relative;">
          <%!-- Current Language Button --%>
          <div tabindex="0" role="button" class="btn btn-outline btn-sm w-full justify-start">
            <span class="text-lg">{get_language_flag(@current_language["code"])}</span>
            <span class="truncate flex-1 text-left">{@current_language["name"]}</span>
            <span class="text-xs">▲</span>
          </div>

          <%!-- Language Options Dropdown --%>
          <ul
            tabindex="0"
            class="dropdown-content menu bg-base-100 rounded-box z-50 w-full p-2 shadow-lg border border-base-300"
            style="position: absolute; bottom: 100%; margin-bottom: 4px;"
          >
            <%= for language <- @other_languages do %>
              <li>
                <a
                  href={generate_language_switch_url(@current_path, language["code"])}
                  class="flex items-center gap-3 px-3 py-2 hover:bg-base-200 rounded-lg"
                >
                  <span class="text-lg">{get_language_flag(language["code"])}</span>
                  <span>{language["name"]}</span>
                </a>
              </li>
            <% end %>
          </ul>
        </div>
        """
      else
        ~H""
      end
    else
      ~H""
    end
  end

  # Used in HEEX template - compiler cannot detect usage
  def get_language_flag(code) do
    case code do
      "en" -> "🇺🇸"
      "es" -> "🇪🇸"
      "fr" -> "🇫🇷"
      "de" -> "🇩🇪"
      "pt" -> "🇵🇹"
      "it" -> "🇮🇹"
      "nl" -> "🇳🇱"
      "ru" -> "🇷🇺"
      "zh-CN" -> "🇨🇳"
      "ja" -> "🇯🇵"
      _ -> "🌐"
    end
  end

  # Used in HEEX template - compiler cannot detect usage
  def generate_language_switch_url(current_path, new_locale) do
    # Get actual enabled language codes to properly detect locale prefixes
    enabled_language_codes = Languages.get_enabled_language_codes()

    # Remove PhoenixKit prefix if present
    normalized_path = String.replace_prefix(current_path || "", "/phoenix_kit", "")

    # Remove existing locale prefix only if it matches actual language codes
    clean_path =
      case String.split(normalized_path, "/", parts: 3) do
        ["", potential_locale, rest] ->
          if potential_locale in enabled_language_codes do
            "/" <> rest
          else
            normalized_path
          end

        _ ->
          normalized_path
      end

    # Build the new URL with the new locale prefix
    url_prefix = PhoenixKit.Config.get_url_prefix()
    base_prefix = if url_prefix == "/", do: "", else: url_prefix

    "#{base_prefix}/#{new_locale}#{clean_path}"
  end
end
