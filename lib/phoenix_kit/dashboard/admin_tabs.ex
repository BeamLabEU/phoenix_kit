defmodule PhoenixKit.Dashboard.AdminTabs do
  @moduledoc """
  Default admin navigation tabs for PhoenixKit.

  Defines all admin sidebar navigation items as Tab structs.
  These are registered in the Dashboard Registry during initialization
  and can be customized by parent applications via config.
  """

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope

  # Suppress warnings about optional modules (loaded conditionally)
  @compile {:no_warn_undefined, PhoenixKit.Modules.Tickets}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Billing}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Shop}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Emails}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Entities}
  @compile {:no_warn_undefined, PhoenixKit.Modules.AI}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Sync}
  @compile {:no_warn_undefined, PhoenixKit.Modules.DB}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Posts}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Comments}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Publishing}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Referrals}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Sitemap}
  @compile {:no_warn_undefined, PhoenixKit.Modules.SEO}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Maintenance}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Languages}
  @compile {:no_warn_undefined, PhoenixKit.Modules.Legal}
  @compile {:no_warn_undefined, PhoenixKit.Jobs}

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
  @spec default_groups() :: [map()]
  def default_groups do
    [
      %{id: :admin_main, label: nil, priority: 100},
      %{id: :admin_modules, label: nil, priority: 500},
      %{id: :admin_system, label: nil, priority: 900}
    ]
  end

  @doc """
  Returns core admin tabs (always present, gated only by permission).
  """
  @spec core_tabs() :: [Tab.t()]
  def core_tabs do
    [
      # Dashboard
      %Tab{
        id: :admin_dashboard,
        label: "Dashboard",
        icon: "hero-home",
        path: "/admin",
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
        path: "/admin/users",
        priority: 200,
        level: :admin,
        permission: "users",
        match: :prefix,
        group: :admin_main,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      # Users subtabs
      %Tab{
        id: :admin_users_manage,
        label: "Manage Users",
        icon: "hero-users",
        path: "/admin/users",
        priority: 210,
        level: :admin,
        permission: "users",
        match: :exact,
        parent: :admin_users
      },
      %Tab{
        id: :admin_users_live_sessions,
        label: "Live Sessions",
        icon: "hero-eye",
        path: "/admin/users/live_sessions",
        priority: 220,
        level: :admin,
        permission: "users",
        match: :prefix,
        parent: :admin_users
      },
      %Tab{
        id: :admin_users_sessions,
        label: "Sessions",
        icon: "hero-computer-desktop",
        path: "/admin/users/sessions",
        priority: 230,
        level: :admin,
        permission: "users",
        match: :prefix,
        parent: :admin_users
      },
      %Tab{
        id: :admin_users_roles,
        label: "Roles",
        icon: "hero-shield-check",
        path: "/admin/users/roles",
        priority: 240,
        level: :admin,
        permission: "users",
        match: :prefix,
        parent: :admin_users
      },
      %Tab{
        id: :admin_users_permissions,
        label: "Permissions",
        icon: "hero-key",
        path: "/admin/users/permissions",
        priority: 250,
        level: :admin,
        permission: "users",
        match: :prefix,
        parent: :admin_users
      },
      %Tab{
        id: :admin_users_referral_codes,
        label: "Referral Codes",
        icon: "hero-ticket",
        path: "/admin/users/referral-codes",
        priority: 260,
        level: :admin,
        permission: "referrals",
        match: :prefix,
        parent: :admin_users
      },
      # Media
      %Tab{
        id: :admin_media,
        label: "Media",
        icon: "hero-photo",
        path: "/admin/media",
        priority: 300,
        level: :admin,
        permission: "media",
        match: :prefix,
        group: :admin_main
      }
    ]
  end

  @doc """
  Returns feature module admin tabs (gated by module enabled + permission).
  """
  @spec module_tabs() :: [Tab.t()]
  def module_tabs do
    [
      # Emails parent
      %Tab{
        id: :admin_emails,
        label: "Emails",
        icon: "hero-envelope",
        path: "/admin/emails/dashboard",
        priority: 510,
        level: :admin,
        permission: "emails",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        subtab_indent: "pl-4"
      },
      %Tab{
        id: :admin_emails_dashboard,
        label: "Dashboard",
        icon: "hero-envelope",
        path: "/admin/emails/dashboard",
        priority: 511,
        level: :admin,
        permission: "emails",
        match: :prefix,
        parent: :admin_emails
      },
      %Tab{
        id: :admin_emails_list,
        label: "Emails",
        icon: "hero-envelope",
        path: "/admin/emails",
        priority: 512,
        level: :admin,
        permission: "emails",
        match: :exact,
        parent: :admin_emails
      },
      %Tab{
        id: :admin_emails_templates,
        label: "Templates",
        icon: "hero-envelope",
        path: "/admin/modules/emails/templates",
        priority: 513,
        level: :admin,
        permission: "emails",
        match: :prefix,
        parent: :admin_emails
      },
      %Tab{
        id: :admin_emails_queue,
        label: "Queue",
        icon: "hero-envelope",
        path: "/admin/emails/queue",
        priority: 514,
        level: :admin,
        permission: "emails",
        match: :prefix,
        parent: :admin_emails
      },
      %Tab{
        id: :admin_emails_blocklist,
        label: "Blocklist",
        icon: "hero-envelope",
        path: "/admin/emails/blocklist",
        priority: 515,
        level: :admin,
        permission: "emails",
        match: :prefix,
        parent: :admin_emails
      },
      # Billing parent
      %Tab{
        id: :admin_billing,
        label: "Billing",
        icon: "hero-banknotes",
        path: "/admin/billing",
        priority: 520,
        level: :admin,
        permission: "billing",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      %Tab{
        id: :admin_billing_dashboard,
        label: "Dashboard",
        icon: "hero-banknotes",
        path: "/admin/billing",
        priority: 521,
        level: :admin,
        permission: "billing",
        match: :exact,
        parent: :admin_billing
      },
      %Tab{
        id: :admin_billing_orders,
        label: "Orders",
        icon: "hero-banknotes",
        path: "/admin/billing/orders",
        priority: 522,
        level: :admin,
        permission: "billing",
        match: :prefix,
        parent: :admin_billing
      },
      %Tab{
        id: :admin_billing_invoices,
        label: "Invoices",
        icon: "hero-banknotes",
        path: "/admin/billing/invoices",
        priority: 523,
        level: :admin,
        permission: "billing",
        match: :prefix,
        parent: :admin_billing
      },
      %Tab{
        id: :admin_billing_transactions,
        label: "Transactions",
        icon: "hero-banknotes",
        path: "/admin/billing/transactions",
        priority: 524,
        level: :admin,
        permission: "billing",
        match: :prefix,
        parent: :admin_billing
      },
      %Tab{
        id: :admin_billing_subscriptions,
        label: "Subscriptions",
        icon: "hero-banknotes",
        path: "/admin/billing/subscriptions",
        priority: 525,
        level: :admin,
        permission: "billing",
        match: :prefix,
        parent: :admin_billing
      },
      %Tab{
        id: :admin_billing_plans,
        label: "Plans",
        icon: "hero-banknotes",
        path: "/admin/billing/plans",
        priority: 526,
        level: :admin,
        permission: "billing",
        match: :prefix,
        parent: :admin_billing
      },
      %Tab{
        id: :admin_billing_profiles,
        label: "Billing Profiles",
        icon: "hero-banknotes",
        path: "/admin/billing/profiles",
        priority: 527,
        level: :admin,
        permission: "billing",
        match: :prefix,
        parent: :admin_billing
      },
      %Tab{
        id: :admin_billing_currencies,
        label: "Currencies",
        icon: "hero-banknotes",
        path: "/admin/billing/currencies",
        priority: 528,
        level: :admin,
        permission: "billing",
        match: :prefix,
        parent: :admin_billing
      },
      %Tab{
        id: :admin_billing_providers,
        label: "Payment Providers",
        icon: "hero-banknotes",
        path: "/admin/settings/billing/providers",
        priority: 529,
        level: :admin,
        permission: "billing",
        match: :prefix,
        parent: :admin_billing
      },
      # Shop parent
      %Tab{
        id: :admin_shop,
        label: "E-Commerce",
        icon: "hero-shopping-bag",
        path: "/admin/shop",
        priority: 530,
        level: :admin,
        permission: "shop",
        match: :exact,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      %Tab{
        id: :admin_shop_dashboard,
        label: "Dashboard",
        icon: "hero-home",
        path: "/admin/shop",
        priority: 531,
        level: :admin,
        permission: "shop",
        match: :exact,
        parent: :admin_shop
      },
      %Tab{
        id: :admin_shop_products,
        label: "Products",
        icon: "hero-cube",
        path: "/admin/shop/products",
        priority: 532,
        level: :admin,
        permission: "shop",
        match: :prefix,
        parent: :admin_shop
      },
      %Tab{
        id: :admin_shop_categories,
        label: "Categories",
        icon: "hero-folder",
        path: "/admin/shop/categories",
        priority: 533,
        level: :admin,
        permission: "shop",
        match: :prefix,
        parent: :admin_shop
      },
      %Tab{
        id: :admin_shop_shipping,
        label: "Shipping",
        icon: "hero-truck",
        path: "/admin/shop/shipping",
        priority: 534,
        level: :admin,
        permission: "shop",
        match: :prefix,
        parent: :admin_shop
      },
      %Tab{
        id: :admin_shop_carts,
        label: "Carts",
        icon: "hero-shopping-cart",
        path: "/admin/shop/carts",
        priority: 535,
        level: :admin,
        permission: "shop",
        match: :prefix,
        parent: :admin_shop
      },
      %Tab{
        id: :admin_shop_imports,
        label: "CSV Import",
        icon: "hero-cloud-arrow-up",
        path: "/admin/shop/imports",
        priority: 536,
        level: :admin,
        permission: "shop",
        match: :prefix,
        parent: :admin_shop
      },
      # Entities (with dynamic children)
      %Tab{
        id: :admin_entities,
        label: "Entities",
        icon: "hero-cube",
        path: "/admin/entities",
        priority: 540,
        level: :admin,
        permission: "entities",
        match: :exact,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        dynamic_children: &__MODULE__.entities_children/1
      },
      # AI parent
      %Tab{
        id: :admin_ai,
        label: "AI",
        icon: "hero-cpu-chip",
        path: "/admin/ai",
        priority: 550,
        level: :admin,
        permission: "ai",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      %Tab{
        id: :admin_ai_endpoints,
        label: "Endpoints",
        icon: "hero-server-stack",
        path: "/admin/ai/endpoints",
        priority: 551,
        level: :admin,
        permission: "ai",
        match: :prefix,
        parent: :admin_ai
      },
      %Tab{
        id: :admin_ai_prompts,
        label: "Prompts",
        icon: "hero-document-text",
        path: "/admin/ai/prompts",
        priority: 552,
        level: :admin,
        permission: "ai",
        match: :prefix,
        parent: :admin_ai
      },
      %Tab{
        id: :admin_ai_usage,
        label: "Usage",
        icon: "hero-chart-bar",
        path: "/admin/ai/usage",
        priority: 553,
        level: :admin,
        permission: "ai",
        match: :prefix,
        parent: :admin_ai
      },
      # Sync parent
      %Tab{
        id: :admin_sync,
        label: "Sync",
        icon: "hero-arrows-right-left",
        path: "/admin/sync",
        priority: 560,
        level: :admin,
        permission: "sync",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      %Tab{
        id: :admin_sync_overview,
        label: "Overview",
        icon: "hero-home",
        path: "/admin/sync",
        priority: 561,
        level: :admin,
        permission: "sync",
        match: :exact,
        parent: :admin_sync
      },
      %Tab{
        id: :admin_sync_connections,
        label: "Connections",
        icon: "hero-link",
        path: "/admin/sync/connections",
        priority: 562,
        level: :admin,
        permission: "sync",
        match: :prefix,
        parent: :admin_sync
      },
      %Tab{
        id: :admin_sync_history,
        label: "History",
        icon: "hero-clock",
        path: "/admin/sync/history",
        priority: 563,
        level: :admin,
        permission: "sync",
        match: :prefix,
        parent: :admin_sync
      },
      # DB
      %Tab{
        id: :admin_db,
        label: "DB",
        icon: "hero-table-cells",
        path: "/admin/db",
        priority: 570,
        level: :admin,
        permission: "db",
        match: :exact,
        group: :admin_modules
      },
      # Posts parent
      %Tab{
        id: :admin_posts,
        label: "Posts",
        icon: "hero-document-text",
        path: "/admin/posts",
        priority: 580,
        level: :admin,
        permission: "posts",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      %Tab{
        id: :admin_posts_all,
        label: "All Posts",
        icon: "hero-document-text",
        path: "/admin/posts",
        priority: 581,
        level: :admin,
        permission: "posts",
        match: :exact,
        parent: :admin_posts
      },
      %Tab{
        id: :admin_posts_groups,
        label: "Groups",
        icon: "hero-folder",
        path: "/admin/posts/groups",
        priority: 582,
        level: :admin,
        permission: "posts",
        match: :prefix,
        parent: :admin_posts
      },
      # Comments
      %Tab{
        id: :admin_comments,
        label: "Comments",
        icon: "hero-chat-bubble-left-right",
        path: "/admin/comments",
        priority: 590,
        level: :admin,
        permission: "comments",
        match: :prefix,
        group: :admin_modules
      },
      # Publishing (with dynamic children)
      %Tab{
        id: :admin_publishing,
        label: "Publishing",
        icon: "hero-document-text",
        path: "/admin/publishing",
        priority: 600,
        level: :admin,
        permission: "publishing",
        match: :exact,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        dynamic_children: &__MODULE__.publishing_children/1
      },
      # Jobs
      %Tab{
        id: :admin_jobs,
        label: "Jobs",
        icon: "hero-queue-list",
        path: "/admin/jobs",
        priority: 610,
        level: :admin,
        permission: "jobs",
        match: :prefix,
        group: :admin_modules
      },
      # Tickets
      %Tab{
        id: :admin_tickets,
        label: "Tickets",
        icon: "hero-ticket",
        path: "/admin/tickets",
        priority: 620,
        level: :admin,
        permission: "tickets",
        match: :prefix,
        group: :admin_modules
      },
      # Modules
      %Tab{
        id: :admin_modules_page,
        label: "Modules",
        icon: "hero-puzzle-piece",
        path: "/admin/modules",
        priority: 630,
        level: :admin,
        permission: "modules",
        match: :exact,
        group: :admin_modules
      }
    ]
  end

  @doc """
  Returns settings admin tabs.
  """
  @spec settings_tabs() :: [Tab.t()]
  def settings_tabs do
    [
      # Settings parent (visible if user has settings or any sub-module permission)
      %Tab{
        id: :admin_settings,
        label: "Settings",
        icon: "hero-cog-6-tooth",
        path: "/admin/settings",
        priority: 910,
        level: :admin,
        match: :exact,
        group: :admin_system,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        visible: &__MODULE__.settings_visible?/1
      },
      # Settings subtabs — core settings
      %Tab{
        id: :admin_settings_general,
        label: "General",
        icon: "hero-cog-6-tooth",
        path: "/admin/settings",
        priority: 911,
        level: :admin,
        permission: "settings",
        match: :exact,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_organization,
        label: "Organization",
        icon: "hero-building-office",
        path: "/admin/settings/organization",
        priority: 912,
        level: :admin,
        permission: "settings",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_users,
        label: "Users",
        icon: "hero-users",
        path: "/admin/settings/users",
        priority: 913,
        level: :admin,
        permission: "settings",
        match: :prefix,
        parent: :admin_settings
      },
      # Settings subtabs — feature module settings
      %Tab{
        id: :admin_settings_referrals,
        label: "Referrals",
        icon: "hero-ticket",
        path: "/admin/settings/referral-codes",
        priority: 920,
        level: :admin,
        permission: "referrals",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_publishing,
        label: "Publishing",
        icon: "hero-document-text",
        path: "/admin/settings/publishing",
        priority: 921,
        level: :admin,
        permission: "publishing",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_posts,
        label: "Posts",
        icon: "hero-document-text",
        path: "/admin/settings/posts",
        priority: 922,
        level: :admin,
        permission: "posts",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_tickets,
        label: "Tickets",
        icon: "hero-ticket",
        path: "/admin/settings/tickets",
        priority: 923,
        level: :admin,
        permission: "tickets",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_comments,
        label: "Comments",
        icon: "hero-chat-bubble-left-right",
        path: "/admin/settings/comments",
        priority: 924,
        level: :admin,
        permission: "comments",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_emails,
        label: "Emails",
        icon: "hero-envelope",
        path: "/admin/settings/emails",
        priority: 925,
        level: :admin,
        permission: "emails",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_billing,
        label: "Billing",
        icon: "hero-banknotes",
        path: "/admin/settings/billing",
        priority: 926,
        level: :admin,
        permission: "billing",
        match: :exact,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_shop,
        label: "E-Commerce",
        icon: "hero-shopping-bag",
        path: "/admin/shop/settings",
        priority: 927,
        level: :admin,
        permission: "shop",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_languages,
        label: "Languages",
        icon: "hero-language",
        path: "/admin/settings/languages",
        priority: 928,
        level: :admin,
        permission: "languages",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_legal,
        label: "Legal",
        icon: "hero-scale",
        path: "/admin/settings/legal",
        priority: 929,
        level: :admin,
        permission: "legal",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_seo,
        label: "SEO",
        icon: "hero-magnifying-glass-circle",
        path: "/admin/settings/seo",
        priority: 930,
        level: :admin,
        permission: "seo",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_sitemap,
        label: "Sitemap",
        icon: "hero-map",
        path: "/admin/settings/sitemap",
        priority: 931,
        level: :admin,
        permission: "sitemap",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_maintenance,
        label: "Maintenance",
        icon: "hero-wrench-screwdriver",
        path: "/admin/settings/maintenance",
        priority: 932,
        level: :admin,
        permission: "maintenance",
        match: :prefix,
        parent: :admin_settings
      },
      %Tab{
        id: :admin_settings_media,
        label: "Media",
        icon: "hero-photo",
        path: "/admin/settings/media",
        priority: 933,
        level: :admin,
        permission: "media",
        match: :prefix,
        parent: :admin_settings,
        subtab_display: :when_active,
        highlight_with_subtabs: false
      },
      %Tab{
        id: :admin_settings_media_dimensions,
        label: "Dimensions",
        icon: "hero-photo",
        path: "/admin/settings/media/dimensions",
        priority: 934,
        level: :admin,
        permission: "media",
        match: :prefix,
        parent: :admin_settings_media
      },
      %Tab{
        id: :admin_settings_entities,
        label: "Entities",
        icon: "hero-cube",
        path: "/admin/settings/entities",
        priority: 935,
        level: :admin,
        permission: "entities",
        match: :prefix,
        parent: :admin_settings
      }
    ]
  end

  @doc """
  Visibility function for the Settings parent tab.
  Returns true if user has "settings" permission or any sub-module permission.
  """
  @settings_submodule_keys ~w(referrals publishing posts tickets comments emails billing shop languages legal seo sitemap maintenance media entities)
  def settings_visible?(scope) do
    Scope.has_module_access?(scope, "settings") or
      Enum.any?(
        @settings_submodule_keys,
        &Scope.has_module_access?(scope, &1)
      )
  rescue
    _ -> false
  end

  @doc """
  Dynamic children function for Entities.
  Returns a tab for each published entity.
  Uses a lightweight query (no preloads) since the sidebar only needs name/icon/status.
  """
  @spec entities_children(map()) :: [Tab.t()]
  def entities_children(_scope) do
    if Code.ensure_loaded?(Entities) and
         function_exported?(Entities, :list_entities, 0) do
      # Lightweight query: select only fields needed for sidebar tabs, no preloads
      import Ecto.Query, only: [from: 2]

      entities =
        from(e in Entities,
          where: e.status == "published",
          order_by: [desc: e.date_created],
          select: %{
            name: e.name,
            display_name: e.display_name,
            display_name_plural: e.display_name_plural,
            icon: e.icon
          }
        )
        |> PhoenixKit.RepoHelper.repo().all()

      entities
      |> Enum.with_index()
      |> Enum.map(fn {entity, idx} ->
        %Tab{
          id: :"admin_entity_#{entity.name}",
          label: entity.display_name_plural || entity.display_name,
          icon: entity.icon || "hero-cube",
          path: "/admin/entities/#{entity.name}/data",
          priority: 541 + idx,
          level: :admin,
          permission: "entities",
          match: :prefix,
          parent: :admin_entities
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Dynamic children function for Publishing.
  Returns a tab for each publishing group from settings.
  """
  @spec publishing_children(map()) :: [Tab.t()]
  def publishing_children(_scope) do
    groups = load_publishing_groups()

    groups
    |> Enum.with_index()
    |> Enum.map(fn {group, idx} ->
      slug = group["slug"] || group[:slug] || ""
      name = group["name"] || group[:name] || slug

      %Tab{
        id: :"admin_publishing_#{slug}",
        label: name,
        icon: "hero-document-text",
        path: "/admin/publishing/#{slug}",
        priority: 601 + idx,
        level: :admin,
        permission: "publishing",
        match: :prefix,
        parent: :admin_publishing
      }
    end)
  rescue
    _ -> []
  end

  defp load_publishing_groups do
    # Use cached settings check instead of Publishing.enabled?() which
    # calls get_setting (non-cached) and would add redundant DB queries.
    # Check both new and legacy keys to match Publishing.enabled?() behavior.
    publishing_enabled =
      Settings.get_boolean_setting("publishing_enabled", false) or
        Settings.get_boolean_setting("blogging_enabled", false)

    if publishing_enabled do
      json =
        Settings.get_json_setting_cached("publishing_groups", nil) ||
          Settings.get_json_setting_cached("blogging_blogs", nil)

      case json do
        %{"publishing_groups" => groups} when is_list(groups) -> normalize_groups(groups)
        %{"blogs" => blogs} when is_list(blogs) -> normalize_groups(blogs)
        list when is_list(list) -> normalize_groups(list)
        _ -> []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp normalize_groups(groups) do
    Enum.map(groups, fn group ->
      Enum.reduce(group, %{}, fn
        {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
        {key, value}, acc when is_atom(key) -> Map.put(acc, Atom.to_string(key), value)
        {key, value}, acc -> Map.put(acc, to_string(key), value)
      end)
    end)
  end
end
