defmodule PhoenixKit.Users.Sessions do
  @moduledoc """
  Context for managing user sessions in PhoenixKit.

  This module provides functions for listing, viewing, and managing active user sessions.
  It's primarily used by the admin interface to monitor and control user sessions.

  ## Functions

  - `list_active_sessions/0` - Get all currently active sessions
  - `list_user_sessions/1` - Get all active sessions for a specific user
  - `get_session_info/1` - Get detailed information about a specific session
  - `revoke_session/1` - Revoke a specific session token
  - `revoke_user_sessions/1` - Revoke all sessions for a specific user
  - `count_active_sessions/0` - Get total count of active sessions

  ## Session Information

  Each session includes:
  - User information (id, email, status)
  - Session creation time
  - Session token (first 8 chars for identification)
  - Session age and validity status
  """

  import Ecto.Query, warn: false
  require Logger
  alias PhoenixKit.Admin.Events
  alias PhoenixKit.RepoHelper, as: Repo
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.ActiveRole
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.{KnownDevice, User, UserToken}
  alias PhoenixKit.Users.Sessions.Revocation
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.TimeZone

  @session_validity_in_days 60

  @doc """
  Lists all currently active sessions with user information.

  Returns a list of maps containing session and user details.

  ## Examples

      iex> list_active_sessions()
      [
        %{
          token_uuid: "019b5704-3680-7b95-...",
          token_preview: "abc12345",
          user: %User{uuid: "019b5704-...", email: "user@example.com"},
          created_at: ~N[2024-01-01 12:00:00],
          expires_at: ~N[2024-03-02 12:00:00],
          is_current: false
        }
      ]

  """
  def list_active_sessions(scope \\ :active) do
    from(token in UserToken,
      where: token.context == "session",
      where: ^scope_condition(scope),
      join: user in User,
      on: token.user_uuid == user.uuid,
      select: %{
        token_uuid: token.uuid,
        token_preview: fragment("encode(substring(?, 1, 4), 'hex')", token.token),
        user_uuid: user.uuid,
        user_email:
          fragment(
            "CASE WHEN ? THEN ? ELSE ? END",
            user.managed_by_members,
            user.contact_email,
            user.email
          ),
        user_is_active: user.is_active,
        user_confirmed_at: user.confirmed_at,
        browser: token.browser,
        os: token.os,
        active_role_uuid: token.active_role_uuid,
        created_at: token.inserted_at,
        expires_at: fragment("? + interval '60 days'", token.inserted_at)
      },
      order_by: [desc: token.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(&format_session_info/1)
    |> with_active_roles()
  end

  @doc """
  One page of sessions for the admin list, filtered and paginated in SQL.

  Options:

    * `:scope` — `:active` (default), `:today` or `:expired`, as
      `list_active_sessions/1`
    * `:search` — case-insensitive match on the user's email or the token
      preview (the first 8 hex chars shown in the UI)
    * `:user_status` — `"all"` (default), `"active"`, `"inactive"`,
      `"confirmed"` or `"pending"`
    * `:page` / `:per_page` — defaults `1` / `20`

  Returns `%{sessions: [...], total_count: n, total_pages: n}`. The page is
  clamped into `[1, total_pages]` before the offset is applied, so a stale
  link past the end shows the last page rather than an empty one — mirror
  the returned `page` back into the assigns.
  """
  def list_sessions_paginated(opts \\ []) do
    scope = Keyword.get(opts, :scope, :active)
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)

    base =
      from(token in UserToken,
        where: token.context == "session",
        where: ^scope_condition(scope),
        join: user in User,
        on: token.user_uuid == user.uuid
      )
      |> filter_sessions_by_search(Keyword.get(opts, :search, ""))
      |> filter_sessions_by_user_status(Keyword.get(opts, :user_status, "all"))

    total_count = Repo.aggregate(base, :count, :uuid)
    total_pages = max(div(total_count + per_page - 1, per_page), 1)
    page = page |> max(1) |> min(total_pages)

    sessions =
      base
      |> select([token, user], %{
        token_uuid: token.uuid,
        token_preview: fragment("encode(substring(?, 1, 4), 'hex')", token.token),
        user_uuid: user.uuid,
        user_email:
          fragment(
            "CASE WHEN ? THEN ? ELSE ? END",
            user.managed_by_members,
            user.contact_email,
            user.email
          ),
        user_is_active: user.is_active,
        user_confirmed_at: user.confirmed_at,
        browser: token.browser,
        os: token.os,
        active_role_uuid: token.active_role_uuid,
        created_at: token.inserted_at,
        expires_at: fragment("? + interval '60 days'", token.inserted_at)
      })
      |> order_by([token], desc: token.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()
      |> Enum.map(&format_session_info/1)
      |> with_active_roles()

    %{sessions: sessions, total_count: total_count, total_pages: total_pages, page: page}
  end

  defp filter_sessions_by_search(query, search) when search in [nil, ""], do: query

  defp filter_sessions_by_search(query, search) do
    pattern = "%" <> escape_like(search) <> "%"

    where(
      query,
      [token, user],
      ilike(
        fragment(
          "CASE WHEN ? THEN ? ELSE ? END",
          user.managed_by_members,
          user.contact_email,
          user.email
        ),
        ^pattern
      ) or
        ilike(user.organization_name, ^pattern) or
        ilike(fragment("encode(substring(?, 1, 4), 'hex')", token.token), ^pattern)
    )
  end

  defp filter_sessions_by_user_status(query, "active"),
    do: where(query, [_token, user], user.is_active == true)

  defp filter_sessions_by_user_status(query, "inactive"),
    do: where(query, [_token, user], user.is_active == false)

  defp filter_sessions_by_user_status(query, "confirmed"),
    do: where(query, [_token, user], not is_nil(user.confirmed_at))

  defp filter_sessions_by_user_status(query, "pending"),
    do: where(query, [_token, user], is_nil(user.confirmed_at))

  defp filter_sessions_by_user_status(query, _all), do: query

  # `%` and `_` typed into the search box are literal characters, not wildcards.
  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  @doc """
  Lists all active sessions for a specific user.

  ## Examples

      iex> list_user_sessions(%User{uuid: "019b5704-..."})
      [%{token_uuid: "019b5704-...", user: %User{}, created_at: ~N[...], ...}]

  """
  def list_user_sessions(%User{uuid: user_uuid}) do
    from(token in UserToken,
      where: token.context == "session",
      where: token.user_uuid == ^user_uuid,
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      join: user in User,
      on: token.user_uuid == user.uuid,
      select: %{
        token_uuid: token.uuid,
        token_preview: fragment("encode(substring(?, 1, 4), 'hex')", token.token),
        user_uuid: user.uuid,
        user_email:
          fragment(
            "CASE WHEN ? THEN ? ELSE ? END",
            user.managed_by_members,
            user.contact_email,
            user.email
          ),
        user_is_active: user.is_active,
        user_confirmed_at: user.confirmed_at,
        browser: token.browser,
        os: token.os,
        active_role_uuid: token.active_role_uuid,
        created_at: token.inserted_at,
        expires_at: fragment("? + interval '60 days'", token.inserted_at)
      },
      order_by: [desc: token.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(&format_session_info/1)
    |> with_active_roles()
  end

  @doc """
  Lists a user's active sessions enriched with device info, for the
  self-service "Active Sessions" UI.

  Each session's `(ip_address, user_agent_hash)` is matched against the
  user's `KnownDevice` history to recover browser/OS/location/last-active
  (session tokens store only the hashed UA, never the raw string). Sessions
  predating fingerprinting — or from a device never recorded as "known" —
  degrade gracefully to an "Unknown device" with nil fields.

  `current_token` is the raw session token of the browser making the
  request (from the session's `"user_token"`); the matching row is flagged
  `is_current: true` so the UI can mark it and omit its "Sign out" button.
  """
  def list_user_device_sessions(%User{uuid: user_uuid}, current_token) do
    known = known_devices_by_fingerprint(user_uuid)
    current_uuid = current_session_uuid(user_uuid, current_token)
    acting = acting_sessions_by_parent(user_uuid)

    from(token in UserToken,
      where: token.context == "session",
      where: token.user_uuid == ^user_uuid,
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      select: %{
        token_uuid: token.uuid,
        user_uuid: token.user_uuid,
        ip_address: token.ip_address,
        user_agent_hash: token.user_agent_hash,
        browser: token.browser,
        os: token.os,
        active_role_uuid: token.active_role_uuid,
        created_at: token.inserted_at
      },
      order_by: [desc: token.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn s ->
      device = Map.get(known, {IpAddress.network(s.ip_address), s.user_agent_hash})

      %{
        token_uuid: s.token_uuid,
        user_uuid: s.user_uuid,
        ip_address: s.ip_address,
        # Device name comes from the token (V148), populated at login for every
        # session; fall back to a known-device row for pre-V148 sessions.
        browser: s.browser || (device && device.browser),
        os: s.os || (device && device.os),
        # Location stays known-device-only (recorded when new-login alerts run).
        location: device && device.location,
        last_active: (device && device.last_seen_at) || s.created_at,
        created_at: s.created_at,
        # The role this session acts as (`PhoenixKit.Users.ActiveRole`), nil
        # when not narrowed.
        active_role_uuid: s.active_role_uuid,
        active_role: nil,
        acting_organizations: Map.get(acting, s.token_uuid, []),
        is_current: s.token_uuid == current_uuid
      }
    end)
    |> with_active_roles()
  end

  defp acting_sessions_by_parent(person_uuid) do
    alias PhoenixKit.Users.OrganizationManager

    from(child in UserToken,
      join: root in UserToken,
      on: root.uuid == child.acting_session_uuid,
      join: org in User,
      on: org.uuid == child.user_uuid,
      join: grant in OrganizationManager,
      on: grant.uuid == child.organization_manager_uuid,
      where:
        child.context == "session" and root.context == "session" and
          root.user_uuid == ^person_uuid,
      where: org.managed_by_members and org.is_active,
      where: grant.organization_uuid == org.uuid and grant.user_uuid == ^person_uuid,
      where:
        root.inserted_at > ago(@session_validity_in_days, "day") and
          child.inserted_at > ago(@session_validity_in_days, "day"),
      select: %{
        parent: root.uuid,
        token_uuid: child.uuid,
        organization_uuid: org.uuid,
        name: org.organization_name
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.parent)
  end

  @doc """
  Revokes one of a user's *own* sessions by token uuid.

  Scoped to `user` so a user can never revoke another user's session by
  guessing a token uuid. Returns `:ok` or `{:error, :not_found}`.
  """
  def revoke_user_session(%User{uuid: user_uuid}, token_uuid) when is_binary(token_uuid) do
    case Revocation.delete_all(
           from(t in UserToken,
             where:
               t.uuid == ^token_uuid and t.user_uuid == ^user_uuid and t.context == "session",
             select: t.token
           )
         ) do
      {1, _revoked} ->
        Events.broadcast_session_revoked(token_uuid)
        :ok

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Revokes all of a user's sessions except the one identified by
  `current_token` (kept so the acting browser stays signed in). Returns the
  number revoked. With a nil token, revokes every session for the user.
  """
  def revoke_other_user_sessions(%User{} = user, nil), do: revoke_user_sessions(user)

  def revoke_other_user_sessions(%User{uuid: user_uuid}, current_token)
      when is_binary(current_token) do
    {count, _revoked} =
      Revocation.delete_all(
        from(t in UserToken,
          where:
            t.user_uuid == ^user_uuid and t.context == "session" and t.token != ^current_token,
          select: t.token
        )
      )

    if count > 0, do: Events.broadcast_user_sessions_revoked(user_uuid, count)
    count
  end

  @doc """
  Gets detailed information about a specific session by token ID.

  ## Examples

      iex> get_session_info("019b5704-3680-7b95-...")
      %{token_uuid: "019b5704-...", user: %User{}, created_at: ~N[...], ...}

      iex> get_session_info("019b5704-0000-0000-...")
      nil

  """
  def get_session_info(token_uuid) when is_binary(token_uuid) do
    from(token in UserToken,
      where: token.uuid == ^token_uuid,
      where: token.context == "session",
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      join: user in User,
      on: token.user_uuid == user.uuid,
      select: %{
        token_uuid: token.uuid,
        token_preview: fragment("encode(substring(?, 1, 4), 'hex')", token.token),
        user_uuid: user.uuid,
        user_email:
          fragment(
            "CASE WHEN ? THEN ? ELSE ? END",
            user.managed_by_members,
            user.contact_email,
            user.email
          ),
        user_is_active: user.is_active,
        user_confirmed_at: user.confirmed_at,
        active_role_uuid: token.active_role_uuid,
        created_at: token.inserted_at,
        expires_at: fragment("? + interval '60 days'", token.inserted_at)
      }
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      session_data ->
        session_data |> format_session_info() |> List.wrap() |> with_active_roles() |> hd()
    end
  end

  @doc """
  Whether `actor` may sign `target` out of their sessions.

  Your own sessions are yours to end. Anyone else's take the rank rule that
  changing their status takes (`PhoenixKit.Users.Auth.can_manage_user_status?/2`):
  the actor must hold Owner or Admin, an Admin's sessions need an Owner, and
  nobody but an Owner ends an Owner's sessions.

  Reuses preloaded roles for display. The revoke functions reload both role
  sets before deciding, so a stale dialog cannot authorize a mutation.
  """
  @spec can_revoke_sessions_of?(User.t(), User.t()) :: boolean()
  def can_revoke_sessions_of?(%User{uuid: uuid}, %User{uuid: uuid}), do: true

  def can_revoke_sessions_of?(%User{} = target, %User{} = actor),
    do: Auth.can_manage_user_status?(target, actor)

  def can_revoke_sessions_of?(_target, _actor), do: false

  @doc """
  Revokes a specific session by token ID.

  Returns :ok if successful, {:error, :not_found} if session doesn't exist.

  With `actor: %User{}` it is a revocation on that person's behalf:
  `{:error, :not_permitted}` unless `can_revoke_sessions_of?/2` allows it for
  the session's user. Without it (system callers) nothing is checked.

  ## Examples

      iex> revoke_session("019b5704-3680-7b95-...")
      :ok

      iex> revoke_session("019b5704-0000-0000-...")
      {:error, :not_found}

  """
  def revoke_session(token_uuid, opts \\ []) when is_binary(token_uuid) do
    with :ok <- authorize_session_revoke(token_uuid, Keyword.get(opts, :actor)) do
      do_revoke_session(token_uuid)
    end
  end

  defp authorize_session_revoke(_token_uuid, nil), do: :ok

  defp authorize_session_revoke(token_uuid, %User{} = actor) do
    owner =
      Repo.one(
        from(token in UserToken,
          join: user in User,
          on: token.user_uuid == user.uuid,
          where: token.uuid == ^token_uuid and token.context == "session",
          select: user
        )
      )

    cond do
      owner == nil -> {:error, :not_found}
      can_revoke_sessions_now?(owner, actor) -> :ok
      true -> {:error, :not_permitted}
    end
  end

  defp do_revoke_session(token_uuid) do
    case Revocation.delete_all(
           from(token in UserToken,
             where: token.uuid == ^token_uuid and token.context == "session",
             select: token.token
           )
         ) do
      {1, _revoked} ->
        # Broadcast session revocation event
        Events.broadcast_session_revoked(token_uuid)
        :ok

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc """
  Revokes every session of `user` that is **acting as** `role_uuid`
  (`PhoenixKit.Users.ActiveRole`) — called when that role is taken away from
  them, so the affected browser signs out instead of quietly continuing in
  another role. Sessions in another role, and sessions that never switched
  (`NULL`, the default role), are left alone. Returns the number revoked.
  """
  @spec revoke_user_sessions_in_role(User.t(), String.t()) :: non_neg_integer()
  def revoke_user_sessions_in_role(%User{uuid: user_uuid}, role_uuid) when is_binary(role_uuid) do
    {count, revoked} =
      Revocation.delete_all(
        from(token in UserToken,
          where:
            token.user_uuid == ^user_uuid and token.context == "session" and
              token.active_role_uuid == ^role_uuid,
          select: %{uuid: token.uuid, token: token.token}
        )
      )

    Enum.each(revoked, &Events.broadcast_session_revoked(&1.uuid))
    count
  end

  # Fills `:active_role` (the name of the role each session acts as, or nil)
  # from the sessions' stored uuids — one roles query for the whole list.
  defp with_active_roles(sessions) do
    names = ActiveRole.session_role_names(sessions)
    Enum.map(sessions, &%{&1 | active_role: Map.get(names, &1.token_uuid)})
  end

  @doc """
  Revokes all sessions for a specific user.

  Returns the number of sessions revoked. With `actor: %User{}` it is a
  revocation on that person's behalf: `{:error, :not_permitted}` (nothing
  revoked) unless `can_revoke_sessions_of?/2` allows it.

  ## Examples

      iex> revoke_user_sessions(%User{uuid: "019b5704-..."})
      3

  """
  def revoke_user_sessions(user, opts \\ [])

  def revoke_user_sessions(%User{} = user, opts) do
    case Keyword.get(opts, :actor) do
      nil ->
        do_revoke_user_sessions(user)

      actor ->
        if can_revoke_sessions_now?(user, actor),
          do: do_revoke_user_sessions(user),
          else: {:error, :not_permitted}
    end
  end

  # A dialog or a caller can hold preloaded roles from before a promotion or
  # revocation. The display predicate may use them; a revoke must read again.
  defp can_revoke_sessions_now?(%User{} = target, %User{} = actor) do
    [target, actor] = Repo.preload([target, actor], :roles, force: true)
    can_revoke_sessions_of?(target, actor)
  end

  defp can_revoke_sessions_now?(_target, _actor), do: false

  defp do_revoke_user_sessions(%User{uuid: user_uuid}) do
    {count, _revoked} =
      Revocation.delete_all(
        from(token in UserToken,
          where: token.user_uuid == ^user_uuid and token.context == "session",
          select: token.token
        )
      )

    # Broadcast user sessions revocation event
    if count > 0 do
      Events.broadcast_user_sessions_revoked(user_uuid, count)
    end

    count
  end

  @doc """
  Counts the total number of active sessions.

  ## Examples

      iex> count_active_sessions()
      15

  """
  def count_active_sessions do
    from(token in UserToken,
      where: token.context == "session",
      where: token.inserted_at > ago(@session_validity_in_days, "day"),
      select: count(token.uuid)
    )
    |> Repo.one()
  end

  # The three scopes the admin dashboard counts, so each card can link to the
  # list behind its own number. `:active` is the historical behaviour and the
  # default, and the predicates are the same expressions `get_session_stats/0`
  # counts with — a report that disagreed with the card above it would be worse
  # than no link.
  defp scope_condition(:active),
    do: dynamic([token], token.inserted_at > ago(@session_validity_in_days, "day"))

  defp scope_condition(:expired),
    do: dynamic([token], token.inserted_at <= ago(@session_validity_in_days, "day"))

  defp scope_condition(:today) do
    today_start = today_start()
    dynamic([token], token.inserted_at >= ^today_start)
  end

  defp scope_condition(_other), do: scope_condition(:active)

  # "Today" is the OPERATOR's day, not UTC's. Counting from UTC midnight is
  # invisible for most of the day and then wrong every evening: on
  # Europe/Tallinn (UTC+3) every sign-in between 21:00 and midnight local falls
  # into "yesterday", so a dashboard read at night shows 0 while someone is
  # signed in — which is exactly how this was found.
  defp today_start do
    "time_zone"
    |> Settings.get_setting_cached("0")
    |> TimeZone.day_start()
  end

  @doc """
  Gets session statistics including total, unique users, expired sessions etc.

  ## Examples

      iex> get_session_stats()
      %{
        total_active: 15,
        unique_users: 8,
        expired_sessions: 5,
        sessions_today: 3
      }

  """
  def get_session_stats do
    today_start = today_start()

    # Active sessions
    active_query =
      from(token in UserToken,
        where: token.context == "session",
        where: token.inserted_at > ago(@session_validity_in_days, "day")
      )

    total_active = Repo.aggregate(active_query, :count, :uuid)

    # NOT `Repo.aggregate(active_query, :count, :user_uuid, distinct: true)`.
    # `aggregate/4`'s last argument is REPO options (`:prefix`, `:timeout`, …),
    # never query modifiers — `Ecto.Repo.Queryable.query_for_aggregate/3` builds
    # the select from the field alone and never sees them. So `distinct: true`
    # was accepted and silently ignored, and this counted ROWS: every panel
    # reported "unique users" exactly equal to "active sessions". Reported from
    # a live install showing 29 unique users against 2 registered accounts.
    unique_users =
      active_query
      |> select([token], count(token.user_uuid, :distinct))
      |> Repo.one()

    # Sessions created today
    sessions_today =
      from(token in UserToken,
        where: token.context == "session",
        where: token.inserted_at >= ^today_start,
        select: count(token.uuid)
      )
      |> Repo.one()

    # Expired sessions (for cleanup reference)
    expired_sessions =
      from(token in UserToken,
        where: token.context == "session",
        where: token.inserted_at <= ago(@session_validity_in_days, "day"),
        select: count(token.uuid)
      )
      |> Repo.one()

    %{
      total_active: total_active,
      unique_users: unique_users,
      expired_sessions: expired_sessions,
      sessions_today: sessions_today,
      by_os: active_breakdown(active_query, :os),
      by_browser: active_breakdown(active_query, :browser)
    }
  end

  # `[{name, count}, ...]` for active sessions grouped by a token field
  # (`:os` / `:browser`), most common first. Nil names (pre-V148 sessions
  # or missing UA) collapse into "Unknown".
  defp active_breakdown(active_query, field) do
    from(t in active_query,
      group_by: field(t, ^field),
      select: {field(t, ^field), count(t.uuid)},
      order_by: [desc: count(t.uuid)]
    )
    |> Repo.all()
    |> Enum.map(fn {name, count} -> {name || "Unknown", count} end)
  end

  # Loads the user's known devices keyed by {network, user_agent_hash} for
  # O(1) enrichment of each session row. By network (`IpAddress.network/1`)
  # because login alerts record one row per IPv6 /64, not per address; where
  # older rows share a key, the most recently seen one wins.
  #
  # Degrades to no enrichment (empty map) if the known-devices table isn't
  # present yet — a parent app can deploy code carrying this feature before
  # running the V143/V147 migrations, and the sessions list (built from the
  # tokens table) must still render rather than crash the settings page.
  defp known_devices_by_fingerprint(user_uuid) do
    from(d in KnownDevice, where: d.user_uuid == ^user_uuid, order_by: [asc: d.last_seen_at])
    |> Repo.all()
    |> Map.new(fn d -> {{IpAddress.network(d.ip_address), d.user_agent_hash}, d} end)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "[PhoenixKit.Sessions] known-device enrichment skipped " <>
          "(run PhoenixKit migrations to V147?): #{inspect(error)}"
      )

      %{}
  end

  # Resolves the token uuid of the acting session (session tokens are stored
  # raw, so a direct byte match is correct). Nil token / no match → nil.
  defp current_session_uuid(_user_uuid, nil), do: nil

  defp current_session_uuid(user_uuid, token) when is_binary(token) do
    from(t in UserToken,
      where: t.context == "session" and t.user_uuid == ^user_uuid and t.token == ^token,
      select: t.uuid
    )
    |> Repo.one()
  end

  # Private helper to format session information
  defp format_session_info(session_data) do
    %{
      token_uuid: session_data.token_uuid,
      token_preview: session_data.token_preview,
      user_uuid: session_data.user_uuid,
      user_email: session_data.user_email,
      user_is_active: session_data.user_is_active,
      user_confirmed_at: session_data.user_confirmed_at,
      browser: Map.get(session_data, :browser),
      os: Map.get(session_data, :os),
      active_role_uuid: Map.get(session_data, :active_role_uuid),
      active_role: nil,
      created_at: session_data.created_at,
      expires_at: session_data.expires_at,
      age_in_days: calculate_age_in_days(session_data.created_at),
      is_expired: session_expired?(session_data.created_at)
    }
  end

  ## Disconnecting live sockets

  @doc """
  The topic a LiveView socket authenticated by `token` is subscribed to.

  Mirrors what the session plugs write to `:live_socket_id` at login.
  """
  @spec live_socket_id(binary()) :: String.t()
  def live_socket_id(token) when is_binary(token),
    do: "phoenix_kit_sessions:#{Base.url_encode64(token)}"

  @doc """
  Tells every LiveView socket authenticated by one of `tokens` to disconnect.

  Deleting a token row ends a session for the NEXT request; it does nothing to a
  socket that is already connected, which keeps its assigns — an authenticated
  scope included — and goes on serving events until it re-mounts. Revoking a
  session has to do both, so every path that drops session tokens calls this
  with the raw token values it deleted.

  Raw values, because the topic is derived from the token itself: once the row
  is gone there is nothing left to address the socket with. Postgres'
  `DELETE ... RETURNING` is how the callers keep them.
  """
  @spec disconnect_tokens([binary()]) :: :ok
  def disconnect_tokens(tokens) when is_list(tokens) do
    Enum.each(tokens, &disconnect(live_socket_id(&1)))
  end

  @doc """
  `disconnect_tokens/1`, but `delay_ms` later (default 5 s), from a task under
  `PhoenixKit.TaskSupervisor`.

  For the one case where a token that is already deleted must NOT be
  disconnected right away: the browser that just changed its password. Its
  settings LiveView still needs the socket for the `phx-trigger-action`
  re-login POST, and the re-login page has to finish loading before the old
  socket's reconnect-and-redirect could race the navigation. Once the new
  page is up the old topic is held only by leftovers — including any stolen
  copy of the same cookie — and those are what the delayed broadcast closes.
  """
  @spec disconnect_tokens_later([binary()], non_neg_integer()) :: :ok
  def disconnect_tokens_later(tokens, delay_ms \\ 5_000) when is_list(tokens) do
    case Process.whereis(PhoenixKit.TaskSupervisor) do
      nil ->
        disconnect_tokens(tokens)

      supervisor ->
        Task.Supervisor.start_child(supervisor, fn ->
          Process.sleep(delay_ms)
          disconnect_tokens(tokens)
        end)

        :ok
    end
  end

  @doc """
  Broadcasts LiveView's `"disconnect"` message on `live_socket_id`.
  """
  @spec disconnect(String.t()) :: :ok
  def disconnect(live_socket_id) when is_binary(live_socket_id) do
    case endpoint() do
      {:ok, endpoint} ->
        try do
          endpoint.broadcast(live_socket_id, "disconnect", %{})
          :ok
        rescue
          error ->
            Logger.warning("[PhoenixKit] Failed to broadcast disconnect: #{inspect(error)}")
            :ok
        end

      :error ->
        Logger.warning("[PhoenixKit] Could not find an endpoint to broadcast disconnect on")
        :ok
    end
  end

  # The HOST's endpoint, not PhoenixKit's own.
  #
  # A LiveView socket subscribes to its `live_socket_id` on the endpoint that
  # serves it, which in a host app is the host's. This resolved
  # `PhoenixKitWeb.Endpoint` unconditionally — a module that ships in the
  # library but that nothing here ever starts outside PhoenixKit's own dev and
  # test apps. Broadcasting on it raised "no :pubsub_server configured", the
  # rescue above swallowed it as a warning, and so every force-logout in every
  # host app quietly closed no tab at all.
  defp endpoint do
    case PhoenixKit.Config.get_parent_endpoint() do
      {:ok, endpoint} -> {:ok, endpoint}
      :error -> own_endpoint()
    end
  end

  defp own_endpoint do
    if Code.ensure_loaded?(PhoenixKitWeb.Endpoint) and
         function_exported?(PhoenixKitWeb.Endpoint, :broadcast, 3) do
      {:ok, PhoenixKitWeb.Endpoint}
    else
      :error
    end
  end

  defp calculate_age_in_days(created_at) do
    DateTime.diff(UtilsDate.utc_now(), created_at, :day)
  end

  defp session_expired?(created_at) do
    DateTime.diff(UtilsDate.utc_now(), created_at, :day) >= @session_validity_in_days
  end
end
