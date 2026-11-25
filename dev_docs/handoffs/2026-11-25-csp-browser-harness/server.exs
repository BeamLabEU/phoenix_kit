# Throwaway host for a browser run under a strict Content-Security-Policy.
Application.put_env(:phoenix_kit, :update_mode, true)
Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("k", 64))
Application.put_env(:phoenix, :json_library, Jason)

defmodule H.ErrorView do
  def render(template, assigns), do: "error #{template}: #{inspect(assigns[:reason])}"
end

# ?mode=one (one nonce, default) | two (script and style nonces differ) | late (assigned after the first reading)
defmodule H.CSPPlug do
  import Plug.Conn
  def init(o), do: o

  def call(conn, :early) do
    conn = fetch_query_params(conn)
    if conn.params["mode"] == "late", do: conn, else: assign_nonces(conn)
  end

  def call(conn, :late) do
    if conn.params["mode"] == "late", do: assign_nonces(conn), else: conn
  end

  defp assign_nonces(conn) do
    s = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    t = if conn.params["mode"] == "two", do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false), else: s

    conn
    |> assign(:script_nonce, s)
    |> assign(:style_nonce, t)
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; script-src 'self' 'nonce-#{s}'; style-src 'self' 'nonce-#{t}'; " <>
        "style-src-attr 'unsafe-inline'; connect-src 'self' ws://127.0.0.1:4177"
    )
  end
end

defmodule H.First do
  def init(o), do: o
  # What PhoenixKitWeb.Plugs.Integration does first; the rest of that plug needs a database.
  def call(conn, _), do: PhoenixKitWeb.CSP.put_nonces_first(conn)
end

defmodule H.Files do
  import Plug.Conn
  def init(o), do: o
  @root File.cwd!()
  @scratch System.fetch_env!("PK_SCRATCH")
  @files %{
    "phoenix.js" => Path.join(@root, "deps/phoenix/priv/static/phoenix.min.js"),
    "phoenix_live_view.js" => Path.join(@root, "deps/phoenix_live_view/priv/static/phoenix_live_view.min.js"),
    "phoenix_kit.js" => Path.join(@root, "priv/static/assets/phoenix_kit.js"),
    "phoenix_kit_admin.js" => Path.join(@root, "priv/static/assets/phoenix_kit_admin.js"),
    "old/phoenix_kit.js" => Path.join(@scratch, "phoenix_kit.old.js"),
    "old/phoenix_kit_admin.js" => Path.join(@scratch, "phoenix_kit_admin.old.js"),
    "app.js" => Path.join(@scratch, "app.js")
  }
  def call(%{path_info: ["js" | rest]} = conn, _) do
    case @files[Enum.join(rest, "/")] do
      nil -> conn
      path -> conn |> put_resp_content_type("text/javascript") |> send_resp(200, File.read!(path)) |> halt()
    end
  end
  def call(conn, _), do: conn
end

defmodule H.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <PhoenixKitWeb.Components.ThemeBootstrap.theme_bootstrap />
        <PhoenixKitWeb.Components.Core.PhoenixKitGlobals.phoenix_kit_globals />
        <script defer nonce={assigns[:script_nonce]} src={"/js/" <> (@conn.params["old"] && "old/" || "") <> "phoenix_kit.js"}></script>
        <script :if={@conn.params["admin"]} defer nonce={assigns[:script_nonce]} src={"/js/" <> (@conn.params["old"] && "old/" || "") <> "phoenix_kit_admin.js"}></script>
        <script defer src="/js/phoenix.js"></script>
        <script defer src="/js/phoenix_live_view.js"></script>
        <script defer src="/js/app.js"></script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end
end

