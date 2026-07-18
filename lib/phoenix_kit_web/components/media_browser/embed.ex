defmodule PhoenixKitWeb.Components.MediaBrowser.Embed do
  @moduledoc """
  One-line embedder for `PhoenixKitWeb.Components.MediaBrowser`.

  LiveView uploads must live on the parent socket (not the LiveComponent),
  so embedding the MediaBrowser requires three small pieces of plumbing on
  the parent: an `allow_upload`, a `"validate"` event stub for the upload
  channel, and a `handle_info` delegator for component→parent messages.

  This module bundles all three into a single `use` call.

  ## Usage

      defmodule MyAppWeb.MediaPage do
        use MyAppWeb, :live_view
        use PhoenixKitWeb.Components.MediaBrowser.Embed

        def mount(_params, _session, socket) do
          {:ok, socket}
        end
      end

  Then in the template:

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="media-browser"
        parent_uploads={@uploads}
      />

  ## URL sync (shareable folder links)

  Pass `url_sync: true` (or `url_sync: [id: "your-component-id"]`) to make
  the embedded browser reflect the current folder / search / page / view
  in the page URL — so a deep link like `…?folder=<uuid>` reopens that
  folder on reload and can be shared with someone else.

      use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: true

      # multiple browsers, or a non-default component id:
      use PhoenixKitWeb.Components.MediaBrowser.Embed,
        url_sync: [id: "my-media-browser"]

  With `url_sync` on, the host template must pass the controlled-mode
  attrs through to the component:

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="media-browser"
        on_navigate={:navigate}
        initial_params={@initial_params}
        parent_uploads={@uploads}
      />

  Everything else is automatic: `initial_params` is parsed from the URL
  in `on_mount`, folder navigation `push_patch`es the new params into the
  address bar, and a reload feeds them back to the component. The folder
  is tracked by **uuid** (stable across renames); an unknown / out-of-scope
  uuid falls back to root. The base path is taken from the live URL, so
  any router prefix is respected.

  URL sync is implemented with LiveView lifecycle hooks
  (`attach_hook(:handle_params)` + `attach_hook(:handle_info)` in
  `on_mount`), **not** injected `handle_params/3` clauses — so it composes
  cleanly with a host LiveView that already defines its own
  `handle_params` / `handle_info` (e.g. an `…/orders/:id/edit/files`
  page that loads the order in its own `handle_params`). Nothing to
  reconcile; both run. The `push_patch` only appends the query string to
  the *current* path, so every existing segment (locale, parent resource
  ids, sub-tab) is preserved.

  Single-browser-per-page is assumed: the query keys (`folder`, `q`,
  `page`, `orphaned`, `view`) are not namespaced per component, so two
  url-synced browsers on one page would fight over them. Give only one
  the `url_sync` option in that case.

  ## What gets injected

  * `on_mount` — calls `MediaBrowser.setup_uploads/1` so `@uploads.media_files`
    is available on every mount of this LiveView. On connected mounts that
    also subscribes to storage file events and attaches a `:handle_info`
    hook forwarding `{:phoenix_kit_file_processed, uuid}` to every embedded
    browser — a just-uploaded file's thumbnails/dimensions appear live once
    background processing finishes, no reload needed. With `url_sync`, also
    assigns `:initial_params` parsed from the mount params.
  * Fallback `handle_event("validate", _, socket)` — absorbs the upload
    channel's `phx-change` events. User-defined clauses with other event
    names still win because they are defined first.
  * With `url_sync`: a `:handle_params` hook (feeds URL params to the
    component + captures the live path) and a `:handle_info` hook that
    intercepts `{MediaBrowser, id, {:navigate, _}}` and `push_patch`es,
    both attached in `on_mount` so they compose with the host's own
    handlers.
  * Fallback `handle_info({MediaBrowser, _, _}, socket)` — forwards to
    `MediaBrowser.handle_parent_info/2` for component registration and
    upload piping.
  * Fallback `handle_info({:leaf_changed, _}, socket)` — routes
    Leaf editor content updates from the sidebar comments (when
    PhoenixKitComments is installed) to
    `PhoenixKitComments.Web.CommentsComponent.forward_leaf_event/2`.
    Without this, comment Leaf editors render but the typed
    content never reaches the server. The clause only injects
    when `PhoenixKitComments.Web.CommentsComponent` is loaded —
    otherwise it's compiled away. User-defined `:leaf_changed`
    clauses (e.g. for a post-content editor on the same page)
    still win because they are defined first.

  All fallbacks are injected via `@before_compile`, so user clauses
  declared earlier in the module match before them.
  """

  alias PhoenixKitWeb.Components.MediaBrowser

  # ── on_mount ────────────────────────────────────────────────────
  # `:default` — uploads only (the no-url_sync path; unchanged).
  def on_mount(:default, _params, _session, socket) do
    {:cont, MediaBrowser.setup_uploads(socket)}
  end

  # `{:embed, %{...}}` — url_sync on: parse the URL params into
  # :initial_params so the component opens the shared folder on first render
  # (controlled mode reads @initial_params), and seed the nav baseline so the
  # :handle_params hook can skip redundant send_updates (see below). The
  # no-url_sync path uses `:default` above — `__using__` never emits
  # `{:embed, false}`, so there is no clause for it.
  def on_mount({:embed, %{id: component_id}}, params, _session, socket) do
    # `:initial_params` gives the component the right folder on the very
    # first (even static) render — avoids a flash of root before the
    # handle_params hook fires on connect. `:__phoenix_kit_mb_nav__` records
    # the params already reflected in the component so the hook can skip a
    # send_update when the next handle_params carries the same nav.
    nav = parse_nav_params(params)

    socket =
      socket
      |> MediaBrowser.setup_uploads()
      |> Phoenix.Component.assign(:initial_params, nav)
      |> Phoenix.Component.assign(:__phoenix_kit_mb_nav__, nav)
      |> attach_url_sync_hooks(component_id)

    {:cont, socket}
  end

  # URL-sync via lifecycle hooks rather than injected handle_params /
  # handle_info clauses, so it composes with a host LiveView that already
  # defines its own (e.g. an `…/orders/:id/edit/files` page that loads the
  # order in its own handle_params). The :handle_params hook feeds URL
  # params to the component and captures the live path; the :handle_info
  # hook intercepts the component's {:navigate, …} and push_patches the
  # new query onto that same path (preserving every path segment — locale,
  # parent resource ids, sub-tab), {:halt}ing so it doesn't fall through.
  #
  # The :handle_params hook fires on *every* navigation in the host LiveView,
  # not just media-browser ones, so it only send_updates when the parsed nav
  # actually changed — otherwise an unrelated host push_patch would make the
  # component re-run its folder/file/orphan/trash queries for no reason.
  defp attach_url_sync_hooks(socket, component_id) do
    socket
    |> Phoenix.LiveView.attach_hook(:phoenix_kit_mb_url_sync_params, :handle_params, fn
      params, uri, socket ->
        socket = Phoenix.Component.assign(socket, :__phoenix_kit_mb_path__, URI.parse(uri).path)
        nav = parse_nav_params(params)

        if Phoenix.LiveView.connected?(socket) and nav != socket.assigns[:__phoenix_kit_mb_nav__] do
          Phoenix.LiveView.send_update(MediaBrowser, id: component_id, nav_params: nav)
          {:cont, Phoenix.Component.assign(socket, :__phoenix_kit_mb_nav__, nav)}
        else
          {:cont, socket}
        end
    end)
    |> Phoenix.LiveView.attach_hook(:phoenix_kit_mb_url_sync_info, :handle_info, fn
      {MediaBrowser, ^component_id, {:navigate, nav}}, socket ->
        qs = build_nav_query(nav)
        base = socket.assigns[:__phoenix_kit_mb_path__] || "/"
        url = if qs == %{}, do: base, else: base <> "?" <> URI.encode_query(qs)
        {:halt, Phoenix.LiveView.push_patch(socket, to: url)}

      _msg, socket ->
        {:cont, socket}
    end)
  end

  # ── Shared URL <-> nav-params helpers (public so a host with its own
  # handle_params can reuse the exact parse/build the macro uses) ──────

  @doc """
  Parse a LiveView params map into the `nav_params` shape MediaBrowser's
  controlled mode expects (`folder`, `q`, `page`, `filter_orphaned`,
  `view`).
  """
  def parse_nav_params(params) do
    %{
      folder: params["folder"],
      q: params["q"] || "",
      page: parse_page(params["page"]),
      filter_orphaned: params["orphaned"] == "1",
      view: params["view"]
    }
  end

  @doc """
  Build the query-string map from a `{:navigate, params}` payload —
  omitting defaults so a root, unsearched, first-page view yields a clean
  bare URL.
  """
  def build_nav_query(p) do
    folder = p[:folder]
    q = p[:q] || ""
    page = p[:page] || 1
    filter_orphaned = p[:filter_orphaned] || false
    view = p[:view]

    %{}
    |> then(&if(folder, do: Map.put(&1, "folder", folder), else: &1))
    |> then(&if(q != "", do: Map.put(&1, "q", q), else: &1))
    |> then(&if(page > 1, do: Map.put(&1, "page", page), else: &1))
    |> then(&if(filter_orphaned, do: Map.put(&1, "orphaned", "1"), else: &1))
    |> then(&if(view == "all", do: Map.put(&1, "view", "all"), else: &1))
  end

  defp parse_page(p) do
    case Integer.parse(p || "1") do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defmacro __using__(opts) do
    sync =
      case Keyword.get(opts, :url_sync, false) do
        false -> false
        true -> %{id: "media-browser"}
        kw when is_list(kw) -> %{id: Keyword.get(kw, :id, "media-browser")}
      end

    on_mount_arg = if sync, do: {:embed, sync}, else: :default

    quote do
      @phoenix_kit_mb_url_sync unquote(sync != false)
      on_mount({PhoenixKitWeb.Components.MediaBrowser.Embed, unquote(Macro.escape(on_mount_arg))})
      @before_compile PhoenixKitWeb.Components.MediaBrowser.Embed
    end
  end

  defmacro __before_compile__(env) do
    # `url_sync` push_patches from the :handle_info hook. LiveView routes a
    # push_patch issued inside handle_info through
    # `sync_handle_params_with_live_redirect`, which calls
    # `call_handle_params!/4` with `exported?` defaulting to TRUE — i.e. it
    # invokes `view.handle_params/3` unconditionally. The :handle_params
    # hook already did the real work, but if the host LiveView defines no
    # handle_params/3 of its own that call blows up
    # (UndefinedFunctionError). Inject a trivial stub in exactly that case;
    # a host that defines its own keeps it (the hook composes alongside).
    stub_handle_params? =
      Module.get_attribute(env.module, :phoenix_kit_mb_url_sync, false) and
        not Module.defines?(env.module, {:handle_params, 3})

    handle_params_stub =
      if stub_handle_params? do
        quote do
          def handle_params(_params, _uri, socket), do: {:noreply, socket}
        end
      else
        quote do
        end
      end

    # Fully-qualified references on purpose: this code is injected into the
    # caller's module, where aliasing from Embed wouldn't be in scope.
    #
    # The leaf-forwarder is always injected (not gated at MACRO-compile
    # time on Code.ensure_loaded?) because phoenix_kit_comments may not be
    # loaded yet when phoenix_kit compiles — they're sibling deps with no
    # compile-order guarantee. Runtime `Code.ensure_loaded?` inside the
    # clause does the right thing: when the comments package is installed,
    # the event is forwarded; when it isn't, the clause is a no-op.
    quote do
      def handle_event("validate", _params, socket), do: {:noreply, socket}

      unquote(handle_params_stub)

      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      def handle_info(
            {PhoenixKitWeb.Components.MediaBrowser, _, _} = msg,
            socket
          ) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
      end

      def handle_info({:leaf_changed, _} = msg, socket) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        PhoenixKitWeb.CommentsForwarding.forward_leaf_changed(msg, socket)
      end
    end
  end
end
