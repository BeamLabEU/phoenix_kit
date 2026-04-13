defmodule PhoenixKit.Widgets.LoaderTest do
  use ExUnit.Case

  alias PhoenixKit.Widgets.Loader
  alias PhoenixKit.Widgets.Widget

  setup do
    # Enable test modules
    PhoenixKit.Modules.AI.enable_system()
    PhoenixKit.Modules.Billing.enable_system()

    on_exit(fn ->
      PhoenixKit.Modules.AI.disable_system()
      PhoenixKit.Modules.Billing.disable_system()
    end)

    :ok
  end

  describe "load_all_widgets/0" do
    test "loads widgets from enabled modules" do
      widgets = Loader.load_all_widgets()

      assert length(widgets) > 0
      assert Enum.all?(widgets, &is_struct(&1, Widget))
    end

    test "widgets are sorted by order" do
      widgets = Loader.load_all_widgets()

      orders = Enum.map(widgets, & &1.order)
      assert orders == Enum.sort(orders)
    end

    test "skips disabled modules" do
      PhoenixKit.Modules.Posts.disable_system()

      widgets = Loader.load_all_widgets()

      refute Enum.any?(widgets, &(&1.module == PhoenixKit.Modules.Posts))
    end
  end

  describe "load_module_widgets/1" do
    test "loads widgets from specific module" do
      widgets = Loader.load_module_widgets(PhoenixKit.Modules.AI)

      assert length(widgets) > 0
      assert Enum.all?(widgets, &(&1.module == PhoenixKit.Modules.AI))
    end

    test "returns empty list if module disabled" do
      PhoenixKit.Modules.AI.disable_system()

      widgets = Loader.load_module_widgets(PhoenixKit.Modules.AI)

      assert widgets == []
    end
  end

  describe "get_widget/1" do
    test "finds widget by id" do
      widget = Loader.get_widget("ai_usage_stats")

      assert widget.id == "ai_usage_stats"
      assert widget.module == PhoenixKit.Modules.AI
    end

    test "returns nil if widget not found" do
      widget = Loader.get_widget("nonexistent_widget")

      assert is_nil(widget)
    end
  end

  describe "get_widget_count_by_module/0" do
    test "returns widget count grouped by module" do
      counts = Loader.get_widget_count_by_module()

      assert is_map(counts)
      assert counts[PhoenixKit.Modules.AI] > 0
      assert counts[PhoenixKit.Modules.Billing] > 0
    end
  end
end
