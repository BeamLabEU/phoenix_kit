defmodule PhoenixKitWeb.Plugs.HostLocale do
  @moduledoc """
  The language of a host application's own `/:locale` pages, validated
  against the languages the kit serves (Admin → Settings → Languages).

  A plug for the HTTP request and an `on_mount` hook for the LiveView, with
  the same options and the same answer. The kit never mounts a `/:locale`
  scope for the host; the host declares its scopes and puts this in front of
  them:

      pipeline :host_locale do
        plug PhoenixKitWeb.Plugs.HostLocale, gettext: MyAppWeb.Gettext
      end

      # after phoenix_kit_routes() and every fixed-prefix scope
      scope "/", MyAppWeb do
        pipe_through [:browser, :host_locale]

        live_session :localized,
          on_mount: [{PhoenixKitWeb.Plugs.HostLocale, gettext: MyAppWeb.Gettext}] do
          live "/products", ProductLive.Index          # the primary language
          scope "/:locale" do
            live "/products", ProductLive.Index        # every other language
          end
        end
      end

  The full recipe, including the scope-ordering trap (a wide `/:locale` scope
  declared too early swallows `/admin`, `/assets` and the kit's own routes), is
  in `guides/locale-routing.md`, "Host locale routes".

  ## What it does

  It reads the `"locale"` path parameter (`:param`) and resolves it with
  `PhoenixKit.I18n.resolve_segment/1`:

    * **A served language** — sets Gettext (the kit's backend, the global
      locale that module backends read, and every backend in `:gettext`),
      records the dialect on the process (`Languages.put_request_locale/1`) and
      assigns `:current_locale` (full dialect, `"et-EE"`),
      `:current_locale_base` (`"et"`) and `:current_language` (the language
      map of `PhoenixKit.I18n`).
    * **The primary language's segment, on a site that serves the primary
      without one** — the plug redirects to the same path without the segment
      (`on_primary_segment: :redirect`, the default; 302, 307 for a method
      other than GET/HEAD, query kept), so each page has one URL. `:serve`
      renders it instead. The `on_mount` hook always renders: links the kit
      builds never point there.
    * **Another spelling of a served segment** (`/ET/…`, `/en-US/…` where
      `en-US` owns `/en/`) — the plug redirects to the canonical segment; the
      hook renders that language.
    * **Anything else** — `on_unknown: :not_found` (the default) raises
      `PhoenixKitWeb.Plugs.HostLocale.NotFoundError`, a 404 that the host's
      error view renders. `on_unknown: :primary` renders the page in the
      primary language instead (for a scope whose first segment is not always
      a language).
    * **No locale parameter** — the primary language. (The plug does not add a
      segment for a primary that the site serves with one: declare only the
      `/:locale` routes on such a site, or turn "Primary language without
      prefix" on.)

  A segment that names a fixed kit path (the admin segment, the kit's
  `url_prefix`, `assets`, `api`, …) is a scope-ordering bug in the host's
  router; the plug logs a warning once per segment and node, then applies
  `on_unknown`.

  ## Options

    * `:param` — the path parameter, default `"locale"`.
    * `:on_unknown` — `:not_found` (default) or `:primary`.
    * `:on_primary_segment` — `:redirect` (default) or `:serve`. Plug only.
    * `:gettext` — a Gettext backend or a list of them to set as well (the
      host's own). They get the base language (`"et"`), as feature modules'
      backends do; the process-global locale is set either way, unless
      `config :phoenix_kit, host_live_view_locale: :leave` (LiveViews only).

  The hook also keeps `:phoenix_kit_current_path` (path and query of the
  current URL) up to date on every `handle_params`, so `PhoenixKit.I18n`'s
  `strategy: :path` / `:query` builders find the current page from the socket,
  and re-reads the locale on a live patch. Mount and the hook read the segment
  from the route's path parameters, never from the query string (a LiveView's
  `params` merge both, so `?locale=et` on `/products` is the primary language, as
  for the plug), so what `mount/3` translates and what renders agree.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias PhoenixKit.I18n
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKitWeb.Users.Auth

  defmodule NotFoundError do
    @moduledoc """
    Raised for a locale segment the site does not serve. `plug_status` 404, so
    Phoenix renders the host's 404 page.
    """
    defexception [:segment, plug_status: 404]

    @impl true
    def message(%{segment: segment}),
      do: "no language is served at the locale segment #{inspect(segment)}"
  end

  @mount_uri_key {__MODULE__, :mount_uri}

  @fixed_segments ~w(api mcp oauth handoff webhooks assets static files images .well-known
                     users dashboard sitemap.xml robots.txt llms.txt favicon.ico)

  # ── options ─────────────────────────────────────────────────────────

  @impl Plug
  def init(opts), do: normalize!(opts)

  defp normalize!(%{param: _} = opts), do: opts
  defp normalize!(:default), do: normalize!([])

  defp normalize!(opts) when is_list(opts) do
    on_unknown = Keyword.get(opts, :on_unknown, :not_found)
    on_primary = Keyword.get(opts, :on_primary_segment, :redirect)

    unless on_unknown in [:not_found, :primary] do
      raise ArgumentError,
            "HostLocale: on_unknown must be :not_found or :primary, got #{inspect(on_unknown)}"
    end

    unless on_primary in [:redirect, :serve] do
      raise ArgumentError,
            "HostLocale: on_primary_segment must be :redirect or :serve, got #{inspect(on_primary)}"
    end

    %{
      param: to_string(Keyword.get(opts, :param, "locale")),
      on_unknown: on_unknown,
      on_primary_segment: on_primary,
      gettext: List.wrap(Keyword.get(opts, :gettext, []))
    }
  end

  # ── plug ────────────────────────────────────────────────────────────

  @impl Plug
  def call(conn, opts) do
    opts = normalize!(opts)

    case decide(conn.path_params[opts.param], opts) do
      {:serve, lang} ->
        assign_language(conn, lang, opts)

      {:strip, lang} ->
        if opts.on_primary_segment == :redirect,
          do: redirect_replacing(conn, lang, [], opts),
          else: assign_language(conn, lang, opts)

      {:canonical, lang} ->
        segments = if lang.prefixless?, do: [], else: [lang.code]
        redirect_replacing(conn, lang, segments, opts)

      {:not_found, segment} ->
        raise NotFoundError, segment: segment
    end
  end

  # ── on_mount ────────────────────────────────────────────────────────

  @doc """
  The LiveView side: `on_mount PhoenixKitWeb.Plugs.HostLocale` or
  `on_mount {PhoenixKitWeb.Plugs.HostLocale, opts}`.
  """
  def on_mount(arg, params, _session, socket) do
    opts = normalize!(arg)
    {segment, mount_opts} = mount_segment(socket, params, opts)
    socket = mount_language(socket, segment, mount_opts)

    {:cont, maybe_attach_params_hook(socket, opts)}
  end

  # A LiveView's `params` merge the path and the query, so `?locale=et` on a route
  # without a `:locale` segment looks like a segment. Mount reads the route's own path
  # parameters, as the plug and the `handle_params` hook do: from the request on the
  # dead render, and from the URL LiveView reports when it starts the mount
  # (`attach_mount_uri/0`) on the connected one. A nested `live_render` view (no
  # router) gets what its parent passed. Only when neither is known (the telemetry
  # handler detached) does mount fall back to `params`, leniently: an unknown value is
  # the primary there, and the hook still raises the 404 before the first render.
  defp mount_segment(%{router: nil}, params, opts),
    do: {if(is_map(params), do: params[opts.param]), opts}

  defp mount_segment(socket, params, opts) do
    case socket.private[:connect_info] do
      %Plug.Conn{path_params: path_params} ->
        {path_params[opts.param], opts}

      _connected ->
        # Taken, not read: a URL belongs to the one mount it was recorded for.
        case Process.delete(@mount_uri_key) do
          uri when is_binary(uri) -> {path_segment(socket, uri, params, opts), opts}
          _unknown -> {if(is_map(params), do: params[opts.param]), %{opts | on_unknown: :primary}}
        end
    end
  end

  @mount_handler_id {__MODULE__, :mount_uri}

  @doc false
  # Records the URL of each LiveView mount in the mounting process, for `on_mount/4`
  # (LiveView passes it to its `[:phoenix, :live_view, :mount, :start]` telemetry
  # event, not to `on_mount`). Attached once by `PhoenixKit.Supervisor`.
  @spec attach_mount_uri() :: :ok
  def attach_mount_uri do
    case :telemetry.attach(
           @mount_handler_id,
           [:phoenix, :live_view, :mount, :start],
           &__MODULE__.handle_mount_start/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_mount_start(_event, _measurements, metadata, _config) do
    case metadata do
      %{uri: uri} when is_binary(uri) -> Process.put(@mount_uri_key, uri)
      _ -> Process.delete(@mount_uri_key)
    end
  end

  # `handle_params` hooks exist only for a view mounted at the router; a
  # nested `live_render` view gets the language at mount and nothing more.
  defp maybe_attach_params_hook(%{router: nil} = socket, _opts), do: socket

  defp maybe_attach_params_hook(socket, opts) do
    Phoenix.LiveView.attach_hook(socket, :phoenix_kit_host_locale, :handle_params, fn
      params, uri, socket ->
        socket =
          socket
          |> Phoenix.Component.assign(:phoenix_kit_current_path, path_of(uri))
          |> mount_language(path_segment(socket, uri, params, opts), opts)

        {:cont, socket}
    end)
  end

  # The segment from the route's path parameters only, never from the query string.
  defp path_segment(socket, uri, params, opts) do
    %URI{path: path, host: host} = URI.parse(uri)
    # Decoded, as the router decodes the path it matches (`/%65t/...` is `/et/...`).
    segments = for segment <- String.split(path || "/", "/", trim: true), do: URI.decode(segment)

    case Phoenix.Router.route_info(socket.router, "GET", segments, host) do
      %{path_params: path_params} -> path_params[opts.param]
      _no_route -> if is_map(params), do: params[opts.param]
    end
  rescue
    _ -> nil
  end

  defp mount_language(socket, segment, opts) do
    lang =
      case decide(segment, opts) do
        {:not_found, segment} -> raise NotFoundError, segment: segment
        {_serve_strip_or_canonical, lang} -> lang
      end

    socket =
      Phoenix.Component.assign(socket, :phoenix_kit_locale_segment, segment_of(segment, lang))

    if socket.assigns[:current_language] == lang do
      socket
    else
      put_locale(lang, socket.view, opts)

      Phoenix.Component.assign(socket,
        current_locale: lang.locale,
        current_locale_base: lang.base,
        current_language: lang
      )
    end
  end

  # The segment as the URL spells it (`ET` for `/ET/...`), so `PhoenixKit.I18n`'s
  # `strategy: :path` replaces that spelling; nil when the language came from elsewhere.
  defp segment_of(segment, _lang) when is_binary(segment),
    do: if(I18n.find_language(segment), do: segment)

  defp segment_of(_segment, _lang), do: nil

  defp path_of(uri) do
    case URI.parse(uri) do
      %URI{path: path, query: nil} -> path || "/"
      %URI{path: path, query: query} -> (path || "/") <> "?" <> query
    end
  end

  # ── the decision ────────────────────────────────────────────────────

  defp decide(nil, _opts), do: {:serve, I18n.primary_language()}

  defp decide(segment, opts) when is_binary(segment) do
    case I18n.resolve_segment(segment) do
      {:ok, %{prefixless?: true} = lang} -> {:strip, lang}
      {:ok, lang} -> {:serve, lang}
      {:redirect, lang} -> {:canonical, lang}
      :error -> unknown(segment, opts)
    end
  end

  defp decide(_other, opts), do: decide(nil, opts)

  defp unknown(segment, opts) do
    warn_if_fixed_segment(segment)

    case opts.on_unknown do
      :not_found -> {:not_found, segment}
      :primary -> {:serve, I18n.primary_language()}
    end
  end

  defp warn_if_fixed_segment(segment) do
    key = {__MODULE__, :fixed_segment_warned, segment}

    if fixed_segment?(segment) and not :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "[PhoenixKit] A host /:locale route captured #{inspect("/" <> segment)}, a path the kit " <>
          "or the endpoint serves. Declare the wide /:locale scope after phoenix_kit_routes() " <>
          "and after every fixed-prefix scope — see guides/locale-routing.md, \"Host locale routes\"."
      )
    end
  end

  defp fixed_segment?(segment) do
    kit =
      [PhoenixKit.Config.get_admin_path(), PhoenixKit.Config.get_url_prefix()]
      |> Enum.map(fn path ->
        path |> to_string() |> String.split("/", trim: true) |> List.first()
      end)

    segment in (@fixed_segments ++ Enum.reject(kit, &is_nil/1))
  rescue
    _ -> segment in @fixed_segments
  end

  # ── serving ─────────────────────────────────────────────────────────

  defp assign_language(conn, lang, opts) do
    put_locale(lang, nil, opts)

    conn
    |> assign(:current_locale, lang.locale)
    |> assign(:current_locale_base, lang.base)
    |> assign(:current_language, lang)
    |> put_private(:phoenix_kit_host_locale, lang)
  end

  defp put_locale(lang, view, opts) do
    Auth.put_gettext_locale(lang.locale, view)
    host_locale = RecipientLocale.global_locale(lang.locale)
    Enum.each(opts.gettext, &Gettext.put_locale(&1, host_locale))
  end

  # ── redirects ───────────────────────────────────────────────────────

  # Replaces the locale segment of the request path with `segments` ([] strips
  # it). The segment's position comes from the matched route's pattern, so a
  # nested `/shop/:locale/...` works; a path that cannot be rebuilt safely is
  # rendered in `lang` instead of redirected.
  defp redirect_replacing(conn, lang, segments, opts) do
    with {:ok, index} <- segment_index(conn, opts.param),
         {before, [_locale | rest]} <- Enum.split(conn.path_info, index),
         path = "/" <> Enum.join(conn.script_name ++ before ++ segments ++ rest, "/"),
         false <- unsafe_target?(path),
         true <- path != conn.request_path do
      conn
      |> keep_method()
      |> Phoenix.Controller.redirect(to: with_query(path, conn))
      |> halt()
    else
      _ -> assign_language(conn, lang, opts)
    end
  end

  defp segment_index(conn, param) do
    decoded = Enum.map(conn.path_info, &URI.decode/1)
    target = ":" <> param

    from_route =
      with router when is_atom(router) and not is_nil(router) <- conn.private[:phoenix_router],
           %{route: route} <- Phoenix.Router.route_info(router, conn.method, decoded, conn.host) do
        route |> String.split("/", trim: true) |> Enum.find_index(&(&1 == target))
      else
        _ -> nil
      end

    case from_route || Enum.find_index(decoded, &(&1 == conn.path_params[param])) do
      nil -> :error
      index -> {:ok, index}
    end
  rescue
    _ -> :error
  end

  defp keep_method(%Plug.Conn{method: method} = conn) when method in ["GET", "HEAD"], do: conn
  defp keep_method(conn), do: put_status(conn, :temporary_redirect)

  @unsafe ["\\", "/%09", "/\t", "\n", "\r"]

  defp unsafe_target?(path) do
    String.starts_with?(path, "//") or String.contains?(path, @unsafe) or
      path
      |> String.split("/")
      |> Enum.any?(fn seg -> seg in [".", ".."] or safe_decode(seg) in [".", ".."] end)
  end

  defp safe_decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end

  defp with_query(path, %Plug.Conn{query_string: ""}), do: path

  defp with_query(path, %Plug.Conn{query_string: query}) do
    candidate = path <> "?" <> query
    if String.contains?(candidate, @unsafe), do: path, else: candidate
  end
end
