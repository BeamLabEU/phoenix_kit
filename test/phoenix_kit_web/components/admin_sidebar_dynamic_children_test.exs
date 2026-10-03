defmodule PhoenixKitWeb.Components.Dashboard.AdminSidebarDynamicChildrenTest do
  @moduledoc """
  Unit tests for the arity-dispatching `dynamic_children` callback handling in
  `PhoenixKitWeb.Components.Dashboard.AdminSidebar`. The internal helper
  `invoke_dynamic_children/3` is private, so the suite reaches it via the
  `@doc false` test-only delegate `__invoke_dynamic_children_for_test__/3`.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Dashboard.TabHelpers
  alias PhoenixKitWeb.Components.Dashboard.AdminSidebar

  describe "dynamic_children_fn type" do
    test "arity-1 function is a valid dynamic_children_fn" do
      fun = fn _scope -> [] end
      assert is_function(fun, 1)
      # Matches Tab.dynamic_children_fn :: (map() -> [t()]) branch
      tab =
        Tab.new!(
          id: :test_arity_one,
          label: "Arity One",
          path: "one",
          priority: 1,
          level: :admin,
          dynamic_children: fun
        )

      assert is_function(tab.dynamic_children, 1)
    end

    test "arity-2 function is a valid dynamic_children_fn" do
      fun = fn _scope, _locale -> [] end
      assert is_function(fun, 2)
      # Matches Tab.dynamic_children_fn :: (map(), String.t() | nil -> [t()]) branch
      tab =
        Tab.new!(
          id: :test_arity_two,
          label: "Arity Two",
          path: "two",
          priority: 1,
          level: :admin,
          dynamic_children: fun
        )

      assert is_function(tab.dynamic_children, 2)
    end
  end

  describe "expand_dynamic_children/3 keeps the priority order" do
    # The sidebar draws `tabs` in the order this returns, grouped. Parents with
    # dynamic_children used to be moved behind every other tab, so they were
    # drawn last in their group whatever their priority.
    test "a tab with dynamic_children stays where its priority puts it" do
      child = Tab.new!(id: :order_child, label: "Child", path: "c", priority: 1, level: :admin)

      tabs = [
        Tab.new!(id: :order_first, label: "First", path: "a", priority: 100, level: :admin),
        Tab.new!(
          id: :order_dynamic,
          label: "Dynamic",
          path: "b",
          priority: 200,
          level: :admin,
          dynamic_children: fn _scope -> [child] end
        ),
        Tab.new!(id: :order_last, label: "Last", path: "d", priority: 300, level: :admin)
      ]

      expanded = AdminSidebar.__expand_dynamic_children_for_test__(tabs, %{}, "en")

      assert Enum.map(expanded, & &1.id) == [
               :order_first,
               :order_dynamic,
               :order_last,
               :order_child
             ]

      assert Enum.find(expanded, &(&1.id == :order_child)).parent == :order_dynamic
    end
  end

  describe "invoke_dynamic_children/3 dispatch (via __invoke_dynamic_children_for_test__/3)" do
    test "arity-1 callback receives only the scope" do
      parent = self()

      fun = fn scope ->
        send(parent, {:called_with, :arity_1, scope})
        []
      end

      assert AdminSidebar.__invoke_dynamic_children_for_test__(fun, %{user: :alice}, "en-US") ==
               []

      assert_received {:called_with, :arity_1, %{user: :alice}}
    end

    test "arity-2 callback receives both scope and locale" do
      parent = self()

      fun = fn scope, locale ->
        send(parent, {:called_with, :arity_2, scope, locale})
        []
      end

      assert AdminSidebar.__invoke_dynamic_children_for_test__(fun, %{user: :bob}, "ja-JP") == []
      assert_received {:called_with, :arity_2, %{user: :bob}, "ja-JP"}
    end

    test "arity-2 callback handles a nil locale gracefully" do
      parent = self()

      fun = fn _scope, locale ->
        send(parent, {:locale_received, locale})
        []
      end

      AdminSidebar.__invoke_dynamic_children_for_test__(fun, %{}, nil)
      assert_received {:locale_received, nil}
    end

    test "callback's return value is propagated" do
      tab =
        Tab.new!(
          id: :child_one,
          label: "Child",
          path: "child",
          priority: 1,
          level: :admin
        )

      arity_1 = fn _scope -> [tab] end
      arity_2 = fn _scope, _locale -> [tab] end

      assert AdminSidebar.__invoke_dynamic_children_for_test__(arity_1, %{}, "en") == [tab]
      assert AdminSidebar.__invoke_dynamic_children_for_test__(arity_2, %{}, "en") == [tab]
    end
  end

  describe "compact-mode flyout markup" do
    # The rail shows an icon and nothing else, so the flyout is where an entry
    # says its own name and offers its children. Rendered for EVERY navigable
    # top-level entry, not only the active one — `subtab_display` defaults to
    # `:when_active`, so the inline list exists only for the section you are
    # already in, which is exactly the browsing the rail would otherwise lose.

    # Absolute paths: the Dashboard Registry resolves a tab's relative slug
    # (`"settings"`) against its context prefix before anything renders, and
    # this suite skips the Registry.
    defp parent_row(opts \\ []) do
      parent =
        Tab.new!(
          id: :settings,
          label: "Settings",
          path: "/admin/settings",
          icon: "hero-cog",
          level: :admin
        )

      children =
        for {id, label} <- Keyword.get(opts, :children, users: "Users", media: "Media") do
          Tab.new!(
            id: id,
            label: label,
            path: "/admin/settings/#{id}",
            icon: "hero-user",
            level: :admin,
            parent: :settings
          )
        end

      # Through the same helper the sidebar uses: it `Map.put`s `:active` onto
      # each tab, and the row components read that key directly.
      [parent | children] =
        TabHelpers.add_active_state([parent | children], "/admin/nowhere")

      render_component(&AdminSidebar.__tab_with_subtabs_for_test__/1,
        tab: parent,
        all_tabs: [parent | children],
        locale: nil
      )
    end

    test "the row points at its own flyout" do
      html = parent_row()

      assert html =~ ~s(data-pk-flyout-id="pk-flyout-settings")
      assert html =~ ~s(id="pk-flyout-settings")
      assert html =~ ~s(popover="auto")
    end

    test "the flyout names the parent" do
      # The point of the whole thing: collapsed, the parent's own label is
      # off-screen, so the flyout has to say what the icon means.
      html = parent_row()

      assert html =~ "pk-sidebar-flyout-title"
      assert html =~ "Settings"
    end

    test "the flyout lists the children even though the section is not active" do
      html = parent_row()

      assert html =~ "Users"
      assert html =~ "Media"
    end

    test "a childless entry still gets a flyout, holding just its name" do
      # Otherwise the rail is unreadable for exactly the items with no children
      # to explain them.
      html = parent_row(children: [])

      assert html =~ ~s(id="pk-flyout-settings")
      assert html =~ "pk-sidebar-flyout-title"
    end

    test "a section holding the active page is marked on the rail" do
      # Expanded, `admin_tab_with_subtabs/1` moves the highlight off the parent
      # and onto the active subtab. Collapsed, that subtab row is hidden — so
      # the parent has to state the fact and let the rail's CSS paint it, or
      # nothing on screen says which section you are in.
      parent =
        Tab.new!(
          id: :settings,
          label: "Settings",
          path: "/admin/settings",
          icon: "hero-cog",
          level: :admin
        )

      child =
        Tab.new!(
          id: :users,
          label: "Users",
          path: "/admin/settings/users",
          icon: "hero-user",
          level: :admin,
          parent: :settings
        )

      tabs = TabHelpers.add_active_state([parent, child], "/admin/settings/users")
      [parent | _] = tabs

      html =
        render_component(&AdminSidebar.__tab_with_subtabs_for_test__/1,
          tab: parent,
          all_tabs: tabs,
          locale: nil
        )

      assert html =~ ~s(data-pk-branch-active="true")
    end

    test "a section holding nothing active is not marked" do
      assert parent_row() =~ ~s(data-pk-branch-active="false")
    end

    test "the flyout sits immediately after the link, so Tab walks into it" do
      # The top layer changes PAINTING, not the DOM tree — focus order still
      # follows this position.
      html = parent_row()

      link = :binary.match(html, ~s(data-tab-id="settings")) |> elem(0)
      panel = :binary.match(html, ~s(id="pk-flyout-settings")) |> elem(0)

      assert link < panel
    end
  end
end
