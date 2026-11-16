defmodule PhoenixKit.API.OAuth.Requests do
  @moduledoc """
  The authorization requests that wait for a person's consent (`PhoenixKit.API.OAuth.Request`).

  A request is stored on the server once the authorization endpoint has checked everything
  (client, redirect URI, PKCE, resource), and the browser carries only a short capability URL,
  `/oauth/consent/<token>`: the token is 32 random bytes (256 bits, base64url) and it is **not**
  the row's uuid (a UUIDv7 carries its creation time, and the URL ends up in a session, a
  return-to path and the endpoint log). The consent screen and its form post work on the stored
  row, never on fields the form carries, and the request is used once: `consume/1` is an atomic
  update.

  ## Bound to the browser that started it

  A URL that can be relayed is a weak capability: whoever is handed the consent URL while signed
  in could be talked into allowing a connection somebody else started. So the request is bound to
  the browser that made the authorization request: that browser holds a random `browser` nonce
  (a cookie, `PhoenixKitWeb.OAuth.Responses.bind_browser/1`), and the stored hash is
  `HMAC-SHA256(key: browser, message: token)`, never the plain hash of the token. `fetch/2` finds
  the row only for the pair, so the same URL opened in another browser (or with another nonce)
  finds nothing and meets the "start again" page. Nothing else is stored: no column, and the
  nonce itself stays in the browser.

  A request lives ten minutes. The number of live ones is bounded for the whole install
  (`PhoenixKit.API.Config.oauth_requests_ceiling/0`), because the authorization endpoint is
  public: `create/2` refuses over the ceiling.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Request
  alias PhoenixKit.RepoHelper

  @ttl_seconds 600
  @token_bytes 32
  @token_pattern ~r/\A[A-Za-z0-9_-]{43}\z/
  @ceiling_lock "phoenix_kit_api:oauth_requests"

  @doc "Seconds a request lives."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Stores a validated request of `client`. `attrs` takes `redirect_uri`, `code_challenge`,
  `resource`, `state`, `requested_scopes` and `browser` (the nonce of the browser that made the
  request, required, see `new_browser/0`); the client's name and redirect URIs are pinned in
  the row (`client_snapshot`), so a changed document changes nothing here.

  Returns `{:ok, token, request}` (the token goes into the consent URL and is not kept), or
  `{:error, :busy}` when the install already has as many waiting requests as the ceiling allows
  (counted and inserted under one advisory lock, so requests that arrive together cannot all pass).
  """
  @spec create(Client.t(), map()) :: {:ok, String.t(), Request.t()} | {:error, :busy}
  def create(%Client{} = client, attrs) when is_map(attrs) do
    browser = Map.fetch!(attrs, :browser)
    browser?(browser) || raise ArgumentError, "browser must be a nonce made by new_browser/0"

    # The count and the insert run under one advisory lock for the whole install, so requests
    # that arrive together cannot all pass the ceiling.
    result =
      repo().transaction(fn ->
        repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@ceiling_lock])

        if live_count() >= Config.oauth_requests_ceiling(),
          do: repo().rollback(:busy),
          else: insert(client, attrs, browser)
      end)

    case result do
      {:ok, {secret, request}} -> {:ok, Base.url_encode64(secret, padding: false), request}
      {:error, :busy} -> {:error, :busy}
    end
  end

  defp insert(client, attrs, browser) do
    secret = :crypto.strong_rand_bytes(@token_bytes)

    {:ok, request} =
      repo().insert(%Request{
        request_token_hash: hash(secret, browser),
        client_uuid: client.uuid,
        redirect_uri: Map.fetch!(attrs, :redirect_uri),
        code_challenge: Map.fetch!(attrs, :code_challenge),
        resource: Map.fetch!(attrs, :resource),
        state: Map.get(attrs, :state),
        requested_scopes: Map.get(attrs, :requested_scopes, []),
        client_snapshot: snapshot(client),
        expires_at: DateTime.add(now(), @ttl_seconds, :second)
      })

    {secret, request}
  end

  @doc """
  The live request behind `token` for the browser holding `browser` (not used, not expired), or
  `:error`. A token that is not in the canonical form, and a `browser` that is not a nonce
  `new_browser/0` makes (or is missing), are `:error` without a query.
  """
  @spec fetch(term(), term()) :: {:ok, Request.t()} | :error
  def fetch(token, browser) do
    with {:ok, hash} <- parse(token, browser),
         %Request{} = request <-
           repo().one(
             from(r in Request,
               where:
                 r.request_token_hash == ^hash and is_nil(r.consumed_at) and r.expires_at > ^now()
             )
           ) do
      {:ok, request}
    else
      _ -> :error
    end
  end

  @doc """
  Marks `request` used. Atomic: `:ok` for the one caller that got there first, `:error` for
  any other (a second click, a replayed form) and for a request that has run out meanwhile.
  """
  @spec consume(Request.t()) :: :ok | :error
  def consume(%Request{uuid: uuid}) do
    now = now()

    {count, _} =
      repo().update_all(
        from(r in Request,
          where: r.uuid == ^uuid and is_nil(r.consumed_at) and r.expires_at > ^now
        ),
        set: [consumed_at: now]
      )

    if count == 1, do: :ok, else: :error
  end

  @doc "A new random nonce for a browser that has none: 32 random bytes, base64url."
  @spec new_browser() :: String.t()
  def new_browser, do: Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)

  @doc "Whether `value` is a nonce in the form `new_browser/0` makes."
  @spec browser?(term()) :: boolean()
  def browser?(value), do: is_binary(value) and Regex.match?(@token_pattern, value)

  @doc """
  Whether `value` has the form of a consent token (not whether such a request exists). A token
  and a browser nonce are made the same way, so this is `browser?/1` under the name of its use.
  """
  @spec token?(term()) :: boolean()
  def token?(value), do: browser?(value)

  @doc "How many requests wait for a consent now (not used, not expired)."
  @spec live_count() :: non_neg_integer()
  def live_count do
    repo().aggregate(
      from(r in Request, where: is_nil(r.consumed_at) and r.expires_at > ^now()),
      :count
    )
  end

  defp snapshot(%Client{} = client) do
    %{
      "client_id" => client.client_id,
      "kind" => client.kind,
      "client_name" => client.client_name,
      "client_uri" => client.client_uri,
      "redirect_uris" => client.redirect_uris
    }
  end

  defp parse(token, browser) when is_binary(token) do
    with true <- browser?(browser),
         true <- Regex.match?(@token_pattern, token),
         {:ok, secret} <- Base.url_decode64(token, padding: false),
         @token_bytes <- byte_size(secret),
         true <- Base.url_encode64(secret, padding: false) == token do
      {:ok, hash(secret, browser)}
    else
      _ -> :error
    end
  end

  defp parse(_token, _browser), do: :error

  # Keyed by the browser's nonce: the same token under another nonce is another hash.
  defp hash(secret, browser), do: :crypto.mac(:hmac, :sha256, browser, secret)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp repo, do: RepoHelper.repo()
end
