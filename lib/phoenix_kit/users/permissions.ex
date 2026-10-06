defmodule PhoenixKit.Users.Permissions do
  @moduledoc """
  Context for module-level permissions in PhoenixKit.

  Controls which roles can access which admin sections and feature modules.
  Uses an allowlist model: row present = granted, absent = denied.
  Owner role always has full access (enforced in code, no DB rows needed).

  ## Permission Keys

  Core sections: dashboard, users, media, settings, modules
  Feature modules: billing, shop, emails, entities, tickets, posts, comments,
    ai, publishing, sitemap, crawlers, maintenance, storage,
    languages, connections, legal, db, jobs

  ## Sub-Permissions (fine-grained)

  A module may declare fine-grained permissions under its base key via the
  optional `sub_permissions` field of `permission_metadata/0`. They live in
  the same table as composed dotted keys (`"calendar.view_others"`):

  - The base key gates the module's admin pages; sub-keys are additive
    grants the module checks itself via `Scope.can?/2`.
  - A sub-key implies its base: granting a sub auto-grants the base,
    revoking the base cascades its subs, and `set_permissions/3` normalizes
    the desired set — no path can persist an orphan sub-key row.
  - A sub-key is enabled iff its parent module is enabled.

      Permissions.sub_permission_keys()          # ["calendar.edit_others", ...]
      Permissions.sub_permissions_for("calendar") # [%{key:, label:, description:}]
      Permissions.parent_key("calendar.view_others") # "calendar"
      Permissions.expand_with_parents(keys)      # keys ∪ implied base keys

  ## Constants & Metadata

      Permissions.all_module_keys()        # 25 built-in + any custom keys
      Permissions.core_section_keys()      # 7 core keys
      Permissions.feature_module_keys()    # 20 feature keys
      Permissions.enabled_module_keys()    # Core + enabled features + custom keys
      Permissions.valid_module_key?("ai")  # true
      Permissions.feature_enabled?("ai")   # true/false based on module status
      Permissions.module_label("shop")     # "E-Commerce"
      Permissions.module_icon("shop")      # "hero-shopping-cart"
      Permissions.module_description("shop") # "Product catalog, orders, ..."

  ## Query API

      Permissions.get_permissions_for_user(user)          # User's keys via roles
      Permissions.get_permissions_for_role(role_uuid)      # Keys for a role
      Permissions.role_has_permission?(role_uuid, "billing") # Single check
      Permissions.get_permissions_matrix()                 # All roles → MapSet
      Permissions.roles_with_permission("billing")         # Role UUIDs with key
      Permissions.users_with_permission("billing")         # User UUIDs with key
      Permissions.count_permissions_for_role(role_uuid)    # Efficient count
      Permissions.diff_permissions(role_a, role_b)        # Compare two roles

  ## Mutation API

      Permissions.grant_permission(role_uuid, "billing", granted_by_uuid)
      Permissions.revoke_permission(role_uuid, "billing")
      Permissions.set_permissions(role_uuid, ["dashboard", "users"], granted_by_uuid)
      Permissions.grant_all_permissions(role_uuid, granted_by_uuid)
      Permissions.revoke_all_permissions(role_uuid)
      Permissions.copy_permissions(source_role_uuid, target_role_uuid, granted_by_uuid)

  ## Custom Keys API

  Parent apps can register custom permission keys for custom admin tabs:

      Permissions.register_custom_key("analytics", label: "Analytics", icon: "hero-chart-bar")
      Permissions.unregister_custom_key("analytics")
      Permissions.custom_keys()              # List of registered custom key strings
      Permissions.custom_view_permissions()   # %{{ViewModule, action} | ViewModule => "key"}

  Custom keys are always treated as "enabled" (no module toggle) and appear
  in the permission matrix UI under a "Custom" group.

  ## Edit Protection

      Permissions.can_edit_role_permissions?(scope, role) :: :ok | {:error, atom()}

  Enforces: users cannot edit their own role, only Owner can edit Admin,
  system roles cannot have `is_system_role` changed. The error reason is a
  bare atom, not display text — pass it through
  `edit_role_permissions_error_message/1` before showing it to a user (e.g.
  in a flash).
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Admin.Events
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Queries, as: SettingsQueries
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.ScopeNotifier
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @core_section_keys ~w(dashboard users media settings modules jobs languages)

  # Sub-permissions of CORE sections. A feature module declares its own in
  # `permission_metadata/0`; a core section has no module, so they live here and
  # are merged into the registry's (`sub_permission_map/0`).
  #
  # `media.view_all` — Media shows the holder every file of the site's libraries.
  # Without it a holder of `media` sees only their own stuff
  # (`docs: dev_docs/plans/2026-09-30-media-by-viewer.md`).
  # `media.manage` — the storage administration screens (buckets, sizes, health)
  # and the site-wide actions in Media (empty the trash, delete every orphan).
  # Both are granted once to every role that held `media` before they existed
  # (`backfill_media_sub_permissions/0`), so an upgrade changes nothing.
  @core_sub_permissions %{
    "media" => [
      %{
        key: "media.view_all",
        label: "See everyone's files",
        description: "See the files other people uploaded to the site's libraries"
      },
      %{
        key: "media.manage",
        label: "Manage storage",
        description: "Buckets, sizes and health, and the site-wide trash and orphan actions"
      }
    ],
    # `jobs` is view: the Jobs page lists runs and their history. `jobs.manage`
    # starts, pauses, resumes, cancels and retries them. Unlike the media subs it
    # is NOT backfilled to the roles that hold `jobs`: the page was read-only, so
    # holding it never meant control, and granting control would add authority
    # (`dev_docs/plans/2026-10-03-job-runs.md`, §14 R3). Admin gets it at boot with
    # every new key; Owner has everything.
    "jobs" => [
      %{
        key: "jobs.manage",
        label: "Manage jobs",
        description: "Start, pause, resume, cancel and retry background jobs"
      }
    ]
  }
  @media_subs_flag "media_sub_permissions_backfilled"

  # Core-managed integration permission keys. TWO INDEPENDENT flat keys (not
  # dotted ⇒ no cascade / no sub-implies-base): `integrations` gates the
  # personal per-user page; `integrations_system` gates the website-wide page.
  # Each is independently grantable — an admin can hold the system page without
  # a personal page, and a user can hold personal without system.
  @integrations_personal_key "integrations"
  @integrations_system_key "integrations_system"
  @integration_keys [@integrations_personal_key, @integrations_system_key]

  # The wildcard "superadmin" permission key. Holding it grants access to EVERY
  # permission-gated surface — present and future — WITHOUT enumerating keys, so
  # it stays complete as modules are added/enabled (drift-immune, unlike a
  # grant-all role whose explicit rows go stale the moment a new module appears).
  # It is NOT a module and never gates a page directly; it is honored by
  # `Scope.has_module_access?/2` / `Scope.can?/2` as a blanket grant. Owner holds
  # it structurally (it is in `all_module_keys/0`); it is also independently
  # grantable in the matrix so a host can mint an Owner-equivalent custom role
  # with a single grant. Deliberately kept OUT of `enabled_module_keys/0` — see
  # `Scope.holds_all_enabled_permissions?/1` for why the subset check must not
  # require it. Not a valid `register_custom_key/2` target (fails the collision
  # guard AND the `[a-z]`-anchored pattern).
  @superadmin_key "*"

  # Keys that must NEVER be auto-granted to the Admin role — they are opt-in and
  # appear only when an Owner explicitly grants them. The personal `integrations`
  # page is the first: admins don't get a personal connections page they never
  # asked for. Enforced at the single `auto_grant_to_admin_roles/1` chokepoint so
  # BOTH the boot-time sweep (`auto_grant_new_keys_to_admin/0`) and the tab
  # registry (`Dashboard.Registry.auto_register_custom_permission/1`) honor it.
  @opt_in_admin_keys [@integrations_personal_key]

  # Persistent term keys for runtime-registered custom permission keys
  @custom_keys_pterm {PhoenixKit, :custom_permission_keys}
  @custom_views_pterm {PhoenixKit, :custom_view_permissions}
  @valid_key_pattern ~r/^[a-z][a-z0-9_]*$/
  @max_key_length 50
  @max_custom_keys 50
  @max_label_length 100
  @max_icon_length 60
  @max_description_length 255

  # Feature enabled checks are now resolved at runtime via ModuleRegistry.feature_enabled_checks/0

  # --- Custom Permission Keys ---

  @doc """
  Registers a custom permission key with metadata.

  Custom keys extend the built-in 25 permission keys, allowing parent apps
  to define new permission scopes for custom admin tabs. Custom keys are
  always treated as "enabled" (no module toggle) and appear in the
  permission matrix UI under "Custom".

  Raises `ArgumentError` if the key collides with a built-in key or has
  an invalid format. Logs a warning on duplicate override.

  ## Options

  - `:label` - Human-readable label (default: capitalized key)
  - `:icon` - Heroicon name (default: `"hero-squares-2x2"`)
  - `:description` - Short description (default: `""`)
  - `:gettext_backend` - Optional Gettext backend module; when set,
    `localized_module_label/1` translates the label with it (the label
    string is the msgid), mirroring `PhoenixKit.Dashboard.Tab`
  - `:gettext_domain` - Gettext domain for the label (default: `"default"`;
    only meaningful together with `:gettext_backend`)
  - `:auto_grant_admin` - Auto-grant this key to the Admin role on first
    registration (default: `true`). Set `false` for sensitive keys that should
    require an explicit Owner grant.

  ## Examples

      Permissions.register_custom_key("analytics", label: "Analytics", icon: "hero-chart-bar")

      Permissions.register_custom_key("analytics",
        label: "Analytics",
        gettext_backend: MyAppWeb.Gettext,
        gettext_domain: "admin"
      )
  """
  @spec register_custom_key(String.t(), keyword()) :: :ok
  def register_custom_key(key, opts \\ []) when is_binary(key) do
    if key == @superadmin_key or key in @core_section_keys or key in @integration_keys or
         key in ModuleRegistry.all_feature_keys() do
      raise ArgumentError,
            "Cannot register custom permission key #{inspect(key)}: conflicts with built-in key"
    end

    unless Regex.match?(@valid_key_pattern, key) do
      raise ArgumentError,
            "Invalid permission key #{inspect(key)}: must match ~r/^[a-z][a-z0-9_]*$/"
    end

    if String.length(key) > @max_key_length do
      raise ArgumentError,
            "Permission key #{inspect(key)} exceeds max length of #{@max_key_length}"
    end

    meta = %{
      label:
        opts
        |> Keyword.get(:label)
        |> coerce_string(String.capitalize(key))
        |> String.slice(0, @max_label_length),
      icon:
        opts
        |> Keyword.get(:icon)
        |> coerce_string("hero-squares-2x2")
        |> String.slice(0, @max_icon_length),
      description:
        opts
        |> Keyword.get(:description)
        |> coerce_string("")
        |> String.slice(0, @max_description_length),
      # Retained so the operator baseline can later exclude keys that were NOT
      # auto-granted to Admin (see `admin_baseline_exclusions/0`). Without
      # persisting it, an `auto_grant_admin: false` custom key would sit in the
      # baseline un-held by a default Admin and lock Admin out of unmapped views.
      auto_grant_admin: Keyword.get(opts, :auto_grant_admin, true) != false
    }

    meta =
      case validate_gettext_backend(Keyword.get(opts, :gettext_backend), key) do
        nil ->
          meta

        backend ->
          domain = opts |> Keyword.get(:gettext_domain) |> coerce_string("default")
          Map.merge(meta, %{gettext_backend: backend, gettext_domain: domain})
      end

    # Note: persistent_term has no CAS, so concurrent register_custom_key calls
    # could theoretically exceed the limit by 1-2 keys. This is acceptable since
    # registration only happens at app startup, not at runtime.
    # Re-registration of existing keys is always allowed (override).
    current = custom_keys_map()
    check_registration!(current, key, meta, opts)

    :persistent_term.put(@custom_keys_pterm, Map.put(current, key, meta))

    maybe_auto_grant_custom_key(key, opts)

    :ok
  end

  # A new key must fit under the cap; an existing one may be re-registered.
  defp check_registration!(current, key, meta, opts) do
    case Map.fetch(current, key) do
      {:ok, previous} ->
        warn_on_reregistration(key, previous, meta, opts)

      :error when map_size(current) >= @max_custom_keys ->
        raise ArgumentError,
              "Cannot register more than #{@max_custom_keys} custom permission keys"

      :error ->
        :ok
    end
  end

  # Re-registering a key replaces its metadata (the latest registration wins,
  # as it always has). Whether that deserves a warning depends on who is
  # registering:
  #
  #   * Admin tabs register the key they are gated on, one call per tab, and
  #     again on every registry reload. Several tabs sharing one permission is
  #     normal — each carries its own label and icon — so a warning per tab is
  #     noise: one app key produced eight of them per boot. The registry marks
  #     those calls `from_admin_tab: true` and they stay quiet…
  #   * …unless the tabs disagree on `auto_grant_admin`. That flag decides
  #     whether Admin holds the key by default, and "the last tab to load
  #     wins" is not a rule anyone should rely on for it, so that conflict is
  #     always reported.
  #   * A direct `register_custom_key/2` call re-registering a key is still
  #     worth knowing about, so it keeps its warning.
  defp warn_on_reregistration(key, previous, meta, opts) do
    auto_grant_conflict? =
      Map.get(previous, :auto_grant_admin, true) != Map.get(meta, :auto_grant_admin, true)

    cond do
      auto_grant_conflict? ->
        Logger.warning(
          "[Permissions] Custom permission key #{inspect(key)} registered with conflicting " <>
            "auto_grant_admin values (#{inspect(Map.get(previous, :auto_grant_admin, true))} " <>
            "then #{inspect(Map.get(meta, :auto_grant_admin, true))}); the latest registration " <>
            "wins, but every tab gated on this key should agree"
        )

      Keyword.get(opts, :from_admin_tab, false) ->
        :ok

      true ->
        Logger.warning(
          "[Permissions] Custom permission key #{inspect(key)} re-registered, overriding previous metadata"
        )
    end
  end

  # Auto-grant a newly-registered custom key to Admin so a host's custom admin
  # tab is visible to admins by default (matching built-in admin sections). Uses
  # a settings flag to avoid re-granting after an Owner explicitly revokes. A
  # host registering a SENSITIVE key can opt out with `auto_grant_admin: false`,
  # in which case the key surfaces only on an explicit Owner grant — like the
  # personal `integrations` key.
  defp maybe_auto_grant_custom_key(key, opts) do
    if Keyword.get(opts, :auto_grant_admin, true) do
      auto_grant_to_admin_roles(key)
    end

    :ok
  end

  @doc """
  Unregisters a custom permission key. Stale DB rows are harmless.
  """
  @spec unregister_custom_key(String.t()) :: :ok
  def unregister_custom_key(key) when is_binary(key) do
    current = custom_keys_map()
    :persistent_term.put(@custom_keys_pterm, Map.delete(current, key))

    # Clean up any view → permission mappings that reference this key
    views = :persistent_term.get(@custom_views_pterm, %{})

    cleaned =
      views
      |> Enum.reject(fn {_mod, perm} -> perm == key end)
      |> Map.new()

    if map_size(cleaned) != map_size(views) do
      :persistent_term.put(@custom_views_pterm, cleaned)
    end

    # Clear auto-grant flag so re-registering the key will auto-grant again
    clear_auto_grant_flag(key)

    :ok
  end

  @doc """
  Returns the map of registered custom permission keys and their metadata.
  """
  @spec custom_keys_map() :: %{String.t() => map()}
  def custom_keys_map do
    :persistent_term.get(@custom_keys_pterm, %{})
  end

  @doc """
  Returns the list of custom permission key strings.
  """
  @spec custom_keys() :: [String.t()]
  def custom_keys do
    custom_keys_map() |> Map.keys() |> Enum.sort()
  end

  @doc """
  Clears all custom permission keys. For test isolation.
  """
  @spec clear_custom_keys() :: :ok
  def clear_custom_keys do
    :persistent_term.put(@custom_keys_pterm, %{})
    :persistent_term.put(@custom_views_pterm, %{})
    :ok
  end

  @typedoc """
  Key under which a custom view's permission is cached: `{module, live_action}`
  for a tab that named an action, or a bare `module()` for one that did not
  (host tabs registered before per-action caching, or a module that never
  disambiguates by action).
  """
  @type view_permission_key :: {module(), atom()} | module()

  @doc """
  Caches a LiveView view → permission key mapping for custom admin tabs.

  `view` is either `{module, live_action}` — two tabs naming the same module
  on different actions cache independently — or a bare `module()` for a tab
  registered without an action. Used by the auth system to enforce
  permissions on custom admin LiveViews without reading Application config on
  every mount.
  """
  @spec cache_custom_view_permission(view_permission_key(), String.t()) :: :ok
  def cache_custom_view_permission({view_module, live_action}, permission_key)
      when is_atom(view_module) and is_atom(live_action) and is_binary(permission_key) do
    do_cache_custom_view_permission({view_module, live_action}, permission_key)
  end

  def cache_custom_view_permission(view_module, permission_key)
      when is_atom(view_module) and is_binary(permission_key) do
    do_cache_custom_view_permission(view_module, permission_key)
  end

  defp do_cache_custom_view_permission(view, permission_key) do
    current = :persistent_term.get(@custom_views_pterm, %{})

    case Map.get(current, view) do
      nil ->
        :ok

      ^permission_key ->
        :ok

      old_key ->
        Logger.warning(
          "[Permissions] View #{inspect(view)} permission changed from #{inspect(old_key)} to #{inspect(permission_key)}"
        )
    end

    :persistent_term.put(@custom_views_pterm, Map.put(current, view, permission_key))
    :ok
  end

  @doc """
  Returns the cached custom view → permission mapping.
  """
  @spec custom_view_permissions() :: %{view_permission_key() => String.t()}
  def custom_view_permissions do
    :persistent_term.get(@custom_views_pterm, %{})
  end

  # --- Sub-Permissions ---
  #
  # Modules declare fine-grained permissions under their base key via the
  # optional `sub_permissions` field of `permission_metadata/0`. They are
  # stored in the same phoenix_kit_role_permissions table as composed dotted
  # keys ("calendar.view_others"). The base key gates the module's admin
  # pages; sub-keys are additive grants the module checks itself via
  # `Scope.can?/2`. Base and sub parts each match ~r/^[a-z][a-z0-9_]*$/, so a
  # composed key contains exactly one dot — plain keys never contain dots.

  # The registry's sub-permissions plus the core sections' (`@core_sub_permissions`).
  defp sub_permission_map do
    Map.merge(ModuleRegistry.sub_permission_map(), @core_sub_permissions, fn _base,
                                                                             from_modules,
                                                                             core ->
      from_modules ++ core
    end)
  end

  @doc """
  Returns all composed sub-permission keys (`"calendar.view_others"`)
  declared by registered modules.
  """
  @spec sub_permission_keys() :: [String.t()]
  def sub_permission_keys do
    sub_permission_map()
    |> Enum.flat_map(fn {_base, subs} -> Enum.map(subs, & &1.key) end)
    |> Enum.sort()
  end

  @doc """
  Returns the sub-permission metadata declared under a base module key.
  Each entry is `%{key: composed_key, label: label, description: description}`.
  """
  @spec sub_permissions_for(String.t()) :: [map()]
  def sub_permissions_for(base_key) when is_binary(base_key) do
    sub_permission_map() |> Map.get(base_key, [])
  end

  @doc """
  Returns the base module key a composed sub-permission key belongs to, or
  `nil` when the key is not a registered sub-permission. Registry-driven —
  never inferred by string splitting.
  """
  @spec parent_key(String.t()) :: String.t() | nil
  def parent_key(key) when is_binary(key) do
    if String.contains?(key, ".") do
      sub_permission_map()
      |> Enum.find_value(fn {base, subs} ->
        if Enum.any?(subs, &(&1.key == key)), do: base
      end)
    end
  end

  def parent_key(_), do: nil

  @doc """
  Expands a set of permission keys with the base keys its sub-permissions
  imply (a sub-permission is meaningless without module access). Used by the
  grant paths to keep the "no orphan sub-key" invariant, and by the admin
  UIs to compute the full set a grant would create before authorizing it.
  """
  @spec expand_with_parents(Enumerable.t()) :: MapSet.t()
  def expand_with_parents(keys) do
    keys = MapSet.new(keys)

    parents =
      keys
      |> Enum.map(&parent_key/1)
      |> Enum.reject(&is_nil/1)

    MapSet.union(keys, MapSet.new(parents))
  end

  # --- Constants ---

  @doc "Returns all built-in, sub-permission, and custom permission keys as a list (including the `\"*\"` superadmin key). See `enabled_module_keys/0` for filtered MapSet variant."
  @spec all_module_keys() :: [String.t()]
  def all_module_keys,
    do:
      [@superadmin_key | @core_section_keys] ++
        @integration_keys ++ feature_module_keys() ++ sub_permission_keys() ++ custom_keys()

  @doc "The two independent integration permission keys (`integrations`, `integrations_system`)."
  @spec integration_keys() :: [String.t()]
  def integration_keys, do: @integration_keys

  @doc "The wildcard superadmin permission key (`\"*\"`). Holding it is a blanket grant honored by `Scope.has_module_access?/2` / `Scope.can?/2`."
  @spec superadmin_key() :: String.t()
  def superadmin_key, do: @superadmin_key

  @doc """
  Keys that are opt-in — never auto-granted to Admin, and excluded from the
  "operator baseline" that `Scope.holds_all_enabled_permissions?/1` compares
  against (so a default Admin, which never holds them, is still Owner-equivalent
  for admin-view access). Currently just the personal `integrations` page.
  """
  @spec opt_in_admin_keys() :: [String.t()]
  def opt_in_admin_keys, do: @opt_in_admin_keys

  @doc """
  Custom keys registered with `auto_grant_admin: false` — never auto-granted to
  Admin, so they must be excluded from the operator baseline too.
  """
  @spec opt_out_custom_keys() :: [String.t()]
  def opt_out_custom_keys do
    custom_keys_map()
    |> Enum.filter(fn {_key, meta} -> Map.get(meta, :auto_grant_admin, true) == false end)
    |> Enum.map(fn {key, _meta} -> key end)
  end

  @doc """
  Every enabled key that a default Admin is NOT auto-granted — the built-in
  opt-in keys PLUS any `auto_grant_admin: false` custom keys.
  `Scope.holds_all_enabled_permissions?/1` subtracts this from
  `enabled_module_keys/0` to form the "operator baseline": the set a default
  Admin genuinely holds, so a default Admin (and any grant-all role) stays
  Owner-equivalent for admin-view access no matter what opt-in/opt-out keys a
  host registers.
  """
  @spec admin_baseline_exclusions() :: [String.t()]
  def admin_baseline_exclusions, do: @opt_in_admin_keys ++ opt_out_custom_keys()

  @doc "Returns the core section permission keys."
  @spec core_section_keys() :: [String.t()]
  def core_section_keys, do: @core_section_keys

  @doc "Returns the feature module keys from the registry."
  @spec feature_module_keys() :: [String.t()]
  def feature_module_keys, do: ModuleRegistry.all_feature_keys()

  @doc """
  Returns module keys that are currently enabled (core sections + enabled feature modules + custom keys)
  as a `MapSet` for efficient membership checks. Core sections and custom keys are always included.
  Feature modules are included only if their module reports enabled status.

  Returns `MapSet.t()` unlike `all_module_keys/0` which returns a list — callers use this
  primarily for `MapSet.member?/2` and `MapSet.intersection/2` checks.
  """
  @spec enabled_module_keys() :: MapSet.t()
  def enabled_module_keys do
    enabled_features =
      feature_module_keys()
      |> Enum.filter(&do_feature_enabled?/1)

    sub_map = sub_permission_map()

    # Core sections are always on, so are their sub-permissions.
    enabled_subs =
      Enum.flat_map(enabled_features ++ @core_section_keys, fn base ->
        sub_map |> Map.get(base, []) |> Enum.map(& &1.key)
      end)

    MapSet.new(
      @core_section_keys ++ @integration_keys ++ enabled_features ++ enabled_subs ++ custom_keys()
    )
  end

  @doc "Checks whether `key` is a known permission key (built-in, sub-permission, or custom)."
  @spec valid_module_key?(String.t()) :: boolean()
  def valid_module_key?(key) when is_binary(key) do
    key == @superadmin_key or
      key in @core_section_keys or
      key in @integration_keys or
      key in ModuleRegistry.all_feature_keys() or
      not is_nil(parent_key(key)) or
      Map.has_key?(custom_keys_map(), key)
  end

  def valid_module_key?(_), do: false

  @doc """
  Checks whether a feature module is currently enabled.

  Core section keys always return `true`. Feature module keys return the
  result of calling the module's `enabled?/0` (or equivalent) function.
  Sub-permission keys are enabled iff their parent module is enabled.
  Custom permission keys are always enabled (no module toggle).
  Returns `false` for unknown keys.
  """
  @spec feature_enabled?(String.t()) :: boolean()
  # The superadmin key is not a module — it is always "effective".
  def feature_enabled?(@superadmin_key), do: true

  def feature_enabled?(key) when key in @core_section_keys, do: true

  # The integration keys are core-managed and always "enabled" (no module toggle).
  def feature_enabled?(key) when key in @integration_keys, do: true

  def feature_enabled?(key) when is_binary(key) do
    case Map.get(ModuleRegistry.feature_enabled_checks(), key) do
      {mod, fun} ->
        Code.ensure_loaded?(mod) && apply(mod, fun, [])

      nil ->
        case parent_key(key) do
          # Custom keys are always "enabled" (no module toggle)
          nil -> Map.has_key?(custom_keys_map(), key)
          parent -> feature_enabled?(parent)
        end
    end
  rescue
    _ -> false
  end

  # Core section metadata (always present, not from registry)
  @core_labels %{
    "dashboard" => "Dashboard",
    "users" => "Users",
    "media" => "Media",
    "settings" => "Settings",
    "modules" => "Modules",
    "jobs" => "Jobs",
    # Languages is core and always on: the page that holds the site's
    # multi-language switch must stay reachable while the switch is off.
    "languages" => "Languages",
    # `db` was extracted into `phoenix_kit_db` but core still
    # references the key (e.g. `auth.ex` `/admin/db` route).
    # `phoenix_kit_db` registers `"db" => "DB"` via its
    # `permission_metadata/0`, but only when the module is loaded
    # in the parent app. Core's own test environment doesn't load
    # external modules, so without this fallback `module_label("db")`
    # produces `String.capitalize("db")` = `"Db"`. Pin the canonical
    # label here so the display is correct regardless of whether
    # the external module is installed.
    "db" => "DB",
    "integrations" => "My Integrations",
    "integrations_system" => "System Integrations",
    "*" => "Full Access (Superadmin)"
  }

  @core_icons %{
    "dashboard" => "hero-home",
    "users" => "hero-users",
    "media" => "hero-photo",
    "settings" => "hero-cog-6-tooth",
    "modules" => "hero-squares-2x2",
    "jobs" => "hero-queue-list",
    "languages" => "hero-language",
    # Mirrors `phoenix_kit_db`'s registered icon. See `@core_labels`
    # above for the rationale.
    "db" => "hero-server-stack",
    "integrations" => "hero-link",
    "integrations_system" => "hero-link",
    "*" => "hero-key"
  }

  @core_descriptions %{
    "dashboard" => "Overview statistics, charts, and system health",
    "users" => "User accounts, roles, and access management",
    "media" => "File uploads, image processing, and storage buckets",
    "settings" => "General, organization, and user preference settings",
    "modules" => "Enable, disable, and configure feature modules",
    "jobs" => "Background jobs: what is running, its progress and history, and control over it",
    "languages" => "Multi-language support: the site's languages and locale routing",
    # Mirrors `phoenix_kit_db`'s registered description. See
    # `@core_labels` above for the rationale.
    "db" => "Database explorer and schema inspection",
    "integrations" => "Your own personal service connections (API keys, SMTP, etc.)",
    "integrations_system" => "Website-wide integration setup shared across the app",
    "*" =>
      "Grants access to everything, including features added later — the drift-immune way to make a role Owner-equivalent"
  }

  @doc "Returns a human-readable label for a module key (sub-permission keys resolve to the sub's own label)."
  @spec module_label(String.t()) :: String.t()
  def module_label(key) do
    Map.get_lazy(@core_labels, key, fn ->
      case Map.get(ModuleRegistry.permission_labels(), key) do
        nil ->
          sub_permission_metadata(key)[:label] ||
            custom_key_metadata(key)[:label] || String.capitalize(key)

        label ->
          label
      end
    end)
  end

  @doc """
  Returns `module_label/1` translated for the current Gettext locale.

  Backend resolution mirrors `PhoenixKit.Dashboard.Tab.localized_label/1`
  (the label string is the msgid):

  * core sections and registered feature modules translate through the
    library's own `PhoenixKitWeb.Gettext` (`"default"` domain) — the same
    msgids the admin sidebar tabs already carry — unless the module
    declares its own `gettext_backend`/`gettext_domain` in
    `permission_metadata/0`;
  * sub-permission keys inherit the parent module's backend;
  * custom keys use the backend passed to `register_custom_key/2`, or fall
    back to the raw label when none was registered.

  When the msgid has no translation for the active locale, gettext returns
  the msgid itself, so this never renders worse than `module_label/1`.

  > #### Labels are runtime msgids {: .info}
  >
  > `mix gettext.extract` scans for `gettext`/`gettext_noop` call sites, so
  > it cannot see a label that only exists as data in `permission_metadata/0`
  > or a `register_custom_key/2` option. A module's label translates only if
  > its exact string is already a msgid in the target backend's `.po` files —
  > most core labels are, because the admin sidebar tabs mark the same
  > strings with `gettext_noop/1`. When adding a module whose label is not
  > yet a tab label, add the msgid to the backend's `.po` files by hand.
  """
  @spec localized_module_label(String.t()) :: String.t()
  def localized_module_label(key) do
    label = module_label(key)

    case label_gettext(key) do
      nil -> label
      {backend, domain} -> Gettext.dgettext(backend, domain, label)
    end
  end

  # Resolves which gettext {backend, domain} translates `key`'s label,
  # following the same source order as module_label/1.
  defp label_gettext(key) do
    cond do
      Map.has_key?(@core_labels, key) ->
        {PhoenixKitWeb.Gettext, "default"}

      Map.has_key?(ModuleRegistry.permission_labels(), key) ->
        Map.get(ModuleRegistry.permission_gettext(), key, {PhoenixKitWeb.Gettext, "default"})

      parent_key(key) != nil ->
        label_gettext(parent_key(key))

      true ->
        custom_label_gettext(custom_key_metadata(key))
    end
  end

  defp custom_label_gettext(%{gettext_backend: backend} = meta) when is_atom(backend),
    do: {backend, meta[:gettext_domain] || "default"}

  defp custom_label_gettext(_), do: nil

  # A backend that isn't a loaded Gettext module would raise from
  # `dgettext/3` at render time — taking down the whole permissions matrix
  # for one bad registration. Reject it here instead, where the caller can
  # see the warning at boot.
  defp validate_gettext_backend(nil, _key), do: nil

  defp validate_gettext_backend(backend, _key)
       when is_atom(backend) and backend != nil do
    if Code.ensure_loaded?(backend) and function_exported?(backend, :__gettext__, 1) do
      backend
    else
      Logger.warning(
        "[Permissions] Ignoring gettext_backend #{inspect(backend)}: not a loaded Gettext backend (no __gettext__/1)"
      )

      nil
    end
  end

  defp validate_gettext_backend(backend, key) do
    Logger.warning(
      "[Permissions] Ignoring non-module gettext_backend #{inspect(backend)} for key #{inspect(key)}"
    )

    nil
  end

  @doc "Returns a Heroicon name for a module key (sub-permission keys inherit the parent module's icon)."
  @spec module_icon(String.t()) :: String.t()
  def module_icon(key) do
    Map.get_lazy(@core_icons, key, fn ->
      case Map.get(ModuleRegistry.permission_icons(), key) do
        nil ->
          case parent_key(key) do
            nil -> custom_key_metadata(key)[:icon] || "hero-squares-2x2"
            parent -> module_icon(parent)
          end

        icon ->
          icon
      end
    end)
  end

  @doc "Returns a short description for a module key (sub-permission keys resolve to the sub's own description)."
  @spec module_description(String.t()) :: String.t()
  def module_description(key) do
    Map.get_lazy(@core_descriptions, key, fn ->
      case Map.get(ModuleRegistry.permission_descriptions(), key) do
        nil ->
          sub_permission_metadata(key)[:description] ||
            custom_key_metadata(key)[:description] || ""

        desc ->
          desc
      end
    end)
  end

  # --- Query API ---

  @doc """
  Returns the list of module_keys the given user has access to.
  Joins through role_assignments → role_permissions.
  """
  @spec get_permissions_for_user(User.t() | nil) :: [String.t()]
  def get_permissions_for_user(nil), do: []
  def get_permissions_for_user(%User{uuid: nil}), do: []

  def get_permissions_for_user(%User{uuid: user_uuid}) when not is_nil(user_uuid) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      join: ra in RoleAssignment,
      on: ra.role_uuid == rp.role_uuid,
      where: ra.user_uuid == ^user_uuid,
      select: rp.module_key,
      distinct: true
    )
    |> repo.all()
  rescue
    e ->
      if table_missing_error?(e) do
        Logger.error(
          "PhoenixKit: phoenix_kit_role_permissions table not found. " <>
            "Run `mix phoenix_kit.update` to apply V53 migration."
        )
      else
        Logger.warning("Permissions.get_permissions_for_user failed: #{inspect(e)}")
      end

      []
  end

  @doc """
  Whether the permissions table is present (migrated), regardless of how many
  rows it holds.

  This is the ONLY signal that unlocks the Admin full-access fallback: a
  genuinely unmigrated install (pre-V53, table missing) returns `false`, and
  scope treats that as "not yet seeded → grant Admin everything". Once the
  table exists, zero rows for an Admin means an Owner deliberately revoked
  them — no access — and that must stick; row COUNT must never re-open the
  fallback (the old `any_permissions_exist?` did, so stripping every role
  bare ironically restored full access).

  Fails CLOSED: a transient/other query error returns `true` (table assumed
  present), so a DB blip de-privileges an Admin to their explicit rows rather
  than escalating them to full access.
  """
  @spec permissions_table_ready?() :: boolean()
  def permissions_table_ready? do
    repo = RepoHelper.repo()
    _ = repo.exists?(from(rp in RolePermission, select: true))
    true
  rescue
    e -> not table_missing_error?(e)
  end

  @deprecated "Use permissions_table_ready?/0 — count-based checks re-open the full-access fallback"
  @spec any_permissions_exist?() :: boolean()
  def any_permissions_exist? do
    repo = RepoHelper.repo()
    repo.exists?(from(rp in RolePermission, select: true))
  rescue
    _ -> false
  end

  @doc """
  Checks if a specific role has a specific permission.
  """
  @spec role_has_permission?(String.t(), String.t()) :: boolean()
  def role_has_permission?(role_uuid, module_key) do
    repo = RepoHelper.repo()
    role_uuid = resolve_role_uuid(role_uuid)

    from(rp in RolePermission,
      where: rp.role_uuid == ^role_uuid and rp.module_key == ^module_key,
      select: true
    )
    |> repo.exists?()
  rescue
    e ->
      Logger.warning("Permissions.role_has_permission? failed: #{inspect(e)}")
      false
  end

  @doc """
  Returns the list of module_keys granted to a specific role.
  """
  @spec get_permissions_for_role(String.t()) :: [String.t()]
  def get_permissions_for_role(role_uuid) do
    repo = RepoHelper.repo()
    role_uuid = resolve_role_uuid(role_uuid)

    from(rp in RolePermission,
      where: rp.role_uuid == ^role_uuid,
      select: rp.module_key,
      order_by: [asc: rp.module_key]
    )
    |> repo.all()
  rescue
    e ->
      Logger.warning("Permissions.get_permissions_for_role failed: #{inspect(e)}")
      []
  end

  @doc """
  Returns the union of module_keys granted to the given roles.

  The role-restricted counterpart of `get_permissions_for_user/1`, and how a
  scope narrowed to an active role (`PhoenixKit.Users.ActiveRole`) loads its
  permissions. Same failure policy: any error returns `[]`, failing closed.
  """
  @spec get_permissions_for_roles([String.t()]) :: [String.t()]
  def get_permissions_for_roles([]), do: []

  def get_permissions_for_roles(role_uuids) when is_list(role_uuids) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      where: rp.role_uuid in ^role_uuids,
      select: rp.module_key,
      distinct: true
    )
    |> repo.all()
  rescue
    e ->
      Logger.warning("Permissions.get_permissions_for_roles failed: #{inspect(e)}")
      []
  end

  @doc """
  Returns a matrix of role_uuid → MapSet of granted keys for all roles.
  """
  @spec get_permissions_matrix() :: %{String.t() => MapSet.t()}
  def get_permissions_matrix do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      select: {rp.role_uuid, rp.module_key}
    )
    |> repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {role_uuid, keys} -> {role_uuid, MapSet.new(keys)} end)
  rescue
    e ->
      Logger.warning("Permissions.get_permissions_matrix failed: #{inspect(e)}")
      %{}
  end

  @doc """
  Returns a list of role_ids that have been granted the given module_key.
  """
  @spec roles_with_permission(String.t()) :: [String.t()]
  def roles_with_permission(module_key) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      where: rp.module_key == ^module_key,
      select: rp.role_uuid,
      order_by: [asc: rp.role_uuid]
    )
    |> repo.all()
  rescue
    e ->
      Logger.warning("Permissions.roles_with_permission failed: #{inspect(e)}")
      []
  end

  @doc """
  Returns a list of user_ids that have access to the given module_key
  (through any of their assigned roles).
  """
  @spec users_with_permission(String.t()) :: [String.t()]
  def users_with_permission(module_key) do
    repo = RepoHelper.repo()

    from(rp in RolePermission,
      join: ra in RoleAssignment,
      on: ra.role_uuid == rp.role_uuid,
      where: rp.module_key == ^module_key,
      select: ra.user_uuid,
      distinct: true,
      order_by: [asc: ra.user_uuid]
    )
    |> repo.all()
  rescue
    e ->
      Logger.warning("Permissions.users_with_permission failed: #{inspect(e)}")
      []
  end

  @doc """
  Returns the number of permission keys granted to a role.
  More efficient than `length(get_permissions_for_role(role_uuid))`.
  """
  @spec count_permissions_for_role(integer() | String.t()) :: non_neg_integer()
  def count_permissions_for_role(role_uuid) do
    repo = RepoHelper.repo()
    role_uuid = resolve_role_uuid(role_uuid)

    from(rp in RolePermission,
      where: rp.role_uuid == ^role_uuid,
      select: count()
    )
    |> repo.one()
  rescue
    e ->
      Logger.warning("Permissions.count_permissions_for_role failed: #{inspect(e)}")
      0
  end

  @doc """
  Compares permissions between two roles and returns a diff map.

  Returns `%{only_a: MapSet.t(), only_b: MapSet.t(), common: MapSet.t()}`
  where `only_a` are keys role_a has but role_b doesn't, `only_b` is the
  inverse, and `common` are keys both roles share.
  """
  @spec diff_permissions(integer() | String.t(), integer() | String.t()) :: %{
          only_a: MapSet.t(),
          only_b: MapSet.t(),
          common: MapSet.t()
        }
  def diff_permissions(role_uuid_a, role_uuid_b) do
    keys_a = get_permissions_for_role(role_uuid_a) |> MapSet.new()
    keys_b = get_permissions_for_role(role_uuid_b) |> MapSet.new()

    %{
      only_a: MapSet.difference(keys_a, keys_b),
      only_b: MapSet.difference(keys_b, keys_a),
      common: MapSet.intersection(keys_a, keys_b)
    }
  end

  # --- Mutation API ---

  @doc """
  Grants a single permission to a role. Uses upsert to be idempotent.

  Granting a sub-permission key (`"calendar.view_others"`) also grants its
  base module key in the same transaction — a sub-permission row must never
  exist without module access, regardless of which code path grants it.
  """
  @spec grant_permission(integer() | String.t(), String.t(), integer() | String.t() | nil) ::
          {:ok, RolePermission.t()} | {:error, Ecto.Changeset.t() | :role_not_found}
  def grant_permission(role_uuid, module_key, granted_by_uuid \\ nil) do
    repo = RepoHelper.repo()

    role_uuid = resolve_role_uuid(role_uuid)

    if is_nil(role_uuid) do
      {:error, :role_not_found}
    else
      case grant_permission_locked(repo, role_uuid, module_key, granted_by_uuid) do
        {:ok, _} = result ->
          # Audit on success. The row uuid is client-generated (UUIDv7
          # autogenerate), so it CANNOT distinguish a real insert from an
          # idempotent `on_conflict: :nothing` no-op — a rare re-grant of an
          # already-held key may log a duplicate "granted". Acceptable: the only
          # UI path (the permissions matrix) grants un-held keys, and
          # over-logging is not a security/data concern.
          log_permission_activity(
            "permission.granted",
            role_uuid,
            resolve_user_uuid(granted_by_uuid),
            %{"module_key" => module_key}
          )

          result

        error ->
          error
      end
    end
  end

  # Take the same advisory lock as revoke, so a base revoke's
  # authorize-then-cascade can't interleave a concurrent sub grant. A
  # sub-permission also pulls in its base — a sub row must never exist
  # without module access, whatever path grants it. The base insert is an
  # idempotent upsert, so an already-held base is unaffected.
  defp grant_permission_locked(repo, role_uuid, module_key, granted_by_uuid) do
    base = base_key_of(module_key)

    repo.transaction(fn ->
      lock_role_for_update(repo, role_uuid)
      lock_role_module(repo, role_uuid, base)

      case do_grant(repo, role_uuid, module_key, granted_by_uuid) do
        {:ok, record} -> record
        {:error, changeset} -> repo.rollback(changeset)
      end
    end)
  end

  # Grant `module_key`, first pulling in its base when it is a sub-permission —
  # a sub row must never exist without module access. The base insert is an
  # idempotent upsert, so an already-held base is unaffected.
  defp do_grant(repo, role_uuid, module_key, granted_by_uuid) do
    case parent_key(module_key) do
      nil ->
        grant_permission_insert(repo, role_uuid, module_key, granted_by_uuid)

      parent ->
        with {:ok, _base} <- grant_permission_insert(repo, role_uuid, parent, granted_by_uuid) do
          grant_permission_insert(repo, role_uuid, module_key, granted_by_uuid)
        end
    end
  end

  defp base_key_of(module_key), do: parent_key(module_key) || module_key

  # Transaction-scoped advisory lock serializing grant/revoke of one role's
  # module tree (base + its sub-keys). Released automatically on commit/rollback.
  defp lock_role_module(repo, role_uuid, base_key) do
    repo.query!(
      "SELECT pg_advisory_xact_lock(hashtext($1))",
      ["pk_role_perm:#{role_uuid}:#{base_key}"]
    )
  end

  # Row-level lock on the Role row, taken by EVERY mutation path
  # (grant/revoke/set_permissions) as its FIRST lock. Without it, per-key
  # grant/revoke (which take only the per-{role, base} advisory lock above) and
  # the whole-role `set_permissions/3` (which locks this row) are disjoint lock
  # objects: a grant of key X committed between `set_permissions` snapshotting
  # `current_keys` and its delete pass is invisible to that snapshot, so X
  # survives a strip the Owner intended — the exact interleaving the advisory
  # lock was built to stop, reachable because the two paths never shared a lock.
  # Always acquired before `lock_role_module/3`, so the order is consistent and
  # cannot deadlock.
  #
  # FOR NO KEY UPDATE, not FOR UPDATE: no mutation path here changes the role's
  # key, and FOR UPDATE also conflicts with the FOR KEY SHARE that Postgres
  # takes on this row to validate the foreign key of every
  # `phoenix_kit_user_role_assignments` insert. That made role assignment — a
  # step in creating any user — block on unrelated permission edits, and the
  # pair deadlocked (40P01) whenever two transactions held one role row each
  # and then referenced the other's. FOR NO KEY UPDATE still excludes the
  # concurrent grant/revoke/set_permissions this guard exists to exclude.
  defp lock_role_for_update(repo, role_uuid) do
    from(r in Role, where: r.uuid == ^role_uuid, select: r.uuid, lock: "FOR NO KEY UPDATE")
    |> repo.one()
  end

  defp grant_permission_insert(repo, role_uuid, module_key, granted_by_uuid) do
    granted_by_uuid = resolve_user_uuid(granted_by_uuid)

    %RolePermission{}
    |> RolePermission.changeset(%{
      role_uuid: role_uuid,
      module_key: module_key,
      granted_by_uuid: granted_by_uuid
    })
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:role_uuid, :module_key]
    )
    |> tap(fn
      {:ok, %{uuid: uuid}} when not is_nil(uuid) ->
        Events.broadcast_permission_granted(role_uuid, module_key)
        notify_affected_users(role_uuid)

      _ ->
        :ok
    end)
  end

  @doc """
  Revokes a single permission from a role.

  Revoking a base module key also revokes all of its sub-permission keys in
  the same statement — a sub-permission row must never outlive module access.
  Revoking a sub-permission key removes only that key.

  Pass `authorized_keys: MapSet.t()` to restrict the revoke to keys the caller
  is allowed to manage: the role's currently-held keys among the cascade are
  read **inside the transaction under an advisory lock**, and if any falls
  outside `authorized_keys` the whole revoke is rejected with `:unauthorized`.
  This closes the race where a caller's cached view misses a concurrently
  granted sub-key it doesn't hold. Omitted (or `:all`) skips the check — for
  system/internal callers.

  Pass `actor_uuid:` to record who performed the revoke in the audit trail
  (`permission.revoked` activity). Omitted ⇒ no audit entry (internal callers).
  """
  @spec revoke_permission(integer() | String.t(), String.t(), keyword()) ::
          :ok | {:error, :not_found | :unauthorized}
  def revoke_permission(role_uuid, module_key, opts \\ []) do
    repo = RepoHelper.repo()
    role_uuid = resolve_role_uuid(role_uuid)
    authorized = Keyword.get(opts, :authorized_keys, :all)
    actor_uuid = Keyword.get(opts, :actor_uuid)
    base = base_key_of(module_key)

    keys_to_remove = [module_key | Enum.map(sub_permissions_for(module_key), & &1.key)]

    repo.transaction(fn ->
      # Serialize with concurrent grants of this role's module tree, then read
      # what the role ACTUALLY holds under the lock — so authorization can't
      # miss a sub-key granted after the caller's (cached) view was built, and
      # the base's cascade can't drop a key the caller isn't allowed to manage.
      lock_role_for_update(repo, role_uuid)
      lock_role_module(repo, role_uuid, base)

      present =
        from(rp in RolePermission,
          where: rp.role_uuid == ^role_uuid and rp.module_key in ^keys_to_remove,
          select: rp.module_key
        )
        |> repo.all()

      cond do
        present == [] ->
          repo.rollback(:not_found)

        authorized != :all and not MapSet.subset?(MapSet.new(present), authorized) ->
          repo.rollback(:unauthorized)

        true ->
          from(rp in RolePermission,
            where: rp.role_uuid == ^role_uuid and rp.module_key in ^keys_to_remove
          )
          |> repo.delete_all()

          :revoked
      end
    end)
    |> case do
      {:ok, :revoked} ->
        Events.broadcast_permission_revoked(role_uuid, module_key)
        notify_affected_users(role_uuid)

        log_permission_activity(
          "permission.revoked",
          role_uuid,
          resolve_user_uuid(actor_uuid),
          %{"module_key" => module_key}
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Syncs permissions for a role: grants missing keys, revokes extras.
  Runs in a transaction.

  The desired set is normalized before applying: every sub-permission key in
  it pulls in its base module key (a sub-permission implies module access),
  so no code path can persist an orphan sub-key row.
  """
  @spec set_permissions(integer() | String.t(), [String.t()], integer() | String.t() | nil) ::
          :ok | {:error, term()}
  def set_permissions(role_uuid, desired_keys, granted_by_uuid \\ nil) do
    repo = RepoHelper.repo()
    valid_keys = MapSet.new(all_module_keys())

    repo.transaction(fn ->
      role_uuid = resolve_role_uuid(role_uuid)

      # Lock the ROLE row first (see `lock_role_for_update/2` for the mode and
      # why). Locking only the permission rows (below) is insufficient when the
      # role currently has ZERO of them —
      # there is nothing to lock, so two concurrent set_permissions calls both
      # observe an empty set and insert disjoint desired sets, leaving their
      # union rather than either requested state. The role-row lock serializes
      # them regardless of how many permission rows exist — AND serializes this
      # whole-role sync against single-key grant/revoke, which take the same
      # lock (see `lock_role_for_update/2`).
      lock_role_for_update(repo, role_uuid)

      # Lock existing permission rows FOR UPDATE to prevent concurrent set_permissions
      # from reading the same state and computing conflicting diffs.
      current_keys =
        from(rp in RolePermission,
          where: rp.role_uuid == ^role_uuid,
          select: rp.module_key,
          lock: "FOR UPDATE"
        )
        |> repo.all()
        |> MapSet.new()

      # Filter out any invalid keys, then pull in base keys implied by subs
      desired_set =
        desired_keys
        |> MapSet.new()
        |> MapSet.intersection(valid_keys)
        |> expand_with_parents()

      # Keys to add
      to_add = MapSet.difference(desired_set, current_keys)

      # Keys to remove
      to_remove = MapSet.difference(current_keys, desired_set)

      # Bulk insert new permissions
      if MapSet.size(to_add) > 0 do
        now = UtilsDate.utc_now()
        granted_by_uuid = resolve_user_uuid(granted_by_uuid)

        entries =
          Enum.map(to_add, fn key ->
            %{
              uuid: UUIDv7.generate(),
              role_uuid: role_uuid,
              module_key: key,
              granted_by_uuid: granted_by_uuid,
              inserted_at: now
            }
          end)

        repo.insert_all(RolePermission, entries, on_conflict: :nothing)
      end

      # Bulk delete removed permissions
      if MapSet.size(to_remove) > 0 do
        remove_list = MapSet.to_list(to_remove)

        from(rp in RolePermission,
          where: rp.role_uuid == ^role_uuid and rp.module_key in ^remove_list
        )
        |> repo.delete_all()
      end

      MapSet.to_list(desired_set)
    end)
    |> case do
      {:ok, filtered_keys} ->
        Events.broadcast_permissions_synced(role_uuid, filtered_keys)
        notify_affected_users(role_uuid)

        log_permission_activity(
          "permission.synced",
          resolve_role_uuid(role_uuid),
          resolve_user_uuid(granted_by_uuid),
          %{"keys" => filtered_keys, "count" => length(filtered_keys)}
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Grants all permission keys to a role.

  `all_module_keys/0` includes the `"*"` superadmin key, so this confers
  Owner-equivalent, drift-immune access (any future module key is reachable
  without a re-grant) — not merely the currently-registered keys. Reserve it
  for roles that are genuinely meant to be all-powerful.
  """
  @spec grant_all_permissions(integer() | String.t(), integer() | String.t() | nil) ::
          :ok | {:error, term()}
  def grant_all_permissions(role_uuid, granted_by_uuid \\ nil) do
    set_permissions(role_uuid, all_module_keys(), granted_by_uuid)
  end

  @doc """
  Revokes all permissions from a role.
  """
  @spec revoke_all_permissions(integer() | String.t()) :: :ok | {:error, term()}
  def revoke_all_permissions(role_uuid) do
    repo = RepoHelper.repo()

    role_uuid = resolve_role_uuid(role_uuid)

    repo.transaction(fn ->
      # Join the F2 lock regime: take the role-row lock the other whole-role and
      # single-key mutations take, so a concurrent grant can't survive this
      # strip (otherwise this bare delete would race grant_permission).
      lock_role_for_update(repo, role_uuid)

      from(rp in RolePermission, where: rp.role_uuid == ^role_uuid)
      |> repo.delete_all()
    end)

    Events.broadcast_permissions_synced(role_uuid, [])
    notify_affected_users(role_uuid)
    :ok
  rescue
    e ->
      require Logger
      Logger.warning("[PhoenixKit.Permissions] revoke_all_permissions failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Copies all permissions from one role to another.

  The target role will end up with the exact same set of permissions as the
  source role. Existing permissions on the target that don't exist on the
  source will be revoked.
  """
  @spec copy_permissions(
          integer() | String.t(),
          integer() | String.t(),
          integer() | String.t() | nil
        ) :: :ok | {:error, term()}
  def copy_permissions(source_role_uuid, target_role_uuid, granted_by_uuid \\ nil) do
    source_keys = get_permissions_for_role(source_role_uuid)
    set_permissions(target_role_uuid, source_keys, granted_by_uuid)
  end

  # --- Access Control ---

  @doc """
  Checks if the given scope can edit the target role's permissions.

  Returns `:ok` if allowed, or `{:error, reason}` if not.

  Rules:
  - Owner role cannot be edited (always has full access)
  - Users cannot edit their own role (prevents self-lockout)
  - Only Owner can edit Admin role (prevents privilege escalation)
  """
  @spec can_edit_role_permissions?(Scope.t() | nil, Role.t()) :: :ok | {:error, atom()}
  def can_edit_role_permissions?(nil, _role), do: {:error, :not_authenticated}

  def can_edit_role_permissions?(scope, role) do
    if Scope.authenticated?(scope) do
      can_edit_role_permissions_check(scope, role)
    else
      {:error, :not_authenticated}
    end
  end

  defp can_edit_role_permissions_check(scope, role) do
    # Every role the user REALLY holds, not only the one they are acting as
    # (`PhoenixKit.Users.ActiveRole`): acting as "Seller" must not make the
    # user's other roles editable by them.
    user_roles = Scope.held_roles(scope)

    cond do
      role.name == "Owner" ->
        {:error, :owner_immutable}

      role.name in user_roles and not Scope.system_role?(scope) ->
        {:error, :self_role}

      role.name == "Admin" and not Scope.owner?(scope) ->
        {:error, :admin_owner_only}

      true ->
        :ok
    end
  end

  @doc """
  Maps a `can_edit_role_permissions?/2` error reason to a human-readable,
  translated message suitable for display (e.g. in a flash).
  """
  @spec edit_role_permissions_error_message(atom()) :: String.t()
  def edit_role_permissions_error_message(:not_authenticated),
    do: gettext("Not authenticated")

  def edit_role_permissions_error_message(:owner_immutable),
    do: gettext("Owner role always has full access and cannot be modified")

  def edit_role_permissions_error_message(:self_role),
    do: gettext("You cannot edit permissions for your own role")

  def edit_role_permissions_error_message(:admin_owner_only),
    do: gettext("Only the Owner can edit Admin permissions")

  def edit_role_permissions_error_message(_reason),
    do: gettext("Permission denied")

  # --- Helpers ---

  # Returns metadata for a custom permission key, or nil if not found.
  defp custom_key_metadata(key) do
    Map.get(custom_keys_map(), key)
  end

  # Returns %{key:, label:, description:} for a composed sub-permission key,
  # or nil if the key is not a registered sub-permission.
  defp sub_permission_metadata(key) do
    case parent_key(key) do
      nil -> nil
      parent -> Enum.find(sub_permissions_for(parent), &(&1.key == key))
    end
  end

  defp do_feature_enabled?(key) do
    case Map.get(ModuleRegistry.feature_enabled_checks(), key) do
      {mod, fun} ->
        Code.ensure_loaded?(mod) && apply(mod, fun, [])

      nil ->
        false
    end
  rescue
    _ -> false
  end

  # Detect Postgrex "relation does not exist" errors (table missing).
  #
  # Matches ONLY the structured `:undefined_table` SQLSTATE (42P01) — never a
  # free-form message substring. `permissions_table_ready?/0` fails CLOSED on
  # every other error, and this is the one signal that unlocks the Admin
  # full-access fallback, so it must be precise: a looser `"does not exist"`
  # substring match also caught `:undefined_column`/`:undefined_function`
  # (e.g. a half-applied migration), which would misread a transient schema
  # error as "unmigrated" and escalate a zero-row Admin to every key — a
  # fail-OPEN. The code match cannot make that mistake.
  # A `%Postgrex.Error{}` struct is itself a map carrying `:postgres`, so this
  # single pattern covers both the struct and any wrapper map exposing the code.
  defp table_missing_error?(%{postgres: %{code: :undefined_table}}), do: true

  defp table_missing_error?(_), do: false

  # Resolves an integer role_id to its UUID for changeset/insert_all use
  defp resolve_role_uuid(nil), do: nil

  defp resolve_role_uuid(role_uuid) when is_binary(role_uuid), do: role_uuid

  defp resolve_user_uuid(nil), do: nil
  defp resolve_user_uuid(user_uuid) when is_binary(user_uuid), do: user_uuid

  # Notify all users with the affected role to refresh their scope
  defp notify_affected_users(role_uuid) do
    repo = RepoHelper.repo()

    role_uuid = resolve_role_uuid(role_uuid)

    user_uuids =
      from(ra in RoleAssignment,
        where: ra.role_uuid == ^role_uuid,
        select: ra.user_uuid
      )
      |> repo.all()

    Enum.each(user_uuids, &ScopeNotifier.broadcast_roles_updated/1)
  rescue
    e ->
      Logger.warning("Permissions.notify_affected_users failed: #{inspect(e)}")
      :ok
  end

  # Best-effort durable audit trail for permission mutations. Fires ONLY for
  # user-initiated changes (an actor uuid is present) — the boot-time auto-grant
  # sweep passes no actor, so routine startup never floods the feed. `target_uuid`
  # is nil: this records a change to a ROLE for audit, not a user notification
  # (the notification fan-out keys on target_uuid, which a role change has none).
  defp log_permission_activity(_action, _role_uuid, nil, _metadata), do: :ok

  defp log_permission_activity(action, role_uuid, actor_uuid, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: action,
        module: "permissions",
        mode: "manual",
        actor_uuid: actor_uuid,
        resource_type: "role",
        resource_uuid: role_uuid,
        target_uuid: nil,
        metadata: metadata
      })
    end

    :ok
  rescue
    error ->
      Logger.warning("[Permissions] audit log failed for #{action}: #{Exception.message(error)}")
      :ok
  end

  # Clears the auto-grant settings flag for a custom key so that
  # re-registering it will trigger a fresh auto-grant to Admin.
  defp clear_auto_grant_flag(key) do
    Settings.update_setting("auto_granted_perm:#{key}", nil)
  rescue
    _ -> :ok
  end

  @doc """
  Grants every known built-in permission key (core sections, feature-module
  keys, sub-permission keys) to the Admin system role, skipping keys that
  were auto-granted before (per-key settings flag) so an Owner's later
  revocation is never overridden. Custom keys go through the same mechanism
  at `register_custom_key/2` time.

  Called after module discovery. This is also the repair path for installs
  whose V53 seeding predates newer modules: the first boot after upgrade
  fills the Admin role's missing keys, after which revocations stick
  per-key. Idempotent; safe when the table doesn't exist yet.
  """
  @spec auto_grant_new_keys_to_admin() :: :ok
  def auto_grant_new_keys_to_admin do
    # Auto-grant ONLY the website-wide integration key to Admin (so admins keep
    # the system integrations page after it moved off the `settings` key). The
    # PERSONAL `integrations` key is deliberately NOT auto-granted — it's opt-in,
    # so admins don't silently get a personal page they didn't ask for.
    (@core_section_keys ++
       [@integrations_system_key] ++ feature_module_keys() ++ sub_permission_keys())
    |> Enum.each(&auto_grant_to_admin_roles/1)

    :ok
  end

  @doc """
  Grants `media.view_all` and `media.manage` ONCE to every role that holds `media`:
  before they existed, holding `media` meant seeing every file and opening the
  storage screens, and an upgrade must not take either away. A flag records that it
  ran, so a role that later has one revoked (or a role created afterwards) is not
  given it back. Idempotent; called at boot after `auto_grant_new_keys_to_admin/0`.
  """
  @spec backfill_media_sub_permissions() :: :ok
  def backfill_media_sub_permissions do
    # Read from the row, like `auto_grant_to_admin_roles/1`'s flag: through
    # `Settings.get_setting/1` it reads nil with `update_mode` on.
    if match?(%{value: "true"}, SettingsQueries.get_setting_by_key(@media_subs_flag)) do
      :ok
    else
      subs = Enum.map(@core_sub_permissions["media"], & &1.key)
      roles = roles_with_permission("media")

      results =
        for role <- roles, key <- subs do
          grant_permission(role, key)
        end

      # Flagged only when every grant went through: a failure is retried next boot.
      if Enum.all?(results, &match?({:ok, _}, &1)),
        do: Settings.update_setting(@media_subs_flag, "true")

      :ok
    end
  rescue
    error ->
      unless table_missing_error?(error) do
        Logger.warning(
          "[Permissions] media sub-permission backfill failed: #{Exception.message(error)}"
        )
      end

      :ok
  end

  @doc """
  Auto-grants a permission key to the Admin system role.
  Stores a flag in phoenix_kit_settings so that if Owner later revokes
  the key, it won't be re-granted on next application restart — nor by
  `mix phoenix_kit.update` / `mix phoenix_kit.doctor`, which start the host
  in `update_mode` (the flag is read from its row, not the settings reader
  that answers nil in that mode). A flag that cannot be read grants
  nothing: the grant fails closed and is tried again next boot.
  """
  @spec auto_grant_to_admin_roles(String.t()) :: :ok
  # Opt-in keys are never auto-granted to Admin — they surface only on an explicit
  # Owner grant. This is the authoritative chokepoint, so the guarantee holds no
  # matter which path requests the grant (the boot-time sweep OR the tab registry
  # auto-registering a core/feature tab's permission).
  def auto_grant_to_admin_roles(key) when key in @opt_in_admin_keys, do: :ok

  def auto_grant_to_admin_roles(key) do
    flag_key = "auto_granted_perm:#{key}"

    # If already auto-granted before, respect any manual changes. The flag is
    # read from its row, not through `Settings.get_setting/1`: with
    # `update_mode` on (`mix phoenix_kit.update` / `mix phoenix_kit.doctor`
    # start the host that way, and a host registers its custom keys while it
    # starts) that answers nil without reading, and an Owner's revocation was
    # undone by the grant on every such run.
    if match?(%{value: "true"}, SettingsQueries.get_setting_by_key(flag_key)) do
      :ok
    else
      case Roles.get_role_by_name(Role.system_roles().admin) do
        %{uuid: admin_uuid} when not is_nil(admin_uuid) ->
          maybe_auto_grant(admin_uuid, key, flag_key)

        _ ->
          # Admin role not found (pre-V53 or missing), skip
          :ok
      end
    end
  rescue
    error ->
      # Silently skip if the table doesn't exist yet (expected on fresh installs
      # where the app starts before migrations have created the table). Uses the
      # structured `:undefined_table` check (matching F7), not a message
      # substring. This suppresses a log line only — a genuine grant failure
      # still fails CLOSED (Admin simply lacks the key, retried next boot).
      unless table_missing_error?(error) do
        Logger.warning(
          "[Permissions] Failed to auto-grant #{inspect(key)} to Admin role: #{Exception.message(error)}"
        )
      end

      :ok
  catch
    # A dead pool exits rather than raises; the grant fails closed the same way.
    :exit, reason ->
      Logger.warning(
        "[Permissions] Failed to auto-grant #{inspect(key)} to Admin role: #{inspect(reason)}"
      )

      :ok
  end

  # Auto-grant one key, but never let a NEW sub-key resurrect a base that an
  # Owner has revoked from Admin. Granting a sub normally cascades a grant of
  # its base (grant_sub_with_parent); at boot that would silently undo the
  # revocation. So a sub is auto-granted only while Admin still holds its
  # base — and when it doesn't, we skip WITHOUT flagging, so a later
  # re-grant of the base lets the sub auto-grant on a subsequent boot.
  defp maybe_auto_grant(admin_uuid, key, flag_key) do
    parent = parent_key(key)

    if parent && not role_has_permission?(admin_uuid, parent) do
      :ok
    else
      case grant_permission(admin_uuid, key, nil) do
        {:ok, _} ->
          Settings.update_setting(flag_key, "true")
          :ok

        {:error, _} ->
          Logger.warning(
            "[Permissions] grant_permission failed for Admin role on key #{inspect(key)}, will retry next boot"
          )

          :ok
      end
    end
  end

  # Coerces a value to a string, returning the default for nil.
  # Handles atoms, integers, and other types gracefully via to_string/1.
  defp coerce_string(nil, default), do: default
  defp coerce_string(value, _default) when is_binary(value), do: value
  defp coerce_string(value, _default), do: to_string(value)
end
