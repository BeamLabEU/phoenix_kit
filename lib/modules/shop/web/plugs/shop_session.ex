defmodule PhoenixKit.Modules.Shop.Web.Plugs.ShopSession do
  @moduledoc """
  Plug that ensures a persistent shop session ID exists.

  This plug generates a unique session ID for guest users and stores it
  both in a dedicated cookie AND in the Phoenix session. This ensures
  the same cart is used across different pages.
  """

  import Plug.Conn

  alias PhoenixKit.Modules.Shop

  @cookie_name "shop_session_id"
  # 30 days
  @cookie_max_age 60 * 60 * 24 * 30

  def init(opts), do: opts

  def call(conn, _opts) do
    if Shop.enabled?() do
      # First try to get from cookie (most reliable)
      # Then fall back to session
      session_id = get_shop_session_id(conn)

      case session_id do
        nil ->
          new_id = generate_session_id()

          conn
          |> put_resp_cookie(@cookie_name, new_id, max_age: @cookie_max_age, http_only: true)
          |> put_session("shop_session_id", new_id)

        existing_id ->
          put_session(conn, "shop_session_id", existing_id)
      end
    else
      conn
    end
  end

  defp get_shop_session_id(conn) do
    # Try cookie first
    conn = fetch_cookies(conn)

    case conn.cookies[@cookie_name] do
      nil ->
        # Fall back to session
        get_session(conn, "shop_session_id")

      cookie_value ->
        cookie_value
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
