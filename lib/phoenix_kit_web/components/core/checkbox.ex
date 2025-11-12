defmodule PhoenixKitWeb.Components.Core.Checkbox do
  @moduledoc """
  Provides a default checkbox UI component.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Form
  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]

  @doc """
  Renders a checkbox.
  """
  attr :field, Phoenix.HTML.FormField

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :errors, :list, default: []
  attr :checked, :boolean, default: false

  attr :rest, :global, include: ~w(readonly required)

  slot :inner_block

  def checkbox(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    checked = Form.normalize_value("checkbox", field.value)

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:checked, fn -> checked end)
    |> checkbox()
  end

  def checkbox(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <label class="flex items-center gap-4 text-sm leading-6 text-base-content">
        <input type="hidden" name={@name} value="false" />

        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="checkbox checkbox-primary"
          {@rest}
        />

        <span class="select-none cursor-pointer">
          {@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end
end
