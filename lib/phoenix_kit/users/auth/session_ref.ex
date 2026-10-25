defmodule PhoenixKit.Users.Auth.SessionRef do
  @moduledoc """
  A live browser session as an actor, for code that runs on a person's behalf without a
  `Plug.Conn` (an assistant LiveView, a task it starts).

  A session is referred to by `{session_token_uuid, user_uuid}`: the `uuid` of its row in
  `phoenix_kit_users_tokens` and the user it belongs to. Neither is a secret, so the pair
  may travel in the signed (but not encrypted) session map of a nested LiveView; the raw
  session token must not, and never leaves the cookie session.

  `scope_for_session/2` rebuilds the user's `PhoenixKit.Users.Auth.Scope` from that row
  on every call, by the rules a web request follows
  (`PhoenixKit.Users.Auth.UserToken.verify_session_token_uuid_query/1`): the row is a
  `"session"` row and has not expired, its user is not a service user, and the scope is
  narrowed to the role this session acts as (`PhoenixKit.Users.ActiveRole`). The account
  must also pass the gate every authenticated page applies: a confirmed email while
  `require_email_confirmation` is on, and the invite-only gate
  (`PhoenixKit.Users.Referrals.access_satisfied?/1`), so a session acts with no more than
  its pages would let it. Logging out, revoking the session or blocking the user takes
  effect on the next call.

  `from_session/1` reads the reference from a LiveView's session map.

  The pair is not a secret, but it is an in-process credential: any code that hands it to
  `PhoenixKit.API.Executor.execute_as/5` or `visible_for/3` acts as that session. Take it
  only from the signed session of the LiveView that runs in that session
  (`from_session/1` in its connected mount), never from params or client events.

  Maintenance mode is deliberately not checked on this path: the web shows the maintenance
  layout at mount, where nothing that calls the Executor is rendered.
  """

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Referrals
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @typedoc "`{session_token_uuid, user_uuid}`."
  @type t :: {String.t(), String.t()}

  @typedoc """
  Why a session cannot act: `:session_gone` (no such live session: logged out, revoked,
  expired, not a session row, or a service user's), `:mismatch` (the session belongs to
  another user), `:inactive` (the user is blocked), `:unconfirmed` (the email is not
  confirmed and confirmation is required) or `:referral_required` (the invite-only gate
  still asks for a referral code).
  """
  @type refusal :: :session_gone | :mismatch | account_refusal()

  @typedoc "Why the account gate stops a user: see `t:refusal/0`."
  @type account_refusal :: :inactive | :unconfirmed | :referral_required

  @doc """
  The scope of the live session `session_token_uuid`, which must belong to `user_uuid`.

  Returns `{:ok, scope}` narrowed to the session's active role, or `{:error, reason}`
  (`t:refusal/0`). Never raises on a malformed reference.
  """
  @spec scope_for_session(term(), term()) :: {:ok, Scope.t()} | {:error, refusal()}
  def scope_for_session(session_token_uuid, user_uuid) do
    with {:ok, %User{} = user} <- session_user(session_token_uuid),
         :ok <- same_user(user, user_uuid) do
      scope_for_user(user, narrow: true)
    end
  end

  @doc """
  The scope of `user` if the web's account gate lets them in: the user is active, has a
  confirmed email while `require_email_confirmation` is on, and passes the invite-only
  gate. These are the checks `scope_for_session/2` applies after finding the session, for
  an actor that is not a browser session (a linked Telegram chat, see
  `PhoenixKit.API.Executor.execute_as/5`). Pass the user as just read from the database.

  Options: `:narrow` (default `true`), as `PhoenixKit.Users.Auth.Scope.for_user/2`:
  narrowed to the role the user acts as, or (`false`) the union of every held role.

  Returns `{:ok, scope}` or `{:error, reason}` (`t:account_refusal/0`).
  """
  @spec scope_for_user(User.t(), keyword()) :: {:ok, Scope.t()} | {:error, account_refusal()}
  def scope_for_user(%User{} = user, opts) do
    with %User{} = active <- Auth.ensure_active_user(user) || {:error, :inactive},
         :ok <- confirmed(active),
         scope = Scope.for_user(active, narrow: Keyword.get(opts, :narrow, true)),
         :ok <- referral_satisfied(scope) do
      {:ok, scope}
    end
  end

  @doc """
  The reference of the session a LiveView runs in, read from its session map: the
  `"user_token"` of the cookie session resolved to `{session_token_uuid, user_uuid}`.
  `:error` when there is no token or it is not a live session.

  Call it in the nested LiveView itself (a sticky `live_render` beside the page, e.g. a
  widget in the layout): LiveView merges the cookie session into the session of every
  LiveView, nested ones included, both in the connected mount (the socket's
  `connect_info: [session: ...]`) and in the static render (the parent's conn session).
  The reference read in a static render is the same one, but act on it (call the
  executor) only in the connected mount.
  Do not have a host page read the reference and pass it in the nested LiveView's
  `:session`: a widget rendered by the core layout has no host that holds the cookie
  session. Like `PhoenixKitWeb.Users.MultiSession.impersonated?/1`, call it where the
  session is signed and trusted, never with data from params or events.
  """
  @spec from_session(map()) :: {:ok, t()} | :error
  def from_session(%{"user_token" => token}) when is_binary(token) do
    case Auth.get_session_token_record(token) do
      %UserToken{uuid: uuid, user_uuid: user_uuid} when is_binary(user_uuid) ->
        {:ok, {uuid, user_uuid}}

      _none ->
        :error
    end
  end

  def from_session(_session), do: :error

  defp session_user(token_uuid) do
    if UUIDUtils.valid?(token_uuid) do
      {:ok, query} = UserToken.verify_session_token_uuid_query(token_uuid)

      case RepoHelper.repo().one(query) do
        %User{} = user -> {:ok, user}
        nil -> {:error, :session_gone}
      end
    else
      {:error, :session_gone}
    end
  end

  defp same_user(%User{uuid: uuid}, uuid), do: :ok
  defp same_user(%User{}, _user_uuid), do: {:error, :mismatch}

  # The two halts of the web's account gate (`PhoenixKitWeb.Users.Auth`, behind every
  # authenticated `on_mount` hook and plug), in its order. The confirmation rule is the
  # one `PhoenixKit.API.Keys.active_owner/1` applies to a key's owner.
  defp confirmed(%User{confirmed_at: %DateTime{}}), do: :ok

  defp confirmed(%User{}) do
    if Settings.get_boolean_setting("require_email_confirmation", true),
      do: {:error, :unconfirmed},
      else: :ok
  end

  defp referral_satisfied(%Scope{} = scope),
    do: if(Referrals.access_satisfied?(scope), do: :ok, else: {:error, :referral_required})
end
