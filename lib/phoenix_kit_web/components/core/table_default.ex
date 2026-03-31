defmodule PhoenixKitWeb.Components.Core.TableDefault do
  @moduledoc """
  A basic table component with daisyUI styling.

  Supports an optional card/table view toggle for responsive layouts. When `items`
  is provided or `toggleable` is true, renders both a table view (desktop default)
  and a card view (mobile default) with an optional toggle button.

  ## Examples

  ### Basic table (unchanged API)

      <.table_default>
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>Name</.table_default_header_cell>
            <.table_default_header_cell>Email</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row>
            <.table_default_cell>John Doe</.table_default_cell>
            <.table_default_cell>john@example.com</.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>

  ### With card/table toggle

      <.table_default
        id="users-table"
        toggleable
        items={@users}
        card_title={fn user -> user.name end}
        card_fields={fn user -> [
          %{label: "Email", value: user.email},
          %{label: "Role", value: user.role}
        ] end}
      >
        <.table_default_header>...</.table_default_header>
        <.table_default_body>...</.table_default_body>
        <:card_actions :let={user}>
          <.button size="sm" navigate={~p"/users/\#{user.id}"}>View</.button>
        </:card_actions>
      </.table_default>
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  @doc """
  Renders a table with daisyUI styling.

  When `items` is provided or `toggleable` is true, renders a responsive wrapper
  with both table and card views, plus an optional desktop toggle button.
  Otherwise renders the classic table-only layout (fully backward compatible).

  ## Attributes

  * `id` - Element ID, required when using card/table toggle (optional)
  * `class` - Additional CSS classes (optional)
  * `variant` - Table variant: "default", "zebra", "pin-rows", "pin-cols" (optional, default: "default")
  * `size` - Table size: "xs", "sm", "md", "lg" (optional, default: "md")
  * `toggleable` - Show card/table toggle buttons on desktop (optional, default: false)
  * `items` - List of items for card view rendering (optional, default: [])
  * `card_title` - Function that returns the card title for an item (optional)
  * `card_fields` - Function that returns a list of `%{label: string, value: any}` for an item (optional)
  * `storage_key` - localStorage key for persisting view preference, falls back to `id` in JS (optional)
  * `rest` - Additional HTML attributes (optional)

  ## Slots

  * `inner_block` - Table content (thead, tbody, etc.)
  * `card_actions` - Action buttons rendered in each card footer (receives item via :let)
  """
  attr :id, :string, default: nil
  attr :class, :string, default: ""
  attr :variant, :string, default: "default", values: ["default", "zebra", "pin-rows", "pin-cols"]
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :toggleable, :boolean, default: false
  attr :show_toggle, :boolean, default: true
  attr :items, :list, default: []
  attr :card_title, :any, default: nil
  attr :card_fields, :any, default: nil
  attr :storage_key, :string, default: nil
  attr :wrapper_class, :string, default: "rounded-lg shadow-md overflow-x-auto overflow-y-clip"
  attr :rest, :global

  slot :inner_block, required: true

  slot :card_header,
    doc: "Custom header for each card (receives item via :let); replaces card_title"

  slot :card_actions, doc: "Action buttons in card footer"

  def table_default(assigns) do
    if assigns.items == [] and not assigns.toggleable do
      table_default_classic(assigns)
    else
      table_default_with_cards(assigns)
    end
  end

  defp table_default_classic(assigns) do
    ~H"""
    <div class={@wrapper_class}>
      <table
        class={[
          "table",
          table_variant_class(@variant),
          table_size_class(@size),
          @class
        ]}
        {@rest}
      >
        {render_slot(@inner_block)}
      </table>
    </div>
    """
  end

  defp table_default_with_cards(assigns) do
    ~H"""
    <div id={@id} phx-hook="TableCardView" data-storage-key={@storage_key || @id} class="relative">
      <%!-- Toggle buttons — only if toggleable and show_toggle, only desktop --%>
      <div :if={@toggleable && @show_toggle} class="hidden md:flex justify-end mb-2">
        <div class="join">
          <button
            type="button"
            data-view-action="card"
            class="btn btn-sm join-item"
            title="Card view"
          >
            <.icon name="hero-squares-2x2" class="w-4 h-4" />
          </button>
          <button
            type="button"
            data-view-action="table"
            class="btn btn-sm join-item"
            title="Table view"
          >
            <.icon name="hero-bars-3-bottom-left" class="w-4 h-4" />
          </button>
        </div>
      </div>
      <%!-- Table: hidden on mobile always, shown on desktop (JS controls md: classes) --%>
      <div data-table-view="" class="hidden md:block">
        <div class={@wrapper_class}>
          <table
            class={[
              "table",
              table_variant_class(@variant),
              table_size_class(@size),
              @class
            ]}
            {@rest}
          >
            {render_slot(@inner_block)}
          </table>
        </div>
      </div>
      <%!-- Cards: always shown on mobile, hidden on desktop (JS controls md: classes) --%>
      <div data-card-view="" class="md:hidden grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        <div :for={item <- @items} class="card card-sm bg-base-200 shadow-sm">
          <div class="card-body gap-3 flex flex-col">
            <%!-- Custom header (slot) or plain title string --%>
            <div :if={@card_header != []}>
              {render_slot(@card_header, item)}
            </div>
            <div :if={@card_header == [] && @card_title} class="font-medium text-sm">
              {@card_title.(item)}
            </div>
            <%!-- Key-value fields --%>
            <div :if={@card_fields} class="grid grid-cols-2 gap-x-4 gap-y-1 text-sm flex-1">
              <%= for field <- @card_fields.(item) do %>
                <div class="text-base-content/60">{field.label}</div>
                <div>{field.value}</div>
              <% end %>
            </div>
            <%!-- Actions: pinned to bottom --%>
            <div
              :if={@card_actions != []}
              class="card-actions justify-end pt-1 border-t border-base-200 mt-auto"
            >
              {render_slot(@card_actions, item)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a table header section.
  """
  slot :inner_block, required: true

  def table_default_header(assigns) do
    ~H"""
    <thead class="bg-primary text-primary-content">
      {render_slot(@inner_block)}
    </thead>
    """
  end

  @doc """
  Renders a table body section.
  """
  slot :inner_block, required: true

  def table_default_body(assigns) do
    ~H"""
    <tbody>
      {render_slot(@inner_block)}
    </tbody>
    """
  end

  @doc """
  Renders a table footer section.
  """
  slot :inner_block, required: true

  def table_default_footer(assigns) do
    ~H"""
    <tfoot>
      {render_slot(@inner_block)}
    </tfoot>
    """
  end

  @doc """
  Renders a table row.

  ## Attributes

  * `class` - Additional CSS classes (optional)
  * `hover` - Enable hover effect: true/false (optional, default: true)
  * `rest` - Additional HTML attributes (optional)
  """
  attr :class, :string, default: ""
  attr :hover, :boolean, default: true
  attr :rest, :global

  slot :inner_block, required: true

  def table_default_row(assigns) do
    ~H"""
    <tr
      class={[
        if(@hover, do: "hover", else: ""),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </tr>
    """
  end

  @doc """
  Renders a table header cell.

  ## Attributes

  * `class` - Additional CSS classes (optional)
  * `rest` - Additional HTML attributes (optional)
  """
  attr :class, :string, default: ""
  attr :rest, :global

  slot :inner_block, required: true

  def table_default_header_cell(assigns) do
    ~H"""
    <th class={@class} {@rest}>
      {render_slot(@inner_block)}
    </th>
    """
  end

  @doc """
  Renders a table data cell.

  ## Attributes

  * `class` - Additional CSS classes (optional)
  * `colspan` - Number of columns to span (optional)
  * `rowspan` - Number of rows to span (optional)
  * `rest` - Additional HTML attributes (optional)
  """
  attr :class, :string, default: ""
  attr :colspan, :integer, default: nil
  attr :rowspan, :integer, default: nil
  attr :rest, :global

  slot :inner_block, required: true

  def table_default_cell(assigns) do
    ~H"""
    <td class={@class} colspan={@colspan} rowspan={@rowspan} {@rest}>
      {render_slot(@inner_block)}
    </td>
    """
  end

  # Private helper functions

  defp table_variant_class("default"), do: ""
  defp table_variant_class("zebra"), do: "table-zebra"
  defp table_variant_class("pin-rows"), do: "table-pin-rows"
  defp table_variant_class("pin-cols"), do: "table-pin-cols"

  defp table_size_class(nil), do: ""
  defp table_size_class("xs"), do: "table-xs"
  defp table_size_class("sm"), do: "table-sm"
  defp table_size_class("md"), do: "table-md"
  defp table_size_class("lg"), do: "table-lg"
end
