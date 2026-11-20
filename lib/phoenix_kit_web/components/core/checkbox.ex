defmodule PhoenixKitWeb.Components.Core.Checkbox do
  @moduledoc """
  Provides a default checkbox UI component.

  daisyUI's `.checkbox` class only styles the `<input>` — it does not wrap it
  in a `<label>`, so a hand-rolled checkbox + adjacent text is easy to get
  wrong (clicking the text does nothing). This component always renders the
  correct `<label><input/><span>...</span></label>` structure, plus the
  hidden-false fallback input so an unchecked box still submits a value.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Form
  alias PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]

  @doc """
  Renders a checkbox.

  ## Examples

      <.checkbox field={@form[:remember_me]} label="Keep me logged in" />

      <.checkbox
        name="settings[allow_registration]"
        checked={@settings["allow_registration"] == "true"}
        label="Anyone can register"
      />

      <%!-- Rich label content (badges, icons) via the default slot —
           overrides the `label` attr when given: --%>
      <.checkbox name="roles[admin]" checked={...} disabled={owner_role?}>
        <.role_badge role={role} size={:sm} /> {role.name}
        <:description>Grants full administrative access</:description>
      </.checkbox>

      <%!-- Locked (but still submitted) while a parent switch is off — use
           `wrapper_class`, not `disabled`, so the field's real stored value
           keeps submitting instead of collapsing to the hidden "false"
           fallback: --%>
      <.checkbox
        name="settings[oauth_google_enabled]"
        checked={@settings["oauth_google_enabled"] == "true"}
        label="Google Sign-In"
        wrapper_class={!@settings["oauth_enabled"] == "true" && "pointer-events-none"}
      />

      <%!-- An on/off switch: daisyUI's `.toggle` instead of `.checkbox`, the
           same label/hidden-false structure. `class` still merges (size,
           colour). --%>
      <.checkbox variant="toggle" name="feature[gate]" checked={@on?} label="Enabled" />
  """
  attr :field, Phoenix.HTML.FormField

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  # nil (the default): a field-bound checkbox shows its field's errors
  # (`Core.Input.field_errors/1`). A list given, `[]` included, is used as is.
  attr :errors, :list, default: nil
  # nil (the default) means "derive from the field's value". A non-nil
  # default would defeat that: attr defaults are materialized into assigns
  # before the component runs, so `assign_new` in the field clause would
  # never fire and a field-bound checkbox would ALWAYS render unchecked.
  attr :checked, :boolean, default: nil
  attr :disabled, :boolean, default: false

  attr :value, :string,
    default: "true",
    doc: "what a ticked box submits — a box in a `name[]` group submits its own item"

  attr :unchecked_value, :any,
    default: "false",
    doc:
      "what the hidden fallback submits for an unticked box; `nil` renders no fallback (a box in a `name[]` group, where an unticked box submits nothing)"

  attr :variant, :string,
    default: "checkbox",
    values: ~w(checkbox toggle),
    doc: "`toggle` renders daisyUI's switch (`.toggle`) instead of a square box"

  attr :title, :string,
    default: nil,
    doc:
      "tooltip on the wrapping `<label>` (covers the box and the text), e.g. explaining why a checkbox is disabled"

  attr :class, :any,
    default: nil,
    doc:
      "extra classes merged onto the `<input type=\"checkbox\">` (e.g. `checkbox-sm`, `checkbox-accent`)"

  attr :wrapper_class, :any,
    default: nil,
    doc:
      "extra classes merged onto the wrapping `<label>` (e.g. spacing like `mb-3`, or `pointer-events-none` to lock the whole control — box and text — without excluding it from form submission the way `disabled` would)."

  attr :rest, :global, include: ~w(readonly required)

  slot :inner_block,
    doc: "Rich label content (badges, icons, multiple elements). Overrides `label` when given."

  slot :description, doc: "Secondary helper text rendered below the label."

  def checkbox(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    derived = Form.normalize_value("checkbox", field.value)

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign_new(:name, fn -> field.name end)
    |> assign(:checked, if(is_nil(assigns.checked), do: derived, else: assigns.checked))
    # The field's own errors, unless the caller passed a list.
    |> assign(:errors, assigns.errors || Input.field_errors(field))
    |> checkbox()
  end

  def checkbox(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <% has_description? = @description != [] %>
      <label
        title={@title}
        class={[
          "flex gap-2.5 text-sm leading-6 text-base-content",
          (has_description? && "items-start") || "items-center",
          (@disabled && "cursor-not-allowed opacity-70") || "cursor-pointer",
          @wrapper_class
        ]}
      >
        <input :if={@unchecked_value} type="hidden" name={@name} value={@unchecked_value} />

        <%!-- With a description the label is items-start, so the box must
             center itself against the FIRST text line. The line box is 24px
             (text-sm leading-6) — an h-6 flex wrapper centers any checkbox
             size in it. The old `mt-0.5` nudge was tuned for checkbox-sm and
             sat the default 24px box 2px low ("the checkbox and the text are
             kind of not centered"). --%>
        <span class={["flex items-center shrink-0", has_description? && "h-6"]}>
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value={@value}
            checked={@checked}
            disabled={@disabled}
            class={[
              (@variant == "toggle" && "toggle toggle-primary") || "checkbox checkbox-primary",
              @class
            ]}
            {@rest}
          />
        </span>

        <span class="select-none">
          <span class={has_description? && "font-medium"}>
            <%!-- Render the label attr AND the default slot, in that order —
                 never either/or. The old `if @inner_block != []` guard read as
                 "rich content replaces the label", but HEEx assigns the
                 component BODY to the default slot even when that body holds
                 nothing except named-slot tags and their surrounding
                 whitespace — so every `label=` + `<:description>` caller got a
                 whitespace-only inner_block that silently replaced the label
                 with a blank. Whitespace-only slot output collapses in HTML,
                 so label-only, rich-only and label+description callers all
                 render what they wrote, and a caller providing both label and
                 body text gets both instead of losing the label. --%>
            {@label}
            {render_slot(@inner_block)}
          </span>
          <span :if={has_description?} class="block text-xs text-base-content/60">
            {render_slot(@description)}
          </span>
        </span>
      </label>
      <.error :for={msg <- @errors || []}>{msg}</.error>
    </div>
    """
  end
end
