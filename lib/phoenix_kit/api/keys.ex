defmodule PhoenixKit.API.Keys do
  @moduledoc """
  API keys: creating, verifying, revoking and rotating the bearer tokens of the
  admin API.

  A key belongs to a **user** (its owner) and carries a list of **scopes**
  (`"catalogue.products:write"`). What a request may actually do is the key's
  scopes filtered by the owner's permissions **right now**:

      effective scopes = key.scopes
                         that some enabled admin tool declares
                         and whose tool permission the owner holds

  The owner's permissions come from `Scope.for_user(user, narrow: false)` (the
  union of all roles, ignoring the role switcher) and `Scope.can?/2`, on every
  request. Removing a role from the owner, blocking or deleting the owner
  therefore takes effect on the next request, whatever the 60 second key row
  cache still holds (`PhoenixKit.API.Keys.Cache`). A scope whose module is
  disabled stays on the key but grants nothing.

  ## Who may create a key

  - the creator holds the `api` permission;
  - the owner is the creator, or a **service user** (`api_only`) they created
    (an Owner may use any) whose roles' permissions are a subset of the creator's;
  - every scope is one the owner could use (`allowed_scopes_for/1`).

  Authorization failures are atoms (`:forbidden`, `:owner_not_allowed`,
  `:owner_inactive`, `:invalid_scopes`; for personal keys also `:impersonated`,
  `:impersonation_unknown`, `:personal_key_limit`, `:scopes_not_narrowing` and, on a
  request, `:personal_keys_not_allowed`); validation failures are changesets.

  ## Personal keys

  A **personal** key (`personal = true`, V226) is a person's own key, made through
  `create_personal_key/3` (the "My API keys" page) by a holder of `api_personal_keys` or
  `api`. Nothing else sets the flag: `create_key/3` never does, whatever its attributes
  say, so every key made on Settings -> API, and every key made before V226, is not
  personal and behaves exactly as described above. A personal key:

  - is owned and created by the same person, never a service user;
  - must expire, no later than the end of the UTC day
    `PhoenixKit.API.PersonalKeysConfig.max_days/0` days from today, and cannot need
    approval (nobody but an Owner could decide, and the owner may not see the queue);
  - counts towards `PhoenixKit.API.PersonalKeysConfig.max_count/0` live personal keys per
    person (a key in the grace period of a rotation included), so a person never has more.
    A creation, and a rotation with a grace period (`rotate/4`), are checked under one
    advisory lock per person; a rotation without a grace period replaces the key one for
    one and is always allowed;
  - works only while its owner holds `api_personal_keys` or `api` (`Scope.for_user/2`,
    `narrow: false`). The check is one private owner lookup that `active_owner/1` and
    `verify/2` both use (so `active?/1` and `Confirm.live_actor/1` too), so taking the
    permission from a role stops the key on the next request; giving it back revives it;
  - is managed (rotated, its scopes edited) by its owner alone: `can_manage?/2`. An Owner
    may revoke someone else's personal key (`can_revoke?/2`) and remove scopes from it
    (`update_scopes/3`, `:scopes_not_narrowing` for anything else), never rotate it: a new
    token acting as a person goes to nobody but that person;
  - is created and rotated only outside a borrowed session: both take
    `impersonated: boolean` with no default (`:impersonation_unknown` without it,
    `:impersonated` when true), which the page reads from the session
    (`PhoenixKitWeb.Users.MultiSession.impersonated?/1`).

  A rotation of a personal key gives the new key the latest expiry allowed now
  (`PersonalKeysConfig.latest_expiry/0`), not the old key's.

  ## Token

  `pk_<8 hex>_<43 base64url>` (see `PhoenixKit.API.Keys.Token`). The token is
  returned once, by `create_key/3`, `create_personal_key/3`, `rotate/3` and `rotate/4`;
  only a SHA-256 of its secret is stored.

  ## Revocation and rotation

  `revoked_at` in the past means revoked. A `revoked_at` **in the future** is a
  scheduled revocation: the key works until then. `rotate/3` uses it to keep the
  old key alive for a grace period.

  `rotate/4` (`rotate/3` is its form without options) takes the person's scope and
  checks it on the locked row: the person must be able to manage the key
  (`can_manage?/2`) and, when the owner is a service user, must still hold every
  permission that service user holds (the rule of `create_key/3`), so a demoted
  creator cannot mint a token beyond their own rights. The new token acts as the
  key's owner. When an Owner rotates the key of a regular user, the token they receive
  therefore acts as that user; this is intended for keys made on Settings -> API. A
  personal key is never rotated by anyone but its owner (see "Personal keys").

  `revoke/2` is different: it takes a bare actor uuid and does not authorize.
  The caller decides with `can_revoke?/2` first (`can_manage?/2`, plus an Owner for a
  personal key; the Settings page finds the key through `list_keys/1`).

  ## Editing scopes

  `update_scopes/3` replaces the scope list of a live key. The editor must be
  able to manage the key, and every new scope must be one the key's **owner**
  could be given (`allowed_scopes_for/1`). When the editor is not the owner, a new
  scope must also be one the editor holds themselves (the permissions of its
  tools): a creator who was demoted, or a service user whose roles grew, cannot
  widen the key beyond the editor's own rights. Scopes already on the key may stay
  or go whoever the editor is. The cached row is dropped, so the next request
  already sees the new list.

  Scopes the owner cannot use right now (module switched off, tool hidden,
  permission lost, owner blocked or deleted) are not the editor's to change: they
  are merged back into the saved list and stay on the key, granting nothing until
  the owner can use them again. Authorization and validation run on the locked,
  re-read row, never on the struct the caller holds.

  Create, revoke, rotate and scope edits are written to `PhoenixKit.Activity`
  (module `api`, `permanent: true`).
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Keys.Cache
  alias PhoenixKit.API.Keys.CIDR
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.Keys.Token
  alias PhoenixKit.API.PersonalKeysConfig
  alias PhoenixKit.API.Registry, as: ToolRegistry
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  # Compared against when the prefix is unknown, so that a wrong prefix and a
  # wrong secret take the same time.
  @unknown_key_hash :crypto.hash(:sha256, "phoenix_kit_api_unknown_key")
  @max_name_length 100
  # Either one lets a person keep personal keys (and lets those keys work).
  @personal_rights ["api_personal_keys", "api"]
  # Every entry is parsed again on each request that presents the key.
  @max_allowed_ips 100

  # --- Creating ----------------------------------------------------------

  @doc """
  Creates a key for `owner` on behalf of the person behind `creator_scope`.

  `attrs` takes `name` (required), `scopes`, `requires_approval`, `allowed_ips`
  (CIDR blocks or bare addresses; stored in canonical form) and `expires_at`,
  with atom or string keys (not mixed).

  Returns the stored key and the token, which exists nowhere else and is never
  shown again.
  """
  @spec create_key(User.t(), Scope.t(), map()) ::
          {:ok, Key.t(), String.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_key(%User{} = owner, %Scope{} = creator_scope, attrs) when is_map(attrs) do
    repo().transaction(fn ->
      with :ok <- lock_mint_users(owner.uuid, creator_scope),
           {:ok, key, token} <- insert_key(owner, creator_scope, attrs) do
        {key, token}
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> case do
      {:ok, {key, token}} ->
        log_created(key, creator_scope.user.uuid)
        {:ok, key, token}

      {:error, _} = error ->
        error
    end
  end

  defp insert_key(owner, creator_scope, attrs) do
    {prefix, token, secret_hash} = Token.generate()

    with :ok <- authorize_creator(creator_scope),
         {:ok, owner} <- authorize_owner(owner, creator_scope),
         {:ok, changeset} <- valid(key_changeset(attrs, owner, creator_scope.user.uuid)),
         :ok <- authorize_scopes(owner, changeset),
         {:ok, key} <-
           changeset
           |> Ecto.Changeset.put_change(:prefix, prefix)
           |> Ecto.Changeset.put_change(:secret_hash, secret_hash)
           |> Ecto.Changeset.unique_constraint(:prefix)
           |> repo().insert() do
      {:ok, key, token}
    end
  end

  # Minting (creation AND rotation) locks the owner before keys. Conversion holds
  # that same user lock while draining keys; a concurrent mint must finish
  # before the drain's snapshot, or see the converted policy afterward.
  defp lock_mint_users(owner_uuid, %Scope{user: %User{uuid: creator_uuid}}) do
    owner = repo().one(from(u in User, where: u.uuid in ^[owner_uuid], lock: "FOR NO KEY UPDATE"))
    creator = if owner_uuid == creator_uuid, do: owner, else: repo().get(User, creator_uuid)

    case creator do
      %User{managed_by_members: false, is_active: true} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp lock_mint_users(_owner, _scope), do: {:error, :forbidden}

  defp authorize_creator(%Scope{user: %User{managed_by_members: true}}),
    do: {:error, :forbidden}

  defp authorize_creator(%Scope{user: %User{}} = scope) do
    if Scope.can?(scope, "api"), do: :ok, else: {:error, :forbidden}
  end

  defp authorize_creator(_scope), do: {:error, :forbidden}

  # The owner is read again: the caller's struct may be stale, and `api_only`
  # decides what the creator is allowed to hand a key to.
  defp authorize_owner(%User{uuid: uuid}, %Scope{} = creator_scope) do
    case uuid |> Auth.get_user() |> Auth.ensure_active_user() do
      %User{} = owner -> owner_allowed(owner, creator_scope)
      nil -> {:error, :owner_inactive}
    end
  end

  defp owner_allowed(%User{managed_by_members: true}, _scope), do: {:error, :owner_not_allowed}

  defp owner_allowed(%User{uuid: uuid} = owner, %Scope{user: %User{uuid: uuid}}), do: {:ok, owner}

  # A service user is the creator's to hand keys to (an Owner may use any), the same set
  # `ServiceUsers.list/1` shows; and the creator must hold everything it holds.
  defp owner_allowed(%User{api_only: true} = owner, creator_scope) do
    owner_permissions = owner |> scope_of() |> Scope.accessible_modules() |> MapSet.to_list()

    if service_user_of?(owner, creator_scope) and
         Scope.has_all_module_access?(creator_scope, owner_permissions),
       do: {:ok, owner},
       else: {:error, :owner_not_allowed}
  end

  defp owner_allowed(_owner, _creator_scope), do: {:error, :owner_not_allowed}

  defp service_user_of?(
         %User{created_by_uuid: created_by},
         %Scope{user: %User{uuid: uuid}} = scope
       ),
       do: Scope.owner?(scope) or (is_binary(created_by) and created_by == uuid)

  defp service_user_of?(_owner, _scope), do: false

  defp authorize_scopes(owner, changeset) do
    requested = Ecto.Changeset.get_field(changeset, :scopes) || []
    allowed = owner |> allowed_scopes_for() |> MapSet.new()

    if Enum.all?(requested, &MapSet.member?(allowed, &1)),
      do: :ok,
      else: {:error, :invalid_scopes}
  end

  # `personal` is not cast: only `create_personal_key/3` sets it, on the server.
  defp key_changeset(attrs, owner, creator_uuid) do
    attrs
    |> base_changeset()
    |> Ecto.Changeset.put_change(:user_uuid, owner.uuid)
    |> Ecto.Changeset.put_change(:created_by_uuid, creator_uuid)
  end

  defp base_changeset(attrs) do
    %Key{}
    |> Ecto.Changeset.cast(attrs, [:name, :scopes, :requires_approval, :allowed_ips, :expires_at])
    |> Ecto.Changeset.validate_required([:name])
    |> Ecto.Changeset.validate_length(:name, max: @max_name_length)
    |> drop_nil_changes([:scopes, :allowed_ips, :requires_approval])
    |> normalize_scopes()
    |> normalize_allowed_ips()
    |> Ecto.Changeset.validate_length(:allowed_ips, max: @max_allowed_ips)
    |> validate_future_expiry()
  end

  # An explicit nil (JSON `null`, an empty form value) means "the default".
  defp drop_nil_changes(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case Ecto.Changeset.fetch_change(acc, field) do
        {:ok, nil} -> Ecto.Changeset.delete_change(acc, field)
        _ -> acc
      end
    end)
  end

  defp normalize_scopes(changeset) do
    Ecto.Changeset.update_change(changeset, :scopes, &clean_scopes/1)
  end

  defp clean_scopes(scopes) do
    scopes |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp normalize_allowed_ips(changeset) do
    case Ecto.Changeset.fetch_change(changeset, :allowed_ips) do
      {:ok, entries} -> put_normalized_ips(changeset, CIDR.normalize_all(entries))
      :error -> changeset
    end
  end

  defp put_normalized_ips(changeset, {:ok, normalized}),
    do: Ecto.Changeset.put_change(changeset, :allowed_ips, normalized)

  defp put_normalized_ips(changeset, {:error, invalid}) do
    Ecto.Changeset.add_error(
      changeset,
      :allowed_ips,
      "is not an IP address or CIDR block: %{value}",
      value: Enum.join(invalid, ", ")
    )
  end

  defp validate_future_expiry(changeset) do
    Ecto.Changeset.validate_change(changeset, :expires_at, fn :expires_at, expires_at ->
      if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
        do: [],
        else: [expires_at: "must be in the future"]
    end)
  end

  defp valid(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp valid(%Ecto.Changeset{} = changeset), do: {:error, changeset}

  # --- Personal keys -----------------------------------------------------

  @doc """
  Creates a **personal** key for the person behind `creator_scope`, who is also its
  owner (see "Personal keys" in the moduledoc).

  `creator_scope` should be the person's full scope read again for this event
  (`PhoenixKit.API.Access.fresh_scope/2`); the person is read again here as well and must
  hold `api_personal_keys` or `api` in both. `attrs` takes `name` (required), `scopes`,
  `allowed_ips` and `expires_at` (required, at most `PersonalKeysConfig.latest_expiry/0`),
  as `create_key/3`; `requires_approval: true` is a changeset error, not dropped.

  `opts` must say `impersonated: true | false` (no default): a missing or non-boolean value
  is `{:error, :impersonation_unknown}`, `true` is `{:error, :impersonated}`. Other
  failures: `:forbidden` (neither permission), `:owner_inactive`, `:owner_not_allowed`
  (a service user), `:invalid_scopes`, `:personal_key_limit` (the person already has
  `PersonalKeysConfig.max_count/0` live personal keys), or a changeset.
  """
  @spec create_personal_key(Scope.t() | nil, map(), keyword()) ::
          {:ok, Key.t(), String.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_personal_key(%Scope{user: %User{}} = creator_scope, attrs, opts)
      when is_map(attrs) do
    {prefix, token, secret_hash} = Token.generate()

    with :ok <- check_not_impersonated(opts),
         :ok <- authorize_personal(creator_scope),
         {:ok, owner} <- personal_owner(creator_scope),
         {:ok, changeset} <- valid(personal_changeset(attrs, owner)),
         :ok <- authorize_scopes(owner, changeset),
         {:ok, key} <- insert_personal(changeset, owner, prefix, secret_hash) do
      log_created(key, owner.uuid)
      {:ok, key, token}
    end
  end

  def create_personal_key(_creator_scope, _attrs, opts) do
    with :ok <- check_not_impersonated(opts), do: {:error, :forbidden}
  end

  # The page reads the flag from the session; a caller that forgets to pass it is refused
  # rather than taken for an unborrowed session.
  defp check_not_impersonated(opts) when is_list(opts) do
    case List.keyfind(opts, :impersonated, 0) do
      {:impersonated, false} -> :ok
      {:impersonated, true} -> {:error, :impersonated}
      _missing_or_not_boolean -> {:error, :impersonation_unknown}
    end
  end

  defp check_not_impersonated(_opts), do: {:error, :impersonation_unknown}

  defp authorize_personal(scope),
    do: if(holds_personal_right?(scope), do: :ok, else: {:error, :forbidden})

  defp holds_personal_right?(scope), do: Enum.any?(@personal_rights, &Scope.can?(scope, &1))

  # The person is read again: blocked or deleted since the scope was built is
  # `:owner_inactive`, and the rights are checked once more on a scope built now.
  # The owner lookup of a request (`active_user/1`): a person who is not confirmed while
  # confirmation is required would get a key that never works.
  defp personal_owner(%Scope{user: %User{uuid: uuid}}) do
    case active_user(%Key{user_uuid: uuid}) do
      {:ok, %User{api_only: true}} ->
        {:error, :owner_not_allowed}

      {:ok, owner} ->
        if owner |> scope_of() |> holds_personal_right?(),
          do: {:ok, owner},
          else: {:error, :forbidden}

      {:error, _reason} = error ->
        error
    end
  end

  defp personal_changeset(attrs, owner) do
    attrs
    |> base_changeset()
    |> Ecto.Changeset.validate_required([:expires_at])
    |> validate_personal_expiry()
    |> Ecto.Changeset.validate_change(:requires_approval, fn :requires_approval, value ->
      if value == true,
        do: [requires_approval: "is not available for a personal key"],
        else: []
    end)
    |> Ecto.Changeset.put_change(:requires_approval, false)
    |> Ecto.Changeset.put_change(:personal, true)
    |> Ecto.Changeset.put_change(:user_uuid, owner.uuid)
    |> Ecto.Changeset.put_change(:created_by_uuid, owner.uuid)
  end

  defp validate_personal_expiry(changeset) do
    latest = PersonalKeysConfig.latest_expiry()

    Ecto.Changeset.validate_change(changeset, :expires_at, fn :expires_at, expires_at ->
      if DateTime.compare(expires_at, latest) == :gt,
        do: [expires_at: {"must be no later than %{date}", date: Date.to_iso8601(latest)}],
        else: []
    end)
  end

  # The count and the insert run under one advisory lock per person, so simultaneous
  # creations cannot pass the cap together.
  defp insert_personal(changeset, owner, prefix, secret_hash) do
    repo().transaction(fn ->
      scope = %Scope{user: owner}

      with :ok <- lock_mint_users(owner.uuid, scope),
           {:ok, _owner} <- personal_owner(scope) do
        :ok
      else
        {:error, reason} -> repo().rollback(reason)
      end

      lock_personal_keys(owner.uuid)

      if live_personal_key_count(owner.uuid) >= PersonalKeysConfig.max_count() do
        repo().rollback(:personal_key_limit)
      else
        changeset
        |> Ecto.Changeset.put_change(:prefix, prefix)
        |> Ecto.Changeset.put_change(:secret_hash, secret_hash)
        |> Ecto.Changeset.unique_constraint(:prefix)
        |> repo().insert()
        |> case do
          {:ok, key} -> key
          {:error, changeset} -> repo().rollback(changeset)
        end
      end
    end)
  end

  defp lock_personal_keys(owner_uuid) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "api_personal_keys:" <> owner_uuid
    ])
  end

  # Neither revoked nor expired yet; a key in the grace period of a rotation is alive.
  defp live_personal_key_count(owner_uuid) do
    now = DateTime.utc_now()

    repo().aggregate(
      from(k in Key,
        where:
          k.user_uuid == ^owner_uuid and k.personal == true and
            (is_nil(k.revoked_at) or k.revoked_at > ^now) and
            (is_nil(k.expires_at) or k.expires_at > ^now)
      ),
      :count
    )
  end

  @doc """
  Whether the person behind `scope` already has `PersonalKeysConfig.max_count/0` live
  personal keys (a key in a grace period included): then a new key, and a rotation with a
  grace period, are refused with `:personal_key_limit`. For the pages, which offer a grace
  period of 0 in that case; the decision itself is made again under the lock.
  """
  @spec personal_keys_full?(Scope.t() | nil) :: boolean()
  def personal_keys_full?(%Scope{user: %User{uuid: user_uuid}}),
    do: live_personal_key_count(user_uuid) >= PersonalKeysConfig.max_count()

  def personal_keys_full?(_scope), do: false

  @doc """
  The personal keys of the person behind `scope` (`personal = true` and owned by them),
  newest first; `[]` unless they hold `api_personal_keys` or `api`. An Owner sees only
  their own here (`list_keys/1` lists everyone's).
  """
  @spec list_personal_keys(Scope.t() | nil) :: [Key.t()]
  def list_personal_keys(%Scope{user: %User{uuid: user_uuid}} = scope) do
    if holds_personal_right?(scope) do
      repo().all(
        from(k in Key,
          where: k.personal == true and k.user_uuid == ^user_uuid,
          order_by: [desc: k.inserted_at, desc: k.uuid]
        )
      )
    else
      []
    end
  end

  def list_personal_keys(_scope), do: []

  # --- Allowed scopes ----------------------------------------------------

  @doc """
  Every scope the owner could be given: a scope of the enabled admin tools, provided the
  owner holds the permission of every one of those tools that declares it.
  """
  @spec allowed_scopes_for(User.t()) :: [String.t()]
  def allowed_scopes_for(%User{} = owner) do
    owner |> held_scopes() |> MapSet.to_list() |> Enum.sort()
  end

  # A scope is held when the owner holds the permission of EVERY enabled admin tool that
  # declares it. The Executor checks a key's tool against `actor.scopes` only (for a live
  # session it also checks the tool's own permission, `Scope.can?/2`), so a scope that
  # two tools share with different permissions must not reach an owner who holds only one of
  # them: that would let the key call the tool whose permission the owner lacks. A scope no
  # enabled tool declares (its module is disabled, or the tool is hidden) is never held.
  defp held_scopes(owner), do: owner |> scope_of() |> held_scope_set()

  @doc """
  The scopes `scope` holds: those of the enabled admin tools, provided `scope` holds the
  permission of every one of those tools that declares it (the rule of
  `allowed_scopes_for/1`), sorted.

  `allowed_scopes_for/1` asks it of the owner's full scope (`narrow: false`); a caller
  acting through a live session (`PhoenixKit.API.Executor.execute_as/5`) asks it of the
  session's scope, which is narrowed to the session's active role.
  """
  @spec held_scopes_of(Scope.t()) :: [String.t()]
  def held_scopes_of(%Scope{} = scope),
    do: scope |> held_scope_set() |> MapSet.to_list() |> Enum.sort()

  defp held_scope_set(%Scope{} = scope) do
    ToolRegistry.all_tools()
    |> Enum.filter(&scoped_admin_tool?/1)
    |> Enum.group_by(& &1.scope, & &1.permission)
    |> Enum.filter(fn {_scope, permissions} -> Enum.all?(permissions, &Scope.can?(scope, &1)) end)
    |> MapSet.new(fn {scope_name, _permissions} -> scope_name end)
  end

  @doc """
  The scopes `editor_scope` may hand to `owner`'s keys: `allowed_scopes_for/1` of
  the owner, narrowed to the scopes whose tool permissions the editor holds too.
  Editing one's own keys needs no narrowing (the owner is the editor).
  """
  @spec allowed_scopes_for(User.t(), Scope.t()) :: [String.t()]
  def allowed_scopes_for(%User{} = owner, %Scope{} = editor_scope) do
    owner_scopes = allowed_scopes_for(owner)

    if editor?(editor_scope, owner.uuid) do
      owner_scopes
    else
      held = held_scope_set(editor_scope)
      Enum.filter(owner_scopes, &MapSet.member?(held, &1))
    end
  end

  defp editor?(%Scope{user: %User{uuid: uuid}}, uuid), do: true
  defp editor?(_scope, _owner_uuid), do: false

  defp scoped_admin_tool?(%{audience: :admin, scope: scope, permission: permission})
       when is_binary(scope) and is_binary(permission),
       do: true

  defp scoped_admin_tool?(_tool), do: false

  defp scope_of(%User{} = owner), do: Scope.for_user(owner, narrow: false)

  # --- Verifying ---------------------------------------------------------

  @doc """
  Verifies a bearer token presented from `ip`.

  Checks, in order: the token's shape and secret, revocation, expiry, the IP
  allow-list, that the owner exists and is active, and, for a personal key, that the
  owner holds `api_personal_keys` or `api` (`:personal_keys_not_allowed`; the API answers
  the same 401 for every reason). On success returns an
  `Actor` whose `scopes` are the key's **effective** scopes for this request.

  Never raises on bad input, whatever its type (a missing header arrives as
  `nil`); a malformed token is `:invalid_token`, the same answer as an unknown
  key, so the response does not tell the two apart.

  The returned `Actor` already carries the **effective** scopes of this request
  (the key's scopes filtered by the owner's live permissions and by the tools
  that are enabled right now), and `verify/2` itself writes `last_used_at` /
  `last_used_ip`. The Executor therefore trusts `actor.scopes` and does
  not call `effective_scopes/1` again for the same request: the owner lookup, the
  `Scope.for_user/2` build and the tool-registry scan happen once, here.
  """
  @spec verify(term(), String.t() | nil) ::
          {:ok, Actor.t()}
          | {:error,
             :invalid_token
             | :revoked
             | :expired
             | :ip_not_allowed
             | :owner_inactive
             | :personal_keys_not_allowed}
  def verify(token, ip) do
    with {:ok, prefix, presented_hash} <- Token.parse(token),
         {:ok, key} <- find_key(prefix, presented_hash),
         :ok <- check_alive(key),
         :ok <- check_ip(key, ip),
         {:ok, owner, scope} <- checked_owner(key) do
      touch_last_used(key, ip)
      {:ok, build_actor(key, owner, ip, scope || scope_of(owner))}
    else
      :error -> {:error, :invalid_token}
      {:error, _reason} = error -> error
    end
  end

  defp find_key(prefix, presented_hash) do
    key = Cache.fetch(prefix, fn -> repo().get_by(Key, prefix: prefix) end)
    stored_hash = if key, do: key.secret_hash, else: @unknown_key_hash

    if Token.matches?(presented_hash, stored_hash) and key != nil,
      do: {:ok, key},
      else: {:error, :invalid_token}
  end

  defp check_alive(%Key{} = key) do
    case dead_reason(key) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp check_not_revoked(%Key{revoked_at: revoked_at}),
    do: if(reached?(revoked_at), do: {:error, :revoked}, else: :ok)

  defp reached?(nil), do: false
  defp reached?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp check_ip(%Key{allowed_ips: []}, _ip), do: :ok

  defp check_ip(%Key{allowed_ips: allowed}, ip),
    do: if(CIDR.allowed?(allowed, ip), do: :ok, else: {:error, :ip_not_allowed})

  @doc """
  The active owner of a key, `{:error, :owner_inactive}` when the user is gone, blocked or
  not confirmed, and `{:error, :personal_keys_not_allowed}` for a personal key whose owner
  holds neither `api_personal_keys` nor `api` right now. Behind `active?/1` and
  `Confirm.live_actor/1`. `verify/2` goes through the same private check
  (`checked_owner/1`), so the two cannot disagree.
  """
  @spec active_owner(Key.t()) ::
          {:ok, User.t()} | {:error, :owner_inactive | :personal_keys_not_allowed}
  def active_owner(%Key{} = key) do
    with {:ok, owner, _scope} <- checked_owner(key), do: {:ok, owner}
  end

  # The one owner check of a key: the owner is active and, for a personal key, holds one
  # of the personal rights now. Returns the owner's full scope when the check had to build
  # it (a personal key), so `verify/2` does not build it twice; `nil` otherwise. A key that
  # is not personal needs no permission here (its scopes are filtered by the owner's
  # rights, as before).
  defp checked_owner(%Key{} = key) do
    with {:ok, owner} <- active_user(key), do: check_personal_right(key, owner)
  end

  defp check_personal_right(%Key{personal: true}, owner) do
    scope = scope_of(owner)

    if holds_personal_right?(scope),
      do: {:ok, owner, scope},
      else: {:error, :personal_keys_not_allowed}
  end

  defp check_personal_right(_key, owner), do: {:ok, owner, nil}

  defp personal_allowed?(%{personal: true}, %Scope{} = scope), do: holds_personal_right?(scope)
  defp personal_allowed?(_key_or_actor, _scope), do: true

  defp active_user(%Key{user_uuid: user_uuid}) do
    case user_uuid |> Auth.get_user() |> Auth.ensure_active_user() do
      %User{managed_by_members: true} -> {:error, :owner_inactive}
      %User{api_only: true} = owner -> {:ok, owner}
      %User{confirmed_at: %DateTime{}} = owner -> {:ok, owner}
      %User{} = owner -> confirmation_optional(owner)
      nil -> {:error, :owner_inactive}
    end
  end

  defp confirmation_optional(owner) do
    if Settings.get_boolean_setting("require_email_confirmation", true),
      do: {:error, :owner_inactive},
      else: {:ok, owner}
  end

  @doc """
  The `Actor` of `key` held by its (already loaded, active) `owner`, with the effective
  scopes (none for a personal key whose owner lacks the permission). It and `verify/2`
  share one private builder, so a field added to the actor reaches the request path and
  an approved operation (`Confirm.live_actor/1`) alike.
  """
  @spec actor(Key.t(), User.t(), String.t() | nil) :: Actor.t()
  def actor(%Key{} = key, %User{} = owner, ip), do: build_actor(key, owner, ip, scope_of(owner))

  # A personal key whose owner lost the permission carries no scopes, even when a caller
  # builds its actor without going through `active_owner/1` first.
  defp build_actor(%Key{} = key, %User{} = owner, ip, %Scope{} = scope) do
    %Actor{
      kind: :key,
      key_uuid: key.uuid,
      key_prefix: key.prefix,
      user_uuid: owner.uuid,
      scopes: if(personal_allowed?(key, scope), do: scopes_held_by(key.scopes, scope), else: []),
      scope: scope,
      personal: key.personal,
      requires_approval: key.requires_approval,
      ip: ip
    }
  end

  # `last_used_at` is written at most once a minute per key. A failed write must
  # not fail the request. `last_used_ip` is `varchar(45)` (the longest textual
  # IPv6 form, V219), so the slice must be 45.
  defp touch_last_used(%Key{uuid: uuid}, ip) do
    if Cache.touch_last_used?(uuid) do
      now = DateTime.truncate(DateTime.utc_now(), :second)

      repo().update_all(from(k in Key, where: k.uuid == ^uuid),
        set: [last_used_at: now, last_used_ip: ip && String.slice(ip, 0, 45)]
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # --- Effective scopes --------------------------------------------------

  @doc """
  The scopes of a key (or of an `Actor`) that its owner may use **right now**.

  Empty when the owner is blocked or deleted, and for a personal key (or the actor of
  one) whose owner holds neither `api_personal_keys` nor `api`. For code that holds a `Key` row or
  an old `Actor` (the Settings page, tests). A request does not need it: the
  `Actor` returned by `verify/2` already carries these scopes and the Executor
  trusts them.
  """
  @spec effective_scopes(Key.t() | Actor.t()) :: [String.t()]
  def effective_scopes(%Key{scopes: scopes, user_uuid: user_uuid} = key),
    do: live_scopes(scopes, user_uuid, key)

  def effective_scopes(%Actor{scopes: scopes, user_uuid: user_uuid} = actor),
    do: live_scopes(scopes, user_uuid, actor)

  defp live_scopes(_scopes, nil, _key_or_actor), do: []

  defp live_scopes(scopes, user_uuid, key_or_actor) do
    case user_uuid |> Auth.get_user() |> Auth.ensure_active_user() do
      %User{} = owner ->
        scope = scope_of(owner)
        if personal_allowed?(key_or_actor, scope), do: scopes_held_by(scopes, scope), else: []

      nil ->
        []
    end
  end

  defp scopes_held_by(scopes, %Scope{} = scope) do
    held = held_scope_set(scope)
    scopes |> Enum.filter(&MapSet.member?(held, &1)) |> Enum.uniq() |> Enum.sort()
  end

  # --- Revoking and rotating --------------------------------------------

  @doc """
  Revokes a key now. Revoking a key that is already revoked changes nothing.
  The row is read again, so a stale struct neither overwrites an earlier
  revocation nor fails; a key that no longer exists is `{:error, :not_found}`.

  Unlike `rotate/3` and `update_scopes/3`, which take the person's scope and
  authorize it, this takes a bare `actor_uuid` (only for the activity entry) and
  checks nothing: the CALLER must authorize with `can_revoke?/2` first (the
  Settings page does, on the key it found through `list_keys/1`; "My API keys" on one it
  found through `list_personal_keys/1`).
  """
  @spec revoke(Key.t(), String.t() | nil) :: {:ok, Key.t()} | {:error, term()}
  def revoke(%Key{} = key, actor_uuid) do
    with {:ok, current} <- reload(key) do
      if reached?(current.revoked_at) do
        {:ok, current}
      else
        current
        |> Ecto.Changeset.change(revoked_at: now())
        |> repo().update()
        |> after_revoke(actor_uuid)
      end
    end
  rescue
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  defp after_revoke({:ok, key}, actor_uuid) do
    Cache.invalidate(key.prefix)
    log("api.key_revoked", key, actor_uuid, %{})
    {:ok, key}
  end

  defp after_revoke({:error, _} = error, _actor_uuid), do: error

  @doc """
  Issues a new key with the same owner, scopes, flags, IP list and expiry, and
  retires the old one after `grace_hours` (0 to 24; 0 revokes it now).

  A **personal** key is rotated by its owner only (`can_manage?/2`), with
  `opts[:impersonated]` given and `false` (`:impersonation_unknown` / `:impersonated`, as
  in `create_personal_key/3`; `rotate/3` passes no opts, so it refuses a personal key).
  The new key stays personal, never needs approval and expires at
  `PersonalKeysConfig.latest_expiry/0`, not at the old key's expiry.

  A rotation of a personal key takes the same per-person advisory lock as a creation,
  before the row lock. With a grace period (`grace_hours > 0`) the old key stays alive
  next to the new one, so it is refused with `{:error, :personal_key_limit}` while the
  person already has `PersonalKeysConfig.max_count/0` live personal keys (a key in a
  grace period included), checked under that lock. Without one (`0`) the swap is one for
  one and always allowed.

  The old key keeps working until then, so a client can switch over without
  downtime. The creator must be able to manage the key (`can_manage?/2`) and, when the owner
  is a service user, still hold every permission the service user holds
  (`{:error, :owner_not_allowed}`, as in `create_key/3`). Returns the new key and
  its token.

  The row is locked and read again first. A key that is gone is
  `{:error, :not_found}`, one that is revoked or expired `:revoked` / `:expired`
  (also through a stale struct), and one whose retirement is already scheduled
  `:rotation_pending`.
  """
  @spec rotate(Key.t(), 0..24, Scope.t(), keyword()) ::
          {:ok, Key.t(), String.t()} | {:error, term()}
  def rotate(key, grace_hours, creator_scope, opts \\ [])

  def rotate(%Key{} = key, grace_hours, %Scope{} = creator_scope, opts)
      when is_integer(grace_hours) and grace_hours in 0..24 do
    case swap_keys(key, grace_hours, creator_scope, opts) do
      {:ok, {retired, new_key, token}} ->
        Cache.invalidate(retired.prefix)
        log_rotated(retired, new_key, grace_hours, creator_scope.user.uuid)
        {:ok, new_key, token}

      {:error, _reason} = error ->
        error
    end
  end

  def rotate(%Key{}, _grace_hours, %Scope{}, _opts), do: {:error, :invalid_grace}

  # The row is locked and read again, so the checks run on what is stored now,
  # not on the caller's struct: a stale struct cannot revive a revoked key, and
  # two rotations of one key cannot both succeed.
  defp swap_keys(%Key{uuid: uuid}, grace_hours, creator_scope, opts) do
    {prefix, token, secret_hash} = Token.generate()
    retire_at = DateTime.add(now(), grace_hours * 3600, :second)

    repo().transaction(fn ->
      with %Key{} = original <- repo().get(Key, uuid),
           :ok <- lock_mint_users(original.user_uuid, creator_scope),
           {:ok, current} <- lock_for_rotation(uuid),
           :ok <- authorize_manage(creator_scope, current),
           :ok <- check_personal_rotation(current, opts),
           :ok <- authorize_service_owner(current, creator_scope),
           :ok <- check_alive(current),
           :ok <- check_not_retiring(current),
           :ok <- check_rotation_room(current, grace_hours),
           {:ok, new_key} <- insert_copy(current, prefix, secret_hash),
           {:ok, retired} <-
             current |> Ecto.Changeset.change(revoked_at: retire_at) |> repo().update() do
        {retired, new_key, token}
      else
        nil -> repo().rollback(:not_found)
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp lock(uuid) when is_binary(uuid) do
    case repo().one(from(k in Key, where: k.uuid == ^uuid, lock: "FOR UPDATE")) do
      %Key{} = key -> {:ok, key}
      nil -> {:error, :not_found}
    end
  end

  defp lock(_uuid), do: {:error, :not_found}

  # A personal key takes its owner's advisory lock before the row lock, in the order a
  # creation takes them. `personal` and `user_uuid` never change, so the unlocked read
  # that finds them cannot be stale in a way that matters; the row is locked and read
  # again right after.
  defp lock_for_rotation(uuid) do
    case lock_target(uuid) do
      %{personal: true, user_uuid: owner_uuid} when is_binary(owner_uuid) ->
        lock_personal_keys(owner_uuid)
        lock(uuid)

      _other ->
        lock(uuid)
    end
  end

  defp lock_target(uuid) when is_binary(uuid),
    do:
      repo().one(from(k in Key, where: k.uuid == ^uuid, select: map(k, [:personal, :user_uuid])))

  defp lock_target(_uuid), do: nil

  # The person's rights are read again here, as `create_personal_key/3` reads them: the
  # scope a caller passes may be the one captured at mount.
  defp check_personal_rotation(%Key{personal: true, user_uuid: owner_uuid}, opts) do
    with :ok <- check_not_impersonated(opts),
         {:ok, _owner} <- personal_owner(%Scope{user: %User{uuid: owner_uuid}}),
         do: :ok
  end

  defp check_personal_rotation(%Key{}, _opts), do: :ok

  # A future `revoked_at` means a rotation is already under way; rotating again
  # would push the old key's end date out and leave a third key behind.
  defp check_not_retiring(%Key{revoked_at: nil}), do: :ok
  defp check_not_retiring(%Key{}), do: {:error, :rotation_pending}

  # A rotation with a grace period adds a live key for that period (the old one stays
  # alive), so it needs room under the cap like a creation does; checked under the
  # person's advisory lock taken in `lock_for_rotation/1`. Without a grace period the old
  # key dies at once, a one-for-one swap that never raises the count.
  defp check_rotation_room(%Key{personal: true, user_uuid: owner_uuid}, grace_hours)
       when grace_hours > 0 do
    if live_personal_key_count(owner_uuid) >= PersonalKeysConfig.max_count(),
      do: {:error, :personal_key_limit},
      else: :ok
  end

  defp check_rotation_room(%Key{}, _grace_hours), do: :ok

  # A personal key's copy stays personal, gets the latest expiry allowed now and never
  # needs approval; any other key's copy keeps the old flags and expiry.
  defp insert_copy(key, prefix, secret_hash) do
    %Key{}
    |> Ecto.Changeset.change(%{
      user_uuid: key.user_uuid,
      created_by_uuid: key.created_by_uuid,
      name: key.name,
      scopes: key.scopes,
      requires_approval: key.requires_approval and not key.personal,
      allowed_ips: key.allowed_ips,
      expires_at: if(key.personal, do: PersonalKeysConfig.latest_expiry(), else: key.expires_at),
      personal: key.personal,
      prefix: prefix,
      secret_hash: secret_hash
    })
    |> Ecto.Changeset.unique_constraint(:prefix)
    |> repo().insert()
  end

  # A fresh token for a service user is the creator's grant of that user's
  # rights, so the rule of `create_key/3` holds again here: the person must
  # still hold every permission the service user holds. Demoting the creator
  # must not leave them able to mint tokens beyond their own rights.
  defp authorize_service_owner(%Key{user_uuid: owner_uuid}, %Scope{} = editor_scope)
       when is_binary(owner_uuid) do
    if editor?(editor_scope, owner_uuid),
      do: :ok,
      else: check_service_owner(Auth.get_user(owner_uuid), editor_scope)
  end

  defp authorize_service_owner(_key, _editor_scope), do: :ok

  defp check_service_owner(%User{api_only: true} = owner, editor_scope),
    do: with({:ok, _owner} <- owner_allowed(owner, editor_scope), do: :ok)

  defp check_service_owner(_owner, _editor_scope), do: :ok

  defp authorize_manage(scope, key),
    do: if(can_manage?(scope, key), do: :ok, else: {:error, :forbidden})

  defp log_rotated(retired, new_key, grace_hours, actor_uuid) do
    log("api.key_rotated", retired, actor_uuid, %{
      "new_key_uuid" => new_key.uuid,
      "new_key_prefix" => new_key.prefix,
      "grace_hours" => grace_hours,
      "personal" => retired.personal
    })
  end

  @doc """
  Replaces the scopes of a live key.

  - `editor_scope` must be able to manage the key (`can_manage?/2`), else
    `{:error, :forbidden}`; an Owner who may not manage someone else's **personal** key
    may still remove scopes from it: every scope of `new_scopes` must already be on the
    stored row, else `{:error, :scopes_not_narrowing}` (no token changes hands, and the
    key can only lose rights). In that case the saved list is exactly `new_scopes`:
    inactive scopes are not kept (the rule below does not apply), so any scope can go;
  - the key is re-read: gone gives `{:error, :not_found}`, revoked (even if the
    struct passed in is stale) `{:error, :revoked}`;
  - `new_scopes` is the desired list of **active** scopes: a list of strings, and
    every scope that is not on the key yet must be in `allowed_scopes_for/1` of the
    key's **owner** and, unless the editor is the owner, in `allowed_scopes_for/2`
    (the editor holds the permissions of its tools too), else
    `{:error, :invalid_scopes}`. Blank entries and duplicates
    are dropped; an empty list is allowed;
  - scopes already on the key that the owner cannot use right now are **kept
    untouched**: their module is switched off, their tool is hidden, the owner lost
    the permission, or the owner is blocked or deleted (then every scope is inactive
    and saving `[]` changes nothing). Saving never drops them, whether or not
    `new_scopes` names them. A named inactive scope keeps the position requested for
    it; the others are appended after the requested scopes. An inactive scope cannot
    be removed while it is inactive: only `revoke/2` removes it (`rotate/3` copies
    it). It grants nothing meanwhile (`effective_scopes/1`) and works again once the
    owner can use it.

  On success the cached row is dropped on every node and a permanent
  `api.key_scopes_updated` entry (`from` / `to`) is written. Saving the scopes the
  key already has, in any order, changes and logs nothing.
  """
  @spec update_scopes(Key.t(), [String.t()], Scope.t()) ::
          {:ok, Key.t()}
          | {:error, :forbidden | :invalid_scopes | :scopes_not_narrowing | :revoked | :not_found}
  def update_scopes(%Key{uuid: uuid}, new_scopes, %Scope{} = editor_scope) do
    result =
      repo().transaction(fn ->
        with {:ok, current} <- lock(uuid),
             {:ok, mode} <- authorize_scope_edit(editor_scope, current),
             :ok <- check_not_revoked(current),
             {:ok, scopes} <- validate_scope_edit(mode, current, new_scopes, editor_scope) do
          write_scopes(current, scopes)
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    case result do
      {:ok, {:unchanged, current}} ->
        {:ok, current}

      {:ok, {:updated, current, updated}} ->
        Cache.invalidate(updated.prefix)
        log_scopes_updated(current, updated, editor_scope.user.uuid)
        {:ok, updated}

      {:error, _reason} = error ->
        error
    end
  end

  defp reload(%Key{uuid: uuid}) when is_binary(uuid) do
    case repo().get(Key, uuid) do
      %Key{} = current -> {:ok, current}
      nil -> {:error, :not_found}
    end
  end

  defp reload(_key), do: {:error, :not_found}

  defp validate_new_scopes(%Key{user_uuid: owner_uuid} = current, scopes, editor_scope)
       when is_list(scopes) do
    if Enum.all?(scopes, &is_binary/1) do
      cleaned = clean_scopes(scopes)
      allowed = owner_uuid |> owner_allowed_scopes() |> MapSet.new()
      addable = addable_scopes(allowed, owner_uuid, editor_scope)

      if Enum.all?(cleaned, &(MapSet.member?(addable, &1) or &1 in current.scopes)),
        do: {:ok, cleaned ++ inactive_scopes_to_keep(current.scopes, cleaned, allowed)},
        else: {:error, :invalid_scopes}
    else
      {:error, :invalid_scopes}
    end
  end

  defp validate_new_scopes(_key, _scopes, _editor_scope), do: {:error, :invalid_scopes}

  # Decided on the locked, re-read row: a forged `personal` or `scopes` counts for nothing.
  defp authorize_scope_edit(editor_scope, %Key{} = current) do
    cond do
      can_manage?(editor_scope, current) -> {:ok, :manage}
      current.personal and Scope.owner?(editor_scope) -> {:ok, :narrow}
      true -> {:error, :forbidden}
    end
  end

  defp validate_scope_edit(:manage, current, scopes, editor_scope),
    do: validate_new_scopes(current, scopes, editor_scope)

  # Only scopes already on the stored row, and exactly those asked for: unlike an edit by
  # someone who manages the key, inactive scopes are not merged back, so an Owner can take
  # any scope off (the key only loses rights; nothing else changes).
  defp validate_scope_edit(:narrow, %Key{} = current, scopes, _editor_scope)
       when is_list(scopes) do
    if Enum.all?(scopes, &is_binary/1) do
      cleaned = clean_scopes(scopes)

      if Enum.all?(cleaned, &(&1 in current.scopes)),
        do: {:ok, cleaned},
        else: {:error, :scopes_not_narrowing}
    else
      {:error, :invalid_scopes}
    end
  end

  defp validate_scope_edit(:narrow, _current, _scopes, _editor_scope),
    do: {:error, :invalid_scopes}

  # A scope is added to a key only when its owner may use it and the editor
  # holds the permission of its tools too: the creator's authority was checked
  # once, in `create_key/3`, and a later demotion of the creator (or a wider
  # role for the service user) must not let them grow the key beyond their own
  # rights. Scopes already on the key may stay or go whoever the editor is.
  defp addable_scopes(allowed, owner_uuid, editor_scope) do
    if editor?(editor_scope, owner_uuid) do
      allowed
    else
      held = held_scope_set(editor_scope)
      MapSet.filter(allowed, &MapSet.member?(held, &1))
    end
  end

  # Scopes already on the key that the owner cannot use right now are neither validated nor
  # dropped: they come back after the requested list, unless the list names them itself.
  defp inactive_scopes_to_keep(current_scopes, cleaned, allowed) do
    Enum.reject(current_scopes, &(MapSet.member?(allowed, &1) or &1 in cleaned))
  end

  defp owner_allowed_scopes(owner_uuid) do
    case owner_uuid |> Auth.get_user() |> Auth.ensure_active_user() do
      %User{} = owner -> allowed_scopes_for(owner)
      nil -> []
    end
  end

  # The row is locked and read again, so authorization and validation run on what is stored now,
  # not on the caller's struct (a forged `created_by_uuid` or `scopes` counts for nothing). The
  # cache is dropped and the entry written once the change is committed.
  defp write_scopes(%Key{} = current, scopes) do
    if MapSet.new(scopes) == MapSet.new(current.scopes) do
      {:unchanged, current}
    else
      case current |> Ecto.Changeset.change(scopes: scopes) |> repo().update() do
        {:ok, updated} -> {:updated, current, updated}
        {:error, reason} -> repo().rollback(reason)
      end
    end
  end

  defp log_scopes_updated(current, updated, actor_uuid) do
    log("api.key_scopes_updated", updated, actor_uuid, %{
      "from" => current.scopes,
      "to" => updated.scopes
    })
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  # --- Access ------------------------------------------------------------

  @doc """
  Whether the person behind `scope` may revoke, rotate or edit the scopes of `key`: they
  hold `api` and are an Owner or created the key. A **personal** key is managed by its
  owner alone, while they hold `api_personal_keys` or `api` (an Owner included: see
  `can_revoke?/2`).
  """
  @spec can_manage?(Scope.t(), Key.t()) :: boolean()
  def can_manage?(%Scope{user: %User{uuid: user_uuid}} = scope, %Key{
        personal: true,
        user_uuid: owner_uuid
      }) do
    is_binary(owner_uuid) and owner_uuid == user_uuid and holds_personal_right?(scope)
  end

  def can_manage?(%Scope{user: %User{uuid: user_uuid}} = scope, %Key{created_by_uuid: creator}) do
    Scope.can?(scope, "api") and (Scope.owner?(scope) or creator == user_uuid)
  end

  def can_manage?(_scope, _key), do: false

  @doc """
  Whether the person behind `scope` may revoke `key`: `can_manage?/2`, and an Owner for
  anyone's personal key too (revoking hands out no token). Callers of `revoke/2` check
  this first.
  """
  @spec can_revoke?(Scope.t(), Key.t()) :: boolean()
  def can_revoke?(%Scope{user: %User{}} = scope, %Key{personal: true} = key),
    do: can_manage?(scope, key) or Scope.owner?(scope)

  def can_revoke?(scope, %Key{} = key), do: can_manage?(scope, key)
  def can_revoke?(_scope, _key), do: false

  @doc "Fetches a key by uuid; `nil` for an unknown or malformed uuid."
  @spec get_key(String.t()) :: Key.t() | nil
  def get_key(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid), do: repo().get(Key, uuid), else: nil
  end

  def get_key(_uuid), do: nil

  @doc """
  Why a key row cannot be used now: `:revoked` (`revoked_at` has been reached), `:expired`
  (`expires_at` has been reached), or `nil`. A time in the future has not been reached: a
  revocation in the future is a scheduled one (the grace period of a rotation) and the key
  still works until then. When both have been reached the answer is `:revoked`.
  """
  @spec dead_reason(Key.t()) :: :revoked | :expired | nil
  def dead_reason(%Key{revoked_at: revoked_at, expires_at: expires_at}) do
    cond do
      reached?(revoked_at) -> :revoked
      reached?(expires_at) -> :expired
      true -> nil
    end
  end

  @doc """
  Token-less check that a key may be used now: the
  key is neither revoked nor expired (`dead_reason/1` is `nil`) **and its owner is an
  active user** (`Auth.get_user/1 |> Auth.ensure_active_user/1`, the same lookup
  `verify/2` uses). A caller that needs the reason, or the key's effective scopes, uses
  `Confirm.live_actor/1`. The owner is read only when the row itself is alive.
  """
  @spec active?(Key.t()) :: boolean()
  def active?(%Key{user_uuid: user_uuid} = key) when is_binary(user_uuid),
    do: dead_reason(key) == nil and match?({:ok, _owner}, active_owner(key))

  def active?(%Key{}), do: false

  # --- Listing -----------------------------------------------------------

  @doc """
  The keys the person behind `scope` may see: all of them for an Owner, the keys
  they created themselves for any other holder of `api`, none otherwise.
  Newest first.
  """
  @spec list_keys(Scope.t()) :: [Key.t()]
  def list_keys(%Scope{user: %User{uuid: user_uuid}} = scope) do
    cond do
      not Scope.can?(scope, "api") ->
        []

      Scope.owner?(scope) ->
        repo().all(from(k in Key, order_by: [desc: k.inserted_at, desc: k.uuid]))

      true ->
        repo().all(
          from(k in Key,
            where: k.created_by_uuid == ^user_uuid,
            order_by: [desc: k.inserted_at, desc: k.uuid]
          )
        )
    end
  end

  def list_keys(_scope), do: []

  @doc """
  The prefix of a token (`"pk_<prefix>_<secret>"` gives `prefix`), or `nil`.
  Safe to log: the prefix is not secret.
  """
  @spec token_prefix(String.t()) :: String.t() | nil
  def token_prefix(token), do: Token.prefix(token)

  # --- Activity ----------------------------------------------------------

  defp log_created(key, actor_uuid) do
    log("api.key_created", key, actor_uuid, %{
      "scopes" => key.scopes,
      "requires_approval" => key.requires_approval,
      "allowed_ips" => key.allowed_ips,
      "expires_at" => key.expires_at && DateTime.to_iso8601(key.expires_at),
      "personal" => key.personal
    })
  end

  # Metadata never holds the token or its hash.
  defp log(action, %Key{} = key, actor_uuid, extra) do
    Activity.log("api", action,
      actor_uuid: actor_uuid,
      resource_type: "api_key",
      resource_uuid: key.uuid,
      permanent: true,
      metadata:
        Map.merge(
          %{"key_prefix" => key.prefix, "name" => key.name, "owner_uuid" => key.user_uuid},
          extra
        )
    )
  end

  defp repo, do: RepoHelper.repo()
end
