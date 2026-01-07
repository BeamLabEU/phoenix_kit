defmodule PhoenixKit.Modules.Publishing.Components.CTA do
  @moduledoc """
  Call-to-action button component.
  """
  use Phoenix.Component

  attr :content, :string, required: true
  attr :attributes, :map, default: %{}
  attr :variant, :string, default: "default"

  def render(assigns) do
    is_primary = Map.get(assigns.attributes, "primary", "false") == "true"
    action = Map.get(assigns.attributes, "action", "#")

    assigns =
      assigns
      |> assign(:is_primary, is_primary)
      |> assign(:action, action)

    ~H"""
    <a
      href={@action}
      class={[
        "btn inline-block px-8 py-3 rounded-lg font-semibold transition-all",
        if(@is_primary,
          do: "btn-primary text-primary-content",
          else: "btn-outline"
        )
      ]}
    >
      {@content}
    </a>
    """
  end
end
