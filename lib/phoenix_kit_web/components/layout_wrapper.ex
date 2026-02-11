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

  alias Phoenix.HTML
  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.SEO
  alias PhoenixKit.ThemeConfig
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
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
      |> assign_new(:publishing_groups, fn -> load_publishing_groups() end)
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

  # Check if current page is an admin page that needs navigation
  defp admin_page?(assigns) do
    case assigns[:current_path] do
      nil -> false
      path when is_binary(path) -> String.contains?(path, "/admin")
      _ -> false
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
              publishing_groups: assigns[:publishing_groups] || [],
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
                  <div class="flex items-center gap-1">
                    <.link href="/" class="font-bold text-base-content hover:opacity-80 transition-opacity">
                      {@project_title}
                    </.link>
                    <span class="font-bold text-base-content">{gettext("Admin")}</span>
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
                  <nav class="px-4 py-6 space-y-2 flex-1">
                    <%= if module_accessible?(@scope, "dashboard") do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin")}
                        icon="dashboard"
                        label={gettext("Dashboard")}
                        current_path={@current_path || ""}
                        exact_match_only={true}
                      />
                    <% end %>

                    <%!-- Users section with direct link and conditional submenu --%>
                    <%= if module_accessible?(@scope, "users") do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/users")}
                        icon="users"
                        label={gettext("Users")}
                        current_path={@current_path || ""}
                        disable_active={true}
                        submenu_open={
                          submenu_open?(@current_path, [
                            "/admin/users",
                            "/admin/users/live_sessions",
                            "/admin/users/sessions",
                            "/admin/users/roles",
                            "/admin/users/permissions",
                            "/admin/users/referral-codes"
                          ])
                        }
                      />

                      <%= if submenu_open?(@current_path, ["/admin/users", "/admin/users/live_sessions", "/admin/users/sessions", "/admin/users/roles", "/admin/users/permissions", "/admin/users/referral-codes"]) do %>
                        <%!-- Submenu items --%>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/users")}
                            icon="users"
                            label={gettext("Manage Users")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/users/live_sessions")}
                            icon="live_sessions"
                            label={gettext("Live Sessions")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/users/sessions")}
                            icon="sessions"
                            label={gettext("Sessions")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/users/roles")}
                            icon="roles"
                            label={gettext("Roles")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/users/permissions")}
                            icon="hero-key"
                            label={gettext("Permissions")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <%= if PhoenixKit.Modules.Referrals.enabled?() and module_accessible?(@scope, "referrals") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/users/referral-codes")}
                              icon="referral_codes"
                              label={gettext("Referral Codes")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>
                        </div>
                      <% end %>
                    <% end %>

                    <%!-- Media as top-level menu item --%>
                    <%= if module_accessible?(@scope, "media") do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/media")}
                        icon="photo"
                        label={gettext("Media")}
                        current_path={@current_path || ""}
                      />
                    <% end %>

                    <%!-- Custom Admin Dashboard Categories --%>
                    <%= for category <- PhoenixKit.Config.AdminDashboardCategories.get_categories() do %>
                      <.admin_nav_item
                        href={
                          category.subsections
                          |> List.first()
                          |> Map.get(:url, "#")
                          |> then(&Routes.locale_aware_path(assigns, &1))
                        }
                        icon={category.icon || "hero-folder"}
                        label={category.title}
                        current_path={@current_path || ""}
                        disable_active={true}
                        submenu_open={custom_category_submenu_open?(@current_path, category.subsections)}
                      />

                      <%= if custom_category_submenu_open?(@current_path, category.subsections) do %>
                        <div class="mt-1">
                          <%= for subsection <- category.subsections do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, subsection.url)}
                              icon={subsection.icon || "hero-document-text"}
                              label={subsection.title}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>
                        </div>
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Modules.Emails.enabled?() and module_accessible?(@scope, "emails") do %>
                      <%!-- Email section with direct link and conditional submenu --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/emails/dashboard")}
                        icon="email"
                        label={gettext("Emails")}
                        current_path={@current_path || ""}
                        disable_active={true}
                        submenu_open={
                          submenu_open?(@current_path, [
                            "/admin/emails",
                            "/admin/emails/dashboard",
                            "/admin/modules/emails/templates",
                            "/admin/emails/queue",
                            "/admin/emails/blocklist"
                          ])
                        }
                      />

                      <%= if submenu_open?(@current_path, ["/admin/emails", "/admin/emails/dashboard", "/admin/modules/emails/templates", "/admin/emails/queue", "/admin/emails/blocklist"]) do %>
                        <%!-- Email submenu items --%>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails/dashboard")}
                            icon="email"
                            label={gettext("Dashboard")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails")}
                            icon="email"
                            label={gettext("Emails")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.path("/admin/modules/emails/templates")}
                            icon="email"
                            label={gettext("Templates")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails/queue")}
                            icon="email"
                            label={gettext("Queue")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/emails/blocklist")}
                            icon="email"
                            label={gettext("Blocklist")}
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        </div>
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Modules.Billing.enabled?() and module_accessible?(@scope, "billing") do %>
                      <%!-- Billing section with submenu --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/billing")}
                        icon="billing"
                        label="Billing"
                        current_path={@current_path || ""}
                        disable_active={true}
                        submenu_open={
                          submenu_open?(@current_path, [
                            "/admin/billing",
                            "/admin/billing/orders",
                            "/admin/billing/invoices",
                            "/admin/billing/transactions",
                            "/admin/billing/subscriptions",
                            "/admin/billing/plans",
                            "/admin/billing/profiles",
                            "/admin/billing/currencies",
                            "/admin/settings/billing/providers"
                          ])
                        }
                      />

                      <%= if submenu_open?(@current_path, ["/admin/billing", "/admin/billing/orders", "/admin/billing/invoices", "/admin/billing/transactions", "/admin/billing/subscriptions", "/admin/billing/plans", "/admin/billing/profiles", "/admin/billing/currencies", "/admin/settings/billing/providers"]) do %>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/billing")}
                            icon="billing"
                            label="Dashboard"
                            current_path={@current_path || ""}
                            nested={true}
                            exact_match_only={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/billing/orders")}
                            icon="billing"
                            label="Orders"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/billing/invoices")}
                            icon="billing"
                            label="Invoices"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/billing/transactions")}
                            icon="billing"
                            label="Transactions"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/billing/subscriptions")}
                            icon="billing"
                            label="Subscriptions"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/billing/plans")}
                            icon="billing"
                            label="Plans"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/billing/profiles")}
                            icon="billing"
                            label="Billing Profiles"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/billing/currencies")}
                            icon="billing"
                            label="Currencies"
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/settings/billing/providers")}
                            icon="billing"
                            label="Payment Providers"
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        </div>
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Modules.Shop.enabled?() and module_accessible?(@scope, "shop") do %>
                      <%!-- Shop section with submenu --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/shop")}
                        icon="shop"
                        label={gettext("E-Commerce")}
                        current_path={@current_path || ""}
                        disable_active={true}
                        submenu_open={
                          submenu_open?(@current_path, [
                            "/admin/shop",
                            "/admin/shop/products",
                            "/admin/shop/categories",
                            "/admin/shop/shipping",
                            "/admin/shop/carts",
                            "/admin/shop/imports",
                            "/admin/shop/settings"
                          ])
                        }
                      />

                      <%= if submenu_open?(@current_path, ["/admin/shop", "/admin/shop/products", "/admin/shop/categories", "/admin/shop/shipping", "/admin/shop/carts", "/admin/shop/imports", "/admin/shop/settings"]) do %>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/shop")}
                            icon="hero-home"
                            label={gettext("Dashboard")}
                            current_path={@current_path || ""}
                            nested={true}
                            exact_match_only={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/shop/products")}
                            icon="hero-cube"
                            label={gettext("Products")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/shop/categories")}
                            icon="hero-folder"
                            label={gettext("Categories")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/shop/shipping")}
                            icon="hero-truck"
                            label={gettext("Shipping")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/shop/carts")}
                            icon="hero-shopping-cart"
                            label={gettext("Carts")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/shop/imports")}
                            icon="hero-cloud-arrow-up"
                            label={gettext("CSV Import")}
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        </div>
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Modules.Entities.enabled?() and module_accessible?(@scope, "entities") do %>
                      <%!-- Entities section with direct link and conditional submenu --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/entities")}
                        icon="entities"
                        label={gettext("Entities")}
                        current_path={@current_path || ""}
                        exact_match_only={true}
                        submenu_open={submenu_open?(@current_path, ["/admin/entities"])}
                      />

                      <%= if submenu_open?(@current_path, ["/admin/entities"]) do %>
                        <%!-- Dynamically list each published entity --%>
                        <div class="mt-1">
                          <%= for entity <- PhoenixKit.Modules.Entities.list_entities() do %>
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
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Modules.AI.enabled?() and module_accessible?(@scope, "ai") do %>
                      <%!-- AI section --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/ai")}
                        icon="ai"
                        label={gettext("AI")}
                        current_path={@current_path || ""}
                        disable_active={true}
                      />

                      <%= if submenu_open?(@current_path, ["/admin/ai"]) do %>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/ai/endpoints")}
                            icon="hero-server-stack"
                            label={gettext("Endpoints")}
                            current_path={@current_path || ""}
                            nested={true}
                          />
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/ai/prompts")}
                            icon="hero-document-text"
                            label={gettext("Prompts")}
                            current_path={@current_path || ""}
                            nested={true}
                          />
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/ai/usage")}
                            icon="hero-chart-bar"
                            label={gettext("Usage")}
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        </div>
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Modules.Sync.enabled?() and module_accessible?(@scope, "sync") do %>
                      <%!-- Sync section --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/sync")}
                        icon="sync"
                        label={gettext("Sync")}
                        current_path={@current_path || ""}
                        disable_active={true}
                        submenu_open={
                          submenu_open?(@current_path, [
                            "/admin/sync",
                            "/admin/sync/connections",
                            "/admin/sync/history"
                          ])
                        }
                      />

                      <%= if submenu_open?(@current_path, ["/admin/sync", "/admin/sync/connections", "/admin/sync/history"]) do %>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/sync")}
                            icon="hero-home"
                            label={gettext("Overview")}
                            current_path={@current_path || ""}
                            nested={true}
                            exact_match_only={true}
                          />
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/sync/connections")}
                            icon="hero-link"
                            label={gettext("Connections")}
                            current_path={@current_path || ""}
                            nested={true}
                          />
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/sync/history")}
                            icon="hero-clock"
                            label={gettext("History")}
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        </div>
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Modules.DB.enabled?() and module_accessible?(@scope, "db") do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/db")}
                        icon="hero-table-cells"
                        label={gettext("DB")}
                        current_path={@current_path || ""}
                        exact_match_only={true}
                      />
                    <% end %>

                    <%= if PhoenixKit.Modules.Posts.enabled?() and module_accessible?(@scope, "posts") do %>
                      <%!-- Posts Section --%>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/posts")}
                        icon="document"
                        label={gettext("Posts")}
                        current_path={@current_path || ""}
                        disable_active={true}
                        submenu_open={submenu_open?(@current_path, ["/admin/posts"])}
                      />

                      <%= if submenu_open?(@current_path, ["/admin/posts"]) do %>
                        <div class="mt-1">
                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/posts")}
                            icon="document"
                            label={gettext("All Posts")}
                            current_path={@current_path || ""}
                            nested={true}
                          />

                          <.admin_nav_item
                            href={Routes.locale_aware_path(assigns, "/admin/posts/groups")}
                            icon="hero-folder"
                            label={gettext("Groups")}
                            current_path={@current_path || ""}
                            nested={true}
                          />
                        </div>
                      <% end %>
                    <% end %>

                    <%= if PhoenixKit.Modules.Comments.enabled?() and module_accessible?(@scope, "comments") do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/comments")}
                        icon="hero-chat-bubble-left-right"
                        label={gettext("Comments")}
                        current_path={@current_path || ""}
                      />
                    <% end %>

                    <%= if Publishing.enabled?() and module_accessible?(@scope, "publishing") do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/publishing")}
                        icon="document"
                        label={gettext("Publishing")}
                        current_path={@current_path || ""}
                        exact_match_only={true}
                        submenu_open={submenu_open?(@current_path, ["/admin/publishing", "/admin/blogging"])}
                      />

                      <%= if submenu_open?(@current_path, ["/admin/publishing", "/admin/blogging"]) do %>
                        <div class="mt-1">
                          <%= for blog <- @publishing_groups do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/publishing/#{blog["slug"]}")}
                              icon="hero-document-text"
                              label={blog["name"]}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>
                        </div>
                      <% end %>
                    <% end %>

                    <%!-- Jobs (only shown when module is enabled) --%>
                    <%= if PhoenixKit.Jobs.enabled?() and module_accessible?(@scope, "jobs") do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/jobs")}
                        icon="jobs"
                        label={gettext("Jobs")}
                        current_path={@current_path || ""}
                      />
                    <% end %>

                    <%!-- Tickets (only shown when module is enabled) --%>
                    <%= if PhoenixKit.Modules.Tickets.enabled?() and module_accessible?(@scope, "tickets") do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/tickets")}
                        icon="hero-ticket"
                        label={gettext("Tickets")}
                        current_path={@current_path || ""}
                      />
                    <% end %>

                    <%= if module_accessible?(@scope, "modules") do %>
                      <.admin_nav_item
                        href={Routes.locale_aware_path(assigns, "/admin/modules")}
                        icon="modules"
                        label={gettext("Modules")}
                        current_path={@current_path || ""}
                      />
                    <% end %>

                    <%!-- Settings section with direct link and conditional submenu --%>
                    <%= if settings_section_visible?(@scope) do %>
                      <.admin_nav_item
                        href={settings_href(assigns, @scope)}
                        icon="settings"
                        label={gettext("Settings")}
                        current_path={@current_path || ""}
                        disable_active={true}
                        submenu_open={
                          submenu_open?(@current_path, [
                            "/admin/settings",
                            "/admin/settings/organization",
                            "/admin/settings/users",
                            "/admin/settings/referral-codes",
                            "/admin/settings/emails",
                            "/admin/settings/languages",
                            "/admin/settings/entities",
                            "/admin/settings/media",
                            "/admin/settings/storage/dimensions",
                            "/admin/settings/maintenance",
                            "/admin/settings/publishing",
                            "/admin/settings/blogging",
                            "/admin/settings/seo",
                            "/admin/settings/posts",
                            "/admin/settings/tickets",
                            "/admin/settings/billing",
                            "/admin/settings/billing/providers",
                            "/admin/shop/settings"
                          ])
                        }
                      />

                      <%= if submenu_open?(@current_path, ["/admin/settings", "/admin/settings/organization", "/admin/settings/users", "/admin/settings/referral-codes", "/admin/settings/emails", "/admin/settings/languages", "/admin/settings/entities", "/admin/settings/media", "/admin/settings/storage/dimensions", "/admin/settings/maintenance", "/admin/settings/publishing", "/admin/settings/blogging", "/admin/settings/seo", "/admin/settings/sitemap", "/admin/settings/posts", "/admin/settings/tickets", "/admin/settings/billing", "/admin/settings/billing/providers", "/admin/shop/settings"]) do %>
                        <%!-- Settings submenu items --%>
                        <div class="mt-1">
                          <%= if module_accessible?(@scope, "settings") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings")}
                              icon="settings"
                              label={gettext("General")}
                              current_path={@current_path || ""}
                              nested={true}
                              exact_match_only={true}
                            />

                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/organization")}
                              icon="organization"
                              label={gettext("Organization")}
                              current_path={@current_path || ""}
                              nested={true}
                            />

                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/users")}
                              icon="users"
                              label={gettext("Users")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if PhoenixKit.Modules.Referrals.enabled?() and module_accessible?(@scope, "referrals") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/referral-codes")}
                              icon="referral_codes"
                              label={gettext("Referrals")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if Publishing.enabled?() and module_accessible?(@scope, "publishing") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/publishing")}
                              icon="document"
                              label={gettext("Publishing")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if PhoenixKit.Settings.get_setting_cached("posts_enabled", "true") == "true" and module_accessible?(@scope, "posts") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/posts")}
                              icon="document"
                              label={gettext("Posts")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if PhoenixKit.Modules.Tickets.enabled?() and module_accessible?(@scope, "tickets") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/tickets")}
                              icon="hero-ticket"
                              label={gettext("Tickets")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if PhoenixKit.Modules.Comments.enabled?() and module_accessible?(@scope, "comments") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/comments")}
                              icon="hero-chat-bubble-left-right"
                              label={gettext("Comments")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%!-- Legacy Pages settings navigation retained for future use --%>

                          <%= if PhoenixKit.Modules.Emails.enabled?() and module_accessible?(@scope, "emails") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/emails")}
                              icon="email"
                              label={gettext("Emails")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if PhoenixKit.Modules.Billing.enabled?() and module_accessible?(@scope, "billing") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/billing")}
                              icon="billing"
                              label="Billing"
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if PhoenixKit.Modules.Shop.enabled?() and module_accessible?(@scope, "shop") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/shop/settings")}
                              icon="shop"
                              label={gettext("E-Commerce")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if Languages.enabled?() and module_accessible?(@scope, "languages") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/languages")}
                              icon="language"
                              label={gettext("Languages")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if PhoenixKit.Modules.Legal.enabled?() and module_accessible?(@scope, "legal") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/legal")}
                              icon="legal"
                              label={gettext("Legal")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if SEO.module_enabled?() and module_accessible?(@scope, "seo") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/seo")}
                              icon="seo"
                              label={gettext("SEO")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if PhoenixKit.Modules.Sitemap.enabled?() and module_accessible?(@scope, "sitemap") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/sitemap")}
                              icon="sitemap"
                              label={gettext("Sitemap")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%= if PhoenixKit.Modules.Maintenance.module_enabled?() and module_accessible?(@scope, "maintenance") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/maintenance")}
                              icon="maintenance"
                              label={gettext("Maintenance")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>

                          <%!-- Media settings section with submenu --%>
                          <%= if module_accessible?(@scope, "media") do %>
                            <.admin_nav_item
                              href={Routes.locale_aware_path(assigns, "/admin/settings/media")}
                              icon="photo"
                              label={gettext("Media")}
                              current_path={@current_path || ""}
                              nested={true}
                            />

                            <%= if submenu_open?(@current_path, ["/admin/settings/media", "/admin/settings/media/dimensions"]) do %>
                              <%!-- Storage submenu items --%>
                              <div class="mt-1 pl-4">
                                <.admin_nav_item
                                  href={Routes.locale_aware_path(assigns, "/admin/settings/media/dimensions")}
                                  icon="photo"
                                  label={gettext("Dimensions")}
                                  current_path={@current_path || ""}
                                  nested={true}
                                />
                              </div>
                            <% end %>
                          <% end %>

                          <%= if PhoenixKit.Modules.Entities.enabled?() and module_accessible?(@scope, "entities") do %>
                            <.admin_nav_item
                              href={Routes.path("/admin/settings/entities")}
                              icon="entities"
                              label={gettext("Entities")}
                              current_path={@current_path || ""}
                              nested={true}
                            />
                          <% end %>
                        </div>
                      <% end %>
                    <% end %>
                  </nav>
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

  # Check if a user has access to a specific admin module/section
  defp module_accessible?(scope, module_key) do
    Scope.has_module_access?(scope, module_key)
  end

  # Settings section is visible if user has "settings" permission
  # or has permission for any module that has a settings sub-page
  @settings_submodule_keys ~w(referrals publishing posts tickets emails billing shop languages legal seo sitemap maintenance media entities)
  defp settings_section_visible?(scope) do
    module_accessible?(scope, "settings") or
      Enum.any?(@settings_submodule_keys, &module_accessible?(scope, &1))
  end

  # Returns the best settings href for the parent nav item.
  # If user has "settings" permission, go to General settings.
  # Otherwise, find the first accessible sub-module settings page.
  @settings_submodule_paths [
    {"referrals", "/admin/settings/referral-codes"},
    {"publishing", "/admin/settings/publishing"},
    {"posts", "/admin/settings/posts"},
    {"tickets", "/admin/settings/tickets"},
    {"emails", "/admin/settings/emails"},
    {"billing", "/admin/settings/billing"},
    {"shop", "/admin/shop/settings"},
    {"languages", "/admin/settings/languages"},
    {"legal", "/admin/settings/legal"},
    {"seo", "/admin/settings/seo"},
    {"sitemap", "/admin/settings/sitemap"},
    {"maintenance", "/admin/settings/maintenance"},
    {"media", "/admin/settings/media"},
    {"entities", "/admin/settings/entities"}
  ]
  defp settings_href(assigns, scope) do
    if module_accessible?(scope, "settings") do
      Routes.locale_aware_path(assigns, "/admin/settings")
    else
      enabled = Permissions.enabled_module_keys()

      case Enum.find(@settings_submodule_paths, fn {key, _} ->
             module_accessible?(scope, key) and MapSet.member?(enabled, key)
           end) do
        {_, path} -> Routes.locale_aware_path(assigns, path)
        nil -> Routes.locale_aware_path(assigns, "/admin/settings")
      end
    end
  end

  # Check if a submenu should be open based on current path
  defp submenu_open?(current_path, paths) when is_binary(current_path) do
    current_path
    |> remove_phoenix_kit_prefix()
    |> remove_locale_prefix()
    |> path_matches_any?(paths)
  end

  defp submenu_open?(_, _), do: false

  defp remove_phoenix_kit_prefix(path) do
    url_prefix = Config.get_url_prefix()

    if url_prefix == "/" do
      path
    else
      String.replace_prefix(path, url_prefix, "")
    end
  end

  defp remove_locale_prefix(path) do
    case String.split(path, "/", parts: 3) do
      ["", locale, rest] when locale != "" and rest != "" ->
        if looks_like_locale?(locale), do: "/" <> rest, else: path

      _ ->
        path
    end
  end

  defp looks_like_locale?(locale) do
    # Match 2-letter codes (en, es) or regional variants (en-US, es-ES, zh-CN)
    String.length(locale) <= 6 and String.match?(locale, ~r/^[a-z]{2}(-[A-Z]{2})?$/)
  end

  defp path_matches_any?(normalized_path, paths) do
    Enum.any?(paths, fn path ->
      # Exact match or path segment match (followed by / or query string)
      normalized_path == path ||
        String.starts_with?(normalized_path, path <> "/") ||
        String.starts_with?(normalized_path, path <> "?")
    end)
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

  # Load publishing groups configuration with dual-key support (new key first, legacy fallback)
  defp load_publishing_groups do
    if Publishing.enabled?() do
      # Check new key first, then fallback to legacy keys
      json_settings = %{
        "publishing_groups" =>
          PhoenixKit.Settings.get_json_setting_cached("publishing_groups", nil),
        "blogging_blogs" => PhoenixKit.Settings.get_json_setting_cached("blogging_blogs", nil),
        "blogging_categories" =>
          PhoenixKit.Settings.get_json_setting_cached("blogging_categories", %{"types" => []})
      }

      extract_and_normalize_groups(json_settings)
    else
      []
    end
  end

  defp extract_and_normalize_groups(json_settings) do
    # Try new publishing_groups key first
    case json_settings["publishing_groups"] do
      %{"publishing_groups" => groups} when is_list(groups) ->
        normalize_blogs(groups)

      # Fallback to legacy blogging_blogs key
      _ ->
        extract_legacy_blogs(json_settings)
    end
  end

  defp extract_legacy_blogs(json_settings) do
    case json_settings["blogging_blogs"] do
      %{"blogs" => blogs} when is_list(blogs) ->
        normalize_blogs(blogs)

      list when is_list(list) ->
        normalize_blogs(list)

      _ ->
        handle_legacy_blogging_categories(json_settings)
    end
  end

  defp handle_legacy_blogging_categories(json_settings) do
    legacy =
      case json_settings["blogging_categories"] do
        %{"types" => types} when is_list(types) -> types
        other when is_list(other) -> other
        _ -> []
      end

    migrate_legacy_categories_if_present(legacy)
    normalize_blogs(legacy)
  end

  defp migrate_legacy_categories_if_present([]), do: :ok

  defp migrate_legacy_categories_if_present(legacy) do
    # Migrate to new publishing_groups key
    PhoenixKit.Settings.update_json_setting("publishing_groups", %{"publishing_groups" => legacy})
  end

  # Normalize blogs list to ensure consistent structure
  defp normalize_blogs(blogs) do
    blogs
    |> Enum.map(&normalize_blog_keys/1)
    |> Enum.map(fn
      %{"mode" => mode} = blog when mode in ["timestamp", "slug"] ->
        blog

      blog ->
        Map.put(blog, "mode", "timestamp")
    end)
  end

  defp normalize_blog_keys(blog) when is_map(blog) do
    Enum.reduce(blog, %{}, fn
      {key, value}, acc when is_binary(key) ->
        Map.put(acc, key, value)

      {key, value}, acc when is_atom(key) ->
        Map.put(acc, Atom.to_string(key), value)

      {key, value}, acc ->
        Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_blog_keys(other), do: other

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

  # Check if custom category submenu should be open based on subsection URLs
  defp custom_category_submenu_open?(current_path, subsections)
       when is_binary(current_path) and is_list(subsections) do
    subsection_urls = Enum.map(subsections, & &1.url)

    current_path
    |> remove_phoenix_kit_prefix()
    |> remove_locale_prefix()
    |> path_matches_any?(subsection_urls)
  end

  defp custom_category_submenu_open?(_, _), do: false
end
