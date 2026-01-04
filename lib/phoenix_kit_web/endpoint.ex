defmodule PhoenixKitWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :phoenix_kit

  # The session will be stored in the cookie and signed.
  @session_options [
    store: :cookie,
    key: "_phoenix_kit_key",
    signing_salt: "YV7t8l8S",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  # DB Sync socket for cross-site data sync
  socket "/sync", PhoenixKit.Modules.Sync.Web.Socket,
    websocket: [connect_info: [:peer_data, :x_headers]],
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  plug Plug.Static,
    at: "/",
    from: :phoenix_kit,
    gzip: false,
    only: PhoenixKitWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :phoenix_kit
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PhoenixKitWeb.Router
end
