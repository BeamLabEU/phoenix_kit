defmodule PhoenixKitWeb.Components.Core.DecimalInput do
  @moduledoc """
  A form control for numbers a person types — quantities, prices, weights,
  lengths — where a comma and a dot must both work and nothing may be
  rounded.

  Why not `<.input type="number">`: the browser owns a number control. Its
  decimal separator follows the page/element locale, so on a page with
  `lang="et"` a typed `2.5` can be swallowed (the field submits `""`), and
  on `lang="en"` a typed `2,5` is; `step` makes any other precision
  invalid and silently blocks a `phx-submit`; the spinner arrows steal
  wheel and arrow-key events. This component renders a plain
  `<input type="text" inputmode="decimal">`: the mobile keyboard still
  opens on digits, and the server decides what the text means with
  `PhoenixKit.Utils.Number.parse_decimal/2` — comma or dot, grouping
  spaces, sign, and nothing else.

  Otherwise it is `<.input>`: a `Phoenix.HTML.FormField` or raw
  `name`/`value`, `label`, gettext-translated `errors`, `class` on the
  control and `wrapper_class` on the `phx-feedback-for` wrapper, the
  required marker, and daisyUI 5 styling.

  A zero clears itself on focus: a field showing `0` (or `0,00`, `0.0`)
  empties when it gains focus, so typing `1` gives `1` and not `10` (the
  caret used to land after the zero). Leaving the field still empty puts
  the zero back — nothing was entered, nothing changes — and so does
  pressing Enter in it, so an implicit submit sends the zero, not `""`.
  Typing anything keeps what was typed; typing and then erasing it all
  puts the zero back and fires an `input` event, so a `phx-change` form
  hears the zero instead of keeping the `""` it last saw. A `readonly`
  field is left alone. The control only carries `data-pk-zero-clear`; the
  behaviour is listeners in `phoenix_kit.js` (no hook, so it works in any
  host app and on a page with no LiveView, and no inline handler, which a
  Content-Security-Policy without `'unsafe-inline'` would block). The
  remembered zero lives in a property on the element, not a `data-`
  attribute: LiveView strips attributes the server did not render from a
  focused input on every patch.

  A host's own `onfocus`/`onblur`/`onkeydown` are kept as the host wrote
  them and run right after the component's (the kit listens in the capture
  phase). `phx-focus` fires on `focusin`, after the clear, so it sees the
  emptied field; `phx-blur` fires on `focusout`, after the restore, so it
  sees the zero again.

  `bare` renders the control alone, for a host that sets it inside a group
  of its own — a daisyUI `join` with a unit button, a table cell: the
  wrapper `<div>` would sit between `.join` and its `.join-item`. It keeps
  everything that makes it a decimal control (text, decimal keyboard, no
  browser autofill, the zero handlers) and drops what the host draws
  itself: label, unit suffix, error list and the full width. A `label`
  given to a bare control becomes its `aria-label` (unless the host passes
  one), so the control keeps an accessible name; with neither, pass
  `aria-label`.
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [field_errors: 1]

  alias PhoenixKit.Utils.Number

  @doc """
  Renders a free-decimal text control.

  The value is shown normalized when it is a number (`Decimal.new("2.500")`
  → `2.5`, `1E+3` → `1000`) and echoed back unchanged when it is a binary,
  so the text a person typed survives a re-render exactly as typed — a
  `2,5` does not turn into `2.5` under their cursor.

  ## Examples

      <%!-- FormField binding: name, id, value, errors derived --%>
      <.decimal_input field={@form[:quantity]} label="Quantity" />

      <%!-- Unit suffix inside the field --%>
      <.decimal_input field={@form[:weight]} label="Weight" unit="kg" />

      <%!-- The control alone, as a join item next to the host's own unit --%>
      <div class="join">
        <.decimal_input bare name="qty" value={@qty} class="join-item w-20 text-center" />
        <span class="btn join-item pointer-events-none">kg</span>
      </div>

      <%!-- Raw name/value for a row in a list, small and right-aligned --%>
      <.decimal_input
        id={"row-\#{row.id}-qty"}
        name="qty"
        value={row.qty}
        class="input-sm text-right"
        phx-debounce="400"
        phx-blur="commit_qty"
        phx-value-row_id={row.id}
      />

  Parse the submitted text with `PhoenixKit.Utils.Number.parse_decimal/2`:

      case Number.parse_decimal(params["qty"], min: 0) do
        {:ok, qty} -> ...
        {:error, :empty} -> ...
        {:error, _reason} -> ...
      end
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any, default: nil

  attr :unit, :string,
    default: nil,
    doc: "a unit suffix rendered inside the field, after the number (kg, m, pcs)"

  attr :class, :any,
    default: nil,
    doc:
      "extra classes merged onto the control — daisyUI modifiers like `input-sm`, `input-primary`, or `text-right`"

  attr :wrapper_class, :any,
    default: nil,
    doc: "extra classes for the outer `<div phx-feedback-for>` wrapper"

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:quantity]"

  attr :errors, :list, default: []

  attr :bare, :boolean,
    default: false,
    doc:
      "render the `<input>` alone — no wrapper, label, unit or error list, no `w-full` — for a host that places it in a group of its own (a daisyUI `join`, a table cell); `errors` still mark it `input-error`, and a `label` becomes the control's `aria-label` unless one is passed"

  attr :rest, :global,
    include: ~w(autofocus disabled form maxlength placeholder readonly required size)

  def decimal_input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, field_errors(field))
    |> assign_new(:name, fn -> field.name end)
    |> assign(:value, if(assigns.value == nil, do: field.value, else: assigns.value))
    |> decimal_input()
  end

  def decimal_input(assigns) do
    # Clearing a zero on focus (and bringing it back) is `data-pk-zero-clear`
    # in phoenix_kit.js, not inline handlers: a Content-Security-Policy
    # without 'unsafe-inline' blocks those. A host's own onfocus / onblur /
    # onkeydown still ride along in @rest and run after the kit's.
    assigns = assign(assigns, :text, Number.format_decimal(assigns.value))

    layout(assigns)
  end

  # One root per layout: two sibling `:if` roots would leave the whitespace
  # between them in every render.
  defp layout(%{bare: true} = assigns) do
    # The label has nowhere to render; it still names the control.
    assigns =
      if assigns.label in [nil, ""] or Map.has_key?(assigns.rest, :"aria-label"),
        do: assigns,
        else: assign(assigns, :rest, Map.put(assigns.rest, :"aria-label", assigns.label))

    ~H"""
    <.control
      name={@name}
      id={@id}
      text={@text}
      rest={@rest}
      class={["input transition-colors focus:input-primary", @errors != [] && "input-error", @class]}
    />
    """
  end

  defp layout(assigns) do
    ~H"""
    <div phx-feedback-for={@name} class={@wrapper_class}>
      <label :if={@label && @label != ""} class="label mb-2" for={@id}>
        <span class="font-semibold">{@label}</span>
        <span :if={@rest[:required]} class="text-error ml-0.5" aria-hidden="true">*</span>
      </label>
      <%!-- Unit variant: daisyUI 5 puts the `input` class on a <label>
           wrapper so the suffix sits inside the field; the wrapper never
           receives focus, hence `focus-within`. --%>
      <label
        :if={@unit}
        class={[
          "input w-full transition-colors focus-within:input-primary",
          @errors != [] && "input-error",
          @class
        ]}
      >
        <.control
          name={@name}
          id={@id}
          text={@text}
          rest={@rest}
          class="grow min-w-0"
        />
        <span class="opacity-60 select-none" aria-hidden="true">{@unit}</span>
      </label>
      <.control
        :if={!@unit}
        name={@name}
        id={@id}
        text={@text}
        rest={@rest}
        class={[
          "input w-full transition-colors focus:input-primary",
          @errors != [] && "input-error",
          @class
        ]}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # The control itself, the same in every layout.
  defp control(assigns) do
    ~H"""
    <input
      type="text"
      inputmode="decimal"
      autocomplete="off"
      name={@name}
      id={@id}
      value={@text}
      class={@class}
      data-pk-zero-clear
      {@rest}
    />
    """
  end
end
