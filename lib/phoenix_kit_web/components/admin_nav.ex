defmodule PhoenixKitWeb.Components.AdminNav do
  @moduledoc """
  Admin navigation components for the PhoenixKit admin panel.
  Provides consistent navigation elements for both desktop sidebar and mobile drawer.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.ThemeConfig
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icon

  @doc """
  Renders an admin navigation item with proper active state styling.

  ## Examples

      <.admin_nav_item
        href={Routes.locale_aware_path(assigns,"/admin/dashboard")}
        icon="dashboard"
        label="Dashboard"
        current_path={Routes.locale_aware_path(assigns,"/admin/dashboard")}
      />

      <.admin_nav_item
        href={Routes.locale_aware_path(assigns,"/admin/users")}
        icon="users"
        label="Users"
        current_path={Routes.locale_aware_path(assigns,"/admin/dashboard")}
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
        <% "entities" -> %>
          <.icon name="hero-cube" class="w-5 h-5" />
        <% "language" -> %>
          <.icon name="hero-language" class="w-5 h-5" />
        <% "seo" -> %>
          <.icon name="hero-magnifying-glass-circle" class="w-5 h-5" />
        <% "document" -> %>
          <.icon name="hero-document-text" class="w-5 h-5" />
        <% "maintenance" -> %>
          <.icon name="hero-wrench-screwdriver" class="w-5 h-5" />
        <% "storage" -> %>
          <.icon name="hero-folder" class="w-5 h-5" />
        <% "photo" -> %>
          <.icon name="hero-photo" class="w-5 h-5" />
        <% _ -> %>
          <.icon name="hero-squares-2x2" class="w-5 h-5" />
      <% end %>
    </div>
    """
  end

  @doc """
  Renders theme controller for admin panel.
  Based on EZNews theme system with DaisyUI integration.
  """
  attr(:mobile, :boolean, default: false)

  def admin_theme_controller(assigns) do
    assigns =
      assigns
      |> assign(:dropdown_themes, ThemeConfig.dropdown_themes())
      |> assign(:system_targets, ThemeConfig.slider_targets("system") |> Enum.join(","))
      |> assign(:light_targets, ThemeConfig.slider_targets("light") |> Enum.join(","))
      |> assign(:dark_targets, ThemeConfig.slider_targets("dark") |> Enum.join(","))
      |> assign(:system_primary, ThemeConfig.slider_primary_theme("system"))
      |> assign(:light_primary, ThemeConfig.slider_primary_theme("light"))
      |> assign(:dark_primary, ThemeConfig.slider_primary_theme("dark"))
      |> assign(:system_primary, ThemeConfig.slider_primary_theme("system"))
      |> assign(:light_primary, ThemeConfig.slider_primary_theme("light"))
      |> assign(:dark_primary, ThemeConfig.slider_primary_theme("dark"))

    ~H"""
    <div class="flex flex-col gap-3 w-full">
      <div class="relative w-full" data-theme-dropdown>
        <details class="dropdown dropdown-end dropdown-bottom" id="theme-dropdown">
          <summary class="btn btn-sm btn-ghost btn-circle">
            <.icon name="hero-swatch" class="w-5 h-5" />
          </summary>
          <ul
            class="dropdown-content w-72 min-w-0 rounded-box border border-base-200 bg-base-100 p-2 shadow-xl z-[60] mt-2 max-h-[80vh] overflow-y-auto overflow-x-hidden list-none space-y-1"
            tabindex="0"
            phx-click-away={JS.remove_attribute("open", to: "#theme-dropdown")}
          >
            <%= for theme <- @dropdown_themes do %>
              <li class="w-full">
                <button
                  type="button"
                  phx-click={JS.dispatch("phx:set-admin-theme", detail: %{theme: theme.value})}
                  data-tip={theme.value}
                  data-theme-target={theme.value}
                  data-theme-role="dropdown-option"
                  role="option"
                  aria-pressed="false"
                  class="w-full group flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary"
                >
                  <%= case theme.type do %>
                    <% :system -> %>
                      <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-base-200 bg-base-100 shadow-sm">
                        <PhoenixKitWeb.Components.Core.Icons.icon_system class="size-4 opacity-90" />
                      </div>
                    <% :theme -> %>
                      <div
                        data-theme={theme.preview_theme}
                        class="grid h-8 w-8 shrink-0 grid-cols-2 gap-0.5 rounded-md border border-base-200 bg-base-100 p-0.5 shadow-sm"
                      >
                        <div class="rounded-full bg-base-content"></div>
                        <div class="rounded-full bg-primary"></div>
                        <div class="rounded-full bg-secondary"></div>
                        <div class="rounded-full bg-accent"></div>
                      </div>
                  <% end %>
                  <span class="flex-1 text-left font-medium text-base-content truncate">
                    {theme.label}
                  </span>
                  <span data-theme-active-indicator>
                    <PhoenixKitWeb.Components.Core.Icons.icon_check class="size-4 text-primary opacity-0 scale-75 transition-all" />
                  </span>
                </button>
              </li>
            <% end %>
          </ul>
        </details>
      </div>
    </div>
    """
  end

  @doc """
  Renders language dropdown for top bar navigation.
  Shows globe icon with dropdown menu for language selection.
  """
  attr(:current_path, :string, default: "")
  attr(:current_locale, :string, default: "en")

  def admin_language_dropdown(assigns) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Get admin languages from settings (separate from the language module)
    admin_languages = get_admin_languages()

    # Extract base code from current locale for matching
    current_base = DialectMapper.extract_base(assigns.current_locale)

    # Transform languages: code = base (for URLs), dialect = full (for preferences)
    transformed_languages =
      Enum.map(admin_languages, fn lang ->
        dialect = lang["code"]
        base = DialectMapper.extract_base(dialect)

        lang
        |> Map.put("code", base)
        |> Map.put("dialect", dialect)
      end)

    current_language =
      Enum.find(transformed_languages, &(&1["code"] == current_base)) ||
        %{
          "code" => current_base,
          "dialect" => assigns.current_locale,
          "name" => String.upcase(current_base)
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
              <a
                href={build_locale_url(@current_path, language["code"])}
                phx-click="phoenix_kit_set_locale"
                phx-value-locale={language["code"]}
                phx-value-url={build_locale_url(@current_path, language["code"])}
                class={[
                  "w-full flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition hover:bg-base-200",
                  if(language["code"] == @current_base, do: "bg-base-200", else: "")
                ]}
              >
                <span class="text-lg">{get_language_flag(language["dialect"])}</span>
                <span class="flex-1 text-left font-medium text-base-content">
                  {language["name"]}
                </span>
                <%= if language["code"] == @current_base do %>
                  <PhoenixKitWeb.Components.Core.Icons.icon_check class="size-4 text-primary" />
                <% end %>
              </a>
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
    avatar_file_id = user && user.custom_fields && user.custom_fields["avatar_file_id"]

    assigns =
      assigns
      |> assign(:avatar_file_id, avatar_file_id)
      |> assign(:user, user)

    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="dropdown dropdown-end">
        <%!-- User Avatar Button --%>
        <div
          tabindex="0"
          role="button"
          class="w-10 h-10 rounded-lg bg-primary flex items-center justify-center text-primary-content font-bold cursor-pointer hover:opacity-80 transition-opacity overflow-hidden"
        >
          <%= if @avatar_file_id do %>
            <% avatar_url = PhoenixKit.Storage.URLSigner.signed_url(@avatar_file_id, "medium") %>
            <img
              src={avatar_url}
              alt="Avatar"
              class="w-full h-full object-cover"
              onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';"
            />
            <div class="hidden w-full h-full bg-primary flex items-center justify-center text-primary-content font-bold">
              {String.first(@user.email || "?") |> String.upcase()}
            </div>
          <% else %>
            {String.first(PhoenixKit.Users.Auth.Scope.user_email(@scope) || "?") |> String.upcase()}
          <% end %>
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

          <div class="divider my-0"></div>

          <%!-- Settings Link --%>
          <li>
            <.link
              href={Routes.locale_aware_path(assigns, "/users/settings")}
              class="flex items-center gap-3"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-4 h-4" />
              <span>Settings</span>
            </.link>
          </li>

          <%!-- Language Switcher (Admin Languages) --%>
          <% admin_languages = get_admin_languages() %>
          <%= if length(admin_languages) > 0 do %>
            <div class="divider my-0"></div>

            <li class="menu-title px-4 py-1">
              <span class="text-xs">Language</span>
            </li>

            <%= for language <- admin_languages do %>
              <li>
                <a
                  href={generate_language_switch_url(@current_path, language["code"])}
                  class={[
                    "flex items-center gap-3",
                    if(language["code"] == @current_locale, do: "active", else: "")
                  ]}
                >
                  <span class="text-lg">{get_language_flag(language["code"])}</span>
                  <span>{language["name"]}</span>
                  <%= if language["code"] == @current_locale do %>
                    <PhoenixKitWeb.Components.Core.Icons.icon_check class="w-4 h-4 ml-auto" />
                  <% end %>
                </a>
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
    avatar_file_id = user && user.custom_fields && user.custom_fields["avatar_file_id"]

    assigns =
      assigns
      |> assign(:avatar_file_id, avatar_file_id)
      |> assign(:user, user)

    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="bg-base-200 rounded-lg p-3 text-sm">
        <div class="flex items-center gap-2 mb-2">
          <div class="w-8 h-8 bg-primary rounded-md flex items-center justify-center text-primary-content text-xs font-bold overflow-hidden">
            <%= if @avatar_file_id do %>
              <% avatar_url = PhoenixKit.Storage.URLSigner.signed_url(@avatar_file_id, "small") %>
              <img
                src={avatar_url}
                alt="Avatar"
                class="w-full h-full object-cover"
                onerror="this.style.display='none'; this.nextElementSibling.style.display='flex';"
              />
              <div class="hidden w-full h-full bg-primary flex items-center justify-center text-primary-content text-xs font-bold">
                {String.first(@user.email || "?") |> String.upcase()}
              </div>
            <% else %>
              {String.first(PhoenixKit.Users.Auth.Scope.user_email(@scope) || "?") |> String.upcase()}
            <% end %>
          </div>
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
            href={Routes.locale_aware_path(assigns, "/users/settings")}
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
  defp nav_item_active?(current_path, href, nested, exact_match_only) do
    current_parts = parse_admin_path(current_path)
    href_parts = parse_admin_path(href)

    # For nested items, use only exact and tab matching to prevent parent highlighting
    if nested do
      exact_match?(current_parts, href_parts) or tab_match?(current_parts, href_parts)
    else
      # For top-level items with exact_match_only, skip hierarchical matching
      base_matches =
        exact_match?(current_parts, href_parts) or
          tab_match?(current_parts, href_parts) or
          parent_match?(current_parts, href_parts)

      if exact_match_only do
        base_matches
      else
        base_matches or hierarchical_match?(current_parts, href_parts)
      end
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
        # Default to dashboard for root
        "" -> "dashboard"
        "/" -> "dashboard"
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
    # Only match base language codes (2 letters, no hyphen)
    # Full dialect codes (en-US) are no longer used in URLs
    String.length(locale) == 2 and Regex.match?(~r/^[a-z]{2}$/i, locale)
  end

  # Helper function to get admin languages from settings
  # Default is ["en-US"] - a fresh install only has English enabled
  defp get_admin_languages do
    admin_languages_json =
      Settings.get_setting("admin_languages", Jason.encode!(["en-US"]))

    languages =
      case Jason.decode(admin_languages_json) do
        {:ok, codes} when is_list(codes) -> codes
        _ -> ["en-US"]
      end

    # Map language codes to language details
    languages
    |> Enum.map(fn code ->
      case Languages.get_predefined_language(code) do
        %{name: name, flag: flag, native: native} ->
          %{"code" => code, "name" => name, "flag" => flag, "native" => native}

        nil ->
          %{"code" => code, "name" => String.upcase(code), "flag" => "🌐", "native" => ""}
      end
    end)
  end

  # Helper function to get language flag emoji
  defp get_language_flag(code) when is_binary(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      nil -> "🌐"
    end
  end

  # Build URL with base code - expects base code directly (e.g., "en" not "en-US")
  # Used by admin language dropdown where language["code"] is already the base code
  # Uses Routes.path/2 which automatically skips locale prefix for default language
  defp build_locale_url(current_path, base_code) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Get valid language codes from both admin and frontend systems
    admin_languages = get_admin_languages()
    admin_language_codes = Enum.map(admin_languages, & &1["code"])
    admin_base_codes = Enum.map(admin_language_codes, &DialectMapper.extract_base/1)

    # Get frontend language codes from the Language Module
    frontend_language_codes = Languages.enabled_locale_codes()
    frontend_base_codes = Enum.map(frontend_language_codes, &DialectMapper.extract_base/1)

    # Accept language if it's valid in EITHER admin or frontend (both full and base codes)
    valid_language_codes =
      (admin_language_codes ++ frontend_language_codes ++ admin_base_codes ++ frontend_base_codes)
      |> Enum.uniq()

    # Remove PhoenixKit prefix if present
    normalized_path = String.replace_prefix(current_path || "", "/phoenix_kit", "")

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

    # Use Routes.path which handles default language logic
    # Default language gets clean URLs (no prefix), other languages get prefixed
    Routes.path(clean_path, locale: base_code)
  end

  # Legacy helper - kept for backward compatibility
  defp generate_language_switch_url(current_path, new_locale) do
    alias PhoenixKit.Modules.Languages.DialectMapper
    base_code = DialectMapper.extract_base(new_locale)
    build_locale_url(current_path, base_code)
  end
end
