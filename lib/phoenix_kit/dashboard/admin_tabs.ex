defmodule PhoenixKit.Dashboard.AdminTabs do
  @moduledoc """
  Default admin navigation tabs for PhoenixKit.

  Defines all admin sidebar navigation items as Tab structs.
  These are registered in the Dashboard Registry during initialization
  and can be customized by parent applications via config.
  """

  require Logger

  alias PhoenixKit.Dashboard.{Group, Registry, Tab}
  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope

  # ETS cache TTL for entity summaries (30 seconds)
  @entities_cache_ttl_ms 30_000
  @entities_cache_key :entities_children_cache

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
      admin_subtab(
        :admin_users_manage,
        "Manage Users",
        "hero-users",
        "/admin/users",
        210,
        :admin_users,
        "users",
        match: :exact
      ),
      admin_subtab(
        :admin_users_live_sessions,
        "Live Sessions",
        "hero-eye",
        "/admin/users/live_sessions",
        220,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_sessions,
        "Sessions",
        "hero-computer-desktop",
        "/admin/users/sessions",
        230,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_roles,
        "Roles",
        "hero-shield-check",
        "/admin/users/roles",
        240,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_permissions,
        "Permissions",
        "hero-key",
        "/admin/users/permissions",
        250,
        :admin_users,
        "users"
      ),
      admin_subtab(
        :admin_users_referral_codes,
        "Referral Codes",
        "hero-ticket",
        "/admin/users/referral-codes",
        260,
        :admin_users,
        "referrals"
      ),
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
      admin_subtab(
        :admin_emails_dashboard,
        "Dashboard",
        "hero-chart-bar-square",
        "/admin/emails/dashboard",
        511,
        :admin_emails,
        "emails"
      ),
      admin_subtab(
        :admin_emails_list,
        "Emails",
        "hero-inbox-stack",
        "/admin/emails",
        512,
        :admin_emails,
        "emails",
        match: :exact
      ),
      admin_subtab(
        :admin_emails_templates,
        "Templates",
        "hero-document-duplicate",
        "/admin/emails/templates",
        513,
        :admin_emails,
        "emails"
      ),
      admin_subtab(
        :admin_emails_queue,
        "Queue",
        "hero-queue-list",
        "/admin/emails/queue",
        514,
        :admin_emails,
        "emails"
      ),
      admin_subtab(
        :admin_emails_blocklist,
        "Blocklist",
        "hero-no-symbol",
        "/admin/emails/blocklist",
        515,
        :admin_emails,
        "emails"
      ),
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
      admin_subtab(
        :admin_billing_dashboard,
        "Dashboard",
        "hero-chart-bar-square",
        "/admin/billing",
        521,
        :admin_billing,
        "billing",
        match: :exact
      ),
      admin_subtab(
        :admin_billing_orders,
        "Orders",
        "hero-shopping-bag",
        "/admin/billing/orders",
        522,
        :admin_billing,
        "billing"
      ),
      admin_subtab(
        :admin_billing_invoices,
        "Invoices",
        "hero-document-text",
        "/admin/billing/invoices",
        523,
        :admin_billing,
        "billing"
      ),
      admin_subtab(
        :admin_billing_transactions,
        "Transactions",
        "hero-arrows-right-left",
        "/admin/billing/transactions",
        524,
        :admin_billing,
        "billing"
      ),
      admin_subtab(
        :admin_billing_subscriptions,
        "Subscriptions",
        "hero-arrow-path",
        "/admin/billing/subscriptions",
        525,
        :admin_billing,
        "billing"
      ),
      admin_subtab(
        :admin_billing_plans,
        "Plans",
        "hero-rectangle-stack",
        "/admin/billing/plans",
        526,
        :admin_billing,
        "billing"
      ),
      admin_subtab(
        :admin_billing_profiles,
        "Billing Profiles",
        "hero-identification",
        "/admin/billing/profiles",
        527,
        :admin_billing,
        "billing"
      ),
      admin_subtab(
        :admin_billing_currencies,
        "Currencies",
        "hero-currency-dollar",
        "/admin/billing/currencies",
        528,
        :admin_billing,
        "billing"
      ),
      admin_subtab(
        :admin_billing_providers,
        "Payment Providers",
        "hero-credit-card",
        "/admin/settings/billing/providers",
        529,
        :admin_billing,
        "billing"
      ),
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
      admin_subtab(
        :admin_shop_dashboard,
        "Dashboard",
        "hero-home",
        "/admin/shop",
        531,
        :admin_shop,
        "shop",
        match: :exact
      ),
      admin_subtab(
        :admin_shop_products,
        "Products",
        "hero-cube",
        "/admin/shop/products",
        532,
        :admin_shop,
        "shop"
      ),
      admin_subtab(
        :admin_shop_categories,
        "Categories",
        "hero-folder",
        "/admin/shop/categories",
        533,
        :admin_shop,
        "shop"
      ),
      admin_subtab(
        :admin_shop_shipping,
        "Shipping",
        "hero-truck",
        "/admin/shop/shipping",
        534,
        :admin_shop,
        "shop"
      ),
      admin_subtab(
        :admin_shop_carts,
        "Carts",
        "hero-shopping-cart",
        "/admin/shop/carts",
        535,
        :admin_shop,
        "shop"
      ),
      admin_subtab(
        :admin_shop_imports,
        "CSV Import",
        "hero-cloud-arrow-up",
        "/admin/shop/imports",
        536,
        :admin_shop,
        "shop"
      ),
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
      admin_subtab(
        :admin_ai_endpoints,
        "Endpoints",
        "hero-server-stack",
        "/admin/ai/endpoints",
        551,
        :admin_ai,
        "ai"
      ),
      admin_subtab(
        :admin_ai_prompts,
        "Prompts",
        "hero-document-text",
        "/admin/ai/prompts",
        552,
        :admin_ai,
        "ai"
      ),
      admin_subtab(
        :admin_ai_usage,
        "Usage",
        "hero-chart-bar",
        "/admin/ai/usage",
        553,
        :admin_ai,
        "ai"
      ),
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
      admin_subtab(
        :admin_sync_overview,
        "Overview",
        "hero-home",
        "/admin/sync",
        561,
        :admin_sync,
        "sync",
        match: :exact
      ),
      admin_subtab(
        :admin_sync_connections,
        "Connections",
        "hero-link",
        "/admin/sync/connections",
        562,
        :admin_sync,
        "sync"
      ),
      admin_subtab(
        :admin_sync_history,
        "History",
        "hero-clock",
        "/admin/sync/history",
        563,
        :admin_sync,
        "sync"
      ),
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
      admin_subtab(
        :admin_posts_all,
        "All Posts",
        "hero-newspaper",
        "/admin/posts",
        581,
        :admin_posts,
        "posts",
        match: :exact
      ),
      admin_subtab(
        :admin_posts_groups,
        "Groups",
        "hero-folder",
        "/admin/posts/groups",
        582,
        :admin_posts,
        "posts"
      ),
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
      admin_subtab(
        :admin_settings_general,
        "General",
        "hero-cog-6-tooth",
        "/admin/settings",
        911,
        :admin_settings,
        "settings",
        match: :exact
      ),
      admin_subtab(
        :admin_settings_organization,
        "Organization",
        "hero-building-office",
        "/admin/settings/organization",
        912,
        :admin_settings,
        "settings"
      ),
      admin_subtab(
        :admin_settings_users,
        "Users",
        "hero-users",
        "/admin/settings/users",
        913,
        :admin_settings,
        "settings"
      ),
      # Settings subtabs — feature module settings
      admin_subtab(
        :admin_settings_referrals,
        "Referrals",
        "hero-ticket",
        "/admin/settings/referral-codes",
        920,
        :admin_settings,
        "referrals"
      ),
      admin_subtab(
        :admin_settings_publishing,
        "Publishing",
        "hero-document-text",
        "/admin/settings/publishing",
        921,
        :admin_settings,
        "publishing"
      ),
      admin_subtab(
        :admin_settings_posts,
        "Posts",
        "hero-newspaper",
        "/admin/settings/posts",
        922,
        :admin_settings,
        "posts"
      ),
      admin_subtab(
        :admin_settings_tickets,
        "Tickets",
        "hero-ticket",
        "/admin/settings/tickets",
        923,
        :admin_settings,
        "tickets"
      ),
      admin_subtab(
        :admin_settings_comments,
        "Comments",
        "hero-chat-bubble-left-right",
        "/admin/settings/comments",
        924,
        :admin_settings,
        "comments"
      ),
      admin_subtab(
        :admin_settings_emails,
        "Emails",
        "hero-envelope",
        "/admin/settings/emails",
        925,
        :admin_settings,
        "emails"
      ),
      admin_subtab(
        :admin_settings_billing,
        "Billing",
        "hero-banknotes",
        "/admin/settings/billing",
        926,
        :admin_settings,
        "billing",
        match: :exact
      ),
      admin_subtab(
        :admin_settings_shop,
        "E-Commerce",
        "hero-shopping-bag",
        "/admin/shop/settings",
        927,
        :admin_settings,
        "shop"
      ),
      admin_subtab(
        :admin_settings_languages,
        "Languages",
        "hero-language",
        "/admin/settings/languages",
        928,
        :admin_settings,
        "languages"
      ),
      admin_subtab(
        :admin_settings_legal,
        "Legal",
        "hero-scale",
        "/admin/settings/legal",
        929,
        :admin_settings,
        "legal"
      ),
      admin_subtab(
        :admin_settings_seo,
        "SEO",
        "hero-magnifying-glass-circle",
        "/admin/settings/seo",
        930,
        :admin_settings,
        "seo"
      ),
      admin_subtab(
        :admin_settings_sitemap,
        "Sitemap",
        "hero-map",
        "/admin/settings/sitemap",
        931,
        :admin_settings,
        "sitemap"
      ),
      admin_subtab(
        :admin_settings_maintenance,
        "Maintenance",
        "hero-wrench-screwdriver",
        "/admin/settings/maintenance",
        932,
        :admin_settings,
        "maintenance"
      ),
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
      admin_subtab(
        :admin_settings_media_dimensions,
        "Dimensions",
        "hero-arrows-pointing-out",
        "/admin/settings/media/dimensions",
        934,
        :admin_settings_media,
        "media"
      ),
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
  @spec settings_visible?(map()) :: boolean()
  def settings_visible?(scope) do
    Scope.has_module_access?(scope, "settings") or
      Enum.any?(
        @settings_submodule_keys,
        &Scope.has_module_access?(scope, &1)
      )
  rescue
    error ->
      Logger.warning("[AdminTabs] settings_visible?/1 failed: #{Exception.message(error)}")
      false
  end

  @doc """
  Dynamic children function for Entities.
  Returns a tab for each published entity.
  Uses a lightweight query (no preloads) since the sidebar only needs name/icon/status.
  """
  @spec entities_children(map()) :: [Tab.t()]
  def entities_children(_scope) do
    if Code.ensure_loaded?(Entities) and
         function_exported?(Entities, :list_entity_summaries, 0) do
      entities = cached_entity_summaries()

      entities
      |> Enum.with_index()
      |> Enum.map(fn {entity, idx} ->
        %Tab{
          id: sanitize_tab_id("admin_entity", entity.name),
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
    error ->
      Logger.warning("[AdminTabs] entities_children/1 failed: #{Exception.message(error)}")
      []
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
      slug = group["slug"] || ""
      name = group["name"] || slug

      %Tab{
        id: sanitize_tab_id("admin_publishing", slug),
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
    error ->
      Logger.warning("[AdminTabs] publishing_children/1 failed: #{Exception.message(error)}")
      []
  end

  @spec load_publishing_groups() :: [map()]
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
    error ->
      Logger.warning("[AdminTabs] load_publishing_groups/0 failed: #{Exception.message(error)}")
      []
  end

  @spec normalize_groups([map()]) :: [map()]
  defp normalize_groups(groups) do
    Enum.map(groups, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))
  end

  # --- Cache helpers ---

  @doc """
  Invalidates the cached entity summaries in ETS.
  Called by the Registry when entity lifecycle PubSub events are received.
  """
  @spec invalidate_entities_cache() :: :ok
  def invalidate_entities_cache do
    if Registry.initialized?() do
      :ets.delete(Registry.ets_table(), @entities_cache_key)
    end

    :ok
  end

  # Returns cached entity summaries from the Registry's ETS table, or fetches fresh.
  @spec cached_entity_summaries() :: [map()]
  defp cached_entity_summaries do
    if Registry.initialized?() do
      case :ets.lookup(Registry.ets_table(), @entities_cache_key) do
        [{@entities_cache_key, entities, timestamp}]
        when is_integer(timestamp) ->
          if System.monotonic_time(:millisecond) - timestamp < @entities_cache_ttl_ms do
            entities
          else
            fetch_and_cache_entities()
          end

        _ ->
          fetch_and_cache_entities()
      end
    else
      Entities.list_entity_summaries()
    end
  end

  @spec fetch_and_cache_entities() :: [map()]
  defp fetch_and_cache_entities do
    entities = Entities.list_entity_summaries()

    if Registry.initialized?() do
      :ets.insert(
        Registry.ets_table(),
        {@entities_cache_key, entities, System.monotonic_time(:millisecond)}
      )
    end

    entities
  end

  # Sanitizes a string for use as part of an atom tab ID.
  # Strips non-alphanumeric chars, truncates, and appends a hash for collision safety.
  @spec sanitize_tab_id(String.t(), term()) :: atom()
  defp sanitize_tab_id(prefix, name) when is_binary(name) do
    sanitized =
      name
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> String.slice(0, 50)

    hash = :erlang.phash2(name) |> Integer.to_string(16) |> String.downcase()
    :"#{prefix}_#{sanitized}_#{hash}"
  end

  defp sanitize_tab_id(prefix, name), do: sanitize_tab_id(prefix, to_string(name))
end
