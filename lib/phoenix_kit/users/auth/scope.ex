defmodule PhoenixKit.Users.Auth.Scope do
  @moduledoc """
  Scope module for encapsulating PhoenixKit authentication state.

  This module provides a structured way to handle user authentication context
  throughout your Phoenix application, similar to Phoenix's built-in authentication
  patterns but with PhoenixKit prefixing to avoid conflicts.

  ## Nil scopes

  **Every predicate and accessor here tolerates a `nil` scope and answers as if
  the visitor were unauthenticated.** Host layouts render on kit auth pages with
  `phoenix_kit_current_scope` unset, so `authenticated?(nil)` and
  `anonymous?(nil)` are ordinary calls, not programmer errors — and "no scope"
  and "a scope with no user" mean the same thing to a caller deciding what to
  render.

  The exception is `to_map/1`, which deliberately does not accept `nil`. There
  is nothing meaningful to serialize for a non-scope, and returning an empty map
  would fabricate data that looks real; it is a debug/serialization helper, so
  failing surfaces the bug where permissiveness would bury it. Its spec keeps
  `t()`, so the type checker rejects `to_map(nil)` at compile time rather than
  leaving it to blow up at runtime.

  Apply the same rule to anything added here: if `nil` has a correct answer,
  give it one; if answering would mean inventing data, let it raise.

  ## Usage

      # Create scope for authenticated user
      scope = Scope.for_user(user)

      # Create scope for anonymous user
      scope = Scope.for_user(nil)

      # Check authentication status
      Scope.authenticated?(scope)  # true or false

      # Get user information
      Scope.user(scope)        # %User{} or nil
      Scope.user_uuid(scope)   # user.uuid or nil
      Scope.user_email(scope)  # user.email or nil

  ## Role & State Checks

      Scope.has_role?(scope, "Admin")  # true/false
      Scope.owner?(scope)             # Owner role?
      Scope.can_access_admin_area?(scope)  # Owner, Admin, or custom role with permissions?
      Scope.system_role?(scope)       # Strictly Owner or Admin (not custom roles)?
      Scope.anonymous?(scope)         # Not authenticated?
      Scope.user_roles(scope)         # ["Admin", "User"]
      Scope.user_full_name(scope)     # "John Doe" or nil
      Scope.user_active?(scope)       # true/false
      Scope.to_map(scope)             # Debug-friendly map of all fields

  ## Module-Level Permissions

  Permissions are cached in the scope when it is built via `for_user/1`
  (on mount and on PubSub-triggered refresh). Owner gets every key
  automatically. Admin defaults to all keys via seeding/auto-grant but is
  genuinely gated by its rows — the full-access fallback applies only on an
  unseeded install (no permission rows exist at all).

      Scope.has_module_access?(scope, "billing")          # Single key check (pure cache)
      Scope.can?(scope, "calendar.view_others")           # Key held AND module enabled
      Scope.has_any_module_access?(scope, ["billing", "shop"])  # Any of these?
      Scope.has_all_module_access?(scope, ["billing", "shop"])  # All of these?
      Scope.accessible_modules(scope)                     # MapSet of granted keys
      Scope.permission_count(scope)                       # Number of granted keys

  ## Struct Fields

  - `:user` - The current user struct or nil
  - `:authenticated?` - Boolean indicating if user is authenticated
  - `:cached_roles` - List of role name strings IN EFFECT, loaded at scope creation
  - `:cached_permissions` - MapSet of granted permission keys, loaded at scope creation
  - `:held_roles` - List of every role name the user really holds
  - `:active_role` - `%{uuid, name}` of the role the user is acting as, or `nil`
  - `:switchable_roles` - `%{uuid, name}` of every role the user can switch to (`[]` when not narrowed)

  ## Active role

  With the role switcher on, a user holding two or more switchable roles acts
  as one of them, and `for_user/1` narrows `cached_roles` and
  `cached_permissions` to that role plus the always-on ones — so every check
  above answers for the active role. See `PhoenixKit.Users.ActiveRole`.

      Scope.active_role(scope)  # %{uuid: "...", name: "Seller"} or nil
      Scope.held_roles(scope)   # ["Admin", "Seller", "User"]
      Scope.narrowed?(scope)    # acting as one role?

  `held_roles/1` is for the switcher and for rules that protect against a
  user's REAL roles (e.g. "cannot edit a role you hold"). Access decisions use
  the narrowed checks. `for_user(user, narrow: false)` builds the full union.
  """

  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles

  @type t :: %__MODULE__{
          user: User.t() | nil,
          authenticated?: boolean(),
          cached_roles: [String.t()] | nil,
          cached_permissions: MapSet.t() | nil,
          held_roles: [String.t()] | nil,
          active_role: ActiveRole.role() | nil,
          switchable_roles: [ActiveRole.role()],
          multi_session_accounts: list(),
          multi_session_allowed?: boolean()
        }

  # `multi_session_*` are transient, request-scoped UI fields populated by the
  # scope-mounting hook/plug (which have the Plug session) for the header
  # account switcher; they are NOT loaded by `for_user/1` and default empty.
  defstruct user: nil,
            authenticated?: false,
            cached_roles: nil,
            cached_permissions: nil,
            held_roles: nil,
            active_role: nil,
            switchable_roles: [],
            multi_session_accounts: [],
            multi_session_allowed?: false

  @doc """
  Creates a new scope for the given user.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001", email: "user@example.com"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> scope.authenticated?
      true
      iex> scope.user.email
      "user@example.com"

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> scope.authenticated?
      false
      iex> scope.user
      nil
  """
  # Mirrors `Permissions.superadmin_key/0`, kept as a local literal to avoid a
  # compile-time call into `Permissions` (which aliases this module — a cycle).
  # Holding this wildcard key is a blanket grant honored by `has_module_access?/2`,
  # `base_held?/2`, and `can?/2` via `holds?/2`.
  @superadmin_key "*"

  @spec for_user(User.t() | nil, keyword()) :: t()
  def for_user(user, opts \\ [])

  def for_user(%User{} = user, opts) do
    held = Roles.get_user_role_records(user)

    # Narrow to the active role (plus always-on roles) when the user is acting
    # as one. Everything below reads the EFFECTIVE roles, so an Owner acting as
    # "Seller" gets neither the Owner branch nor Owner's permissions.
    {active_role, effective, switchable} =
      if Keyword.get(opts, :narrow, true),
        do: ActiveRole.narrow(user, held),
        else: {nil, held, []}

    cached_roles = Enum.map(effective, & &1.name)

    # Load permissions: Owner gets all, others get from DB
    roles = Role.system_roles()

    cached_permissions =
      cond do
        roles.owner in cached_roles ->
          MapSet.new(Permissions.all_module_keys())

        roles.admin in cached_roles ->
          case load_permissions(user, active_role, effective) do
            # Admin with no explicit permissions falls back to full access
            # ONLY when the permissions table is genuinely MISSING (pre-V53
            # / migrations not yet run). Once the table exists, zero rows
            # means an Owner deliberately revoked everything from this
            # admin's roles, and that must stick — keyed on table presence,
            # NOT row count, so stripping every role bare can never restore
            # full access, and a transient query error fails closed to
            # empty rather than escalating.
            [] ->
              if Permissions.permissions_table_ready?() do
                MapSet.new()
              else
                MapSet.new(Permissions.all_module_keys())
              end

            perms ->
              MapSet.new(perms)
          end

        true ->
          load_permissions(user, active_role, effective) |> MapSet.new()
      end

    %__MODULE__{
      user: user,
      authenticated?: true,
      cached_roles: cached_roles,
      cached_permissions: cached_permissions,
      held_roles: Enum.map(held, & &1.name),
      active_role: active_role,
      switchable_roles: switchable
    }
  end

  def for_user(nil, _opts) do
    %__MODULE__{
      user: nil,
      authenticated?: false,
      cached_roles: [],
      cached_permissions: MapSet.new()
    }
  end

  # Not narrowed: the union across every held role, exactly as before the
  # active role existed. Narrowed: only the roles in effect.
  defp load_permissions(user, nil, _effective), do: Permissions.get_permissions_for_user(user)

  defp load_permissions(_user, _active_role, effective),
    do: Permissions.get_permissions_for_roles(Enum.map(effective, & &1.uuid))

  @doc """
  Checks if the scope represents an authenticated user.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.authenticated?(scope)
      true

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.authenticated?(scope)
      false
  """
  @spec authenticated?(t() | nil) :: boolean()
  def authenticated?(%__MODULE__{authenticated?: authenticated?}), do: authenticated?
  def authenticated?(_), do: false

  @doc """
  Gets the user from the scope.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001", email: "user@example.com"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.user(scope)
      %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001", email: "user@example.com"}

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.user(scope)
      nil
  """
  @spec user(t() | nil) :: User.t() | nil
  def user(%__MODULE__{user: user}), do: user
  def user(_), do: nil

  @doc """
  Gets the user ID (UUID) from the scope.

  ## Examples

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.user_uuid(scope)
      "0193a5e4-..."

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.user_uuid(scope)
      nil
  """
  @spec user_uuid(t() | nil) :: String.t() | nil
  def user_uuid(%__MODULE__{user: %User{uuid: uuid}}), do: uuid
  def user_uuid(_), do: nil

  @doc """
  Gets the user email from the scope.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001", email: "user@example.com"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.user_email(scope)
      "user@example.com"

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.user_email(scope)
      nil
  """
  @spec user_email(t() | nil) :: String.t() | nil
  def user_email(%__MODULE__{user: %User{email: email}}), do: email
  def user_email(_), do: nil

  @doc """
  Checks if the scope represents an anonymous (non-authenticated) user.

  ## Examples

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.anonymous?(scope)
      true

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.anonymous?(scope)
      false
  """
  @spec anonymous?(t() | nil) :: boolean()
  def anonymous?(%__MODULE__{authenticated?: authenticated?}), do: not authenticated?
  def anonymous?(_), do: true

  @doc """
  Checks if the user has a specific role.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.has_role?(scope, "Admin")
      true

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.has_role?(scope, "Admin")
      false
  """
  @spec has_role?(t(), String.t()) :: boolean()
  def has_role?(%__MODULE__{cached_roles: cached_roles}, role_name)
      when is_binary(role_name) and is_list(cached_roles) do
    role_name in cached_roles
  end

  def has_role?(_, _role_name), do: false

  @doc """
  Checks if the user is an owner.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.owner?(scope)
      true

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.owner?(scope)
      false
  """
  @spec owner?(t()) :: boolean()
  def owner?(%__MODULE__{cached_roles: cached_roles})
      when is_list(cached_roles) do
    roles = Role.system_roles()
    roles.owner in cached_roles
  end

  def owner?(_), do: false

  @doc """
  Checks if the user can access the admin AREA — the `/admin` shell entry gate.

  Returns true when the user holds the Admin or Owner role, OR has been
  explicitly granted any module-level permission (via `RolePermission`) — so a
  custom role (e.g. "Editor", "Support") holding at least one permission can
  enter the admin area.

  This is a COARSE entry gate only. It does NOT mean the user is a privileged
  operator: holding a single grant is enough. Which pages and actions are
  actually allowed is enforced per-view by `has_module_access?/2` / `can?/2`.
  For a "can do everything, like Owner" check use `holds_all_enabled_permissions?/1`
  or `superadmin?/1` instead — never this.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.can_access_admin_area?(scope)
      true

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.can_access_admin_area?(scope)
      false
  """
  @spec can_access_admin_area?(t()) :: boolean()
  def can_access_admin_area?(%__MODULE__{cached_roles: cached_roles, cached_permissions: perms})
      when is_list(cached_roles) do
    roles = Role.system_roles()

    roles.admin in cached_roles or roles.owner in cached_roles or
      (not is_nil(perms) and MapSet.size(perms) > 0)
  end

  def can_access_admin_area?(_), do: false

  @doc """
  Deprecated alias for `can_access_admin_area?/1`.

  The name misleads: it returns `true` for ANY permission holder, not just the
  Admin role. Call `can_access_admin_area?/1` instead.
  """
  @deprecated "Use can_access_admin_area?/1 — `admin?` is true for ANY permission holder, not just the Admin role."
  @spec admin?(t()) :: boolean()
  def admin?(scope), do: can_access_admin_area?(scope)

  @doc """
  Gets all roles for the user.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.user_roles(scope)
      ["Admin", "User"]

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.user_roles(scope)
      []
  """
  @spec user_roles(t()) :: [String.t()]
  def user_roles(%__MODULE__{cached_roles: cached_roles}) when is_list(cached_roles) do
    cached_roles
  end

  def user_roles(_), do: []

  @doc """
  Every role the user really holds, whatever role they are acting as.

  For the role switcher and for rules that must judge the user's REAL roles
  (e.g. "you cannot edit a role you hold"). Access decisions belong to the
  narrowed checks (`has_role?/2`, `can_access_admin_area?/1`, ...), never this.
  A scope built without `held_roles` answers with its `cached_roles`.
  """
  @spec held_roles(t() | nil) :: [String.t()]
  def held_roles(%__MODULE__{held_roles: held}) when is_list(held), do: held
  def held_roles(%__MODULE__{cached_roles: roles}) when is_list(roles), do: roles
  def held_roles(_), do: []

  @doc """
  The role the user is acting as (`%{uuid, name}`), or `nil` when the scope is
  not narrowed. See `PhoenixKit.Users.ActiveRole`.
  """
  @spec active_role(t() | nil) :: ActiveRole.role() | nil
  def active_role(%__MODULE__{active_role: %{uuid: _, name: _} = role}), do: role
  def active_role(_), do: nil

  @doc """
  Whether the scope is narrowed to an active role.
  """
  @spec narrowed?(t() | nil) :: boolean()
  def narrowed?(scope), do: active_role(scope) != nil

  @doc """
  The roles the user can switch between (`%{uuid, name}`), loaded with the
  scope so the switcher renders without a query. `[]` when not narrowed.
  """
  @spec switchable_roles(t() | nil) :: [ActiveRole.role()]
  def switchable_roles(%__MODULE__{switchable_roles: roles}) when is_list(roles), do: roles
  def switchable_roles(_), do: []

  @doc """
  Gets the user's full name.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{first_name: "John", last_name: "Doe"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.user_full_name(scope)
      "John Doe"

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.user_full_name(scope)
      nil
  """
  @spec user_full_name(t() | nil) :: String.t() | nil
  def user_full_name(%__MODULE__{user: %User{} = user}) do
    User.full_name(user)
  end

  def user_full_name(_), do: nil

  @doc """
  Checks if the user is active.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{is_active: true}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.user_active?(scope)
      true

      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(nil)
      iex> PhoenixKit.Users.Auth.Scope.user_active?(scope)
      false
  """
  @spec user_active?(t() | nil) :: boolean()
  def user_active?(%__MODULE__{user: %User{is_active: is_active}}) do
    is_active
  end

  def user_active?(_), do: false

  @doc """
  Converts scope to a map for debugging or logging purposes.

  ## Examples

      iex> user = %PhoenixKit.Users.Auth.User{uuid: "0193a5e4-0000-7000-8000-000000000001", email: "user@example.com"}
      iex> scope = PhoenixKit.Users.Auth.Scope.for_user(user)
      iex> PhoenixKit.Users.Auth.Scope.to_map(scope)
      %{
        authenticated?: true,
        user_uuid: "019...",
        user_email: "user@example.com",
        user_roles: ["Admin", "User"],
        owner?: false,
        admin?: true
      }
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = scope) do
    %{
      authenticated?: authenticated?(scope),
      user_uuid: user_uuid(scope),
      user_email: user_email(scope),
      user_full_name: user_full_name(scope),
      user_roles: user_roles(scope),
      held_roles: held_roles(scope),
      active_role: scope |> active_role() |> then(&(&1 && &1.name)),
      owner?: owner?(scope),
      # Map key kept as `admin?:` for back-compat; sourced from the non-deprecated fn.
      admin?: can_access_admin_area?(scope),
      user_active?: user_active?(scope)
    }
  end

  @doc """
  Checks if the user has access to a specific admin module/section.

  Looks up `module_key` in `cached_permissions`. Owner access works because
  `for_user/1` pre-populates all keys for owners; this function itself does
  not special-case roles.
  """
  @spec has_module_access?(t(), String.t()) :: boolean()
  def has_module_access?(%__MODULE__{cached_permissions: perms}, module_key)
      when is_binary(module_key) and not is_nil(perms) do
    holds?(perms, module_key)
  end

  def has_module_access?(_, _), do: false

  # Does this permission set grant `key`? True if the key is held directly, OR
  # the set holds the wildcard superadmin key (`"*"`) — a blanket grant that
  # covers every key, present and future. For a dotted sub-key, the caller is
  # responsible for also checking `base_held?/2` (a raw sub-key membership
  # without its base is an orphan). Centralised so has_module_access?/base_held?/
  # can? all honor superadmin identically.
  defp holds?(perms, key) do
    MapSet.member?(perms, key) or MapSet.member?(perms, @superadmin_key)
  end

  @doc """
  Whether the scope holds the wildcard superadmin key (`"*"`) — a blanket,
  drift-immune grant to every permission-gated FEATURE/VIEW. Owner holds it by
  construction; a host can grant it to a custom role to make that role
  Owner-equivalent for feature access with one grant, and unlike a "grant every
  current key" role it stays complete as new modules are added.

  Scope: feature/view access only. The Owner-only role-management safety rails
  (editing the Admin role, assigning Owner/Admin, the last-Owner guard) remain
  role-name-based by design and are NOT unlocked by `"*"`.
  """
  @spec superadmin?(t()) :: boolean()
  def superadmin?(%__MODULE__{cached_permissions: perms}) when not is_nil(perms) do
    MapSet.member?(perms, @superadmin_key)
  end

  def superadmin?(_), do: false

  @doc """
  Whether this scope holds EVERY currently-grantable permission key — i.e. it
  can reach everything the permission system exposes right now, exactly like
  Owner. Purely permission-based and role-AGNOSTIC: a custom role granted all
  permissions returns `true`, with no role-name special-casing.

  Compared against `Permissions.enabled_module_keys/0` (the grantable set the
  permissions matrix produces), NOT `all_module_keys/0`. Disabled modules
  expose no reachable admin surface and their keys can't be granted via the UI,
  so a grant-all custom role legitimately lacks them — including them would
  re-introduce the Owner-vs-custom asymmetry this is meant to remove (Owner's
  set is a superset that trivially satisfies the subset test either way). The
  `size > 0` guard stops an empty grantable set from making `subset?/2`
  vacuously true (a fail-open) for every scope; in practice the core and
  integration keys are a non-disableable floor, but the guard never rots.
  """
  @spec holds_all_enabled_permissions?(t()) :: boolean()
  def holds_all_enabled_permissions?(%__MODULE__{cached_permissions: perms} = scope)
      when not is_nil(perms) do
    # Compare against the OPERATOR baseline: every grantable key EXCEPT the ones
    # a default Admin is never auto-granted — the built-in opt-in key (personal
    # `integrations`) AND any `auto_grant_admin: false` custom key. Requiring
    # those would wrongly deny a default Admin (which holds every operator key
    # but not those opt-out extras) Owner-equivalence, locking it out of unmapped
    # admin views (the REG-1 regression, which an opt-out custom key otherwise
    # reopens). The `"*"` superadmin key satisfies this directly and
    # drift-immunely (it is deliberately NOT in `enabled_module_keys/0`).
    required =
      MapSet.difference(
        Permissions.enabled_module_keys(),
        MapSet.new(Permissions.admin_baseline_exclusions())
      )

    superadmin?(scope) or
      (MapSet.size(required) > 0 and MapSet.subset?(required, perms))
  end

  def holds_all_enabled_permissions?(_), do: false

  @doc """
  Checks whether the user holds a permission key AND that key is currently
  effective — the module behind it (or behind its parent, for sub-permission
  keys like `"calendar.view_others"`) is enabled.

  This is the check modules should use for fine-grained, in-page
  authorization. Unlike `has_module_access?/2` (a pure cache lookup used on
  hot paths where enablement is enforced separately at mount), `can?/2`
  consults live module-enablement state, so a scope snapshotted before a
  module was disabled cannot keep authorizing its actions.

  ## Examples

      Scope.can?(scope, "calendar.edit_others")
      Scope.can?(scope, "calendar")
  """
  @spec can?(t(), String.t()) :: boolean()
  def can?(%__MODULE__{cached_permissions: perms}, key)
      when is_binary(key) and not is_nil(perms) do
    holds?(perms, key) and base_held?(perms, key) and Permissions.feature_enabled?(key)
  end

  def can?(_, _), do: false

  # A sub-permission is only effective while its BASE is also held. The cascade
  # guarantees this in normal operation (granting a sub grants its base), so
  # this is defensive: it closes the orphan case where a sub row survives its
  # base being removed (e.g. a module/sub-key temporarily leaves the registry
  # and returns) — without it, `can?/2` would honor a dotted key whose base
  # the role no longer holds.
  defp base_held?(perms, key) do
    case Permissions.parent_key(key) do
      nil -> true
      base -> holds?(perms, base)
    end
  end

  @doc """
  Returns the set of module keys the user can access.
  """
  @spec accessible_modules(t()) :: MapSet.t()
  def accessible_modules(%__MODULE__{cached_permissions: perms} = scope) when not is_nil(perms) do
    # A superadmin ("*") can reach everything, so surface the full key set — the
    # same set Owner gets. Without this, a `"*"`-only role's set is just `{"*"}`,
    # and the callers that do raw membership (the Modules page's per-card
    # `key in @accessible_modules`, and the matrix/roles grantable ceiling) would
    # render an empty page / block every concrete-key grant for that role.
    if superadmin?(scope), do: MapSet.new(Permissions.all_module_keys()), else: perms
  end

  def accessible_modules(_), do: MapSet.new()

  @doc """
  Returns the number of module permissions the user has been granted.
  """
  @spec permission_count(t()) :: non_neg_integer()
  def permission_count(%__MODULE__{cached_permissions: perms}) when not is_nil(perms) do
    MapSet.size(perms)
  end

  def permission_count(_), do: 0

  @doc """
  Checks if the user has access to at least one of the given module keys.

  ## Examples

      Scope.has_any_module_access?(scope, ["billing", "shop"])
  """
  @spec has_any_module_access?(t(), [String.t()]) :: boolean()
  def has_any_module_access?(%__MODULE__{cached_permissions: perms}, keys)
      when is_list(keys) and not is_nil(perms) do
    Enum.any?(keys, &holds?(perms, &1))
  end

  def has_any_module_access?(_, _), do: false

  @doc """
  Checks if the user has access to all of the given module keys.

  ## Examples

      Scope.has_all_module_access?(scope, ["billing", "shop"])
  """
  @spec has_all_module_access?(t(), [String.t()]) :: boolean()
  def has_all_module_access?(%__MODULE__{cached_permissions: perms}, keys)
      when is_list(keys) and not is_nil(perms) do
    Enum.all?(keys, &holds?(perms, &1))
  end

  def has_all_module_access?(_, _), do: false

  @doc """
  Checks if the user holds the Owner or Admin system role.

  Unlike `admin?/1` which also returns true for custom roles with permissions,
  this strictly checks for the two built-in system roles.
  """
  @spec system_role?(t()) :: boolean()
  def system_role?(%__MODULE__{cached_roles: cached_roles}) when is_list(cached_roles) do
    roles = Role.system_roles()
    roles.owner in cached_roles or roles.admin in cached_roles
  end

  def system_role?(_), do: false
end
