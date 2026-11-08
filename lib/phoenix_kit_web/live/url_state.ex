defmodule PhoenixKitWeb.Live.UrlState do
  @moduledoc """
  URL-backed list state for LiveView index pages — search, filters, sort, page.

  A list screen's state belongs in the address bar: the result is then a real
  URL that can be pasted to a colleague, bookmarked, and reproduced by a reload,
  and the browser Back button returns to the previous query instead of leaving
  the page.

  Declare the state, handle one callback, and push changes:

      defmodule MyAppWeb.UsersLive do
        use MyAppWeb, :live_view

        use PhoenixKitWeb.Live.UrlState,
          params: [
            search_query: [default: "", url_key: "q", alias: "search"],
            filter_role:  [default: "all", url_key: "role"],
            sort_by:      [default: "inserted_at", in: ~w(inserted_at email)],
            sort_dir:     [default: :desc, cast: :atom, in: [:asc, :desc]],
            page:         [default: 1, cast: :integer, min: 1]
          ]

        def handle_url_state(state, socket) do
          assign(socket, :users, Users.list(state))
        end

        def handle_event("search", %{"search" => q}, socket) do
          {:noreply, push_url_state(socket, [search_query: q], replace: true)}
        end
      end

  ## Parameter spec

  Each entry is `assign_name: opts`. The key is the socket assign the value
  lands in, so adopting an existing LiveView is a matter of listing the assigns
  it already has — its template does not change.

    * `:default` — required. The value used when the key is absent or invalid.
      Values equal to the default are **omitted from the query string**, so an
      unfiltered list is `/admin/users`, not `/admin/users?q=&role=all&page=1`.
    * `:url_key` — the query-string key. Defaults to the assign name. Use it
      when the assign is `:search_query` but the URL should read `?q=`.
    * `:alias` — an additional key accepted when **reading**, never written.
      Lets a screen that already published `?search=` links converge on `?q=`
      without breaking them. Accepts a string or a list of strings.
    * `:cast` — `:string` (default), `:integer`, `:atom` or `:boolean`.
    * `:in` — allowed values. Anything else falls back to the default.
      **Required for `cast: :atom`**: the incoming string is matched against
      this list, so no atom is ever created from user input.
    * `:min` / `:max` — bounds for `cast: :integer`. Out-of-range falls back to
      the default. `:max` defaults to 1_000_000 for integers: an unbounded page
      number out of the URL overflows PostgreSQL's `bigint` once it reaches
      `OFFSET`, turning a crafted link into a 500.

  Unknown query keys are preserved across patches, so an unrelated param is not
  dropped when a filter changes — the media selector is opened with
  `?return_to=…&mode=single`, and both survive a search.

  ## Options

    * `:params` — the spec above. Required.
    * `:dead_render` — `:call` (default) runs `handle_url_state/2` on the
      disconnected render as well, so the first paint already carries the list.
      This is what a `mount/3` that loads its data already does, which is why it
      is the default: adopting the module does not change what the user sees.
      `:skip` runs the callback only once the socket is connected, halving the
      queries per page load — worth it on a heavy list, wrong on a page that
      must serve content to crawlers. ⚠ With `:skip` the callback has not run
      when the disconnected render happens, so **any assign the callback sets
      does not exist yet**: the template must tolerate that (`@users || []`),
      or mount must seed a placeholder. Otherwise the dead render raises rather
      than merely painting empty.
    * `:page_param` — the assign reset whenever another parameter changes.
      Defaults to `:page` when the spec declares it; `false` disables the reset.

  ## Writing state

  `push_url_state/3` merges the changes, resets the page parameter unless the
  page itself was what changed, drops defaults, and patches **the path the
  LiveView is currently on** — captured from the live `uri`, not rebuilt from a
  literal. A screen reachable at more than one route (a sub-tab such as
  `/orders/:id/edit/files`) therefore stays where it is, and the locale segment
  survives.

  Pass `replace: true` for continuous input. A debounced search box otherwise
  writes one history entry per pause in typing, and Back walks the query
  backwards a few characters at a time instead of leaving the page. Discrete
  actions — picking a filter, sorting, changing page — should push a real entry.

  For links rather than events (`<.pagination>`, `<.link patch=…>`), build the
  target with `url_state_path/2`.

  ## `:patch` is router-only; embeddable LiveViews need `:history`

  The default, `mode: :patch`, makes a LiveView **impossible to embed with
  `live_render/3`**. The two requirements are mutually exclusive in Phoenix
  LiveView itself:

    * `push_patch` from a root LiveView reaches
      `sync_handle_params_with_live_redirect/5`, which invokes
      `view.handle_params/3` unconditionally — the 4-arity
      `Utils.call_handle_params!` defaults `exported?` to `true`. So
      `handle_params/3` must be exported.
    * On an embedded mount (`socket.root_pid != self()`),
      `maybe_call_mount_handle_params/4` sees `any? = callbacks? or exported?`
      and takes the branch that raises through `Route.live_link_info!`. Merely
      exporting `handle_params/3` — whatever its body — makes a LiveView
      un-embeddable.

  One requires exactly what the other forbids. `mode: :history` sidesteps both
  by never touching `handle_params` at all: the browser owns the URL, and the
  LiveView talks to it through a JS hook.

      use PhoenixKitWeb.Live.UrlState,
        mode: :history,
        params: [search: [default: "", url_key: "q"]]

  The template must render the hook's element once:

      <.url_state_sync mode={:history} />

  What changes in `:history` mode:

    * `push_url_state/3` applies the state itself and pushes the new query to
      the client, which rewrites the address bar (`pushState`, or
      `replaceState` when you pass `replace: true`). There is no round trip.
    * Back and Forward arrive as a `popstate` report from the hook, decoded the
      same way a patch would be.
    * **The LiveView keeps loading its list in `mount/3`.** There is no
      `handle_params` to hang the first call on, so `handle_url_state/2` serves
      changes only. Declared params are still assigned before `mount/3` runs,
      so a router-mounted LiveView loads the right thing immediately.
    * On an embedded mount, params arrive as `:not_mounted_at_router`, so
      `mount/3` sees the defaults and the hook corrects it on connect — one
      extra load, and only when the URL actually carried state.
    * `url_state_path/2` and `<.link patch=…>` do **not** apply — there is no
      router to patch against. Drive everything through events.
    * Only the query is exchanged; the path stays client-side, because an
      embedded LiveView does not know what page it is on. One synced LiveView
      per page — two would fight over the same query keys.

  In `:patch` mode, a LiveView that already defines its own `handle_params/3`
  keeps it and the state hook composes alongside — both run. Only one without
  it gets the stub that `push_patch` requires; in `:history` mode the stub is
  deliberately never injected.

  ## Setting a declared param outside an event

  Prefer `push_url_state/3` so the address bar changes with the state. But a
  plain `assign/3` on a declared param is safe: the next patch reads its merge
  base back from the assigns, so the freshest value wins and the URL catches
  up rather than resurrecting what was superseded.

  This matters for screens that adjust their own state as a side effect — a
  list re-picking its sort column after the current one is hidden, say. Before
  this was handled, such a reset left the old column in the URL, the next
  search re-applied it, and a reload sorted by a column that was no longer
  visible.

  ## `@impl` is all-or-nothing

  Elixir demands `@impl` on *every* callback of a module that uses it on any
  one of them, so match whatever the LiveView already does:

    * **Annotates nothing** (core's own LiveViews) — leave `handle_url_state/2`
      bare. Adding `@impl` here turns `mount/3`, `handle_event/3` and friends
      into warnings, which `mix precommit` compiles as errors.
    * **Annotates its callbacks** (e.g. a host app's LiveViews) — annotate
      `handle_url_state/2` too, *and* define an explicit
      `@impl true def handle_params(_params, _uri, socket), do: {:noreply, socket}`.
      The stub injected below carries no `@impl`, so letting it be injected into
      an annotating module is itself a warning.
  """

  @typedoc "Decoded state: assign name => value"
  @type state :: %{atom() => term()}

  @doc """
  Invoked with the decoded state whenever it changes, and once after mount.

  Returns the socket, typically with the list re-queried. Runs after the
  LiveView's own `mount/3`, so assigns set there are available.
  """
  @callback handle_url_state(state(), Phoenix.LiveView.Socket.t()) ::
              Phoenix.LiveView.Socket.t()

  @state_assign :__phoenix_kit_url_state__
  @path_assign :__phoenix_kit_url_path__
  # For url_state_sync/1 — the only markup this module owns.
  use Phoenix.Component

  @extra_assign :__phoenix_kit_url_extra__
  @loaded_assign :__phoenix_kit_url_loaded__
  @cfg_assign :__phoenix_kit_url_cfg__

  # ── Compile-time spec normalisation ──────────────────────────────────

  @doc false
  def normalize!(params, opts) when is_list(params) do
    if params == [] do
      raise ArgumentError, "use PhoenixKitWeb.Live.UrlState requires a non-empty :params list"
    end

    specs = Enum.map(params, &normalize_param!/1)

    url_keys = Enum.map(specs, & &1.url_key)

    if length(Enum.uniq(url_keys)) != length(url_keys) do
      raise ArgumentError,
            "duplicate URL keys in PhoenixKit.UrlState spec: #{inspect(url_keys -- Enum.uniq(url_keys))}"
    end

    %{
      params: specs,
      mode: validate_mode!(Keyword.get(opts, :mode, :patch)),
      dead_render: validate_dead_render!(Keyword.get(opts, :dead_render, :call)),
      page_param: resolve_page_param!(Keyword.get(opts, :page_param, :__auto__), specs)
    }
  end

  def normalize!(other, _opts) do
    raise ArgumentError, ":params must be a keyword list, got: #{inspect(other)}"
  end

  defp normalize_param!({key, opts}) when is_atom(key) and is_list(opts) do
    unless Keyword.has_key?(opts, :default) do
      raise ArgumentError, "PhoenixKit.UrlState param #{inspect(key)} is missing :default"
    end

    cast = Keyword.get(opts, :cast, :string)

    unless cast in [:string, :integer, :atom, :boolean] do
      raise ArgumentError,
            "PhoenixKit.UrlState param #{inspect(key)} has unsupported cast #{inspect(cast)}"
    end

    allowed = Keyword.get(opts, :in)

    if cast == :atom and is_nil(allowed) do
      raise ArgumentError,
            "PhoenixKit.UrlState param #{inspect(key)} uses cast: :atom and therefore requires " <>
              ":in — the incoming string is matched against it so that no atom is created from " <>
              "user input"
    end

    %{
      key: key,
      url_key: to_string(Keyword.get(opts, :url_key, key)),
      aliases: opts |> Keyword.get(:alias, []) |> List.wrap() |> Enum.map(&to_string/1),
      default: Keyword.fetch!(opts, :default),
      cast: cast,
      allowed: allowed,
      min: Keyword.get(opts, :min),
      max: integer_max(cast, opts)
    }
  end

  defp normalize_param!(other) do
    raise ArgumentError,
          "PhoenixKit.UrlState params must be `assign_name: [default: …]`, got: #{inspect(other)}"
  end

  # An unbounded integer from the URL is a 500 waiting to happen: a page number
  # of 10^24 survives Integer.parse, reaches Ecto as OFFSET, and overflows
  # PostgreSQL's bigint. Integer params therefore get a ceiling whether or not
  # the caller thought to set one; anything above it falls back to the default.
  @default_integer_max 1_000_000
  defp integer_max(:integer, opts), do: Keyword.get(opts, :max, @default_integer_max)
  defp integer_max(_cast, opts), do: Keyword.get(opts, :max)

  defp validate_mode!(value) when value in [:patch, :history], do: value

  defp validate_mode!(other) do
    raise ArgumentError, ":mode must be :patch or :history, got: #{inspect(other)}"
  end

  defp validate_dead_render!(value) when value in [:skip, :call], do: value

  defp validate_dead_render!(other) do
    raise ArgumentError, ":dead_render must be :skip or :call, got: #{inspect(other)}"
  end

  defp resolve_page_param!(:__auto__, specs) do
    if Enum.any?(specs, &(&1.key == :page)), do: :page, else: false
  end

  defp resolve_page_param!(false, _specs), do: false

  defp resolve_page_param!(key, specs) when is_atom(key) do
    unless Enum.any?(specs, &(&1.key == key)) do
      raise ArgumentError, ":page_param #{inspect(key)} is not declared in :params"
    end

    key
  end

  # ── Decoding: query params -> state ──────────────────────────────────

  @doc """
  Decodes LiveView params into the state map, applying defaults.

  Public so a LiveView that does its own thing with `handle_params/3` can still
  share the exact codec.
  """
  @spec decode(map() | :not_mounted_at_router, map()) :: state()
  def decode(params, cfg) when is_map(params) do
    Map.new(cfg.params, fn spec -> {spec.key, decode_param(params, spec)} end)
  end

  def decode(_not_a_map, cfg) do
    Map.new(cfg.params, fn spec -> {spec.key, spec.default} end)
  end

  defp decode_param(params, spec) do
    case fetch_raw(params, [spec.url_key | spec.aliases]) do
      :error -> spec.default
      {:ok, raw} -> cast_value(raw, spec)
    end
  end

  defp fetch_raw(params, keys) do
    Enum.reduce_while(keys, :error, fn key, acc ->
      case Map.fetch(params, key) do
        {:ok, value} when is_binary(value) -> {:halt, {:ok, value}}
        _ -> {:cont, acc}
      end
    end)
  end

  defp cast_value(raw, %{cast: :string} = spec), do: validate_allowed(raw, spec)

  defp cast_value(raw, %{cast: :integer} = spec) do
    case Integer.parse(raw) do
      {int, ""} -> validate_bounds(int, spec)
      _ -> spec.default
    end
  end

  defp cast_value(raw, %{cast: :boolean} = spec) do
    case raw do
      "1" -> true
      "true" -> true
      "0" -> false
      "false" -> false
      _ -> spec.default
    end
  end

  # Never String.to_atom/1 on user input: the raw string is compared against the
  # already-existing atoms in :in, so an unknown value can only reach the default.
  defp cast_value(raw, %{cast: :atom} = spec) do
    Enum.find(spec.allowed, spec.default, &(to_string(&1) == raw))
  end

  defp validate_allowed(value, %{allowed: nil}), do: value

  defp validate_allowed(value, spec) do
    if value in spec.allowed, do: value, else: spec.default
  end

  defp validate_bounds(int, spec) do
    cond do
      spec.min != nil and int < spec.min -> spec.default
      spec.max != nil and int > spec.max -> spec.default
      true -> validate_allowed(int, spec)
    end
  end

  # ── Encoding: state -> query params ──────────────────────────────────

  @doc """
  Encodes the state into a query map, omitting every value equal to its default.

  `extra` carries query keys the spec does not know about so that an unrelated
  param survives a filter change.
  """
  @spec encode(state(), map(), map()) :: %{String.t() => String.t()}
  def encode(state, cfg, extra \\ %{}) do
    Enum.reduce(cfg.params, extra, fn spec, acc ->
      value = Map.get(state, spec.key, spec.default)

      if value == spec.default do
        Map.delete(acc, spec.url_key)
      else
        Map.put(acc, spec.url_key, to_string(value))
      end
    end)
  end

  @doc """
  Builds `path?query` from a state map, or bare `path` when nothing differs
  from the defaults.
  """
  @spec build_path(String.t(), state(), map(), map()) :: String.t()
  def build_path(path, state, cfg, extra \\ %{}) do
    case encode(state, cfg, extra) do
      empty when map_size(empty) == 0 -> path
      query -> path <> "?" <> URI.encode_query(query)
    end
  end

  # ── Runtime: on_mount and hooks ──────────────────────────────────────

  @doc false
  def on_mount({:url_state, cfg}, params, _session, socket) do
    if cfg.mode == :patch, do: ensure_router!(socket)

    socket =
      socket
      |> assign_state(decode(params, cfg), cfg)
      # Extras are filled from the real query string in handle_params
      # (:patch) or the client report (:history). Seeding them from the
      # mount params map would re-encode router path params — the same
      # leak extras_from_uri/2 exists to close.
      |> Phoenix.Component.assign(@extra_assign, %{})
      # :patch has a handle_params hook to make the first call; :history has
      # none, so its LiveViews load in mount/3 and are already "loaded" by the
      # time the client reports the query. Marking it here keeps that report
      # from costing a redundant query whenever the URL held nothing anyway.
      |> Phoenix.Component.assign(@loaded_assign, cfg.mode == :history)
      |> Phoenix.Component.assign(@cfg_assign, cfg)
      |> attach_mode_hooks(cfg)

    {:cont, socket}
  end

  defp attach_mode_hooks(socket, %{mode: :patch}) do
    Phoenix.LiveView.attach_hook(socket, :phoenix_kit_url_state, :handle_params, &handle_params/3)
  end

  # :history never touches handle_params — attaching that stage raises outright
  # when the view has no router, and exporting the callback is what makes a
  # LiveView un-embeddable in the first place. A :handle_event hook has no such
  # restriction, so the client drives the state through two events instead.
  defp attach_mode_hooks(socket, %{mode: :history}) do
    Phoenix.LiveView.attach_hook(socket, :phoenix_kit_url_state, :handle_event, &handle_client/3)
  end

  # The browser owns the URL in :history mode, so it is also the only thing that
  # knows the query on an embedded mount, where params arrive as
  # :not_mounted_at_router. The hook reports it once on connect, and again on
  # every popstate — which is what makes Back work without a router.
  defp handle_client("phoenix_kit_url_state", %{"query" => query}, socket) do
    cfg = config!(socket)
    params = decode_query(query)
    state = decode(params, cfg)

    socket =
      socket
      |> Phoenix.Component.assign(@extra_assign, extra_params(params, cfg))
      |> apply_state(state, cfg)

    {:halt, socket}
  end

  defp handle_client(_event, _params, socket), do: {:cont, socket}

  defp decode_query(query) when is_binary(query) do
    query |> String.trim_leading("?") |> URI.decode_query()
  end

  defp decode_query(_query), do: %{}

  # A LiveView using this module exports handle_params/3 (its own or the
  # injected stub), which already makes an embedded mount fail deep inside
  # Phoenix with a message about live_link_info. Fail here instead, where the
  # cause is nameable.
  defp ensure_router!(socket) do
    if is_nil(socket.router) do
      raise """
      #{inspect(socket.view)} uses PhoenixKitWeb.Live.UrlState but was not mounted \
      through the router.

      URL-backed state relies on push_patch, which requires handle_params/3 to be \
      exported, and exporting it makes a LiveView un-embeddable via live_render/3. \
      The two cannot be combined; see the module docs.
      """
    end

    socket
  end

  defp handle_params(params, uri, socket) do
    cfg = config!(socket)
    parsed = URI.parse(uri)

    # Extras must come from the URI's ACTUAL query string, not the params
    # map LiveView hands in — that map merges router PATH params (a
    # `/:uuid` segment, say) with the query, and treating a path param as
    # an unknown-but-preserved query key re-encodes it into every patched
    # URL (`?q=oak` became `?q=oak&uuid=<uuid>`).
    socket =
      socket
      |> Phoenix.Component.assign(@path_assign, parsed.path)
      |> Phoenix.Component.assign(@extra_assign, extras_from_uri(parsed, cfg))
      |> apply_state(decode(params, cfg), cfg)

    {:cont, socket}
  end

  @doc """
  Unknown query keys from a URI, excluding declared UrlState keys.

  Reads the URI's **query string only** — never the path — so a router
  segment such as `/:uuid` is not treated as an extra to re-encode into
  the next patch. Public so a LiveView that owns `handle_params/3` can
  share the same rule, and so the contract is cheap to pin in a test.
  """
  @spec extras_from_uri(String.t() | URI.t(), map()) :: %{String.t() => String.t()}
  def extras_from_uri(uri, cfg) when is_binary(uri), do: extras_from_uri(URI.parse(uri), cfg)
  def extras_from_uri(%URI{} = uri, cfg), do: extra_params(query_params(uri), cfg)

  defp query_params(%URI{query: nil}), do: %{}
  defp query_params(%URI{query: query}), do: URI.decode_query(query)

  # Assign the decoded state and, if it actually moved, hand it to the
  # LiveView's callback. Shared by both modes: the patch hook, the client's
  # init/popstate report, and the local application in :history mode all need
  # exactly this.
  defp apply_state(socket, state, cfg) do
    reload? = reload?(socket.assigns[@loaded_assign], state, socket.assigns[@state_assign])
    socket = assign_state(socket, state, cfg)

    if reload? and run_callback?(socket, cfg) do
      socket = Phoenix.Component.assign(socket, @loaded_assign, true)
      socket.view.handle_url_state(state, socket)
    else
      socket
    end
  end

  @doc """
  Whether a navigation should re-run `handle_url_state/2`.

  The hook fires on every navigation in the LiveView, not only the ones this
  module caused. A patch touching an unrelated query key — the media selector's
  `?return_to=…`, a host LiveView's own patch — must not make the list re-run
  its queries, so the callback runs only when the declared state actually
  differs, or when it has never run at all.

  Public because it is the one branch that decides whether a shared link, a
  Back press or a filter change reloads; it is worth pinning in a test without
  a router.
  """
  @spec reload?(boolean() | nil, state(), state() | nil) :: boolean()
  def reload?(loaded?, new_state, previous_state)
  def reload?(true, state, state), do: false
  def reload?(true, _new, _previous), do: true
  def reload?(_not_loaded, _new, _previous), do: true

  defp run_callback?(socket, cfg) do
    cfg.dead_render == :call or Phoenix.LiveView.connected?(socket)
  end

  defp assign_state(socket, state, cfg) do
    socket = Phoenix.Component.assign(socket, @state_assign, state)

    Enum.reduce(cfg.params, socket, fn spec, acc ->
      Phoenix.Component.assign(acc, spec.key, Map.fetch!(state, spec.key))
    end)
  end

  # Query keys the spec does not own — kept verbatim so that the media
  # selector's ?return_to=…&mode=single is not dropped the moment a filter
  # changes, stranding the user with no way back.
  defp extra_params(params, cfg) when is_map(params) do
    known =
      Enum.flat_map(cfg.params, fn spec -> [spec.url_key | spec.aliases] end)
      |> MapSet.new()

    params
    |> Enum.filter(fn {k, v} ->
      is_binary(k) and is_binary(v) and not MapSet.member?(known, k)
    end)
    |> Map.new()
  end

  # Accepts a socket or a bare assigns map. Inside a template `@socket.assigns`
  # has been swapped for `%Socket.AssignsNotInSocket{}`, which raises on access
  # — so a HEEX caller passes `assigns` instead, and the config travels in an
  # assign rather than being read back off `socket.view`.
  defp assigns_of(%Phoenix.LiveView.Socket{assigns: assigns}), do: assigns
  defp assigns_of(assigns) when is_map(assigns), do: assigns

  defp config!(socket_or_assigns) do
    case assigns_of(socket_or_assigns) do
      %{@cfg_assign => cfg} ->
        cfg

      _ ->
        raise ArgumentError, """
        UrlState config not found in assigns.

        Inside a HEEX template pass `assigns`, not `@socket` — LiveView replaces
        `socket.assigns` with %Phoenix.LiveView.Socket.AssignsNotInSocket{} while
        rendering, so `@socket` cannot carry state into a template:

            <.link patch={url_state_path(assigns, page: 2)}>2</.link>
        """
    end
  end

  # ── Runtime: writing state ───────────────────────────────────────────

  @doc """
  Merges `changes` into the current state and patches the URL.

  Resets the page parameter unless the page itself changed. Pass
  `replace: true` for continuous input so a debounced search box leaves one
  history entry instead of one per keystroke pause.
  """
  @spec push_url_state(Phoenix.LiveView.Socket.t(), keyword() | map(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def push_url_state(socket, changes, opts \\ []) do
    cfg = config!(socket)
    replace? = Keyword.get(opts, :replace, false)

    case cfg.mode do
      :patch ->
        Phoenix.LiveView.push_patch(socket,
          to: url_state_path(socket, changes),
          replace: replace?
        )

      # No patch to bounce off, so the state is applied here and the browser is
      # told to rewrite its address bar. The path stays client-side on purpose:
      # an embedded LiveView has no idea what page it is on.
      :history ->
        assigns = assigns_of(socket)
        state = next_state(assigns, changes, cfg)
        query = state |> encode(cfg, assigns[@extra_assign] || %{}) |> URI.encode_query()

        socket
        |> Phoenix.LiveView.push_event("phoenix_kit_url_state", %{
          query: query,
          replace: replace?
        })
        |> apply_state(state, cfg)
    end
  end

  @doc """
  The path this LiveView would patch to for `changes` — for `<.link patch=…>`
  and `<.pagination>`, which navigate by href rather than by event.

  Takes a socket, or — from inside a template, where `@socket` carries no
  assigns — the template's own `assigns`:

      <.link patch={url_state_path(assigns, page: page)}>{page}</.link>
  """
  @spec url_state_path(Phoenix.LiveView.Socket.t() | map(), keyword() | map()) :: String.t()
  def url_state_path(socket_or_assigns, changes) do
    assigns = assigns_of(socket_or_assigns)
    cfg = config!(assigns)

    path = assigns[@path_assign] || assigns[:url_path] || "/"
    extra = assigns[@extra_assign] || %{}

    build_path(path, next_state(assigns, changes, cfg), cfg, extra)
  end

  # The state a set of changes resolves to: merged onto what the assigns
  # currently hold, page reset when anything else moved, and sanitised so
  # nothing the decoder would reject can reach the URL.
  defp next_state(assigns, changes, cfg) do
    changes = changes |> Map.new() |> validate_changes!(cfg)

    assigns
    |> current_state(cfg)
    |> Map.merge(changes)
    |> maybe_reset_page(changes, cfg)
    |> sanitize(cfg)
  end

  # The merge base is read back from the individual assigns, not from the
  # bookkeeping state map, because the two can legitimately drift: a LiveView
  # may set a declared param with a plain `assign` — a list re-picking its sort
  # column after the current one is hidden does exactly that. Merging onto the
  # stale map would then resurrect the old value on the next patch, and a
  # reload would apply it. Reading the assigns makes the freshest value win,
  # whichever way it was set. The map is only a fallback for a param an
  # unusual LiveView has dropped from its assigns.
  defp current_state(assigns, cfg) do
    stored = Map.get(assigns, @state_assign, %{})

    Map.new(cfg.params, fn spec ->
      {spec.key, Map.get(assigns, spec.key, Map.get(stored, spec.key, spec.default))}
    end)
  end

  # Changes are keyed by assign name, not by URL key — an easy thing to get
  # backwards. Left unchecked, `push_url_state(socket, q: "x")` on a param
  # declared as `search_query: [url_key: "q"]` would silently do nothing except
  # reset the page, which reads as "search is broken" with no error anywhere.
  defp validate_changes!(changes, cfg) do
    declared = MapSet.new(cfg.params, & &1.key)

    case Enum.reject(Map.keys(changes), &MapSet.member?(declared, &1)) do
      [] ->
        changes

      unknown ->
        raise ArgumentError, """
        unknown UrlState parameter(s): #{inspect(unknown)}

        Changes are keyed by assign name, not by URL key. Declared: \
        #{inspect(MapSet.to_list(declared))}
        """
    end
  end

  # A value the decoder would reject must never reach the URL, or the address
  # bar and the assigns disagree: the link says one thing, a reload shows
  # another. Callers do push values the spec has not seen — a screen that
  # re-picks a sort column after the current one is hidden hands over whatever
  # column is left, sortable or not.
  defp sanitize(state, cfg) do
    Map.new(cfg.params, fn spec ->
      value = Map.get(state, spec.key, spec.default)
      {spec.key, if(valid_value?(value, spec), do: value, else: spec.default)}
    end)
  end

  defp valid_value?(value, %{allowed: nil} = spec), do: within_bounds?(value, spec)
  defp valid_value?(value, spec), do: value in spec.allowed and within_bounds?(value, spec)

  defp within_bounds?(value, %{cast: :integer} = spec) when is_integer(value) do
    (is_nil(spec.min) or value >= spec.min) and (is_nil(spec.max) or value <= spec.max)
  end

  defp within_bounds?(_value, _spec), do: true

  defp maybe_reset_page(state, _changes, %{page_param: false}), do: state

  defp maybe_reset_page(state, changes, cfg) do
    if Map.has_key?(changes, cfg.page_param) or map_size(changes) == 0 do
      state
    else
      default = Enum.find(cfg.params, &(&1.key == cfg.page_param)).default
      Map.put(state, cfg.page_param, default)
    end
  end

  @doc """
  Gives a declared parameter another default, for this LiveView only: a
  person's own saved page size, say (`PhoenixKitWeb.PageSize`).

  The new default is what a URL without the key reads as, what
  `reset_url_state/1` goes back to, and what is left out of every URL the
  LiveView writes. A URL that names another value still wins.

  Call it in `mount/3`. In `:patch` mode the first `handle_params` runs after
  mount and reads the query with it. In `:history` mode the client's report on
  connect does, so a dead render shows the declared default. A value the
  parameter would refuse from a URL (wrong type, not in `:in`, out of bounds)
  is ignored, and the default stays as it was.
  """
  @spec put_url_state_default(Phoenix.LiveView.Socket.t(), atom(), term()) ::
          Phoenix.LiveView.Socket.t()
  def put_url_state_default(socket, key, value) do
    cfg = config!(socket)

    case Enum.find_index(cfg.params, &(&1.key == key)) do
      nil ->
        raise ArgumentError, "unknown UrlState parameter: #{inspect(key)}"

      index ->
        spec = Enum.at(cfg.params, index)

        if cast_type?(value, spec.cast) and valid_value?(value, spec) do
          params = List.replace_at(cfg.params, index, %{spec | default: value})
          Phoenix.Component.assign(socket, @cfg_assign, %{cfg | params: params})
        else
          socket
        end
    end
  end

  defp cast_type?(value, :integer), do: is_integer(value)
  defp cast_type?(value, :boolean), do: is_boolean(value)
  defp cast_type?(value, :atom), do: is_atom(value)
  defp cast_type?(value, :string), do: is_binary(value)

  @doc """
  Resets every declared parameter to its default — the "clear all filters"
  action. Unknown query keys are preserved.
  """
  @spec reset_url_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset_url_state(socket) do
    cfg = config!(socket)
    defaults = Map.new(cfg.params, &{&1.key, &1.default})

    push_url_state(socket, defaults)
  end

  @doc """
  Renders the element `mode: :history` needs, and nothing in `:patch` mode.

  The browser owns the URL there, so something has to carry the JS hook that
  reports the query on connect, rewrites the address bar on a change, and
  reports Back and Forward. Put it anywhere inside the LiveView's own markup:

      <.url_state_sync mode={:history} />
  """
  attr :mode, :atom, default: :patch, doc: "the `:mode` the LiveView declared"
  attr :id, :string, default: "phoenix-kit-url-state", doc: "unique when nested"

  def url_state_sync(assigns) do
    ~H"""
    <div :if={@mode == :history} id={@id} phx-hook="PhoenixKitUrlState" hidden></div>
    """
  end

  # ── use ──────────────────────────────────────────────────────────────

  defmacro __using__(opts) do
    params = Keyword.get(opts, :params) || raise ArgumentError, "missing :params"

    # The spec is normalised in the CALLER's module body, not here. At macro
    # expansion the option values are still unexpanded AST: `in: [:asc, :desc]`
    # happens to *be* a list of atoms and so works by accident, but
    # `in: ~w(name email)` is a `{:sigil_w, …}` node, and matching a URL value
    # against a tuple raises Protocol.UndefinedError at request time — past
    # compilation, past the codec's own tests. Unquoting the options into a
    # module attribute makes them evaluate normally, so the spec sees the list
    # the sigil produces.
    quote do
      @behaviour PhoenixKitWeb.Live.UrlState

      import PhoenixKitWeb.Live.UrlState,
        only: [
          push_url_state: 2,
          push_url_state: 3,
          url_state_path: 2,
          reset_url_state: 1,
          put_url_state_default: 3,
          url_state_sync: 1
        ]

      @phoenix_kit_url_state_cfg PhoenixKitWeb.Live.UrlState.normalize!(
                                   unquote(params),
                                   unquote(opts)
                                 )

      @doc false
      def __phoenix_kit_url_state__, do: @phoenix_kit_url_state_cfg

      on_mount({PhoenixKitWeb.Live.UrlState, {:url_state, @phoenix_kit_url_state_cfg}})

      @before_compile PhoenixKitWeb.Live.UrlState
    end
  end

  defmacro __before_compile__(env) do
    cfg = Module.get_attribute(env.module, :phoenix_kit_url_state_cfg)

    # In :patch mode, push_patch routes through
    # sync_handle_params_with_live_redirect/5, which calls
    # Utils.call_handle_params!/4 — the arity whose `exported?` defaults to
    # true. view.handle_params/3 is therefore invoked whether or not the
    # LiveView defines it, so one without it needs a stub.
    #
    # In :history mode the stub must NOT be injected: exporting handle_params/3
    # is precisely what makes a LiveView un-embeddable, which is the whole
    # reason that mode exists.
    if cfg.mode == :patch and not Module.defines?(env.module, {:handle_params, 3}) do
      quote do
        @doc false
        def handle_params(_params, _uri, socket), do: {:noreply, socket}
      end
    else
      quote(do: nil)
    end
  end
end
