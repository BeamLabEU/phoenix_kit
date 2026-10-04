defmodule PhoenixKit.Dashboard.AdminTabs do
  @moduledoc """
  Default admin navigation tabs for PhoenixKit.

  Defines all admin sidebar navigation items as Tab structs.
  These are registered in the Dashboard Registry during initialization
  and can be customized by parent applications via config.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Dashboard.{Group, Tab}
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope

  # Sidebar position of the top-level tabs that feature modules register.
  #
  # The admin sidebar draws group by group (`:admin_main` 100, `:admin_modules`
  # 500, `:admin_system` 900) and only then by priority inside a group. Modules
  # used to pick their own numbers, and the result was the bottom of the
  # sidebar for the modules people work in every day (Catalogues and Projects at
  # 660, Document Creator and CRM at 650 — below Modules and AI), plus many
  # ties: 650 ×7, 645 ×4, 600 ×3, 640 ×3, 520 ×2, 660 ×2 in an app with every
  # module installed. Core owns the global order here:
  #
  #   * daily work joins `:admin_main` right after the dashboard and the host's
  #     own entries — Catalogues, Warehouse, Manufacturing, Projects, Document
  #     Creator, CRM; Staff sits next to Users;
  #   * every other module stays in `:admin_modules` near where it was, moved
  #     only as far as needed to give every tab a priority of its own (Emails
  #     moves from 510 to 600, between Publishing and Connections).
  #
  # A tab id not listed keeps the module's own values; a host overrides any
  # entry with `config :phoenix_kit, :admin_tab_order` (see Registry).
  @module_tab_order %{
    admin_catalogue: %{priority: 151, group: :admin_main},
    warehouse: %{priority: 153, group: :admin_main},
    manufacturing: %{priority: 154, group: :admin_main},
    admin_projects: %{priority: 155, group: :admin_main},
    admin_document_creator: %{priority: 156, group: :admin_main},
    admin_crm: %{priority: 157, group: :admin_main},
    admin_staff: %{priority: 210, group: :admin_main},
    admin_billing: %{priority: 520},
    admin_newsletters: %{priority: 525},
    admin_shop: %{priority: 530},
    admin_entities: %{priority: 540},
    admin_db: %{priority: 570},
    admin_posts: %{priority: 580},
    admin_comments: %{priority: 590},
    admin_publishing: %{priority: 595},
    admin_emails: %{priority: 600},
    admin_connections: %{priority: 602},
    admin_referrals: %{priority: 604},
    admin_customer_support: %{priority: 620},
    admin_ai: %{priority: 640},
    admin_sync: %{priority: 642},
    admin_notifications: %{priority: 645},
    admin_boards: %{priority: 646},
    admin_calendar: %{priority: 647},
    admin_inbox: %{priority: 648},
    admin_stats: %{priority: 649},
    admin_dashboards: %{priority: 650},
    admin_bookings: %{priority: 652},
    admin_phoenix_kit_og: %{priority: 654},
    admin_web_analytics: %{priority: 656},
    admin_locations: %{priority: 670}
  }

  # Builder helper to reduce repetition across admin subtab definitions.
  # All admin tabs share level: :admin; subtabs share parent and permission.
  defp admin_subtab(id, label, icon, path, priority, parent, permission, opts \\ []) do
    %Tab{
      id: id,
      label: label,
      icon: icon,
      path: path,
      priority: priority,
      level: :admin,
      permission: permission,
      parent: parent,
      match: Keyword.get(opts, :match, :prefix),
      gettext_backend: PhoenixKitWeb.Gettext
    }
  end

  @doc """
  Returns all default admin tabs.
  """
  @spec default_tabs() :: [Tab.t()]
  def default_tabs do
    core_tabs() ++ module_tabs() ++ settings_tabs()
  end

  @doc """
  Returns the default admin tab groups.
  """
  @spec default_groups() :: [Group.t()]
  def default_groups do
    [
      %Group{id: :admin_main, label: nil, priority: 100},
      %Group{id: :admin_modules, label: nil, priority: 500},
      %Group{id: :admin_system, label: nil, priority: 900}
    ]
  end

  @doc """
  Returns core admin tabs (always present, gated only by permission).
  """
  @spec core_tabs() :: [Tab.t()]
  def core_tabs do
    tabs = [
      # Dashboard
      %Tab{
        id: :admin_dashboard,
        label: gettext_noop("Dashboard"),
        icon: "hero-home",
        path: "",
        priority: 100,
        level: :admin,
        permission: "dashboard",
        match: :exact,
        group: :admin_main,
        gettext_backend: PhoenixKitWeb.Gettext
      },
      # Users parent
      %Tab{
        id: :admin_users,
        label: gettext_noop("Users"),
        icon: "hero-users",
        path: "users",
        priority: 200,
        level: :admin,
        permission: "users",
        match: :prefix,
        group: :admin_main,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        gettext_backend: PhoenixKitWeb.Gettext
      },
      # Users subtabs
      admin_subtab(
        :admin_users_manage,
        gettext_noop("Users"),
        "hero-users",
        "users",
        210,
        :admin_users,
        "users",
        # :exact only matched the list itself (/admin/users) — viewing or
        # editing a single user (/admin/users/view|edit/:id) fell through
        # to no subtab match, so the parent :admin_users tab (which DOES
        # prefix-match those routes) highlighted as a whole section
        # instead of this specific "Users" subtab staying lit. Match the
        # list + its own detail/edit/new routes, but not sibling subtabs
        # (roles, permissions, live_sessions, sessions) which have their
        # own path already covered by their own :prefix match.
        match: {:regex, ~r{^/admin/users(/(new|edit|view)(/.*)?)?$}}
      ),
      admin_subtab(
        :admin_users_live_sessions,
        gettext_noop("Live Sessions"),
        "hero-eye",
        "users/live_sessions",
        220,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_sessions,
        gettext_noop("Sessions"),
        "hero-computer-desktop",
        "users/sessions",
        230,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_roles,
        gettext_noop("Roles"),
        "hero-shield-check",
        "users/roles",
        240,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_permissions,
        gettext_noop("Permissions"),
        "hero-key",
        "users/permissions",
        250,
        :admin_users,
        "users"
      ),
      # Activity
      %Tab{
        id: :admin_activity,
        label: gettext_noop("Activity"),
        icon: "hero-bell-alert",
        path: "activity",
        priority: 250,
        level: :admin,
        permission: "dashboard",
        match: :prefix,
        group: :admin_main,
        gettext_backend: PhoenixKitWeb.Gettext
      },
      # Jobs: always on (it was a module with a toggle; background work now runs through it)
      %Tab{
        id: :admin_jobs,
        label: gettext_noop("Jobs"),
        icon: "hero-queue-list",
        path: "jobs",
        priority: 260,
        level: :admin,
        permission: "jobs",
        match: :prefix,
        group: :admin_main,
        gettext_backend: PhoenixKitWeb.Gettext
      },
      # Media
      %Tab{
        id: :admin_media,
        label: gettext_noop("Media"),
        icon: "hero-photo",
        path: "media",
        priority: 300,
        level: :admin,
        permission: "media",
        match: :prefix,
        group: :admin_main,
        gettext_backend: PhoenixKitWeb.Gettext
      },
      # The user's own storage libraries, while user libraries are on — unless they
      # hold `media`, where Media's switcher lists them.
      %Tab{
        id: :admin_libraries,
        label: gettext_noop("Libraries"),
        icon: "hero-rectangle-stack",
        path: "libraries",
        priority: 310,
        level: :admin,
        permission: "storage",
        match: :prefix,
        group: :admin_main,
        visible: &Libraries.show_libraries_entry?/1,
        gettext_backend: PhoenixKitWeb.Gettext
      }
    ]

    Enum.map(tabs, &Tab.resolve_path(&1, :admin))
  end

  @doc """
  Returns feature module admin tabs (collected from ModuleRegistry).
  """
  @spec module_tabs() :: [Tab.t()]
  def module_tabs do
    apply_module_tab_order(ModuleRegistry.all_admin_tabs()) ++
      [
        # Modules management page (core admin, not a feature module)
        Tab.resolve_path(
          %Tab{
            id: :admin_modules_page,
            label: gettext_noop("Modules"),
            icon: "hero-puzzle-piece",
            path: "modules",
            priority: 630,
            level: :admin,
            permission: "modules",
            match: :exact,
            group: :admin_modules,
            gettext_backend: PhoenixKitWeb.Gettext
          },
          :admin
        )
      ]
  end

  @doc """
  Core's default sidebar position (`:priority`, and `:group` where it changes)
  for the top-level tabs of known feature modules, keyed by tab id.
  """
  @spec module_tab_order() :: %{atom() => map()}
  def module_tab_order, do: @module_tab_order

  @doc """
  Applies `module_tab_order/0` to module tabs: a listed top-level tab takes
  core's priority (and group, where given); subtabs and unlisted tabs are
  returned unchanged.

  Public so the ordering can be tested as the pure function it is — this is
  the exact step `module_tabs/0` applies to `ModuleRegistry.all_admin_tabs/0`.
  """
  @spec apply_module_tab_order([Tab.t()]) :: [Tab.t()]
  def apply_module_tab_order(tabs) do
    Enum.map(tabs, fn
      %Tab{parent: nil, id: id} = tab ->
        case Map.fetch(@module_tab_order, id) do
          {:ok, attrs} -> struct(tab, attrs)
          :error -> tab
        end

      tab ->
        tab
    end)
  end

  @doc """
  Returns settings admin tabs.

  Core settings (General, Organization, Users, Media) are hardcoded here.
  Feature module settings subtabs are collected from the ModuleRegistry.
  """
  @spec settings_tabs() :: [Tab.t()]
  def settings_tabs do
    core_settings_tabs() ++ ModuleRegistry.all_settings_tabs()
  end

  defp core_settings_tabs do
    # Settings parent lives in admin context (it's a top-level sidebar item)
    settings_parent =
      Tab.resolve_path(
        %Tab{
          id: :admin_settings,
          label: gettext_noop("Settings"),
          icon: "hero-cog-6-tooth",
          path: "settings",
          priority: 910,
          level: :admin,
          match: :exact,
          group: :admin_system,
          subtab_display: :when_active,
          redirect_to_first_subtab: true,
          highlight_with_subtabs: false,
          visible: &__MODULE__.settings_visible?/1,
          gettext_backend: PhoenixKitWeb.Gettext
        },
        :admin
      )

    # Settings subtabs live in settings context (paths under /admin/settings/)
    subtabs = [
      admin_subtab(
        :admin_settings_general,
        gettext_noop("General"),
        "hero-cog-6-tooth",
        "",
        911,
        :admin_settings,
        "settings",
        match: :exact
      ),
      admin_subtab(
        :admin_settings_authorization,
        gettext_noop("Authorization"),
        "hero-lock-closed",
        "authorization",
        912,
        :admin_settings,
        "settings"
      ),
      admin_subtab(
        :admin_settings_organization,
        gettext_noop("Organization"),
        "hero-building-office",
        "organization",
        913,
        :admin_settings,
        "settings"
      ),
      admin_subtab(
        :admin_settings_users,
        gettext_noop("Users"),
        "hero-users",
        "users",
        914,
        :admin_settings,
        "settings"
      ),
      admin_subtab(
        :admin_settings_website_access,
        gettext_noop("Website access"),
        "hero-shield-check",
        "website-access",
        915,
        :admin_settings,
        "settings"
      ),
      admin_subtab(
        :admin_settings_email_sending,
        gettext_noop("Emails Transactional"),
        "hero-envelope",
        "email-sending",
        916,
        :admin_settings,
        "settings"
      ),
      admin_subtab(
        :admin_settings_emails_bulk,
        gettext_noop("Emails Bulk"),
        "hero-adjustments-horizontal",
        "emails-bulk",
        917,
        :admin_settings,
        "settings"
      ),
      # Personal "My Integrations" used to live here too, grouped under a
      # shared "Integrations" parent with this one — moved to the profile
      # settings page (2026-09) since it is per-user data, not a site-wide
      # setting; nesting it under Settings put it three levels deep and made
      # every visitor with only the personal `integrations` key see the
      # whole Settings section appear in their sidebar. Now a plain flat
      # subtab like its siblings, gated on `integrations_system` alone.
      admin_subtab(
        :admin_settings_integrations,
        gettext_noop("Integrations"),
        "hero-globe-alt",
        "integrations",
        920,
        :admin_settings,
        "integrations_system"
      ),
      # Languages: always on (it was a module with a toggle). The multi-language
      # switch lives on this page, so the page has to be reachable while it is off.
      admin_subtab(
        :admin_settings_languages,
        gettext_noop("Languages"),
        "hero-language",
        "languages",
        928,
        :admin_settings,
        "languages"
      ),
      %Tab{
        id: :admin_settings_media,
        label: gettext_noop("Media"),
        icon: "hero-photo",
        path: "media",
        priority: 933,
        level: :admin,
        permission: "media.manage",
        match: :prefix,
        parent: :admin_settings,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        gettext_backend: PhoenixKitWeb.Gettext
      },
      admin_subtab(
        :admin_settings_media_dimensions,
        gettext_noop("Dimensions"),
        "hero-arrows-pointing-out",
        "media/dimensions",
        934,
        :admin_settings_media,
        "media.manage"
      ),
      admin_subtab(
        :admin_settings_media_health,
        gettext_noop("Health"),
        "hero-heart",
        "media/health",
        935,
        :admin_settings_media,
        "media.manage"
      )
    ]

    [settings_parent | Enum.map(subtabs, &Tab.resolve_path(&1, :settings))]
  end

  @doc """
  Visibility function for the Settings parent tab.
  Returns true if user has "settings" permission or any sub-module permission.
  """
  @spec settings_visible?(map()) :: boolean()
  def settings_visible?(scope) do
    # Settings visible if user has core "settings" permission, "media.manage",
    # the website-wide integrations key (the Website Integrations subtab),
    # or any module permission that provides settings tabs. The personal
    # `integrations` key does NOT belong here — "My Integrations" lives on
    # the profile settings page now, not under site-wide Settings.
    Scope.has_module_access?(scope, "settings") or
      Scope.has_module_access?(scope, "media.manage") or
      integrations_visible?(scope) or
      Enum.any?(settings_tab_permissions(), &Scope.has_module_access?(scope, &1))
  rescue
    error ->
      Logger.warning("[AdminTabs] settings_visible?/1 failed: #{Exception.message(error)}")
      false
  end

  @doc """
  Whether the Website Integrations subtab is visible — the user holds the
  website-wide `integrations_system` key. The personal `integrations` key
  no longer factors in here; that UI moved to the profile settings page.
  """
  @spec integrations_visible?(map()) :: boolean()
  def integrations_visible?(scope) do
    Scope.has_module_access?(scope, "integrations_system")
  rescue
    error ->
      Logger.warning("[AdminTabs] integrations_visible?/1 failed: #{Exception.message(error)}")
      false
  end

  # Returns permission keys from modules that actually provide settings tabs
  defp settings_tab_permissions do
    ModuleRegistry.all_settings_tabs()
    |> Enum.map(& &1.permission)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end
end
