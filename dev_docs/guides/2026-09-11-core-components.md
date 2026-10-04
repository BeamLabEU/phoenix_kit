# Core UI Components

Canonical components for PhoenixKit admin UI. Read this before building admin
forms, lists, or media pickers. Related: LiveView form-id rules and the
landmine warnings are kept in the root `AGENTS.md` ("Admin UI Components").

## Core Form Components

`PhoenixKitWeb.Components.Core.{Input, Select, Textarea, Checkbox}` — canonical form primitives. Use over raw `<input>`/`<select>`/`<textarea>` in new code. They handle `phx-feedback-for`, gettext error display, label wiring, daisyUI styling. Reference: `lib/phoenix_kit_web/users/user_form.html.heex`.

- `class` attr → merges onto the **styled element** (input/label/textarea/checkbox). Pass daisyUI modifiers here: `input-sm`, `select-primary`, `checkbox-accent`, etc.
- `<.input>` also has `wrapper_class` → goes to the outer `<div phx-feedback-for>`.
- Prefer FormField binding: `<.input field={@form[:email]} type="email" label="Email" />`. Raw `name=`/`value=` still works for dynamic field names.
- **Free decimals (quantity, price, weight): `<.decimal_input>`, never `<.input type="number">`.** A browser number control follows the page locale (a typed `2.5` or `2,5` can submit `""`), and `step` blocks `phx-submit` on any other precision. `decimal_input` renders `type="text" inputmode="decimal"` (optional `unit="kg"` suffix; `bare` renders the `<input>` alone for a group of the host's own, e.g. a daisyUI `join` — its `label` becomes the control's `aria-label`) and echoes a typed binary back unchanged; parse the submitted text server-side with `PhoenixKit.Utils.Number.parse_decimal/2` (comma or dot, 3-digit grouping, `:min`/`:max`, `{:error, :empty | :invalid | :below_min | :above_max}`).

- **Form layout** — `<.form_section title icon>` is one card per group of fields (`:subtitle` and `:actions` slots); `title` is optional, for a page whose only card needs no heading. Inside one card, sub-groups take `<.section_header icon title>`, not a hand-drawn divider. The footer is `<.form_actions submit_label …>`: Cancel comes from exactly one of the `:cancel` slot, `cancel_click` (+ `cancel_target` inside a LiveComponent) or `cancel_to`, in that precedence; `submitting_label` is the `phx-disable-with` text (default "Saving…"). All three live in `Core.FormSection` / `Core.FormActions`.
- **Page header action** — the layout's `page_action` map (`%{icon:, label:, navigate:}`) is a navigation chip after the breadcrumb title; add `show_label: true` to write the label beside the icon on `sm` and up (the circle stays on phones). Navigation only — anything interactive goes in `page_toolbar`.

## Core List-UI Components

The canonical toolkit for admin list views — DnD reorder, bulk-select, sort, strategy reorder, load-more pagination. All live in `lib/phoenix_kit_web/components/core/`. Reference call sites: `phoenix_kit_projects`' `projects_live.ex` / `tasks_live.ex` / `templates_live.ex`.

