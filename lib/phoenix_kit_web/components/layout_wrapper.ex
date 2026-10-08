defmodule PhoenixKitWeb.Components.LayoutWrapper do
  @compile {:no_warn_undefined,
            [PhoenixKit.Modules.Legal, PhoenixKit.Modules.Legal.CookieConsent]}

  @moduledoc """
  Dynamic layout wrapper component for Phoenix v1.7- and v1.8+ compatibility.

  This component automatically detects the Phoenix version and layout configuration
  to provide seamless integration with parent applications while maintaining
  backward compatibility.

  ## Usage

  Replace direct layout calls with the wrapper:

      <%!-- OLD (Phoenix v1.7-) --%>
      <%!-- Templates relied on router-level layout config --%>

      <%!-- NEW (Phoenix v1.8+) --%>
      <PhoenixKitWeb.Components.LayoutWrapper.app_layout flash={@flash}>
        <%!-- content --%>
      </PhoenixKitWeb.Components.LayoutWrapper.app_layout>

  ## Configuration

  Configure parent layout in config.exs:

      config :phoenix_kit,
        layout: {MyAppWeb.Layouts, :app}

  """
  use Phoenix.Component
  use PhoenixKitWeb, :verified_routes
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.Flash, only: [flash_group: 1]
  import PhoenixKitWeb.Components.Core.LibraryLoadNotice, only: [library_load_notice: 1]

  import PhoenixKitWeb.Components.Core.PhoenixKitFavicon
  import PhoenixKitWeb.Components.Core.PhoenixKitGlobals
  import PhoenixKitWeb.Components.Core.CrumbSwitcher, only: [crumb_switcher: 1]
  import PhoenixKitWeb.Components.AdminNav
  import PhoenixKitWeb.Components.Dashboard.AdminSidebar, only: [admin_sidebar: 1]
  import PhoenixKitWeb.Components.InvitationBanner, only: [invitation_banners: 1]

  alias Phoenix.HTML
  alias Phoenix.LiveView.TagEngine
  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.ThemeConfig
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.PhoenixVersion
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.WebsiteAccess
  alias PhoenixKitWeb.Components.Core.AdminLabel
  alias PhoenixKitWeb.Users.Auth

  @doc """
  Renders content with the appropriate layout based on configuration and Phoenix version.

  Automatically handles:
  - Phoenix v1.8+ function component layouts
  - Phoenix v1.7- legacy layout configuration
  - Fallback to PhoenixKit layouts when no parent configured
  - Parent layout compatibility with PhoenixKit assigns

  ## Attributes

  - `flash` - Flash messages (required)
  - `phoenix_kit_current_scope` - Current authentication scope (optional)
  - `phoenix_kit_current_user` - Current user (optional, for backwards compatibility)

  ## Inner Block

  - `inner_block` - Content to render within the layout
  """
  attr :flash, :map, default: %{}
  # Parent LiveView socket — required only to embed the sticky
  # NotificationsBell (a nested LiveView) in the admin header. Callers
  # pass `socket={@socket}`; when absent the bell is simply not rendered.
  attr :socket, :any, default: nil
  attr :phoenix_kit_current_scope, :any, default: nil
  attr :phoenix_kit_current_user, :any, default: nil
  attr :page_title, :string, default: nil
  attr :page_subtitle, :string, default: nil

  attr :page_section, :string,
    default: nil,
    doc:
      "Optional breadcrumb segment rendered between \"Admin Panel\" and `page_title` (e.g. \"Users\" on a user detail page). Desktop only — collapses along with the rest of the breadcrumb prefix on mobile."

  attr :page_section_path, :string,
    default: nil,
    doc:
      "Prefixed path (via `PhoenixKit.Utils.Routes.path/1`) the `page_section` crumb links to. Renders as plain text when omitted."

  attr :page_crumbs, :list,
    default: [],
    doc:
      "Extra breadcrumb crumbs rendered between `page_section` and `page_title`, for pages nested deeper than one level (e.g. catalogue / category drill trails): `[%{label: \"Plumbing\", path: \"/…\"}]`. `path` is a `push_navigate` target; `patch` is a `push_patch` target for same-LiveView drill trails. Both are optional — omitted renders plain text. A crumb may also carry a `:switcher` (see `page_title_switcher`): a ▾ beside it lists the other things on that crumb's level. The last crumb stays visible below `sm` (the trail truncates from the left); earlier crumbs collapse with the section."

  attr :page_title_switcher, :map,
    default: nil,
    doc:
      "A switcher on the page title itself: a ▾ beside it opening a searchable list of the other things on this level — GitHub's repository switcher. Same shape as a crumb's `:switcher` (`%{title:, items: [%{label:, navigate: | patch:, current:}], search_placeholder:}`); see `PhoenixKitWeb.Components.Core.CrumbSwitcher`."

  attr :page_action, :map,
    default: nil,
    doc:
      "Optional compact action button rendered right after the breadcrumb title: `%{icon: \"hero-plus\", label: \"New template\", navigate: path}`. Lets a page keep its primary create action without spending an in-content header row. `label` becomes the tooltip/aria-label; `icon` defaults to hero-plus. With `show_label: true` the label is written beside the icon (hidden on narrow screens, where the circle stays), for a page whose primary action should read as one. Navigation only, by design: it renders a real link, so middle-click, open-in-new-tab and copy-link keep working. For anything interactive — a `phx-click`, a modal, a `JS` command — use `page_toolbar: {Module, :fun}` on the socket (see the `:toolbar` slot), which reaches every page including plugin LiveViews rendered through the admin layout. Do not add click handling to this map."

  attr :current_path, :string, default: nil
  attr :inner_content, :string, default: nil
  attr :project_title, :string, default: nil

  attr :show_admin_panel_label, :boolean,
    default: nil,
    doc:
      "Overrides the `show_admin_panel_label` setting for this render. `nil` (the default) reads the setting. Mirrors how `project_title` overrides `Settings.get_project_title/0`, and keeps the header renderable without a database."

  attr :show_page_descriptions, :boolean,
    default: nil,
    doc:
      "Overrides the `show_page_descriptions` setting for this render. `nil` (the default) reads the setting, which is off unless an operator turns it on under Settings → General; `page_subtitle` renders only when it is on."

  attr :dev_environment, :boolean,
    default: nil,
    doc:
      "Overrides `PhoenixKit.WebsiteAccess.environment().looks_like_dev?` for this render (nil, the default, reads it). Drives the small \"[dev]\" tag next to the project title — automatic, not a setting, so a dev/staging box never has to be told apart by an admin toggle."

  attr :current_locale, :string, default: nil
  attr :from_layout, :boolean, default: false
  attr :pk_pending_invitations, :list, default: []

  attr :module_assigns, :map,
    default: %{},
    doc:
      "Module-supplied host-consumable assigns. Each key in this map is merged into the assigns set passed to the parent layout (`Layouts.app`), so a host's custom layout can read e.g. `assigns[:phoenix_kit_publishing_translations]` from publishing, or any other module-defined key. Plain `conn.assigns` don't reach a function-component layout — only declared attrs do — so this single map attribute is how modules thread arbitrary host-consumable data through the boundary without core having to declare each one explicitly."

  slot :action,
    doc: """
    **Superseded by `:toolbar` / `page_toolbar`** — prefer those for new code:
    they reach every page, including plugin LiveViews routed through the admin
    layout, which this slot never can. Kept for existing direct callers.

    The same compact action button, for pages whose primary action is not a
    navigation — a `phx-click`, a `JS` command, anything needing `phx-target`.
    The map attribute cannot express those and cannot address a LiveComponent.

    Takes render priority over the `page_action` attribute. Content is wrapped
    in the same chip shell, and the contract is **one compact control**: a
    multi-action toolbar belongs in the page body, not the breadcrumb bar.

    ⚠️ Only reaches views calling `app_layout/1` directly. Plugin LiveViews
    render through `layouts/admin.html.heex`, which threads `page_action` as an
    assign — slots do not travel through assigns — so those keep the map.

        <:action>
          <button phx-click="new_device" phx-target={@myself} title="Add device">
            <.icon name="hero-plus" class="w-4 h-4" />
          </button>
        </:action>
    """

  slot :toolbar,
    doc: """
    Controls that belong to the page's identity, rendered in the breadcrumb
    bar right after the title — a status picker, the page's ⋮ menu. Rendered
    as given (no chip shell); distinct from `page_action` / `:action`, which
    stay the one compact *create* chip.

    Two ways in. A view calling `app_layout/1` directly passes this slot. A
    plugin LiveView rendered through `layouts/admin.html.heex` cannot pass a
    slot, so it assigns `page_toolbar: {Module, :fun}` on its socket: the
    layout calls `render_page_toolbar/1` with the LiveView's own assigns
    (change-tracked) and puts the result in this slot — `phx-change` /
    `phx-click` inside it reach the LiveView as usual, because the layout
    renders inside it. Embedded mounts have no breadcrumb bar, so a page that
    is also embeddable renders the same component in its body there.

        # in a plugin LiveView's mount:
        assign(socket, page_toolbar: {__MODULE__, :header_toolbar})
        # `def header_toolbar(assigns)` renders, with ~H, e.g. a
        # `<form id="status" phx-change="change_status">` select and the
        # page's `<.table_row_menu>`; both events land in handle_event/3.
    """

  slot :inner_block, required: false

  def app_layout(assigns) do
    # Guard against double-wrapping: when admin.html.heex layout auto-applies admin
    # chrome for plugin views, the LiveView's render/1 may also call app_layout.
    #
    # Only the layout's call (from_layout=true) checks the flag. The LiveView's
    # direct call always renders normally and sets the flag for the layout to detect.
    # This avoids the stale-flag bug: in connected mode only the LiveView re-renders
    # (not the layout), so an unchecked flag would incorrectly persist across events.
    if assigns[:from_layout] && Process.delete(:phoenix_kit_admin_chrome_rendered) do
      Logger.debug(
        "[LayoutWrapper] app_layout called twice in same render tree. " <>
          "Plugin LiveViews should not call LayoutWrapper.app_layout — " <>
          "the admin.html.heex layout handles admin chrome automatically. " <>
          "Remove the LayoutWrapper wrapper from your render/1 function."
      )

      ~H"{render_slot(@inner_block)}"
    else
      app_layout_inner(assigns)
    end
  end

  defp app_layout_inner(assigns) do
    # Batch load all page settings in a single operation for optimal database performance
    assigns =
      assigns
      |> assign_new(:content_language, fn ->
        # Use the current locale from LiveView, falling back to content language setting
        # Extract base code from full dialect if necessary (e.g., "en-US" -> "en")
        case assigns[:current_locale] do
          nil ->
            PhoenixKit.Settings.get_content_language()

          locale when is_binary(locale) ->
            DialectMapper.extract_base(locale)

          _ ->
            PhoenixKit.Settings.get_content_language()
        end
      end)
      |> assign_new(:crawlers_no_index, fn -> Crawlers.no_index_enabled?() end)

    # Handle both inner_content (Phoenix 1.7-) and inner_block (Phoenix 1.8+)
    assigns = normalize_content_assigns(assigns)

    # For admin pages, render simplified layout without parent headers
    if admin_page?(assigns) do
      if get_layout_config() do
        # Parent layout provides the HTML shell (head, assets, CSRF, etc.)
        render_admin_with_parent(assigns)
      else
        # Standalone: full HTML document for PhoenixKit without parent app
        render_admin_only_layout(assigns)
      end
    else
      case get_layout_config() do
        {module, function} when is_atom(module) and is_atom(function) ->
          render_with_parent_layout(assigns, module, function)

        nil ->
          render_with_phoenix_kit_layout(assigns)
      end
    end
  end

  ## Private Implementation

  # Normalize content assigns to handle both inner_content and inner_block
  defp normalize_content_assigns(assigns) do
    if needs_inner_block_conversion?(assigns) do
      convert_inner_content_to_block(assigns)
    else
      assigns
    end
  end

  defp needs_inner_block_conversion?(assigns) do
    has_inner_content?(assigns) and not has_inner_block?(assigns)
  end

  defp has_inner_content?(assigns), do: assigns[:inner_content] != nil

  # Must return a strict boolean: `needs_inner_block_conversion?/1` calls
  # `not has_inner_block?(...)`. When `app_layout` is reached with only an
  # `inner_content` (the legacy Phoenix 1.7 flow) and no `inner_block` key at
  # all, the old `assigns[:inner_block] && ...` short-circuited to `nil`, and
  # `not nil` raised ArgumentError. `not in [nil, []]` normalizes both "absent"
  # (nil) and "declared-but-empty slot" ([]) to `false`.
  defp has_inner_block?(assigns), do: assigns[:inner_block] not in [nil, []]

  defp convert_inner_content_to_block(assigns) do
    inner_content = assigns[:inner_content]
    inner_block = build_synthetic_inner_block(inner_content)
    # Use assign/3 (not Map.put) so `__changed__[:inner_block]` is force-marked.
    # Phoenix only force-marks `:inner_content` on a diff (renderer.ex), so a
    # host layout's `render_slot(@inner_block)` dynamic is guarded by
    # `changed_assign?(__changed__, :inner_block)` — which is false for a bare
    # Map.put — and would emit nil, freezing the page body after first paint on
    # connected updates. Mirrors the admin-nav path's `assign(..., :inner_block)`.
    assign(assigns, :inner_block, inner_block)
  end

  # Synthesize a one-entry slot whose body yields `inner_content`. `inner_content`
  # may be a `%Phoenix.LiveView.Rendered{}` (return it verbatim — it is already
  # renderable; `Phoenix.HTML.raw/1` has no struct clause and would raise
  # FunctionClauseError on it) or a binary from the legacy Phoenix 1.7- flow
  # (mark it safe via `raw/1`).
  defp build_synthetic_inner_block(inner_content) do
    body =
      case inner_content do
        %Phoenix.LiveView.Rendered{} = rendered -> rendered
        other -> Phoenix.HTML.raw(other)
      end

    [%{inner_block: fn _slot_assigns, _index -> body end}]
  end

  # Check if current page is an admin page that needs navigation.
  # Strips URL prefix first, then locale prefix, to handle paths like
  # /phoenix_kit/uk/admin/users where the locale sits between prefix and /admin.
  defp admin_page?(assigns) do
    case assigns[:current_path] do
      nil ->
        false

      path when is_binary(path) ->
        prefix = PhoenixKit.Config.get_url_prefix()

        normalized =
          if prefix == "/", do: path, else: String.replace_prefix(path, prefix, "")

        # Strip locale prefix (e.g., /uk/admin → /admin) for localized admin routes
        normalized = strip_locale_prefix(normalized)

        # Canonicalise the configured admin segment back to `/admin` so this
        # comparison holds on a host that renamed it.
        normalized = Routes.canonical_admin_path(normalized)

        normalized == "/admin" or String.starts_with?(normalized, "/admin/")

      _ ->
        false
    end
  end

  @doc """
  Renders a page's `page_toolbar` — `{Module, :fun}` — with the LiveView's own
  assigns. Called by `layouts/admin.html.heex`, which is the only place that
  holds those assigns; the result goes into the `:toolbar` slot. Renders
  nothing when the page set no toolbar — and nothing, with a logged
  warning, when the pair names no `fun/1`: a page missing its toolbar beats
  the whole admin chrome raising on every render (the same policy
  `nav_tabs` applies to a dead tab).
  """
  @spec render_page_toolbar(map()) :: Phoenix.LiveView.Rendered.t() | nil
  def render_page_toolbar(%{page_toolbar: {mod, fun}} = assigns)
      when is_atom(mod) and is_atom(fun) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 1) do
      TagEngine.component(
        Function.capture(mod, fun, 1),
        assigns,
        {__ENV__.module, __ENV__.function, __ENV__.file, __ENV__.line}
      )
    else
      Logger.warning(
        "[LayoutWrapper] page_toolbar #{inspect(mod)}.#{fun}/1 is not a function component — rendering no toolbar"
      )

      nil
    end
  end

  def render_page_toolbar(_assigns), do: nil

  @doc """
  Styles + pre-paint stamp for the admin sidebar's compact (icon-only) mode.

  Render once, immediately BEFORE the sidebar markup. Everything about compact
  mode lives client-side, and deliberately so:

    * the sidebar is a **function component**, not a LiveView — there is no
      `handle_event/3` owner for a `phx-click`, and giving one to every admin
      page (or bolting a global `attach_hook` onto the admin `on_mount` chain)
      would be a lot of machinery for a display preference;
    * it is a per-browser density choice, exactly like the theme, so it belongs
      in `localStorage` next to it rather than in a settings row;
    * a client-side toggle costs no round trip, and nothing for morphdom to
      fight over — the DOM is identical either way, only `<html>` changes.

  Which makes the first paint the whole problem, and the reason this is a
  synchronous inline `<script>` rather than a hook in `phoenix_kit.js`:

    * it must run **before the sidebar is parsed**, or a viewer who chose
      compact gets a frame of the full-width menu on every load. An inline
      script placed above the markup does exactly that;
    * it must not depend on the host having re-run `mix phoenix_kit.update` to
      refresh its vendored `phoenix_kit.js`. Self-contained markup ships with
      the feature.

  Same reasoning, and the same shape, as
  `PhoenixKitWeb.Components.ThemeBootstrap` — including the one-instance guard,
  since a host layout and the kit's own admin shell can both be on the page.

  The CSS hides the label rather than removing it (`clip-path`, not
  `display: none`), so every link keeps its accessible name and the menu still
  reads correctly to a screen reader while collapsed.
  """
  def admin_sidebar_compact_bootstrap(assigns) do
    ~H"""
    <style data-phoenix-kit-sidebar>
      /* Scoped to lg and up: below it the sidebar is an overlay drawer that is
         already hidden until summoned, so there is nothing to reclaim. */
      @media (min-width: 1024px) {
        html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar { width: 5rem; }
        html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar > div { padding-left: 0; padding-right: 0; }

        /* Visually hidden, NOT display:none — the link keeps its accessible name. */
        html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar-label {
          position: absolute;
          width: 1px;
          height: 1px;
          overflow: hidden;
          white-space: nowrap;
          clip-path: inset(50%);
        }

        /* Centre what is left of each row, and drop the trailing badge column
           so a lone icon is not pushed off-centre by an empty flex sibling. */
        html[data-pk-sidebar="compact"] #pk-admin-sidebar [data-tab-id] > div { justify-content: center; gap: 0; }
        html[data-pk-sidebar="compact"] #pk-admin-sidebar [data-tab-id] { justify-content: center; }

        /* Group headings and subtab lists: a column of indistinguishable
           indented icons is worse than none, so the tree collapses to its
           top level. Expanding brings it straight back — nothing is lost,
           because none of this is server state. */
        html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar-group,
        html[data-pk-sidebar="compact"] #pk-admin-sidebar .subtabs { display: none; }

        html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar-toggle { justify-content: center; }
        html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar-toggle-icon { transform: rotate(180deg); }

      }

      /* ── Flyouts ──────────────────────────────────────────────────────────
         Outside the `min-width: 1024px` block because the script only ever
         opens these when the rail is collapsed, which is already lg-only; an
         unopened popover is `display: none` regardless.

         A shown popover paints in the TOP LAYER, so it does not inherit the
         rail's 5rem width — but it is still a DOM DESCENDANT of the sidebar,
         which is both why the label override below is needed and why it works.

         Every rule here carries the `html[data-pk-sidebar="compact"]` prefix.
         Uniformly, including the two that compete with nothing — it costs
         nothing (a flyout is only ever shown in compact mode) and it lets the
         regression guard in the test suite be a total rule rather than a list
         of exceptions that a future rule could quietly slip past. */
      html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar-flyout {
        position: fixed;
        inset: auto;
        margin: 0;
        min-width: 13rem;
        max-width: 20rem;
        max-height: 80vh;
        overflow-y: auto;
        padding: 0.5rem;
        border: 1px solid var(--color-base-300, #e5e5e5);
        border-radius: 0.5rem;
        background: var(--color-base-100, #fff);
        color: var(--color-base-content, #1f2937);
        box-shadow: 0 10px 25px -5px rgb(0 0 0 / 0.25);
      }

      html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar-flyout-title {
        padding: 0.25rem 0.75rem 0.5rem;
        font-size: 0.75rem;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.05em;
        opacity: 0.6;
      }

      /* The rail hides every `.pk-sidebar-label`, and these are descendants of
         the sidebar — so without this the flyout would be a list of anonymous
         icons, which is the whole thing it exists to prevent.

         ⚠️ The `html[data-pk-sidebar="compact"]` prefix is LOAD-BEARING, not
         decoration. Without it these read (1,2,0) against the rail rules'
         (1,2,1) and lose on specificity, which is exactly the bug that shipped:
         a flyout of anonymous icons. Do not "simplify" the prefix away — the
         media query the rail rules sit in contributes no specificity, so this
         is the only thing separating them. */
      html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar-flyout .pk-sidebar-label {
        position: static;
        width: auto;
        height: auto;
        overflow: visible;
        white-space: normal;
        clip-path: none;
      }

      html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar-flyout [data-tab-id] {
        justify-content: flex-start;
      }

      html[data-pk-sidebar="compact"] #pk-admin-sidebar .pk-sidebar-flyout [data-tab-id] > div {
        justify-content: flex-start;
        gap: 0.75rem;
      }

      /* Where you are, marked on the rail — as an edge bar rather than the
         filled block `tab_classes/5` paints when the menu is expanded. At 5rem
         a solid primary slab is most of the row, which reads as a state
         (selected/disabled) rather than as a marker.

         Two cases, and the rail needs both:
           * `aria-current="page"` — this entry IS the page (a leaf like Users);
           * `data-pk-branch-active` — a descendant is. Expanded, that highlight
             sits on the active SUBTAB, and compact mode hides the subtab list,
             so without this the section you are in shows nothing at all.

         `.tab-with-subtabs > a` is a deliberate direct-child combinator: it
         matches the rail row and never a link inside the flyout, which is a
         DOM descendant of the same sidebar. The flyout is a wide panel with
         text, where the ordinary filled highlight is right. */
      html[data-pk-sidebar="compact"] #pk-admin-sidebar .tab-with-subtabs > a {
        position: relative;
      }

      html[data-pk-sidebar="compact"] #pk-admin-sidebar .tab-with-subtabs > a[aria-current="page"],
      html[data-pk-sidebar="compact"] #pk-admin-sidebar [data-pk-branch-active="true"] > a {
        /* Two declarations, and the order is the point: the first cancels the
           `bg-primary` utility (a plain class, easily outranked) and is what a
           browser without `color-mix` is left holding — which is exactly the
           bar-only rendering that already worked. The second tints where it is
           supported. */
        background-color: transparent;
        background-color: color-mix(in oklab, var(--color-primary) 12%, transparent);
        color: var(--color-base-content);
      }

      /* Deliberately not `--color-base-200`, daisyUI's hover colour: a neutral
         tint at this weight is indistinguishable from hover, so the row would
         stop saying which page you are on the moment the pointer crossed it.
         Tinting with the primary keeps "current" and "hovered" separable, and
         the row still lifts under the pointer. */
      html[data-pk-sidebar="compact"] #pk-admin-sidebar .tab-with-subtabs > a[aria-current="page"]:hover,
      html[data-pk-sidebar="compact"] #pk-admin-sidebar [data-pk-branch-active="true"] > a:hover {
        background-color: color-mix(in oklab, var(--color-primary) 20%, transparent);
      }

      html[data-pk-sidebar="compact"] #pk-admin-sidebar .tab-with-subtabs > a[aria-current="page"]::after,
      html[data-pk-sidebar="compact"] #pk-admin-sidebar [data-pk-branch-active="true"] > a::after {
        content: "";
        position: absolute;
        right: 0;
        top: 0.375rem;
        bottom: 0.375rem;
        width: 3px;
        border-radius: 9999px;
        background-color: var(--color-primary);
      }
    </style>
    <script>
      (function () {
        // One instance per page: a host root layout and the kit's own admin
        // shell can both render this.
        if (window.__pkSidebarCompact) return;
        window.__pkSidebarCompact = true;

        var KEY = "phoenix_kit:admin:sidebar:compact";

        function read() {
          try { return localStorage.getItem(KEY) === "1"; } catch (_e) { return false; }
        }

        function stamp(on) {
          var el = document.documentElement;
          if (on) { el.setAttribute("data-pk-sidebar", "compact"); }
          else { el.removeAttribute("data-pk-sidebar"); closeAll(); }
          syncButton(on);
        }

        // The button's own label has to follow the state it toggles, and the
        // button is re-rendered by every live navigation — so this runs on
        // stamp AND on the LiveView page-load event, not just once.
        function syncButton(on) {
          var btn = document.querySelector("[data-pk-sidebar-toggle]");
          if (!btn) return;
          var label = on ? btn.dataset.pkLabelExpand : btn.dataset.pkLabelCollapse;
          if (!label) return;
          btn.setAttribute("aria-label", label);
          btn.setAttribute("title", label);
          btn.setAttribute("aria-expanded", on ? "false" : "true");
        }

        // Pre-paint: this script sits above the sidebar markup, so the
        // attribute is on <html> before the menu is parsed. No flash.
        stamp(read());

        // Delegated: the sidebar DOM is replaced on every live navigation, so
        // a listener bound to the button itself would need re-binding and
        // cleanup. A document listener survives every patch.
        document.addEventListener("click", function (e) {
          var btn = e.target.closest && e.target.closest("[data-pk-sidebar-toggle]");
          if (!btn) return;
          var next = !read();
          try { localStorage.setItem(KEY, next ? "1" : "0"); } catch (_e) {}
          stamp(next);
        });

        // Re-apply after a live navigation swaps the button back in.
        window.addEventListener("phx:page-loading-stop", function () { syncButton(read()); });

        // Follow the choice into the app's other tabs, as the theme does.
        window.addEventListener("storage", function (e) {
          if (e.key === KEY) stamp(read());
        });

        // ── Flyouts ─────────────────────────────────────────────────────────
        //
        // Collapsed, a row shows an icon and nothing else, so every entry needs
        // somewhere to say its own name — and a section needs somewhere to
        // offer its children, which `subtab_display: :when_active` otherwise
        // renders only for the section you are already in.
        //
        // Every listener is delegated from `document`: the sidebar DOM is
        // replaced on every live navigation, so anything bound per-element
        // would need re-binding and teardown. `mouseover`/`focusin` bubble, and
        // a shown popover is still a DOM descendant of the row it belongs to —
        // the top layer changes painting, not the tree — so one listener covers
        // the trigger and its flyout together.
        var HOVER_IN = 120;   // hover intent: don't flash on a passing cursor
        var HOVER_OUT = 220;  // grace to travel from the icon to the panel
        var openTimer = null;
        var closeTimer = null;

        function compact() {
          return document.documentElement.getAttribute("data-pk-sidebar") === "compact";
        }

        function flyoutFor(node) {
          var row = node && node.closest && node.closest("[data-pk-flyout-id]");
          if (!row) return null;
          return document.getElementById(row.dataset.pkFlyoutId);
        }

        // Popovers paint in the top layer, which means they are positioned
        // against the VIEWPORT — the one thing the old CSS tooltip could not do
        // from inside the sidebar's own scroll container.
        function place(panel, row) {
          var r = row.getBoundingClientRect();
          panel.style.left = Math.round(r.right + 6) + "px";
          panel.style.top = Math.round(r.top) + "px";
          panel.style.bottom = "auto";
          // Clamp: a section near the bottom of a long menu would otherwise
          // open past the fold, where its last items are unreachable.
          var h = panel.offsetHeight;
          if (r.top + h > window.innerHeight - 8) {
            panel.style.top = Math.max(8, window.innerHeight - h - 8) + "px";
          }
        }

        function open(panel, row) {
          if (!panel || !panel.showPopover || panel.matches(":popover-open")) return;
          try {
            panel.showPopover();
          } catch (_e) {
            return;
          }
          place(panel, row);
        }

        function closeAll() {
          var open = document.querySelector(".pk-sidebar-flyout:popover-open");
          if (open && open.hidePopover) {
            try { open.hidePopover(); } catch (_e) {}
          }
        }

        document.addEventListener("mouseover", function (e) {
          if (!compact()) return;
          var row = e.target.closest && e.target.closest("[data-pk-flyout-id]");
          if (!row) return;
          clearTimeout(closeTimer);
          clearTimeout(openTimer);
          var panel = flyoutFor(row);
          if (!panel || panel.matches(":popover-open")) return;
          openTimer = setTimeout(function () { open(panel, row); }, HOVER_IN);
        });

        document.addEventListener("mouseout", function (e) {
          if (!compact()) return;
          if (!e.target.closest || !e.target.closest("[data-pk-flyout-id]")) return;
          // Moving deeper inside the same row (or into its panel) is not a
          // leave — `relatedTarget` is null only when the pointer left the
          // window entirely.
          var to = e.relatedTarget;
          if (to && to.closest && to.closest("[data-pk-flyout-id]") === e.target.closest("[data-pk-flyout-id]")) {
            return;
          }
          clearTimeout(openTimer);
          clearTimeout(closeTimer);
          closeTimer = setTimeout(closeAll, HOVER_OUT);
        });

        // Keyboard: tabbing onto a rail icon names it, and Tab then walks
        // straight into the panel because it sits next to the link in the DOM.
        // Esc and click-away are `popover=auto`'s own behaviour.
        document.addEventListener("focusin", function (e) {
          if (!compact()) return;
          var row = e.target.closest && e.target.closest("[data-pk-flyout-id]");
          if (!row) { closeAll(); return; }
          open(flyoutFor(row), row);
        });

        // Touch: there is no hover, so a tap on a rail icon opens its flyout
        // instead of navigating — otherwise a touch user on a wide screen
        // (a convertible laptop, a tablet in landscape; the rail is lg-only)
        // could never reach a subtab at all. The flyout's own links navigate
        // normally, and a second tap on the icon dismisses it.
        document.addEventListener("click", function (e) {
          if (!compact()) return;
          if (!window.matchMedia || !window.matchMedia("(hover: none)").matches) return;
          var link = e.target.closest && e.target.closest("[data-pk-flyout-id] > a");
          if (!link) return;
          var row = link.closest("[data-pk-flyout-id]");
          var panel = flyoutFor(row);
          if (!panel) return;
          e.preventDefault();
          if (panel.matches(":popover-open")) { closeAll(); } else { open(panel, row); }
        });

        // A live navigation replaces the sidebar under an open panel, and
        // expanding the rail makes flyouts meaningless.
        window.addEventListener("phx:page-loading-start", closeAll);
        window.addEventListener("resize", closeAll);
      })();
    </script>
    """
  end

  # Own function rather than an inline `case` in the assigns map: that map is
  # already at credo's complexity ceiling, and one more branch tipped it.
  #
  # Not `assigns[:show_admin_panel_label] || Settings.get...` the way
  # `project_title` is written — carrying `false` is the entire point of this
  # assign, and `||` would discard exactly the value that means "hide it".
  defp resolve_admin_panel_label(nil) do
    PhoenixKit.Settings.get_boolean_setting("show_admin_panel_label", true)
  end

  defp resolve_admin_panel_label(value), do: value

  # Same shape as `resolve_admin_panel_label/1`, same reason for not using `||`.
  defp resolve_page_descriptions(nil) do
    PhoenixKit.Settings.get_boolean_setting("show_page_descriptions", false)
  end

  defp resolve_page_descriptions(value), do: value

  # `nil` (the default) reads the live heuristic; an explicit `true`/`false`
  # from the caller wins (tests, previews). Same "not `||`" reasoning as
  # `resolve_admin_panel_label/1` — an explicit `false` must not fall through
  # to the automatic read.
  defp resolve_dev_environment(nil), do: WebsiteAccess.environment().looks_like_dev?
  defp resolve_dev_environment(value), do: value

  # The chip's TEXT. Delegates to the shared resolver so the header and the
  # account-menu entry cannot disagree about what the admin area is called;
  # see `PhoenixKitWeb.Components.Core.AdminLabel`.
  #
  # A named function rather than an inline call in `admin_template_assigns/2`:
  # that function sits ON credo's cyclomatic ceiling, as its own comment says.
  defp admin_panel_text, do: AdminLabel.text()

  defp strip_locale_prefix(path) do
    case Regex.run(~r/^\/[a-z]{2,3}(-[A-Za-z]{2,4})?(\/.*)?$/, path) do
      [_, _locale, rest] when is_binary(rest) -> rest
      [_, _locale] -> "/"
      _ -> path
    end
  end

  # Wrap inner_block with admin navigation if needed
  # Extracted so `wrap_inner_block_with_admin_nav_if_needed/1` stays under the
  # complexity ceiling — it is a plain projection of the caller's assigns onto
  # the keys the admin chrome template reads.
  defp admin_template_assigns(assigns, original_inner_block) do
    %{
      # The page toolbar slot (see `slot :toolbar`); `nil` for callers
      # that pass none, compared against `[]` in the render.
      toolbar: List.wrap(assigns[:toolbar]),
      original_inner_block: original_inner_block,
      # Parent LiveView socket — only used to embed the sticky
      # NotificationsBell; nil when the caller didn't thread it
      # through (then the bell simply isn't rendered).
      socket: assigns[:socket],
      # The project title's home link (#852), resolved ONCE per render and
      # read as `@home_path` by both title variants. Called inside the
      # template as `locale_aware_home_path(assigns, @socket)` it probed the
      # router twice per render, and handing `assigns` to a function in HEEx
      # turns change tracking off for the expression.
      home_path: Routes.locale_aware_home_path(assigns, assigns[:socket]),
      phoenix_kit_current_user: assigns[:phoenix_kit_current_user],
      current_path: assigns[:current_path],
      page_title: assigns[:page_title],
      page_subtitle: assigns[:page_subtitle],
      page_section: assigns[:page_section],
      page_section_path: assigns[:page_section_path],
      page_crumbs: assigns[:page_crumbs] || [],
      page_title_switcher: assigns[:page_title_switcher],
      page_action: assigns[:page_action],
      # The slots travel here as ordinary keys; `assigns[:action]` is
      # `nil` for every caller that does not pass one, and the render
      # compares against `[]`.
      action: assigns[:action] || [],
      phoenix_kit_current_scope: assigns[:phoenix_kit_current_scope],
      project_title: assigns[:project_title] || PhoenixKit.Settings.get_project_title(),
      # Operator switch for the "Admin Panel" chip beside the project name.
      # A cache-backed read: this renders on every admin page.
      #
      # SHOW/HIDE, not a title field — deliberately. The wording is
      # `gettext("Admin Panel")`, a common noun phrase already translated in
      # every shipped locale, and a string typed into `/admin/settings` would
      # serve one language's wording to all of them. A DEVELOPER can still
      # override it in `config.exs` (`PhoenixKit.Config.admin_panel_label/0`),
      # where the untranslated-for-everyone tradeoff is visible at the point of
      # the decision rather than buried in an operator form.
      show_admin_panel_label: resolve_admin_panel_label(assigns[:show_admin_panel_label]),
      show_page_descriptions: resolve_page_descriptions(assigns[:show_page_descriptions]),
      # The chip's TEXT — see `admin_panel_text/0`.
      admin_panel_text: admin_panel_text(),
      # The small "[dev]" tag beside the project title — see `resolve_dev_environment/1`.
      dev_environment?: resolve_dev_environment(assigns[:dev_environment]),
      current_locale: assigns[:current_locale],
      current_locale_base:
        assigns[:current_locale] && DialectMapper.extract_base(assigns[:current_locale]),
      scope: assigns[:phoenix_kit_current_scope],
      # Whether this visitor gets a navigation sidebar at all.
      #
      # `Scope.can_access_admin_area?/1` is the gate `:phoenix_kit_ensure_admin`
      # applies before anything else, so failing it means every `/admin`
      # destination redirects — the sidebar would render an empty 16rem column
      # and a burger button opening an empty drawer. `/admin` itself is the
      # guaranteed landing for EVERY authenticated user, so that case is now
      # reachable: a visitor with no permissions gets the welcome page, the
      # header (theme, language, their own account menu, sign-out) and no
      # navigation. `AdminSidebar` applies the same gate to its own entries —
      # this one collapses the chrome around them.
      show_admin_nav: Scope.can_access_admin_area?(assigns[:phoenix_kit_current_scope]),
      # The bell's "View all" footer points at `/admin/notifications`. Reading
      # your own inbox is personal, not administrative — that is exactly what
      # `@personal_admin_views` says — but the page still lives under `/admin`,
      # so the admin-area gate bounces a visitor holding no permission. Ask the
      # destination's own gate rather than re-deriving one.
      can_open_inbox:
        Auth.can_access_admin_view?(
          assigns[:phoenix_kit_current_scope],
          PhoenixKitWeb.Live.Notifications.Inbox
        ),
      phoenix_kit_session_accounts:
        (assigns[:phoenix_kit_current_scope] &&
           assigns[:phoenix_kit_current_scope].multi_session_accounts) || [],
      phoenix_kit_multi_session_allowed?:
        (assigns[:phoenix_kit_current_scope] &&
           assigns[:phoenix_kit_current_scope].multi_session_allowed?) || false,
      auth_logo_url:
        case PhoenixKit.Settings.get_logo_uuid() do
          uuid when is_binary(uuid) and uuid != "" -> URLSigner.signed_url(uuid, "medium")
          _ -> nil
        end
    }
  end

  # A non-admin kit page (profile settings, the user dashboard's pages) inside
  # the HOST's layout has no kit `<body>` to carry `data-phoenix-kit`, and the
  # host's root layout does not render `phoenix_kit_globals`. Mark the kit's
  # own content instead — `display: contents`, so the host's flex/grid sees
  # the children as before — and bring the phone form-control style with it.
  # Admin pages are already marked by `#admin-drawer`. Public for testing.
  @doc false
  def mark_kit_content(assigns) do
    if admin_page?(assigns) or assigns[:inner_block] in [nil, []] do
      assigns
    else
      original_inner_block = assigns[:inner_block]

      assign(assigns, :inner_block, [
        %{
          inner_block: fn _slot_assigns, _index ->
            assigns = %{original_inner_block: original_inner_block}

            ~H"""
            <div data-phoenix-kit class="contents">
              <PhoenixKitWeb.Components.Core.PhoenixKitGlobals.mobile_inputs_style />
              {render_slot(@original_inner_block)}
            </div>
            """
          end
        }
      ])
    end
  end

  defp wrap_inner_block_with_admin_nav_if_needed(assigns) do
    if admin_page?(assigns) do
      # Mark that admin chrome is being rendered by this (LiveView) call.
      # The layout's call (from_layout=true) will detect this and short-circuit.
      # Only set the flag for non-layout calls (core views that call app_layout directly).
      # Plugin views never call app_layout, so the layout's own call should NOT set
      # the flag — otherwise it persists in the process dictionary and causes the
      # layout to incorrectly short-circuit on subsequent LiveView re-renders.
      unless assigns[:from_layout], do: Process.put(:phoenix_kit_admin_chrome_rendered, true)
      # Create new inner_block slot that wraps original content with admin navigation
      original_inner_block = assigns[:inner_block]

      new_inner_block = [
        %{
          inner_block: fn _slot_assigns, _index ->
            # Create template assigns with needed values
            assigns = admin_template_assigns(assigns, original_inner_block)

            ~H"""
            <%!-- PhoenixKit Admin Layout --%>
            <%!-- Globals + favicon needed here for render_admin_with_parent path where parent layout may not set them --%>
            <.phoenix_kit_globals />
            <.phoenix_kit_favicon />
            <style data-phoenix-kit-themes>
              <%= HTML.raw(ThemeConfig.custom_theme_css()) %>
            </style>
            <style>
              /* Custom sidebar control for desktop - override lg:drawer-open grid layout when closed */
              @media (min-width: 1024px) {
                /* Override the grid to collapse sidebar column when closed */
                #admin-drawer.sidebar-closed {
                  grid-template-columns: 0 1fr !important;
                  transition: grid-template-columns 300ms ease-in-out;
                }
                #admin-drawer.sidebar-closed .drawer-side {
                  /* -100%, not -16rem: the drawer-side is wider than the w-64 aside
                     when its scrollbar gutter is reserved — a fixed offset would
                     leave the gutter strip peeking out when closed. */
                  transform: translateX(-100%);
                  transition: transform 300ms ease-in-out;
                  overflow: hidden;
                }
                #admin-drawer:not(.sidebar-closed) {
                  transition: grid-template-columns 300ms ease-in-out;
                }
                #admin-drawer:not(.sidebar-closed).drawer.lg\:drawer-open .drawer-side {
                  transform: translateX(0);
                  transition: transform 300ms ease-in-out;
                }
              }
            </style>
            <%!-- Top Bar Navbar (always visible, spans full width) --%>
            <header class="bg-base-100 shadow-sm border-b border-base-300 fixed top-0 left-0 right-0 z-50">
              <div class="flex items-center justify-between h-16 px-4">
                <%!-- Left: Burger Menu, Logo and Title --%>
                <div class="flex items-center gap-3 min-w-0">
                  <%!-- Burger Menu Button (Far left) --%>
                  <label
                    :if={@show_admin_nav}
                    for="admin-mobile-menu"
                    class="btn btn-square btn-primary drawer-button p-0 lg:hidden"
                  >
                    <PhoenixKitWeb.Components.Core.Icons.icon_menu />
                  </label>

                  <%!-- Logo --%>
                  <%= if @auth_logo_url do %>
                    <img src={@auth_logo_url} alt={@project_title} class="h-8 w-8 object-contain rounded-lg" />
                  <% end %>

                  <%!-- Project title and Admin label grouped together --%>
                  <div class="flex items-center gap-1 min-w-0">
                    <.link
                      href={@home_path}
                      class={[
                        "font-bold text-base-content hover:opacity-80 transition-opacity truncate",
                        (@page_title && "hidden lg:inline") || "hidden sm:inline"
                      ]}
                    >
                      {@project_title}
                    </.link>
                    <%!-- Automatic — not a setting. `resolve_dev_environment/1`
                         reads `WebsiteAccess.environment().looks_like_dev?`
                         (mix env, hostname, site_url heuristics). This tag is
                         now the only thing that says which site you are on:
                         it replaced both the old fixed bottom-of-viewport
                         "This is the development site" bar and the Website
                         access page's environment banner, neither of which
                         anyone had to remember to switch on. --%>
                    <span
                      :if={@dev_environment?}
                      class={[
                        "text-xs font-mono text-warning shrink-0",
                        @page_title && "hidden lg:inline"
                      ]}
                    >
                      [dev]
                    </span>
                    <%!-- Progressive collapse when a page has a title, dropping
                         from the LEFT so the tail of the trail survives: below
                         lg the site name + "Admin Panel" give way to a "…" that
                         still links home (the burger appears at lg too, so this
                         is where width runs out); below sm the section and all
                         but the LAST page_crumb go too, leaving
                         "… / parent / page".

                         Dropped entirely for a visitor with no admin rights.
                         `/admin` is the landing EVERY authenticated user can
                         reach, so this shell now renders for people who are not
                         operators — and telling someone with no sidebar, no
                         subtitle and no operator content that they are in the
                         "Admin Panel" is the one claim on the page that would
                         be false. What remains is the ordinary breadcrumb the
                         markup already builds: project title / page title.
                         Omission rather than a replacement label, because a new
                         msgid would ship untranslated in every shipped locale
                         while this reuses strings that are already there.
                         `show_admin_nav` is the same gate the sidebar and the
                         burger button use, so an operator's header is
                         byte-identical to before. --%>
                    <span
                      :if={@show_admin_nav and @show_admin_panel_label}
                      class={[
                        "font-bold text-base-content shrink-0",
                        @page_title && "hidden lg:inline"
                      ]}
                    >
                      {@admin_panel_text}
                    </span>
                    <.link
                      :if={@page_title}
                      href={@home_path}
                      title={@project_title}
                      class="lg:hidden font-bold text-base-content/50 hover:text-base-content transition-opacity shrink-0"
                    >
                      …
                    </.link>
                    <%!-- Current page breadcrumb: " / Page Title · subtitle".
                         Pushed in via page_title / page_subtitle so pages can
                         drop their own in-content header and reclaim the space. --%>
                    <span :if={@page_title} class="flex items-center gap-1.5 min-w-0">
                      <span class="text-base-content/30 shrink-0">/</span>
                      <span
                        :if={@page_section}
                        class="hidden sm:flex items-center gap-1.5 shrink-0"
                      >
                        <.link
                          :if={@page_section_path}
                          navigate={@page_section_path}
                          class="font-semibold text-base-content/60 hover:text-base-content transition-opacity"
                        >
                          {@page_section}
                        </.link>
                        <span :if={!@page_section_path} class="font-semibold text-base-content/60">
                          {@page_section}
                        </span>
                        <span class="text-base-content/30">/</span>
                      </span>
                      <%!-- Deeper crumbs (page_crumbs): between the section and
                           the page title, for drill-down pages. The LAST crumb
                           (the page's parent) stays visible below sm — the
                           trail truncates from the left, not all at once.
                           `patch` is same-LiveView; `path` is navigate. --%>
                      <span
                        :for={{crumb, idx} <- Enum.with_index(@page_crumbs)}
                        class={[
                          "items-center gap-1.5 min-w-0",
                          if(idx == length(@page_crumbs) - 1,
                            do: "flex",
                            else: "hidden sm:flex shrink-0"
                          )
                        ]}
                      >
                        <.link
                          :if={crumb[:patch]}
                          patch={crumb[:patch]}
                          class="font-semibold text-base-content/60 hover:text-base-content transition-opacity truncate"
                        >
                          {crumb.label}
                        </.link>
                        <.link
                          :if={is_nil(crumb[:patch]) and crumb[:path]}
                          navigate={crumb[:path]}
                          class="font-semibold text-base-content/60 hover:text-base-content transition-opacity truncate"
                        >
                          {crumb.label}
                        </.link>
                        <span
                          :if={is_nil(crumb[:patch]) and is_nil(crumb[:path])}
                          class="font-semibold text-base-content/60 truncate"
                        >
                          {crumb.label}
                        </span>
                        <.crumb_switcher
                          :if={crumb[:switcher]}
                          id={"pk-crumb-switcher-#{idx}"}
                          switcher={crumb.switcher}
                        />
                        <span class="text-base-content/30">/</span>
                      </span>
                      <span class="font-semibold text-base-content truncate min-w-0">{@page_title}</span>
                      <.crumb_switcher
                        :if={@page_title_switcher}
                        id="pk-title-switcher"
                        switcher={@page_title_switcher}
                      />
                      <span
                        :if={@page_subtitle && @show_page_descriptions}
                        class="text-sm text-base-content/50 truncate hidden md:inline"
                      >
                        {@page_subtitle}
                      </span>
                      <%!-- The page toolbar: identity controls (a status
                            picker, the ⋮ menu) that would otherwise float in
                            the page body under a title the bar already shows.
                            Rendered as given — the page owns the controls. --%>
                      <span :if={@toolbar != []} class="flex items-center gap-1.5 shrink-0">
                        {render_slot(@toolbar)}
                      </span>
                      <%!-- Slot wins when given; the map is the shorthand for
                            the navigate-only case and the only thing plugin
                            LiveViews can reach. Same chip shell either way —
                            this is the one *create* chip; identity controls
                            go in the toolbar above. --%>
                      <span
                        :if={@action != []}
                        class="[&>*]:btn [&>*]:btn-xs [&>*]:btn-primary [&>*]:btn-circle [&>*]:shrink-0"
                      >
                        {render_slot(@action)}
                      </span>
                      <.link
                        :if={@action == [] and @page_action}
                        navigate={@page_action[:navigate]}
                        class={[
                          "btn btn-xs btn-primary shrink-0",
                          if(@page_action[:show_label],
                            do: "max-sm:btn-circle sm:gap-1",
                            else: "btn-circle"
                          )
                        ]}
                        title={@page_action[:label]}
                        aria-label={@page_action[:label]}
                      >
                        <PhoenixKitWeb.Components.Core.Icon.icon
                          name={@page_action[:icon] || "hero-plus"}
                          class="w-4 h-4"
                        />
                        <span :if={@page_action[:show_label]} class="hidden sm:inline">
                          {@page_action[:label]}
                        </span>
                      </.link>
                    </span>
                  </div>
                </div>

                <%!-- Right: Website-access badges, Theme Switcher, Notifications bell, User Dropdown --%>
                <div class="flex items-center gap-3">
                  <PhoenixKitWeb.Components.Core.WebsiteAccessBadges.website_access_badges current_locale={
                    assigns[:current_locale_base]
                  } />
                  <.admin_theme_controller mobile={true} />
                  <%!-- Notifications bell — a sticky nested LiveView, shown only
                       when the socket is threaded through, the module is enabled,
                       and there's a logged-in user. Sticky + a stable id so the
                       bell keeps its PubSub subscription across admin navigation. --%>
                  <% bell_user =
                    assigns[:phoenix_kit_current_user] ||
                      (assigns[:phoenix_kit_current_scope] &&
                         assigns[:phoenix_kit_current_scope].user) %>
                  <%= if @socket && bell_user && PhoenixKit.Notifications.enabled?() do %>
                    {Phoenix.Component.live_render(@socket, PhoenixKitWeb.Live.NotificationsBell,
                      id: "pk-notifications-bell",
                      sticky: true,
                      session: %{
                        "user_uuid" => bell_user.uuid,
                        "locale" => assigns[:current_locale_base],
                        "can_open_inbox" => @can_open_inbox
                      }
                    )}
                  <% end %>
                  <%!-- Role switcher, when `role_switcher_location` is
                       "header" (from `sm` up; the account menu carries it on
                       phones). Renders nothing otherwise. --%>
                  <PhoenixKitWeb.Components.Core.RoleSwitcher.role_switcher
                    variant={:header}
                    id="admin-role-switcher-header"
                    scope={@phoenix_kit_current_scope}
                    current_path={@current_path}
                    current_locale={@current_locale}
                  />
                  <.admin_user_dropdown
                    scope={@phoenix_kit_current_scope}
                    current_path={@current_path}
                    current_locale={@current_locale}
                    accounts={@phoenix_kit_session_accounts}
                    multi_session_allowed?={@phoenix_kit_multi_session_allowed?}
                  />
                </div>
              </div>
            </header>

            <%!-- Without `lg:drawer-open` AND without a `.drawer-side` child,
                  daisyUI's `grid-auto-columns: max-content auto` leaves column
                  one empty, so `.drawer-content` (grid-column-start: 2) spans
                  the full width. --%>
            <div id="admin-drawer" class={["drawer", @show_admin_nav && "lg:drawer-open"]}>
              <input id="admin-mobile-menu" type="checkbox" class="drawer-toggle" />

              <%!-- Main content --%>
              <div class="drawer-content flex min-h-screen flex-col bg-base-100 transition-colors pt-16">
                <%!-- Page content from parent layout --%>
                <div class="flex-1">
                  {render_slot(@original_inner_block)}
                </div>

                <%!-- Where the collapse scroll keeper (phoenix_kit.js) parks the
                     height it holds when a section closes near the page bottom.
                     It belongs INSIDE the content column: the sidebar is a
                     sticky grid item, so it only extends into the held space if
                     the grid row grows — padding the document below <main>
                     instead leaves the sidebar and the page background cut off
                     at the old bottom edge. Server-rendered so morphdom keeps
                     it, with `style` handed to the client so the height it sets
                     survives patches. --%>
                <div
                  id="pk-collapse-pad"
                  data-pk-collapse-pad
                  aria-hidden="true"
                  class="shrink-0"
                  phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["style"])}
                >
                </div>
              </div>

              <%!-- Desktop/Mobile Sidebar. lg:[scrollbar-gutter:stable]: the sidebar is
                   its own scroll container (the menu outgrows the viewport), and the
                   drawer grid auto-sizes this column — without a reserved gutter its
                   width flips ±15px (classic scrollbars) when a modal's page scroll
                   lock changes ambient scroll state, shifting the whole content pane.
                   Scoped to lg (the drawer-open column mode); the mobile overlay
                   drawer needs no gutter. --%>
              <%!-- id + hook: AdminSidebarScroll keeps the menu's scroll
                   position across navigations (a live redirect replaces
                   this whole container; cross-live_session navigation is
                   a full reload). The hook restores pre-paint; the save
                   side lives in phoenix_kit.js as document-level
                   listeners so no per-element cleanup is needed. --%>
              <PhoenixKitWeb.Components.LayoutWrapper.admin_sidebar_compact_bootstrap :if={@show_admin_nav} />
              <div
                :if={@show_admin_nav}
                id="pk-admin-sidebar"
                phx-hook="AdminSidebarScroll"
                class="drawer-side lg:[scrollbar-gutter:stable]"
              >
                <label for="admin-mobile-menu" class="drawer-overlay lg:hidden"></label>
                <aside class="pk-sidebar min-h-full w-64 bg-base-100 shadow-lg border-r border-base-300 flex flex-col pt-16">
                  <%!-- Navigation (fills available space) --%>
                  <div class="px-4 py-6 flex-1">
                    <.admin_sidebar
                      current_path={@current_path || ""}
                      scope={@scope}
                      locale={@current_locale_base}
                    />
                  </div>

                  <%!-- Compact toggle. Desktop only: the mobile sidebar is an
                       overlay drawer that is already absent until summoned, so
                       narrowing it buys nothing and costs the labels. --%>
                  <div class="hidden lg:block border-t border-base-300 px-4 py-3">
                    <button
                      type="button"
                      data-pk-sidebar-toggle
                      class="pk-sidebar-toggle btn btn-ghost btn-sm w-full justify-start gap-3"
                      aria-controls="pk-admin-sidebar"
                      aria-label={gettext("Collapse the menu to icons")}
                      title={gettext("Collapse the menu to icons")}
                      data-pk-label-expand={gettext("Expand the menu")}
                      data-pk-label-collapse={gettext("Collapse the menu to icons")}
                    >
                      <PhoenixKitWeb.Components.Core.Icon.icon
                        name="hero-chevron-double-left"
                        class="pk-sidebar-toggle-icon w-5 h-5"
                      />
                      <span class="pk-sidebar-label">{gettext("Collapse")}</span>
                    </button>
                  </div>
                </aside>
              </div>
            </div>

            <%!-- Auto-close mobile drawer on navigation --%>
            <script>
              // Mobile drawer and burger menu navigation
              document.addEventListener('DOMContentLoaded', function() {
                const drawerToggle = document.getElementById('admin-mobile-menu');
                const adminDrawer = document.getElementById('admin-drawer');
                const burgerMenuButton = document.querySelector('label[for="admin-mobile-menu"]');

                // Close mobile drawer on navigation
                const mainNavLinks = document.querySelectorAll('.drawer-side a');

                mainNavLinks.forEach(link => {
                  link.addEventListener('click', () => {
                    if (drawerToggle && window.innerWidth < 1024) {
                      drawerToggle.checked = false;
                    }
                  });
                });

                // Handle burger menu toggle for desktop
                if (burgerMenuButton && adminDrawer) {
                  burgerMenuButton.addEventListener('click', () => {
                    // On desktop (>= 1024px), toggle the sidebar-closed class
                    if (window.innerWidth >= 1024) {
                      adminDrawer.classList.toggle('sidebar-closed');
                    }
                    // On mobile, default checkbox behavior handles it
                  });
                }
              });
            </script>
            <%!-- Shared theme controller (dropdown a11y, pair toggle,
                 indicators, host dispatch) — the near-copy that lived here
                 moved to one generated script serving every layout. --%>
            <PhoenixKitWeb.Components.ThemeControllerScript.theme_controller_script />
            """
          end
        }
      ]

      # Return assigns with new inner_block
      assign(assigns, :inner_block, new_inner_block)
    else
      # Not an admin page, return assigns unchanged
      assigns
    end
  end

  # Render with parent application layout (Phoenix v1.8+ function component approach)
  defp render_with_parent_layout(assigns, module, function) do
    # Prepare assigns for parent layout compatibility
    assigns = prepare_parent_layout_assigns(assigns)

    # Dynamically call the parent layout function based on Phoenix version
    case PhoenixVersion.get_strategy() do
      :modern ->
        render_modern_parent_layout(assigns, module, function)

      :legacy ->
        render_legacy_parent_layout(assigns, module, function)
    end
  end

  # Phoenix v1.8+ approach - function components
  defp render_modern_parent_layout(assigns, module, function) do
    # Wrap inner content with admin navigation if needed
    assigns = assigns |> wrap_inner_block_with_admin_nav_if_needed() |> mark_kit_content()

    # `app_layout` is the single owner of the host layout (the native `:layout`
    # is a passthrough — see `PhoenixKitWeb.__using__(:live_view)`), so this is
    # the one place the host layout is applied.
    apply_host_layout(assigns, module, function)
  end

  # Apply the configured host layout, giving it BOTH inner conventions so it
  # works whether it renders `{@inner_content}` (the documented contract) or
  # `render_slot(@inner_block)` (the Phoenix 1.8 idiom). `app_layout` is invoked
  # with an `inner_block` slot; `ensure_inner_content_from_block/1` derives a
  # lazy `@inner_content` from it when absent. Rescues a bad
  # `config :phoenix_kit, layout:` (renamed/removed function) to PhoenixKit's own
  # layout instead of 500-ing every page. Public for regression testing.
  @doc false
  def apply_host_layout(assigns, module, function) do
    assigns
    |> ensure_inner_content_from_block()
    |> then(&apply(module, function, [&1]))
  rescue
    UndefinedFunctionError ->
      render_with_phoenix_kit_layout(assigns)
  end

  # Derive `@inner_content` from the `inner_block` slot when the caller only
  # supplied a slot. Kept lazy (a `%Rendered{}`) so a host layout using
  # `{@inner_content}` still change-tracks correctly on connected updates.
  defp ensure_inner_content_from_block(assigns) do
    if has_inner_content?(assigns) do
      assigns
    else
      assign(assigns, :inner_content, render_inner_block(assigns))
    end
  end

  defp render_inner_block(assigns) do
    ~H"{render_slot(@inner_block)}"
  end

  # Phoenix v1.7- approach - templates (legacy support)
  defp render_legacy_parent_layout(assigns, _module, _function) do
    # For legacy Phoenix, layouts are handled at router level
    # Wrap inner content with admin navigation if needed
    assigns = assigns |> wrap_inner_block_with_admin_nav_if_needed() |> mark_kit_content()

    # Just render content without wrapper - layout comes from router
    ~H"""
    {render_slot(@inner_block)}
    """
  end

  # Render admin pages when a parent layout provides the HTML shell.
  # Content only — root layout (from put_root_layout) supplies head, assets, CSRF, etc.
  defp render_admin_with_parent(assigns) do
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    ~H"""
    <main class="min-h-screen bg-base-100 transition-colors">
      <.flash_group flash={@flash} />
      <.library_load_notice scope={assigns[:phoenix_kit_current_scope]} />
      <.timezone_detector
        scope={assigns[:phoenix_kit_current_scope]}
        handler_attached={assigns[:phoenix_kit_timezone_hook_attached?] == true}
      />
      <.invitation_banners invitations={@pk_pending_invitations} />
      {render_slot(@inner_block)}
    </main>
    """
  end

  # Render admin pages with simplified layout (no parent headers)
  defp render_admin_only_layout(assigns) do
    # Wrap inner content with admin navigation
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    ~H"""
    <!DOCTYPE html>
    <html
      lang={@content_language || "en"}
      data-theme="light"
      class="[scrollbar-gutter:stable]"
    >
      <head>
        <%!-- Pre-paint: the standalone admin used to hardcode light and fix
             it up on DOMContentLoaded — a guaranteed flash for dark users. --%>
        <PhoenixKitWeb.Components.ThemeBootstrap.theme_bootstrap />
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <% default_tab = PhoenixKit.Settings.get_setting_cached("default_tab_title", "") %>
        <.live_title default={
          if(default_tab != "",
            do: default_tab,
            else: "#{assigns[:project_title] || PhoenixKit.Settings.get_project_title()} Admin"
          )
        }>
          {assigns[:page_title] || "Admin"}
        </.live_title>
        <.phoenix_kit_favicon />
        <PhoenixKitWeb.Components.Core.CrawlerMetas.crawler_metas />
        <link phx-track-static rel="stylesheet" href="/assets/css/app.css" />
        <%!-- PhoenixKit Cookie Consent Widget Setup --%>
        <.phoenix_kit_globals />
        <%= if Code.ensure_loaded?(PhoenixKit.Modules.Legal) do %>
          <script defer src={Routes.path("/assets/phoenix_kit_consent.js")}>
          </script>
        <% end %>
      </head>
      <body class="bg-base-100 antialiased transition-colors" data-phoenix-kit>
        <%!-- Admin pages without parent headers --%>
        <main class="min-h-screen bg-base-100 transition-colors">
          <.flash_group flash={@flash} />
          <.library_load_notice scope={assigns[:phoenix_kit_current_scope]} />
          <.timezone_detector
            scope={assigns[:phoenix_kit_current_scope]}
            handler_attached={assigns[:phoenix_kit_timezone_hook_attached?] == true}
          />
          <.invitation_banners invitations={@pk_pending_invitations} />
          {render_slot(@inner_block)}
        </main>

        <%!-- Cookie Consent Widget --%>
        <%= if Code.ensure_loaded?(PhoenixKit.Modules.Legal) and
               PhoenixKit.Modules.Legal.consent_widget_enabled?() do %>
          <% config = PhoenixKit.Modules.Legal.get_consent_widget_config() %>
          <PhoenixKit.Modules.Legal.CookieConsent.cookie_consent
            frameworks={config.frameworks}
            consent_mode={config.consent_mode}
            icon_position={config.icon_position}
            policy_version={config.policy_version}
            cookie_policy_url={config.cookie_policy_url}
            privacy_policy_url={config.privacy_policy_url}
            legal_links={config.legal_links}
            legal_index_url={config.legal_index_url}
            google_consent_mode={config.google_consent_mode}
          />
        <% end %>
      </body>
    </html>
    """
  end

  # Standalone fallback (no `config :phoenix_kit, layout:` — core's own
  # dev/test, or a minimal host): render content only. The document shell
  # already comes from the router's `put_root_layout` (Layouts.root), so
  # rendering `<PhoenixKitWeb.Layouts.root>` here nested a SECOND full
  # document inside the LiveView — and, worse, the spread carried
  # `app_layout`'s `attr :inner_content, default: nil` into a template that
  # renders `{@inner_content}`, so the actual page content was swallowed
  # entirely (empty login/register pages in standalone mode). The flash
  # group must render HERE, inside the LiveView's tree — the root layout's
  # copy is static after the dead render, so connected `put_flash` updates
  # would never display through it.
  @doc """
  Rendering path for auth pages (login, register, reset, confirm, magic link,
  QR handoff, and the invite-only referral screen).

  Auth pages **do not** render inside the host's `Layouts.app`. That layout is
  where a `mix phx.new` app keeps its logo, framework version and off-site
  links, so wrapping sign-in in it put Phoenix Framework branding on the login
  page of every kit install — reported by more than one host. Admin already
  works this way (`render_admin_with_parent/1` never calls the host's `:app`);
  auth was the outlier.

  The host's **root** layout still applies, because `PhoenixKitWeb.Integration`
  never calls `put_root_layout`. That is where the document shell, assets and
  CSRF come from, and it is unaffected.

  A host that genuinely wants its own chrome on sign-in opts back in:

      config :phoenix_kit, auth_uses_host_layout: true

  ⚠️ Two things a host may notice when it does not: anything wired into the
  **app** layout rather than root — a cookie-consent banner, analytics, a theme
  toggle — stops appearing on auth pages only. Root-level wiring is unaffected.
  Stock `phx.new` puts assets and CSRF in root, so conventional hosts see only
  the branding disappear, which is the point.
  """
  attr :flash, :map, required: true
  attr :phoenix_kit_current_scope, :any, default: nil
  attr :page_title, :string, default: nil
  attr :current_path, :string, default: nil
  attr :pk_pending_invitations, :list, default: []
  slot :inner_block, required: true

  def auth_layout(assigns) do
    if auth_uses_host_layout?() do
      ~H"""
      <.app_layout
        flash={@flash}
        phoenix_kit_current_scope={@phoenix_kit_current_scope}
        page_title={@page_title}
        current_path={@current_path}
      >
        {render_slot(@inner_block)}
      </.app_layout>
      """
    else
      # `min-h-dvh` here so the auth background has a definite containing block
      # to fill: the wrapper inside uses `min-h-full`, which is a percentage and
      # therefore cannot overflow it. `dvh` rather than `vh` because on mobile
      # `vh` is the LARGE viewport, which puts the bottom of the card behind the
      # URL bar.
      #
      # Flash renders HERE, inside the LiveView tree — a copy in the root layout
      # freezes at its dead-render value (see `render_with_phoenix_kit_layout/1`).
      ~H"""
      <.flash_group flash={@flash} />
      <.library_load_notice scope={assigns[:phoenix_kit_current_scope]} />
      <.timezone_detector
        scope={assigns[:phoenix_kit_current_scope]}
        handler_attached={assigns[:phoenix_kit_timezone_hook_attached?] == true}
      />
      <.invitation_banners invitations={@pk_pending_invitations} />
      <div class="min-h-dvh">{render_slot(@inner_block)}</div>
      """
    end
  end

  @doc false
  # Mounts the browser timezone detector on every authenticated page.
  #
  # Renders an empty div whose only job is to carry `phx-hook`. It reports the
  # browser's IANA zone to the LiveView, where the handle_event hook attached in
  # `PhoenixKitWeb.Users.Auth` compares it against the account and notifies once
  # if they disagree. Living in the layout rather than on the profile page is
  # what lets a change of location be noticed on whatever page someone happens
  # to open, instead of only when they go looking in settings.
  #
  # Nothing renders for a signed-out visitor: there is no account to contradict.
  #
  # `handler_attached` is the important guard. The element only exists where the
  # LiveView has the matching `handle_event` hook, which
  # `PhoenixKitWeb.Users.Auth` attaches on the shared authenticated mount path.
  # A scope can be assigned WITHOUT going through it — `assign_embedded_current_user/2`
  # does exactly that for a host embedding an admin LiveView, where the on_mount
  # gate deliberately does not run. Rendering the hook there would push an event
  # nothing handles and take the host's LiveView down with a
  # no-function-clause error. Gating on the flag the attachment itself sets
  # means the DOM node cannot outlive its handler.
  attr :scope, :any, default: nil
  attr :handler_attached, :boolean, default: false

  def timezone_detector(assigns) do
    ~H"""
    <div
      :if={@handler_attached && @scope && PhoenixKit.Users.Auth.Scope.authenticated?(@scope)}
      id="phoenix-kit-timezone-detector"
      phx-hook="TimezoneDetector"
      hidden
    >
    </div>
    """
  end

  defp auth_uses_host_layout? do
    PhoenixKit.Config.get_boolean(:auth_uses_host_layout, false)
  end

  defp render_with_phoenix_kit_layout(assigns) do
    # Wrap inner content with admin navigation if needed
    assigns = wrap_inner_block_with_admin_nav_if_needed(assigns)

    ~H"""
    <.flash_group flash={@flash} />
    <.library_load_notice scope={assigns[:phoenix_kit_current_scope]} />
    <.timezone_detector
      scope={assigns[:phoenix_kit_current_scope]}
      handler_attached={assigns[:phoenix_kit_timezone_hook_attached?] == true}
    />
    <.invitation_banners invitations={@pk_pending_invitations} />
    {render_slot(@inner_block)}
    """
  end

  # Prepare assigns for parent layout compatibility
  @doc false
  def prepare_parent_layout_assigns(assigns) do
    # Flatten `:module_assigns` into the top-level assigns map FIRST so that
    # host layouts can read module-supplied keys directly (e.g.
    # `assigns[:phoenix_kit_publishing_translations]`). Existing top-level
    # keys win over module-supplied ones to prevent a module from
    # overwriting core-managed assigns like `:flash` or `:current_user`.
    module_assigns = assigns[:module_assigns] || %{}

    assigns =
      Enum.reduce(module_assigns, assigns, fn {key, value}, acc ->
        Map.put_new(acc, key, value)
      end)

    assigns
    |> Map.put_new(:current_user, get_current_user_for_parent(assigns))
    |> maybe_put_anonymous_scope()
    |> Map.put_new(:phoenix_kit_integrated, true)
    |> Map.put_new(:phoenix_kit_version, get_phoenix_kit_version())
    |> Map.put_new(:phoenix_version_info, PhoenixVersion.get_version_info())
    |> Map.put_new(:crawlers_no_index, assigns[:crawlers_no_index] || false)
  end

  # A host layout written for Phoenix 1.8 reads `@current_scope`, which the
  # kit's pages never set — so on the login and registration pages (no user)
  # it got nil and every such layout needed a nil guard. A host can name a
  # function returning its own anonymous scope:
  #
  #     config :phoenix_kit, host_anonymous_scope: {MyApp.Accounts.Scope, :anonymous, []}
  #
  # It is given to the layout when nobody is signed in, and is the host's own
  # struct: display only — the kit never uses it for an access decision.
  # Unset (the default) leaves `current_scope` absent, as before.
  #
  # The host's function runs only when the layout has no scope yet, and a
  # function that raises leaves the key absent (on the record) rather than
  # taking the login and registration pages down with it.
  defp maybe_put_anonymous_scope(%{current_user: nil} = assigns) do
    if Map.has_key?(assigns, :current_scope) do
      assigns
    else
      case host_anonymous_scope() do
        {:ok, scope} -> Map.put(assigns, :current_scope, scope)
        :none -> assigns
      end
    end
  end

  defp maybe_put_anonymous_scope(assigns), do: assigns

  defp host_anonymous_scope do
    case Application.get_env(:phoenix_kit, :host_anonymous_scope) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {:ok, apply(mod, fun, args)}

      fun when is_function(fun, 0) ->
        {:ok, fun.()}

      _ ->
        :none
    end
  rescue
    error ->
      Logger.warning(
        "[LayoutWrapper] host_anonymous_scope failed, rendering without a scope: " <>
          Exception.message(error)
      )

      :none
  end

  # Extract current user from scope for parent layout compatibility
  defp get_current_user_for_parent(assigns) do
    case assigns[:phoenix_kit_current_scope] do
      nil -> assigns[:phoenix_kit_current_user]
      scope -> Scope.user(scope)
    end
  end

  # Get layout configuration from PhoenixKit.Config with Phoenix version compatibility
  defp get_layout_config do
    case Config.get(:phoenix_version_strategy, nil) do
      :modern ->
        # Phoenix v1.8+ - respect explicit layout: config first, then fall back
        # to {layouts_module, :app}. The layout: config allows parent apps to
        # specify a different layout function (e.g., :full_width instead of :app).
        case Config.get(:layout, nil) do
          {module, function} when is_atom(module) and is_atom(function) ->
            {module, function}

          _ ->
            case Config.get(:layouts_module, nil) do
              nil -> nil
              module -> {module, :app}
            end
        end

      :legacy ->
        # Phoenix v1.7- - use legacy layout config
        Config.get(:layout, nil)

      nil ->
        # Fallback - check for legacy layout config first
        Config.get(:layout, nil)
    end
  end

  # Get PhoenixKit version
  defp get_phoenix_kit_version do
    case Application.spec(:phoenix_kit) do
      nil ->
        "unknown"

      spec ->
        spec
        |> Keyword.get(:vsn, "unknown")
        |> to_string()
    end
  end

  # Used in HEEX template - compiler cannot detect usage
  def get_language_flag(code) when is_binary(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      nil -> "🌐"
    end
  end
end
