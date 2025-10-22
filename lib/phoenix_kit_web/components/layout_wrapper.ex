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
                  class="hidden fixed inset-0 z-[70] pointer-events-none"
                  aria-hidden="true"
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
              function initAdminPopup() {
                const container = document.getElementById('admin-generic-popup');
                const openButton = document.getElementById('admin-generic-popup-button');

                if (!container || !openButton || openButton.dataset.popupEnhanced === 'true') {
                  console.warn('[Popup] Skipping init', { container: !!container, openButton: !!openButton, enhanced: openButton?.dataset?.popupEnhanced });
                  return;
                }

                const panel = container.querySelector('[data-popup-panel]');
                const handle = container.querySelector('[data-popup-handle]');
                const closeButtons = container.querySelectorAll('[data-popup-close]');
                const resizeHandle = container.querySelector('[data-popup-resize-handle]');
                const content = container.querySelector('[data-popup-content]');

                if (!panel || !handle) {
                  console.warn('[Popup] Missing panel or handle', { hasPanel: !!panel, hasHandle: !!handle });
                  return;
                }
                console.log('[Popup] Initialized');

                let isOpen = false;
                let isDragging = false;
                let dragPointerId = null;
                let dragOffsetX = 0;
                let dragOffsetY = 0;
                let isResizing = false;
                let resizePointerId = null;
                let startWidth = 0;
                let startHeight = 0;
                let startX = 0;
                let startY = 0;

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

                const stopDragging = () => {
                  if (!isDragging) {
                    return;
                  }

                  console.log('[Popup] Stop dragging');

                  if (handle.releasePointerCapture && dragPointerId !== null) {
                    try {
                      handle.releasePointerCapture(dragPointerId);
                    } catch (_error) {}
                  }

                  isDragging = false;
                  dragPointerId = null;
                  window.removeEventListener('pointermove', handleDragMove);
                  window.removeEventListener('pointerup', endDrag);
                  window.removeEventListener('pointercancel', endDrag);
                };

                const stopResizing = () => {
                  if (!isResizing) {
                    return;
                  }

                  console.log('[Popup] Stop resizing');

                  if (resizeHandle && resizeHandle.releasePointerCapture && resizePointerId !== null) {
                    try {
                      resizeHandle.releasePointerCapture(resizePointerId);
                    } catch (_error) {}
                  }

                  isResizing = false;
                  resizePointerId = null;
                  window.removeEventListener('pointermove', handleResizeMove);
                  window.removeEventListener('pointerup', endResize);
                  window.removeEventListener('pointercancel', endResize);
                };

                const showPopup = () => {
                  centerPanel();
                  console.log('[Popup] Show');
                  container.classList.remove('hidden');
                  container.setAttribute('aria-hidden', 'false');
                  openButton.setAttribute('aria-expanded', 'true');
                  isOpen = true;
                  panel.focus({ preventScroll: true });
                  document.addEventListener('keydown', handleKeydown);
                };

                const hidePopup = () => {
                  if (!isOpen) {
                    return;
                  }

                  console.log('[Popup] Hide');

                  stopDragging();
                  stopResizing();

                  container.setAttribute('aria-hidden', 'true');
                  openButton.setAttribute('aria-expanded', 'false');
                  container.classList.add('hidden');
                  isOpen = false;

                  document.removeEventListener('keydown', handleKeydown);
                };

                const handleKeydown = (event) => {
                  console.log('[Popup] Keydown', event.key);
                  if (!isOpen) {
                    return;
                  }

                  if (event.key === 'Escape') {
                    event.preventDefault();
                    hidePopup();
                  }
                };

                const endDrag = (event) => {
                  console.log('[Popup] End drag');
                  if (!isDragging || (dragPointerId !== null && event.pointerId !== dragPointerId)) {
                    return;
                  }

                  stopDragging();
                };

                const handleDragMove = (event) => {
                  if (!isDragging) {
                    return;
                  }

                  const containerRect = container.getBoundingClientRect();
                  const mouseXInContainer = event.clientX - containerRect.left;
                  const mouseYInContainer = event.clientY - containerRect.top;
                  const nextLeft = mouseXInContainer - dragOffsetX;
                  const nextTop = mouseYInContainer - dragOffsetY;
                  const clamped = clampPosition(nextLeft, nextTop);

                  console.log('[Popup] Drag move', {
                    pointer: { x: event.clientX, y: event.clientY },
                    mouseInContainer: { x: mouseXInContainer, y: mouseYInContainer },
                    containerLeft: containerRect.left,
                    containerTop: containerRect.top,
                    dragOffsetX,
                    dragOffsetY,
                    nextLeft,
                    nextTop,
                    clamped
                  });

                  panel.style.left = `${clamped.left}px`;
                  panel.style.top = `${clamped.top}px`;
                };

                const startDrag = (event) => {
                  if (event.button !== undefined && event.button !== 0) {
                    return;
                  }

                  console.log('[Popup] Start drag', { pointer: { x: event.clientX, y: event.clientY } });

                  event.preventDefault();

                  const containerRect = container.getBoundingClientRect();

                  panel.style.transform = '';
                  const panelRect = panel.getBoundingClientRect();
                  const handleRect = handle.getBoundingClientRect();

                  const currentLeft = panelRect.left - containerRect.left;
                  const currentTop = panelRect.top - containerRect.top;
                  panel.style.left = `${currentLeft}px`;
                  panel.style.top = `${currentTop}px`;

                  isDragging = true;
                  dragPointerId = event.pointerId;

                  const mouseXInContainer = event.clientX - containerRect.left;
                  const mouseYInContainer = event.clientY - containerRect.top;
                  dragOffsetX = mouseXInContainer - currentLeft;
                  dragOffsetY = mouseYInContainer - currentTop;

                  console.log('[Popup] Start drag - Initial state', {
                    mouse: { clientX: event.clientX, clientY: event.clientY },
                    mouseInContainer: { x: mouseXInContainer, y: mouseYInContainer },
                    panelPosition: { left: currentLeft, top: currentTop },
                    container: { left: containerRect.left, top: containerRect.top },
                    calculatedOffset: { x: dragOffsetX, y: dragOffsetY },
                    verification: {
                      shouldEqual_mouseX: `${mouseXInContainer} should equal ${currentLeft} + ${dragOffsetX} = ${currentLeft + dragOffsetX}`,
                      matches: mouseXInContainer === currentLeft + dragOffsetX
                    }
                  });

                  if (handle.setPointerCapture) {
                    try {
                      handle.setPointerCapture(event.pointerId);
                    } catch (_error) {}
                  }

                  window.addEventListener('pointermove', handleDragMove);
                  window.addEventListener('pointerup', endDrag);
                  window.addEventListener('pointercancel', endDrag);
                };

                const endResize = (event) => {
                  if (!isResizing || (resizePointerId !== null && event.pointerId !== resizePointerId)) {
                    return;
                  }

                  stopResizing();
                };

                const handleResizeMove = (event) => {
                  if (!isResizing) {
                    return;
                  }

                  const nextWidth = startWidth + (event.clientX - startX);
                  const nextHeight = startHeight + (event.clientY - startY);

                  console.log('[Popup] Resize move', { nextWidth, nextHeight });

                  panel.style.width = `${nextWidth}px`;
                  panel.style.height = `${nextHeight}px`;
                };

                const startResize = (event) => {
                  if (!resizeHandle || (event.button !== undefined && event.button !== 0)) {
                    return;
                  }

                  console.log('[Popup] Start resize', { x: event.clientX, y: event.clientY });

                  event.preventDefault();

                  const containerRect = container.getBoundingClientRect();

                  panel.style.transform = '';
                  const panelRect = panel.getBoundingClientRect();
                  panel.style.left = `${panelRect.left - containerRect.left}px`;
                  panel.style.top = `${panelRect.top - containerRect.top}px`;

                  isResizing = true;
                  resizePointerId = event.pointerId;
                  startWidth = panelRect.width;
                  startHeight = panelRect.height;
                  startX = event.clientX;
                  startY = event.clientY;

                  if (resizeHandle.setPointerCapture) {
                    try {
                      resizeHandle.setPointerCapture(event.pointerId);
                    } catch (_error) {}
                  }

                  window.addEventListener('pointermove', handleResizeMove);
                  window.addEventListener('pointerup', endResize);
                  window.addEventListener('pointercancel', endResize);
                };

                handle.addEventListener('pointerdown', startDrag);

                closeButtons.forEach((button) => {
                  button.addEventListener('click', hidePopup);
                });

                if (resizeHandle) {
                  resizeHandle.addEventListener('pointerdown', startResize);
                }

                openButton.addEventListener('click', () => {
                  console.log('[Popup] Toggle button clicked');
                  if (isOpen) {
                    hidePopup();
                  } else {
                    showPopup();
                  }
                });

                openButton.dataset.popupEnhanced = 'true';
              }

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

                initAdminPopup();
              });

              window.addEventListener('phx:page-loading-stop', function() {
                initAdminPopup();
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
