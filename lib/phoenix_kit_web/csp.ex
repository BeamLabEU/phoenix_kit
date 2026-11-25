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
      The connection is the whole answer: a missing assign is no nonce, not the one an
      earlier request left in this process.

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
  Inline event handlers (`onclick="…"`) cannot take a nonce at all, so the kit renders none: the
  same test fails on one, and `phoenix_kit.js` ("DECLARATIVE HANDLERS") does their work.
  """

  require Logger

  @pdict_key {__MODULE__, :nonces}
  @session_key "phoenix_kit_csp_nonces"
  @integration_ran_key {__MODULE__, :integration_ran}
  @warned_key {__MODULE__, :late_plug_warned}

  @type kind :: :script | :style
  @type nonces :: %{optional(kind) => String.t()}

  @doc """
  The nonce of the current page for `kind`, or `nil` when the host set none.
  """
  @spec nonce(kind) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style], do: Map.get(current(), kind)

  @doc """
  The nonce on `conn` for `kind`, or `nil` when that connection has none.

  For a controller or plug that builds its page by hand and may run before `put_nonces/1`.
  The connection is authoritative, a missing assign included: the process dictionary is
  only for a render that has no `conn`, and a connection process serves many requests.
  """
  @spec nonce(Plug.Conn.t(), kind) :: String.t() | nil
  def nonce(%Plug.Conn{} = conn, kind) when kind in [:script, :style] do
    Map.get(from_conn(conn), kind)
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

  Called by `PhoenixKitWeb.Plugs.Integration`, again by the kit's own route pipeline (after the
  whole `:browser` pipeline, so a host plug placed after `Integration` is still read on kit
  routes), and by a controller that writes its page by hand. A later call replaces an earlier
  one. The dictionary is emptied when the response is sent: a connection process serves many
  requests, and one that never comes through here must not find this page's nonce.
  """
  @spec put_nonces(Plug.Conn.t()) :: Plug.Conn.t()
  def put_nonces(%Plug.Conn{} = conn) do
    nonces = from_conn(conn)
    warn_late_plug(current(), nonces)
    store(nonces)

    if map_size(nonces) > 0 and conn.state in [:unset, :set] do
      Plug.Conn.register_before_send(conn, fn conn ->
        Process.delete(@pdict_key)
        conn
      end)
    else
      conn
    end
  end

  # `Integration` read no nonce and a later reading of the same request finds one: the host's
  # plug runs after `Integration`. Kit routes recover (this call), but the host's own pages
  # render kit components (the theme bootstrap in its root layout) from the first reading.
  defp warn_late_plug(earlier, later) when map_size(earlier) == 0 and map_size(later) > 0 do
    if Process.get(@integration_ran_key) && !:persistent_term.get(@warned_key, false) do
      :persistent_term.put(@warned_key, true)

      Logger.warning(
        "[PhoenixKit] The plug that assigns the Content-Security-Policy nonce runs after " <>
          "PhoenixKitWeb.Plugs.Integration. Move it before, or the kit components on your own " <>
          "pages (the theme bootstrap in the root layout) render without a nonce. " <>
          "See guides/content-security-policy.md."
      )
    end

    :ok
  end

  defp warn_late_plug(_earlier, _later), do: :ok

  @doc false
  # `Integration`'s own call: the first reading of a request. It marks the process so a later
  # reading can tell "the host's plug came after" from "this is the first reading".
  @spec put_nonces_first(Plug.Conn.t()) :: Plug.Conn.t()
  def put_nonces_first(%Plug.Conn{} = conn) do
    Process.delete(@pdict_key)
    Process.delete(@integration_ran_key)
    conn = put_nonces(conn)
    # Marked after the reading: this one is the first, never "late".
    Process.put(@integration_ran_key, true)

    Plug.Conn.register_before_send(conn, fn conn ->
      Process.delete(@integration_ran_key)
      conn
    end)
  end

  @doc """
  The session of a nested LiveView (`live_render/3`) with the page's nonces added.

  A nested view is its own process and skips the live session's `on_mount`, so its parent hands
  the nonces over here and the child restores them with `on_mount PhoenixKitWeb.CSP` (every view
  that does `use PhoenixKitWeb, :live_view` has it).

      {live_render(@socket, MyWidget, id: "w", session: PhoenixKitWeb.CSP.nested_session(%{"a" => 1}))}
  """
  @spec nested_session(map) :: map
  def nested_session(session \\ %{}) when is_map(session) do
    case current() do
      nonces when map_size(nonces) == 0 -> session
      nonces -> Map.put(session, @session_key, stringify(nonces))
    end
  end

  @doc """
  What is wrong with `config :phoenix_kit, csp_nonce_assign_key:`, or `nil`.

  A value of the wrong shape reads as "no nonce" at runtime, silently; `mix phoenix_kit.doctor`
  shows this text.
  """
  @spec config_problem() :: String.t() | nil
  def config_problem do
    case Application.get_env(:phoenix_kit, :csp_nonce_assign_key) do
      nil ->
        nil

      # `true` and `false` are atoms. `false` is also what `key && router` turns into, so the
      # doctor used to pass it where a router source belongs and raise.
      key when is_boolean(key) ->
        "expected an atom naming an assign, or a map with :script / :style, got #{inspect(key)}"

      key when is_atom(key) ->
        nil

      %{} = keys ->
        unknown = Map.keys(keys) -- [:script, :style]
        bad = for {kind, key} <- keys, kind in [:script, :style], not assign_name?(key), do: kind

        cond do
          unknown != [] ->
            "unknown keys #{inspect(unknown)}; the map takes :script and :style"

          bad != [] ->
            "the assign names of #{inspect(bad)} must be atoms other than true and false"

          map_size(keys) == 0 ->
            "the map is empty; name :script and/or :style"

          true ->
            nil
        end

      other ->
        "expected an atom or a map with :script / :style, got #{inspect(other)}"
    end
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
        %{@session_key => stringify(nonces)}
    end
  end

  defp stringify(nonces), do: Map.new(nonces, fn {kind, value} -> {to_string(kind), value} end)

  @doc false
  def on_mount(_arg, _params, session, socket) do
    case session do
      # A session without them leaves what the plug stored for the dead render.
      %{@session_key => %{} = stored} when map_size(stored) > 0 -> store(from_session(stored))
      _ -> :ok
    end

    {:cont, socket}
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
      nil ->
        []

      key when is_atom(key) and not is_boolean(key) ->
        [script: key, style: key]

      %{} = keys ->
        for kind <- [:script, :style], assign_name?(keys[kind]), do: {kind, keys[kind]}

      _ ->
        []
    end
  end

  defp assign_name?(key), do: is_atom(key) and not is_boolean(key)

  defp usable?(value), do: is_binary(value) and value != ""
end
