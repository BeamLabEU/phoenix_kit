defmodule PhoenixKitWeb.Components.UserDashboardNav do
  @moduledoc """
  User dashboard navigation components for the PhoenixKit user dashboard.
  Provides navigation elements specifically for user dashboard pages.
  """

  use PhoenixKitWeb, :html

  alias PhoenixKit.Dashboard.Registry, as: TabRegistry
  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.AdminLabel

  # Guest dropdown link catalog. Each entry is
  # `{key, path, icon, label_fn, setting_gate_fn}`; `label_fn`/`gate_fn`
  # are zero-arity so gettext + settings are evaluated at render time
  # (per-request locale / live setting), not at compile time.
  @guest_link_catalog [
    {:login, "/users/log-in", "hero-arrow-right-on-rectangle"},
    {:register, "/users/register", "hero-user-plus"},
    {:reset, "/users/reset-password", "hero-key"},
    {:magic_link, "/users/magic-link", "hero-sparkles"}
  ]

  @doc """
  Renders the user widget for dashboard navigation.

  For authenticated visitors this is the avatar dropdown (email, the admin
  area, Settings, language switcher, log out). For anonymous visitors the
  same dropdown *shape* is rendered with a generic "not signed in" icon and
  guest-relevant links (log in, sign up, forgot password, magic link) plus
  the same language switcher — so a single widget covers both states and
  always offers a language switcher.

  ## One destination, two labels

  Every signed-in visitor gets exactly one entry leading to `/admin`, because
  `/admin` is the one page core declares unconditionally and admits EVERY
  authenticated visitor to (`PhoenixKitWeb.Users.Auth.landing_view?/1` exempts
  the index from the admin-area gate, and the page shows a permission-less
  visitor the welcome block and nothing else). An admin-area holder sees it as
  "Admin Panel" with a shield; everybody else sees "My Account" with a house.
  The two are mutually exclusive and share `admin_entry_label/1`.

  The URL is always built with `Routes.path("/admin")`, so a host running
  `config :phoenix_kit, admin_path: "/myaccount"` gets `/myaccount` here for
  free — `/admin` stays the canonical spelling in code.

  ## Attributes

    * `:scope` — current scope; `nil`/unauthenticated renders the guest dropdown.
    * `:current_path` — used for active-link highlighting and locale-switch URLs.
      Canonicalised before comparison, so a renamed admin segment still
      highlights.
    * `:current_locale` — the active locale. A full dialect (`"en-US"`) is
      accepted: every URL built here reduces it to the base code the router
      actually serves (`/en/…`), so passing `@current_locale` rather than
      `@current_locale_base` no longer emits a link that costs a redirect.
    * `:show_language_switcher` — include the in-menu language list (default `true`).
      Set `false` when the host renders a standalone switcher elsewhere to avoid
      a duplicate. Applies to both the signed-in and guest states.
    * `:guest_links` — which guest links may appear, e.g.
      `[:login, :register, :reset, :magic_link]` (default: all). Links are also
      gated by the `allow_registration` / `magic_link_login_enabled` settings, so
      this list can only narrow, never force-enable a disabled feature.
    * `:authenticated_links` — which authenticated-menu entries may appear, e.g.
      `[:admin, :dashboard, :settings, :user_menu_tabs, :logout]` (default: all). Same narrowing
      rule as `:guest_links` — `:admin` still requires `Scope.can_access_admin_area?/1` to be
      true, so listing it can't grant an entry a non-admin shouldn't see. Use
      this to hide entries a host app's own navigation already covers.

      `:dashboard` is the "My Account" half of the pair described above — the
      admin-area entry shown to a visitor `:admin` does not cover. It used to
      point at the deprecated user dashboard (`/dashboard`,
      `PhoenixKit.Install.Deprecations.user_dashboard_warning/0`), which a host
      can compile out with `user_dashboard_enabled: false` — leaving this menu
      offering a 404. The key name is kept so hosts passing an explicit list
      need no edit.

      `:user_menu_tabs` is every module tab registered with `user_menu:`
      (`PhoenixKit.Dashboard.Tab`) — billing's "My Orders", the shop's
      "My Cart" — listed after Settings; see `user_menu_tab_links/1`.
  """
  attr(:scope, :any, default: nil)
  attr(:current_path, :string, default: "")
  attr(:current_locale, :string, default: "en")
  attr(:admin_edit_url, :string, default: nil)
  attr(:admin_edit_label, :string, default: nil)
  attr(:show_language_switcher, :boolean, default: true)
  attr(:guest_links, :list, default: [:login, :register, :reset, :magic_link])

  attr(:authenticated_links, :list,
    default: [:admin, :dashboard, :settings, :user_menu_tabs, :logout]
  )

  def user_dropdown(assigns) do
    user = Scope.user(assigns.scope)
    multi_session_allowed? = assigns.scope && assigns.scope.multi_session_allowed?
    accounts = (assigns.scope && assigns.scope.multi_session_accounts) || []

    assigns =
      assigns
      |> assign(:user, user)
      |> assign(:multi_session_allowed?, multi_session_allowed?)
      |> assign(:accounts, accounts)

    ~H"""
    <%= if @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope) do %>
      <div class="dropdown dropdown-end">
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

        <ul
          tabindex="0"
          class="dropdown-content menu bg-base-100 rounded-box z-[60] w-64 p-2 shadow-xl border border-base-300 mt-3 max-h-[calc(100vh-5rem)] overflow-y-auto flex-nowrap"
        >
          <li class="menu-title px-4 py-2">
            <div class="flex flex-col gap-1">
              <span class="text-sm font-medium text-base-content truncate">
                {if PhoenixKit.Users.Auth.Scope.acting_user_uuid(@scope),
                  do: PhoenixKit.Users.Auth.Scope.session_display_name(@scope),
                  else: PhoenixKit.Users.Auth.Scope.user_email(@scope)}
              </span>
            </div>
          </li>

          <div class="divider my-0"></div>

          <%= if :admin in @authenticated_links && PhoenixKit.Users.Auth.Scope.can_access_admin_area?(@scope) do %>
            <li>
              <.link
                navigate={PhoenixKit.Utils.Routes.path("/admin")}
                class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/admin"), do: " bg-primary text-primary-content", else: "")}
              >
                <.icon name="hero-shield-check" class="w-4 h-4" />
                <span>{admin_entry_label(@scope)}</span>
              </.link>
            </li>
            <PhoenixKitWeb.Components.Core.AdminEditLink.admin_edit_link
              url={@admin_edit_url}
              label={@admin_edit_label}
              variant={:menu_item}
            />
          <% end %>

          <li :if={
            :dashboard in @authenticated_links and
              not PhoenixKit.Users.Auth.Scope.can_access_admin_area?(@scope)
          }>
            <.link
              navigate={PhoenixKit.Utils.Routes.path("/admin")}
              class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/admin"), do: " bg-primary text-primary-content", else: "")}
            >
              <.icon name="hero-home" class="w-4 h-4" />
              <span>{admin_entry_label(@scope)}</span>
            </.link>
          </li>

          <li :if={:settings in @authenticated_links}>
            <.link
              navigate={Routes.locale_aware_user_settings_path(assigns)}
              class={"flex items-center gap-3" <> if(active_path?(assigns[:current_path], "/profile/settings"), do: " bg-primary text-primary-content", else: "")}
            >
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
              <span>{gettext("Settings")}</span>
            </.link>
          </li>

          <.user_menu_tab_links
            :if={:user_menu_tabs in @authenticated_links}
            scope={@scope}
            current_path={@current_path}
            current_locale={@current_locale}
          />

          <.language_menu_section
            :if={@show_language_switcher}
            current_path={@current_path}
            current_locale={@current_locale}
          />

          <PhoenixKitWeb.Components.Core.OrganizationSwitcher.organization_switcher
            id="dashboard-organization-switcher"
            scope={@scope}
            current_path={@current_path}
            current_locale={assigns[:current_locale]}
          />
          <PhoenixKitWeb.Components.Core.RoleSwitcher.role_switcher
            id="dashboard-role-switcher-menu"
            scope={@scope}
            current_path={@current_path}
            current_locale={@current_locale}
          />

          <PhoenixKitWeb.Components.AccountMenu.accounts_section
            :if={@multi_session_allowed?}
            scope={@scope}
            accounts={@accounts}
            current_path={@current_path}
            current_locale={@current_locale}
            modal_id="pk-add-account-modal-dashboard"
          />

          <div class="divider my-0"></div>

          <li :if={:logout in @authenticated_links}>
            <.link
              navigate={Routes.path("/users/log-out")}
              method="delete"
              class="flex items-center gap-3 text-error hover:bg-error hover:text-error-content"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
              <span>{gettext("Log Out")}</span>
            </.link>
          </li>
          <li :if={
            :logout in @authenticated_links and @multi_session_allowed? and length(@accounts) > 1
          }>
            <.link
              navigate={Routes.path("/users/log-out") <> "?all=1"}
              method="delete"
              class="flex items-center gap-3 text-error hover:bg-error hover:text-error-content"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" />
              <span>{gettext("Log out from all accounts")}</span>
            </.link>
          </li>
        </ul>
      </div>

      <PhoenixKitWeb.Components.AccountMenu.add_account_modal
        :if={@multi_session_allowed?}
        id="pk-add-account-modal-dashboard"
        current_path={@current_path}
        current_locale={@current_locale}
      />
    <% else %>
      <.guest_dropdown
        current_path={@current_path}
        current_locale={@current_locale}
        guest_links={@guest_links}
        show_language_switcher={@show_language_switcher}
      />
    <% end %>
    """
  end

  # Guest counterpart to the authenticated avatar dropdown: same shape and
  # styling, a generic "not signed in" trigger icon, guest-relevant links,
  # and the shared language switcher.
  attr(:current_path, :string, required: true)
  attr(:current_locale, :string, required: true)
  attr(:guest_links, :list, required: true)
  attr(:show_language_switcher, :boolean, required: true)

  defp guest_dropdown(assigns) do
    assigns = assign(assigns, :links, visible_guest_links(assigns.guest_links))

    ~H"""
    <div class="dropdown dropdown-end">
      <div
        tabindex="0"
        role="button"
        class="cursor-pointer hover:opacity-80 transition-opacity"
        aria-label={gettext("Account menu")}
      >
        <%!--
          Rounded-rectangle placeholder matching the authenticated avatar shape
          (md = w-10 h-10, rounded-lg via its `!rounded-lg`), so the guest and
          signed-in triggers look consistent — a generic person silhouette
          signals "not signed in".
        --%>
        <div class="w-10 h-10 rounded-lg bg-base-300 flex items-center justify-center text-base-content/60">
          <.icon name="hero-user" class="w-6 h-6" />
        </div>
      </div>

      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-100 rounded-box z-[60] w-64 p-2 shadow-xl border border-base-300 mt-3 max-h-[calc(100vh-5rem)] overflow-y-auto flex-nowrap"
      >
        <li class="menu-title px-4 py-2">
          <span class="text-sm font-medium text-base-content">{gettext("Not signed in")}</span>
        </li>

        <div class="divider my-0"></div>

        <li :for={link <- @links}>
          <.link navigate={Routes.path(link.path)} class="flex items-center gap-3">
            <.icon name={link.icon} class="w-4 h-4" />
            <span>{link.label}</span>
          </.link>
        </li>

        <.language_menu_section
          :if={@show_language_switcher}
          current_path={@current_path}
          current_locale={@current_locale}
        />
      </ul>
    </div>
    """
  end

  # The language list, shared with the admin menu (`AccountMenu`). Plain
  # links: the guest menu is on the sign-in pages, which have no socket.
  attr(:current_path, :string, required: true)
  attr(:current_locale, :string, required: true)

  defp language_menu_section(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.AccountMenu.language_section
      languages={PhoenixKitWeb.Components.AccountMenu.languages(@current_locale)}
      current_path={@current_path}
      current_locale={@current_locale}
      switch={:link}
    />
    """
  end

  # Resolves which guest links to render: starts from the catalog, keeps
  # only keys the caller allowed, and applies the per-feature settings
  # gates (`allow_registration`, `magic_link_login_enabled`). Log in and
  # forgot-password are always available; the others are gated.
  defp visible_guest_links(allowed) do
    allow_registration? = Settings.get_boolean_setting("allow_registration", true)
    magic_link? = Settings.get_boolean_setting("magic_link_login_enabled", true)

    @guest_link_catalog
    |> Enum.filter(fn {key, _path, _icon} ->
      key in allowed and guest_link_enabled?(key, allow_registration?, magic_link?)
    end)
    |> Enum.map(fn {key, path, icon} ->
      %{key: key, path: path, icon: icon, label: guest_link_label(key)}
    end)
  end

  defp guest_link_enabled?(:register, allow_registration?, _magic?), do: allow_registration?
  defp guest_link_enabled?(:magic_link, _allow?, magic?), do: magic?
  defp guest_link_enabled?(_key, _allow?, _magic?), do: true

  defp guest_link_label(:login), do: gettext("Log in")
  defp guest_link_label(:register), do: gettext("Sign up")
  defp guest_link_label(:reset), do: gettext("Forgot password")
  defp guest_link_label(:magic_link), do: gettext("Magic link")

  # The label for the entry that leads to the admin area.
  #
  # ONE source for both call sites above, which are mutually exclusive: an
  # admin-area holder gets the `:admin` entry, everyone else gets the
  # `:dashboard` one, and both navigate to `Routes.path("/admin")`. The
  # wording is the only thing that differs, so it lives here rather than
  # being written out twice.
  #
  # Translated on both arms, not typed into an operator form, for the reason
  # `PhoenixKitWeb.Components.LayoutWrapper` gives for the "Admin Panel" chip:
  # these are common noun phrases, already translated in every shipped locale,
  # and a stored string would serve one language's wording to all of them.
  #
  # A DEVELOPER can rename the admin arm in `config.exs` — either by picking a
  # translated preset (`admin_panel_label: :workspace`) or, since renaming the
  # URL usually means renaming the thing, just by setting `admin_path:`, which
  # the label derives from. Both go through
  # `PhoenixKitWeb.Components.Core.AdminLabel`, the same resolver the header
  # chip uses, so the menu entry and the chip always say the same thing.
  #
  # Neither touches the "My Account" arm, which names the visitor's own
  # account rather than the admin area.
  defp admin_entry_label(scope) do
    if Scope.can_access_admin_area?(scope),
      do: AdminLabel.text(),
      else: gettext("My Account")
  end

  @doc """
  Renders the module tabs offered in the avatar dropdown — one `<li>` per tab
  `PhoenixKit.Dashboard.Registry.get_user_menu_tabs/1` returns for `scope`,
  in tab priority order. Meant to sit inside a dropdown `<ul class="menu">`;
  renders nothing when no tab opts in, so a dropdown can always include it.

  Both avatar dropdowns use it (this module's `user_dropdown/1` and
  `PhoenixKitWeb.Components.AdminNav.admin_user_dropdown/1`): with the user
  dashboard deprecated, the dropdown is the one place a signed-in visitor can
  reach their orders or cart from on every page.
  """
  attr(:scope, :any, default: nil)
  attr(:current_path, :string, default: "")
  attr(:current_locale, :string, default: "en")

  def user_menu_tab_links(assigns) do
    assigns = assign(assigns, :tabs, TabRegistry.get_user_menu_tabs(assigns.scope))

    ~H"""
    <li :for={tab <- @tabs}>
      <.link
        navigate={Routes.locale_aware_path(assigns, tab.path)}
        class={[
          "flex items-center gap-3",
          tab_active?(tab, @current_path) && "bg-primary text-primary-content"
        ]}
      >
        <.icon :if={tab.icon} name={tab.icon} class="w-4 h-4" />
        <span>{Tab.localized_label(tab)}</span>
      </.link>
    </li>
    """
  end

  # Same canonicalisation as active_path?/2, then the tab's own match rule —
  # a `:prefix` tab ("/cart") stays highlighted on its sub-pages.
  defp tab_active?(tab, current_path) when is_binary(current_path) do
    clean_path =
      current_path
      |> remove_phoenix_kit_prefix()
      |> remove_locale_prefix()
      |> Routes.canonical_admin_path()

    Tab.matches_path?(tab, clean_path)
  end

  defp tab_active?(_tab, _current_path), do: false

  # Check if current path matches the given path
  defp active_path?(current_path, path) when is_binary(current_path) and is_binary(path) do
    # Remove PhoenixKit prefix if present
    normalized_path = remove_phoenix_kit_prefix(current_path)
    # Remove locale prefix if present
    # Then fold the configured admin segment back to canonical `/admin`, so a
    # host running `admin_path: "/myaccount"` compares `/myaccount/...` against
    # the `/admin` written above rather than never matching (dead highlight).
    clean_path =
      normalized_path
      |> remove_locale_prefix()
      |> Routes.canonical_admin_path()

    # Check for exact match or ends with path
    clean_path == path or String.ends_with?(clean_path, path)
  end

  defp active_path?(_, _), do: false

  # Remove PhoenixKit prefix
  defp remove_phoenix_kit_prefix(path) do
    url_prefix = PhoenixKit.Config.get_url_prefix()

    if url_prefix == "/" do
      path
    else
      String.replace_prefix(path, url_prefix, "")
    end
  end

  # Remove locale prefix
  defp remove_locale_prefix(path) do
    case String.split(path, "/", parts: 3) do
      ["", locale, rest] when locale != "" and rest != "" ->
        if looks_like_locale?(locale), do: "/" <> rest, else: path

      ["", locale] ->
        if looks_like_locale?(locale), do: "/", else: path

      _ ->
        path
    end
  end

  # Check if it looks like a locale code
  defp looks_like_locale?(locale) do
    String.length(locale) <= 8 and String.match?(locale, ~r/^[a-z]{2,3}(-[A-Za-z]{2,4})?$/)
  end
end
