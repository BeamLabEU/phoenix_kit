defmodule PhoenixKit.API.OAuth.Exchange do
  @moduledoc """
  The token endpoint's logic (`POST /oauth/token`, RFC 6749 section 3.2): an authorization code
  or a refresh token in, a pair of tokens out. `token/1` takes the form parameters and answers
  `{:ok, response}` or `{:error, error, description}` with an RFC 6749 section 5.2 error code.

  The clients here are public (`token_endpoint_auth_method: none`): `client_secret` and
  `client_assertion` are ignored, a client is told by its `client_id` and proves itself with
  PKCE. A client the server does not know is `invalid_client`.

  ## Authorization code

  `PhoenixKit.API.OAuth.Codes.redeem/1` is the first step: one atomic update decides who gets the
  code. A code that was already used is a replay: the grant, its tokens and its hidden key are
  revoked (RFC 6749 section 4.1.2) and the answer is `invalid_grant`. Then the code must belong to
  the presented client, the `redirect_uri` must be the very string of the authorization request, the
  `code_verifier` must hash (S256) to the stored challenge, and `resource`, when sent, must be the
  one of the grant. On success the grant is activated, an access token and a refresh token are
  issued, and `oauth.grant_created` is written to the activity feed. Nothing about the person
  or the client is in the response: only the tokens, their lifetime and the scope actually granted.

  ## Refresh token

  Rotation: a refresh token is exchanged once, for a new pair, and the request cannot widen the
  scope. The one used again is told from a network retry like this, all under the grant's lock:

    * **R1**, used before, is presented again within 10 seconds of its use **and its successor R2
      has not been used**: a retry. R2 and the access token issued with it (A2) are revoked
      (`retry_superseded`), a fresh pair (with `parent_uuid = R1`) is issued, and
      `oauth.refresh_retry` is written. The 10 seconds are checked first; the conditional update of
      R2 has no window in it.
    * Anything else is a theft signal and the grant is revoked as a whole (`oauth.refresh_reuse`):
      R1 after the window, R1 after R2 was used, and **R2 after it was revoked by a retry** (an
      honest client never received it, so it cannot present it).

  The check of the grant (`PhoenixKit.API.OAuth.Grants.live?/1`) and of the person's right to
  hold a key (`PhoenixKit.API.Keys.active_owner/1`) is made again on every refresh.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Activity
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Codes
  alias PhoenixKit.API.OAuth.Grant
  alias PhoenixKit.API.OAuth.Grants
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.OAuth.Token
  alias PhoenixKit.API.OAuth.Tokens
  alias PhoenixKit.RepoHelper

  @retry_window_seconds 10
  @verifier ~r/\A[A-Za-z0-9\-._~]{43,128}\z/

  @type result :: {:ok, map()} | {:error, String.t(), String.t()}

  @doc "Seconds after a refresh token was used in which its repeat is taken for a retry."
  @spec retry_window_seconds() :: pos_integer()
  def retry_window_seconds, do: @retry_window_seconds

  @doc "Answers one token request (see the moduledoc)."
  @spec token(map()) :: result()
  def token(params) when is_map(params) do
    if Enum.all?(params, fn {_name, value} -> is_binary(value) end) do
      case Map.get(params, "grant_type") do
        "authorization_code" -> authorization_code(params)
        "refresh_token" -> refresh(params)
        nil -> invalid_request("grant_type is required.")
        _other -> {:error, "unsupported_grant_type", "Only authorization_code and refresh_token."}
      end
    else
      invalid_request("Every parameter must be a single string.")
    end
  end

  def token(_params), do: invalid_request("The request has no parameters.")

  # --- authorization code ------------------------------------------------------

  defp authorization_code(params) do
    with {:ok, code} <- required(params, "code"),
         {:ok, redirect_uri} <- required(params, "redirect_uri"),
         {:ok, client_id} <- required(params, "client_id"),
         {:ok, verifier} <- verifier(params),
         {:ok, client} <- known_client(client_id),
         {:ok, row} <- redeem(code),
         {:ok, grant} <- code_grant(row, client, redirect_uri, verifier, params) do
      issue_first_pair(grant)
    end
  end

  defp redeem(code) do
    case Codes.redeem(code) do
      {:ok, row} ->
        {:ok, row}

      {:error, :reused, row} ->
        revoke_grant(row.grant_uuid, "code_reuse")
        invalid_grant("The authorization code was already used.")

      {:error, :invalid} ->
        invalid_grant("The authorization code is invalid or has expired.")
    end
  end

  defp code_grant(row, %Client{} = client, redirect_uri, verifier, params) do
    grant = Grants.get(row.grant_uuid)

    cond do
      is_nil(grant) or grant.client_uuid != client.uuid ->
        invalid_grant("The authorization code was not issued to this client.")

      row.redirect_uri != redirect_uri ->
        invalid_grant("The redirect_uri does not match the authorization request.")

      not pkce_ok?(verifier, row.code_challenge) ->
        invalid_grant("The code_verifier does not match.")

      true ->
        with :ok <- check_resource(params, grant), do: {:ok, grant}
    end
  end

  defp pkce_ok?(verifier, challenge) do
    computed = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    Plug.Crypto.secure_compare(computed, challenge)
  end

  # Activation and the first pair under the grant's locks: a grant revoked a moment ago
  # (the person withdrew it, the ceiling flow) must not come to life.
  defp issue_first_pair(%Grant{uuid: uuid}) do
    result =
      Grants.locked(uuid, fn grant, key ->
        with true <- usable?(grant, key),
             {:ok, grant} <- activate(grant),
             family = UUIDv7.generate(),
             {:ok, access, access_row} <- Tokens.issue(grant, :access, family: family),
             {:ok, refresh, _row} <- Tokens.issue(grant, :refresh, family: family) do
          log(grant, "oauth.grant_created", %{"client_uuid" => grant.client_uuid})
          response(grant, access, access_row, refresh)
        else
          _ -> repo().rollback(:invalid_grant)
        end
      end)

    case result do
      {:ok, {:ok, _response} = ok} -> ok
      {:error, _reason} -> invalid_grant("The grant is no longer valid.")
    end
  end

  defp activate(%Grant{activated_at: nil} = grant) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    grant |> Ecto.Changeset.change(activated_at: now) |> repo().update()
  end

  defp activate(%Grant{} = grant), do: {:ok, grant}

  # --- refresh token -------------------------------------------------------------

  defp refresh(params) do
    with {:ok, presented} <- required(params, "refresh_token"),
         {:ok, client_id} <- required(params, "client_id"),
         {:ok, client} <- known_client(client_id),
         {:ok, row} <- find_refresh(presented) do
      rotate(row, client, params)
    end
  end

  defp find_refresh(presented) do
    with {:ok, :refresh, hash} <- Tokens.parse(presented),
         %Token{} = row <-
           repo().one(from(t in Token, where: t.token_hash == ^hash and t.kind == "refresh")) do
      {:ok, row}
    else
      _ -> invalid_grant("The refresh token is invalid.")
    end
  end

  defp rotate(%Token{grant_uuid: grant_uuid, uuid: row_uuid}, client, params) do
    result =
      Grants.locked(grant_uuid, fn grant, key ->
        # What the row says now, under the lock: a rival may have used it a moment ago.
        row = repo().get(Token, row_uuid)

        with :ok <- own_grant(grant, client),
             :ok <- usable(grant, key),
             :ok <- check_resource(params, grant),
             :ok <- check_scope(params, grant) do
          by_state(row, grant)
        end
      end)

    case result do
      {:ok, {:ok, _response} = ok} -> ok
      {:ok, {:error, _error, _description} = error} -> error
      {:error, _reason} -> invalid_grant("The refresh token is invalid.")
    end
  end

  defp own_grant(%Grant{client_uuid: client_uuid}, %Client{uuid: client_uuid}), do: :ok

  defp own_grant(_grant, _client),
    do: invalid_grant("The refresh token was not issued to this client.")

  defp by_state(%Token{revoked_at: %DateTime{}, revoke_reason: "retry_superseded"}, grant),
    do: reuse(grant)

  defp by_state(%Token{revoked_at: %DateTime{}}, _grant),
    do: invalid_grant("The refresh token is invalid.")

  defp by_state(%Token{used_at: nil} = row, grant) do
    cond do
      reached?(row.expires_at) -> invalid_grant("The refresh token has expired.")
      mark_used(row) == 1 -> issue_pair(grant, row)
      true -> by_state(repo().get(Token, row.uuid), grant)
    end
  end

  # Used before: a retry only inside the window and while its successor is untouched.
  defp by_state(%Token{used_at: %DateTime{} = used_at} = row, grant) do
    if DateTime.diff(DateTime.utc_now(), used_at) <= @retry_window_seconds,
      do: retry(row, grant),
      else: reuse(grant)
  end

  defp mark_used(%Token{uuid: uuid}) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {count, _} =
      repo().update_all(
        from(t in Token, where: t.uuid == ^uuid and is_nil(t.used_at) and is_nil(t.revoked_at)),
        set: [used_at: now]
      )

    count
  end

  defp retry(%Token{uuid: uuid} = row, grant) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    {superseded, _} =
      repo().update_all(
        from(t in Token,
          where:
            t.parent_uuid == ^uuid and t.kind == "refresh" and is_nil(t.used_at) and
              is_nil(t.revoked_at)
        ),
        set: [revoked_at: now, revoke_reason: "retry_superseded"]
      )

    if superseded >= 1 do
      repo().update_all(
        from(t in Token,
          where: t.parent_uuid == ^uuid and t.kind == "access" and is_nil(t.revoked_at)
        ),
        set: [revoked_at: now, revoke_reason: "retry_superseded"]
      )

      log(grant, "oauth.refresh_retry", %{"family" => row.family})
      issue_pair(grant, row)
    else
      reuse(grant)
    end
  end

  defp issue_pair(%Grant{} = grant, %Token{uuid: parent, family: family}) do
    with {:ok, access, access_row} <-
           Tokens.issue(grant, :access, family: family, parent_uuid: parent),
         {:ok, refresh, _row} <-
           Tokens.issue(grant, :refresh, family: family, parent_uuid: parent) do
      response(grant, access, access_row, refresh)
    else
      {:error, _reason} -> invalid_grant("The tokens could not be issued.")
    end
  end

  defp reuse(%Grant{} = grant) do
    revoke_grant(grant.uuid, "refresh_reuse")
    log(grant, "oauth.refresh_reuse", %{})
    invalid_grant("The refresh token was already used.")
  end

  # --- revocation (RFC 7009) ------------------------------------------------------------

  @doc """
  Ends the grant a presented token (access or refresh) belongs to: its tokens, the grant and
  its hidden key. A client that names itself (`client_id`) must be the grant's own. Always
  `:ok`: whether the token was known, already revoked, or never existed is not told.
  """
  @spec revoke(map()) :: :ok
  def revoke(%{"token" => presented} = params) when is_binary(presented) do
    with {:ok, kind, hash} <- Tokens.parse(presented),
         %Token{grant_uuid: grant_uuid} <-
           repo().one(
             from(t in Token, where: t.token_hash == ^hash and t.kind == ^Atom.to_string(kind))
           ),
         %Grant{} = grant <- Grants.get(grant_uuid),
         true <- own_client?(params, grant) do
      Grants.revoke(grant, reason: "revoked_by_client")
    end

    :ok
  end

  def revoke(_params), do: :ok

  defp own_client?(%{"client_id" => client_id}, %Grant{client_uuid: client_uuid}) do
    match?(%Client{uuid: ^client_uuid}, Clients.get_by_client_id(client_id))
  end

  defp own_client?(_params, _grant), do: true

  # --- shared ----------------------------------------------------------------------

  defp usable(%Grant{} = grant, key) do
    if usable?(grant, key), do: :ok, else: invalid_grant("The grant is no longer valid.")
  end

  defp usable?(%Grant{} = grant, key) do
    Grants.live?(grant) and is_nil(Keys.dead_reason(key)) and
      match?({:ok, _owner}, Keys.active_owner(key))
  end

  defp check_resource(%{"resource" => resource}, %Grant{resource: granted}) do
    with {:ok, given} <- Resource.normalize(resource),
         {:ok, own} <- Resource.normalize(granted),
         true <- given == own do
      :ok
    else
      _ -> {:error, "invalid_target", "The resource is not the one of this grant."}
    end
  end

  defp check_resource(_params, _grant), do: :ok

  # A request cannot widen the scope; naming a part of it only changes the wording of the
  # request: the answer always says what the grant holds.
  defp check_scope(%{"scope" => scope}, %Grant{scopes: granted}) do
    if scope |> String.split(" ", trim: true) |> Enum.all?(&(&1 in granted)),
      do: :ok,
      else: {:error, "invalid_scope", "The scope is wider than the grant."}
  end

  defp check_scope(_params, _grant), do: :ok

  defp response(%Grant{scopes: scopes}, access, %Token{expires_at: expires_at}, refresh) do
    {:ok,
     %{
       "access_token" => access,
       "token_type" => "Bearer",
       "expires_in" => max(DateTime.diff(expires_at, DateTime.utc_now()), 0),
       "refresh_token" => refresh,
       "scope" => Enum.join(scopes, " ")
     }}
  end

  defp known_client(client_id) do
    case Clients.get_by_client_id(client_id) do
      %Client{} = client -> {:ok, client}
      nil -> {:error, "invalid_client", "The client is not known."}
    end
  end

  defp verifier(params) do
    with {:ok, verifier} <- required(params, "code_verifier") do
      if Regex.match?(@verifier, verifier),
        do: {:ok, verifier},
        else: invalid_request("The code_verifier is malformed.")
    end
  end

  defp required(params, name) do
    case Map.get(params, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> invalid_request("#{name} is required.")
    end
  end

  defp invalid_request(description), do: {:error, "invalid_request", description}
  defp invalid_grant(description), do: {:error, "invalid_grant", description}

  defp revoke_grant(grant_uuid, reason), do: Grants.revoke(grant_uuid, reason: reason)

  defp reached?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) != :gt

  # No token, hash, redirect or person's data in the entry.
  defp log(%Grant{} = grant, action, metadata) do
    Activity.log("api", action,
      actor_uuid: grant.user_uuid,
      resource_type: "oauth_grant",
      resource_uuid: grant.uuid,
      permanent: true,
      metadata: metadata
    )
  end

  defp repo, do: RepoHelper.repo()
end
