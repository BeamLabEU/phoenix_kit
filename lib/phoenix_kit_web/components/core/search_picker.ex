defmodule PhoenixKitWeb.Components.Core.SearchPicker do
  @moduledoc """
  A generic instant typeahead for "search a source, pick an entry" fields —
  extracted from `phoenix_kit_crm`'s involved-parties picker.

  The dropdown opens, spins, and renders ENTIRELY client-side (the
  `SearchPicker` hook, in `phoenix_kit_admin.js`); the server only executes the
  actual search and returns rows via `push_event`. Nothing visual waits on
  a round-trip.

  ## Contract

  The consumer (LiveView or LiveComponent) implements:

  - a **search event** (`search_event`, default `"picker_search"`) receiving
    `%{"q" => query, "limit" => limit}` and answering with
    `push_event(socket, results_event, %{q: query, results: rows, has_more: bool})`
    where each row is `%{kind:, uuid:, label:, sublabel?, icon?}` (icon =
    a heroicon class, defaults to `hero-user`);
  - a **pick event** (`pick_event`, default `"picker_pick"`) receiving
    `%{"kind" =>, "uuid" =>, "label" =>}` — stage your chip, then confirm
    with `push_event(socket, staged_event, %{})` so the hook clears the input;
  - optionally a **free-text event** (`text_event`) receiving
    `%{"name" => text}` — the "Add … as text" row renders only when this
    attr is set.

  ## Multiple pickers in one view

  `push_event` replies broadcast to EVERY hook listening on the event
  name, so two pickers sharing names would cross-populate (and a staged
  confirm would clear both). Give each picker distinct event names — or
  keep shared names and echo the `id` the hook sends with every push
  (`%{"id" => input_id}`) back in the results/staged payloads; when
  present, each instance drops payloads addressed to another `id`.

  ## Single-select mode

  `mode="single"` turns the picker into a suggestion box for ONE value: a
  pick sets the input's value client-side and fires a synthetic input event
  so a surrounding form's `phx-change` (and any server-side value→id
  mapping) sees it. No pick/staged events, no chips — give the input a form
  `name` and it submits like any field.

  ## Example (multi, inside a LiveComponent)

      <.search_picker
        id="party-search"
        dropdown_id="party-dropdown"
        text_event="stage_text"
        placeholder={gettext("Type a name…")}
      />

  Events auto-route to the closest LiveComponent/LiveView containing the
  input — no target needed when the picker renders inside the component
  that handles its events.

  The chips themselves stay consumer-rendered — their look and remove
  semantics differ per feature.

  ## One choice at a time (`chosen`)

  A filter or a form field that holds ONE picked record — "which task",
  "whose time" — is the same three steps everywhere: search, pick, show
  what was picked with a way to clear it. Pass `chosen` (the picked
  record's label) and the component draws that last state itself, in the
  input's place and at its size, with an × that sends `clear_event`:

      <.search_picker
        id="task-filter"
        dropdown_id="task-filter-list"
        chosen={@task && @task.title}
        clear_event="clear_task"
        search_on_focus
        close_on_pick
        placeholder={gettext("All tasks")}
      />

  With `chosen` nil it is the ordinary picker. The pick still arrives as
  `pick_event`; store the record and re-render with its label.
  """

  use Phoenix.Component

  @doc """
  Renders the picker input + its client-rendered dropdown container.

  ## Attributes

  - `id` — input DOM id (required; must be page-unique)
  - `dropdown_id` — dropdown DOM id (required)
  - `target` — CSS selector of an element inside the LiveComponent that
    should receive the pushed events. ONLY needed when the picker renders
    OUTSIDE that component's DOM tree; omitted, events auto-route to the
    closest LiveComponent/LiveView containing the input (the usual case).
    The selector must actually match an element or every push is dropped
    with a console error.
  - `mode` — `"multi"` (default) or `"single"` (see moduledoc)
  - `search_on_focus` — when `true`, clicking/focusing the EMPTY input
    already opens the dropdown in browse mode (the hook searches with an
    empty query, so the server should answer it with a first page — the
    workspace picker rule: offer options before any typing). Off by
    default; without it the dropdown only opens while typing, which also
    means a multi-mode picker won't reopen after a pick clears the input.
    (Previously only reachable as a raw `data-search-on-focus` rest attr —
    still honored for existing call sites.)
  - `direction` — `"down"` (default) or `"up"`. Use `"up"` when the input
    sits near the BOTTOM of a scrollable container (e.g. the last field
    of a modal): a downward dropdown there extends the container's
    scroll area instead of floating, so the suggestions end up below the
    fold — users read that as "no suggestions".
  - `name`/`value` — form field wiring for single mode
  - `search_event` / `results_event` / `pick_event` / `text_event` /
    `staged_event` — event-name overrides (defaults in moduledoc;
    `text_event` nil = no free-text row)
  - `placeholder`, `class` — input presentation
  - `searching_label` etc. — translated strings for the client-rendered rows
  - `close_on_pick` — multi mode: after a pick the list stays closed until
    the user types again (by default it clears the input and, with
    `search_on_focus`, reopens straight away)
  - `row_layout` — `"inline"` (default: label and sublabel on one line,
    the label truncated) or `"stacked"` (label on top, up to two lines,
    sublabel underneath)
  - anything else in `rest` (`form`, `maxlength`, `required`, `inputmode`,
    `enterkeyhint`, `autocapitalize`…) lands on the input

  ## Where the list is drawn

  The dropdown is a `popover="manual"` element: it opens in the top layer,
  positioned from the input, so an `overflow` ancestor — a modal's body, a
  scrolling panel — can no longer cut it off. It stays a DOM child of the
  picker, so inside a `<dialog>` it is not inert. It opens downward unless
  `direction="up"` or there is no room below (the phone keyboard counts),
  follows the input when anything scrolls, and closes with the dialog.
  Browsers without the Popover API get the old absolute positioning.

  On touch screens a row is picked when the finger lifts (and has not
  moved to scroll), so the first tap counts even with the keyboard up.
  """
  attr :id, :string, required: true
  attr :dropdown_id, :string, required: true
  attr :target, :any, default: nil
  attr :mode, :string, default: "multi", values: ["multi", "single"]
  attr :search_on_focus, :boolean, default: false
  attr :direction, :string, default: "down", values: ["down", "up"]
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :search_event, :string, default: "picker_search"
  attr :results_event, :string, default: "picker_results"
  attr :pick_event, :string, default: "picker_pick"
  attr :text_event, :string, default: nil
  attr :staged_event, :string, default: "picker_staged"
  attr :placeholder, :string, default: nil
  attr :class, :any, default: "input w-full"
  attr :searching_label, :string, default: "Searching…"
  attr :add_prefix_label, :string, default: "Add"
  attr :add_suffix_label, :string, default: "as text"
  attr :adding_label, :string, default: "Adding…"
  attr :more_label, :string, default: "Load more"
  attr :loading_more_label, :string, default: "Loading…"
  attr :no_matches_label, :string, default: "No matches"
  attr :close_on_pick, :boolean, default: false

  attr :chosen, :string,
    default: nil,
    doc: "The picked record's label: shown in the input's place, with a clear button."

  attr :clear_event, :string,
    default: "picker_clear",
    doc: "Sent (with the picker's `id`) when the chosen value's × is pressed."

  attr :clear_label, :string, default: "Clear"
  attr :row_layout, :string, default: "inline", values: ["inline", "stacked"]

  attr :rest, :global,
    include:
      ~w(form maxlength minlength required disabled readonly autofocus inputmode enterkeyhint autocapitalize spellcheck pattern)

  def search_picker(%{chosen: chosen} = assigns) when is_binary(chosen) and chosen != "" do
    ~H"""
    <%!-- The input's own classes, so the chosen value is the same box the
         picker was (size, border, width); the hook is not mounted. --%>
    <div class="relative">
      <span id={@id} class={[@class, "flex items-center gap-1 pr-1"]} data-picker-chosen>
        <span class="truncate flex-1 min-w-0" title={@chosen}>{@chosen}</span>
        <button
          type="button"
          class="btn btn-ghost btn-xs btn-circle shrink-0"
          phx-click={@clear_event}
          phx-value-id={@id}
          phx-target={@target}
          aria-label={@clear_label}
          title={@clear_label}
        >
          <span class="hero-x-mark w-3.5 h-3.5"></span>
        </button>
      </span>
    </div>
    """
  end

  def search_picker(assigns) do
    ~H"""
    <div class="relative">
      <input
        type="text"
        id={@id}
        name={@name}
        value={@value}
        phx-hook="SearchPicker"
        data-target={@target}
        data-dropdown={@dropdown_id}
        data-mode={@mode}
        data-search-on-focus={@search_on_focus || nil}
        data-direction={@direction}
        data-close-on-pick={@close_on_pick || nil}
        data-row-layout={@row_layout}
        data-search-event={@search_event}
        data-results-event={@results_event}
        data-pick-event={@pick_event}
        data-text-event={@text_event}
        data-staged-event={@staged_event}
        data-t-searching={@searching_label}
        data-t-add-prefix={@add_prefix_label}
        data-t-add-suffix={@add_suffix_label}
        data-t-adding={@adding_label}
        data-t-more={@more_label}
        data-t-loading-more={@loading_more_label}
        data-t-no-matches={@no_matches_label}
        placeholder={@placeholder}
        class={@class}
        autocomplete="off"
        {@rest}
      />
      <div
        id={@dropdown_id}
        phx-update="ignore"
        popover="manual"
        class={[
          "hidden absolute left-0 right-0 z-20 m-0 p-0 border border-base-200 rounded-box bg-base-100 text-base-content shadow overflow-hidden",
          if(@direction == "up", do: "bottom-full mb-1", else: "top-full mt-1")
        ]}
      >
      </div>
      <%!-- Keep the hook's client-rendered classes in the CSS bundle.
           `cursor-pointer` is in here because Tailwind v4's preflight stopped
           giving buttons a pointer, so the dropdown rows read as decoration
           without it — and a host that never writes the class by hand would
           otherwise not have it compiled at all. --%>
      <span class="hidden loading loading-spinner loading-xs hero-user hero-plus-mini hero-x-mark cursor-pointer items-start flex-col line-clamp-2 break-words mt-0.5"></span>
    </div>
    """
  end
end
