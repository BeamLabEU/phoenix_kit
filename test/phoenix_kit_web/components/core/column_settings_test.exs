defmodule PhoenixKitWeb.Components.Core.ColumnSettingsTest do
  @moduledoc """
  Render tests for `<.column_settings_modal>`. Pins:

  - shown list renders selected ids (in order) with drag handles + remove
  - Shown rows use `sortable-item` + `data-sortable-handle` (SortableGrid contract)
  - available list renders unselected columns as add buttons
  - selected ids missing from the catalog are ignored (unmanaged columns)
  - labels accept strings and 0-arity functions
  - an optional `hint` is a second line under the label in both lists; a
    column without one stays a single line
  - footer is Reset + Close (live editor — no Apply)
  - `target` is forwarded to clicks and the SortableGrid hook
  - show={false} renders nothing
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.ColumnSettings

  defp columns do
    [
      %{id: "sku", label: "SKU"},
      %{id: "price", label: fn -> "Price (fn)" end},
      %{id: "status", label: "Status"}
    ]
  end

  defp render_modal(selected) do
    assigns = %{columns: columns(), selected: selected}

    rendered_to_string(~H"""
    <.column_settings_modal show={true} columns={@columns} selected={@selected} />
    """)
  end

  test "selected columns render in the Shown list with remove buttons" do
    html = render_modal(["sku", "price"])
    assert html =~ ~s(phx-value-column_id="sku")
    assert html =~ "pk-drag-handle"
    assert html =~ ~s(phx-click="remove_column")
    assert html =~ "Price (fn)"
    # SortableGrid hardcodes `.sortable-item` for draggable / ordered_ids;
    # a custom class (the original `.col-item`) is silently ignored.
    assert html =~ ~s(phx-hook="SortableGrid")
    assert html =~ ~s(data-sortable-event="reorder_columns")
    assert html =~ ~s(data-sortable-items=".sortable-item")
    assert html =~ ~s(data-sortable-handle=".pk-drag-handle")
    assert html =~ ~s(class="sortable-item)
    refute html =~ "col-item"
  end

  test "a column's hint is a second line under its label, in both lists" do
    columns = [
      %{id: "approved", label: "Approved", hint: "Approved for Wood Matrix"},
      %{id: "vip", label: "VIP", hint: fn -> "Very important person" end},
      %{id: "sku", label: "SKU"}
    ]

    assigns = %{columns: columns}

    doc =
      rendered_to_string(~H"""
      <.column_settings_modal show={true} columns={@columns} selected={["approved", "sku"]} />
      """)
      |> Floki.parse_document!()

    lines = fn node ->
      node |> Floki.find("span.text-xs") |> Enum.map(&String.trim(Floki.text(&1)))
    end

    shown = Floki.find(doc, ~s(li[data-id="approved"]))

    assert shown |> Floki.text() |> String.split() |> Enum.join(" ") =~
             "Approved Approved for Wood Matrix"

    assert lines.(shown) == ["Approved for Wood Matrix"]

    available = Floki.find(doc, ~s(button[phx-value-column_id="vip"]))
    assert lines.(available) == ["Very important person"]

    # No hint: one line, as before.
    assert lines.(Floki.find(doc, ~s(li[data-id="sku"]))) == []
  end

  test "unselected columns render as add buttons" do
    html = render_modal(["sku"])
    assert html =~ ~s(phx-click="add_column")
    assert html =~ "Status"
  end

  test "selected ids outside the catalog are ignored" do
    html = render_modal(["name", "sku"])
    refute html =~ ~s(data-id="name")
    assert html =~ ~s(data-id="sku")
  end

  test "footer is Reset + Close, no Apply" do
    html = render_modal(["sku"])
    assert html =~ ~s(phx-click="reset_columns")
    assert html =~ ~s(phx-click="hide_column_modal")
    refute html =~ "apply_columns"
  end

  test "target is forwarded onto clicks and the SortableGrid hook" do
    assigns = %{columns: columns()}

    html =
      rendered_to_string(~H"""
      <.column_settings_modal
        show={true}
        columns={@columns}
        selected={["sku"]}
        target="#pk-columns-lc"
      />
      """)

    assert html =~ ~s(phx-target="#pk-columns-lc")
    assert html =~ ~s(data-sortable-target="#pk-columns-lc")
  end

  test "hidden when show is false" do
    assigns = %{columns: columns()}

    html =
      rendered_to_string(~H"""
      <.column_settings_modal show={false} columns={@columns} selected={[]} />
      """)

    refute html =~ "Shown"
  end
end
