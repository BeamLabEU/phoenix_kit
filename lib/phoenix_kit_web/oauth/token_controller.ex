defmodule PhoenixKitWeb.OAuth.TokenController do
  @moduledoc """
  `POST <prefix>/oauth/token` and `POST <prefix>/oauth/revoke`: the machine endpoints of the
  authorization server. No session, no CSRF, no cookies: the route is in the API's own (empty)
  pipeline, and `PhoenixKit.API.BodyGuard` has already read the form body (16 KB at most) into
  `body_params`; this controller reads **only** `body_params`, so a `?code=...` in the URL is
  never a parameter here.

  Answers are JSON in the form of RFC 6749 section 5: `{"error":..., "error_description":...}`
  (not a problem document), and every one carries `Cache-Control: no-store` and
  `Pragma: no-cache`. A refused request is `400`, except `invalid_client`, which is `401` with a
  `WWW-Authenticate` challenge when the client sent an `Authorization` header and `400`
  otherwise, the rate limit, `429`, and `server_error` (the tokens could not be written), `500`.
  One minute of requests per client network is `api_oauth_token_per_min` (60); the routes are
  declared with `log: false`, so no parameter reaches the log.

  The logic is `PhoenixKit.API.OAuth.Exchange`. `revoke/2` answers `200 {}` whether the token was
  known or not, and `400 invalid_request` only for parameters the database cannot hold (a NUL
  byte); the token endpoint refuses those the same way.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.Exchange
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.API.Problem
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitWeb.OAuth.Responses

  @doc "The token request."
  def create(conn, _params) do
    with :ok <- enabled(conn),
         :ok <- within_limit(conn) do
      case conn |> body() |> Exchange.token() do
        {:ok, tokens} -> json_answer(conn, 200, tokens)
        {:error, error, description} -> error_answer(conn, error, description)
      end
    end
  end

  @doc "The revocation request (RFC 7009)."
  def revoke(conn, _params) do
    with :ok <- enabled(conn),
         :ok <- within_limit(conn) do
      case conn |> body() |> Exchange.revoke() do
        :ok -> json_answer(conn, 200, %{})
        {:error, :invalid_request} -> malformed(conn)
      end
    end
  end

  defp enabled(conn) do
    if Config.oauth_enabled?(), do: :ok, else: Problem.send(conn, :not_found, "", %{})
  end

  defp within_limit(conn) do
    case Limits.hit(:token, IpAddress.client_address(conn)) do
      :ok ->
        :ok

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> json_answer(429, %{
          "error" => "invalid_request",
          "error_description" => "Too many requests."
        })
    end
  end

  defp malformed(conn) do
    json_answer(conn, 400, %{
      "error" => "invalid_request",
      "error_description" => "Every parameter must be a single string."
    })
  end

  # Only what the guard read from the body.
  defp body(%Plug.Conn{body_params: %{} = params}) when not is_struct(params), do: params
  defp body(_conn), do: %{}

  defp error_answer(conn, "invalid_client", description) do
    body = %{"error" => "invalid_client", "error_description" => description}

    case get_req_header(conn, "authorization") do
      [] ->
        json_answer(conn, 400, body)

      _attempted ->
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="oauth"))
        |> json_answer(401, body)
    end
  end

  defp error_answer(conn, "server_error", description),
    do: json_answer(conn, 500, %{"error" => "server_error", "error_description" => description})

  defp error_answer(conn, error, description),
    do: json_answer(conn, 400, %{"error" => error, "error_description" => description})

  defp json_answer(conn, status, body), do: Responses.json(conn, status, body)
end
