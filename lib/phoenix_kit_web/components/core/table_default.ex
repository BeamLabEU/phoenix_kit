defmodule PhoenixKitWeb.Components.Core.TableDefault do
  @moduledoc """
  A basic table component with daisyUI styling.

  Supports an optional card/table view toggle for responsive layouts. When `items`
  is provided or `toggleable` is true, renders both a table view (desktop default)
  and a card view (mobile default) with an optional toggle button.

  ## Examples

  ### Basic table (unchanged API)

      <.table_default>
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>Name</.table_default_header_cell>
            <.table_default_header_cell>Email</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row>
            <.table_default_cell>John Doe</.table_default_cell>
            <.table_default_cell>john@example.com</.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>

  ### With card/table toggle

      <.table_default
        id="users-table"
        toggleable
        items={@users}
        card_title={fn user -> user.name end}
        card_fields={fn user -> [
          %{label: "Email", value: user.email},
          %{label: "Role", value: user.role}
        ] end}
      >
        <.table_default_header>...</.table_default_header>
        <.table_default_body>...</.table_default_body>
        <:card_actions :let={user}>
          <.button size="sm" navigate={~p"/users/\#{user.id}"}>View</.button>
        </:card_actions>
        <:toolbar_title>
          <span class="text-sm text-base-content/60">{length(@users)} users</span>
        </:toolbar_title>
        <:toolbar_primary>
          <.button size="sm" navigate={~p"/users/new"}>Add User</.button>
        </:toolbar_primary>
      </.table_default>
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders a table with daisyUI styling.

  When `items` is provided or `toggleable` is true, renders a responsive wrapper
  with both table and card views, plus an optional desktop toggle button.
  Otherwise renders the classic table-only layout (fully backward compatible).

  ## Attributes

  * `id` - Element ID, required when using card/table toggle (optional)
  * `class` - Additional CSS classes (optional)
  * `variant` - Table variant: "default", "zebra", "pin-rows", "pin-cols" (optional, default: "default")
  * `size` - Table size: "xs", "sm", "md", "lg" (optional, default: "md")
  * `toggleable` - Show card/table toggle buttons on desktop (optional, default: false)
  * `items` - List of items for card view rendering (optional, default: [])
  * `card_title` - Function that returns the card title for an item (optional)
  * `card_fields` - Function that returns a list of `%{label: string, value: any}` for an item (optional)
  * `card_class` - Per-card wrapper class. String OR 1-arity function `(item) -> string`.
    Default `"card card-sm bg-base-200 shadow-sm"`. Override when the consumer needs a
    different look (e.g. larger padding, conditional opacity for disabled rows).
  * `storage_key` - localStorage key for persisting view preference, falls back to `id` in JS (optional)
  * `rest` - Additional HTML attributes (optional)

  ## Slots

  * `inner_block` - Table content (thead, tbody, etc.)
  * `card_body` - Fully-custom card content (receives item via `:let`). When provided,
    REPLACES the prescribed `card_header` + `card_title` + `card_fields` rendering — the
    consumer owns the inside of `<div class="card-body">`. `card_actions` footer still
    renders if provided. Use for rich cards with badges, icon-prefixed rows, custom layouts.
  * `card_media` - Media region (image/thumbnail/video preview) rendered ABOVE the card
    body, receives item via `:let`. Use for thumbnails, cover images, document previews.
    The slot owns its own padding/background — wrap content in a styled container.
  * `card_actions` - Action buttons rendered in each card footer (receives item via :let)
  * `toolbar_title` - Title/content rendered at the start of the toolbar row
  * `toolbar_actions` - Buttons rendered in the toolbar before the view toggle
  * `toolbar_primary` - The page's primary action (e.g. "New …"), rendered
    last in the toolbar, AFTER the view toggle, so it holds the far-right
    corner at every breakpoint — the toggle hides on phones in JS mode and
    would otherwise shift it

  ## Controlled view mode

  By default the card / comfortable / compact toggle is driven entirely
  client-side (JS hook + localStorage; comfortable is the default when
  nothing is stored). Pass `view_mode="card"`, `view_mode="comfy"`, or
  `view_mode="table"` to take control from the assigns side — the
  component then renders ONLY that view (no JS toggle) and the toolbar
  buttons emit `phx-click={view_event}` with
  `phx-value-mode="card"|"comfy"|"table"` so the consumer can drive
  state via `push_patch` (URL-backed) or `assign`. Use this when the
  view choice must survive across LV navigation or be part of the URL.

  ## Fitting columns to the width (`fit`)

  Pass `fit` (with an `id`) and the table drops its least important
  columns when they do not fit, instead of scrolling sideways:

      <.table_default id="users-table" fit>
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell lead>Name</.table_default_header_cell>
            <.table_default_header_cell priority={3}>Email</.table_default_header_cell>
            <.table_default_header_cell priority={1}>Status</.table_default_header_cell>
            <.table_default_header_cell />
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={u <- @users}>
            <.table_default_cell lead>{u.name}</.table_default_cell>
            ...

  * `lead` marks the one column that stays on the left and takes the slack
    (the name). Put it on the header cell AND on the body cell — the body
    cell then truncates instead of pushing the other columns out. Every
    other column is sized to its content and packed against the right
    edge, so no column sits alone in the middle of the table.
  * `priority` on a HEADER cell says how soon the column goes: the highest
    number goes first, `1` last; equal priorities go from the right. A
    column without a priority never goes (a checkbox, the row actions).
    Body cells declare nothing — the hook hides a column by its position.
  * `width` on a header cell pins that column's width (`"8rem"`).

  The `TableFit` hook measures the real table against its wrapper (the
  sidebar makes the viewport width useless here) on mount, on resize and
  after every patch, so a table with three columns keeps all of them where
  one with nine sheds four. Printing shows every column. A cell with a
  `colspan` is left alone (an empty-state row), and a header cell that
  spans columns is counted as that many. Columns are hidden by position,
  so every body and footer row must have the header's cells, in its order:
  a row with a `rowspan` continuation or an extra cell loses the wrong one.

  `fit_pack={false}` keeps the dropping and leaves the sizing to the
  caller, for a table that sets its own column widths.
  """
  attr :id, :string, default: nil
  attr :class, :any, default: ""
  attr :variant, :string, default: "default", values: ["default", "zebra", "pin-rows", "pin-cols"]
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :toggleable, :boolean, default: false
  attr :show_toggle, :boolean, default: true
  attr :items, :list, default: []

  attr :fit, :boolean,
    default: false,
    doc:
      "Drop the least important columns when the table is wider than its wrapper, and pack every column but the `lead` one against the right edge. Needs an `id`. See \"Fitting columns to the width\" in the moduledoc."

  attr :fit_pack, :boolean,
    default: true,
    doc:
      "With `fit`: also size and right-pack the columns. Pass `false` when the table already sizes its own columns (a prose column that must wrap) and only wants columns dropped."

  attr :card_title, :any, default: nil
  attr :card_fields, :any, default: nil

  attr :card_class, :any,
    default: "card card-sm bg-base-200 shadow-sm",
    doc:
      "Per-card wrapper class. String or 1-arity fn `(item) -> string`. When fn, called per item."

  attr :card_context_menu, :boolean,
    default: false,
    doc: """
    Flag each CARD `data-row-menu-context`, so a right-click anywhere on it
    opens the `table_row_menu` rendered in its `card_actions` slot at the
    pointer (see that component's "Right-click" section).

    Cards only: the table branch's rows come from the caller's inner block,
    so put the same attribute on your `table_default_row` / `sortable_row`
    there. Pass `false` to leave the browser's own menu in place — that is
    how a setting turns the gesture off.
    """

  attr :storage_key, :string, default: nil
  attr :wrapper_class, :string, default: "rounded-lg shadow-md overflow-x-auto overflow-y-clip"

  attr :card_grid_class, :string,
    default: "gap-4 md:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-4",
    doc:
      "Layout classes for the card-view grid (column density, gaps). Must NOT include a `display` utility (`grid`/`hidden`) — the component sets `display` per view-mode branch so controlled table mode can emit `hidden` cleanly. Override to change column count, e.g. a denser `gap-4 grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5`. Must be a literal in a Tailwind-scanned source so the classes are compiled — a dynamically-built string won't be in the generated CSS."

  attr :view_mode, :string,
    default: nil,
    values: [nil, "card", "table", "comfy"],
    doc:
      "Controlled view selector. When set, renders ONLY that view and disables the JS toggle; toggle buttons emit `view_event` with `phx-value-mode`. When nil, falls back to the JS hook + localStorage default."

  attr :view_event, :string,
    default: "switch_view",
    doc: "Event name emitted by the toggle buttons in controlled mode."

  attr :on_reorder, :string,
    default: nil,
    doc:
      "When set, the card-view container becomes a SortableGrid hook target. The table-view's tbody is owned by the inner_block — wire that side separately so desktop users get the same DnD as mobile."

  attr :reorder_scope, :map,
    default: %{},
    doc:
      "Map of scope values exposed on the card-view container as data-sortable-scope-* attrs. Keys are lowercased and dasherized for the DOM attr; the JS hook sends them back to LV as camelCase, so an Elixir key `:category_uuid` arrives in the LV handler payload as `\"categoryUuid\"`."

  attr :reorder_group, :string,
    default: nil,
    doc: "SortableJS group name for cross-container drag (must match the table-view side)"

  attr :item_id, :any,
    default: nil,
    doc:
      "1-arity function returning the data-id for a card. Defaults to `& &1.uuid`. Required when on_reorder is set."

  attr :card_media_class, :string,
    default: nil,
    doc: """
    Classes for the `:card_media` wrapper.

    Defaults to no class at all, which is exactly what the wrapper was
    before this attr existed — an existing consumer renders unchanged.
    Pass `"relative"` for a positioning context if the slot puts a corner
    overlay (a checkbox, a drag handle, a spinner) over the media.

    For a card GRID, pass a fixed band instead —
    `"relative h-24 bg-base-200 overflow-hidden"` is the shape the catalogue
    module uses everywhere: a card with a photo and one without are then the
    same height and the grid stays even. Cards drift apart when each page
    invents its own, so pick one per module and pass it consistently.
    """

  attr :rest, :global

  slot :inner_block, required: true

  slot :card_header,
    doc: "Custom header for each card (receives item via :let); replaces card_title"

  slot :card_body,
    doc:
      "Fully-custom card body (receives item via :let). When present, replaces card_header + card_title + card_fields rendering."

  slot :card_media,
    doc:
      "Media region (image/thumbnail/video) rendered above the card body. Receives item via :let. The slot owns its own padding/background; pass `card_media_class` to frame the wrapper so cards look alike across pages."

  slot :card_actions, doc: "Action buttons in card footer"

  slot :above_cards,
    doc:
      "Content rendered inside the card-view container, above the card grid. Hidden automatically when the JS hook switches to table mode (the wrapper has `md:hidden` toggled on)."

  slot :sort_bar,
    doc:
      "Always-visible sort UI rendered in its own row above the table/cards (e.g. a `<.sort_selector>`). Unlike `:above_cards`, this slot renders in both views."

  slot :toolbar_title,
    doc: "Title or arbitrary content rendered at the start of the toolbar row"

  slot :toolbar_actions,
    doc: "Action buttons rendered in the toolbar, before the view toggle"

  slot :toolbar_primary,
    doc:
      "The page's primary action (a create button), rendered after the view toggle so it sits in the far-right corner"

  def table_default(assigns) do
    if assigns.fit and is_nil(assigns.id) do
      raise ArgumentError, "<.table_default fit> needs an id: the TableFit hook is keyed by it"
    end

    if assigns.items == [] and not assigns.toggleable do
      table_default_classic(assigns)
    else
      table_default_with_cards(assigns)
    end
  end

  # The plain table (no items, no card toggle) still carries the toolbar: a
  # list's filters and its create button must not vanish when the list is
  # empty, which is exactly when they are needed.
  defp table_default_classic(assigns) do
    ~H"""
    <div
      :if={@toolbar_title != [] || @toolbar_actions != [] || @toolbar_primary != []}
      class="flex flex-wrap items-center justify-between gap-2 mb-2"
    >
      <div :if={@toolbar_title != []} class="min-w-0 flex-1 md:flex-none">
        {render_slot(@toolbar_title)}
      </div>
      <div class="flex flex-wrap items-center gap-2 ml-auto">
        <div :if={@toolbar_actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@toolbar_actions)}
        </div>
        {render_slot(@toolbar_primary)}
      </div>
    </div>
    <div class={@wrapper_class} {fit_wrapper_attrs(@fit, @id)}>
      <table
        class={[
          "table",
          table_variant_class(@variant),
          table_size_class(@size),
          @fit && fit_lead_class(),
          @fit && @fit_pack && fit_table_class(),
          @class
        ]}
        {@rest}
      >
        {render_slot(@inner_block)}
      </table>
    </div>
    """
  end

  defp table_default_with_cards(assigns) do
    item_id_fn = assigns[:item_id] || fn item -> Map.get(item, :uuid) end
    reorder_scope_attrs = build_sortable_scope_attrs(assigns[:reorder_scope] || %{})

    card_class_fn =
      case assigns[:card_class] do
        fun when is_function(fun, 1) -> fun
        str when is_binary(str) -> fn _item -> str end
        _ -> fn _item -> "card card-sm bg-base-200 shadow-sm" end
      end

    assigns =
      assigns
      |> assign(:item_id_fn, item_id_fn)
      |> assign(:card_class_fn, card_class_fn)
      |> assign(:reorder_scope_attrs, reorder_scope_attrs)

    ~H"""
    <div
      id={@id}
      phx-hook={if is_nil(@view_mode), do: "TableCardView"}
      data-storage-key={if is_nil(@view_mode), do: @storage_key || @id}
      class="relative"
    >
      <%!-- Toolbar row: title (left) + actions and view toggle (right) --%>
      <div
        :if={
          @toolbar_title != [] || @toolbar_actions != [] || @toolbar_primary != [] ||
            (@toggleable && @show_toggle)
        }
        class="flex flex-wrap items-center justify-between gap-2 mb-2"
      >
        <div :if={@toolbar_title != []} class="min-w-0 flex-1 md:flex-none">
          {render_slot(@toolbar_title)}
        </div>
        <div class="flex flex-wrap items-center gap-2 ml-auto">
          <div :if={@toolbar_actions != []} class="flex flex-wrap items-center gap-2">
            {render_slot(@toolbar_actions)}
          </div>
          <div
            :if={@toggleable && @show_toggle}
            class={
              [
                "join",
                # JS-toggle mode hides the buttons on mobile (only desktop has a
                # toggle there). Controlled mode is consumer-driven, so the
                # buttons are visible everywhere.
                is_nil(@view_mode) && "hidden md:inline-flex",
                @view_mode && "inline-flex"
              ]
            }
          >
            <button
              type="button"
              data-view-action={if is_nil(@view_mode), do: "card"}
              phx-click={@view_mode && @view_event}
              phx-value-mode={@view_mode && "card"}
              class={[
                "btn btn-sm join-item",
                @view_mode == "card" && "btn-active"
              ]}
              title={gettext("Card view")}
            >
              <.icon name="hero-squares-2x2" class="w-4 h-4" />
            </button>
            <button
              type="button"
              data-view-action={if is_nil(@view_mode), do: "comfy"}
              phx-click={@view_mode && @view_event}
              phx-value-mode={@view_mode && "comfy"}
              class={[
                "btn btn-sm join-item",
                @view_mode == "comfy" && "btn-active"
              ]}
              title={gettext("Comfortable view")}
            >
              <.icon name="hero-bars-3" class="w-4 h-4" />
            </button>
            <button
              type="button"
              data-view-action={if is_nil(@view_mode), do: "table"}
              phx-click={@view_mode && @view_event}
              phx-value-mode={@view_mode && "table"}
              class={[
                "btn btn-sm join-item",
                @view_mode == "table" && "btn-active"
              ]}
              title={gettext("Compact view")}
            >
              <.icon name="hero-bars-4" class="w-4 h-4" />
            </button>
          </div>
          <div :if={@toolbar_primary != []} class="flex items-center gap-2">
            {render_slot(@toolbar_primary)}
          </div>
        </div>
      </div>
      <%!-- Sort bar row: always-visible sort UI (renders in both views) --%>
      <div :if={@sort_bar != []} class="mb-2">
        {render_slot(@sort_bar)}
      </div>
      <%!-- Table: hidden on mobile always, shown on desktop (JS controls md: classes).
           In controlled mode, visibility is purely driven by @view_mode. --%>
      <div
        data-table-view=""
        class={
          [
            # `pk-comfy` on the uncontrolled branch matches the JS hook's
            # default so first paint is comfortable, not a compact flash
            # that jumps after localStorage is read.
            is_nil(@view_mode) && "hidden md:block pk-comfy",
            @view_mode == "table" && "block",
            @view_mode == "comfy" && "block pk-comfy",
            @view_mode == "card" && "hidden"
          ]
        }
      >
        <div class={@wrapper_class} {fit_wrapper_attrs(@fit, @id)}>
          <%!-- The stacked-variant utilities react to the `pk-comfy` marker
               (comfortable view): roomier cell padding without changing the
               table's size class. daisyUI's own paddings sit in :where()
               (zero specificity), so these win whenever the marker is on. --%>
          <table
            class={[
              "table",
              table_variant_class(@variant),
              table_size_class(@size),
              "[.pk-comfy_&]:[&_:where(td,th)]:py-3.5",
              @fit && fit_lead_class(),
              @fit && @fit_pack && fit_table_class(),
              @class
            ]}
            {@rest}
          >
            {render_slot(@inner_block)}
          </table>
        </div>
      </div>
      <%!-- Cards: always shown on mobile, hidden on desktop (JS controls md: classes).
           In controlled mode, visibility is purely driven by @view_mode. --%>
      <div
        id={if @on_reorder, do: "#{@id}-cards"}
        data-card-view=""
        class={
          [
            # Layout-only classes (no `display`) are always safe; the `display`
            # utility is set per-branch so controlled "table" mode emits only
            # `hidden` — no reliance on Tailwind's hidden-beats-grid source order.
            @card_grid_class,
            is_nil(@view_mode) && "grid md:hidden",
            @view_mode == "card" && "grid",
            @view_mode in ["table", "comfy"] && "hidden"
          ]
        }
        data-sortable={if @on_reorder, do: "true"}
        data-sortable-event={@on_reorder}
        data-sortable-items={if @on_reorder, do: ".sortable-item"}
        data-sortable-hide-source="false"
        data-sortable-group={@reorder_group}
        data-sortable-handle={if @on_reorder, do: ".pk-drag-handle"}
        phx-hook={if @on_reorder, do: "SortableGrid"}
        {@reorder_scope_attrs}
      >
        <%!-- Above-cards slot — spans full grid width via `col-span-full`,
             auto-hidden in table mode since it lives inside data-card-view --%>
        <div :if={@above_cards != []} class="col-span-full">
          {render_slot(@above_cards)}
        </div>
        <div
          :for={item <- @items}
          class={
            [
              @card_class_fn.(item),
              # min-w-0 lets the card shrink to its grid track instead of being
              # forced wide by a long unbreakable token (email/username) inside.
              "min-w-0",
              @on_reorder && "sortable-item"
            ]
          }
          data-id={if @on_reorder, do: @item_id_fn.(item)}
          data-row-menu-context={@card_context_menu}
        >
          <%!-- Optional media region rendered ABOVE the card body. Pass
               `card_media_class` to frame it — a fixed height and a neutral
               backdrop keep cards with and without a picture the same shape,
               which is what makes every page that shows cards look like every
               other one. Stays a plain unstyled div by default: this wrapper
               shipped classless, and giving it a positioning context or
               daisyUI's `figure` treatment would silently move an existing
               consumer's absolutely-positioned overlay. --%>
          <div :if={@card_media != []} class={@card_media_class}>
            {render_slot(@card_media, item)}
          </div>
          <%!-- Custom card body slot: REPLACES prescribed header+fields rendering.
               Consumer owns the inside of card-body. card_actions footer still
               applies below if also provided. --%>
          <div :if={@card_body != []} class="card-body min-w-0 break-words">
            {render_slot(@card_body, item)}
            <%!-- Footer row inside custom-body branch so spacing stays consistent --%>
            <div
              :if={@on_reorder || @card_actions != []}
              class="flex flex-wrap items-center gap-2 pt-1 border-t border-base-200 mt-auto"
            >
              <div
                :if={@on_reorder}
                class="pk-drag-handle text-base-content/30 hover:text-base-content/70 cursor-grab active:cursor-grabbing select-none"
                title={gettext("Drag to reorder")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </div>
              <div :if={@card_actions != []} class="flex flex-wrap items-center gap-1 ml-auto">
                {render_slot(@card_actions, item)}
              </div>
            </div>
          </div>
          <%!-- Default card body: prescribed header + key/value fields + footer --%>
          <div :if={@card_body == []} class="card-body gap-3 flex flex-col min-w-0 break-words">
            <%!-- Custom header (slot) or plain title string --%>
            <div :if={@card_header != []}>
              {render_slot(@card_header, item)}
            </div>
            <div :if={@card_header == [] && @card_title} class="font-medium text-sm">
              {@card_title.(item)}
            </div>
            <%!-- Key-value fields --%>
            <div :if={@card_fields} class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm flex-1">
              <%= for field <- @card_fields.(item) do %>
                <div class="text-base-content/60 min-w-0">{field.label}</div>
                <div class="min-w-0 break-words">{field.value}</div>
              <% end %>
            </div>
            <%!-- Footer row: drag handle (leftmost), action buttons
                 (rightmost via ml-auto on the wrapper). Both sit in a
                 flex-wrap so they share rows when buttons must wrap on
                 narrow cards instead of leaving the handle alone above
                 an empty space. --%>
            <div
              :if={@on_reorder || @card_actions != []}
              class="flex flex-wrap items-center gap-2 pt-1 border-t border-base-200 mt-auto"
            >
              <div
                :if={@on_reorder}
                class="pk-drag-handle text-base-content/30 hover:text-base-content/70 cursor-grab active:cursor-grabbing select-none"
                title={gettext("Drag to reorder")}
              >
                <.icon name="hero-bars-3" class="w-4 h-4" />
              </div>
              <div :if={@card_actions != []} class="flex flex-wrap items-center gap-1 ml-auto">
                {render_slot(@card_actions, item)}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Translates a `%{key => value}` map into a list of
  # `{"data-sortable-scope-key" => value}` tuples so the SortableGrid
  # hook can read them off the container as extra payload. nil/blank
  # values become "" so the parser side can detect "uncategorized" /
  # "no scope" without ambiguity.
  defp build_sortable_scope_attrs(scope) when is_map(scope) do
    Enum.flat_map(scope, fn {key, value} ->
      attr_name = "data-sortable-scope-" <> sortable_scope_dash(to_string(key))
      [{attr_name, sortable_scope_value(value)}]
    end)
  end

  # The hook sits on the scroll wrapper, not on the component root: the root
  # already carries TableCardView, and an element takes one hook.
  defp fit_wrapper_attrs(false, _id), do: []
  defp fit_wrapper_attrs(true, id), do: [id: "#{id}-fit", "phx-hook": "TableFit"]

  # Right-packing, in CSS so the first paint already has it: the lead column
  # takes all the slack, every other column shrinks to its content. Child
  # combinators keep a table nested inside a cell out of it. A lead BODY cell
  # (`max-w-0` + `overflow-hidden`) gives its width up to the column instead
  # of dictating it, which is what lets a long name truncate.
  # Always with `fit`, packed or not: the room the lead column keeps. Without
  # it a name wraps down to its longest word before the table overflows, and
  # overflow is the only thing that drops a column.
  defp fit_lead_class, do: "[&>thead>tr>th[data-col-lead]]:min-w-48"

  defp fit_table_class do
    [
      "[&>thead>tr>th[data-col-lead]]:w-full",
      "[&>thead>tr>th:not([data-col-lead])]:w-px [&>thead>tr>th:not([data-col-lead])]:whitespace-nowrap",
      "[&>tbody>tr>td:not([data-col-lead]):not([colspan])]:whitespace-nowrap",
      "[&>tbody>tr>td[data-col-lead]]:max-w-0 [&>tbody>tr>td[data-col-lead]]:overflow-hidden"
    ]
  end

  defp sortable_scope_value(nil), do: ""
  defp sortable_scope_value(v) when is_binary(v), do: v
  defp sortable_scope_value(v), do: to_string(v)

  defp col_width_style(nil), do: nil
  defp col_width_style(width), do: "width: #{width}; min-width: #{width}"

  defp sortable_scope_dash(name), do: name |> String.replace("_", "-") |> String.downcase()

  @doc """
  Renders a table header section.

  ## Attributes

  * `class` - Overrides the default header styling. Default is `"bg-base-300"` — a calm,
    theme-neutral header that reads as a subtle separator from `<tbody>` instead of the
    loud daisyUI primary. Pass `"bg-primary text-primary-content"` to restore the legacy
    look, or `class=""` for a fully bare header. The string fully replaces the default;
    concatenate manually if you want to add classes on top.
  """
  attr :class, :any, default: "bg-base-300"
  slot :inner_block, required: true

  def table_default_header(assigns) do
    ~H"""
    <thead class={@class}>
      {render_slot(@inner_block)}
    </thead>
    """
  end

  @doc """
  Renders a table body section.

  Accepts arbitrary HTML attrs via `:rest` so consumers can wire the
  `SortableGrid` hook directly onto the `<tbody>`:

      <.table_default_body
        id="endpoints-list-body"
        phx-hook="SortableGrid"
        data-sortable="true"
        data-sortable-event="reorder_endpoints"
        data-sortable-items=".sortable-item"
        data-sortable-handle=".pk-drag-handle"
      >
        ...
      </.table_default_body>
  """
  attr :rest, :global
  slot :inner_block, required: true

  def table_default_body(assigns) do
    ~H"""
    <tbody {@rest}>
      {render_slot(@inner_block)}
    </tbody>
    """
  end

  @doc """
  Renders a table footer section.
  """
  slot :inner_block, required: true

  def table_default_footer(assigns) do
    ~H"""
    <tfoot>
      {render_slot(@inner_block)}
    </tfoot>
    """
  end

  @doc """
  Renders a table row.

  ## Attributes

  * `class` - Additional CSS classes (optional)
  * `hover` - Enable hover effect: true/false (optional, default: true)
  * `rest` - Additional HTML attributes (optional)
  """
  attr :class, :any, default: ""
  attr :hover, :boolean, default: true

  attr :rest, :global

  slot :inner_block, required: true

  def table_default_row(assigns) do
    ~H"""
    <tr
      class={
        [
          # `group/row` is a NAMED Tailwind group marker so descendants can
          # use `group-hover/row:*` selectors keyed specifically to row hover.
          # Required by `<.drag_handle_cell>`'s hide-until-hover behavior.
          # Named (not bare `group`) on purpose: a bare row-level group would
          # also satisfy any descendant's unnamed `group-hover:` (e.g. the
          # sortable header chevron's `group-hover:opacity-70`), brightening
          # it on row hover instead of only on its own local-group hover.
          "group/row",
          if(@hover, do: "hover", else: ""),
          @class
        ]
      }
      {@rest}
    >
      {render_slot(@inner_block)}
    </tr>
    """
  end

  @doc """
  Renders a table header cell.

  `:inner_block` is optional — a self-closing call (`<.table_default_header_cell />`)
  renders an empty `<th>`, useful for drag-handle / row-selection columns
  that don't need a label.

  ## Attributes

  * `class` - Additional CSS classes (optional)
  * `priority`, `lead`, `width` - column fitting, for a `<.table_default fit>`
    (see its moduledoc)
  * `rest` - Additional HTML attributes (optional)
  """
  attr :class, :any, default: ""

  attr :priority, :integer,
    default: nil,
    doc: "In a `fit` table: how soon this column is dropped. Highest goes first; nil never goes."

  attr :lead, :boolean,
    default: false,
    doc: "In a `fit` table: the column that stays left and takes the slack."

  attr :width, :string, default: nil, doc: "A fixed CSS width for the column, e.g. `\"8rem\"`."
  attr :rest, :global

  slot :inner_block

  def table_default_header_cell(assigns) do
    ~H"""
    <th
      class={@class}
      data-col-priority={@priority}
      data-col-lead={@lead}
      style={col_width_style(@width)}
      {@rest}
    >
      {render_slot(@inner_block)}
    </th>
    """
  end

  @doc """
  Renders a table data cell.

  ## Attributes

  * `class` - Additional CSS classes (optional)
  * `colspan` - Number of columns to span (optional)
  * `rowspan` - Number of rows to span (optional)
  * `rest` - Additional HTML attributes (optional)
  """
  attr :class, :any, default: ""
  attr :colspan, :integer, default: nil
  attr :rowspan, :integer, default: nil

  attr :lead, :boolean,
    default: false,
    doc:
      "In a `fit` table: this cell is in the lead column, so it truncates rather than widening the table. Wrap its text in a `truncate` element."

  attr :rest, :global

  slot :inner_block, required: true

  def table_default_cell(assigns) do
    ~H"""
    <td class={@class} colspan={@colspan} rowspan={@rowspan} data-col-lead={@lead} {@rest}>
      {render_slot(@inner_block)}
    </td>
    """
  end

  @doc """
  Drag-handle cell for table-view DnD reorder.

  Renders a `<td>` containing the `hero-bars-3` grip icon, with the
  classes the SortableGrid hook needs to find it (`.pk-drag-handle`).
  The icon is **always visible** — a muted tone that strengthens on
  hover. It used to hide until row hover (`opacity-0
  group-hover/row:opacity-100`), but an affordance you cannot see is
  one nobody discovers: users had no idea rows were draggable until
  they happened to mouse over the right cell. Deliberate product call
  (2026-08-14) — do not quietly restore the hover reveal.

  Pair this with a `<tbody phx-hook="SortableGrid">` setup (see the
  `<.table_default>` moduledoc / phoenix_kit_projects reference call
  sites). The cell only renders the affordance — the hook owns the
  drag mechanics.
  """
  attr :class, :any, default: "w-8"
  attr :title, :string, default: nil
  attr :rest, :global

  def drag_handle_cell(assigns) do
    # `attr :title, default: nil` puts `:title => nil` in assigns, so
    # `assign_new` would be a no-op. Resolve the default explicitly so
    # callers can pass `title={nil}` (or omit it) and still get the
    # gettext'd default for accessibility.
    assigns = assign(assigns, :title, assigns.title || gettext("Drag to reorder"))

    ~H"""
    <td
      class={[
        "pk-drag-handle cursor-grab active:cursor-grabbing",
        "text-base-content/40 hover:text-base-content/70 transition-colors",
        @class
      ]}
      title={@title}
      {@rest}
    >
      <.icon name="hero-bars-3" class="w-4 h-4" />
    </td>
    """
  end

  @doc """
  Empty `<th>` sized to match the drag-handle column. Sits in the
  header row alongside `<.bulk_select_header_cell>` and the regular
  `<.table_default_header_cell>`s.

  Separate component (rather than a bare `<.table_default_header_cell class="w-8" />`)
  so the intent is obvious at the call site, and the width default
  matches `<.drag_handle_cell>`'s without consumers having to keep
  them in sync.
  """
  attr :class, :any, default: "w-8"

  def drag_handle_header_cell(assigns) do
    ~H"""
    <th class={@class}></th>
    """
  end

  @doc """
  Renders a sortable table header cell.

  When `sort` is nil, renders an inert `<th>` label. When `sort` is a map,
  renders a clickable button emitting `toggle_sort` (or a custom event) with
  `phx-value-by` set to the field key.

  ## States rendered

  - **Inactive column** (sortable, not the current sort) — faint
    `hero-chevron-up-down-mini` hint, strengthens on hover via `group-hover`.
  - **Active asc** / **Active desc** — solid chevron-up / chevron-down.
  - **Loading** (during in-flight click) — all chevrons hide and a
    `loading-spinner` shows; `pointer-events-none` blocks double-clicks;
    button dims via `opacity-60`. Driven by Phoenix's auto-applied
    `.phx-click-loading` class — no consumer wiring needed.
  - **Active column with an unrecognised `sort.dir`** (defensive) — falls
    back to the inactive up-down hint rather than rendering no icon.

  Atom or string `sort.dir` values are accepted (`:asc`/`:desc`/`"asc"`/`"desc"`).
  """
  attr :field, :atom, required: true

  attr :sort, :map,
    default: nil,
    doc: "Current sort: %{by: atom, dir: :asc | :desc}. When nil, renders inert label."

  attr :event, :string, default: "toggle_sort"
  attr :target, :any, default: nil
  attr :align, :atom, default: :left, values: [:left, :right, :center]
  attr :class, :any, default: ""

  attr :priority, :integer,
    default: nil,
    doc: "In a `fit` table: how soon this column is dropped. Highest goes first; nil never goes."

  attr :lead, :boolean,
    default: false,
    doc: "In a `fit` table: the column that stays left and takes the slack."

  attr :width, :string, default: nil, doc: "A fixed CSS width for the column, e.g. `\"8rem\"`."
  attr :rest, :global, include: ~w(colspan rowspan)

  slot :inner_block, required: true

  def sort_header_cell(assigns) do
    # Pre-compute the active direction (atom-or-string accepted; unknown
    # values fall back to nil → renders the up-down hint instead of leaving
    # the active column with no icon at all).
    active_dir = active_direction(assigns.sort, assigns.field)
    sortable? = is_map(assigns.sort)

    assigns =
      assigns
      |> assign(:active_dir, active_dir)
      |> assign(:sortable?, sortable?)

    ~H"""
    <th
      class={[
        @align == :right && "text-right",
        @align == :center && "text-center",
        @class
      ]}
      aria-sort={sort_header_aria_sort(@sort, @field)}
      data-col-priority={@priority}
      data-col-lead={@lead}
      style={col_width_style(@width)}
      {@rest}
    >
      <%= if @sortable? do %>
        <button
          type="button"
          phx-click={@event}
          phx-value-by={@field}
          phx-target={@target}
          class={[
            "group inline-flex items-center gap-1 cursor-pointer select-none",
            "hover:opacity-80 transition-opacity",
            "[&.phx-click-loading]:opacity-60 [&.phx-click-loading]:pointer-events-none",
            @align == :right && "justify-end w-full",
            @align == :center && "justify-center w-full"
          ]}
        >
          {render_slot(@inner_block)}
          <%!-- Sort indicator. While a click is in flight: spinner. When
               this column is the active sort: solid chevron for current
               direction. Otherwise (including active column with unknown
               dir): faint up-down hint that strengthens on hover. --%>
          <span class="hidden [.phx-click-loading_&]:inline-block loading loading-spinner loading-xs"></span>
          <.icon
            :if={@active_dir == :asc}
            name="hero-chevron-up-mini"
            class="w-4 h-4 [.phx-click-loading_&]:hidden"
          />
          <.icon
            :if={@active_dir == :desc}
            name="hero-chevron-down-mini"
            class="w-4 h-4 [.phx-click-loading_&]:hidden"
          />
          <.icon
            :if={is_nil(@active_dir)}
            name="hero-chevron-up-down-mini"
            class="w-4 h-4 opacity-30 group-hover:opacity-70 transition-opacity [.phx-click-loading_&]:hidden"
          />
        </button>
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </th>
    """
  end

  # Returns `:asc` / `:desc` when the given column is the active sort with a
  # recognised direction, otherwise `nil`. Tolerates atom or string `dir`
  # so consumers can pass either shape without crashing the render.
  defp active_direction(%{by: by, dir: dir}, field) when by == field do
    case dir do
      :asc -> :asc
      :desc -> :desc
      "asc" -> :asc
      "desc" -> :desc
      _ -> nil
    end
  end

  defp active_direction(_sort, _field), do: nil

  defp sort_header_aria_sort(nil, _field), do: nil

  defp sort_header_aria_sort(%{by: field, dir: dir}, field) when dir in [:asc, "asc"],
    do: "ascending"

  defp sort_header_aria_sort(%{by: field, dir: dir}, field) when dir in [:desc, "desc"],
    do: "descending"

  defp sort_header_aria_sort(%{} = _sort, _field), do: "none"
  defp sort_header_aria_sort(_other, _field), do: nil

  @doc """
  Renders a search input with a magnifying glass icon and debounce.

  Emits `phx-change="search"` (override via `on_change`) with a 300ms
  debounce. The input is ALWAYS wrapped in a `<form>` — LiveView's client
  refuses `phx-change` on an input outside a form (it throws in the
  browser console and the event never reaches the server, which reads as
  "search silently does nothing"; the component's original no-`on_submit`
  branch rendered exactly that trap and its first real caller hit it).
  Pressing Enter fires `on_submit` when given, otherwise the same
  `on_change` event — so Enter always means "search now".
  """
  attr :value, :string, required: true
  attr :on_change, :string, default: "search"
  attr :on_submit, :string, default: nil
  attr :placeholder, :string, default: nil
  attr :debounce, :integer, default: 300
  attr :name, :string, default: "search"
  attr :target, :any, default: nil

  attr :id, :string,
    default: nil,
    doc:
      "Id for the wrapping `<form>`. Without one, LiveView form recovery is silently disabled and host suites warn `missing_form_id`. Defaults to a value derived from the change event, which is unique per page in practice; pass an explicit id when two search toolbars share a page."

  attr :loading_indicator, :boolean,
    default: true,
    doc:
      "Show a spinner while the change event is in flight (LiveView's `phx-change-loading` on the input). Pass false when results appear instantly anyway — e.g. a client-side filter (TableLocalSearch) — where a spinner would be noise."

  attr :class, :any, default: ""

  def search_toolbar(assigns) do
    assigns =
      assigns
      |> assign(:placeholder, assigns.placeholder || dgettext("default", "Search..."))
      |> assign(:submit_event, assigns.on_submit || assigns.on_change)
      |> assign(:id, assigns.id || "pk-search-toolbar-#{assigns.on_change}")

    ~H"""
    <form
      id={@id}
      phx-submit={@submit_event}
      phx-target={@target}
      class={["flex items-center gap-2", @class]}
    >
      <.icon name="hero-magnifying-glass" class="w-4 h-4 text-base-content/50 shrink-0" />
      <input
        type="text"
        name={@name}
        value={@value}
        placeholder={@placeholder}
        phx-change={@on_change}
        phx-debounce={@debounce}
        phx-target={@target}
        class="input input-sm flex-1 min-w-0"
      />
      <%!-- Sibling selector: the input (the element LiveView stamps
           `phx-change-loading` on while the debounced query is in
           flight) precedes this span, so `.phx-change-loading ~ &`
           shows the spinner exactly for the round-trip window. --%>
      <span
        :if={@loading_indicator}
        class="hidden [.phx-change-loading~&]:inline-block loading loading-spinner loading-xs shrink-0 text-base-content/50"
      ></span>
    </form>
    """
  end

  # Private helper functions

  defp table_variant_class("default"), do: ""
  defp table_variant_class("zebra"), do: "table-zebra"
  defp table_variant_class("pin-rows"), do: "table-pin-rows"
  defp table_variant_class("pin-cols"), do: "table-pin-cols"

  defp table_size_class(nil), do: ""
  defp table_size_class("xs"), do: "table-xs"
  defp table_size_class("sm"), do: "table-sm"
  defp table_size_class("md"), do: "table-md"
  defp table_size_class("lg"), do: "table-lg"
end
