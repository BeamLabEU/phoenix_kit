defmodule PhoenixKitWeb.OAuth.Pages do
  @moduledoc """
  The pages of the authorization flow: deliberately plain documents with inline style, like the
  password gate's (`PhoenixKitWeb.WebsiteAccessController`): a page a person is asked to trust
  must not depend on the site's assets, theme or scripts, and it carries no script at all.

    * `error/1` - an authorization request that cannot be answered with a redirect. It is the
      same page whatever was wrong (no client, a foreign redirect URI, a repeated parameter): it
      must not tell them apart.
    * `start_again/1` - the request is gone (used, expired, never existed, opened in another
      browser): the person is told to start the connection again in the application.
    * `no_right/1` - the person may not connect applications.
    * `consent/1` - the consent screen.
    * `limit/1` - the person already holds as many connections as the ceiling allows, with the
      list to revoke from.

  Every value shown is escaped by HEEx. The client's name is the client's own text: it is cut to
  80 characters and stripped of control and format characters, and the host the browser will be
  sent to is shown next to it, large.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias Phoenix.HTML.Safe

  @max_name 80

  @style """
  html,body{margin:0;min-height:100%}
  body{font:16px/1.5 system-ui,sans-serif;background:#fafafa;color:#222;display:flex;justify-content:center;padding:2rem 1rem}
  main{width:min(36rem,100%);background:#fff;border:1px solid #ddd;border-radius:.6rem;padding:1.5rem}
  h1{font-size:1.3rem;margin:0 0 1rem}
  h2{font-size:1rem;margin:1.25rem 0 .4rem}
  p{margin:.5rem 0}
  .host{font-size:1.4rem;font-weight:700;word-break:break-all;margin:.25rem 0}
  .warn{border:1px solid #c80;background:#fff7e0;padding:.6rem .8rem;border-radius:.4rem}
  .muted{color:#666;font-size:.9rem}
  .scopes{list-style:none;padding:0;margin:.25rem 0}
  .scopes li{padding:.25rem 0}
  .scopes small{display:block;color:#666;margin-left:1.6rem}
  .write{color:#a40}
  label{cursor:pointer}
  select{font:inherit;padding:.3rem;border:1px solid #bbb;border-radius:.3rem}
  .actions{display:flex;gap:.75rem;margin-top:1.25rem}
  button{font:inherit;padding:.6rem 1rem;border:0;border-radius:.4rem;cursor:pointer;background:#222;color:#fff}
  button.deny,button.secondary{background:#e5e5e5;color:#222}
  .error{color:#a33}
  table{border-collapse:collapse;width:100%}
  td,th{border-bottom:1px solid #eee;padding:.4rem;text-align:left;vertical-align:middle}
  @media (prefers-color-scheme:dark){body{background:#111;color:#eee}main{background:#1a1a1a;border-color:#333}.warn{background:#332a10}.muted,.scopes small{color:#aaa}select{background:#1c1c1c;color:inherit;border-color:#444}button{background:#eee;color:#111}button.deny,button.secondary{background:#333;color:#eee}td,th{border-color:#333}.write{color:#e96}}
  """

  @doc "The client name as shown: stripped of control and format characters, cut to 80 characters."
  @spec client_name(term()) :: String.t()
  def client_name(name) when is_binary(name) do
    name
    |> String.replace(~r/[\p{C}\p{Zl}\p{Zp}]/u, "")
    |> String.trim()
    |> String.slice(0, @max_name)
  end

  def client_name(_name), do: ""

  @doc "The client name as shown, or its `client_id` when the name is empty once stripped."
  @spec client_label(term(), term()) :: String.t()
  def client_label(name, client_id) do
    case client_name(name) do
      "" -> client_name(client_id)
      shown -> shown
    end
  end

  @doc "The error page of a request that cannot be answered with a redirect."
  @spec error(map()) :: iodata()
  def error(assigns) do
    assigns = assign_defaults(assigns)

    render(~H"""
    <.shell title={gettext("This connection cannot be started")}>
      <h1>{gettext("This connection cannot be started")}</h1>
      <p>
        {gettext(
          "The link that brought you here is not valid. Go back to the application and start the connection again."
        )}
      </p>
    </.shell>
    """)
  end

  @doc "A page for an authorization request that is gone or never was."
  @spec start_again(map()) :: iodata()
  def start_again(assigns) do
    assigns = assign_defaults(assigns)

    render(~H"""
    <.shell title={gettext("Start the connection again")}>
      <h1>{gettext("Start the connection again")}</h1>
      <p>
        {gettext(
          "This request has expired or was already used. Go back to the application and start the connection again."
        )}
      </p>
    </.shell>
    """)
  end

  @doc "The page of a person who may not connect applications (`:reason`: `:impersonated` or another)."
  @spec no_right(map()) :: iodata()
  def no_right(assigns) do
    assigns = assign_defaults(assigns)

    render(~H"""
    <.shell title={gettext("You cannot connect applications")}>
      <h1>{gettext("You cannot connect applications")}</h1>
      <p :if={@reason == :impersonated}>
        {gettext("Applications cannot be connected while you are acting as another person.")}
      </p>
      <p :if={@reason != :impersonated}>
        {gettext("You do not have the right to connect applications. Ask an administrator.")}
      </p>
    </.shell>
    """)
  end

  @doc """
  The consent screen. Assigns: `csrf_token`, `action`, `client_name`, `redirect_host`,
  `loopback?`, `email`, `entries` (`PhoenixKit.API.OAuth.Scopes.describe/1`), `preselected`,
  `days` (`{default, choices}`), `error` (`nil` or `:no_scopes`).
  """
  @spec consent(map()) :: iodata()
  def consent(assigns) do
    assigns = assign_defaults(assigns)
    {default_days, day_choices} = assigns.days
    assigns = assign(assigns, default_days: default_days, day_choices: day_choices)

    render(~H"""
    <.shell title={gettext("Allow access")}>
      <h1 id="consent-title">{gettext("%{client} asks for access", client: @client_name)}</h1>
      <p>{gettext("on behalf of %{email}", email: @email)}</p>
      <h2>{gettext("After you decide, your browser is sent to")}</h2>
      <p class="host" id="consent-host">{@redirect_host}</p>
      <p :if={@loopback?} class="warn" id="consent-loopback">
        {gettext(
          "This address is on the computer you are using now. Allow it only if you started this connection yourself."
        )}
      </p>
      <p :if={@error == :no_scopes} class="error" id="consent-error">
        {gettext("Choose at least one permission.")}
      </p>
      <form method="post" action={@action} id="consent-form">
        <input type="hidden" name="_csrf_token" value={@csrf_token} />
        <h2>{gettext("What it may do")}</h2>
        <ul class="scopes">
          <li :for={entry <- @entries}>
            <label>
              <input
                type="checkbox"
                name="scopes[]"
                value={entry.scope}
                checked={entry.scope in @preselected}
              />
              <span class={[not entry.read? && "write"]}>
                {entry.group}: {if entry.read?, do: gettext("read"), else: entry.action}
              </span>
            </label>
            <small :if={entry.tools != []}>{Enum.join(entry.tools, ", ")}</small>
          </li>
        </ul>
        <p class="muted">
          {gettext("Reading is selected by default. Anything that changes data you turn on yourself.")}
        </p>
        <p class="muted">
          {gettext(
            "Permissions are counted across all your roles, not only the one you are using now."
          )}
        </p>
        <h2>{gettext("How long")}</h2>
        <p>
          <select name="days" id="consent-days">
            <option :for={d <- @day_choices} value={d} selected={d == @default_days}>
              {ngettext("%{count} day", "%{count} days", d)}
            </option>
          </select>
        </p>
        <div class="actions">
          <button type="submit" name="decision" value="allow" id="consent-allow">
            {gettext("Allow")}
          </button>
          <button type="submit" name="decision" value="deny" class="deny" id="consent-deny">
            {gettext("Deny")}
          </button>
        </div>
      </form>
    </.shell>
    """)
  end

  @doc """
  The page of a person at the ceiling of connections. Assigns: `csrf_token`, `action` (the revoke
  endpoint), `back` (the consent page), `grants` (the live grants, least used first, with their
  `client` loaded).
  """
  @spec limit(map()) :: iodata()
  def limit(assigns) do
    assigns = assign_defaults(assigns)

    render(~H"""
    <.shell title={gettext("Too many connections")}>
      <h1>{gettext("Too many connections")}</h1>
      <p>
        {gettext(
          "You already have as many connected applications as are allowed. Disconnect one to connect another."
        )}
      </p>
      <table id="grants-table">
        <thead>
          <tr>
            <th>{gettext("Application")}</th>
            <th>{gettext("Connected")}</th>
            <th>{gettext("Last used")}</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={grant <- @grants} id={"grant-#{grant.uuid}"}>
            <td>
              {client_label(
                grant.client && grant.client.client_name,
                grant.client && grant.client.client_id
              )}
            </td>
            <td>{Calendar.strftime(grant.inserted_at, "%Y-%m-%d")}</td>
            <td>
              {if grant.last_used_at, do: Calendar.strftime(grant.last_used_at, "%Y-%m-%d"), else: "-"}
            </td>
            <td>
              <form method="post" action={@action}>
                <input type="hidden" name="_csrf_token" value={@csrf_token} />
                <input type="hidden" name="grant" value={grant.uuid} />
                <button type="submit" class="secondary">{gettext("Disconnect")}</button>
              </form>
            </td>
          </tr>
        </tbody>
      </table>
      <p class="muted">
        <a href={@back} id="limit-back">{gettext("Back to the request")}</a>
      </p>
    </.shell>
    """)
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp shell(assigns) do
    assigns = assign(assigns, :style, @style)

    ~H"""
    <!DOCTYPE html>
    <html lang={Gettext.get_locale(PhoenixKitWeb.Gettext)}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <meta name="referrer" content="no-referrer" />
        <title>{@title}</title>
        <style>
          <%= Phoenix.HTML.raw(@style) %>
        </style>
      </head>
      <body>
        <main>{render_slot(@inner_block)}</main>
      </body>
    </html>
    """
  end

  defp assign_defaults(assigns) do
    assigns
    |> Map.new()
    |> Map.put_new(:reason, nil)
    |> Map.put_new(:error, nil)
    |> Map.put_new(:__changed__, nil)
  end

  defp render(rendered), do: Safe.to_iodata(rendered)
end
