defmodule PhoenixKitWeb.Components.Core.DraggableList do
  @moduledoc """
  A reusable drag-and-drop sortable component supporting both grid and list layouts.

  Uses SortableJS (auto-loaded from CDN) to enable drag-and-drop reordering of items.
  The component sends a LiveView event when items are reordered.

  ## Design Philosophy

  This component provides minimal opinionated styling - it handles drag-drop behavior
  while you control the appearance through classes and slot content.

  ## Usage - Grid Layout (default)

  Perfect for image galleries, card grids, etc:

      <.draggable_list
        id="post-images"
        items={@images}
        on_reorder="reorder_images"
        cols={4}
      >
        <:item :let={img}>
          <img src={img.url} class="w-full aspect-square object-cover rounded" />
        </:item>
        <:add_button>
          <button phx-click="add_image" class="btn">Add</button>
        </:add_button>
      </.draggable_list>

  ## Usage - List Layout

  Perfect for column selectors, ordered lists, etc:

      <.draggable_list
        id="table-columns"
        items={@columns}
        on_reorder="reorder_columns"
        layout={:list}
        item_class="flex items-center p-3 bg-base-100 border rounded-lg hover:bg-base-200"
      >
        <:item :let={col}>
          <div class="mr-3 text-base-content/40">
            <.icon name="hero-bars-3" class="w-5 h-5" />
          </div>
          <span class="flex-1 font-medium">{col.label}</span>
          <button phx-click="remove_column" phx-value-id={col.id} class="btn btn-ghost btn-xs">
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </:item>
      </.draggable_list>

  ## Event Handler

  The `on_reorder` event receives `%{"ordered_ids" => [id1, id2, ...]}` with the new order:

      def handle_event("reorder_items", %{"ordered_ids" => ordered_ids}, socket) do
        # ordered_ids is a list of item IDs in the new order
        {:noreply, socket}
      end
  """
  use Phoenix.Component

  attr :id, :string, required: true, doc: "Unique ID for the container"
  attr :items, :list, required: true, doc: "List of items to display"

  attr :item_id, :any,
    default: nil,
    doc: "Function to extract ID from item, defaults to &(&1.id)"

  attr :on_reorder, :string, required: true, doc: "Event name to send on reorder"
  attr :layout, :atom, default: :grid, values: [:grid, :list], doc: "Layout mode"
  attr :cols, :integer, default: 4, doc: "Number of grid columns (only for layout={:grid})"
  attr :gap, :string, default: "gap-2", doc: "Gap between items (Tailwind class)"
  attr :class, :string, default: "", doc: "Additional CSS classes for the container"
  attr :item_class, :string, default: "", doc: "Additional CSS classes for each item wrapper"

  slot :item, required: true, doc: "Slot to render each item, receives the item as let"
  slot :add_button, doc: "Optional slot for add button at end of container"

  def draggable_list(assigns) do
    item_id_fn = assigns[:item_id] || fn item -> item.id end
    layout = assigns[:layout] || :grid
    cols_class = if layout == :grid, do: cols_to_class(assigns[:cols] || 4), else: nil

    container_class =
      case layout do
        :grid -> ["grid", cols_class, assigns[:gap], assigns[:class]]
        :list -> ["flex flex-col", assigns[:gap], assigns[:class]]
      end

    assigns =
      assign(assigns,
        item_id_fn: item_id_fn,
        container_class: container_class
      )

    ~H"""
    <div
      id={@id}
      data-sortable="true"
      data-sortable-event={@on_reorder}
      data-sortable-items=".sortable-item"
      phx-hook="SortableGrid"
      class={@container_class}
    >
      <%= for item <- @items do %>
        <div
          class={["sortable-item cursor-grab active:cursor-grabbing", @item_class]}
          data-id={@item_id_fn.(item)}
        >
          {render_slot(@item, item)}
        </div>
      <% end %>

      <%= if @add_button != [] do %>
        <div class="sortable-ignore">
          {render_slot(@add_button)}
        </div>
      <% end %>
    </div>
    """
  end

  # Map column count to Tailwind class (must be static for Tailwind to recognize)
  defp cols_to_class(1), do: "grid-cols-1"
  defp cols_to_class(2), do: "grid-cols-2"
  defp cols_to_class(3), do: "grid-cols-3"
  defp cols_to_class(4), do: "grid-cols-4"
  defp cols_to_class(5), do: "grid-cols-5"
  defp cols_to_class(6), do: "grid-cols-6"
  defp cols_to_class(_), do: "grid-cols-4"
end
