# Draggable List Component

A reusable drag-and-drop component supporting both **grid** and **list** layouts. Uses SortableJS (auto-loaded from CDN) for drag-and-drop functionality.

## Basic Usage

### Grid Layout (default)

Perfect for image galleries, card grids, media selectors:

```heex
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
```

### List Layout

Perfect for column selectors, ordered lists, sortable menus:

```heex
<.draggable_list
  id="table-columns"
  items={@columns}
  on_reorder="reorder_columns"
  layout={:list}
  gap="space-y-2"
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
```

## Attributes

| Attribute | Type | Default | Description |
|-----------|------|---------|-------------|
| `id` | string | required | Unique ID for the container |
| `items` | list | required | List of items to display |
| `on_reorder` | string | required | Event name sent when items are reordered |
| `item_id` | function | `&(&1.id)` | Function to extract ID from each item |
| `layout` | atom | `:grid` | Layout mode: `:grid` or `:list` |
| `cols` | integer | 4 | Grid columns (only for grid layout) |
| `gap` | string | `"gap-2"` | Tailwind gap class between items |
| `class` | string | `""` | Additional CSS classes for container |
| `item_class` | string | `""` | Additional CSS classes for each item wrapper |

## Slots

| Slot | Required | Description |
|------|----------|-------------|
| `:item` | yes | Template for each item, receives item via `:let` |
| `:add_button` | no | Optional add button shown at end of list |

## Event Handler

The `on_reorder` event receives the new order as a list of item IDs:

```elixir
def handle_event("reorder_items", %{"ordered_ids" => ordered_ids}, socket) do
  # ordered_ids is a list like ["id1", "id2", "id3"]
  # Update your data with the new order
  {:noreply, socket}
end
```

## JavaScript Setup

The component requires the `SortableGrid` hook. Add to your `app.js`:

```javascript
// Import the hook (auto-loads SortableJS from CDN)
import "../../../deps/phoenix_kit/priv/static/assets/phoenix_kit_sortable.js"

let Hooks = {
  // ... your other hooks ...
  SortableGrid: window.SortableGridHook
}

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  // ... other options
})
```

## CSS Classes

The component injects these CSS classes automatically:

- `.sortable-ghost` - Applied to the placeholder where item will drop (opacity: 0.5)
- `.sortable-chosen` - Applied to the selected item (primary color outline)
- `.sortable-drag` - Applied to the dragging clone (shadow)
- `.sortable-item` - Applied to each draggable item (cursor styles)
- `.sortable-ignore` - Add to elements that shouldn't trigger drag (like the add button)

## Examples

### Media Gallery with Add Button

```heex
<.draggable_list
  id="gallery"
  items={@media}
  item_id={fn m -> m.file_id end}
  on_reorder="reorder_media"
  cols={4}
>
  <:item :let={media}>
    <div class="relative group aspect-square">
      <img src={media.url} class="w-full h-full object-cover rounded-lg" />
      <button
        phx-click="remove_media"
        phx-value-id={media.id}
        class="absolute top-1 right-1 btn btn-xs btn-circle btn-error opacity-0 group-hover:opacity-100"
      >
        <.icon name="hero-x-mark" class="w-3 h-3" />
      </button>
    </div>
  </:item>
  <:add_button>
    <button phx-click="open_media_selector" class="w-full aspect-square border-2 border-dashed rounded-lg">
      <.icon name="hero-plus" class="w-6 h-6" />
    </button>
  </:add_button>
</.draggable_list>
```

### Sortable Settings List

```heex
<.draggable_list
  id="settings-order"
  items={@settings}
  on_reorder="reorder_settings"
  layout={:list}
  item_class="flex items-center p-4 bg-base-200 rounded-lg"
>
  <:item :let={setting}>
    <.icon name="hero-bars-3" class="w-5 h-5 mr-3 text-base-content/40" />
    <span class="flex-1">{setting.name}</span>
    <span class="badge badge-ghost">{setting.value}</span>
  </:item>
</.draggable_list>
```

## Database Considerations

When storing position/order in the database with a unique constraint on `(parent_id, position)`, use a two-pass update to avoid constraint violations:

```elixir
def reorder_items(parent_id, ordered_ids) do
  repo().transaction(fn ->
    # Pass 1: Set all positions to negative (temporary)
    ordered_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {id, pos} ->
      from(i in Item, where: i.parent_id == ^parent_id and i.id == ^id)
      |> repo().update_all(set: [position: -pos])
    end)

    # Pass 2: Set correct positive positions
    ordered_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {id, pos} ->
      from(i in Item, where: i.parent_id == ^parent_id and i.id == ^id)
      |> repo().update_all(set: [position: pos])
    end)
  end)
end
```

## Source Files

- Component: `lib/phoenix_kit_web/components/core/draggable_list.ex`
- JavaScript: `priv/static/assets/phoenix_kit_sortable.js`
