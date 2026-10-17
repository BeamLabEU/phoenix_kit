defmodule PhoenixKitWeb.Components.Core.Input do
  @moduledoc """
  Provides inputs UI components.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, ID, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values:
      ~w(color date datetime-local email file hidden month number password range search tel text time url week)

  attr :class, :any,
    default: nil,
    doc:
      "extra classes merged onto the `<input>` element — use this for daisyUI modifiers like `input-sm`, `input-primary`, or project-specific focus styles. Matches the Phoenix 1.7 generator convention."

  attr :wrapper_class, :any,
    default: nil,
    doc: "extra classes for the outer `<div phx-feedback-for>` wrapper"

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []

  attr :native, :boolean,
    default: false,
    doc:
      "`type=\"date\"` only: render the browser's own date input instead of `date_input/1` (a page with no LiveView). Host-wide: `config :phoenix_kit, native_date_inputs: true`"

  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  slot :inner_block

  slot :icon,
    doc:
      "an icon rendered *inside* the field (daisyUI 5 `<label class=\"input\">` wrapper). Size it with `h-[1em] w-[1em] opacity-50` to match daisyUI."

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  # `type="date"` is a `date_input/1` (text in the site's date format, with a
  # clear button and a calendar) unless the call or the host opts out.
  def input(%{type: "date"} = assigns) do
    if assigns[:native] || Application.get_env(:phoenix_kit, :native_date_inputs, false) do
      native_input(assigns)
    else
      {own, rest} = Map.split(assigns.rest, [:min, :max, :placeholder])

      assigns =
        assigns
        |> assign(:date_rest, Map.delete(rest, :size))
        |> assign(:date_attrs, own)
        |> assign_new(:value, fn -> nil end)

      ~H"""
      <PhoenixKitWeb.Components.Core.DateInput.date_input
        id={@id}
        name={@name}
        label={@label}
        value={@value}
        errors={@errors}
        class={@class}
        wrapper_class={@wrapper_class}
        min={@date_attrs[:min]}
        max={@date_attrs[:max]}
        placeholder={@date_attrs[:placeholder]}
        html={@date_rest}
      />
      """
    end
  end

  def input(assigns), do: native_input(assigns)

  defp native_input(assigns) do
    ~H"""
    <div phx-feedback-for={@name} class={@wrapper_class}>
      <label :if={@label && @label != ""} class="label mb-2" for={@id}>
        <span class="font-semibold">{@label}</span>
        <%!-- Required marker, rendered by the component so callers don't have to
             append " *" to the label string — a plain string cannot carry the
             error colour, and the hand-rolled markup this component replaced did. --%>
        <span :if={@rest[:required]} class="text-error ml-0.5" aria-hidden="true">*</span>
      </label>
      <%!-- Icon-inside variant: daisyUI 5 puts the `input` class on a <label>
           wrapper so the icon sits inside the field. Focus color comes from
           `focus-within` since the wrapping label never receives focus. --%>
      <label
        :if={@icon != []}
        class={[
          "input w-full transition-colors focus-within:input-primary",
          @errors != [] && "input-error",
          @class
        ]}
      >
        {render_slot(@icon)}
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class="grow"
          {@rest}
        />
      </label>
      <input
        :if={@icon == []}
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "input w-full transition-colors focus:input-primary",
          @errors != [] && "input-error",
          @class
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(PhoenixKitWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(PhoenixKitWeb.Gettext, "errors", msg, opts)
    end
  end

  def translate_error(msg), do: msg
end
