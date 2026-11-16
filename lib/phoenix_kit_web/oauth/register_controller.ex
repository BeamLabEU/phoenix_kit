defmodule PhoenixKitWeb.OAuth.RegisterController do
  @moduledoc """
  `POST <prefix>/oauth/register`: Dynamic Client Registration (RFC 7591), for the clients that
  have no metadata document (Claude Code, MCP Inspector, older clients).

  Behind its own switch, `api_oauth_dcr_enabled` (off by default; it also needs OAuth on): while
  it is off the endpoint does not exist (`404`). No session, no CSRF, no cookie: the route is in
  the API's empty pipeline and `PhoenixKit.API.BodyGuard` has already read the JSON body (16 KB at
  most) into `body_params`, the only place this controller reads.

  Each request is counted before anything is read: against `api_oauth_register_per_hour` (10) of
  its network and `api_oauth_register_per_day` (200) of the whole install (`429`). Answers are
  the JSON of RFC 7591 (`201` with the client; `400` with `error` and `error_description`),
  `Cache-Control: no-store` and `Pragma: no-cache`. The route is declared with `log: false`.

  The logic is `PhoenixKit.API.OAuth.Registration`.
  """
  use PhoenixKitWeb, :controller

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.OAuth.Limits
  alias PhoenixKit.API.OAuth.Registration
  alias PhoenixKit.API.Problem
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKitWeb.OAuth.Responses

  @doc "The registration request."
  def create(conn, _params) do
    with :ok <- enabled(conn),
         :ok <- within_limits(conn) do
      case conn |> body() |> Registration.register() do
        {:ok, document} ->
          Responses.json(conn, 201, document)

        {:error, error, description} ->
          Responses.json(conn, 400, %{"error" => error, "error_description" => description})
      end
    end
  end

  defp enabled(conn) do
    if Config.oauth_dcr_enabled?(), do: :ok, else: Problem.send(conn, :not_found, "", %{})
  end

  defp within_limits(conn) do
    ip = IpAddress.client_address(conn)

    with :ok <- Limits.hit(:register_ip, ip),
         :ok <- Limits.hit(:register_global, nil) do
      :ok
    else
      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> Responses.json(429, %{
          "error" => "invalid_request",
          "error_description" => "Too many requests."
        })
    end
  end

  # Only what the guard read from the body.
  defp body(%Plug.Conn{body_params: %{} = params}) when not is_struct(params), do: params
  defp body(_conn), do: %{}
end
