defmodule PhoenixKitWeb.Components.Core.Modal do
  @moduledoc """
  A reusable modal dialog component with robust features.

  Features:
  - Escape key to close
  - Click backdrop to close
  - Scrollable content area for long content
  - Customizable width and height
  - Title, content, and action slots
  - Accessible with proper ARIA attributes

  ## Examples

  Basic usage:
      <.modal show={@show_modal} on_close="close_modal">
        <:title>Confirm Action</:title>
        <p>Are you sure you want to proceed?</p>
        <:actions>
          <button class="btn btn-ghost" phx-click="close_modal">Cancel</button>
          <button class="btn btn-primary" phx-click="confirm">Confirm</button>
        </:actions>
      </.modal>

  With icon in title:
      <.modal show={@show_modal} on_close="close_modal">
        <:title>
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 text-warning" />
          Warning
        </:title>
        <p>This action cannot be undone.</p>
        <:actions>
          <button class="btn btn-ghost" phx-click="close_modal">Cancel</button>
          <button class="btn btn-error" phx-click="delete">Delete</button>
        </:actions>
      </.modal>

  With scrollable content:
      <.modal show={@show_modal} on_close="close_modal" max_height="60vh">
        <:title>Long Content</:title>
        <div class="space-y-2">
          <%= for item <- @items do %>
            <div class="p-2 border rounded"><%= item.name %></div>
          <% end %>
        </div>
        <:actions>
          <button class="btn btn-primary" phx-click="close_modal">Done</button>
        </:actions>
      </.modal>
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  @doc """
  Renders a modal dialog.

  ## Attributes

  - `show` - Boolean to show/hide the modal (required)
  - `on_close` - Event name to send when modal should close (required)
  - `id` - Optional ID for the modal element
  - `max_width` - Maximum width class: "sm", "md", "lg", "xl", "2xl", "3xl", "4xl", "full" (default: "md")
  - `max_height` - Maximum height for content area, e.g., "60vh", "400px" (default: "70vh")
  - `class` - Additional CSS classes for the modal box
  - `backdrop_class` - Additional CSS classes for the backdrop
  - `closeable` - Whether the modal can be closed via backdrop/escape (default: true)

  ## Slots

  - `title` - Optional title slot, rendered in a header with proper styling
  - `inner_block` - Main content of the modal (required)
  - `actions` - Optional actions slot, rendered in footer with proper alignment
  """
  attr :show, :boolean, required: true
  attr :on_close, :string, required: true
  attr :id, :string, default: nil
  attr :max_width, :string, default: "md", values: ~w(sm md lg xl 2xl 3xl 4xl full)
  attr :max_height, :string, default: "70vh"
  attr :class, :string, default: ""
  attr :backdrop_class, :string, default: ""
  attr :closeable, :boolean, default: true

  slot :title
  slot :inner_block, required: true
  slot :actions

  def modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div
        id={@id}
        class="modal modal-open"
        role="dialog"
        aria-modal="true"
        aria-labelledby={@id && "#{@id}-title"}
        phx-window-keydown={@closeable && @on_close}
        phx-key={@closeable && "Escape"}
      >
        <div class={[
          "modal-box flex flex-col",
          max_width_class(@max_width),
          @class
        ]}>
          <%!-- Title --%>
          <%= if @title != [] do %>
            <h3
              id={@id && "#{@id}-title"}
              class="font-bold text-lg mb-4 flex items-center gap-2 flex-shrink-0"
            >
              {render_slot(@title)}
            </h3>
          <% end %>

          <%!-- Content with scrollability --%>
          <div
            class="flex-1 overflow-y-auto overscroll-contain"
            style={"max-height: #{@max_height}"}
          >
            {render_slot(@inner_block)}
          </div>

          <%!-- Actions --%>
          <%= if @actions != [] do %>
            <div class="modal-action flex-shrink-0 mt-4">
              {render_slot(@actions)}
            </div>
          <% end %>
        </div>

        <%!-- Backdrop --%>
        <div
          class={["modal-backdrop bg-base-content/50", @backdrop_class]}
          phx-click={@closeable && @on_close}
          aria-hidden="true"
        >
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Renders a confirmation modal with pre-styled warning/info messages.

  This is a specialized modal for confirmation dialogs that may display
  multiple warnings or informational messages before an action.

  ## Attributes

  - `show` - Boolean to show/hide the modal (required)
  - `on_confirm` - Event name when user confirms (required unless show_confirm is false)
  - `on_cancel` - Event name when user cancels (required)
  - `title` - Modal title text (default: "Confirm")
  - `title_icon` - Heroicon name for title (optional)
  - `title_icon_class` - CSS classes for title icon (default: "w-5 h-5 text-primary")
  - `confirm_text` - Text for confirm button (default: "Confirm")
  - `cancel_text` - Text for cancel button (default: "Cancel")
  - `confirm_class` - CSS classes for confirm button (default: "btn btn-primary")
  - `confirm_icon` - Heroicon name for confirm button (optional)
  - `messages` - List of message tuples: [{:warning | :info | :error | :success, "message"}, ...]
  - `prompt` - Optional prompt text shown after messages (default: "Do you want to continue?")
  - `max_messages` - Number of messages to show before scrolling (default: 5)
  - `confirm_disabled` - Disable the confirm button (default: false)
  - `loading` - Show loading spinner on confirm button (default: false)
  - `danger` - Shorthand for destructive action styling (default: false)
  - `show_confirm` - Whether to show the confirm button (default: true)
  - `closeable` - Whether modal can be closed via backdrop/escape (default: true)

  ## Slots

  - `inner_block` - Optional custom content to render after messages

  ## Examples

  Basic confirmation:
      <.confirm_modal
        show={@show_confirm}
        on_confirm="do_action"
        on_cancel="cancel_action"
        title="Confirm Delete"
        title_icon="hero-trash"
        messages={[{:warning, "This will delete all data"}]}
        confirm_text="Delete"
        danger={true}
      />

  With loading state:
      <.confirm_modal
        show={@show_confirm}
        on_confirm="save"
        on_cancel="cancel"
        loading={@saving}
        confirm_disabled={@saving}
      />

  Error state (confirm disabled):
      <.confirm_modal
        show={@show_error}
        on_confirm="retry"
        on_cancel="close"
        title="Error"
        title_icon="hero-x-circle"
        title_icon_class="w-5 h-5 text-error"
        messages={[{:error, "Something went wrong. Please try again."}]}
        confirm_disabled={true}
        confirm_text="Retry"
      />

  Info-only modal (no confirm button):
      <.confirm_modal
        show={@show_info}
        on_cancel="close"
        title="Information"
        title_icon="hero-information-circle"
        title_icon_class="w-5 h-5 text-info"
        messages={[{:info, "Your changes have been saved."}]}
        show_confirm={false}
        cancel_text="OK"
      />

  With custom content:
      <.confirm_modal
        show={@show_modal}
        on_confirm="confirm"
        on_cancel="cancel"
        title="Review Changes"
      >
        <div class="mt-2">
          <p>Custom content here...</p>
        </div>
      </.confirm_modal>
  """
  attr :show, :boolean, required: true
  attr :on_confirm, :string, default: nil
  attr :on_cancel, :string, required: true
  attr :title, :string, default: nil
  attr :title_icon, :string, default: nil
  attr :title_icon_class, :string, default: "w-5 h-5 text-primary"
  attr :confirm_text, :string, default: nil
  attr :cancel_text, :string, default: nil
  attr :confirm_class, :string, default: nil
  attr :confirm_icon, :string, default: nil
  attr :messages, :list, default: []
  attr :prompt, :string, default: nil
  attr :max_messages, :integer, default: 5
  attr :confirm_disabled, :boolean, default: false
  attr :loading, :boolean, default: false
  attr :danger, :boolean, default: false
  attr :show_confirm, :boolean, default: true
  attr :closeable, :boolean, default: true

  slot :inner_block

  def confirm_modal(assigns) do
    # Apply defaults with gettext and computed values
    assigns =
      assigns
      |> assign_new(:title_text, fn -> assigns[:title] || gettext("Confirm") end)
      |> assign_new(:confirm_button_text, fn -> assigns[:confirm_text] || gettext("Confirm") end)
      |> assign_new(:cancel_button_text, fn -> assigns[:cancel_text] || gettext("Cancel") end)
      |> assign_new(:prompt_text, fn -> assigns[:prompt] || gettext("Do you want to continue?") end)
      |> assign_new(:computed_confirm_class, fn ->
        cond do
          assigns[:confirm_class] -> assigns.confirm_class
          assigns[:danger] -> "btn btn-error"
          true -> "btn btn-primary"
        end
      end)
      |> assign_new(:computed_title_icon_class, fn ->
        cond do
          assigns[:title_icon_class] != "w-5 h-5 text-primary" -> assigns.title_icon_class
          assigns[:danger] -> "w-5 h-5 text-error"
          true -> "w-5 h-5 text-primary"
        end
      end)

    ~H"""
    <.modal
      show={@show}
      on_close={@on_cancel}
      max_width="md"
      max_height={if length(@messages) > @max_messages, do: "50vh", else: "70vh"}
      closeable={@closeable}
    >
      <:title>
        <%= if @title_icon do %>
          <.icon name={@title_icon} class={@computed_title_icon_class} />
        <% end %>
        {@title_text}
      </:title>

      <div class="space-y-3">
        <%!-- Messages --%>
        <%= if @messages != [] do %>
          <div class={[
            "space-y-2",
            length(@messages) > @max_messages && "overflow-y-auto max-h-48 pr-1"
          ]}>
            <%= for {type, message} <- @messages do %>
              <div class={[
                "flex items-start gap-2 p-3 rounded-lg border",
                message_styles(type)
              ]}>
                <.icon name={message_icon(type)} class={"w-5 h-5 flex-shrink-0 mt-0.5 #{message_icon_class(type)}"} />
                <p class="text-sm text-base-content">{message}</p>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Custom content slot --%>
        <%= if @inner_block != [] do %>
          {render_slot(@inner_block)}
        <% end %>

        <%!-- Prompt --%>
        <%= if @show_confirm do %>
          <p class="text-sm text-base-content/70 pt-2">
            {@prompt_text}
          </p>
        <% end %>
      </div>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click={@on_cancel}>
          {@cancel_button_text}
        </button>
        <%= if @show_confirm do %>
          <button
            type="button"
            class={[@computed_confirm_class, (@confirm_disabled || @loading) && "btn-disabled"]}
            phx-click={@on_confirm}
            disabled={@confirm_disabled || @loading}
          >
            <%= if @loading do %>
              <span class="loading loading-spinner loading-sm"></span>
            <% else %>
              <%= if @confirm_icon do %>
                <.icon name={@confirm_icon} class="w-4 h-4" />
              <% end %>
            <% end %>
            {@confirm_button_text}
          </button>
        <% end %>
      </:actions>
    </.modal>
    """
  end

  @doc """
  Renders an info/alert modal with a single OK button.

  This is a convenience wrapper for displaying information or alerts
  that only require acknowledgment.

  ## Attributes

  - `show` - Boolean to show/hide the modal (required)
  - `on_close` - Event name when user closes (required)
  - `title` - Modal title text (default: "Information")
  - `title_icon` - Heroicon name for title (optional)
  - `type` - Type of alert: :info, :success, :warning, :error (default: :info)
  - `message` - Single message to display (alternative to messages list)
  - `messages` - List of message tuples (alternative to single message)
  - `button_text` - Text for close button (default: "OK")

  ## Examples

  Success alert:
      <.alert_modal
        show={@show_success}
        on_close="close"
        type={:success}
        title="Success"
        message="Your changes have been saved."
      />

  Error alert:
      <.alert_modal
        show={@show_error}
        on_close="close"
        type={:error}
        title="Error"
        message="Failed to save changes."
      />
  """
  attr :show, :boolean, required: true
  attr :on_close, :string, required: true
  attr :title, :string, default: nil
  attr :title_icon, :string, default: nil
  attr :type, :atom, default: :info, values: [:info, :success, :warning, :error]
  attr :message, :string, default: nil
  attr :messages, :list, default: []
  attr :button_text, :string, default: nil

  def alert_modal(assigns) do
    # Build messages list from single message or use provided list
    messages =
      cond do
        assigns.message -> [{assigns.type, assigns.message}]
        assigns.messages != [] -> assigns.messages
        true -> []
      end

    # Determine icon based on type if not provided
    title_icon = assigns.title_icon || type_icon(assigns.type)
    title_icon_class = "w-5 h-5 #{type_icon_class(assigns.type)}"

    assigns =
      assigns
      |> assign(:computed_messages, messages)
      |> assign(:computed_title_icon, title_icon)
      |> assign(:computed_title_icon_class, title_icon_class)
      |> assign_new(:title_text, fn -> assigns[:title] || type_title(assigns.type) end)
      |> assign_new(:button_text_computed, fn -> assigns[:button_text] || gettext("OK") end)

    ~H"""
    <.confirm_modal
      show={@show}
      on_cancel={@on_close}
      title={@title_text}
      title_icon={@computed_title_icon}
      title_icon_class={@computed_title_icon_class}
      messages={@computed_messages}
      show_confirm={false}
      cancel_text={@button_text_computed}
      prompt=""
    />
    """
  end

  # Private helpers

  defp max_width_class("sm"), do: "max-w-sm"
  defp max_width_class("md"), do: "max-w-md"
  defp max_width_class("lg"), do: "max-w-lg"
  defp max_width_class("xl"), do: "max-w-xl"
  defp max_width_class("2xl"), do: "max-w-2xl"
  defp max_width_class("3xl"), do: "max-w-3xl"
  defp max_width_class("4xl"), do: "max-w-4xl"
  defp max_width_class("full"), do: "max-w-full"
  defp max_width_class(_), do: "max-w-md"

  defp message_styles(:warning), do: "bg-warning/10 border-warning/30"
  defp message_styles(:error), do: "bg-error/10 border-error/30"
  defp message_styles(:info), do: "bg-info/10 border-info/30"
  defp message_styles(:success), do: "bg-success/10 border-success/30"
  defp message_styles(_), do: "bg-base-200 border-base-300"

  defp message_icon(:warning), do: "hero-exclamation-triangle"
  defp message_icon(:error), do: "hero-x-circle"
  defp message_icon(:info), do: "hero-information-circle"
  defp message_icon(:success), do: "hero-check-circle"
  defp message_icon(_), do: "hero-information-circle"

  defp message_icon_class(:warning), do: "text-warning"
  defp message_icon_class(:error), do: "text-error"
  defp message_icon_class(:info), do: "text-info"
  defp message_icon_class(:success), do: "text-success"
  defp message_icon_class(_), do: "text-base-content/60"

  # Alert modal type helpers
  defp type_icon(:info), do: "hero-information-circle"
  defp type_icon(:success), do: "hero-check-circle"
  defp type_icon(:warning), do: "hero-exclamation-triangle"
  defp type_icon(:error), do: "hero-x-circle"

  defp type_icon_class(:info), do: "text-info"
  defp type_icon_class(:success), do: "text-success"
  defp type_icon_class(:warning), do: "text-warning"
  defp type_icon_class(:error), do: "text-error"

  defp type_title(:info), do: gettext("Information")
  defp type_title(:success), do: gettext("Success")
  defp type_title(:warning), do: gettext("Warning")
  defp type_title(:error), do: gettext("Error")
end
