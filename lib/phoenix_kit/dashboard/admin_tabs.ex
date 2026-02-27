defmodule PhoenixKit.Dashboard.AdminTabs do
  @moduledoc """
  Default admin navigation tabs for PhoenixKit.

  Defines all admin sidebar navigation items as Tab structs.
  These are registered in the Dashboard Registry during initialization
  and can be customized by parent applications via config.
  """

  require Logger

  alias PhoenixKit.Dashboard.{Group, Tab}
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Auth.Scope

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
      match: Keyword.get(opts, :match, :prefix)
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
        label: "Dashboard",
        icon: "hero-home",
        path: "",
        priority: 100,
        level: :admin,
        permission: "dashboard",
        match: :exact,
        group: :admin_main
      },
      # Users parent
      %Tab{
        id: :admin_users,
        label: "Users",
        icon: "hero-users",
        path: "users",
        priority: 200,
        level: :admin,
        permission: "users",
        match: :prefix,
        group: :admin_main,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      # Users subtabs
      admin_subtab(
        :admin_users_manage,
        "Manage Users",
        "hero-users",
        "users",
        210,
        :admin_users,
        "users",
        match: :exact
      ),
      admin_subtab(
        :admin_users_live_sessions,
        "Live Sessions",
        "hero-eye",
        "users/live_sessions",
        220,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_sessions,
        "Sessions",
        "hero-computer-desktop",
        "users/sessions",
        230,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_roles,
        "Roles",
        "hero-shield-check",
        "users/roles",
        240,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_permissions,
        "Permissions",
        "hero-key",
        "users/permissions",
        250,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_referral_codes,
        "Referral Codes",
        "hero-ticket",
        "users/referral-codes",
        260,
        :admin_users,
        "referrals"
      ),
      # Media
      %Tab{
        id: :admin_media,
        label: "Media",
        icon: "hero-photo",
        path: "media",
        priority: 300,
        level: :admin,
        permission: "media",
        match: :prefix,
        group: :admin_main
      }
    ]

    Enum.map(tabs, &Tab.resolve_path(&1, :admin))
  end

  @doc """
  Returns feature module admin tabs (collected from ModuleRegistry).
  """
  @spec module_tabs() :: [Tab.t()]
  def module_tabs do
    ModuleRegistry.all_admin_tabs() ++
      [
        # Modules management page (core admin, not a feature module)
        Tab.resolve_path(
          %Tab{
            id: :admin_modules_page,
            label: "Modules",
            icon: "hero-puzzle-piece",
            path: "modules",
            priority: 630,
            level: :admin,
            permission: "modules",
            match: :exact,
            group: :admin_modules
          },
          :admin
        )
      ]
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
          label: "Settings",
          icon: "hero-cog-6-tooth",
          path: "settings",
          priority: 910,
          level: :admin,
          match: :exact,
          group: :admin_system,
          subtab_display: :when_active,
          highlight_with_subtabs: false,
          visible: &__MODULE__.settings_visible?/1
        },
        :admin
      )

    # Settings subtabs live in settings context (paths under /admin/settings/)
    subtabs = [
      admin_subtab(
        :admin_settings_general,
        "General",
        "hero-cog-6-tooth",
        "",
        911,
        :admin_settings,
        "settings",
        match: :exact
      ),
      admin_subtab(
        :admin_settings_organization,
        "Organization",
        "hero-building-office",
        "organization",
        912,
        :admin_settings,
        "settings"
      ),
      admin_subtab(
        :admin_settings_users,
        "Users",
        "hero-users",
        "users",
        913,
        :admin_settings,
        "settings"
      ),
      %Tab{
        id: :admin_settings_media,
        label: "Media",
        icon: "hero-photo",
        path: "media",
        priority: 933,
        level: :admin,
        permission: "media",
        match: :prefix,
        parent: :admin_settings,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      admin_subtab(
        :admin_settings_media_dimensions,
        "Dimensions",
        "hero-arrows-pointing-out",
        "media/dimensions",
        934,
        :admin_settings_media,
        "media"
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
    # Settings visible if user has core "settings" permission
    # or any module permission that provides settings tabs
    Scope.has_module_access?(scope, "settings") or
      Scope.has_module_access?(scope, "media") or
      Enum.any?(settings_tab_permissions(), &Scope.has_module_access?(scope, &1))
  rescue
    error ->
      Logger.warning("[AdminTabs] settings_visible?/1 failed: #{Exception.message(error)}")
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
