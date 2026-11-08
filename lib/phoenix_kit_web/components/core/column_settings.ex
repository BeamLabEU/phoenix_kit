defmodule PhoenixKitWeb.Components.Core.ColumnSettings do
  @moduledoc """
  Generic LIVE column-configuration modal for admin tables: a "Shown"
  list (drag to reorder via the SortableGrid hook, ✕ to remove) beside
  an "Available" list (click to add), with Reset + Close. There is no
  Apply step — the consumer applies each change immediately, so the
  table updates behind the modal as the user works.

  ## Ownership model

  Pure presentation. The consumer owns the column catalog, the selected
  list, and persistence, and implements these events. LiveView callers
  need no extra wiring; LiveComponent callers pass `target` (a CSS
  selector for the component root) so clicks and the SortableGrid hook
  reach that component instead of the host LiveView:

      add_column        %{"column_id" => id}
      remove_column     %{"column_id" => id}
      reorder_columns   %{"ordered_ids" => ids}   (from SortableGrid)
      reset_columns     %{}
      hide_column_modal %{}                        (Close / backdrop / Esc)

  ## Usage

      <.column_settings_modal
        show={@show_columns}
        columns={[%{id: "sku", label: "SKU"}, %{id: "price", label: fn -> gettext("Price") end}]}
        selected={@columns}
      />

  `columns` is every configurable column; `selected` is the shown ids in
  display order. Labels may be strings or 0-arity functions (evaluated at
  render, so gettext labels stay lazy). A column's optional `hint` (string
  or 0-arity fn) is a second, smaller line under its label in both lists —
  the full name of a column whose label is shortened. Ids in `selected` that are not in
  `columns` are ignored, so consumers with unmanaged always-on columns
  (a Name column outside the editor) can pass their full list. A column's
  optional `group` heads the Available list for consecutive columns of
  that group (standard fields, then custom fields).

  A page with several tables passes `sections` instead — one block each,
  titled when there is more than one — and add/remove/reorder then carry
  `"section" => id`; Reset carries none and means every section.

  `PhoenixKitWeb.TableColumns` implements the events and keeps each user's
  choice; a consumer that uses it needs only the open/close events.

  Shown rows use the `sortable-item` class the SortableGrid hook actually
  reads (`draggable`, item-count, `ordered_ids`). A custom class is
  ignored. Drag starts only on `.pk-drag-handle` so the remove button is
  not a drag surface.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Modal, only: [modal: 1]

  attr :show, :boolean, required: true
  attr :id, :string, default: "pk-column-settings-modal"

  attr :columns, :list,
    default: nil,
    doc:
      "Every configurable column: %{id: String.t(), label: String.t() | (-> String.t())}, optionally `group:` (a heading for the Available list, string or 0-arity fn) and `hint:` (a smaller second line under the label, string or 0-arity fn)."

  attr :selected, :list, default: nil, doc: "Shown column ids, in display order."

  attr :sections, :list,
    default: nil,
    doc:
      "Several tables in one modal, instead of `columns`/`selected`: [%{id: String.t(), title: String.t(), columns: [...], selected: [...]}]. Add, remove and reorder carry `\"section\" => id`; Reset carries none and resets them all."

  attr :target, :any,
    default: nil,
    doc:
      "Optional LiveComponent CSS selector (e.g. `#my-table`). Set on every `phx-click` and on `data-sortable-target` so a LiveComponent consumer receives add/remove/reorder/reset/close."

  def column_settings_modal(assigns) do
    sections =
      (assigns.sections ||
         [
           %{
             id: nil,
             title: nil,
             columns: assigns.columns || [],
             selected: assigns.selected || []
           }
         ])
      |> Enum.map(&section/1)

    assigns = assign(assigns, :section_list, sections)

    ~H"""
    <.modal :if={@show} id={@id} show on_close="hide_column_modal" max_width="lg">
      <:title>{gettext("Columns")}</:title>
      <div class="space-y-6">
        <section :for={s <- @section_list}>
          <h4 :if={length(@section_list) > 1} class="text-sm font-semibold mb-2">{s.title}</h4>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <p class="text-xs uppercase text-base-content/50 mb-2">{gettext("Shown")}</p>
              <p :if={s.shown == []} class="text-sm text-base-content/50 px-2 py-1">
                {gettext("No columns shown.")}
              </p>
              <ul
                id={section_dom_id(@id, s.id) <> "-selected"}
                phx-hook="SortableGrid"
                data-sortable="true"
                data-sortable-event="reorder_columns"
                data-sortable-items=".sortable-item"
                data-sortable-handle=".pk-drag-handle"
                data-sortable-target={@target}
                data-sortable-scope-section={s.id}
                class="space-y-1"
              >
                <li
                  :for={id <- s.shown}
                  data-id={id}
                  class="sortable-item flex items-center gap-2 px-2 py-1 rounded bg-base-200"
                >
                  <.icon
                    name="hero-bars-3"
                    class="w-4 h-4 pk-drag-handle cursor-grab text-base-content/40"
                  />
                  <span class="flex-1 text-sm">
                    {column_label(s.map[id])}
                    <span
                      :if={column_hint(s.map[id])}
                      class="block text-xs text-base-content/50"
                    >
                      {column_hint(s.map[id])}
                    </span>
                  </span>
                  <button
                    type="button"
                    phx-click="remove_column"
                    phx-target={@target}
                    phx-value-column_id={id}
                    phx-value-section={s.id}
                    class="btn btn-ghost btn-xs btn-square text-error cursor-pointer"
                    title={gettext("Remove")}
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </li>
              </ul>
            </div>
            <div>
              <p class="text-xs uppercase text-base-content/50 mb-2">{gettext("Available")}</p>
              <div :for={{group, columns} <- s.hidden} class="mb-2 last:mb-0">
                <p :if={group} class="text-xs font-semibold text-base-content/60 px-2 mb-1">
                  {group}
                </p>
                <ul class="space-y-1">
                  <li :for={c <- columns}>
                    <button
                      type="button"
                      phx-click="add_column"
                      phx-target={@target}
                      phx-value-column_id={c.id}
                      phx-value-section={s.id}
                      class="flex items-center gap-2 w-full text-left text-sm px-2 py-1 rounded hover:bg-base-200 cursor-pointer transition-colors"
                    >
                      <.icon name="hero-plus" class="w-4 h-4 text-base-content/40" />
                      <span>
                        {column_label(c)}
                        <span :if={column_hint(c)} class="block text-xs text-base-content/50">
                          {column_hint(c)}
                        </span>
                      </span>
                    </button>
                  </li>
                </ul>
              </div>
            </div>
          </div>
        </section>
      </div>
      <:actions>
        <button
          type="button"
          phx-click="reset_columns"
          phx-target={@target}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Reset")}
        </button>
        <button
          type="button"
          phx-click="hide_column_modal"
          phx-target={@target}
          class="btn btn-primary btn-sm"
        >
          {gettext("Close")}
        </button>
      </:actions>
    </.modal>
    """
  end

  # Shown ids that are offered, in order; the rest of the offer as
  # `{group heading | nil, columns}`, one per run of consecutive columns.
  defp section(%{columns: columns, selected: selected} = s) do
    map = Map.new(columns, &{&1.id, &1})
    shown = Enum.filter(selected, &Map.has_key?(map, &1))

    hidden =
      columns
      |> Enum.reject(&(&1.id in shown))
      |> Enum.chunk_by(&group_label/1)
      |> Enum.map(fn [first | _] = chunk -> {group_label(first), chunk} end)

    %{id: Map.get(s, :id), title: Map.get(s, :title), map: map, shown: shown, hidden: hidden}
  end

  defp section_dom_id(id, nil), do: id
  defp section_dom_id(id, section), do: id <> "-" <> to_string(section)

  defp group_label(%{group: group}) when is_function(group, 0), do: group.()
  defp group_label(%{group: group}) when is_binary(group), do: group
  defp group_label(_), do: nil

  defp column_label(%{label: label}) when is_function(label, 0), do: label.()
  defp column_label(%{label: label}), do: label
  defp column_label(_), do: ""

  defp column_hint(%{hint: hint}) when is_function(hint, 0), do: hint.()
  defp column_hint(%{hint: hint}) when is_binary(hint) and hint != "", do: hint
  defp column_hint(_), do: nil
end
