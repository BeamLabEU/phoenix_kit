defmodule PhoenixKitWeb.Plugs.EnsureOAuthScheme do
  @moduledoc """
  Ensures correct HTTPS scheme for OAuth callback URL generation behind reverse proxies.

  This plug checks (in order):
  1. `X-Forwarded-Proto` header (nginx/apache standard)
  2. Explicit `:phoenix_kit, :oauth_base_url` config
  3. Endpoint URL configuration

  ## Usage

  Automatically included in OAuth controller. No manual setup required.

  ## Configuration (Optional)

  For edge cases where headers aren't available:

      config :phoenix_kit,
        oauth_base_url: "https://example.com"

  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      # 1. Check X-Forwarded-Proto header (standard for nginx/apache)
      forwarded_proto = get_forwarded_proto(conn) ->
        apply_scheme(conn, forwarded_proto)

      # 2. Check explicit oauth_base_url config
      base_url = Application.get_env(:phoenix_kit, :oauth_base_url) ->
        apply_base_url(conn, base_url)

      # 3. Check endpoint URL config
      true ->
        apply_endpoint_config(conn)
    end
  end

  defp get_forwarded_proto(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [proto | _] when proto in ["https", "http"] -> proto
      _ -> nil
    end
  end

  defp apply_scheme(conn, "https"), do: %{conn | scheme: :https, port: 443}
  defp apply_scheme(conn, _), do: conn

  defp apply_base_url(conn, base_url) when is_binary(base_url) do
    uri = URI.parse(base_url)

    %{
      conn
      | scheme: parse_scheme(uri.scheme),
        host: uri.host || conn.host,
        port: uri.port || default_port(uri.scheme)
    }
  end

  defp apply_endpoint_config(conn) do
    endpoint = Phoenix.Controller.endpoint_module(conn)

    with endpoint when not is_nil(endpoint) <- endpoint,
         url_config when is_list(url_config) <- get_endpoint_url_config(endpoint) do
      # Extract scheme, host, and port from endpoint URL config
      scheme = url_config[:scheme]
      host = url_config[:host]
      port = url_config[:port]

      # Apply each config value if present
      conn
      |> maybe_set_scheme(scheme)
      |> maybe_set_host(host)
      |> maybe_set_port(port)
    else
      _ -> conn
    end
  rescue
    KeyError -> conn
  end

  defp get_endpoint_url_config(endpoint_module) do
    # Get otp_app from endpoint config (correct way)
    otp_app = endpoint_module.config(:otp_app)

    case Application.get_env(otp_app, endpoint_module) do
      nil -> []
      config -> Keyword.get(config, :url, [])
    end
  end

  # Helper functions to conditionally set conn fields
  defp maybe_set_scheme(conn, nil), do: conn
  defp maybe_set_scheme(conn, scheme), do: %{conn | scheme: parse_scheme(scheme)}

  defp maybe_set_host(conn, nil), do: conn
  defp maybe_set_host(conn, host), do: %{conn | host: host}

  defp maybe_set_port(conn, nil), do: conn
  defp maybe_set_port(conn, port), do: %{conn | port: port}

  defp parse_scheme("https"), do: :https
  defp parse_scheme("http"), do: :http
  defp parse_scheme(_), do: :https

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: 443
end
