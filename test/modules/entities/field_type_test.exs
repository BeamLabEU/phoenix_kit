defmodule PhoenixKit.Modules.Entities.FieldTypeTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Entities.FieldType

  # --- from_map/1 ---

  describe "from_map/1" do
    test "converts atom-key map to struct" do
      map = %{
        name: "text",
        label: "Text",
        description: "Single-line text input",
        category: :basic,
        icon: "hero-pencil",
        requires_options: false,
        default_props: %{"max_length" => 255}
      }

      result = FieldType.from_map(map)

      assert %FieldType{} = result
      assert result.name == "text"
      assert result.label == "Text"
      assert result.description == "Single-line text input"
      assert result.category == :basic
      assert result.icon == "hero-pencil"
      assert result.requires_options == false
      assert result.default_props == %{"max_length" => 255}
    end

    test "converts string-key map to struct" do
      map = %{
        "name" => "select",
        "label" => "Select",
        "description" => "Dropdown",
        "category" => :choice,
        "icon" => "hero-chevron-down",
        "requires_options" => true,
        "default_props" => %{}
      }

      result = FieldType.from_map(map)

      assert result.name == "select"
      assert result.label == "Select"
      assert result.requires_options == true
      assert result.category == :choice
    end

    test "defaults requires_options to false" do
      map = %{name: "custom", label: "Custom", category: :basic}
      result = FieldType.from_map(map)

      assert result.requires_options == false
    end

    test "defaults default_props to empty map" do
      map = %{name: "custom", label: "Custom", category: :basic}
      result = FieldType.from_map(map)

      assert result.default_props == %{}
    end

    test "handles nil description and icon" do
      map = %{name: "custom", label: "Custom", category: :basic}
      result = FieldType.from_map(map)

      assert result.description == nil
      assert result.icon == nil
    end
  end
end
