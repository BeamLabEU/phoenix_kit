defmodule PhoenixKit.Users.ActiveRole do
  @moduledoc """
  The role a session is currently *acting as*.

  By default a user's access is the union of every role they hold. With the
  role switcher on (`role_switcher_enabled`), a user holding two or more
  **switchable** roles acts as exactly one of them at a time, and their scope —
  roles and permissions alike — is narrowed to that role plus every
  **always-on** role they hold. An Admin who switches to "Seller" has no admin
  access at all until they switch back.

  ## Switchable and always-on roles

    * Owner and Admin are always switchable — otherwise narrowing could never
      take admin access away.
    * User is always on: it applies whichever role is active.
    * Custom roles are switchable unless listed in
      `role_switcher_always_on_roles` (comma-separated role uuids).

  ## Where the active role lives

  **On the session token** (`phoenix_kit_users_tokens.active_role_uuid`,
  V190), so it is per browser session: Admin on the laptop, Seller on the
  phone, a role of its own for an impersonation, a fresh start for a second
  multi-session account. `NULL` means the **default role** — the first
  switchable role the user holds in role order (`phoenix_kit_user_roles.
  position`: Owner, Admin, then the operator's order) — and nothing is written
  until the user switches.

  It reaches `PhoenixKit.Users.Auth.Scope.for_user/1` through the user's
  virtual field `active_role_uuid`, which only
  `PhoenixKit.Users.Auth.UserToken.verify_session_token_query/1` (or, for a
  session known by its token row id, `verify_session_token_uuid_query/1`) fills: every
  web path starts from a session token, so every scope build narrows without
  knowing about tokens. A user loaded any other way (by uuid, in a background
  job, in an admin list) has `nil` there and acts as their **default role** —
  the same rule as a session that never switched, and never wider than a
  session could be. Never copy the value anywhere else (a session key, an
  assign): the scope is rebuilt from the token in plugs, every LiveView mount
  and the role-change refresh.

  The stored value is never trusted on its own. `resolve/3` only ever returns a
  role the user holds and that is switchable right now, so the narrowed scope
  can never exceed the user's real grants. Nothing here writes on read.

  The functions taking a `t:config/0` are pure, so the rules are unit-testable
  without a database.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.ScopeNotifier

  @type role :: %{uuid: String.t(), name: String.t()}

  @type config :: %{enabled?: boolean(), always_on: [String.t()]}

  @doc """
  The switcher configuration, read from settings.

  Only the enabled flag is read while the feature is off.
  """
  @spec config() :: config()
  def config do
    if Settings.get_boolean_setting("role_switcher_enabled", false) do
      %{
        enabled?: true,
        always_on: parse_always_on(Settings.get_setting_cached("role_switcher_always_on_roles"))
      }
    else
      disabled_config()
    end
  end

  @doc false
  @spec disabled_config() :: config()
  def disabled_config, do: %{enabled?: false, always_on: []}

  @doc """
  Parses the `role_switcher_always_on_roles` setting: comma-separated role
  uuids, returned without duplicates. Anything that is not a string is `[]`.
  """
  @spec parse_always_on(term()) :: [String.t()]
  def parse_always_on(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_always_on(_), do: []

  @doc """
  Whether `role` is a mode the user can act as, rather than always on.
  """
  @spec switchable?(role(), config()) :: boolean()
  def switchable?(%{name: name, uuid: uuid}, config) do
    system = Role.system_roles()

    cond do
      name in [system.owner, system.admin] -> true
      name == system.user -> false
      true -> uuid not in config.always_on
    end
  end

  @doc """
  The held roles that are switchable, in the order given.
  """
  @spec switchable_roles([role()], config()) :: [role()]
  def switchable_roles(held, config), do: Enum.filter(held, &switchable?(&1, config))

  @doc """
  The role a session acts as, given the roles the user holds (in role order)
  and the uuid stored on the session. `nil` means no narrowing: the feature
  is off, or the user holds fewer than two switchable roles.

  A stored uuid naming a role that is not held, or not switchable, is ignored
  and the **default** applies: the first switchable role in role order. So is
  `nil` — a session that never switched.
  """
  @spec resolve([role()], String.t() | nil, config()) :: role() | nil
  def resolve(held, stored_uuid, %{enabled?: true} = config) when is_list(held) do
    case switchable_roles(held, config) do
      [default, _ | _] = candidates ->
        Enum.find(candidates, &(&1.uuid == stored_uuid)) || default

      _ ->
        nil
    end
  end

  def resolve(_held, _stored_uuid, _config), do: nil

  @doc """
  The roles in effect while acting as `active`: the active role plus every
  always-on role held. With no active role, every held role.
  """
  @spec effective_roles([role()], role() | nil, config()) :: [role()]
  def effective_roles(held, nil, _config), do: held

  def effective_roles(held, %{uuid: active_uuid}, config) do
    Enum.filter(held, &(&1.uuid == active_uuid or not switchable?(&1, config)))
  end

  @doc """
  The role uuid the current session stored, carried on the user loaded from
  that session's token, or `nil` (no session, or the session never switched).
  """
  @spec session_role_uuid(User.t()) :: String.t() | nil
  def session_role_uuid(%User{active_role_uuid: uuid}) when is_binary(uuid), do: uuid
  def session_role_uuid(%User{}), do: nil

  @doc false
  # Called by `Scope.for_user/1`. Returns the active role (or `nil`), the roles
  # in effect, and the switchable roles the switcher offers (`[]` when not
  # narrowed). A single held role can never yield two switchable candidates, so
  # the common case skips the settings reads entirely.
  @spec narrow(User.t(), [role()]) :: {role() | nil, [role()], [role()]}
  def narrow(%User{}, held) when length(held) < 2, do: {nil, held, []}

  def narrow(%User{} = user, held) do
    config = config()
    active = resolve(held, session_role_uuid(user), config)
    switchable = if active, do: switchable_roles(held, config), else: []
    {active, effective_roles(held, active, config), switchable}
  end

  @doc """
  The names of the roles in effect for `user`: the active role plus the
  always-on roles while narrowed, every held role otherwise.

  The same roles `Scope.for_user/1` puts in `cached_roles`, without loading
  permissions — for callers that only need names (account labels, the
  impersonation authority). Like `for_user/1`, honours the session role only
  when `user` was loaded from its session token.
  """
  @spec effective_role_names(User.t()) :: [String.t()]
  def effective_role_names(%User{} = user) do
    {_active, effective, _switchable} = narrow(user, Roles.get_user_role_records(user))
    Enum.map(effective, & &1.name)
  end

  @doc """
  The role in effect for each session in `sessions`, for the sessions lists.

  Takes maps with `:token_uuid`, `:user_uuid` and `:active_role_uuid` (what
  `PhoenixKit.Users.Sessions` selects) and returns `%{token_uuid => name}`
  with `nil` where the session is not narrowed — one roles query for the
  whole page, then the pure rules per row.
  """
  @spec session_role_names([map()]) :: %{optional(String.t()) => String.t() | nil}
  def session_role_names([]), do: %{}

  def session_role_names(sessions) when is_list(sessions) do
    config = config()

    held_by_user =
      if config.enabled?,
        do: sessions |> Enum.map(& &1.user_uuid) |> Roles.get_role_records_for_users(),
        else: %{}

    Map.new(sessions, fn session ->
      held = Map.get(held_by_user, session.user_uuid, [])
      active = resolve(held, session.active_role_uuid, config)
      {session.token_uuid, active && active.name}
    end)
  end

  @doc """
  Where the switcher is shown: `:menu` (the account dropdown, default) or
  `:header` (a header control from `sm` up, the account dropdown below it).
  """
  @spec location() :: :menu | :header
  def location, do: parse_location(Settings.get_setting_cached("role_switcher_location"))

  @doc "Parses `role_switcher_location`. Anything unrecognised is `:menu`."
  @spec parse_location(term()) :: :menu | :header
  def parse_location("header"), do: :header
  def parse_location(_), do: :menu

  @doc """
  Makes `role_uuid` the role the session identified by the raw session
  `token` acts as. `user` is that session's user, as loaded from the token.

  Refused unless the switcher is on and the role is one of the user's
  switchable roles — and there are at least two of those, or there is nothing
  to switch between. Switching to the role already in effect writes nothing.

  On a change the choice is stored on the session token, logged as
  `session.role_switched`, and broadcast through `ScopeNotifier`, so every
  open LiveView of this user rebuilds its scope — each from its own token, so
  only this session actually changes — and leaves pages the new role cannot
  reach. Other sessions of the same user, and the user's own sessions while
  someone impersonates them, are untouched.
  """
  @spec switch(User.t(), binary(), String.t()) ::
          {:ok, role()} | {:error, :disabled | :not_switchable | :not_found}
  def switch(%User{} = user, token, role_uuid) when is_binary(token) and is_binary(role_uuid) do
    config = config()
    held = Roles.get_user_role_records(user)
    candidates = switchable_roles(held, config)
    target = Enum.find(candidates, &(&1.uuid == role_uuid))
    current = resolve(held, session_role_uuid(user), config)

    cond do
      not config.enabled? -> {:error, :disabled}
      is_nil(target) or length(candidates) < 2 -> {:error, :not_switchable}
      current && current.uuid == target.uuid -> {:ok, target}
      true -> store_switch(user, token, current, target)
    end
  end

  defp store_switch(user, token, current, target) do
    query =
      from(t in UserToken,
        where: t.token == ^token and t.context == "session" and t.user_uuid == ^user.uuid
      )

    case RepoHelper.repo().update_all(query, set: [active_role_uuid: target.uuid]) do
      {1, _} ->
        log_switch(user, current, target)
        ScopeNotifier.broadcast_active_role_changed(user)
        {:ok, target}

      {0, _} ->
        {:error, :not_found}
    end
  end

  # The user is both actor and target, so `Activity.log/1` fans out no
  # notification.
  defp log_switch(user, from, to) do
    PhoenixKit.Activity.log(%{
      action: "session.role_switched",
      module: "users",
      mode: "auto",
      actor_uuid: user.uuid,
      resource_type: "user",
      resource_uuid: user.uuid,
      target_uuid: user.uuid,
      metadata: %{"from" => from && from.name, "to" => to.name},
      acting_user_uuid: user.acting_user_uuid
    })
  rescue
    _ -> :ok
  end
end
