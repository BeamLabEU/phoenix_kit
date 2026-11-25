defmodule PhoenixKitWeb.PushController do
  @moduledoc """
  The browser's side of push notifications (`PhoenixKit.Notifications.Push`):

    * `GET <prefix>/push/sw.js` — the service worker, with the site's public
      VAPID key and the resubscribe address in front of
      `priv/static/assets/pk_push_sw.js`. `Cache-Control: no-cache`, so a new
      release reaches browsers. Its scope is `<prefix>/push/`: push and clicks
      work from there, and it never sits in front of the host's pages.
    * `GET <prefix>/push/manifest.webmanifest` — the web app manifest from the
      site's name, logo and accent colour: what an iPhone needs to add the
      site to its Home Screen, the only way iOS gets web push.
    * `GET <prefix>/push/install` — the page an iPhone user opens in Safari to
      add the site to the Home Screen (it links the manifest itself, so the
      host's own layout needs nothing).
    * `POST <prefix>/push/resubscribe` — the worker's report of a rotated
      subscription (`pushsubscriptionchange`): the old one's `auth` secret
      proves it; no session, no CSRF token (a service worker has neither).
  """

  use PhoenixKitWeb, :controller
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Notifications.Push
  alias PhoenixKit.Notifications.Push.WebPush
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @worker_path Path.join([__DIR__, "..", "..", "..", "priv", "static", "assets", "pk_push_sw.js"])
  @external_resource @worker_path
  @worker File.read!(@worker_path)

  def service_worker(conn, _params) do
    config =
      Jason.encode!(%{
        key: if(Push.enabled?(), do: WebPush.public_key_b64()),
        resubscribe: Routes.path("/push/resubscribe", locale: :none)
      })

    conn
    |> put_resp_content_type("text/javascript")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, "self.PK_PUSH = #{config};\n" <> @worker)
  end

  def manifest(conn, _params) do
    name = site_name()
    icon = logo()

    manifest =
      %{
        id: Routes.path("/push/app", locale: :none),
        name: name,
        short_name: String.slice(name, 0, 12),
        start_url: Routes.path("/profile/settings/notifications", locale: :none),
        # The installed app's navigation scope is the kit's own root. `"/"`
        # would claim the whole origin when the kit is mounted under a prefix.
        scope: Routes.path("/", locale: :none),
        display: "standalone",
        theme_color: accent(),
        background_color: "#ffffff",
        icons:
          if(icon,
            do: [
              %{src: icon, sizes: "any", purpose: "any"},
              %{src: icon, sizes: "any", purpose: "maskable"}
            ],
            else: []
          )
      }

    conn
    |> put_resp_content_type("application/manifest+json")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, Jason.encode!(manifest))
  end

  def install(conn, _params) do
    assigns = %{
      name: site_name(),
      icon: logo(),
      accent: accent(),
      manifest: Routes.path("/push/manifest.webmanifest", locale: :none),
      settings: Routes.path("/profile/settings/notifications", locale: :none)
    }

    # The page's CSP nonce is read from this connection, whatever the order of the host's plugs.
    conn = PhoenixKitWeb.CSP.put_nonces(conn)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> html(Safe.to_iodata(install_page(assigns)))
  end

  def resubscribe(conn, params) do
    with %{"old_endpoint" => old, "old_auth" => auth, "subscription" => %{} = new} <- params,
         :ok <- Push.resubscribe(old, auth, new) do
      send_resp(conn, 204, "")
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp install_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <meta name="apple-mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-title" content={@name} />
        <meta name="theme-color" content={@accent} />
        <link rel="manifest" href={@manifest} />
        <link :if={@icon} rel="apple-touch-icon" href={@icon} />
        <title>{@name}</title>
        <style nonce={PhoenixKitWeb.CSP.nonce(:style)}>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                 max-width: 28rem; margin: 3rem auto; padding: 0 1rem; line-height: 1.5; color: #1f2937; }
          ol { padding-left: 1.25rem; } li { margin: .5rem 0; }
          a { color: <%= @accent %>; }
        </style>
      </head>
      <body>
        <h1>{gettext("Get notifications on this iPhone")}</h1>
        <p>
          {gettext(
            "iPhone and iPad show a website's notifications only once it is on the Home Screen."
          )}
        </p>
        <ol>
          <li>{gettext("Tap the Share button at the bottom of Safari.")}</li>
          <li>{gettext("Choose “Add to Home Screen”, then “Add”.")}</li>
          <li>
            {gettext("Open %{name} from the Home Screen and turn on notifications in its settings.",
              name: @name
            )}
          </li>
        </ol>
        <p><a href={@settings}>{gettext("Back to the notification settings")}</a></p>
      </body>
    </html>
    """
  end

  defp site_name do
    case Settings.get_project_title() do
      name when is_binary(name) and name != "" -> name
      _ -> "PhoenixKit"
    end
  rescue
    _ -> "PhoenixKit"
  end

  defp logo do
    case Branding.logo_url() do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp accent do
    Branding.configured_accent_color() || Branding.default_accent_color()
  rescue
    _ -> "#3b82f6"
  end
end
