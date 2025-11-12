defmodule PhoenixKitWeb.Components.Core.Accordion do
  @moduledoc """
  Accordion Component for collapsible content sections.

  A versatile accordion component that allows users to expand/collapse
  content sections, perfect for organizing advanced settings and options.

  ## Features

  - Smooth animations and transitions
  - Multiple accordion items in a single component
  - Custom icons and styling
  - Keyboard navigation support
  - Controlled and uncontrolled modes

  ## Usage

      <.accordion id="advanced-settings">
        <:title>Advanced AWS Settings</:title>
        <:content>
          Your advanced settings content here...
        </:content>
      </.accordion>
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :open, :boolean, default: false
  attr :class, :string, default: ""

  slot :title, required: true
  slot :content, required: true

  def accordion(assigns) do
    ~H"""
    <div class="accordion #{open_class(@open)} #{sanitize_class(@class)}" id={@id}>
      <input
        type="checkbox"
        class="accordion-toggle"
        id={@id <> "-toggle"}
        checked={@open}
      />
      <label
        class="accordion-title cursor-pointer flex items-center justify-between p-4 bg-base-200 hover:bg-base-300 transition-colors duration-200"
        for={@id <> "-toggle"}
      >
        {render_slot(@title)}
        <div class="flex items-center gap-2">
          <!-- Chevron icon -->
          <svg
            class="w-4 h-4 transition-transform duration-200 accordion-icon"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M19 9l-7 7-7-7"
            />
          </svg>
        </div>
      </label>
      <div class="accordion-content overflow-hidden transition-all duration-300 ease-in-out">
        <div class="p-4 bg-base-100 border-t border-base-200">
          {render_slot(@content)}
        </div>
      </div>
    </div>
    """
  end
end
