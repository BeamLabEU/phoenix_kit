defmodule PhoenixKitWeb.Components.AdminNav do
  @moduledoc """
  Admin navigation components for the PhoenixKit admin panel.
  Provides consistent navigation elements for both desktop sidebar and mobile drawer.
  """

  use Phoenix.Component

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.OAuthAvailability
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher
  alias PhoenixKitWeb.Users.MultiSession

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.ThemeController, only: [theme_controller: 1]

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
        <% "ai" -> %>
          <.icon name="hero-cpu-chip" class="w-5 h-5" />
        <% "language" -> %>
          <.icon name="hero-language" class="w-5 h-5" />
        <% "crawlers" -> %>
          <.icon name="hero-bug-ant" class="w-5 h-5" />
        <% "sitemap" -> %>
          <.icon name="hero-map" class="w-5 h-5" />
        <% "document" -> %>
          <.icon name="hero-document-text" class="w-5 h-5" />
        <% "legal" -> %>
          <.icon name="hero-scale" class="w-5 h-5" />
        <% "organization" -> %>
          <.icon name="hero-building-office" class="w-5 h-5" />
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
    <%!-- :dashboard_themes applies HERE too — hardcoding :all meant a host's
         narrowed theme list governed only the user dashboard while every
         admin page kept the full catalogue, silently. --%>
    <.theme_controller
      themes={PhoenixKit.Config.get(:dashboard_themes, :all)}
      id="admin-theme-dropdown"
    />
    """
  end

  @doc """
  Renders user dropdown for top bar navigation.
  Shows user avatar with dropdown menu containing email, role, settings and logout.
  """
  attr(:scope, :any, default: nil)
  attr(:current_path, :string, default: "")
  attr(:current_locale, :string, default: "en")
  attr(:accounts, :list, default: [])
  attr(:multi_session_allowed?, :boolean, default: false)

  def admin_user_dropdown(assigns) do
    user = Scope.user(assigns.scope)

    # Highlight by BASE code, not full-dialect equality. `@current_locale`
    # may be a base ("en") or a resolved dialect that differs from the
    # enabled one (e.g. `resolve_dialect("en")` => "en-US" while English is
    # enabled as plain "en"), so a raw `==` against the enabled code never
    # matched on locales with a regional default. Same rule as
    # UserDashboardNav.language_menu_section/1.
    current_base = DialectMapper.extract_base(assigns.current_locale)

    # Get admin languages info for the dropdown
    admin_languages =
      Enum.map(get_admin_languages(), fn language ->
        Map.put(language, :active?, DialectMapper.extract_base(language.code) == current_base)
      end)

    # One language is nothing to switch between (same rule as UserDashboardNav).
    show_language_section = length(admin_languages) > 1
    show_language_divider = PhoenixKit.Config.user_dashboard_enabled?() and show_language_section

    assigns =
      assigns
      |> assign(:user, user)
      |> assign(:admin_languages, admin_languages)
      |> assign(:show_language_section, show_language_section)
      |> assign(:show_language_divider, show_language_divider)
      |> assign(:accounts_removable?, any_removable_account?(assigns.accounts))

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
          class="dropdown-content menu bg-base-100 rounded-box z-[60] w-64 p-2 shadow-xl border border-base-300 mt-3 max-h-[calc(100vh-5rem)] overflow-y-auto overflow-x-hidden flex-nowrap"
        >
          <%!-- User Info Header --%>
          <li class="menu-title px-4 py-2">
            <div class="flex flex-col gap-1">
              <span class="text-sm font-medium text-base-content truncate">
                {PhoenixKit.Users.Auth.Scope.user_email(@scope)}
              </span>
              <div>
                <.current_role_badge scope={@scope} />
              </div>
            </div>
          </li>

          <%!-- Settings Link. Not gated on `user_dashboard_enabled?` any --%>
          <%!-- more: the account page it points at is routed              --%>
          <%!-- unconditionally, and the old guard meant a host that       --%>
          <%!-- compiled the dashboard out left admins with no way in to   --%>
          <%!-- their own email and password.                              --%>
          <li>
            <.link
              href={Routes.locale_aware_user_settings_path(assigns)}
              class="flex items-center gap-3"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-4 h-4" />
              <span>Settings</span>
            </.link>
          </li>

          <%!-- Language Switcher (Admin Languages) --%>
          <%= if @show_language_divider do %>
            <div class="divider my-0"></div>
          <% end %>

          <%= if @show_language_section do %>
            <li class="menu-title px-4 py-1">
              <span class="text-xs">Language</span>
            </li>

            <%!--
              Independently scrollable language list — caps at ~5 visible rows.
              Buttons are styled directly (no nested daisyUI <ul class="menu">) so
              the parent menu doesn't apply submenu indent (16px margin) or
              li-child padding (12px) that would otherwise force horizontal scroll
              and leave a weird left indent. `!p-0` resets the menu-child padding
              the parent <ul> applies to the wrapper <li>'s children.
            --%>
            <li class="p-0 !bg-transparent hover:!bg-transparent focus:!bg-transparent">
              <div class="!p-0 block w-full max-h-60 overflow-y-auto overflow-x-hidden !bg-transparent hover:!bg-transparent focus:!bg-transparent">
                <%= for language <- @admin_languages do %>
                  <button
                    type="button"
                    phx-click="phoenix_kit_set_locale"
                    phx-value-locale={language.code}
                    phx-value-url={
                      Routes.locale_switch_path(@current_path, language.code,
                        current_locale: assigns[:current_locale]
                      )
                    }
                    class={[
                      "w-full flex items-center gap-3 rounded-lg px-4 py-2 text-sm",
                      "focus:outline-none focus-visible:outline-none",
                      "phx-click-loading:opacity-60 phx-click-loading:pointer-events-none",
                      if(language.active?,
                        do:
                          "bg-primary !text-primary-content hover:bg-primary hover:!text-primary-content active:!bg-primary/80",
                        else:
                          "!text-base-content hover:bg-base-200 hover:!text-base-content focus:!text-base-content active:!text-base-content active:!bg-base-300"
                      )
                    ]}
                  >
                    <span class="text-lg">{get_language_flag(language.code)}</span>
                    <span>{language.name}</span>
                    <%= if language.active? do %>
                      <PhoenixKitWeb.Components.Core.Icons.icon_check class="w-4 h-4 ml-auto" />
                    <% end %>
                  </button>
                <% end %>
              </div>
            </li>
          <% end %>

          <PhoenixKitWeb.Components.Core.RoleSwitcher.role_switcher
            id="admin-role-switcher-menu"
            scope={@scope}
            current_path={@current_path}
            current_locale={@current_locale}
          />

          <%= if @multi_session_allowed? do %>
            <div class="divider my-0"></div>

            <li class="menu-title px-4 py-1">
              <span class="text-xs">Accounts</span>
            </li>

            <%!--
              Account rows. The wrapper div is the only `li > *`, so it carries
              the `!p-0` / `!bg-transparent` reset for the padding and hover
              colour daisyUI's `menu` puts on a menu item's direct child; every
              bit of spacing then lives on the inner row, which is structurally
              identical in both branches. That is what keeps the active row's
              email flush with the inactive ones — the two branches used to nest
              at different depths and the emails drifted apart by a pad's width.
            --%>
            <%= for account <- @accounts do %>
              <li class="p-0">
                <div class="!p-0 flex items-center gap-1 min-w-0 !bg-transparent hover:!bg-transparent focus:!bg-transparent">
                  <%= if account.active? do %>
                    <div class="flex-1 min-w-0">
                      <div class="flex w-full min-w-0 items-center gap-2 rounded-lg bg-primary px-4 py-2 text-primary-content">
                        <span class="flex-1 min-w-0 truncate" title={account.email}>
                          {account.email}
                        </span>
                        <span class="badge badge-xs border-0 bg-primary-content/20 text-primary-content shrink-0">
                          {account.role}
                        </span>
                        <PhoenixKitWeb.Components.Core.Icons.icon_check class="w-4 h-4 shrink-0" />
                      </div>
                    </div>
                  <% else %>
                    <.form
                      for={%{}}
                      action={Routes.locale_aware_path(assigns, "/users/session/active")}
                      method="put"
                      class="flex-1 min-w-0"
                    >
                      <input type="hidden" name="ref" value={account.ref} />
                      <input type="hidden" name="return_to" value={@current_path} />
                      <%!--
                        `text-start` is load-bearing. A <button> inherits the UA
                        `text-align: center`, and the email span below is
                        `flex-1`, so a short email centres itself inside its
                        column and drifts right of the active row's — that row
                        is a <div> and starts at the text edge.
                      --%>
                      <button
                        type="submit"
                        class="flex w-full min-w-0 items-center gap-2 rounded-lg px-4 py-2 text-start hover:bg-base-200"
                      >
                        <span class="flex-1 min-w-0 truncate" title={account.email}>
                          {account.email}
                        </span>
                        <span class="badge badge-xs badge-ghost shrink-0">{account.role}</span>
                        <%!-- Stands in for the active row's check so the role badges share a right edge. --%>
                        <span class="w-4 shrink-0" aria-hidden="true"></span>
                      </button>
                    </.form>
                  <% end %>

                  <%!--
                    Fixed-width trailing slot, rendered on every row as soon as a
                    single account is removable so the email column keeps one
                    width down the list. Left empty for the active and root rows.
                  --%>
                  <div
                    :if={@accounts_removable?}
                    class="w-6 shrink-0 flex items-center justify-center"
                  >
                    <.form
                      :if={not account.active? and not account.root?}
                      for={%{}}
                      action={
                        Routes.locale_aware_path(assigns, "/users/session/accounts/#{account.ref}")
                      }
                      method="delete"
                    >
                      <input type="hidden" name="return_to" value={@current_path} />
                      <button
                        type="submit"
                        class="btn btn-ghost btn-xs btn-square text-error"
                        title="Remove"
                        aria-label={"Remove " <> account.email}
                      >
                        <PhoenixKitWeb.Components.Core.Icons.icon_x_thin class="w-3 h-3" />
                      </button>
                    </.form>
                  </div>
                </div>
              </li>
            <% end %>

            <li class="p-0">
              <label
                for="pk-add-account-modal"
                class="!p-0 !bg-transparent hover:!bg-transparent focus:!bg-transparent cursor-pointer"
              >
                <span class="flex w-full items-center gap-3 rounded-lg px-4 py-2 hover:bg-base-200">
                  <PhoenixKitWeb.Components.Core.Icons.icon_user_add class="w-4 h-4 shrink-0" />
                  <span>Add account</span>
                </span>
              </label>
            </li>
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
              <span>Log out</span>
            </.link>
          </li>
          <%= if @multi_session_allowed? and length(@accounts) > 1 do %>
            <li>
              <.link
                href={Routes.locale_aware_path(assigns, "/users/log-out") <> "?all=1"}
                method="delete"
                class="flex items-center gap-3 text-error hover:bg-error hover:text-error-content"
              >
                <PhoenixKitWeb.Components.Core.Icons.icon_logout class="w-4 h-4" />
                <span>Log out from all accounts</span>
              </.link>
            </li>
          <% end %>
        </ul>
      </div>

      <%= if @multi_session_allowed? do %>
        <input type="checkbox" id="pk-add-account-modal" class="modal-toggle" />
        <div class="modal" role="dialog">
          <div class="modal-box">
            <h3 class="text-lg font-bold mb-4">Add account</h3>
            <.form
              for={%{}}
              action={Routes.locale_aware_path(assigns, "/users/session/accounts")}
              method="post"
              class="space-y-4"
            >
              <input type="hidden" name="return_to" value={@current_path} />
              <div class="fieldset">
                <label class="label"><span class="fieldset-legend">Email or username</span></label>
                <input
                  name="user[email_or_username]"
                  type="text"
                  required
                  class="input w-full"
                />
              </div>
              <div class="fieldset">
                <label class="label"><span class="fieldset-legend">Password</span></label>
                <input
                  name="user[password]"
                  type="password"
                  required
                  class="input w-full"
                />
              </div>
              <div class="modal-action">
                <label for="pk-add-account-modal" class="btn btn-outline">Cancel</label>
                <button type="submit" class="btn btn-primary">Add account</button>
              </div>
            </.form>
            <.add_account_oauth_buttons current_path={@current_path} />
          </div>
          <label class="modal-backdrop" for="pk-add-account-modal">Close</label>
        </div>
      <% end %>
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
            <.current_role_badge scope={@scope} />
          </div>
        </div>

        <div class="flex gap-1">
          <.link
            href={Routes.locale_aware_user_settings_path(assigns)}
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

  # True when at least one account row can show its remove button. Drives the
  # fixed-width trailing slot on EVERY row: without it the rows that carry a
  # remove button would squeeze their email column narrower than the rows that
  # do not, and the list would step in and out down its right edge.
  defp any_removable_account?(accounts) do
    Enum.any?(accounts, &(not &1.active? and not &1.root?))
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
    # Matching is about the PATH. Strip the query AND the fragment — a
    # module that publishes its full URL into `:url_path` (so the language
    # switcher can preserve state) hands this a path with either attached,
    # and `Tab.normalize_path/1` strips both (2026-08-31).
    [path_part | _] = String.split(path, ["?", "#"], parts: 2)

    # Get dynamic prefix and normalize paths
    prefix = PhoenixKit.Config.get_url_prefix()
    # Canonical, because `canonical_admin_path/1` below has already put the
    # path back into canonical spelling.
    admin_prefix = if prefix == "/", do: "/admin", else: "#{prefix}/admin"

    base_path =
      path_part
      |> String.replace_prefix(prefix, "")
      |> strip_locale_segment()
      # Canonicalise first: on a host that renamed the admin area the incoming
      # path says `/backoffice/...`, and both strips below are written against
      # the canonical name.
      |> Routes.canonical_admin_path()
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
        |> String.split(["&", "#"])
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
    Regex.match?(~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/i, locale)
  end

  # Helper function to get languages for admin nav display
  # Uses the unified Languages module as the single source of truth. Only the
  # languages the site actually serves: with the module off there are none
  # (`get_display_languages/0` is the admin Languages page's preview list, not
  # something to offer a visitor).
  # The final `dedupe_names/1` call drops the country qualifier from
  # `:name` when only one dialect of a given base language is
  # configured (e.g. "German (Germany)" → "German") — same rule the
  # frontend dropdown applies; the helper lives in
  # `Core.LanguageSwitcher` so all menus share one implementation.
  defp get_admin_languages do
    if Code.ensure_loaded?(Languages) do
      Languages.get_enabled_languages()
      |> Enum.filter(&is_map/1)
      |> Enum.map(&enrich_language/1)
      |> Enum.reject(&is_nil/1)
      |> LanguageSwitcher.dedupe_names()
    else
      []
    end
  end

  defp enrich_language(lang) do
    code = if is_struct(lang), do: lang.code, else: lang[:code]

    if is_binary(code) do
      case Languages.get_predefined_language(code) do
        %{} = predefined -> predefined
        _ -> %{code: code, name: Map.get(lang, :name, code), flag: "🌐", native: ""}
      end
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

  # Badge naming the role of the account that is *currently active* — which,
  # after an account switch, is not the account that opened the stack.
  #
  # Shares `MultiSession.role_label/1` with the account list below it so the
  # two can never disagree. The header badge used to derive its own label from
  # `Scope.can_access_admin_area?/1`, but that gate is true for Owner, Admin
  # *or any single permission holder* — so a Client, who holds `client_portal`,
  # was labelled "Admin", and custom roles were flattened into the same bucket.
  attr :scope, :map, required: true

  defp current_role_badge(assigns) do
    system = Role.system_roles()

    # Read the names the scope already loaded rather than re-querying: this
    # renders on every admin page, twice. `cached_roles` is nil only for a
    # scope built without a user, which the caller has already excluded.
    label =
      case assigns.scope do
        %{cached_roles: [_ | _] = roles} -> MultiSession.role_label_from_roles(roles)
        _ -> system.user
      end

    variant =
      cond do
        label == system.owner -> "badge-error"
        label == system.admin -> "badge-warning"
        true -> "badge-ghost"
      end

    assigns = assigns |> assign(:label, label) |> assign(:variant, variant)

    ~H"""
    <div class={["badge badge-xs", @variant]}>{@label}</div>
    """
  end

  # OAuth buttons for the "Add account" modal.
  #
  # Uses the same provider availability checks as the main login page —
  # a provider button only appears when it is enabled in General Settings.
  # Each link targets /users/auth/:provider with add_account=1 so the OAuth
  # callback knows to append the result to the multi-session stack.
  attr :current_path, :string, default: "/"

  defp add_account_oauth_buttons(assigns) do
    google_enabled = OAuthAvailability.provider_enabled?(:google)
    github_enabled = OAuthAvailability.provider_enabled?(:github)
    facebook_enabled = OAuthAvailability.provider_enabled?(:facebook)

    any_enabled = google_enabled or github_enabled or facebook_enabled

    assigns =
      assigns
      |> assign(:google_enabled, google_enabled)
      |> assign(:github_enabled, github_enabled)
      |> assign(:facebook_enabled, facebook_enabled)
      |> assign(:any_enabled, any_enabled)

    ~H"""
    <%= if @any_enabled do %>
      <div class="mt-4">
        <div class="divider text-base-content/60 text-xs">Or add via</div>
        <div class="space-y-2">
          <%= if @google_enabled do %>
            <.link
              href={
                Routes.path("/users/auth/google", locale: :none) <>
                  "?add_account=1&return_to=#{URI.encode_www_form(@current_path)}"
              }
              class="btn btn-outline w-full flex items-center justify-center gap-2"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_google class="w-5 h-5" />
              <span>Add Google account</span>
            </.link>
          <% end %>
          <%= if @github_enabled do %>
            <.link
              href={
                Routes.path("/users/auth/github", locale: :none) <>
                  "?add_account=1&return_to=#{URI.encode_www_form(@current_path)}"
              }
              class="btn btn-outline w-full flex items-center justify-center gap-2"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_github class="w-5 h-5" />
              <span>Add GitHub account</span>
            </.link>
          <% end %>
          <%= if @facebook_enabled do %>
            <.link
              href={
                Routes.path("/users/auth/facebook", locale: :none) <>
                  "?add_account=1&return_to=#{URI.encode_www_form(@current_path)}"
              }
              class="btn btn-outline w-full flex items-center justify-center gap-2"
            >
              <PhoenixKitWeb.Components.Core.Icons.icon_facebook class="w-5 h-5" />
              <span>Add Facebook account</span>
            </.link>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end
end
