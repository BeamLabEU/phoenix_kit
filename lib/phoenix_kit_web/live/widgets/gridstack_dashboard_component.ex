defmodule PhoenixKitWeb.Widgets.GridStackDashboardComponent do
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <!-- Container with phx-hook to activate JavaScript hook -->
    <div
      id={"gridstack-dashboard-" <> @id}
      class="grid-stack"
      data-gs-width="12"
      data-gs-animate="yes"
      phx-hook="GridStackInit"
      phx-target={@myself}
    >
      <!-- Render each widget as a grid item -->
      <%= for widget <- @widgets do %>
        <div
          id={"widget-#{widget.id}"}
          class="grid-stack-item"
          gs-w={widget.grid_w || 4}
          gs-h={widget.grid_h || 5}
          gs-x={widget.grid_x || 0}
          gs-y={widget.grid_y || 0}
        >
          <div class="grid-stack-item-content">
            <div class="widget-header">
              <h3>{widget.title}</h3>
              <button
                class="widget-remove"
                phx-click="remove_widget"
                phx-value-id={widget.id}
                phx-target={@myself}
              >
                ×
              </button>
            </div>
            <div class="widget-body">
              <!-- Render widget component -->
              <.live_component
                module={widget.component}
                id={"component-#{widget.id}"}
                widget={widget}
                {widget.component_props}
              />
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  # Handle layout changes from GridStack JavaScript
  @impl true
  def handle_event("gridstack_change", %{"changes" => changes}, socket) do
    # Save widget positions to database
    Enum.each(changes, fn change ->
      # fixme: add persistence
      # .update_widget_layout(
      #   socket.assigns.current_user,
      #   change["widget_id"],
      #   %{
      #     grid_x: change["grid_x"],
      #     grid_y: change["grid_y"],
      #     grid_w: change["grid_w"],
      #     grid_h: change["grid_h"]
      #   }
      # )
      IO.inspect(change, label: "Widget layout changed")
    end)

    {:noreply, socket}
  end

  # Handle widget removal
  @impl true
  def handle_event("remove_widget", %{"id" => widget_id}, socket) do
    # Remove from user's dashboard
    # Example: YourApp.Widgets.remove_user_widget(socket.assigns.current_user, widget_id)

    IO.inspect(widget_id, label: "Widget removed")
    {:noreply, socket}
  end
end
