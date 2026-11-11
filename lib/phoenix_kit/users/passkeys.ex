defmodule PhoenixKit.Users.Passkeys do
  @moduledoc """
  Passkeys: signing in with a WebAuthn credential the person's device keeps.

  Plan and decisions: `dev_docs/plans/2026-11-10-passkeys.md`. The cryptography is
  `Wax` (`wax_`); this module decides who, when and what is stored.

  ## The relying party

  A passkey belongs to one domain, the host of the canonical origin
  (`PhoenixKit.API.MCP.Origin.canonical_origin/0`: the `site_url` setting, else the
  endpoint). Never the request's `Host` header. Each row keeps the `rp_id` it was made
  for, so a passkey from before a domain change reads as `usable?/1` false instead of
  failing without a word. Password and magic link stay as the way back in.

  ## Signing in

  `authentication_options/0` makes a challenge for any passkey of this site
  (discoverable credentials: no email first). The caller keeps the challenge in server
  memory (a LiveView assign), never in the browser, and passes it to `authenticate/2`
  with what the device answered. Success gives the user, and the caller mints a
  one-time sign-in token (`mint_login_token/1`, 60 seconds, single use) that a
  controller exchanges for a session (`consume_login_token/1`), exactly as QR sign-in
  does. Every refusal is the same `{:error, :invalid}`: no "no such passkey" versus
  "bad signature" oracle. The reason is logged by category only.

  ## Adding one

  A passkey is a way back into the account for as long as it exists, so
  `register/4` takes the session it is added from and refuses (`check_may_add/2`):

    * an impersonated session (an admin signed in as the person),
    * a session older than 15 minutes (`fresh_session_minutes/0`),
    * a service user or a managed organization (they never sign in on the web),
    * the switch being off.

  Adding and removing tell the person: an email, an in-app notice, and an activity
  entry (`user.passkey_added`, `user.passkey_removed`).

  ## Sign count

  Passkeys may report 0 when they do not implement a counter. Once a positive count
  is recorded, a count that does not go up is logged and sign-in is still allowed.
  """

  import Ecto.Query

  require Logger

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.API.MCP.Origin
  alias PhoenixKit.Notifications
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Passkey
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Users.Sessions
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.UserAgent

  @challenge_timeout 300
  @login_token_context "passkey_login"
  @login_token_seconds 60
  @fresh_session_minutes 15
  # ES256, EdDSA, RS256: every common authenticator, in the order we prefer them.
  @algorithms [-7, -8, -257]

  @type relying_party :: %{origin: String.t(), rp_id: String.t()}

  @doc "Whether passkey sign-in is on (setting `passkey_login_enabled`, default `false`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting("passkey_login_enabled", false)

  @doc "How recent a sign-in must be to add a passkey."
  @spec fresh_session_minutes() :: pos_integer()
  def fresh_session_minutes, do: @fresh_session_minutes

  @doc "The origin passkeys are checked against and the domain they belong to."
  @spec relying_party() :: relying_party()
  def relying_party do
    origin = Origin.canonical_origin()
    %{origin: origin, rp_id: URI.parse(origin).host}
  end

  @doc "Whether `passkey` was made for this site's current domain."
  @spec usable?(Passkey.t()) :: boolean()
  def usable?(%Passkey{rp_id: rp_id}), do: rp_id == relying_party().rp_id

  # ── Listing and changing ───────────────────────────────────────────

  @doc "The person's passkeys, oldest first."
  @spec list(User.t()) :: [Passkey.t()]
  def list(%User{uuid: uuid}) do
    repo().all(from p in Passkey, where: p.user_uuid == ^uuid, order_by: [asc: p.inserted_at])
  end

  @doc "Renames one of `owner`'s passkeys."
  @spec rename(User.t(), String.t(), String.t()) ::
          {:ok, Passkey.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename(%User{} = owner, passkey_uuid, name) when is_binary(name) do
    case get(owner, passkey_uuid) do
      nil -> {:error, :not_found}
      passkey -> passkey |> Passkey.rename_changeset(name) |> repo().update()
    end
  end

  @doc """
  Removes one of `owner`'s passkeys, as `actor`: the owner, or someone who may end the
  owner's sessions (`PhoenixKit.Users.Sessions.can_revoke_sessions_of?/2`).
  """
  @spec delete(User.t(), String.t(), User.t()) ::
          {:ok, Passkey.t()} | {:error, :not_found | :not_allowed}
  def delete(%User{} = owner, passkey_uuid, %User{} = actor) do
    with true <- Sessions.can_revoke_sessions_of?(owner, actor) || {:error, :not_allowed},
         %Passkey{} = passkey <- get(owner, passkey_uuid) || {:error, :not_found},
         {:ok, passkey} <- repo().delete(passkey) do
      announce_removed(owner, passkey, actor)
      {:ok, passkey}
    end
  end

  defp get(%User{uuid: uuid}, passkey_uuid) when is_binary(passkey_uuid) do
    case Ecto.UUID.cast(passkey_uuid) do
      {:ok, id} -> repo().get_by(Passkey, uuid: id, user_uuid: uuid)
      :error -> nil
    end
  end

  defp get(_owner, _passkey_uuid), do: nil

  # ── Adding ─────────────────────────────────────────────────────────

  @doc """
  Whether `user` may add a passkey from the session `session_token`, which is
  `impersonated` or not (the caller computes it with
  `PhoenixKitWeb.Users.MultiSession.impersonated?/1`, never a constant).
  """
  @spec check_may_add(User.t(), keyword()) ::
          :ok | {:error, :disabled | :not_allowed | :impersonated | :stale_session}
  def check_may_add(%User{} = user, opts) do
    cond do
      not enabled?() -> {:error, :disabled}
      user.api_only or user.managed_by_members or not user.is_active -> {:error, :not_allowed}
      Keyword.get(opts, :impersonated, true) != false -> {:error, :impersonated}
      not fresh_session?(user, Keyword.get(opts, :session_token)) -> {:error, :stale_session}
      true -> :ok
    end
  end

  defp fresh_session?(%User{uuid: uuid}, token) when is_binary(token) do
    repo().exists?(
      from t in UserToken,
        where:
          t.token == ^token and t.context == "session" and t.user_uuid == ^uuid and
            t.inserted_at > ago(@fresh_session_minutes, "minute")
    )
  end

  defp fresh_session?(_user, _token), do: false

  @doc """
  A challenge and the options for the browser's `navigator.credentials.create`.

  The caller keeps the challenge (server side) for `register/4`.
  """
  @spec registration_options(User.t()) :: {Wax.Challenge.t(), map()}
  def registration_options(%User{} = user) do
    rp = relying_party()

    challenge =
      Wax.new_registration_challenge(
        origin: rp.origin,
        rp_id: rp.rp_id,
        attestation: "none",
        user_verification: "required",
        # We accept any authenticator and keep no metadata, so there is no root to
        # check: a `packed` statement with a certificate would otherwise fail.
        verify_trust_root: false,
        timeout: @challenge_timeout
      )

    options = %{
      "challenge" => encode64(challenge.bytes),
      "rp" => %{"id" => rp.rp_id, "name" => Settings.get_project_title()},
      "user" => %{
        "id" => encode64(user_handle(user.uuid)),
        "name" => user.email,
        "displayName" => User.display_name(user)
      },
      "pubKeyCredParams" => Enum.map(@algorithms, &%{"type" => "public-key", "alg" => &1}),
      "timeout" => @challenge_timeout * 1000,
      "attestation" => "none",
      "authenticatorSelection" => %{
        "residentKey" => "required",
        "requireResidentKey" => true,
        "userVerification" => "required"
      },
      "excludeCredentials" =>
        user |> list() |> Enum.filter(&(&1.rp_id == rp.rp_id)) |> Enum.map(&descriptor/1)
    }

    {challenge, options}
  end

  @doc """
  Verifies what the browser answered to `registration_options/1` and stores the passkey.

  `params` are the browser's `attestationObject`, `clientDataJSON` and `transports`
  (base64url), and `userAgent` for the default name. `opts` as in `check_may_add/2`.
  """
  @spec register(User.t(), Wax.Challenge.t(), map(), keyword()) ::
          {:ok, Passkey.t()}
          | {:error,
             :invalid
             | :already_registered
             | :disabled
             | :not_allowed
             | :impersonated
             | :stale_session}
  def register(%User{} = user, %Wax.Challenge{} = challenge, params, opts)
      when is_map(params) do
    with :ok <- check_may_add(user, opts),
         :ok <- check_relying_party(challenge),
         {:ok, attestation} <- decode64(params["attestationObject"]),
         {:ok, client_data} <- decode64(params["clientDataJSON"]),
         {:ok, {auth_data, _attestation}} <-
           verify_with_wax(fn -> Wax.register(attestation, client_data, challenge) end),
         %{credential_id: credential_id, credential_public_key: cose_key} <-
           auth_data.attested_credential_data do
      %{
        user_uuid: user.uuid,
        credential_id: credential_id,
        public_key: Passkey.encode_public_key(cose_key),
        sign_count: auth_data.sign_count,
        rp_id: challenge.rp_id,
        transports: List.wrap(params["transports"]),
        backup_eligible: auth_data.flag_backup_eligible == true,
        name: default_name(params["userAgent"])
      }
      |> Passkey.create_changeset()
      |> repo().insert()
      |> case do
        {:ok, passkey} ->
          announce_added(user, passkey, params["userAgent"])
          {:ok, passkey}

        {:error, %Ecto.Changeset{errors: errors}} ->
          if Keyword.has_key?(errors, :credential_id),
            do: {:error, :already_registered},
            else: {:error, :invalid}
      end
    else
      {:error, reason}
      when reason in [:disabled, :not_allowed, :impersonated, :stale_session] ->
        {:error, reason}

      other ->
        log_refusal("register", other)
        {:error, :invalid}
    end
  end

  defp default_name(user_agent) when is_binary(user_agent) do
    user_agent = String.slice(user_agent, 0, 512)

    case {UserAgent.browser(user_agent), UserAgent.os(user_agent)} do
      {nil, nil} -> gettext("Passkey")
      {browser, nil} -> browser
      {nil, os} -> os
      {browser, os} -> gettext("%{browser} on %{os}", browser: browser, os: os)
    end
  end

  defp default_name(_), do: gettext("Passkey")

  # ── Signing in ─────────────────────────────────────────────────────

  @doc """
  A challenge and the options for the browser's `navigator.credentials.get`.

  No `allowCredentials`: the device offers this site's passkeys itself. The caller
  keeps the challenge (server side) for `authenticate/2`.
  """
  @spec authentication_options() :: {Wax.Challenge.t(), map()}
  def authentication_options do
    rp = relying_party()

    challenge =
      Wax.new_authentication_challenge(
        origin: rp.origin,
        rp_id: rp.rp_id,
        user_verification: "required",
        timeout: @challenge_timeout
      )

    options = %{
      "challenge" => encode64(challenge.bytes),
      "rpId" => rp.rp_id,
      "timeout" => @challenge_timeout * 1000,
      "userVerification" => "required",
      "allowCredentials" => []
    }

    {challenge, options}
  end

  @doc """
  Verifies what the browser answered to `authentication_options/0`.

  `params` are the browser's `rawId`, `authenticatorData`, `clientDataJSON`,
  `signature` and `userHandle` (base64url). Returns the user only when they may sign
  in on the web (active, not a service user, not a managed organization).
  """
  @spec authenticate(Wax.Challenge.t(), map()) :: {:ok, User.t()} | {:error, :invalid}
  def authenticate(%Wax.Challenge{} = challenge, params) when is_map(params) do
    with true <- enabled?() || :disabled,
         :ok <- check_relying_party(challenge),
         {:ok, credential_id} <- decode64(params["rawId"]),
         {:ok, auth_data_bin} <- decode64(params["authenticatorData"]),
         {:ok, signature} <- decode64(params["signature"]),
         {:ok, client_data} <- decode64(params["clientDataJSON"]),
         {:ok, handle} <- decode64(params["userHandle"]),
         %Passkey{} = passkey <-
           repo().get_by(Passkey, credential_id: credential_id) || :unknown_credential,
         true <- passkey.rp_id == challenge.rp_id || :other_domain,
         true <- handle == user_handle(passkey.user_uuid) || :user_handle_mismatch,
         {:ok, cose_key} <- Passkey.decode_public_key(passkey.public_key),
         {:ok, auth_data} <-
           verify_with_wax(fn ->
             Wax.authenticate(credential_id, auth_data_bin, signature, client_data, challenge, [
               {credential_id, cose_key}
             ])
           end),
         %User{} = user <- signable_user(passkey.user_uuid) || :user_cannot_sign_in,
         :ok <- record_use(passkey, auth_data.sign_count) do
      {:ok, user}
    else
      other ->
        log_refusal("authenticate", other)
        {:error, :invalid}
    end
  end

  def authenticate(_challenge, _params), do: {:error, :invalid}

  defp signable_user(user_uuid) do
    case repo().get(User, user_uuid) do
      %User{is_active: true, api_only: false, managed_by_members: false} = user -> user
      _ -> nil
    end
  end

  defp record_use(passkey, sign_count) do
    repo = repo()

    # Assertions may finish out of order. Compare against the current row, and
    # refuse if the passkey was removed while its signature was being verified.
    result =
      repo.transaction(fn ->
        current =
          repo.one(from p in Passkey, where: p.uuid == ^passkey.uuid, lock: "FOR NO KEY UPDATE") ||
            repo.rollback(:unknown_credential)

        now = DateTime.utc_now() |> DateTime.truncate(:second)

        current
        |> Passkey.used_changeset(max(sign_count, current.sign_count), now)
        |> repo.update!()

        current.sign_count > 0 and sign_count <= current.sign_count
      end)

    case result do
      {:ok, true} ->
        Logger.warning("[PhoenixKit.Passkeys] the signature count of a passkey did not go up")

        log_activity("user.passkey_sign_count_regressed", passkey.user_uuid, passkey.user_uuid, %{
          "passkey_uuid" => passkey.uuid
        })

        :ok

      {:ok, false} ->
        :ok

      {:error, reason} ->
        reason
    end
  end

  # ── The one-time sign-in token ─────────────────────────────────────

  @doc """
  A one-time token for `user`, valid #{@login_token_seconds} seconds, that
  `consume_login_token/1` exchanges for the user once. Only its hash is stored, and a
  new one replaces the user's earlier one, so at most one row per person waits.
  """
  @spec mint_login_token(User.t()) :: String.t()
  def mint_login_token(%User{uuid: uuid}) do
    token = :crypto.strong_rand_bytes(32)
    repo = repo()

    {:ok, _} =
      repo.transaction(fn ->
        # Lock even when this is the person's first token. Concurrent issuers
        # must replace each other's tokens instead of leaving multiple rows.
        repo.one!(
          from u in User, where: u.uuid == ^uuid, select: u.uuid, lock: "FOR NO KEY UPDATE"
        )

        repo.delete_all(
          from t in UserToken, where: t.user_uuid == ^uuid and t.context == @login_token_context
        )

        repo.insert!(%UserToken{
          token: :crypto.hash(:sha256, token),
          context: @login_token_context,
          user_uuid: uuid
        })
      end)

    Base.url_encode64(token, padding: false)
  end

  @doc """
  Exchanges a token from `mint_login_token/1` for the user it was made for: once, and
  only within #{@login_token_seconds} seconds. The user is read again here, so one
  deactivated in between is refused.
  """
  @spec consume_login_token(String.t()) :: {:ok, User.t()} | :error
  def consume_login_token(encoded) when is_binary(encoded) do
    with {:ok, token} <- Base.url_decode64(encoded, padding: false),
         hashed = :crypto.hash(:sha256, token),
         {1, [user_uuid]} <-
           repo().delete_all(
             from(t in UserToken,
               where:
                 t.token == ^hashed and t.context == @login_token_context and
                   t.inserted_at > ago(@login_token_seconds, "second"),
               select: t.user_uuid
             )
           ),
         %User{} = user <- signable_user(user_uuid) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  def consume_login_token(_), do: :error

  # ── Telling the person ─────────────────────────────────────────────

  defp announce_added(user, passkey, user_agent) do
    log_activity("user.passkey_added", user.uuid, user.uuid, %{"passkey_name" => passkey.name})

    notify_in_app(
      user,
      gettext("A passkey was added to your account: %{name}.", name: passkey.name)
    )

    deliver(fn ->
      UserNotifier.deliver_passkey_added(user, %{
        name: passkey.name,
        at: passkey.inserted_at,
        browser_os: browser_os(user_agent)
      })
    end)
  end

  defp announce_removed(owner, passkey, actor) do
    by_owner? = owner.uuid == actor.uuid

    # Removed by someone else: the activity reaches the owner's inbox by itself
    # (`target_uuid` differs from `actor_uuid`, rendered by `Notifications.Render`).
    log_activity("user.passkey_removed", actor.uuid, owner.uuid, %{
      "passkey_name" => passkey.name
    })

    if by_owner? do
      notify_in_app(
        owner,
        gettext("A passkey was removed from your account: %{name}.", name: passkey.name)
      )
    end

    deliver(fn ->
      UserNotifier.deliver_passkey_removed(owner, %{name: passkey.name, by_owner?: by_owner?})
    end)
  end

  defp browser_os(user_agent) when is_binary(user_agent) do
    [UserAgent.browser(user_agent), UserAgent.os(user_agent)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" on ")
  end

  defp browser_os(_), do: ""

  # A failure to tell must never undo what was done.
  defp deliver(fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[PhoenixKit.Passkeys] email failed: #{inspect(error.__struct__)}")
      :ok
  end

  defp notify_in_app(user, text) do
    Notifications.create(%{
      recipient_uuid: user.uuid,
      type: "security",
      icon: "hero-finger-print",
      link: Routes.user_settings_path(),
      text: text
    })
  rescue
    error ->
      Logger.warning("[PhoenixKit.Passkeys] in-app notice failed: #{inspect(error.__struct__)}")
      :ok
  end

  defp log_activity(action, actor_uuid, target_uuid, metadata) do
    PhoenixKit.Activity.log(%{
      action: action,
      module: "users",
      mode: "manual",
      actor_uuid: actor_uuid,
      target_uuid: target_uuid,
      resource_type: "user",
      resource_uuid: target_uuid,
      metadata: metadata
    })
  rescue
    error ->
      Logger.warning("[PhoenixKit.Passkeys] activity failed: #{inspect(error.__struct__)}")
      :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp check_relying_party(%Wax.Challenge{origin: origin, rp_id: rp_id}) do
    if relying_party() == %{origin: origin, rp_id: rp_id}, do: :ok, else: :other_domain
  end

  defp verify_with_wax(verify) do
    verify.()
  rescue
    error in [ArgumentError, FunctionClauseError, KeyError, MatchError] -> {:error, error}
  end

  @doc false
  # WebAuthn's `user.id`: the 16 bytes of the user's uuid (not personal data).
  @spec user_handle(String.t()) :: binary()
  def user_handle(user_uuid), do: Ecto.UUID.dump!(user_uuid)

  defp descriptor(%Passkey{} = passkey) do
    %{
      "type" => "public-key",
      "id" => encode64(passkey.credential_id),
      "transports" => passkey.transports
    }
  end

  defp encode64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp decode64(value) when is_binary(value) and byte_size(value) <= 16_384 do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :bad_encoding
    end
  end

  defp decode64(_), do: :bad_encoding

  # Never the bytes, the challenge or the credential: the category, or the module of
  # the exception `Wax` returned.
  defp log_refusal(step, reason) do
    category =
      case reason do
        {:error, %{__struct__: module}} -> inspect(module)
        atom when is_atom(atom) -> Atom.to_string(atom)
        _ -> "unexpected"
      end

    Logger.info("[PhoenixKit.Passkeys] #{step} refused: #{category}")
  end

  defp repo, do: RepoHelper.repo()
end
