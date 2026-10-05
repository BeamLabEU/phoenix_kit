defmodule PhoenixKitWeb.Plugs.AlreadyLoggedOut do
  @moduledoc """
  Lets a log-out from someone who is already logged out through the host's
  CSRF check, instead of having it refused.

  The log-out button submits the CSRF token of the session it was rendered
  in. Once that session is gone — a double click, a second tab — the token
  no longer matches, and the host's `protect_from_forgery` answers **403
  Forbidden** to an action that has in fact already succeeded. This plug
  runs ahead of the `:browser` pipeline on the routes that carry log-out and
  marks such a request as exempt (`:plug_skip_csrf_protection`, the switch
  `Plug.CSRFProtection` reads). The request then takes the ordinary path:
  the same pipelines, the same controller, the same flash and the same
  locale-aware redirect as a first log-out.

  It acts only when there is nothing to log out: no session token, no
  account stack, and no remember-me cookie that could still sign the
  visitor back in. Anything else is left untouched and meets the CSRF check
  as before. Nothing is skipped that mattered — the request changes no
  state, and `GET /users/log-out` already logs out without a token.

  Wired by `PhoenixKitWeb.Integration`; a host has nothing to add.
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKitWeb.Users.Auth, as: UserAuth
  alias PhoenixKitWeb.Users.MultiSession

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "DELETE", path_info: path_info} = conn, _opts) do
    if List.last(path_info) == "log-out" do
      conn |> fetch_session() |> fetch_cookies() |> exempt_if_logged_out()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp exempt_if_logged_out(conn) do
    if logged_out?(conn),
      do: put_private(conn, :plug_skip_csrf_protection, true),
      else: conn
  end

  defp logged_out?(conn) do
    MultiSession.stack_tokens(get_session(conn)) == [] and
      not Map.has_key?(conn.req_cookies, UserAuth.remember_me_cookie())
  end
end
