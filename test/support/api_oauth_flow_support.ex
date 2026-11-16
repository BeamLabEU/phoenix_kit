defmodule PhoenixKit.API.OAuthFlowSupport do
  @moduledoc """
  Requests of the authorization flow through the real endpoint, router, body guard and database,
  for the tests of the flow: the browser side (`authorize`, the consent page and its answer) and
  the machine side (`token`, `revoke`, the MCP call with a token).

  Each request gets an address of its own (`X-Forwarded-For`), so the per-network buckets of
  different requests never meet. `browser/1` is a request of a signed-in person (a session token
  in the test session, as `PhoenixKitWeb.ConnCase.log_in_user/2` does); `browser/0` is an
  anonymous one. Parameters of the token endpoint are sent as a form body, as a real client does.
  """

  import Plug.Conn

  alias Phoenix.ConnTest
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.OAuthTestSupport
  alias PhoenixKit.Test.ApiHarness
  alias PhoenixKit.Utils.Routes

  @endpoint PhoenixKitWeb.Endpoint

  @doc "An anonymous browser request."
  def browser, do: ConnTest.build_conn() |> ApiHarness.with_client_ip()

  @doc "A request of a signed-in person."
  def browser(user) do
    ConnTest.build_conn()
    |> PhoenixKitWeb.ConnCase.log_in_user(user)
    |> ApiHarness.with_client_ip()
  end

  @doc "The path of an OAuth route under the kit's URL prefix."
  def path(rest), do: Routes.path("/oauth" <> rest)

  @doc "GET `/oauth/authorize` with `params`."
  def authorize(conn, params),
    do: ConnTest.dispatch(conn, @endpoint, :get, path("/authorize"), params)

  @doc "GET the consent page `id`."
  def consent(conn, id),
    do: ConnTest.dispatch(conn, @endpoint, :get, path("/consent/" <> id), nil)

  @doc "POST the answer to the consent page `id`."
  def decide(conn, id, params),
    do: ConnTest.dispatch(conn, @endpoint, :post, path("/consent/" <> id), params)

  @doc "POST the revoke form of the consent page `id`."
  def disconnect(conn, id, params),
    do: ConnTest.dispatch(conn, @endpoint, :post, path("/consent/" <> id <> "/revoke"), params)

  @doc "POST `/oauth/token` with a form body of `params`."
  def token(params, opts \\ []), do: form_post("/token", params, opts)

  @doc "POST `/oauth/revoke` with a form body of `params`."
  def revoke(params, opts \\ []), do: form_post("/revoke", params, opts)

  defp form_post(rest, params, opts) do
    body = if is_binary(params), do: params, else: URI.encode_query(params)

    ConnTest.build_conn()
    |> ApiHarness.with_client_ip(Keyword.get_lazy(opts, :ip, &ApiHarness.unique_ip/0))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> ConnTest.dispatch(@endpoint, :post, path(rest), body)
  end

  @doc "The JSON body of a sent response."
  def body(conn), do: JSON.decode!(conn.resp_body)

  @doc "The query parameters of the `location` header of a redirect, as a map."
  def location_params(conn) do
    [location] = get_resp_header(conn, "location")
    location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end

  @doc "The `location` header of a redirect."
  def location(conn), do: conn |> get_resp_header("location") |> List.first()

  @doc "The id of the consent page an authorize redirect leads to."
  def consent_id(conn) do
    [_, id] = Regex.run(~r|/oauth/consent/([A-Za-z0-9_-]{43})\z|, location(conn))
    id
  end

  @doc "A valid authorize query for `client` and PKCE `challenge`, with `overrides` (a `nil` removes a key)."
  def authorize_params(client, challenge, overrides \\ %{}) do
    %{
      "response_type" => "code",
      "client_id" => client.client_id,
      "redirect_uri" => hd(client.redirect_uris),
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "st-" <> Integer.to_string(System.unique_integer([:positive]))
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Runs the flow up to the code for `user`: authorize, open the consent page, allow `scopes`.
  Returns `%{code, verifier, client, redirect_uri, state, id}`.
  """
  def code_for(user, client, scopes, extra \\ %{}) do
    {verifier, challenge} = OAuthTestSupport.pkce()
    params = authorize_params(client, challenge, extra)

    id = browser() |> authorize(params) |> consent_id()

    answer =
      decide(browser(user), id, %{"decision" => "allow", "scopes" => scopes, "days" => "30"})

    %{"code" => code} = location_params(answer)

    %{
      code: code,
      verifier: verifier,
      client: client,
      redirect_uri: params["redirect_uri"],
      state: params["state"],
      id: id
    }
  end

  @doc "The token request that exchanges `flow`'s code."
  def exchange_code(flow, overrides \\ %{}) do
    %{
      "grant_type" => "authorization_code",
      "code" => flow.code,
      "code_verifier" => flow.verifier,
      "redirect_uri" => flow.redirect_uri,
      "client_id" => flow.client.client_id
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Map.new()
    |> token()
  end

  @doc "The refresh request for `refresh_token` of `client`."
  def refresh(client, refresh_token, overrides \\ %{}) do
    %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => client.client_id
    }
    |> Map.merge(overrides)
    |> token()
  end

  @doc "A JSON-RPC `tools/list` to the admin MCP endpoint with `access_token`."
  def tools_list(access_token) do
    payload = JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    ConnTest.build_conn()
    |> ApiHarness.with_client_ip()
    |> ApiHarness.bearer(access_token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put_req_header("mcp-protocol-version", "2025-06-18")
    |> ConnTest.dispatch(@endpoint, :post, Routes.path("/mcp/admin"), payload)
  end

  @doc "The names of the tools in a `tools_list/1` answer."
  def tool_names(conn),
    do: conn |> body() |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])

  @doc "Like `PhoenixKit.API.OAuthTestSupport.oauth_holder/1`, kept here for the flow tests."
  def holder(permissions \\ ["dashboard"]) do
    {user, role, _scope} = OAuthTestSupport.oauth_holder(permissions)
    {user, role}
  end

  @doc false
  def unique_ip, do: KeyTestSupport.unique_ip()
end
