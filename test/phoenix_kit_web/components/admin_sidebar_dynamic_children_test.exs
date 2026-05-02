defmodule PhoenixKitWeb.Components.Dashboard.AdminSidebarDynamicChildrenTest do
  @moduledoc """
  Unit tests for the arity-dispatching `dynamic_children` callback handling in
  `PhoenixKitWeb.Components.Dashboard.AdminSidebar`. The internal helper
  `invoke_dynamic_children/3` is private, so the suite reaches it via the
  `@doc false` test-only delegate `__invoke_dynamic_children_for_test__/3`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab
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
end
