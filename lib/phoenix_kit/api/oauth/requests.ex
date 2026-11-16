defmodule PhoenixKit.API.OAuth.Requests do
  @moduledoc """
  The authorization requests that wait for a person's consent (`PhoenixKit.API.OAuth.Request`).

  A request is stored on the server once the authorization endpoint has checked everything
  (client, redirect URI, PKCE, resource), and the browser carries only a short capability URL,
  `/oauth/consent/<token>`: the token is 32 random bytes (256 bits, base64url), only its SHA-256
  is stored, and it is **not** the row's uuid (a UUIDv7 carries its creation time, and the URL
  ends up in a session, a return-to path and the endpoint log). The consent screen and its form
  post work on the stored row, never on fields the form carries, and the request is used once:
  `consume/1` is an atomic update.

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

  @doc "Seconds a request lives."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  Stores a validated request of `client`. `attrs` takes `redirect_uri`, `code_challenge`,
  `resource`, `state` and `requested_scopes`; the client's name and redirect URIs are pinned in
  the row (`client_snapshot`), so a changed document changes nothing here.

  Returns `{:ok, token, request}` (the token goes into the consent URL and is not kept), or
  `{:error, :busy}` when the install already has as many waiting requests as the ceiling allows.
  """
  @spec create(Client.t(), map()) :: {:ok, String.t(), Request.t()} | {:error, :busy}
  def create(%Client{} = client, attrs) when is_map(attrs) do
    if live_count() >= Config.oauth_requests_ceiling() do
      {:error, :busy}
    else
      secret = :crypto.strong_rand_bytes(@token_bytes)
      now = now()

      {:ok, request} =
        repo().insert(%Request{
          request_token_hash: hash(secret),
          client_uuid: client.uuid,
          redirect_uri: Map.fetch!(attrs, :redirect_uri),
          code_challenge: Map.fetch!(attrs, :code_challenge),
          resource: Map.fetch!(attrs, :resource),
          state: Map.get(attrs, :state),
          requested_scopes: Map.get(attrs, :requested_scopes, []),
          client_snapshot: snapshot(client),
          expires_at: DateTime.add(now, @ttl_seconds, :second)
        })

      {:ok, Base.url_encode64(secret, padding: false), request}
    end
  end

  @doc """
  The live request behind `token` (not used, not expired), or `:error`. A token that is not in
  the canonical form is `:error` without a query.
  """
  @spec fetch(term()) :: {:ok, Request.t()} | :error
  def fetch(token) do
    with {:ok, hash} <- parse(token),
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
      "client_name" => client.client_name,
      "client_uri" => client.client_uri,
      "redirect_uris" => client.redirect_uris
    }
  end

  defp parse(token) when is_binary(token) do
    with true <- Regex.match?(@token_pattern, token),
         {:ok, secret} <- Base.url_decode64(token, padding: false),
         @token_bytes <- byte_size(secret),
         true <- Base.url_encode64(secret, padding: false) == token do
      {:ok, hash(secret)}
    else
      _ -> :error
    end
  end

  defp parse(_token), do: :error

  defp hash(secret), do: :crypto.hash(:sha256, secret)

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp repo, do: RepoHelper.repo()
end
