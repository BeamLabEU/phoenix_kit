defmodule PhoenixKit.API.OAuth.Authorize do
  @moduledoc """
  The checks of an authorization request (`GET /oauth/authorize`, RFC 6749 section 4.1.1, with
  PKCE, RFC 7636, and a resource indicator, RFC 8707).

  `validate/3` answers one of three things:

    * `{:ok, request}` - everything is in order; `request` carries the `client`, the confirmed
      `redirect_uri`, the `code_challenge`, the normalized `resource` (the install's own when the
      client sent none), the requested `scopes` (only those an enabled admin tool declares), and
      the `state`.
    * `{:page_error, reason}` - the request cannot be trusted with a redirect: no client, a
      redirect URI the client did not register, a repeated or malformed parameter, a client
      the policy refuses, a metadata document that could not be had. The browser gets an error
      page and **never a redirect** (an unvalidated `redirect_uri` is an open redirect). The page
      is the same for every `reason`: it must not tell a missing client from a foreign redirect
      URI. Two reasons only are told apart, by status: `:rate_limited` (too many metadata fetches)
      and `:busy` (too many run at once). `reason` is for the log and the tests.
    * `{:redirect_error, error}` - the client and the redirect URI are confirmed (the URI matches
      one the client registered, `PhoenixKit.API.OAuth.RedirectUri`), the rest is wrong:
      the error goes to the client in a redirect (`error`, `description`, `state`). Only for a
      **pre-registered** client, one an administrator added. A client that named itself (a
      metadata document, a dynamic registration) is not verified, and this request is made before
      any sign-in or consent screen, so a redirect to an address that client listed would be an
      open redirector on this site's domain: such a request that is wrong in the rest is a
      `{:page_error, :unverified_client_error}`, an error page of ours. The client hears of a
      refusal only when a person denies it on the consent screen.

  The client is `PhoenixKit.API.OAuth.Clients.resolve/2`: a stored one, or the one a metadata
  document at its URL describes (fetched here, once the form of the URL, the policy and the limits
  allow it; `opts[:ip]` is the address of the request, for the limits). The redirect URI is
  compared with the list the client's row holds.

  Read in this order: the client, the redirect URI, then `response_type`, `request`,
  `request_uri`, the PKCE challenge and its method (`S256` only; `plain` is refused), `resource`,
  `scope` and `state`. `prompt` and `id_token_hint` are ignored. Unknown scopes are dropped (a `scope`
  that names only unknown ones names nothing: the person chooses on the consent screen); an empty
  `resource` is treated as omitted.

  A parameter that is repeated (or written as a list or a map) makes the whole request a page
  error: which of two values is meant cannot be known, and one of them may be the client's own
  redirect. So does text the database cannot hold, a NUL byte in any parameter
  (`PhoenixKit.API.OAuth.Input`).
  """

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.API.OAuth.Clients
  alias PhoenixKit.API.OAuth.Input
  alias PhoenixKit.API.OAuth.RedirectUri
  alias PhoenixKit.API.OAuth.Resource
  alias PhoenixKit.API.OAuth.Scopes

  @max_state 512
  @max_client_id 2048
  @challenge ~r/\A[A-Za-z0-9\-._~]{43,128}\z/

  @type request :: %{
          client: Client.t(),
          redirect_uri: String.t(),
          code_challenge: String.t(),
          resource: String.t(),
          scopes: [String.t()],
          state: String.t() | nil
        }

  @type redirect_error :: %{
          redirect_uri: String.t(),
          error: String.t(),
          description: String.t(),
          state: String.t() | nil
        }

  @spec validate(map(), String.t() | nil, keyword()) ::
          {:ok, request()}
          | {:page_error, atom()}
          | {:redirect_error, redirect_error()}
  def validate(params, query_string, opts \\ [])

  def validate(params, query_string, opts) when is_map(params) do
    with :ok <- check_plain(params, query_string),
         {:ok, client} <- client(params, opts),
         {:ok, redirect_uri} <- redirect_uri(params, client) do
      continue(params, client, redirect_uri)
    else
      {:page_error, _reason} = error -> error
    end
  end

  def validate(_params, _query_string, _opts), do: {:page_error, :malformed}

  # --- what cannot be trusted with a redirect -------------------------------

  # Every value must be a string the database can hold (no NUL byte) and no name may appear twice
  # (nor be written `a[]=`).
  defp check_plain(params, query_string) do
    cond do
      not Enum.all?(params, fn {_name, value} -> is_binary(value) end) ->
        {:page_error, :malformed}

      not Input.valid?(params) ->
        {:page_error, :malformed}

      repeated?(query_string) ->
        {:page_error, :repeated_parameter}

      true ->
        :ok
    end
  end

  defp repeated?(query_string) when is_binary(query_string) do
    names =
      query_string
      |> URI.query_decoder()
      |> Enum.map(fn {name, _value} -> name end)

    length(names) != length(Enum.uniq(names)) or
      Enum.any?(names, &String.contains?(&1, ["[", "]"]))
  rescue
    _ -> true
  end

  defp repeated?(_query_string), do: false

  defp client(%{"client_id" => client_id}, opts) when is_binary(client_id) do
    with true <- byte_size(client_id) in 1..@max_client_id,
         {:ok, %Client{} = client} <- Clients.resolve(client_id, opts) do
      {:ok, client}
    else
      {:error, reason} when reason in [:rate_limited, :busy] -> {:page_error, reason}
      {:error, :not_allowed} -> {:page_error, :client_not_allowed}
      _ -> {:page_error, :unknown_client}
    end
  end

  defp client(_params, _opts), do: {:page_error, :unknown_client}

  defp redirect_uri(%{"redirect_uri" => uri}, %Client{redirect_uris: registered})
       when is_binary(uri) do
    if RedirectUri.allowed?(uri, registered),
      do: {:ok, uri},
      else: {:page_error, :unknown_redirect_uri}
  end

  defp redirect_uri(_params, _client), do: {:page_error, :unknown_redirect_uri}

  # --- the redirect URI is confirmed: from here on the client is told ---------

  defp continue(params, client, redirect_uri) do
    state = state(params)

    with :ok <- check_state(params),
         :ok <- check_response_type(params),
         :ok <- check_unsupported(params),
         {:ok, challenge} <- check_challenge(params),
         {:ok, resource} <- check_resource(params),
         {:ok, scopes} <- check_scope(params) do
      {:ok,
       %{
         client: client,
         redirect_uri: redirect_uri,
         code_challenge: challenge,
         resource: resource,
         scopes: scopes,
         state: state
       }}
    else
      {:error, error, description} ->
        refuse(client, redirect_uri, error, description, state)
    end
  end

  defp refuse(%Client{kind: "preregistered"}, redirect_uri, error, description, state) do
    {:redirect_error,
     %{redirect_uri: redirect_uri, error: error, description: description, state: state}}
  end

  defp refuse(%Client{}, _redirect_uri, _error, _description, _state),
    do: {:page_error, :unverified_client_error}

  # An over-long state is refused, and is not echoed back.
  defp state(%{"state" => state}) when is_binary(state) and byte_size(state) <= @max_state,
    do: state

  defp state(_params), do: nil

  defp check_state(%{"state" => state}) when byte_size(state) > @max_state,
    do: {:error, "invalid_request", "The state is too long."}

  defp check_state(_params), do: :ok

  defp check_response_type(%{"response_type" => "code"}), do: :ok

  defp check_response_type(_params),
    do: {:error, "unsupported_response_type", "Only response_type=code is supported."}

  defp check_unsupported(%{"request" => _}),
    do: {:error, "request_not_supported", "Request objects are not supported."}

  defp check_unsupported(%{"request_uri" => _}),
    do: {:error, "request_uri_not_supported", "Request objects are not supported."}

  defp check_unsupported(_params), do: :ok

  defp check_challenge(params) do
    challenge = Map.get(params, "code_challenge")

    cond do
      Map.get(params, "code_challenge_method") != "S256" ->
        {:error, "invalid_request", "PKCE with code_challenge_method=S256 is required."}

      not (is_binary(challenge) and Regex.match?(@challenge, challenge)) ->
        {:error, "invalid_request", "The code_challenge is missing or malformed."}

      true ->
        {:ok, challenge}
    end
  end

  # No `scope`, an empty one, or one that names only values this server does not know: nothing
  # is named, and the person chooses on the consent screen. Unknown names are dropped without a
  # word: an error for them would tell an anonymous caller which scopes exist.
  defp check_scope(%{"scope" => scope}) when is_binary(scope), do: {:ok, Scopes.parse(scope)}

  defp check_scope(_params), do: {:ok, []}

  # No resource, or an empty one (RFC 6749 sections 3.1 and 3.2: a parameter sent without a value
  # is omitted): the one this server protects. A resource that is not it is `invalid_target`.
  defp check_resource(%{"resource" => ""}), do: {:ok, Resource.resource()}

  defp check_resource(%{"resource" => resource}) do
    if Resource.matches?(resource),
      do: {:ok, Resource.resource()},
      else: {:error, "invalid_target", "The resource is not served by this authorization server."}
  end

  defp check_resource(_params), do: {:ok, Resource.resource()}
end
