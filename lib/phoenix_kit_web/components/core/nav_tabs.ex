defmodule PhoenixKitWeb.Components.Core.NavTabs do
  @moduledoc """
  Universal tab component for PhoenixKit.

  Supports two modes with identical visual appearance:

  **Navigation tabs** — each tab carries a URL, renders as `<.link>`:

      <.nav_tabs active_tab="general" tabs={[
        %{id: "general", label: "General", icon: "hero-cog-6-tooth", navigate: Routes.path("/admin/settings")},
        %{id: "advanced", label: "Advanced", navigate: Routes.path("/admin/settings/advanced")}
      ]} />

  **Event tabs** — no URL, uses `on_change` via `phx-click`:

      <.nav_tabs active_tab={@active_tab} on_change="switch_tab" tabs={[
        %{id: "oban", label: "Oban Jobs"},
        %{id: "scheduler", label: "Scheduler"}
      ]} />

  **With badges** (works in both modes):

      <.nav_tabs active_tab={@tab} tabs={[
        %{id: "followers", label: "Followers", patch: Routes.path("/connections?tab=followers"), badge: @followers_count},
        %{id: "following", label: "Following", patch: Routes.path("/connections?tab=following"), badge: @following_count}
      ]} />

  ## Tab map keys

  Required: `:id`, `:label`

  Optional: `:icon` (Heroicon name), `:badge` (count/text), `:badge_class`
  (a daisyUI tone such as `"badge-warning"`, which wins over the active-tab
  default), and at most one link key — `:navigate`, `:patch`, or `:path`.

  Every optional key treats `nil` as absent, so the common
  `badge: if(count > 0, do: count)` renders no badge rather than an empty one.

  The link keys mirror `Phoenix.Component.link/1` rather than inventing a
  parallel vocabulary: `:navigate` for a full LiveView navigation, `:patch`
  to stay in the current LiveView (query-param tabs want this — a `:navigate`
  there remounts and loses socket state). Both pass through VERBATIM, again
  like `link/1` — build them with your module's Paths helpers (or
  `Routes.path/1` yourself). `:path` is the legacy
  spelling: the same link KIND as `:navigate`, but with different prefix
  rules — it is the one key the component still runs through
  `Routes.path/1`, because its callers predate the link keys and have
  always passed unprefixed paths. The two are NOT interchangeable: swapping
  `path:` for `navigate:` while keeping an unprefixed value under-prefixes,
  and the reverse double-prefixes. Setting more than one link key raises; a key whose
  value is `nil` counts as absent, so a conditional path is safe.

  A tab with no link key renders as a button and needs `on_change`; without
  it the tab is inert and the component logs a warning rather than raising —
  a dead tab should not take a whole LiveView down. A strip may freely mix
  link tabs and event tabs.

  ## Event payload

  Event tabs dispatch `phx-value-tab`, so handlers match on:

      def handle_event("switch_tab", %{"tab" => id}, socket)

  The key is deliberately not configurable, and deliberately not `value`:
  LiveView's `extractMeta` overwrites `meta.value` with the element's own
  `.value` DOM property, so a `<button>` (whose `.value` is `""`) silently
  delivers an empty string unless a native `value=` attribute is also set.
  Standardising on `tab` removes the trap rather than making it selectable.

  ## Variants

  `variant={:boxed}` (default) is the filled strip used across admin pages.
  `variant={:plain}` drops the frame for tabs that sit inside an
  already-framed container — a filter row inside a picker, say.
  `variant={:border}` is daisyUI's underline look, the convention on
  show-page and settings tab strips.

  It exists because `class` can only ADD to the container: with the frame
  baked in, a caller had no way to take it off, and hand-rolling the markup
  was the only escape. That is how the copies started.

  ## Overflow

  By default (`overflow={:wrap}`) tabs that do not fit wrap onto further rows,
  exactly as daisyUI lays them out. On a phone that turns a long strip into a
  stack of rows; `overflow={:menu}` keeps it to ONE row instead:

      <.nav_tabs active_tab={@tab} overflow={:menu} class="tabs-sm" tabs={@tabs}>
        <:trailing><span class="text-xs">{@count} items</span></:trailing>
      </.nav_tabs>

  Tabs that do not fit leave the strip and are listed, in order, in a dropdown
  behind a trailing "⋯" button. A menu item behaves exactly like its tab: the
  same `navigate`/`patch`/`href` link, or the same `phx-click`/`phx-target`/
  `phx-value-tab` button. The server renders both the strip tab and the menu
  item for every tab; the `NavTabsOverflow` hook (`phoenix_kit.js`) measures and
  toggles which of each pair is visible. Before the hook mounts the strip looks
  like the default one and the "⋯" button is hidden.

    * The active tab always stays in the strip: earlier tabs make room for it,
      and when it is wider than the strip on its own its label is truncated.
    * "⋯" shows only while at least one tab is hidden.
    * The menu opens on tap/click and closes on an outside tap, Escape,
      choosing an item, or LiveView navigation. Items are 44px touch targets.
    * The menu is positioned inside the component (not portaled), so an ancestor
      with `overflow: hidden` that clips the strip would clip it as well.

  Works with every variant, with `tabs-sm` etc. passed through `class`, and with
  the `trailing` slot (the "⋯" button sits before it). The hook needs a DOM id:
  pass `id` when a page renders two strips with the same tab ids; otherwise one
  is derived from the tab ids.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Utils.Routes

  @doc """
  The daisyUI class list for a tablist container.

  Exposed so anything rendering tab-styled markup that is NOT a tab strip
  (segmented form controls, for instance) can share one definition instead
  of repeating the class string. A daisyUI rename should be a change here,
  not a sweep across every call site — `tabs-boxed` became `tabs-box` in
  daisyUI 5 and had to be fixed in 21 places across 8 repositories.
  """
  def tablist_class(variant \\ :boxed, extra \\ nil)
  def tablist_class(:boxed, extra), do: ["tabs tabs-box bg-base-200 p-1", extra]

  # The underline family: daisyUI's third tab look, used by the show-page
  # and settings strips across the modules. Unlike `tabs-box`, `tabs-border`
  # draws only the underline — there is no frame to shed, so no bg/padding
  # overrides ride along.
  def tablist_class(:border, extra), do: ["tabs tabs-border", extra]

  # `tabs-box` IS the daisyUI frame — it sets background-color, padding,
  # border-radius and box-shadow itself, which is why `:boxed`'s own
  # `bg-base-200 p-1` are redundant overrides rather than the frame. Dropping
  # only those would have left the box in place, so `:plain` drops the
  # modifier and keeps the bare `tabs` layout.
  def tablist_class(:plain, extra), do: ["tabs", extra]

  @doc """
  The daisyUI class list for a single tab. See `tablist_class/2`.
  """
  def tab_class(active?, extra \\ nil), do: ["tab gap-2", active? && "tab-active", extra]

  attr :active_tab, :string, required: true

  attr :tabs, :list,
    required: true,
    doc: "List of tab maps with :id, :label, and optional :icon, :badge, :navigate/:patch/:path"

  attr :on_change, :string,
    default: nil,
    doc: "phx-click event name for event-based tabs (tabs with no link key)"

  attr :target, :any, default: nil, doc: "LiveComponent target for event tabs"

  attr :variant, :atom,
    values: [:boxed, :plain, :border],
    default: :boxed,
    doc: ":boxed fills the strip; :plain drops the frame; :border is the underline look"

  attr :overflow, :atom,
    values: [:wrap, :menu],
    default: :wrap,
    doc:
      ":wrap lets tabs wrap onto further rows; :menu keeps one row and moves the tabs that do not fit into a \"⋯\" dropdown"

  attr :id, :string,
    default: nil,
    doc: "DOM id for `overflow={:menu}` (the hook needs one); derived from the tab ids when nil"

  attr :class, :string, default: nil

  slot :trailing,
    doc:
      "Controls that belong to the strip but are not tabs — a sort select, a count, a note — rendered inside the same frame at its end. A strip with a trailing slot stretches to fill its row (`flex-1`) so the frame visibly holds both; without it a strip with a control beside it reads as two unrelated bars."

  def nav_tabs(%{overflow: :menu} = assigns) do
    tabs = Enum.map(assigns.tabs, &normalize(&1, assigns.on_change))
    id = assigns.id || "nav-tabs-" <> Integer.to_string(:erlang.phash2(Enum.map(tabs, & &1.id)))

    assigns =
      assigns
      |> assign(:tabs, tabs)
      |> assign(:id, id)
      |> assign(:menu_id, id <> "-menu")

    ~H"""
    <%!-- The frame (and `class`) sit on this wrapper, which has no overflow
         clipping so the absolutely positioned menu is never cut off; the
         clipping lives on the inner strip. --%>
    <div
      id={@id}
      phx-hook="NavTabsOverflow"
      class={
        tablist_class(@variant, [
          "relative flex-nowrap items-center min-w-0 max-w-full",
          @class,
          @trailing != [] && "flex-1"
        ])
      }
    >
      <div
        role="tablist"
        data-nav-strip
        class="flex flex-1 flex-nowrap items-center min-w-0 overflow-hidden"
      >
        <%= for tab <- @tabs do %>
          <.link
            :if={tab.link_attrs != nil}
            {tab.link_attrs}
            role="tab"
            data-nav-tab={tab.id}
            data-nav-active={tab.id == @active_tab || nil}
            class={tab_class(tab.id == @active_tab, strip_tab_class(tab.id == @active_tab))}
          >
            <.overflow_tab_body tab={tab} active?={tab.id == @active_tab} />
          </.link>
          <button
            :if={tab.link_attrs == nil}
            type="button"
            role="tab"
            phx-click={@on_change}
            phx-target={@target}
            phx-value-tab={tab.id}
            data-nav-tab={tab.id}
            data-nav-active={tab.id == @active_tab || nil}
            class={
              tab_class(tab.id == @active_tab, [
                strip_tab_class(tab.id == @active_tab),
                "[&.phx-click-loading]:animate-pulse"
              ])
            }
          >
            <.overflow_tab_body tab={tab} active?={tab.id == @active_tab} />
          </button>
        <% end %>
      </div>
      <%!-- Hidden until the hook finds a tab that does not fit. --%>
      <button
        type="button"
        data-nav-more
        class="tab shrink-0 hidden"
        aria-label={gettext("More tabs")}
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls={@menu_id}
      >
        <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
      </button>
      <div :if={@trailing != []} class="flex shrink-0 items-center gap-2 pl-2 pr-1">
        {render_slot(@trailing)}
      </div>
      <div
        id={@menu_id}
        role="menu"
        data-nav-menu
        class="hidden absolute right-0 top-full z-50 mt-1 w-max min-w-44 max-w-[calc(100vw-1rem)] max-h-[70vh] overflow-y-auto rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
      >
        <%= for tab <- @tabs do %>
          <.link
            :if={tab.link_attrs != nil}
            {tab.link_attrs}
            role="menuitem"
            data-nav-item={tab.id}
            aria-current={tab.id == @active_tab && "true"}
            class={menu_item_class(tab.id == @active_tab)}
          >
            <.overflow_tab_body tab={tab} active?={tab.id == @active_tab} />
          </.link>
          <button
            :if={tab.link_attrs == nil}
            type="button"
            role="menuitem"
            phx-click={@on_change}
            phx-target={@target}
            phx-value-tab={tab.id}
            data-nav-item={tab.id}
            aria-current={tab.id == @active_tab && "true"}
            class={[menu_item_class(tab.id == @active_tab), "[&.phx-click-loading]:animate-pulse"]}
          >
            <.overflow_tab_body tab={tab} active?={tab.id == @active_tab} />
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  def nav_tabs(assigns) do
    assigns = assign(assigns, :tabs, Enum.map(assigns.tabs, &normalize(&1, assigns.on_change)))

    ~H"""
    <div
      role="tablist"
      class={tablist_class(@variant, [@class, @trailing != [] && "flex-1 items-center"])}
    >
      <%= for tab <- @tabs do %>
        <.link
          :if={tab.link_attrs != nil}
          {tab.link_attrs}
          role="tab"
          class={tab_class(tab.id == @active_tab)}
        >
          <.tab_body tab={tab} active?={tab.id == @active_tab} />
        </.link>
        <%!-- While the switch round-trips, LiveView tags the clicked tab
             with phx-click-loading — pulse it so a switch whose content
             needs server work still gives instant feedback. --%>
        <button
          :if={tab.link_attrs == nil}
          type="button"
          role="tab"
          phx-click={@on_change}
          phx-target={@target}
          phx-value-tab={tab.id}
          class={tab_class(tab.id == @active_tab, "[&.phx-click-loading]:animate-pulse")}
        >
          <.tab_body tab={tab} active?={tab.id == @active_tab} />
        </button>
      <% end %>
      <div :if={@trailing != []} class="ml-auto flex items-center gap-2 pl-2 pr-1">
        {render_slot(@trailing)}
      </div>
    </div>
    """
  end

  # `!= nil` rather than `Map.has_key?/2` throughout: a count that is only
  # shown when non-zero is normally written `badge: if(n > 0, do: n)`, and
  # keying on presence rendered that as an empty badge.
  defp tab_body(assigns) do
    ~H"""
    <.icon :if={@tab[:icon] != nil} name={@tab.icon} class="w-4 h-4" />
    {@tab.label}
    <span :if={@tab[:badge] != nil} class={["badge badge-sm", badge_tone(@tab, @active?)]}>
      {@tab.badge}
    </span>
    """
  end

  # Overflow-mode tabs never wrap their content and never shrink — except the
  # active one, which may, so that its label can truncate when it is the only
  # tab that fits.
  defp strip_tab_class(true), do: "flex-nowrap whitespace-nowrap min-w-0"
  defp strip_tab_class(false), do: "flex-nowrap whitespace-nowrap shrink-0"

  # 44px (`min-h-11`) is the touch-target floor; the badge is pushed to the end.
  defp menu_item_class(active?) do
    [
      "flex w-full min-h-11 items-center gap-2 rounded-lg px-3 py-2 text-left text-sm",
      "whitespace-nowrap hover:bg-base-200 focus-visible:bg-base-200 [&_.badge]:ml-auto",
      active? && "bg-base-200 font-medium"
    ]
  end

  # `tab_body/1` with a truncatable label, for the overflow-mode strip and menu.
  defp overflow_tab_body(assigns) do
    ~H"""
    <.icon :if={@tab[:icon] != nil} name={@tab.icon} class="w-4 h-4 shrink-0" />
    <span class="min-w-0 truncate">{@tab.label}</span>
    <span :if={@tab[:badge] != nil} class={["badge badge-sm shrink-0", badge_tone(@tab, @active?)]}>
      {@tab.badge}
    </span>
    """
  end

  # A tab may state its own badge tone — a pending-requests count stays
  # `badge-warning` whether or not its tab is the active one — and that has to
  # win over the active-tab default rather than fight it in the class list.
  defp badge_tone(tab, active?), do: tab[:badge_class] || (active? && "badge-primary")

  # Resolves the link keys ONCE, up front, so the template stays a template.
  #
  # `nil` counts as absent, not as "set to nil": tab lists are frequently built
  # with a conditional path (`path: if(admin?, do: "/x")`), and treating that as
  # a link would hand `Routes.path/1` a nil and raise from inside a render.
  defp normalize(tab, on_change) do
    links =
      [navigate: :navigate, patch: :patch, path: :navigate]
      |> Enum.map(fn {key, kind} -> {key, kind, Map.get(tab, key)} end)
      |> Enum.reject(fn {_key, _kind, to} -> to == nil end)

    link_attrs = resolve_link(links, tab)

    # NOT a raise. This renders a button wired to `phx-click={nil}` — a dead
    # tab, which is bad, but taking the whole LiveView down over a tab strip is
    # worse, and this is a library whose consumers we cannot audit. Warn so it
    # is findable, and render what the caller asked for.
    if link_attrs == nil and on_change == nil do
      Logger.warning(
        "nav_tabs: tab #{inspect(tab[:id])} has no :navigate/:patch/:path and no on_change " <>
          "was given, so it renders a button that does nothing"
      )
    end

    Map.put(tab, :link_attrs, link_attrs)
  end

  defp resolve_link([], _tab), do: nil

  # `:navigate`/`:patch` pass through VERBATIM, exactly like
  # `Phoenix.Component.link/1` — modules build their URLs with their own
  # Paths helpers, which already apply the URL prefix and locale, and
  # applying `Routes.path/1` a second time double-prefixes them (found
  # migrating the CRM show pages). Only the legacy `:path` key keeps the
  # helper treatment: it predates the link keys and its callers have always
  # passed unprefixed paths.
  defp resolve_link([{:path, kind, to}], _tab), do: [{kind, Routes.path(to)}]
  defp resolve_link([{_key, kind, to}], _tab), do: [{kind, to}]

  # Two link keys is unambiguously a mistake rather than a degraded render:
  # there is no defensible way to pick one, and `:navigate`/`:patch` are new
  # enough that no existing caller can trip this.
  defp resolve_link(links, tab) do
    raise ArgumentError,
          "nav_tabs: tab #{inspect(tab[:id])} sets more than one link key " <>
            "(#{inspect(Enum.map(links, &elem(&1, 0)))}) — pick one, exactly as " <>
            "Phoenix.Component.link/1 requires"
  end
end
