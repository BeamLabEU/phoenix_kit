defmodule PhoenixKitWeb.PushOpenController do
  @moduledoc """
  Where a push notification's click lands: `<prefix>/notifications/open/:handle`
  (`PhoenixKit.Notifications.Push`). The handle is opaque and encrypted (the
  account it is for, the link, whether it is a summary, an expiry).

  With the browser's own session:

    1. **the account in use is the one it is for** → the notification (the
       inbox for a summary, when the account may open the inbox);
    2. **it is for another account signed in to this browser, and this
       browser may switch to it** (`MultiSession.gate_allowed?/1`, the account
       in `list_accounts/1`, not a borrowed one) → "This notification is for
       Owner. You're using Anna." with **Switch and open** — a POST with a
       CSRF token, which checks everything again — and **Stay**;
    3. **anything else** (a handle that is forged, altered or expired, or an
       account this browser does not hold) → one generic page that names no
       one: the route is never a way to learn who exists (codex, zai).

  Nothing is marked read here: the page it opens does that.
  """

  use PhoenixKitWeb, :controller
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Notifications.Push
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth, as: WebAuth
  alias PhoenixKitWeb.Users.MultiSession
  alias Plug.CSRFProtection

  @style """
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         max-width: 28rem; margin: 4rem auto; padding: 0 1rem; line-height: 1.5; color: #1f2937; }
  .actions { display: flex; gap: .75rem; margin-top: 1.5rem; align-items: center; }
  button { font: inherit; padding: .5rem 1rem; border-radius: .5rem; border: 0;
           background: #2563eb; color: #fff; cursor: pointer; }
  a { color: #2563eb; }
  """

  def show(conn, %{"handle" => handle}) do
    conn = WebAuth.fetch_phoenix_kit_current_scope(conn, [])

    case Push.read_handle(handle) do
      {:ok, %{user_uuid: target} = opened} ->
        current = conn.assigns[:phoenix_kit_current_user]

        cond do
          match?(%User{uuid: ^target}, current) ->
            redirect(conn, to: destination(conn.assigns[:phoenix_kit_current_scope], opened))

          entry = switchable(conn, target) ->
            render_page(conn, :switch, %{
              target: account_label(entry.user),
              current: current && account_label(current),
              action: Routes.path("/notifications/open/" <> handle, locale: :none),
              csrf_token: CSRFProtection.get_csrf_token()
            })

          true ->
            generic(conn)
        end

      :error ->
        generic(conn)
    end
  end

  def show(conn, _params), do: generic(conn)

  def switch(conn, %{"handle" => handle}) do
    conn = WebAuth.fetch_phoenix_kit_current_scope(conn, [])

    case Push.read_handle(handle) do
      {:ok, %{user_uuid: target} = opened} -> switch_to(conn, target, opened)
      :error -> generic(conn)
    end
  end

  def switch(conn, _params), do: generic(conn)

  defp switch_to(conn, target, opened) do
    cond do
      # Already that account (a second click, a switch in another tab).
      match?(%User{uuid: ^target}, conn.assigns[:phoenix_kit_current_user]) ->
        redirect(conn, to: destination(conn.assigns[:phoenix_kit_current_scope], opened))

      entry = switchable(conn, target) ->
        case MultiSession.switch_to(conn, entry.ref) do
          {:ok, conn, user} -> redirect(conn, to: destination(Scope.for_user(user), opened))
          _ -> generic(conn)
        end

      true ->
        generic(conn)
    end
  end

  # The account the notification is for, when this browser holds it as one
  # of its own (not borrowed) and may switch to it; nil otherwise.
  defp switchable(conn, target) do
    session = get_session(conn)

    if MultiSession.gate_allowed?(session) do
      session
      |> MultiSession.list_accounts()
      |> Enum.find(fn entry ->
        entry.user.uuid == target and not entry.active? and
          (entry[:own?] == true or entry[:root?] == true)
      end)
    end
  rescue
    _ -> nil
  end

  # A summary opens the inbox for someone who may open it; anything else
  # opens the notification's own page (a path on this site only), else the
  # site's home. The inbox is a personal page: the admin area is the whole
  # gate (the same question its own mount asks), not the `notifications`
  # permission, which is the administrative all-users view.
  defp destination(scope, %{summary?: true} = opened) do
    if WebAuth.can_access_admin_view?(
         scope,
         PhoenixKitWeb.Live.Notifications.Inbox
       ) and PhoenixKit.Notifications.enabled?(),
       do: inbox_path(scope),
       else: opened.link || Routes.path("/")
  end

  defp destination(_scope, opened), do: opened.link || Routes.path("/")

  # In the recipient's language: the push-open request carries none, so the
  # redirect went to the default language's inbox. The full dialect when the
  # site serves it, else through the recipient's locale.
  defp inbox_path(%{user: %User{} = user}) do
    locale = RecipientLocale.for_rendering(user)

    if Languages.language_enabled?(locale),
      do: Routes.path("/admin/notifications", locale: locale),
      else:
        RecipientLocale.in_locale(locale, fn ->
          Routes.path("/admin/notifications")
        end)
  rescue
    _ -> Routes.path("/admin/notifications")
  end

  defp inbox_path(_scope), do: Routes.path("/admin/notifications")

  defp account_label(%User{} = user) do
    name = User.display_name(user)
    email = User.delivery_email(user)
    if is_binary(email) and name != email, do: "#{name} (#{email})", else: name
  end

  defp generic(conn) do
    render_page(conn, :generic, %{
      sign_in: Routes.path("/users/log-in"),
      home: Routes.path("/")
    })
  end

  defp render_page(conn, page, assigns) do
    assigns =
      assigns
      |> Map.put_new(:home, Routes.path("/"))
      |> Map.merge(%{page: page, style: @style})

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> html(Safe.to_iodata(page(assigns)))
  end

  defp page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <title>{gettext("Notification")}</title>
        <style nonce={PhoenixKitWeb.CSP.nonce(:style)}>
          <%= Phoenix.HTML.raw(@style) %>
        </style>
      </head>
      <body>
        <%= if @page == :switch do %>
          <h1>{gettext("This notification is for another account")}</h1>
          <p>
            {gettext("It is for %{target}.", target: @target)}
            <span :if={@current}>{gettext("You're using %{current}.", current: @current)}</span>
          </p>
          <form method="post" action={@action}>
            <input type="hidden" name="_csrf_token" value={@csrf_token} />
            <div class="actions">
              <button type="submit">{gettext("Switch and open")}</button>
              <a href={@home}>{gettext("Stay")}</a>
            </div>
          </form>
        <% else %>
          <h1>{gettext("This notification can't be opened here")}</h1>
          <p>
            {gettext(
              "It may be for another account, or it is too old. Sign in with the account it is for to see it."
            )}
          </p>
          <div class="actions">
            <a href={@sign_in}>{gettext("Sign in")}</a>
            <a href={@home}>{gettext("Home")}</a>
          </div>
        <% end %>
      </body>
    </html>
    """
  end
end
