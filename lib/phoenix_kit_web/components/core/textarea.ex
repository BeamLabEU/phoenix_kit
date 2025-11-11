defmodule PhoenixKitWeb.Components.Core.Textarea do
  @moduledoc """
  Provides a default textarea UI component.
  """
  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.FormFieldLabel, only: [label: 1]
  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]

  attr :field, Phoenix.HTML.FormField

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :errors, :list, default: []

  attr :rest, :global,
    include: ~w(autocomplete cols maxlength disabled placeholder readonly required rows)

  def textarea(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> textarea()
  end

  def textarea(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <.label :if={@label && @label != ""} for={@id} class="label mb-2">
        {@label}
      </.label>

      <textarea
        id={@id}
        name={@name}
        class={[
          "textarea textarea-bordered min-h-[6rem] w-full focus:input-primary",
          @errors != [] && "textarea-error"
        ]}
        {@rest}
      ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end
end