- **Toolbar row** — `<.table_default>` draws one row above the list: `:toolbar_title` (filters, a search) at the start, `:toolbar_actions` before the view toggle, and `:toolbar_primary` — the page's create button — after it, in the far-right corner. The row renders on the plain table too, with no rows, so a filter and its create button never vanish on an empty list. Passing `items=` (or `toggleable`) switches to the card-capable path, whose phone layout is cards; omit `items` for a table that should stay a table. `<.bulk_actions_toolbar>` has a matching `:primary` slot. A module that uses `:toolbar_primary` needs a core floor that carries it — on an older core the button is simply not drawn (only a compile-time warning says why).
- **Fitting columns** — `<.table_default id="…" fit>` drops the least important columns when the table is wider than its wrapper, instead of scrolling sideways or relying on hand-picked `hidden lg:table-cell` breakpoints (the sidebar makes the viewport width a poor guide). Header cells declare it: `lead` on the one column that stays left and takes the slack (the name — put `lead` on its body cell too, so a long name truncates), `priority={n}` on every column that may go (highest number first, `1` last, none = never), and optionally `width="8rem"`. Everything but the lead column is sized to its content and packed against the right edge, so no column floats alone in the middle. The `TableFit` hook measures the real table, hides columns by position through a stylesheet (so stream inserts need nothing), and print shows every column. A user's Columns choice decides which columns exist; `fit` decides which of those there is room for. A module using `fit` needs a core floor that carries it.
- **Sortable** — `<.sortable_tbody enabled={…} event="reorder_x" id="…">` + `<.sortable_row item_id={uuid}>`; `enabled={false}` omits the hook so DnD turns off when sort_by ≠ position. Pair with `<.drag_handle_cell>` / `<.drag_handle_header_cell>` (render the `.pk-drag-handle` the SortableGrid hook reads).
- **TreeTable** — `<.tree_name_cell depth expandable expanded toggle_event value icon>` is the file-explorer name cell (indent, disclosure chevron, type icon) that composes into `table_default` rows. The consumer owns the walk and the expanded set.
- **BulkSelect** — `<.bulk_select_scope>` wraps the table; selection lives client-side, the hook pushes `%{"uuids" => […]}` on action-click. Children: `<.bulk_select_header_cell>`, `<.bulk_select_cell value={uuid}>`, `<.bulk_actions_toolbar>`. Consumer LVs collapse 0–1 captured uuids to `:all` (a single-row "reorder" is a no-op).
- **ReorderModal** — `<.reorder_modal>` strategy-picker dialog. The consumer LV owns the strategy whitelist (hardcoded string→atom map — never `String.to_existing_atom` on attacker input).
- **Modal `keep_in_dom`** — `<.modal keep_in_dom>` renders the `<dialog>` always; visibility flips via `data-show`. **Pass an explicit `id=`** — the auto-derived id collides when two kept-in-DOM modals share a close-event name.
- **SortSelector** — `<.sort_selector sort_by sort_dir options manual_field>`; select sends only `sort_by`, arrow only `sort_dir` (race-free). `manual_field={:position}` hides the direction toggle. Accepts `id` (default `"pk-sort-selector-#{event}"`). `label` (off by default) shows a visible "Sort by" before the control.
- **TableRowMenu right-click** — flag the row `data-row-menu-context` (`<.table_default_row data-row-menu-context>`, or `card_context_menu` on `<.table_default>` for cards) and a right-click opens the `<.table_row_menu>` rendered inside it at the pointer. A flag, not the menu id; omit it to turn the gesture off. Fields, a text selection and rows with no menu keep the browser's own menu. Use `Core.ContextMenu` only when rows have no `⋮` menu of their own.
- **Columns** — `<.column_settings_modal show columns selected>` (or `sections` for several tables in one modal; a column's optional `group` heads the Available list) is the live column picker: no Apply step, every change applies at once. Implement its events with `PhoenixKitWeb.TableColumns.handle_event/5` and read with `load/2` — each user's choice is the `"columns"` field of their `PhoenixKit.Users.ViewPrefs` for the table's key, Reset takes it back out so they follow the default again, and a site-wide setting can be that default (`site_default:`). Always-on columns (Name, Actions) stay out of the spec; the table draws them around the list. Never keep a column choice in a setting or in `custom_fields`.
- **Reorder writes** — `PhoenixKit.Utils.Reorder.reorder(schema, ids, field, opts)` rewrites `field` to each id's 1-based position. `key:` matches on another column than `:uuid` (a code, an integer id); `max_ids:` caps the deduplicated payload (default 500, `{:error, :too_many_uuids}` above it).
- **Pagination** — `<.load_more>` for embeddable / DnD-aware lists (rows append, selection persists); `<.pagination>` for standalone pages with deep-linkable state.

## Pickers, uploads and per-record files

- **Tree picker** — `PhoenixKitWeb.Components.TreePicker` (a LiveComponent) is every choice of a place in a hierarchy: a parent, a move target, a folder. Never an indented flat `<select>`. Build the tree with `PhoenixKit.Utils.Tree` (`from_flat/2`, `root/2`, `prune/2`); query subtrees and ancestors with `PhoenixKit.Utils.TreeQuery`. The picker sends `{TreePicker, id, value}` to the host LiveView and, with `name`, posts through hidden inputs; it only accepts ids its tree offers, but the host re-checks the pick against live data before acting.
- **Uploads** — `PhoenixKitWeb.Attachments` is the upload toolkit for module file forms: `allow/4`, `store/4` (base name only, core's type classifier, filed by the record's folder rules, never raises) and the shared messages. A module's own form keeps its state; this is the part every form repeated.
- **Per-record folders** — `PhoenixKit.Modules.Storage.ResourceFolders` resolves a record's media folder through the host's `:attachments_parent_folder` / `:attachments_folder_name` hooks, attaches and detaches files (from the row read under a lock), and writes pointers such as an avatar with `point_at/6`. A pointer is one key written by these functions — never set it by replacing a record's whole map from a form.
- **Per-user view preferences** — `PhoenixKit.Users.ViewPrefs` (`get/2`, `put/3`, `delete_fields/3`) holds a user's choices for a view under a key, one row per user and view; a write patches fields, so two tabs changing different fields both keep theirs. Nothing there raises.

## Multilang Form Components

`PhoenixKitWeb.Components.MultilangForm` — `<.multilang_tabs>`, `<.multilang_fields_wrapper>`, `<.translatable_field>`, plus helpers `mount_multilang/2`, `handle_switch_language/2`, `merge_translatable_params/4`. Forms `import` it and call `mount_multilang(socket)` in `mount/3`; an EDIT form passes `open_on: :viewing_language` so it opens on the tab of the language the admin is viewing the page in (a new record keeps the default, the main language, which holds its required fields).

**Wrapper scope rule** (load-bearing): `<.multilang_fields_wrapper>` wraps translatable fields **only**. The wrapper's id includes `@current_lang`, so a switch causes morphdom to re-mount everything inside. Non-translatable fields (pricing, status, actions) render as siblings outside the wrapper or they lose state on every switch.

**Language switching:** client-side skeleton toggle + 150ms trailing debounce on the server. `mount_multilang/1` attaches a `:handle_info` hook via `Phoenix.LiveView.attach_hook/4` that intercepts the timer message — consumers don't need a `handle_info` clause. LiveComponent fallback: rescue `ArgumentError` from `attach_hook` and add the clause manually. The `switching_lang` attr is a backwards-compat no-op.

**Translatable fields:** `<.translatable_field>` takes `changeset={@changeset}` (not FormField) — its behavior changes with the active tab (primary-language vs JSONB-backed secondary). When mixed with `<.input>`/`<.select>`, the LV keeps both `:changeset` and `:form = to_form(changeset)` in sync via a private helper from mount/validate/save-error paths.

## Layout Wrapper

PhoenixKit LiveView templates use `<PhoenixKitWeb.Components.LayoutWrapper.app_layout>` (NOT `Layouts.app`):

```heex
<PhoenixKitWeb.Components.LayoutWrapper.app_layout
  flash={@flash} page_title={@page_title} current_path={@url_path}
  project_title={@project_title} phoenix_kit_current_scope={@phoenix_kit_current_scope}
  current_locale={assigns[:current_locale]}>
  <!-- content -->
</PhoenixKitWeb.Components.LayoutWrapper.app_layout>
```

Only `flash` is required. Note: the assign is `@url_path`, the attr is `current_path`. Full attr list: `lib/phoenix_kit_web/components/layout_wrapper.ex`.

## MediaBrowser Component

Embeddable media UI (folder tree, grid/list, upload, search, selection, trash): `lib/phoenix_kit_web/components/media_browser.ex`. Full attrs/behavior: `dev_docs/guides/2026-07-27-media-browser.md`.

**One-line embed** — the macro injects upload setup, the `"validate"` stub, and the `handle_info` delegator:

```elixir
use PhoenixKitWeb.Components.MediaBrowser.Embed
```

```heex
<.live_component module={PhoenixKitWeb.Components.MediaBrowser}
  id="media-browser" parent_uploads={@uploads} />
```

`parent_uploads={@uploads}` is required (LiveView `allow_upload` constraint). Key attrs: `scope_folder_id`, `on_navigate={:navigate}` (controlled mode), `initial_params`, `admin`, `select_mode`.

**URL sync (shareable folder deep links):** `use …Embed, url_sync: true` puts folder/search/page/view in the URL via lifecycle hooks (`attach_hook`, **not** injected clauses) — composes with a host LV that has its own `handle_params`/`handle_info`. Reference: `lib/phoenix_kit_web/live/users/media.ex`.

## FeaturedImage Component

One entity's "main image" (order/product image, logo, avatar): a thumbnail, an always-visible Change/Remove menu and the whole media-picker protocol — `lib/phoenix_kit_web/components/featured_image.ex`. Reach for it instead of hand-writing the pencil/×/picker trio; the moduledoc has every attr and the host wiring.

```heex
<.live_component module={PhoenixKitWeb.Components.FeaturedImage}
  id="order-featured" uuid={@order.featured_image_uuid}
  picker_scope={@order.storage_folder_uuid && {:folder, @order.storage_folder_uuid}}
  phoenix_kit_current_user={@current_user} readonly={@order.deleted?} />
```

```elixir
def handle_info({PhoenixKitWeb.Components.FeaturedImage, "order-featured", {:set_featured, uuid}}, socket)
```

- **The `:set_featured` handler is required** (`uuid` is a file uuid, or `nil` on Remove) — without it the choice is silently dropped. Same payload shape as `MediaBrowser`'s `:featured`.
- **Controlled and write-free:** it draws only the `uuid` you pass and writes nothing; you authorize, persist and assign the new value back. It checks that a chosen file exists, is an image and is not trashed — never that the user may change this entity.
- **`picker_scope`** is `{:folder, uuid}`, `:lazy` (folder created on the first click: answer `:scope_requested` with `send_update(FeaturedImage, id: id, open_picker: true | false)` or `error: msg`) or `nil` (choosing unavailable; the modal is never mounted).
- The picker renders through `<.portal>` so it can sit inside a host `<.form>`; `has_element?/2` cannot see into it in tests — assert on `#<id>-portal`. Recommended Phoenix LiveView ≥ 1.2.12.
- One `Storage` query per instance: not for lists — draw list thumbnails from data you already have.

## Charts and lanes

`PhoenixKitWeb.Components.Core.Chart` draws zero-JS SVG charts (`<.line_chart>` and friends; imported everywhere through `use PhoenixKitWeb`). `<.chart_lanes>` (`Core.ChartLanes`, imported with `only: [chart_lanes: 1]`) draws rows of horizontal bands on the same x axis: what was scheduled, on or booked over the stretch the chart shows. It knows nothing about the domain; each band says only how it is drawn and in what colour.

```heex
<div class="w-full">
  <div class="h-48"><.line_chart id="price" data={@prices} x_domain={{0, 1440}} step /></div>
  <.chart_lanes
    id="devices"
    x_domain={{0, 1440}}
    marker_x={@now_minute}
    x_format={&clock_label/1}
    rows={[
      %{id: "boiler", label: "Office boiler", note: "22 °C",
        bands: [
          %{from: 360, to: 540, variant: :dashed, class: "text-info", title: "Scheduled"},
          %{from: 380, to: 470, variant: :fill, class: "text-success", title: "Heating"}
        ]}
    ]}
  />
</div>
```

- **Line the lanes up with a chart by giving both the same `x_domain` and the same width** (one wrapper, no padding between). Both place x through `PhoenixKitWeb.Components.Core.ChartScale` (`domain/2`, `fraction/2`, `percent/2`, `span/3`), which is public so a custom overlay can use the same scale.
- **Bands:** `from`/`to` of `nil` run to that edge; `from == to` is a point. `variant` is `:fill`, `:soft`, `:outline` or `:dashed`; the colour is a `text-*` class. `title` (tooltip and screen-reader text) defaults to the label, then to the range through `x_format`. Later bands sit on top.
- **Slots:** `:row_label` (a custom label, e.g. a link), `:band` (content inside each band — a button that opens a booking), `:empty`.
- **Rows:** `row_height` (default `2rem`); with more rows than `scroll_after` (default 12) the list scrolls under a chart that stays put. A row's DOM id follows its `:id`.

Reference: the lanes demos in `phoenix_kit_parent`'s core components showcase.

### Save button with a state

`<.save_button dirty={…} saved={…} />` (`Core.SaveButton`, opt-in import) is a form's Save button that says where the form stands: disabled until something changed, then "Unsaved changes", then "Saved". It only draws — send a `phx-change` from the form with a `key` per form, keep `dirty` / `saved` sets, move the key between them on change and on save (the moduledoc has the six lines). Use it where a change does real work (a different storage profile moves files) and wherever a control that saved on change gave no sign it had.

### Crosshair readout

`<.line_chart hover={:crosshair}>` adds a snapping crosshair with a readout on top of the per-point hover bands (`hover={true}` keeps the native tooltip only; every band carries `data-x` / `data-y` for a host's own hook). `point_note` is a 1-arity function given `%{x, y, index, rank, count}` that returns one more readout line or `nil` — `rank` is the point's place with the series sorted ascending by y, ties sharing a place. `rows` (`%{label:, color:, bands: [{from, to}]}`, bands right-open in x units) lists what runs over the hovered x, in the order given.

## Date navigation

`<.date_nav date path today min max>` (`Core.DateNav`) is the previous / today / next header of a page that shows one day at a time. It is stateless: the date lives in the URL, the buttons are `<.link patch>`es built by your 1-arity `path` function, and `handle_params/3` reads it back with `DateNav.parse_param/2` (clamped to `min`/`max`). The optional date picker sits in a form and sends `pick_event` (default `"date_nav_pick"`, `%{"date" => "YYYY-MM-DD"}`) — answer it with a `push_patch`. Short dates in the viewer's language: `PhoenixKit.Utils.Date.short/1` ("3 Oct", "3. okt") and `short_with_year/1`; the order comes from the translation of `"%{day} %{month}"`, never hand-concatenate.

## Image editor

`PhoenixKitWeb.Components.ImageEditor` (LiveComponent) edits a stored image after upload through `PhoenixKit.Modules.Storage.ImageEditing`: crop (with aspect presets), quarter turns, mirroring, straightening, redaction (blur, pixelate, black box), brightness and contrast. It is a plain server-rendered form; the `ImageEditor` hook adds drawing the crop and the areas on the preview.

```heex
<.live_component
  module={PhoenixKitWeb.Components.ImageEditor}
  id={"image-editor-" <> @file.uuid}
  file={@file}
  scope={@phoenix_kit_current_scope}
  on_close={JS.push("close_image_editor")}
/>
```

- **Who may edit:** `ImageEditing` decides from `scope` (owner, Owner/Admin, `"media"` permission). A host that has already authorized the user for the file (MediaBrowser, by folder scope) passes `authorized={true}`.
- **Keep it current:** forward `{:phoenix_kit_file_processed, uuid}` (`Storage.subscribe_to_file_events/0`) as `send_update(ImageEditor, id: id, file_processed: uuid)`. MediaBrowser and MediaDetail already do.
- MediaBrowser opens it from a file's menu ("Edit image"); MediaDetail from its "Edit image" button.

How editing works underneath (the hidden unedited original, versioned URLs, the placeholder while rendering): `lib/modules/storage/README.md` → "Editing images".

## Built-in Dashboard

Tabs, subtabs, badges, context selectors: see `lib/phoenix_kit/dashboard/README.md`.
