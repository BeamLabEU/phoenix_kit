defmodule PhoenixKitWeb.CSP do
  @moduledoc """
  Content-Security-Policy nonces for the inline `<script>` and `<style>` tags the kit renders.

  The kit never sets a policy: that is the host's. A host whose policy allows inline code by
  nonce (`script-src 'self' 'nonce-…'`) generates the nonce in a plug of its own, puts it in
  `conn.assigns` and tells the kit the name of that assign:

      config :phoenix_kit, csp_nonce_assign_key: :csp_nonce

      # or, with a nonce per kind
      config :phoenix_kit, csp_nonce_assign_key: %{script: :script_nonce, style: :style_nonce}

  Every inline tag of the kit then carries `nonce="…"`. With the setting absent (the default)
  nothing is read and no attribute is rendered.

  ## How the nonce reaches a tag

  A component cannot see the `conn`, so the nonces of the current page are kept in the process
  dictionary, the way Gettext keeps the locale:

    * `PhoenixKitWeb.Plugs.Integration` reads them from the `conn` for the request process, which
      also renders the first (dead) render of a LiveView. The host's plug that assigns the nonce
      must therefore run **before** it in the `:browser` pipeline.
    * The kit's own live sessions carry them in the LiveView session (`live_session/1`) and
      `on_mount/4` restores them, so a `<style>` patched into the page after the socket connects
      still has the nonce of the document it lands in.
    * A controller that writes a page by hand passes its `conn`: `nonce(conn, :style)`.

  A host's own live session that renders kit components (`LayoutWrapper`, the table, the theme
  controller) takes both halves:

      live_session :app,
        session: {PhoenixKitWeb.CSP, :live_session, []},
        on_mount: [PhoenixKitWeb.CSP, ...] do

  Without them the first render is still covered by the plug; only tags added by a later patch or
  live navigation go without a nonce.

  ## Writing an inline tag

      <script nonce={PhoenixKitWeb.CSP.nonce(:script)}>
      <style nonce={PhoenixKitWeb.CSP.nonce(:style)}>

  `test/phoenix_kit_web/csp_inline_tags_test.exs` fails on an inline tag in `lib/` without one.
  Inline event handlers (`onclick="…"`) cannot take a nonce at all.
  """

  import Phoenix.Component, only: [assign: 3]

  @pdict_key {__MODULE__, :nonces}
  @session_key "phoenix_kit_csp_nonces"

  @type kind :: :script | :style
  @type nonces :: %{optional(kind) => String.t()}

  @doc """
  The nonce of the current page for `kind`, or `nil` when the host set none.
  """
  @spec nonce(kind) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style], do: Map.get(current(), kind)

  @doc """
  The same, read from `conn` first: for a controller or plug that builds its page by hand and
  may run before `put_nonces/1` did.
  """
  @spec nonce(Plug.Conn.t(), kind) :: String.t() | nil
  def nonce(%Plug.Conn{} = conn, kind) when kind in [:script, :style] do
    Map.get(from_conn(conn), kind) || nonce(kind)
  end

  @doc """
  ` nonce="…"` (with the leading space) for a tag written as a string, or `""`.
  """
  @spec attr(Plug.Conn.t() | nil, kind) :: String.t()
  def attr(conn \\ nil, kind) do
    value = if conn, do: nonce(conn, kind), else: nonce(kind)

    case value do
      nil -> ""
      value -> ~s( nonce="#{Plug.HTML.html_escape(value)}")
    end
  end

  @doc """
  Remembers the nonces of `conn` for everything rendered in this process. Returns `conn`.
  """
  @spec put_nonces(Plug.Conn.t()) :: Plug.Conn.t()
  def put_nonces(%Plug.Conn{} = conn) do
    store(from_conn(conn))
    conn
  end

  @doc """
  The `session:` of a live session: the page's nonces, for `on_mount/4` to restore.
  """
  @spec live_session(Plug.Conn.t()) :: map
  def live_session(%Plug.Conn{} = conn) do
    case from_conn(conn) do
      nonces when map_size(nonces) == 0 ->
        %{}

      nonces ->
        %{@session_key => Map.new(nonces, fn {kind, value} -> {to_string(kind), value} end)}
    end
  end

  @doc false
  def on_mount(_arg, _params, session, socket) do
    case session do
      # A session without them leaves what the plug stored for the dead render.
      %{@session_key => %{} = stored} when map_size(stored) > 0 -> store(from_session(stored))
      _ -> :ok
    end

    # An assign as well, for a host template that wants the value by name.
    {:cont, assign(socket, :phoenix_kit_csp_nonces, current())}
  end

  defp current, do: Process.get(@pdict_key, %{})

  # The plug always writes, an empty reading included: a connection process serves many
  # requests, and the nonce of the previous page is not this page's.
  defp store(nonces) when map_size(nonces) == 0, do: Process.delete(@pdict_key)
  defp store(nonces), do: Process.put(@pdict_key, nonces)

  defp from_session(stored) do
    for kind <- [:script, :style],
        value = stored[to_string(kind)],
        usable?(value),
        into: %{},
        do: {kind, value}
  end

  defp from_conn(conn) do
    for {kind, key} <- assign_keys(),
        value = conn.assigns[key],
        usable?(value),
        into: %{},
        do: {kind, value}
  end

  defp assign_keys do
    case Application.get_env(:phoenix_kit, :csp_nonce_assign_key) do
      nil -> []
      key when is_atom(key) -> [script: key, style: key]
      %{} = keys -> for kind <- [:script, :style], key = keys[kind], is_atom(key), do: {kind, key}
      _ -> []
    end
  end

  defp usable?(value), do: is_binary(value) and value != ""
end
