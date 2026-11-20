defmodule PhoenixKitWeb.Components.Core.DateInput do
  @moduledoc """
  A date field that shows and accepts the date in the **site's date format**
  (Settings → `date_format`), with a clear button and a calendar button.

  Why not `<input type="date">`: the browser draws it, so the displayed
  format follows the browser/OS locale (`10/16/2026` next to a `16.10.2026`
  page), the picker's language is the browser's, and its "Clear" lives inside
  the browser's popup. This component renders text the page controls.

  ## Usage

      <.date_input field={@form[:due_on]} label="Due" />
      <.date_input id="from" name="value[from]" value={@from} size="xs" bare aria-label="From" />
      <.date_input field={@form[:day]} min={~D[2026-01-01]} max={@today} required />
      <.date_input name="d" value={@d} native />   <%!-- opt out of the widget --%>

  ## Markup

      <div id="x-wrap" phx-hook="PkDateInput" data-format=… data-locale=…>
        <input type="text" id="x" …>                  <%!-- what people see and type --%>
        <input type="date" id="x-value" name="…" …>   <%!-- what the form submits --%>
        <button data-clear>✕</button> <button data-open>📅</button>
      </div>

    * The **visible text input carries the caller's `id`** (so `<label for>`
      and selectors hit the field people type into) and has no `name`.
    * The **value element is a real `<input type="date">`** with the caller's
      `name`, id `<id>-value` and the ISO `YYYY-MM-DD` value (or `""`). Once
      the hook runs it is invisible (`absolute inset-0 opacity-0
      pointer-events-none`, `tabindex="-1"`, `aria-hidden`), not
      `display:none`: LiveViewTest can set it with `form/3`, every receiver
      (`Date.from_iso8601/1`, Ecto `:date`) keeps working, and `showPicker()`
      works on it.
    * `id` should be passed. Without one it is derived from `name`; callers
      whose names repeat on a page (filter chips, table rows) must pass
      distinct ids.

  ## Without LiveView

  The server renders the field as a plain native date input: the value
  element is visible, the text field, ✕ and calendar button are `hidden`, and
  `required` sits on the value element. A page where no hook runs (a
  controller template, a host that does not register `phx-hook`s) therefore
  submits the date correctly, as `<input type="date">` always did. When the
  hook mounts it sets `data-enhanced` on the wrapper (daisyUI/Tailwind
  `group-data-[enhanced]/pk-date:` classes swap the two roles) and moves
  `required` to the text field. In a LiveView page that means the browser's
  date input shows for the moment between the first paint and the socket
  connecting. Pass `native` to skip the widget altogether.

  A date picked in the browser's input during that moment is carried over
  only while that input still has the focus when the socket connects: the
  join patch resets every other form control to the server's value. The hook
  then moves the focus to the text field, the control that is displayed from
  then on. A host stylesheet that predates these classes lacks the
  `group-data-[enhanced]` utilities: the hook notices that the text field is
  still not displayed, undoes the swap (the browser's date input stays
  visible, focusable and `required`) and warns once in the console. Rebuild
  the CSS to get the widget.

  `<label for>` points at the text field (it carries the `id`), which is
  `hidden` on a page where no hook runs, so a click on the label does nothing
  there; the date input is named by its `aria-label`.

  The text field's value is formatted on the server. A value that is not a date
  (a changeset echoing bad input) is shown as given in the text field; the
  value element is rendered with it, but a browser sanitises a non-ISO
  `value` of a date input to `""`, which the hook does not take for a pick.
  The hook marks such a field rejected at mount (the hint, `input-error`,
  `setCustomValidity`), so a submit from a button or Enter, `phx-submit`
  included (the browser fires no `submit` event on an invalid form), waits
  until the person corrects or clears it. A `phx-click` save, `novalidate` or a
  dispatched `submit` still save the empty date input.

  ## Attributes: where `rest` goes

    * The value element gets what describes the submitted value or the
      form: `form`, `step`, `list`, `phx-change` and `data-*`. `phx-target`
      and `phx-value-*` go to **both** elements: LiveView reads them from
      the element that fires the event, and `phx-click`/`phx-blur`/key
      bindings fire on the visible one. The `value` such a binding delivers
      is the visible text in the site format, not ISO.
    * Everything else goes to the visible input: `tabindex`, `phx-click`,
      `phx-blur`, `phx-focus`, `phx-keydown`, `phx-keyup`, `phx-key`, `lang`,
      `spellcheck`, `onkeydown`/`onkeyup`/`onfocus`/`onblur`/`oninput`,
      `style`, `title`, `autofocus` (on both inputs: the browser focuses the
      native one on a page with no hook, and the hook then moves the focus to
      the text field, which the browser cannot do itself because it is `hidden`
      when inserted; not when the person already focused another field),
      `autocomplete` and `inputmode` (which replace the defaults `off` and
      `numeric`/`text`), `aria-*`, … (the value element cannot be clicked or
      focused by a person).
    * Dropped: `phx-debounce` (commits are discrete: a `"blur"` debounce on a
      never-focused element would swallow the change) and the attributes that
      mean nothing for a date (`pattern`, `maxlength`, `minlength`, `size`,
      `accept`, `capture`, `multiple`, `cols`, `rows`): on the text field a
      `pattern` would reject every formatted date.
    * `required` sits on the value element until the hook runs, then on the
      visible input; `readonly` and `disabled` go to both.
    * `class` styles the visible input, `wrapper_class` the outer `<div>`.
    * `format`, `locale`, `week_start` (ISO `1..7`, Monday = 1) and `today`
      default from Settings (`date_format`, `week_start_day`), the UI language
      and the site-zone today, so a unit test needs no database.
    * `%DateTime{}` / `%NaiveDateTime{}` values are shown as the date in the
      site time zone.
    * The ✕ is not rendered for `required`, `disabled` or `readonly` fields
      (clearing a required field only produces an error) and is hidden while
      the field is empty. It is not a tab stop (`tabindex="-1"`): the
      keyboard has the calendar's "Clear" button and an emptied text field.
    * The `:icon` slot of `<.input>` has no place here (the buttons occupy the
      inside of the field): `<.input type="date">` given an icon renders the
      browser's date input instead. `inner_block` is not used by either.
    * `bare` renders the control alone (no label, outer wrapper or error list)
      for a table cell or a filter chip; a `label` becomes its `aria-label`.

  ## The commit contract (hook `PkDateInput`)

  The visible text never talks to LiveView: its `input`/`change` events stop at
  the wrapper. Only these commit points change the value element: blur, Enter,
  a day picked in the calendar, ✕. A commit parses the text (any of
  `. / - space ,` as separators, 1–2 digit day and month, 2- or 4-digit year,
  digits-only `ddmmyyyy`, ISO always, an English month name for `F j, Y`; a
  two-digit year takes the century that puts the date within 50 years before
  to 49 after `today`: in 2026, `85` is 1985 and `30` is 2030); if
  valid and different it sets the value element and fires `input` on it, so
  the form's `phx-change` runs with `_target` = the caller's `name`. Empty
  text clears (`""`). Partial or impossible text (or outside `min`/`max`)
  leaves the value **unchanged**, marks the field `input-error`/`aria-invalid`
  and calls `setCustomValidity` (blocks a native submit): a half-typed date
  never reaches the server; the rejected text stays in the field (it is put
  back after a server update) until the next commit. On a `required` field
  empty text is rejected too instead of clearing the value. Enter commits
  synchronously and is prevented only when the text is invalid or the form
  has no `phx-submit`.

  A rejected entry is announced: the message (the expected format, or the
  `min`/`max` range) goes into a `role="status"` hint under the field, which
  the text input references with `aria-describedby`, and into `title`.

  The rejection blocks a native `submit` (through `setCustomValidity`). It
  does not block a `phx-click` save button, a form with `novalidate` or a
  `requestSubmit` from a hook: there the old value is saved while the field
  still shows the rejected text.

  ## Calendar popup

  The calendar button opens a Cally (`calendar-date`) popup in the UI language,
  with the site's first day of the week, `min`/`max`, a footer with "Today" and
  "Clear", and the day already chosen. Cally is vendored in core
  (`priv/static/assets/vendor_libs/cally`, served through
  `PhoenixKit.Install.ViewerLibraries`) and loaded by `loadVendored` the first
  time a calendar opens. A host that bundles `phoenix_kit.js` into its own
  `app.js` must set `window.PHOENIX_KIT_LIB_BASE` to where the vendored files
  are served, as for the other lazily loaded libraries.

  The popup is a `popover="manual"` element, so it escapes `overflow` in
  tables and sits above a `<dialog>`; it sits under the field (above it when
  there is no room) and closes on a pick, Escape (which does not reach a
  surrounding PkDialog), a press outside, a scroll or resize, the owning
  dialog's close and `pagehide`. On phones (`(pointer: coarse)`), with no
  Popover API, or when Cally fails to load, the button calls `showPicker()` on
  the value element instead: the browser's own picker, while the text field and
  ✕ stay the same.

  Known gap: PkDialog's unsaved-input guard does not see edits to this field.

  ## `<.input type="date">`

  `input/1` renders a `date_input` for `type="date"` (without `size`; the
  other native-only attributes are dropped, see above). Opt out per call with
  `<.input type="date" native>`, or for the whole host with
  `config :phoenix_kit, native_date_inputs: true`. `datetime-local`, `time`,
  `month`, `week` are untouched.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [field_errors: 1]

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @formats ["Y-m-d", "m/d/Y", "d/m/Y", "d.m.Y", "d-m-Y", "F j, Y"]

  # `rest` keys the value element takes (it is the submitted control): the
  # form it belongs to, its date step and datalist, and the LiveView change
  # wiring. `data-*` is matched by prefix. `phx-target` and `phx-value-*` go to
  # both elements: LiveView reads them from the element that fires the event,
  # and click, blur and key events fire on the visible one. Everything else
  # goes to the visible input, the only element a person can click or focus.
  @value_rest [:form, :step, :list, :"phx-change"]

  # Meaningless for a date (and harmful on the text field: a `pattern` would
  # reject every formatted date), or dropped on purpose (`phx-debounce`).
  @dropped_rest [
    :"phx-debounce",
    :pattern,
    :maxlength,
    :minlength,
    :size,
    :accept,
    :capture,
    :multiple,
    :cols,
    :rows
  ]

  # Classes that turn the server-rendered native date input into the invisible
  # value element once the hook has set `data-enhanced` on the wrapper.
  @value_enhanced [
    "group-data-[enhanced]/pk-date:absolute",
    "group-data-[enhanced]/pk-date:inset-0",
    "group-data-[enhanced]/pk-date:h-full",
    "group-data-[enhanced]/pk-date:w-full",
    "group-data-[enhanced]/pk-date:opacity-0",
    "group-data-[enhanced]/pk-date:pointer-events-none"
  ]

  attr :id, :any, default: nil
  attr :name, :any, default: nil
  attr :label, :string, default: nil

  attr :value, :any,
    default: nil,
    doc: "a `Date`, a `DateTime`/`NaiveDateTime` (shown in the site zone), an ISO string or nil"

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:due_on]"

  attr :errors, :list, default: []
  attr :class, :any, default: nil, doc: "extra classes on the visible input"
  attr :wrapper_class, :any, default: nil, doc: "extra classes for the outer wrapper"
  attr :size, :string, default: "md", values: ~w(xs sm md)

  attr :bare, :boolean,
    default: false,
    doc: "the control alone, for a table cell or a filter chip"

  attr :min, :any, default: nil, doc: "a `Date` or an ISO string"
  attr :max, :any, default: nil, doc: "a `Date` or an ISO string"

  attr :placeholder, :string,
    default: nil,
    doc: "default: the format as a pattern, e.g. `dd.mm.yyyy`"

  attr :native, :boolean,
    default: false,
    doc:
      "opt out of the widget: render a plain `<input type=\"date\">` (a page with no hook gets one anyway)"

  attr :format, :string, default: nil, doc: "PHP-style; default: Settings `date_format`"
  attr :locale, :string, default: nil, doc: "BCP 47 tag; default: the UI language"

  attr :week_start, :any,
    default: nil,
    doc: "ISO weekday 1..7; default: Settings `week_start_day`"

  attr :today, :any, default: nil, doc: "a `Date`; default: today in the site time zone"

  attr :html, :map,
    default: %{},
    doc:
      "extra HTML attributes as a map, merged into `rest` — for a wrapper that already holds them (`<.input type=\"date\">`); passing them this way, not as a `{...}` spread, keeps LiveView's change tracking"

  attr :rest, :global,
    include:
      ~w(autofocus autocomplete disabled form readonly required step list onkeydown style title onfocus onblur onkeyup oninput)

  def date_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, field_errors(field))
    |> assign(:name, assigns.name || field.name)
    |> assign(:value, if(assigns.value == nil, do: field.value, else: assigns.value))
    |> date_input()
  end

  def date_input(%{native: true} = assigns) do
    assigns = assign(assigns, :rest, Map.merge(assigns.rest, assigns.html))
    assigns = assign(assigns, :id, assigns.id || derive_id(assigns.name))
    assigns = assign(assigns, :iso, native_value(assigns.value))
    assigns = assign(assigns, :min_iso, iso_or_nil(assigns.min))
    assigns = assign(assigns, :max_iso, iso_or_nil(assigns.max))

    ~H"""
    <div :if={!@bare} phx-feedback-for={@name} class={@wrapper_class}>
      <label :if={@label && @label != ""} class="label mb-2" for={@id}>
        <span class="font-semibold">{@label}</span>
        <span :if={@rest[:required]} class="text-error ml-0.5" aria-hidden="true">*</span>
      </label>
      <input
        type="date"
        name={@name}
        id={@id}
        value={@iso}
        min={@min_iso}
        max={@max_iso}
        placeholder={@placeholder}
        class={[
          "input w-full transition-colors focus:input-primary",
          size_class(@size),
          @errors != [] && "input-error",
          @class
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    <input
      :if={@bare}
      type="date"
      name={@name}
      id={@id}
      value={@iso}
      min={@min_iso}
      max={@max_iso}
      placeholder={@placeholder}
      aria-label={@label}
      class={[
        "input transition-colors focus:input-primary",
        size_class(@size),
        @errors != [] && "input-error",
        @class
      ]}
      {@rest}
    />
    """
  end

  def date_input(assigns) do
    format = normalize_format(assigns.format || site_format())
    today = to_date(assigns.today) || UtilsDate.site_today()
    id = assigns.id || derive_id(assigns.name)

    {iso, text} = value_and_text(assigns.value, format)
    rest = Map.merge(assigns.rest, assigns.html)
    {value_rest, text_rest} = split_rest(rest)
    text_rest = text_rest |> text_defaults(format) |> bare_label(assigns)
    field_name = text_rest[:"aria-label"] || blank_to_nil(assigns.label)
    text_rest = describe_by(text_rest, id)

    assigns =
      assigns
      |> assign(:id, id)
      |> assign(:format, format)
      |> assign(:iso, iso)
      |> assign(:text, text)
      |> assign(:value_rest, value_rest)
      |> assign(:text_rest, text_rest)
      |> assign(:min_iso, iso_or_nil(assigns.min))
      |> assign(:max_iso, iso_or_nil(assigns.max))
      |> assign(:locale_tag, locale_tag(assigns.locale))
      |> assign(:cally_week_start, cally_week_start(assigns.week_start))
      |> assign(:today_iso, Date.to_iso8601(today))
      |> assign(
        :expected,
        gettext("Expected %{example}", example: UtilsDate.format_date(today, format))
      )
      |> assign(:range_message, range_message(assigns.min, assigns.max, format))
      |> assign(:placeholder, assigns.placeholder || pattern(format))
      |> assign(:disabled?, truthy?(rest[:disabled]))
      |> assign(:required?, truthy?(rest[:required]))
      |> assign(:field_name, field_name)
      |> assign(:readonly?, truthy?(rest[:readonly]))

    assigns =
      assigns
      |> assign(:show_clear?, show_clear?(assigns))
      |> assign(:aria_label, assigns.field_name || gettext("Calendar"))
      |> assign(:open_label, open_label(assigns.field_name))
      |> assign(:clear_label, clear_label(assigns.field_name))

    ~H"""
    <div :if={!@bare} phx-feedback-for={@name} class={@wrapper_class}>
      <label :if={@label && @label != ""} class="label mb-2" for={@id}>
        <span class="font-semibold">{@label}</span>
        <span :if={@required?} class="text-error ml-0.5" aria-hidden="true">*</span>
      </label>
      <.control
        id={@id}
        name={@name}
        text={@text}
        iso={@iso}
        format={@format}
        locale_tag={@locale_tag}
        cally_week_start={@cally_week_start}
        min_iso={@min_iso}
        max_iso={@max_iso}
        today_iso={@today_iso}
        expected={@expected}
        range_message={@range_message}
        placeholder={@placeholder}
        errors={@errors}
        size={@size}
        class={@class}
        bare={false}
        wrapper_class={nil}
        text_rest={@text_rest}
        value_rest={@value_rest}
        disabled={@disabled?}
        readonly={@readonly?}
        required={@required?}
        show_clear={@show_clear?}
        aria_label={@aria_label}
        field_name={@field_name}
        open_label={@open_label}
        clear_label={@clear_label}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    <.control
      :if={@bare}
      id={@id}
      name={@name}
      text={@text}
      iso={@iso}
      format={@format}
      locale_tag={@locale_tag}
      cally_week_start={@cally_week_start}
      min_iso={@min_iso}
      max_iso={@max_iso}
      today_iso={@today_iso}
      expected={@expected}
      range_message={@range_message}
      placeholder={@placeholder}
      errors={@errors}
      size={@size}
      class={@class}
      bare={true}
      wrapper_class={@wrapper_class}
      text_rest={@text_rest}
      value_rest={@value_rest}
      disabled={@disabled?}
      readonly={@readonly?}
      required={@required?}
      show_clear={@show_clear?}
      aria_label={@aria_label}
      field_name={@field_name}
      open_label={@open_label}
      clear_label={@clear_label}
    />
    """
  end

  # The hook element: visible text, the value element, ✕ and the calendar button.
  #
  # As rendered it is a plain native date input (the value element, named, ISO
  # value) with the rest `hidden`: that is what a page with no LiveView submits
  # and shows. The hook sets `data-enhanced` on the wrapper, which flips the
  # roles through the `group-data-[enhanced]/pk-date:` classes.
  defp control(assigns) do
    assigns = assign(assigns, :value_enhanced, @value_enhanced)

    ~H"""
    <div
      id={"#{@id}-wrap"}
      phx-hook="PkDateInput"
      data-format={@format}
      data-locale={@locale_tag}
      data-week-start={@cally_week_start}
      data-min={@min_iso}
      data-max={@max_iso}
      data-today={@today_iso}
      data-expected={@expected}
      data-range-message={@range_message}
      data-required={@required && "true"}
      data-clearable={@show_clear && "true"}
      class={["group/pk-date relative", @bare && "inline-block", @bare && @wrapper_class]}
    >
      <input
        type="text"
        id={@id}
        value={@text}
        placeholder={@placeholder}
        data-date-text
        data-has-errors={@errors != [] && "true"}
        aria-invalid={@errors != [] && "true"}
        readonly={@readonly}
        disabled={@disabled}
        class={[
          "input hidden transition-colors focus:input-primary group-data-[enhanced]/pk-date:inline-flex",
          !@bare && "w-full",
          size_class(@size),
          buttons_padding(@size, @show_clear),
          @errors != [] && "input-error",
          @class
        ]}
        {@text_rest}
      />
      <input
        type="date"
        id={"#{@id}-value"}
        name={@name}
        value={@iso}
        min={@min_iso}
        max={@max_iso}
        required={@required}
        readonly={@readonly}
        disabled={@disabled}
        aria-label={@field_name}
        data-date-value
        class={[
          "input transition-colors focus:input-primary",
          !@bare && "w-full",
          size_class(@size),
          @errors != [] && "input-error",
          @class,
          @value_enhanced
        ]}
        {@value_rest}
      />
      <div class="absolute inset-y-0 right-1 hidden items-center gap-0.5 group-data-[enhanced]/pk-date:flex">
        <button
          :if={@show_clear}
          type="button"
          tabindex="-1"
          data-clear
          aria-label={@clear_label}
          class={["btn btn-ghost btn-circle btn-xs", @text == "" && "hidden"]}
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
        <button
          :if={!@disabled and !@readonly}
          type="button"
          tabindex="0"
          data-open
          aria-haspopup="dialog"
          aria-expanded="false"
          aria-controls={"#{@id}-popup"}
          aria-label={@open_label}
          class="btn btn-ghost btn-circle btn-xs"
        >
          <.icon name="hero-calendar" class="size-4" />
        </button>
      </div>
      <%!-- Where a rejected entry is said: a live region the text input points
           at. `phx-update="ignore"` keeps a patch from clearing and re-filling
           it (a screen reader would announce it again); the hook owns its text. --%>
      <span
        id={"#{@id}-hint"}
        role="status"
        phx-update="ignore"
        data-date-hint
        class="pointer-events-none absolute left-0 top-full z-10 mt-1 w-max max-w-xs rounded text-xs text-error not-empty:bg-base-100 not-empty:px-1 not-empty:shadow-sm"
      ></span>
      <%!-- The calendar. The template carries the server's strings; the hook
           clones it into the popup on the first open, after Cally has loaded.
           LiveView does not patch inside a <template>, so nothing that changes
           with the field (Today's `disabled`, whether Clear shows) is rendered
           here: the hook decides both from the wrapper's `data-*` on each open.
           The popup is `phx-update="ignore"`: LiveView must not strip what the
           hook builds in it. daisyUI's `.cally` styles <calendar-date>. --%>
      <template :if={!@disabled and !@readonly} data-popup-template>
        <calendar-date class="cally">
          <span slot="previous" class="flex items-center">
            <.icon name="hero-chevron-left" class="size-4" />
            <span class="sr-only">{gettext("Previous month")}</span>
          </span>
          <span slot="next" class="flex items-center">
            <.icon name="hero-chevron-right" class="size-4" />
            <span class="sr-only">{gettext("Next month")}</span>
          </span>
          <calendar-month></calendar-month>
        </calendar-date>
        <div class="flex items-center justify-between gap-2 border-t border-base-300 pt-2">
          <button type="button" data-popup-today class="btn btn-ghost btn-xs">
            {gettext("Today")}
          </button>
          <button type="button" data-popup-clear class="btn btn-ghost btn-xs hidden">
            {gettext("Clear")}
          </button>
        </div>
      </template>
      <div
        :if={!@disabled and !@readonly}
        id={"#{@id}-popup"}
        popover="manual"
        role="dialog"
        aria-label={@aria_label}
        phx-update="ignore"
        data-popup
        class="inset-auto m-0 rounded-box border border-base-300 bg-base-100 p-2 text-base-content shadow-lg"
      >
      </div>
    </div>
    """
  end

  defp show_clear?(assigns),
    do: not (assigns.disabled? or assigns.required? or assigns.readonly?)

  defp size_class("xs"), do: "input-xs"
  defp size_class("sm"), do: "input-sm"
  defp size_class(_), do: nil

  # Room for the buttons: the calendar one always, ✕ when there is one.
  defp buttons_padding("xs", true), do: "pr-12"
  defp buttons_padding("xs", false), do: "pr-7"
  defp buttons_padding(_, true), do: "pr-14"
  defp buttons_padding(_, false), do: "pr-9"

  # What to say about a date that parses but lies outside min/max.
  defp range_message(min, max, format) do
    min = to_date(min)
    max = to_date(max)
    fmt = &UtilsDate.format_date(&1, format)

    cond do
      min && max ->
        gettext("Pick a date between %{min} and %{max}", min: fmt.(min), max: fmt.(max))

      min ->
        gettext("Pick a date on or after %{min}", min: fmt.(min))

      max ->
        gettext("Pick a date on or before %{max}", max: fmt.(max))

      true ->
        nil
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # What the visible input gets unless the caller says otherwise: written once,
  # so a caller's `autocomplete`/`inputmode` is not a second attribute that the
  # browser then ignores.
  defp text_defaults(text_rest, format) do
    text_rest
    |> Map.put_new(:autocomplete, "off")
    |> Map.put_new(:inputmode, if(format == "F j, Y", do: "text", else: "numeric"))
  end

  defp bare_label(text_rest, %{bare: true, label: label})
       when is_binary(label) and label != "" do
    Map.put_new(text_rest, :"aria-label", label)
  end

  defp bare_label(text_rest, _assigns), do: text_rest

  defp open_label(nil), do: gettext("Open calendar")
  defp open_label(name), do: gettext("Open calendar for %{name}", name: name)

  defp clear_label(nil), do: gettext("Clear date")
  defp clear_label(name), do: gettext("Clear date for %{name}", name: name)

  # The visible input points at the rejection hint, after any description the
  # caller already gave it.
  defp describe_by(text_rest, id) do
    hint = "#{id}-hint"

    Map.update(text_rest, :"aria-describedby", hint, fn given ->
      [given, hint] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
    end)
  end

  defp split_rest(rest) do
    rest = Map.drop(rest, @dropped_rest)
    {value, text} = Enum.split_with(rest, fn {key, _} -> value_rest?(key) end)

    # `form="…"` goes to both: the value element is the one submitted, the
    # visible input is where Enter is pressed. `required` and `readonly` are
    # set on the elements by the markup, `disabled` on both.
    text = text |> Map.new() |> Map.drop([:disabled, :required, :readonly])
    text = if rest[:form], do: Map.put(text, :form, rest[:form]), else: text

    # `phx-target` and `phx-value-*` are read from the element that fires the
    # event, so both elements carry them.
    shared = Map.filter(rest, fn {key, _} -> shared_rest?(key) end)
    # `autofocus` also sits on the value element: it is the one displayed on a
    # page where no hook runs (the hook then moves the focus to the text).
    value = if rest[:autofocus], do: [{:autofocus, rest[:autofocus]} | value], else: value
    {Map.merge(Map.new(value), shared), Map.merge(text, shared)}
  end

  defp shared_rest?(:"phx-target"), do: true
  defp shared_rest?(key), do: String.starts_with?(to_string(key), "phx-value-")

  defp value_rest?(key) when key in @value_rest, do: true
  defp value_rest?(key), do: String.starts_with?(to_string(key), "data-")

  defp truthy?(value), do: value not in [nil, false, "false"]

  defp derive_id(name) do
    case name |> to_string() |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-") do
      "" -> "date-input"
      id -> id
    end
  end

  @doc false
  def normalize_format(format) when format in @formats, do: format
  def normalize_format(_format), do: "Y-m-d"

  @doc false
  def site_format, do: Settings.get_setting_cached("date_format", "Y-m-d")

  defp pattern("Y-m-d"), do: "yyyy-mm-dd"
  defp pattern("m/d/Y"), do: "mm/dd/yyyy"
  defp pattern("d/m/Y"), do: "dd/mm/yyyy"
  defp pattern("d.m.Y"), do: "dd.mm.yyyy"
  defp pattern("d-m-Y"), do: "dd-mm-yyyy"
  defp pattern("F j, Y"), do: "Month d, yyyy"

  # `{value_element_value, visible_text}`: a date is shown formatted; anything
  # else is echoed as given in both, so what the server sent is never rewritten.
  defp value_and_text(value, format) do
    case to_date(value) do
      %Date{} = date -> {Date.to_iso8601(date), UtilsDate.format_date(date, format)}
      nil when value in [nil, ""] -> {"", ""}
      nil when is_binary(value) -> {value, value}
      nil -> {"", ""}
    end
  end

  defp native_value(value) do
    case to_date(value) do
      %Date{} = date -> Date.to_iso8601(date)
      nil when is_binary(value) -> value
      nil -> ""
    end
  end

  defp iso_or_nil(value) do
    case to_date(value) do
      %Date{} = date -> Date.to_iso8601(date)
      nil -> nil
    end
  end

  @doc false
  def to_date(%Date{} = date), do: date
  def to_date(%DateTime{} = dt), do: UtilsDate.to_site_date(dt)
  def to_date(%NaiveDateTime{} = naive), do: UtilsDate.to_site_date(naive)

  def to_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  def to_date(_value), do: nil

  # Intl.DateTimeFormat throws on a malformed tag, which would leave the
  # calendar blank: `_` → `-`, anything that is not a tag → `en`.
  defp locale_tag(locale) do
    tag = String.replace(locale || Gettext.get_locale(PhoenixKitWeb.Gettext), "_", "-")
    if Regex.match?(~r/^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/, tag), do: tag, else: "en"
  end

  # Settings keeps ISO weekdays as "1".."7" (Monday = 1); Cally counts
  # Sunday as 0.
  defp cally_week_start(week_start) do
    week_start = week_start || Settings.get_setting_cached("week_start_day", "1")

    case Integer.parse(to_string(week_start)) do
      {n, ""} when n in 1..7 -> rem(n, 7)
      _ -> 1
    end
  end
end
