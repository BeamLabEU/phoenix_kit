defmodule PhoenixKitWeb.Components.AdminNav do
  @moduledoc """
  Admin navigation components for the PhoenixKit admin panel.
  Provides consistent navigation elements for both desktop sidebar and mobile drawer.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.ThemeController, only: [theme_controller: 1]

  @default_locale Config.default_locale()

  @doc """
  Renders an admin navigation item with proper active state styling.

  ## Examples

      <.admin_nav_item
        href={Routes.locale_aware_path(assigns,"/admin")}
        icon="dashboard"
        label="Dashboard"
        current_path={Routes.locale_aware_path(assigns,"/admin")}
      />

      <.admin_nav_item
        href={Routes.locale_aware_path(assigns,"/admin/users")}
        icon="users"
        label="Users"
        current_path={Routes.locale_aware_path(assigns,"/admin")}
        mobile={true}
      />
  """
  attr(:href, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:description, :string, default: nil)
  attr(:current_path, :string, required: true)
  attr(:mobile, :boolean, default: false)
  attr(:nested, :boolean, default: false)
  attr(:disable_active, :boolean, default: false)
  attr(:exact_match_only, :boolean, default: false)
  attr(:submenu_open, :boolean, default: false)

  def admin_nav_item(assigns) do
    active =
      if assigns.disable_active,
        do: false,
        else:
          nav_item_active?(
            assigns.current_path,
            assigns.href,
            assigns.nested,
            assigns.exact_match_only
          )

    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center py-2 rounded-lg text-sm font-medium transition-colors group",
        cond do
          @active ->
            "bg-primary text-primary-content hover:bg-primary/90"

          @submenu_open ->
            "bg-base-200/50 text-base-content hover:bg-base-200 hover:text-primary"

          true ->
            "text-base-content hover:bg-base-200 hover:text-primary"
        end,
        if(@mobile, do: "w-full", else: ""),
        if(@nested, do: "pl-8 pr-3", else: "px-3")
      ]}
    >
      <%= if @nested do %>
        <%!-- Nested item with custom hero icon --%>
        <%= if String.starts_with?(@icon, "hero-") do %>
          <span class={[@icon, "w-4 h-4 mr-2 flex-shrink-0"]}></span>
          <span class="text-sm truncate">{@label}</span>
        <% else %>
          <div class="w-4 h-4 mr-2 flex-shrink-0">
            <.admin_nav_icon icon={@icon} active={@active} />
          </div>
          <span class="text-sm truncate">{@label}</span>
        <% end %>
      <% else %>
        <.admin_nav_icon icon={@icon} active={@active} />
        <span class="ml-3 font-medium truncate">{@label}</span>
      <% end %>
    </.link>
    """
  end

  @doc """
  Renders an icon for admin navigation items.
  """
  attr(:icon, :string, required: true)
  attr(:active, :boolean, default: false)

  def admin_nav_icon(assigns) do
    ~H"""
    <div class="flex items-center flex-shrink-0">
      <%= case @icon do %>
        <% "dashboard" -> %>
          <.icon name="hero-home" class="w-5 h-5" />
        <% "users" -> %>
          <.icon name="hero-users" class="w-5 h-5" />
        <% "roles" -> %>
          <.icon name="hero-shield-check" class="w-5 h-5" />
        <% "modules" -> %>
          <.icon name="hero-puzzle-piece" class="w-5 h-5" />
        <% "settings" -> %>
          <.icon name="hero-cog-6-tooth" class="w-5 h-5" />
        <% "sessions" -> %>
          <.icon name="hero-computer-desktop" class="w-5 h-5" />
        <% "live_sessions" -> %>
          <.icon name="hero-eye" class="w-5 h-5" />
        <% "referral_codes" -> %>
          <.icon name="hero-ticket" class="w-5 h-5" />
        <% "email" -> %>
          <.icon name="hero-envelope" class="w-5 h-5" />
        <% "billing" -> %>
          <.icon name="hero-banknotes" class="w-5 h-5" />
        <% "entities" -> %>
          <.icon name="hero-cube" class="w-5 h-5" />
        <% "ticket" -> %>
          <.icon name="hero-chat-bubble-left-right" class="w-5 h-5" />
        <% "comments" -> %>
          <.icon name="hero-chat-bubble-left-right" class="w-5 h-5" />
        <% "ai" -> %>
          <.icon name="hero-cpu-chip" class="w-5 h-5" />
        <% "sync" -> %>
          <.icon name="hero-arrows-right-left" class="w-5 h-5" />
        <% "language" -> %>
          <.icon name="hero-language" class="w-5 h-5" />
        <% "seo" -> %>
          <.icon name="hero-magnifying-glass-circle" class="w-5 h-5" />
        <% "sitemap" -> %>
          <.icon name="hero-map" class="w-5 h-5" />
        <% "document" -> %>
          <.icon name="hero-document-text" class="w-5 h-5" />
        <% "legal" -> %>
          <.icon name="hero-scale" class="w-5 h-5" />
        <% "organization" -> %>
          <.icon name="hero-building-office" class="w-5 h-5" />
        <% "maintenance" -> %>
          <.icon name="hero-wrench-screwdriver" class="w-5 h-5" />
        <% "storage" -> %>
          <.icon name="hero-folder" class="w-5 h-5" />
        <% "photo" -> %>
          <.icon name="hero-photo" class="w-5 h-5" />
        <% "jobs" -> %>
          <.icon name="hero-queue-list" class="w-5 h-5" />
        <% "shop" -> %>
          <.icon name="hero-shopping-bag" class="w-5 h-5" />
        <% _ -> %>
          <.icon name="hero-squares-2x2" class="w-5 h-5" />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders theme controller for admin panel.
  Uses the shared theme_controller component with all themes.
  """
  attr(:mobile, :boolean, default: false)

  def admin_theme_controller(assigns) do
    ~H"""
    <.theme_controller themes={:all} id="admin-theme-dropdown" />
    """
  end

  @doc """
  Renders language dropdown for top bar navigation.
  Shows globe icon with dropdown menu for language selection.
  """
  attr(:current_path, :string, default: "")
  attr(:current_locale, :string, default: "en")

  def admin_language_dropdown(assigns) do
    # Get admin languages from settings (separate from the language module)
    admin_languages = get_admin_languages()

    # Extract base code from current locale for matching
    current_base = DialectMapper.extract_base(assigns.current_locale)

    # Transform languages: code = base (for URLs), dialect = full (for preferences)
    transformed_languages =
      Enum.map(admin_languages, fn lang ->
        dialect = lang.code
        base = DialectMapper.extract_base(dialect)

        %{code: base, dialect: dialect, name: lang.name, flag: lang.flag, native: lang.native}
      end)

    current_language =
      Enum.find(transformed_languages, &(&1.code == current_base)) ||
        %{
          code: current_base,
          dialect: assigns.current_locale,
          name: String.upcase(current_base)
        }

    # Hide dropdown when only 1 language is configured
    show_dropdown = length(transformed_languages) > 1

    assigns =
      assigns
      |> assign(:enabled_languages, transformed_languages)
      |> assign(:current_language, current_language)
      |> assign(:current_base, current_base)
      |> assign(:show_dropdown, show_dropdown)

    ~H"""
    <div :if={@show_dropdown} class="relative" data-language-dropdown>
      <details class="dropdown dropdown-end dropdown-bottom" id="language-dropdown">
        <summary class="btn btn-sm btn-ghost btn-circle">
          <.icon name="hero-globe-alt" class="w-5 h-5" />
        </summary>
        <ul
          class="dropdown-content w-52 rounded-box border border-base-200 bg-base-100 p-2 shadow-xl z-[60] mt-2 list-none space-y-1"
          tabindex="0"
          phx-click-away={JS.remove_attribute("open", to: "#language-dropdown")}
        >
          <%= for language <- @enabled_languages do %>
            <li class="w-full">
              <button
                type="button"
                phx-click="phoenix_kit_set_locale"
                phx-value-locale={language.dialect}
                phx-value-url={build_locale_url(@current_path, language.code)}
                class={[
                  "w-full flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition hover:bg-base-200 cursor-pointer",
                  if(language.code == @current_base, do: "bg-base-200", else: "")
                ]}
              >
                <span class="text-lg">{get_language_flag(language.dialect)}</span>
                <span class="flex-1 text-left font-medium text-base-content">
                  {language.name}
                </span>
                <%= if language.code == @current_base do %>
                  <PhoenixKitWeb.Components.Core.Icons.icon_check class="size-4 text-primary" />
                <% end %>
              </button>
            </li>
          <% end %>
        </ul>
      </details>
    </div>
    """
  end

  @doc """
  Renders user dropdown for top bar navigation.
  Shows user avatar with dropdown menu containing email, role, settings and logout.
  """
  attr(:scope, :any, default: nil)
  attr(:current_path, :string, default: "")
  attr(:current_locale, :string, default: "en")

  def admin_user_dropdown(assigns) do
    user = Scope.user(assigns.scope)

    # Get admin languages info for the dropdown
    admin_languages = get_admin_languages()
    show_language_section = not Enum.empty?(admin_languages)
    show_language_divider = PhoenixKit.Config.user_dashboard_enabled?() and show_language_section

    assigns =
      assigns
      |> assign(:user, user)
      |> assign(:admin_languages, admin_languages)
      |> assign(:show_language_section, show_language_section)
      |> assign(:show_language_divider, show_language_divider)

    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="dropdown dropdown-end">
        <%!-- User Avatar Button --%>
        <div
          tabindex="0"
          role="button"
          class="cursor-pointer hover:opacity-80 transition-opacity"
        >
          <PhoenixKitWeb.Components.Core.UserInfo.user_avatar
            user={@user}
            size="md"
            class="!rounded-lg"
          />
        </div>

        <%!-- Dropdown Menu --%>
        <ul
          tabindex="0"
          class="dropdown-content menu bg-base-100 rounded-box z-[60] w-64 p-2 shadow-xl border border-base-300 mt-3"
        >
          <%!-- User Info Header --%>
          <li class="menu-title px-4 py-2">
            <div class="flex flex-col gap-1">
              <span class="text-sm font-medium text-base-content truncate">
                {PhoenixKit.Users.Auth.Scope.user_email(@scope)}
              </span>
              <div>
                <%= if PhoenixKit.Users.Auth.Scope.owner?(@scope) do %>
                  <div class="badge badge-error badge-xs">Owner</div>
                <% else %>
                  <%= if PhoenixKit.Users.Auth.Scope.admin?(@scope) do %>
                    <div class="badge badge-warning badge-xs">Admin</div>
                  <% else %>
                    <div class="badge badge-ghost badge-xs">User</div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </li>

          <%!-- Settings Link --%>
          <%= if PhoenixKit.Config.user_dashboard_enabled?() do %>
            <li>
              <.link
                href={Routes.locale_aware_path(assigns, "/dashboard/settings")}
                class="flex items-center gap-3"
              >
                <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-4 h-4" />
                <span>Settings</span>
              </.link>
            </li>
          <% end %>

          <%!-- Language Switcher (Admin Languages) --%>
          <%= if @show_language_divider do %>
            <div class="divider my-0"></div>
          <% end %>

          <%= if @show_language_section do %>
            <li class="menu-title px-4 py-1">
              <span class="text-xs">Language</span>
            </li>

            <%= for language <- @admin_languages do %>
              <li>
                <button
                  type="button"
                  phx-click="phoenix_kit_set_locale"
                  phx-value-locale={language.code}
                  phx-value-url={generate_language_switch_url(@current_path, language.code)}
                  class={[
                    "flex items-center gap-3",
                    if(language.code == @current_locale, do: "active", else: "")
                  ]}
                >
                  <span class="text-lg">{get_language_flag(language.code)}</span>
                  <span>{language.name}</span>
                  <%= if language.code == @current_locale do %>
                    <PhoenixKitWeb.Components.Core.Icons.icon_check class="w-4 h-4 ml-auto" />
                  <% end %>
                </button>
              </li>
            <% end %>
          <% end %>

          <div class="divider my-0"></div>

          <%!-- Log Out Link --%>
          <li>
            <.link
              href={Routes.locale_aware_path(assigns, "/users/log-out")}
              method="delete"
              class="flex items-center gap-3 text-error hover:bg-error hover:text-error-content"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_logout class="w-4 h-4" />
              <span>Log Out</span>
            </.link>
          </li>
        </ul>
      </div>
    <% else %>
      <%!-- Not Authenticated - Show Login Button --%>
      <.link
        href={Routes.locale_aware_path(assigns, "/users/log-in")}
        class="btn btn-primary btn-sm"
      >
        Login
      </.link>
    <% end %>
    """
  end

  @doc """
  Renders user information section for admin panel sidebar.
  Shows current user email and role information.
  """
  attr(:scope, :any, default: nil)

  def admin_user_info(assigns) do
    user = Scope.user(assigns.scope)

    assigns =
      assigns
      |> assign(:user, user)

    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="bg-base-200 rounded-lg p-3 text-sm">
        <div class="flex items-center gap-2 mb-2">
          <PhoenixKitWeb.Components.Core.UserInfo.user_avatar
            user={@user}
            size="sm"
            class="!rounded-md"
          />
          <div class="flex-1 min-w-0">
            <div class="truncate text-xs font-medium text-base-content">
              {PhoenixKit.Users.Auth.Scope.user_email(@scope)}
            </div>
            <%= if PhoenixKit.Users.Auth.Scope.owner?(@scope) do %>
              <div class="badge badge-error badge-xs">Owner</div>
            <% else %>
              <%= if PhoenixKit.Users.Auth.Scope.admin?(@scope) do %>
                <div class="badge badge-warning badge-xs">Admin</div>
              <% else %>
                <div class="badge badge-ghost badge-xs">User</div>
              <% end %>
            <% end %>
          </div>
        </div>

        <div class="flex gap-1">
          <.link
            href={Routes.locale_aware_path(assigns, "/dashboard/settings")}
            class="btn btn-ghost btn-xs flex-1"
          >
            <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-3 h-3" />
          </.link>

          <.link
            href={Routes.locale_aware_path(assigns, "/users/log-out")}
            method="delete"
            class="btn btn-ghost btn-xs flex-1 text-error hover:bg-error hover:text-error-content"
          >
            <PhoenixKitWeb.Components.Core.Icons.icon_logout />
          </.link>
        </div>
      </div>
    <% else %>
      <div class="bg-base-200 rounded-lg p-3 text-center text-sm">
        <div class="text-base-content/70 mb-2">Not authenticated</div>
        <.link
          href={Routes.locale_aware_path(assigns, "/users/log-in")}
          class="btn btn-primary btn-sm w-full"
        >
          Login
        </.link>
      </div>
    <% end %>
    """
  end

  # Helper function to determine if navigation item is active
  defp nav_item_active?(current_path, href, _nested, exact_match_only) do
    current_parts = parse_admin_path(current_path)
    href_parts = parse_admin_path(href)

    # Base matching: exact, tab, or parent match
    base_matches =
      exact_match?(current_parts, href_parts) or
        tab_match?(current_parts, href_parts) or
        parent_match?(current_parts, href_parts)

    # For exact_match_only items (like Dashboard), skip hierarchical matching
    # For all other items (including nested), use hierarchical matching
    # This allows nested items like Products to be active on /products/:id/edit
    if exact_match_only do
      base_matches
    else
      base_matches or hierarchical_match?(current_parts, href_parts)
    end
  end

  defp hierarchical_match?(current_parts, href_parts) do
    String.starts_with?(current_parts.base_path, href_parts.base_path <> "/")
  end

  # Check if paths match exactly
  defp exact_match?(current_parts, href_parts) do
    href_parts.base_path == current_parts.base_path &&
      is_nil(href_parts.tab) &&
      is_nil(current_parts.tab)
  end

  # Check if tab-specific paths match
  defp tab_match?(current_parts, href_parts) do
    href_parts.base_path == current_parts.base_path &&
      href_parts.tab == current_parts.tab
  end

  # Check if parent page matches when on a tab
  defp parent_match?(current_parts, href_parts) do
    href_parts.base_path == current_parts.base_path &&
      is_nil(href_parts.tab) &&
      not is_nil(current_parts.tab)
  end

  # Helper function to parse admin path into components
  defp parse_admin_path(path) when is_binary(path) do
    # Remove query parameters and split path
    [path_part | _] = String.split(path, "?")

    # Get dynamic prefix and normalize paths
    prefix = PhoenixKit.Config.get_url_prefix()
    admin_prefix = if prefix == "/", do: "/admin", else: "#{prefix}/admin"

    base_path =
      path_part
      |> String.replace_prefix(prefix, "")
      |> strip_locale_segment()
      |> String.replace_prefix(admin_prefix, "")
      |> String.replace_prefix("/admin", "")
      |> case do
        # Only treat exact empty paths as dashboard (for /admin)
        "" -> ""
        "/" -> ""
        path -> String.trim_leading(path, "/")
      end

    # Extract tab parameter if present
    tab =
      if String.contains?(path, "?tab=") do
        path
        |> String.split("?tab=")
        |> List.last()
        |> String.split("&")
        |> List.first()
      else
        nil
      end

    %{base_path: base_path, tab: tab}
  end

  defp parse_admin_path(_), do: %{base_path: "dashboard", tab: nil}

  defp strip_locale_segment(path) do
    case String.split(path, "/", parts: 3) do
      ["", locale, rest] when rest != "" ->
        if locale_candidate?(locale) do
          "/" <> rest
        else
          path
        end

      _ ->
        path
    end
  end

  defp locale_candidate?(locale) do
    # Match both base language codes (en) and full dialect codes (en-US)
    Regex.match?(~r/^[a-z]{2}(-[A-Z]{2})?$/i, locale)
  end

  # Helper function to get admin languages from settings
  # Returns empty list if Languages module is disabled or not loaded
  defp get_admin_languages do
    # If Languages module is not loaded or not enabled, return empty list
    if Code.ensure_loaded?(Languages) and Languages.enabled?() do
      # Read admin languages from settings cache (not all enabled languages)
      # Note: admin_languages is stored as JSON string in value column
      admin_languages_json =
        Settings.get_setting_cached("admin_languages", nil) ||
          Jason.encode!([@default_locale])

      admin_language_codes =
        case Jason.decode(admin_languages_json) do
          {:ok, codes} when is_list(codes) -> codes
          _ -> [@default_locale]
        end

      # Map codes to full language objects
      admin_language_codes
      |> Enum.map(fn code ->
        case Languages.get_predefined_language(code) do
          %{} = lang ->
            lang

          nil ->
            # Fallback for unknown codes
            %{code: code, name: code, flag: "🌐", native: ""}
        end
      end)
    else
      # Module disabled, return empty list
      []
    end
  end

  # Helper function to get language flag emoji
  defp get_language_flag(code) when is_binary(code) do
    if Code.ensure_loaded?(Languages) do
      case Languages.get_predefined_language(code) do
        %{flag: flag} -> flag
        nil -> "🌐"
      end
    else
      "🌐"
    end
  end

  # Build URL with base code - expects base code directly (e.g., "en" not "en-US")
  # Used by admin language dropdown where language["code"] is already the base code
  # Uses Routes.path/2 which automatically skips locale prefix for default language
  defp build_locale_url(current_path, base_code) do
    # Get valid language codes from both admin and frontend systems
    admin_languages = get_admin_languages()
    admin_language_codes = Enum.map(admin_languages, & &1.code)
    admin_base_codes = Enum.map(admin_language_codes, &DialectMapper.extract_base/1)

    # Get frontend language codes from the Language Module
    frontend_language_codes =
      if Code.ensure_loaded?(Languages),
        do: Languages.enabled_locale_codes(),
        else: []

    frontend_base_codes = Enum.map(frontend_language_codes, &DialectMapper.extract_base/1)

    # Accept language if it's valid in EITHER admin or frontend (both full and base codes)
    valid_language_codes =
      (admin_language_codes ++ frontend_language_codes ++ admin_base_codes ++ frontend_base_codes)
      |> Enum.uniq()

    # Remove PhoenixKit prefix if present (use dynamic config, not hardcoded)
    url_prefix = PhoenixKit.Config.get_url_prefix()
    prefix_to_remove = if url_prefix == "/", do: "", else: url_prefix
    normalized_path = String.replace_prefix(current_path || "", prefix_to_remove, "")

    # Remove existing locale prefix only if it matches actual language codes
    clean_path =
      case String.split(normalized_path, "/", parts: 3) do
        ["", potential_locale, rest] ->
          if potential_locale in valid_language_codes do
            "/" <> rest
          else
            normalized_path
          end

        ["", potential_locale] ->
          if potential_locale in valid_language_codes do
            "/"
          else
            normalized_path
          end

        _ ->
          normalized_path
      end

    Routes.admin_path(clean_path, base_code)
  end

  # Legacy helper - kept for backward compatibility
  defp generate_language_switch_url(current_path, new_locale) do
    base_code = DialectMapper.extract_base(new_locale)
    build_locale_url(current_path, base_code)
  end
end
