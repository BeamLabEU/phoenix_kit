defmodule PhoenixKitWeb.Components.Core.TableDefault do
  @moduledoc """
  A basic table component with daisyUI styling.

  ## Examples

      <.table_default>
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>Name</.table_default_header_cell>
            <.table_default_header_cell>Email</.table_default_header_cell>
            <.table_default_header_cell>Role</.table_default_header_cell>
            <.table_default_header_cell>Actions</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row>
            <.table_default_cell>John Doe</.table_default_cell>
            <.table_default_cell>john@example.com</.table_default_cell>
            <.table_default_cell><.badge>Admin</.badge></.table_default_cell>
            <.table_default_cell>
              <.button>Edit</.button>
            </.table_default_cell>
          </.table_default_row>
          <.table_default_row>
            <.table_default_cell>Jane Smith</.table_default_cell>
            <.table_default_cell>jane@example.com</.table_default_cell>
            <.table_default_cell>
              <.badge color="ghost">User</.badge>
            </.table_default_cell>
            <.table_default_cell>
              <.button>Edit</.button>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>

      <.table_default variant="zebra">
        <!-- Table content with striped rows -->
      </.table_default>

      <.table_default size="sm" class="table-compact">
        <!-- Compact small table -->
      </.table_default>
  """

  use Phoenix.Component

  @doc """
  Renders a table with daisyUI styling.

  ## Attributes

  * `class` - Additional CSS classes (optional)
  * `variant` - Table variant: "default", "zebra", "pin-rows", "pin-cols" (optional, default: "default")
  * `size` - Table size: "xs", "sm", "md", "lg" (optional, default: "md")
  * `rest` - Additional HTML attributes (optional)
  """
  attr :class, :string, default: ""
  attr :variant, :string, default: "default", values: ["default", "zebra", "pin-rows", "pin-cols"]
  attr :size, :string, default: "md", values: ["xs", "sm", "md", "lg"]
  attr :rest, :global

  slot :inner_block, required: true

  def table_default(assigns) do
    ~H"""
    <div class="rounded-lg shadow-md">
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
