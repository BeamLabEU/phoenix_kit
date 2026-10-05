defmodule PhoenixKitWeb.Components.Core.TableDefaultTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.TableDefault

  # ── sort_header_cell/1 ─────────────────────────────────────────

  describe "sort_header_cell/1" do
    test "renders th with label only when sort is nil" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:name} sort={nil}>Name</.sort_header_cell>
        """)

      assert result =~ "<th"
      assert result =~ "Name"
      refute result =~ "<button"
      refute result =~ "phx-click"
    end

    test "renders button with toggle_sort event for active column ascending" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:foo} sort={%{by: :foo, dir: :asc}}>Foo</.sort_header_cell>
        """)

      assert result =~ ~s(phx-click="toggle_sort")
      assert result =~ ~s(phx-value-by="foo")
      assert result =~ "hero-chevron-up-mini"
    end

    test "renders button with chevron-down for active column descending" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:foo} sort={%{by: :foo, dir: :desc}}>Foo</.sort_header_cell>
        """)

      assert result =~ ~s(phx-click="toggle_sort")
      assert result =~ "hero-chevron-down-mini"
    end

    test "renders button without chevron for inactive column" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:bar} sort={%{by: :foo, dir: :asc}}>Bar</.sort_header_cell>
        """)

      assert result =~ "<button"
      refute result =~ "hero-chevron-up-mini"
      refute result =~ "hero-chevron-down-mini"
    end

    test "align right adds justify-end class to button" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:amount} sort={%{by: :amount, dir: :asc}} align={:right}>
          Amount
        </.sort_header_cell>
        """)

      assert result =~ "justify-end"
    end

    test "align is applied to <th> in inert (sort=nil) branch" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:name} sort={nil} align={:right}>Name</.sort_header_cell>
        """)

      assert result =~ "text-right"
    end

    test "aria-sort is ascending when active column is asc" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:foo} sort={%{by: :foo, dir: :asc}}>Foo</.sort_header_cell>
        """)

      assert result =~ ~s(aria-sort="ascending")
    end

    test "aria-sort is descending when active column is desc" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:foo} sort={%{by: :foo, dir: :desc}}>Foo</.sort_header_cell>
        """)

      assert result =~ ~s(aria-sort="descending")
    end

    test "aria-sort is none for inactive sortable column" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:bar} sort={%{by: :foo, dir: :asc}}>Bar</.sort_header_cell>
        """)

      assert result =~ ~s(aria-sort="none")
    end

    test "aria-sort is omitted when sort is nil" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell field={:name} sort={nil}>Name</.sort_header_cell>
        """)

      refute result =~ "aria-sort"
    end

    test "custom event and target are passed through" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.sort_header_cell
          field={:name}
          sort={%{by: :name, dir: :asc}}
          event="my_sort"
          target="#my-table"
        >
          Name
        </.sort_header_cell>
        """)

      assert result =~ ~s(phx-click="my_sort")
      assert result =~ ~s(phx-target="#my-table")
    end
  end

  # ── search_toolbar/1 ───────────────────────────────────────────

  describe "search_toolbar/1" do
    test "renders input with default 300ms debounce" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" />
        """)

      assert result =~ ~s(phx-debounce="300")
      assert result =~ ~s(phx-change="search")
      assert result =~ "hero-magnifying-glass"
    end

    test "respects value attribute" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="hello" />
        """)

      assert result =~ ~s(value="hello")
    end

    test "respects placeholder attribute" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" placeholder="Search users..." />
        """)

      assert result =~ ~s(placeholder="Search users...")
    end

    test "respects on_change attribute" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" on_change="filter_users" />
        """)

      assert result =~ ~s(phx-change="filter_users")
    end

    test "wraps in form when on_submit is set" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" on_submit="do_search" />
        """)

      assert result =~ "<form"
      assert result =~ ~s(phx-submit="do_search")
    end

    test "form wrapper is present even without on_submit (Enter falls back to on_change)" do
      # This test used to pin the OPPOSITE (refute <form) — codifying the bug
      # where phx-change on a form-less input silently never reaches the
      # server. The component now always renders the form.
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" />
        """)

      assert result =~ "<form"
      assert result =~ ~s(phx-submit="search")
    end

    test "default placeholder uses dgettext fallback" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" />
        """)

      assert result =~ ~s(placeholder="Search...")
    end

    test "form variant binds phx-change only on input, not on form" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" on_submit="do_search" />
        """)

      count = result |> String.split(~s(phx-change=)) |> length() |> Kernel.-(1)
      assert count == 1, "phx-change should appear exactly once, got #{count}"
    end

    test "form variant propagates phx-target to both form and input" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.search_toolbar value="" on_submit="do_search" target="#my-component" />
        """)

      count = result |> String.split(~s(phx-target="#my-component")) |> length() |> Kernel.-(1)
      assert count == 2, "phx-target should appear on both <form> and <input>, got #{count}"
    end
  end

  # ── table_default_row/1 ───────────────────────────────────────────

  describe "fit" do
    test "the hook goes on the scroll wrapper, keyed by the table id" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.table_default id="people" fit>
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell lead>Name</.table_default_header_cell>
              <.table_default_header_cell priority={3} width="8rem">Email</.table_default_header_cell>
              <.sort_header_cell field={:status} priority={1}>Status</.sort_header_cell>
              <.table_default_header_cell />
            </.table_default_row>
          </.table_default_header>
          <.table_default_body>
            <.table_default_row>
              <.table_default_cell lead>Ann</.table_default_cell>
              <.table_default_cell>ann@example.com</.table_default_cell>
              <.table_default_cell>Active</.table_default_cell>
              <.table_default_cell>…</.table_default_cell>
            </.table_default_row>
          </.table_default_body>
        </.table_default>
        """)

      assert html =~ ~s(id="people-fit")
      assert html =~ ~s(phx-hook="TableFit")
      # the first-paint restore sits right after the wrapper it reads
      assert html =~ ~r{</table>\s*</div>\s*<script>}
      assert html =~ "phoenix_kit:table-fit:"
      assert html =~ ~r/<th[^>]*data-col-lead[^>]*>\s*Name/
      assert html =~ ~r/<th[^>]*data-col-priority="3"[^>]*style="width: 8rem; min-width: 8rem"/
      assert html =~ ~r/<th[^>]*data-col-priority="1"/
      assert html =~ ~r/<td[^>]*data-col-lead[^>]*>\s*Ann/
      # the actions header and the plain body cells declare nothing
      assert length(Regex.scan(~r/data-col-priority/, html)) == 2
      assert length(Regex.scan(~r/data-col-lead/, html)) == 2 + lead_selector_count(html)
    end

    test "the card-capable path carries the hook too, beside TableCardView" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.table_default id="people" fit toggleable>
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell lead>Name</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
        </.table_default>
        """)

      assert html =~ ~s(phx-hook="TableCardView")

      assert html =~
               ~r/id="people-fit"[^>]*phx-hook="TableFit"|phx-hook="TableFit"[^>]*id="people-fit"/
    end

    test "a table without fit renders no hook and no column attributes" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.table_default id="people">
          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>Name</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>
        </.table_default>
        """)

      refute html =~ "TableFit"
      refute html =~ "data-col-"
      refute html =~ "<script>"
    end

    test "fit without an id is refused" do
      assigns = %{}

      assert_raise ArgumentError, ~r/needs an id/, fn ->
        rendered_to_string(~H"""
        <.table_default fit>
          <.table_default_header></.table_default_header>
        </.table_default>
        """)
      end
    end

    # The right-packing classes on <table> name `data-col-lead` in their
    # selectors; count those out so the assertion above is about cells.
    defp lead_selector_count(html) do
      [table_tag] = Regex.run(~r/<table[^>]*>/, html)
      length(Regex.scan(~r/data-col-lead/, table_tag))
    end
  end

  describe "table_default_row/1" do
    test "carries the `group/row` Tailwind marker for group-hover children" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.table_default_row>
          <td>row</td>
        </.table_default_row>
        """)

      assert result =~ "<tr"
      # `group/row` drives `group-hover/row:*` reveals keyed to row hover —
      # the row-menu ⋮ icon still relies on it (the drag handle no longer
      # does; it is always visible as of 2026-08-14). Named (not bare
      # `group`) so it doesn't clobber unnamed `group-hover:` utilities a
      # consumer nests inside a cell. Removing it would silently kill those
      # hover reveals.
      assert result =~ "group/row"
    end

    test "consumer class composes alongside `group/row`" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.table_default_row class="my-extra">
          <td>x</td>
        </.table_default_row>
        """)

      assert result =~ "group/row"
      assert result =~ "my-extra"
    end

    test "hover=false drops the hover class" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.table_default_row hover={false}>
          <td>x</td>
        </.table_default_row>
        """)

      # Should still have `group/row`, but the daisyUI `hover` class is gone.
      assert result =~ "group/row"
      refute result =~ ~s(class="group/row hover)
    end
  end

  # ── drag_handle_cell/1 + drag_handle_header_cell/1 ─────────────────

  describe "drag_handle_cell/1" do
    test "renders td with pk-drag-handle classes, always visible" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.drag_handle_cell />
        """)

      assert result =~ "<td"
      # SortableJS hook reads this selector for the drag handle.
      assert result =~ "pk-drag-handle"
      assert result =~ "cursor-grab"
      # Always visible (deliberate product call, 2026-08-14): an affordance
      # you cannot see is one nobody discovers. The old hide-until-hover
      # classes must NOT come back.
      refute result =~ "opacity-0"
      refute result =~ "group-hover/row:opacity-100"
      # Default heroicon for the handle.
      assert result =~ "hero-bars-3"
    end

    test "has a default title for accessibility" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.drag_handle_cell />
        """)

      assert result =~ "Drag to reorder"
    end

    test "custom title overrides default" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.drag_handle_cell title="Move me" />
        """)

      assert result =~ "Move me"
    end

    test "default width class matches the matching header cell" do
      assigns = %{}

      cell =
        rendered_to_string(~H"""
        <.drag_handle_cell />
        """)

      header =
        rendered_to_string(~H"""
        <.drag_handle_header_cell />
        """)

      # Both default to `w-8` so columns stay aligned without the consumer
      # repeating the width on both sides.
      assert cell =~ "w-8"
      assert header =~ "w-8"
    end
  end

  describe "drag_handle_header_cell/1" do
    test "renders an empty <th>" do
      assigns = %{}

      result =
        rendered_to_string(~H"""
        <.drag_handle_header_cell />
        """)

      assert result =~ "<th"
      assert result =~ "w-8"
    end
  end

  describe "search_toolbar/1 form wrapping (regression)" do
    test "always wraps the input in a form (phx-change outside a form is dead)" do
      # Regression: the no-on_submit branch used to render a bare <div> —
      # LiveView's client throws on phx-change for an input outside a form
      # and the event silently never reaches the server. First real caller
      # (CRM list members search) shipped against that trap.
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.search_toolbar value="" />
        """)

      assert html =~ "<form"
      assert html =~ ~s(phx-change="search")
      # Enter falls back to the change event when no on_submit is given.
      assert html =~ ~s(phx-submit="search")
    end

    test "explicit on_submit wins for the form's submit event" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.search_toolbar value="x" on_change="filter" on_submit="run_search" />
        """)

      assert html =~ ~s(phx-submit="run_search")
      assert html =~ ~s(phx-change="filter")
      assert html =~ ~s(value="x")
    end
  end

  # ── comfortable / compact / card toggle ───────────────────────────

  defp render_toggleable(assigns) do
    rendered_to_string(~H"""
    <.table_default id="items-table" toggleable items={[%{uuid: "1"}]} view_mode={@view_mode}>
      <tbody></tbody>
    </.table_default>
    """)
  end

  describe "view toggle (comfy)" do
    test "uncontrolled mode paints comfy first and exposes all three actions" do
      html = render_toggleable(%{view_mode: nil})

      assert html =~ ~s(data-view-action="card")
      assert html =~ ~s(data-view-action="comfy")
      assert html =~ ~s(data-view-action="table")
      # Marker class on the table wrapper (not the `[.pk-comfy_&]` utility).
      assert html =~ "hidden md:block pk-comfy"
      assert html =~ "Comfortable view"
      assert html =~ "Compact view"
    end

    test "controlled comfy marks the table and hides the card grid" do
      html = render_toggleable(%{view_mode: "comfy"})

      assert html =~ "block pk-comfy"
      assert html =~ ~s(phx-value-mode="comfy")
      assert html =~ ~s(btn-active)
    end

    test "controlled compact table does not carry the comfy marker" do
      html = render_toggleable(%{view_mode: "table"})

      refute html =~ "block pk-comfy"
      refute html =~ "hidden md:block pk-comfy"
      assert html =~ ~s(phx-value-mode="table")
    end
  end

  describe "toolbar_primary slot" do
    test "renders the primary action after the view toggle, actions before it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.table_default id="t" toggleable items={[]}>
          <.table_default_body></.table_default_body>
          <:toolbar_actions><span id="secondary">S</span></:toolbar_actions>
          <:toolbar_primary><a id="primary" href="/new">New</a></:toolbar_primary>
        </.table_default>
        """)

      {secondary, _} = :binary.match(html, ~s(id="secondary"))
      {toggle, _} = :binary.match(html, ~s(data-view-action="card"))
      {primary, _} = :binary.match(html, ~s(id="primary"))

      assert secondary < toggle
      assert toggle < primary
    end

    test "alone it still renders the toolbar row" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.table_default id="t" items={[%{uuid: "1"}]} show_toggle={false}>
          <.table_default_body></.table_default_body>
          <:toolbar_primary><a id="primary" href="/new">New</a></:toolbar_primary>
        </.table_default>
        """)

      assert html =~ ~s(id="primary")
      refute html =~ ~s(data-view-action)
    end

    # The plain table (an empty list, no card toggle) used to drop every
    # toolbar slot: a list lost its filters and its create button exactly
    # when it was empty.
    test "an empty list without a card toggle keeps its toolbar" do
      assigns = %{}

      for items <- [[], nil] do
        assigns = Map.put(assigns, :items, items || [])

        html =
          rendered_to_string(~H"""
          <.table_default id="t" items={@items}>
            <:toolbar_title>
              <form id="filters"></form>
            </:toolbar_title>
            <:toolbar_actions><span id="secondary">S</span></:toolbar_actions>
            <:toolbar_primary><a id="primary" href="/new">New</a></:toolbar_primary>
            <.table_default_body></.table_default_body>
          </.table_default>
          """)

        assert html =~ ~s(id="filters")
        assert html =~ ~s(id="secondary")
        assert html =~ ~s(id="primary")
        refute html =~ ~s(data-view-action)
      end
    end
  end
end
