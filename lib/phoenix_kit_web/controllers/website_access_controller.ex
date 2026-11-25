defmodule PhoenixKitWeb.WebsiteAccessController do
  @moduledoc """
  The password gate's pages — deliberately plain: a visitor who does not
  know the password sees a blank page with one field and nothing else, no
  site name, no login, no layout.

    * `GET  <prefix>/access` — the prompt (`?to=` is where the visitor was
      going: a path on this site, checked before use).
    * `POST <prefix>/access` — one try. The lockout is checked first; a try
      while locked is recorded as such and never judged. A right answer
      unlocks the session and sends the visitor on.
    * `GET  <prefix>/access/link/:token` — the access link a client was
      given: a page with one button, so opening the link (a preview fetcher,
      a chat client) does not by itself unlock anything.
    * `POST <prefix>/access/link/:token` — the button: unlocks when the
      token is current.
    * `GET  <prefix>/access/status` — answers `ok` while everything else is
      locked, for an uptime check.

  These routes are exempt from the gate itself (see
  `PhoenixKitWeb.Plugs.WebsiteAccess`).
  """
  use PhoenixKitWeb, :controller
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.WebsiteAccess.Gate
  alias PhoenixKitWeb.Plugs.WebsiteAccess, as: AccessPlug
  alias Plug.CSRFProtection

  @notice_key :website_access_notice

  # None of the gate's pages or redirects is for a search engine.
  plug :noindex

  defp noindex(conn, _opts), do: put_resp_header(conn, "x-robots-tag", "noindex, nofollow")

  # ── Prompt ─────────────────────────────────────────────────────────

  def prompt(conn, params) do
    with {:locked, conn} <- passable(conn, return_to(params)) do
      {conn, notice} = pop_notice(conn)

      render_page(conn, 200, %{
        to: return_to(params),
        notice: notice,
        locked: lockout_seconds(conn)
      })
    end
  end

  def verify(conn, params) do
    typed =
      case Map.get(params, "password") do
        value when is_binary(value) -> value
        _ -> ""
      end

    to = return_to(params)

    with {:locked, conn} <- passable(conn, to) do
      case Gate.try(typed, address: IpAddress.client_address(conn), user_agent: user_agent(conn)) do
        {:locked, _seconds} ->
          conn |> put_notice(:locked) |> redirect(to: prompt_path(to))

        {:correct, _} ->
          conn
          |> Gate.unlock()
          |> redirect(to: to)

        {verdict, _} ->
          conn |> put_notice(verdict) |> redirect(to: prompt_path(to))
      end
    end
  end

  # Gate off, or this session may pass: send the visitor on (a redirected
  # conn); otherwise `{:locked, conn}` and the page renders.
  defp passable(conn, to) do
    if Gate.enabled?() do
      case AccessPlug.pass(conn) do
        {:ok, conn} -> redirect(conn, to: to)
        :locked -> {:locked, conn}
      end
    else
      redirect(conn, to: "/")
    end
  end

  # ── Access link ────────────────────────────────────────────────────

  def link(conn, %{"token" => token}) do
    with {:locked, conn} <- passable(conn, "/") do
      if Gate.access_link_valid?(token),
        do: render_link_page(conn, token),
        else: render_page(conn, 404, %{to: "/", notice: :bad_link, locked: 0})
    end
  end

  def link_unlock(conn, %{"token" => token}) do
    if Gate.enabled?() and Gate.access_link_valid?(token) do
      Gate.attempt("",
        address: IpAddress.client_address(conn),
        user_agent: user_agent(conn),
        link: true
      )

      conn
      |> Gate.unlock()
      |> redirect(to: "/")
    else
      render_page(conn, 404, %{to: "/", notice: :bad_link, locked: 0})
    end
  end

  # ── Status ─────────────────────────────────────────────────────────

  def status(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{status: "ok", gate: Gate.enabled?()})
  end

  # ── Helpers ────────────────────────────────────────────────────────

  # A path on this site, and not the gate's own page: `to=<gate>` would send
  # an unlocked visitor round in a circle. No fragment and no `.`/`..`
  # segment either — the browser would drop or fold them and reach the gate
  # under another spelling. `Routes.local_path?/1` is the project's one
  # vetted guard for a client-influenced redirect target — everything else
  # here is gate-specific on top of it.
  defp return_to(%{"to" => to}) when is_binary(to) do
    gate = AccessPlug.gate_path()
    [path | _] = String.split(to, "?", parts: 2)

    if Routes.local_path?(to) and not String.contains?(to, " ") and
         not String.contains?(to, "#") and
         not Enum.any?(String.split(path, "/"), &(&1 in [".", ".."])) and
         path != gate and not String.starts_with?(path, gate <> "/"),
       do: to,
       else: "/"
  end

  defp return_to(_), do: "/"

  defp prompt_path("/"), do: AccessPlug.gate_path()

  defp prompt_path(to),
    do: AccessPlug.gate_path() <> "?" <> URI.encode_query(%{"to" => to})

  defp user_agent(conn), do: conn |> get_req_header("user-agent") |> List.first()

  defp lockout_seconds(conn) do
    case Gate.lockout(IpAddress.client_address(conn)) do
      {:locked, seconds} -> seconds
      :ok -> 0
    end
  end

  defp put_notice(conn, verdict), do: put_session(conn, @notice_key, Atom.to_string(verdict))

  defp pop_notice(conn) do
    case get_session(conn, @notice_key) do
      nil -> {conn, nil}
      value -> {delete_session(conn, @notice_key), String.to_existing_atom(value)}
    end
  end

  # ── Pages ──────────────────────────────────────────────────────────

  defp render_page(conn, status, assigns) do
    assigns =
      assigns
      |> Map.put(:csrf_token, CSRFProtection.get_csrf_token())
      |> Map.put(:action, AccessPlug.gate_path())

    # The page's CSP nonce is read from this connection, whatever the order of the host's plugs.
    conn = PhoenixKitWeb.CSP.put_nonces(conn)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_status(status)
    |> html(Safe.to_iodata(prompt_page(assigns)))
  end

  defp render_link_page(conn, token) do
    assigns = %{
      csrf_token: CSRFProtection.get_csrf_token(),
      action: AccessPlug.gate_path() <> "/link/" <> token
    }

    conn = PhoenixKitWeb.CSP.put_nonces(conn)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> html(Safe.to_iodata(link_page(assigns)))
  end

  defp message(nil), do: nil
  defp message(:empty), do: gettext("Type the password.")
  defp message(:locked), do: gettext("Too many tries.")
  defp message(:bad_link), do: gettext("This link is no longer valid.")
  defp message(_wrong), do: gettext("That is not it.")

  defp locked_message(seconds) when seconds > 0 do
    minutes = div(seconds + 59, 60)

    ngettext(
      "Try again in a minute.",
      "Try again in %{count} minutes.",
      minutes
    )
  end

  defp locked_message(_), do: nil

  # The style is inline on purpose: this page must not depend on the site's
  # assets, theme or layout — it is what a visitor sees instead of the site.
  @style """
  html,body{height:100%;margin:0}
  body{display:flex;align-items:center;justify-content:center;font:16px/1.4 system-ui,sans-serif;background:#fafafa;color:#222}
  form{display:flex;flex-direction:column;gap:.75rem;width:min(20rem,90vw)}
  input{font:inherit;padding:.6rem .75rem;border:1px solid #bbb;border-radius:.4rem;background:#fff;color:inherit}
  input:focus{outline:2px solid #666;outline-offset:1px}
  button{font:inherit;padding:.6rem .75rem;border:0;border-radius:.4rem;background:#222;color:#fff;cursor:pointer}
  button[disabled]{opacity:.5;cursor:default}
  p{margin:0;font-size:.9rem;color:#a33}
  p.muted{color:#666}
  @media (prefers-color-scheme:dark){body{background:#111;color:#eee}input{background:#1c1c1c;border-color:#444}button{background:#eee;color:#111}p{color:#e88}p.muted{color:#999}}
  """

  defp prompt_page(assigns) do
    assigns =
      assigns
      |> Map.put(:style, @style)
      |> Map.put(:message, message(assigns.notice))
      |> Map.put(:locked_message, locked_message(assigns.locked))

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <%!-- A locked-out page reloads itself once the lock has passed, so
             the disabled field comes back without the visitor guessing when. --%>
        <meta :if={@locked > 0} http-equiv="refresh" content={Integer.to_string(@locked + 1)} />
        <title>·</title>
        <style nonce={PhoenixKitWeb.CSP.nonce(:style)}>
          <%= Phoenix.HTML.raw(@style) %>
        </style>
      </head>
      <body>
        <form method="post" action={@action} autocomplete="off">
          <input type="hidden" name="_csrf_token" value={@csrf_token} />
          <input type="hidden" name="to" value={@to} />
          <input
            type="password"
            name="password"
            aria-label="Password"
            autocomplete="off"
            autofocus
            required
            disabled={@locked > 0}
          />
          <button type="submit" disabled={@locked > 0}>→</button>
          <p :if={@message}>{@message}</p>
          <p :if={@locked_message} class="muted">{@locked_message}</p>
        </form>
      </body>
    </html>
    """
  end

  defp link_page(assigns) do
    assigns = Map.put(assigns, :style, @style)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <title>·</title>
        <style nonce={PhoenixKitWeb.CSP.nonce(:style)}>
          <%= Phoenix.HTML.raw(@style) %>
        </style>
      </head>
      <body>
        <form method="post" action={@action}>
          <input type="hidden" name="_csrf_token" value={@csrf_token} />
          <button type="submit">{gettext("Open the site")}</button>
        </form>
      </body>
    </html>
    """
  end
end
