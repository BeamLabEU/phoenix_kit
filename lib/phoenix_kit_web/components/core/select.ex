defmodule PhoenixKitWeb.Components.Core.Select do
  @moduledoc """
  Provides a default select UI component.
  """
  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.FormFieldLabel, only: [label: 1]
  import PhoenixKitWeb.Components.Core.FormFieldError, only: [error: 1]

  attr :field, Phoenix.HTML.FormField

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :options, :list
  attr :multiple, :boolean, default: false
  attr :prompt, :string, default: nil

  attr :errors, :list, default: []

  attr :rest, :global,
    include: ~w(autocomplete cols maxlength disabled placeholder readonly required rows)

  def select(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> select()
  end

  def select(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <.label :if={@label && @label != ""} for={@id} class="block mb-2">
        {@label}
      </.label>

      <label class={[
        "select w-full",
        @errors != [] && "select-error"
      ]}>
        <select
          id={@id}
          name={@name}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>

      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end
end
