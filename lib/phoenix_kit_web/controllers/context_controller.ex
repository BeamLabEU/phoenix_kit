defmodule PhoenixKitWeb.ContextController do
  @moduledoc """
  Controller for handling dashboard context switching.

  Provides a POST endpoint that sets the selected context ID in the session
  and redirects back to the referring page.
  """

  use PhoenixKitWeb, :controller

  alias PhoenixKit.Dashboard.ContextSelector

  @doc """
  Sets the current context in the session and redirects back.

  ## Parameters

  - `id` - The context ID to set as current

  ## Response

  Redirects to the referer URL, or `/dashboard` if no referer is present.
  """
  def set(conn, %{"id" => id}) do
    config = ContextSelector.get_config()

    if config.enabled do
      session_key = config.session_key
      redirect_path = get_redirect_path(conn)

      conn
      |> put_session(session_key, id)
      |> redirect(to: redirect_path)
    else
      conn
      |> put_flash(:error, "Context switching is not enabled")
      |> redirect(to: "/dashboard")
    end
  end

  def set(conn, _params) do
    conn
    |> put_flash(:error, "Invalid context")
    |> redirect(to: get_redirect_path(conn))
  end

  # Private functions

  defp get_redirect_path(conn) do
    referer = get_req_header(conn, "referer") |> List.first()

    if is_nil(referer) or referer == "" do
      default_redirect()
    else
      parse_referer(referer, conn)
    end
  end

  defp parse_referer(referer, conn) do
    case URI.parse(referer) do
      %URI{host: host, path: path} when is_binary(path) ->
        # Only allow same-host redirects for security
        if same_host?(host, conn) do
          path
        else
          default_redirect()
        end

      _ ->
        default_redirect()
    end
  end

  defp same_host?(nil, _conn), do: true
  defp same_host?("", _conn), do: true

  defp same_host?(referer_host, conn) do
    request_host = conn.host
    referer_host == request_host
  end

  defp default_redirect do
    url_prefix = PhoenixKit.Config.get_url_prefix()
    "#{url_prefix}/dashboard"
  end
end
