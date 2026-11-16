defmodule PhoenixKit.API.OAuth.Registration do
  @moduledoc """
  Dynamic Client Registration (RFC 7591), the logic behind `POST /oauth/register`.

  Only **public** clients are registered: the client proves itself with PKCE, never with a
  secret. A `client_secret`, `jwks`, `jwks_uri`, `token_endpoint_auth_method`, `grant_types`,
  `response_types`, `scope` or software statement in the request is ignored, and the answer says
  what the server does (`none`, `authorization_code` and `refresh_token`, `code`), as RFC 7591
  section 3.2.1 lets a server do. What is used:

    * `redirect_uris` (required): one to ten URIs that `PhoenixKit.API.OAuth.RedirectUri` accepts
      to register, none of them on a host the client policy refuses
      (`PhoenixKit.API.OAuth.ClientPolicy`). Otherwise `invalid_redirect_uri`.
    * `client_name`, `client_uri` (optional): text; anything else is `invalid_client_metadata`.
      The name is cleaned and cut like every client name; a home page that is not an https URL is
      left out.

  The `client_id` is `dcr_` and 18 random bytes (base64url): it is not a URL and cannot be
  guessed from the previous one. A client that never receives a grant is removed a day later
  (`PhoenixKit.API.OAuth.Prune`). The registration is written to the activity feed as
  `oauth.client_registered`, with the hosts of its redirects and nothing else of the request.
  """

  alias PhoenixKit.Activity
  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.ClientPolicy
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.RepoHelper

  @max_redirect_uris 10
  @id_bytes 18

  @doc """
  Registers the client `params` describe. `{:ok, document}` is the RFC 7591 answer (the keys
  are strings); `{:error, error, description}` is a refusal (`"invalid_redirect_uri"` or
  `"invalid_client_metadata"`) whose text never repeats the request.
  """
  @spec register(map()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def register(params) when is_map(params) do
    with {:ok, uris} <- redirect_uris(params),
         {:ok, name} <- text(params, "client_name"),
         {:ok, home} <- text(params, "client_uri"),
         :ok <- allowed(uris),
         {:ok, client} <- insert(uris, Clients.clean_name(name), Clients.clean_uri(home)) do
      log(client)
      {:ok, document(client)}
    end
  end

  defp redirect_uris(%{"redirect_uris" => [_ | _] = uris})
       when length(uris) <= @max_redirect_uris do
    if Enum.all?(uris, &RedirectUri.valid?/1), do: {:ok, uris}, else: bad_redirects()
  end

  defp redirect_uris(_params), do: bad_redirects()

  defp bad_redirects do
    {:error, "invalid_redirect_uri",
     "redirect_uris must list one to ten https URIs, or http URIs to the loopback, " <>
       "without a fragment or a wildcard."}
  end

  defp text(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, "invalid_client_metadata", "#{key} must be text."}
    end
  end

  defp allowed(uris) do
    if ClientPolicy.allowed?("dcr", "", uris),
      do: :ok,
      else:
        {:error, "invalid_redirect_uri",
         "A redirect URI is on a host this server does not accept."}
  end

  defp insert(uris, name, home) do
    client_id = "dcr_" <> Base.url_encode64(:crypto.strong_rand_bytes(@id_bytes), padding: false)

    case RepoHelper.repo().insert(%Client{
           kind: "dcr",
           client_id: client_id,
           client_name: name,
           client_uri: home,
           redirect_uris: uris
         }) do
      {:ok, client} ->
        {:ok, client}

      {:error, _changeset} ->
        {:error, "invalid_client_metadata", "The client could not be registered."}
    end
  end

  defp document(%Client{} = client) do
    %{
      "client_id" => client.client_id,
      "client_id_issued_at" => DateTime.to_unix(client.inserted_at),
      "redirect_uris" => client.redirect_uris,
      "token_endpoint_auth_method" => "none",
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"]
    }
    |> put_present("client_name", client.client_name)
    |> put_present("client_uri", client.client_uri)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Hosts only: the path and query of a redirect can carry anything.
  defp log(%Client{} = client) do
    Activity.log("api", "oauth.client_registered",
      resource_type: "oauth_client",
      resource_uuid: client.uuid,
      permanent: true,
      metadata: %{
        "kind" => "dcr",
        "redirect_hosts" => client.redirect_uris |> Enum.map(&RedirectUri.host/1) |> Enum.uniq()
      }
    )
  end
end
