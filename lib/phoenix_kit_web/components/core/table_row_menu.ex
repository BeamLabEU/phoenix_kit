defmodule PhoenixKitWeb.Components.Core.TableRowMenu do
  @moduledoc """
  Dropdown action menu for table rows.

  Provides a compact "⋮" trigger button that opens a floating menu with action items.
  Uses `position: fixed` via the `RowMenu` JS hook to escape `overflow-clip` table
  containers — a common DaisyUI issue when dropdowns are nested inside tables.

  The menu is automatically positioned to stay within the viewport: it opens below
  the trigger by default, flips above if there's no space below, and aligns to the
  right edge of the trigger (shifting left if that would clip off-screen).

  Works on mobile and desktop. On mobile the menu is full-width clamped to viewport.

  ## Components

  - `table_row_menu/1` — wrapper with trigger button, accepts items as inner_block
  - `table_row_menu_link/1` — navigation item (`navigate` or `href`)
  - `table_row_menu_button/1` — action item (`phx-click` and other events)
  - `table_row_menu_divider/1` — visual separator between groups

  ## Example

      <.table_row_menu id={"menu-\#{user.uuid}"}>
        <.table_row_menu_link
          navigate={Routes.path("/admin/users/view/\#{user.uuid}")}
          icon="hero-eye"
          label={gettext("View")}
        />
        <.table_row_menu_link
          navigate={Routes.path("/admin/users/edit/\#{user.uuid}")}
          icon="hero-pencil"
          label={gettext("Edit")}
          variant="secondary"
        />
        <.table_row_menu_divider />
        <.table_row_menu_button
          phx-click="delete"
          phx-value-id={user.uuid}
          icon="hero-trash"
          label={gettext("Delete")}
          variant="error"
        />
      </.table_row_menu>
  """

  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  # ---------------------------------------------------------------------------
  # table_row_menu — wrapper
  # ---------------------------------------------------------------------------

  @doc """
  Renders the dropdown trigger and menu container.

  ## Attributes

  * `id` - Unique element ID (required). Used by the JS hook.
  * `label` - Accessible label for the trigger button (optional, default: "Actions")
  * `mode` - Display mode (optional, default: "dropdown"):
    - `"dropdown"` — always show the ⋮ dropdown menu (original behavior)
    - `"inline"` — always show actions as inline buttons (no dropdown)
    - `"auto"` — inline buttons on `md+` screens, dropdown on mobile
  * `class` - Additional CSS classes for the wrapper (optional)

  ## Slots

  * `inner_block` - Menu items (use `table_row_menu_link`, `table_row_menu_button`,
    `table_row_menu_divider`)
  """
  attr :id, :string, required: true
  attr :label, :string, default: "Actions"
  attr :mode, :string, default: "dropdown", values: ["dropdown", "inline", "auto"]
  attr :class, :string, default: nil

  slot :inner_block, required: true

  def table_row_menu(%{mode: "inline"} = assigns) do
    ~H"""
    <div
      class={[
        "inline-flex flex-nowrap items-center gap-0.5 row-menu-inline",
        "[&>li]:list-none [&>li]:inline-flex",
        @class
      ]}
      role="group"
      aria-label={@label}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  def table_row_menu(%{mode: "auto"} = assigns) do
    # Auto mode is intended to show inline buttons when they fit and collapse
    # to the ⋮ dropdown when they overflow. The RowMenuAuto JS hook exists in
    # phoenix_kit.js but doesn't work reliably — DaisyUI table cells have minimum
    # widths that prevent proper overflow detection. For now, auto mode falls through
    # to the default dropdown-only behaviour.
    table_row_menu(%{assigns | mode: "dropdown"})
  end

  def table_row_menu(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="RowMenu"
      class={["relative inline-block", @class]}
      data-row-menu-wrapper
    >
      <%!-- Trigger button --%>
      <button
        type="button"
        data-row-menu-trigger
        aria-label={@label}
        aria-expanded="false"
        aria-haspopup="menu"
        class="btn btn-xs btn-ghost btn-circle"
      >
        <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
      </button>

      <%!-- Floating menu — hidden by default, positioned via JS hook --%>
      <ul
        data-row-menu-content
        role="menu"
        class="hidden fixed z-[9999] min-w-[10rem] rounded-box bg-base-100 border border-base-200 shadow-xl p-1 focus:outline-none"
        tabindex="-1"
      >
        {render_slot(@inner_block)}
      </ul>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # table_row_menu_link — navigation item
  # ---------------------------------------------------------------------------

  @doc """
  Renders a navigation link item inside the menu.

  ## Attributes

  * `navigate` - LiveView navigate path (optional)
  * `href` - Regular href (optional)
  * `icon` - Heroicon name, e.g. "hero-eye" (optional)
  * `label` - Item label text (required)
  * `variant` - Color variant: "default", "primary", "secondary", "info", "success",
    "warning", "error" (optional, default: "default")
  * `rest` - Additional HTML attributes passed to the `<a>` element
  """
  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  attr :icon, :string, default: nil
  attr :label, :string, required: true
  attr :variant, :string, default: "default"
  attr :rest, :global

  def table_row_menu_link(assigns) do
    ~H"""
    <li role="none">
      <.link
        navigate={@navigate}
        href={@href}
        role="menuitem"
        class={[
          "flex items-center gap-2 px-3 py-2 rounded-lg text-sm",
          "hover:bg-base-200 transition-colors cursor-pointer",
          item_color_class(@variant)
        ]}
        {@rest}
      >
        <.icon :if={@icon} name={@icon} class="w-4 h-4 shrink-0 opacity-70" />
        <span>{@label}</span>
      </.link>
    </li>
    """
  end

  # ---------------------------------------------------------------------------
  # table_row_menu_button — action button item
  # ---------------------------------------------------------------------------

  @doc """
  Renders an action button item inside the menu.

  ## Attributes

  * `icon` - Heroicon name, e.g. "hero-trash" (optional)
  * `label` - Item label text (required)
  * `variant` - Color variant: "default", "primary", "secondary", "info", "success",
    "warning", "error" (optional, default: "default")
  * `rest` - Additional HTML attributes (phx-click, phx-value-*, data-confirm, etc.)
  """
  attr :icon, :string, default: nil
  attr :label, :string, required: true
  attr :variant, :string, default: "default"
  attr :rest, :global

  def table_row_menu_button(assigns) do
    ~H"""
    <li role="none">
      <button
        type="button"
        role="menuitem"
        class={[
          "flex items-center gap-2 px-3 py-2 rounded-lg text-sm w-full text-left",
          "hover:bg-base-200 transition-colors cursor-pointer",
          item_color_class(@variant)
        ]}
        {@rest}
      >
        <.icon :if={@icon} name={@icon} class="w-4 h-4 shrink-0 opacity-70" />
        <span>{@label}</span>
      </button>
    </li>
    """
  end

  # ---------------------------------------------------------------------------
  # table_row_menu_divider — separator
  # ---------------------------------------------------------------------------

  @doc """
  Renders a visual separator between menu item groups.
  """
  def table_row_menu_divider(assigns) do
    ~H"""
    <li role="separator" aria-hidden="true" class="my-1 h-px bg-base-200 mx-1"></li>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp item_color_class("primary"), do: "text-primary"
  defp item_color_class("secondary"), do: "text-secondary"
  defp item_color_class("info"), do: "text-info"
  defp item_color_class("success"), do: "text-success"
  defp item_color_class("warning"), do: "text-warning"
  defp item_color_class("error"), do: "text-error"
  defp item_color_class(_), do: "text-base-content"
end
