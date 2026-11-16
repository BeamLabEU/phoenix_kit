defmodule PhoenixKitWeb.OAuth.AuthorizeController do
  @moduledoc """
  `GET <prefix>/oauth/authorize`: the entry of the authorization code flow.

  It runs under the host's `:browser` pipeline and **without** a login plug. It checks the
  request (`PhoenixKit.API.OAuth.Authorize`), stores it on the server
  (`PhoenixKit.API.OAuth.Requests`) and sends the browser to `<prefix>/oauth/consent/<id>`,
  a short capability URL: that page asks for the login, and the long query of the request never
  travels through the sign-in as a return-to path.

  A request that cannot be trusted with a redirect (no such client, a redirect URI the client
  did not register, a repeated parameter) gets an error page, the same whatever was wrong,
  and never a redirect. Once the redirect URI is confirmed, errors go to the client with `state`
  and `iss`.

  Counted before anything is read: one request of the client's network against
  `api_oauth_authorize_per_min` (`429` and a page); a full table of waiting requests answers
  `503` and a page. Switched off (`api_oauth_enabled`) the endpoint does not exist (`404`).
  The route is declared with `log: false`: the query holds `state` and the PKCE challenge.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.Authorize
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.API.OAuth.Requests
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.OAuth.Pages
  alias PhoenixKitWeb.OAuth.Responses

  plug :secure_headers

  defp secure_headers(conn, _opts), do: Responses.secure(conn)

  @doc "Validates a request, stores it and redirects to the consent page."
  def new(conn, _params) do
    with :ok <- enabled(conn),
         :ok <- within_limit(conn) do
      conn.query_params
      |> Authorize.validate(conn.query_string)
      |> answer(conn)
    end
  end

  defp enabled(conn) do
    if Config.oauth_enabled?(), do: :ok, else: error_page(conn, 404)
  end

  defp within_limit(conn) do
    case Limits.hit(:authorize, IpAddress.client_address(conn)) do
      :ok ->
        :ok

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> error_page(429)
    end
  end

  defp answer({:page_error, _reason}, conn), do: error_page(conn, 400)

  defp answer({:redirect_error, error}, conn) do
    Responses.to_client(conn, error.redirect_uri,
      error: error.error,
      error_description: error.description,
      state: error.state
    )
  end

  defp answer({:ok, request}, conn) do
    attrs = %{
      redirect_uri: request.redirect_uri,
      code_challenge: request.code_challenge,
      resource: request.resource,
      state: request.state,
      requested_scopes: request.scopes
    }

    case Requests.create(request.client, attrs) do
      {:ok, token, _row} ->
        touch(request.client)
        redirect(conn, to: Routes.path("/oauth/consent/" <> token))

      {:error, :busy} ->
        conn
        |> put_resp_header("retry-after", "30")
        |> error_page(503)
    end
  end

  defp error_page(conn, status), do: Responses.page(conn, status, Pages.error(%{}))

  # The client was seen now (a registered client nobody uses can be removed by its age). A
  # failed write must not turn a valid request into an error.
  defp touch(client) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    client
    |> Ecto.Changeset.change(last_seen_at: now)
    |> RepoHelper.repo().update()

    :ok
  rescue
    _ -> :ok
  end
end
