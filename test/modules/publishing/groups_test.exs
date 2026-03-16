defmodule PhoenixKit.Modules.Publishing.GroupsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Groups

  # ============================================================================
  # preset_types/0
  # ============================================================================

  describe "preset_types/0" do
    test "returns list of preset type maps" do
      types = Groups.preset_types()
      assert is_list(types)
      assert length(types) == 3

      labels = Enum.map(types, & &1.type)
      assert "blog" in labels
      assert "faq" in labels
      assert "legal" in labels
    end

    test "each preset has type, label, item_singular, item_plural" do
      for preset <- Groups.preset_types() do
        assert is_binary(preset.type)
        assert is_binary(preset.label)
        assert is_binary(preset.item_singular)
        assert is_binary(preset.item_plural)
      end
    end

    test "blog preset has post/posts item names" do
      blog = Enum.find(Groups.preset_types(), &(&1.type == "blog"))
      assert blog.item_singular == "post"
      assert blog.item_plural == "posts"
    end

    test "faq preset has question/questions item names" do
      faq = Enum.find(Groups.preset_types(), &(&1.type == "faq"))
      assert faq.item_singular == "question"
      assert faq.item_plural == "questions"
    end

    test "legal preset has document/documents item names" do
      legal = Enum.find(Groups.preset_types(), &(&1.type == "legal"))
      assert legal.item_singular == "document"
      assert legal.item_plural == "documents"
    end
  end

  # ============================================================================
  # valid_types/0
  # ============================================================================

  describe "valid_types/0" do
    test "returns list of valid type strings" do
      types = Groups.valid_types()
      assert is_list(types)
      assert "blog" in types
      assert "faq" in types
      assert "legal" in types
      assert "custom" in types
    end

    test "includes custom type" do
      assert "custom" in Groups.valid_types()
    end
  end

  # ============================================================================
  # fetch_option/2
  # ============================================================================

  describe "fetch_option/2" do
    test "fetches atom key from map" do
      assert Groups.fetch_option(%{mode: "slug"}, :mode) == "slug"
    end

    test "fetches string key from map as fallback" do
      assert Groups.fetch_option(%{"mode" => "slug"}, :mode) == "slug"
    end

    test "fetches from keyword list" do
      assert Groups.fetch_option([mode: "slug"], :mode) == "slug"
    end

    test "returns nil for missing key" do
      assert Groups.fetch_option(%{}, :mode) == nil
    end

    test "returns nil for non-container" do
      assert Groups.fetch_option(nil, :mode) == nil
    end
  end
end