defmodule H.PageHTML do
  use Phoenix.Component
  import PhoenixKitWeb.Components.Core.DecimalInput
  import PhoenixKitWeb.Components.Core.ThemeController

  def plain(assigns) do
    ~H"""
    <div id="toggle"><.theme_controller themes={["phoenix-light", "phoenix-dark"]} id="tc" /></div>
    <form id="f"><.decimal_input id="qty" name="qty" value={Decimal.new("0")} onfocus="window.__hostFocus = this.value" /></form>
    <code id="cb">https://example.test/cb</code>
    <button id="copy" type="button" data-pk-copy={"it's \"quoted\""}>copy</button>
    <button id="copyfrom" type="button" data-pk-copy-from="cb">copy from</button>
    <span id="wrap"><img id="broken" src="/nope.png" data-pk-img-error="hide" /></span>
    <ul id="menu" data-pk-blur><li><button id="choice" type="button">choose</button></li></ul>
    <form id="nosubmit" data-pk-no-submit action="/submitted"><input id="ns" name="a" /></form>
    """
  end

  # What a host page with nothing of the kit but its bundle looks like.
  def bare(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html><head><meta charset="utf-8" />
      <script nonce={@conn.params["tagnonce"] != "0" && assigns[:script_nonce]} src={"/js/" <> (@conn.params["old"] && "old/" || "") <> "phoenix_kit.js"}></script>
      <script :if={@conn.params["admin"]} nonce={@conn.params["tagnonce"] != "0" && assigns[:script_nonce]} src={"/js/" <> (@conn.params["old"] && "old/" || "") <> "phoenix_kit_admin.js"}></script>
    </head><body><p>bare</p></body></html>
    """
  end
end

defmodule H.PageController do
  use Phoenix.Controller, formats: [:html]
  plug :put_view, H.PageHTML

  def plain(conn, _), do: conn |> put_root_layout(html: {H.Layouts, :root}) |> put_layout(false) |> render(:plain)
  def bare(conn, _), do: conn |> put_root_layout(false) |> put_layout(false) |> render(:bare)
  def submitted(conn, _), do: text(conn, "submitted")
end

# A nested view the kit way: `use PhoenixKitWeb, :live_view` restores the nonce from its session.
defmodule H.ChildLive do
  use PhoenixKitWeb, :live_view
  def mount(_p, _s, socket), do: {:ok, assign(socket, late: false), layout: false}
  def handle_event("late", _, socket), do: {:noreply, assign(socket, late: true)}
  def render(assigns) do
    ~H"""
    <div id="child-box">
      <style nonce={PhoenixKitWeb.CSP.nonce(:style)}>#child-first { color: rgb(1, 2, 3); }</style>
      <style :if={@late} id="child-late-style" nonce={PhoenixKitWeb.CSP.nonce(:style)}>#child-late { color: rgb(4, 5, 6); }</style>
      <p id="child-first">child first</p><p id="child-late">child late</p>
      <button id="child-btn" phx-click="late">child late style</button>
    </div>
    """
  end
end

# The control: a nested view with nothing that restores the nonce (what a nested view was before).
defmodule H.BareChildLive do
  use Phoenix.LiveView
  def mount(_p, _s, socket), do: {:ok, assign(socket, late: false), layout: false}
  def handle_event("late", _, socket), do: {:noreply, assign(socket, late: true)}
  def render(assigns) do
    ~H"""
    <div id="ctl-box">
      <style :if={@late} id="ctl-late-style" nonce={PhoenixKitWeb.CSP.nonce(:style)}>#ctl-late { color: rgb(7, 8, 9); }</style>
      <p id="ctl-late">control late</p>
      <button id="ctl-btn" phx-click="late">control late style</button>
    </div>
    """
  end
end

defmodule H.ParentLive do
  use Phoenix.LiveView
  def mount(_p, _s, socket), do: {:ok, assign(socket, late: false), layout: false}
  def handle_event("late", _, socket), do: {:noreply, assign(socket, late: true)}
  def render(assigns) do
    ~H"""
    <div id="parent-box">
      <style :if={@late} id="parent-late-style" nonce={PhoenixKitWeb.CSP.nonce(:style)}>#parent-late { color: rgb(10, 11, 12); }</style>
      <p id="parent-late">parent late</p>
      <button id="parent-btn" phx-click="late">parent late style</button>
      {live_render(@socket, H.ChildLive, id: "child", session: PhoenixKitWeb.CSP.nested_session(%{}))}
      {live_render(@socket, H.BareChildLive, id: "ctl", session: PhoenixKitWeb.CSP.nested_session(%{}))}
    </div>
    """
  end
end

defmodule H.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {H.Layouts, :root}
    plug :protect_from_forgery
    plug H.CSPPlug, :early
    plug H.First
    plug H.CSPPlug, :late
    # What the kit's own routes add after the host's pipeline.
    plug PhoenixKitWeb.Integration, :phoenix_kit_auto_setup
  end

  scope "/" do
    pipe_through :browser
    get "/plain", H.PageController, :plain
    get "/bare", H.PageController, :bare
    get "/submitted", H.PageController, :submitted

    live_session :h, session: {PhoenixKitWeb.CSP, :live_session, []}, on_mount: [PhoenixKitWeb.CSP] do
      live "/live", H.ParentLive
    end
  end
end

defmodule H.Endpoint do
  use Phoenix.Endpoint, otp_app: :pk_harness
  @session [store: :cookie, key: "_h", signing_salt: "harness1"]
  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session]]
  plug H.Files
  plug Plug.Session, @session
  plug H.Router
end

Application.put_env(:pk_harness, H.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4177],
  server: true,
  secret_key_base: String.duplicate("s", 64),
  live_view: [signing_salt: "harness2"],
  pubsub_server: H.PubSub,
  check_origin: false,
  render_errors: [formats: [html: H.ErrorView], layout: false],
  debug_errors: false
)

Application.put_env(:phoenix_kit, :csp_nonce_assign_key, %{script: :script_nonce, style: :style_nonce})
for app <- [:logger, :plug, :phoenix, :phoenix_pubsub, :phoenix_live_view, :bandit, :decimal, :gettext, :jason], do: {:ok, _} = Application.ensure_all_started(app)
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: H.PubSub}, H.Endpoint], strategy: :one_for_one)
IO.puts("harness up on 4177")
Process.sleep(:infinity)
