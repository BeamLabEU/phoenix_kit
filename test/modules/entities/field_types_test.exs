defmodule PhoenixKit.Modules.Entities.FieldTypesTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Entities.FieldType
  alias PhoenixKit.Modules.Entities.FieldTypes

  # --- all/0 ---

  describe "all/0" do
    test "returns a map of FieldType structs" do
      result = FieldTypes.all()

      assert is_map(result)
      assert map_size(result) > 0

      Enum.each(result, fn {key, value} ->
        assert is_binary(key)
        assert %FieldType{} = value
      end)
    end

    test "includes all expected field types" do
      result = FieldTypes.all()

      expected =
        ~w(text textarea email url rich_text number boolean date select radio checkbox file)

      for type <- expected do
        assert Map.has_key?(result, type), "Missing field type: #{type}"
      end
    end
  end

  # --- list_types/0 ---

  describe "list_types/0" do
    test "returns list of strings" do
      result = FieldTypes.list_types()
      assert is_list(result)
      assert Enum.all?(result, &is_binary/1)
    end

    test "includes core types" do
      types = FieldTypes.list_types()
      assert "text" in types
      assert "select" in types
      assert "number" in types
      assert "boolean" in types
    end
  end

  # --- get_type/1 ---

  describe "get_type/1" do
    test "returns FieldType struct for valid type" do
      result = FieldTypes.get_type("text")

      assert %FieldType{} = result
      assert result.name == "text"
      assert result.label == "Text"
      assert result.category == :basic
    end

    test "returns nil for invalid type" do
      assert FieldTypes.get_type("nonexistent") == nil
    end

    test "returns correct info for choice type" do
      result = FieldTypes.get_type("select")

      assert result.name == "select"
      assert result.requires_options == true
      assert result.category == :choice
    end

    test "returns correct info for number type" do
      result = FieldTypes.get_type("number")

      assert result.category == :numeric
      assert result.requires_options == false
    end
  end

  # --- valid_type?/1 ---

  describe "valid_type?/1" do
    test "returns true for all known types" do
      for type <- FieldTypes.list_types() do
        assert FieldTypes.valid_type?(type), "Expected #{type} to be valid"
      end
    end

    test "returns false for unknown types" do
      refute FieldTypes.valid_type?("invalid")
      refute FieldTypes.valid_type?("xml")
      refute FieldTypes.valid_type?("")
    end
  end

  # --- by_category/1 ---

  describe "by_category/1" do
    test "returns basic field types" do
      result = FieldTypes.by_category(:basic)

      assert is_list(result)
      assert result != []

      names = Enum.map(result, & &1.name)
      assert "text" in names
      assert "textarea" in names
    end

    test "returns choice field types" do
      result = FieldTypes.by_category(:choice)
      names = Enum.map(result, & &1.name)

      assert "select" in names
      assert "radio" in names
      assert "checkbox" in names
    end

    test "returns empty list for nonexistent category" do
      assert FieldTypes.by_category(:nonexistent) == []
    end

    test "all returned types have matching category" do
      for {category, _label} <- FieldTypes.category_list() do
        types = FieldTypes.by_category(category)

        Enum.each(types, fn type ->
          assert type.category == category
        end)
      end
    end
  end

  # --- categories/0 ---

  describe "categories/0" do
    test "returns map grouped by category atom" do
      result = FieldTypes.categories()

      assert is_map(result)
      assert Map.has_key?(result, :basic)
      assert Map.has_key?(result, :choice)
    end

    test "every type appears in exactly one category" do
      result = FieldTypes.categories()

      all_names =
        result
        |> Map.values()
        |> List.flatten()
        |> Enum.map(& &1.name)

      assert length(all_names) == length(Enum.uniq(all_names))
      assert length(all_names) == map_size(FieldTypes.all())
    end
  end

  # --- category_list/0 ---

  describe "category_list/0" do
    test "returns list of {atom, string} tuples" do
      result = FieldTypes.category_list()

      assert is_list(result)

      Enum.each(result, fn {key, label} ->
        assert is_atom(key)
        assert is_binary(label)
      end)
    end

    test "includes expected categories" do
      keys = FieldTypes.category_list() |> Enum.map(&elem(&1, 0))

      assert :basic in keys
      assert :numeric in keys
      assert :choice in keys
    end
  end

  # --- requires_options?/1 ---

  describe "requires_options?/1" do
    test "returns true for select, radio, checkbox" do
      assert FieldTypes.requires_options?("select")
      assert FieldTypes.requires_options?("radio")
      assert FieldTypes.requires_options?("checkbox")
    end

    test "returns false for text, number, boolean" do
      refute FieldTypes.requires_options?("text")
      refute FieldTypes.requires_options?("number")
      refute FieldTypes.requires_options?("boolean")
    end

    test "returns false for unknown type" do
      refute FieldTypes.requires_options?("unknown")
    end
  end

  # --- default_props/1 ---

  describe "default_props/1" do
    test "returns props for text type" do
      props = FieldTypes.default_props("text")
      assert is_map(props)
      assert Map.has_key?(props, "max_length")
    end

    test "returns props for textarea type" do
      props = FieldTypes.default_props("textarea")
      assert Map.has_key?(props, "rows")
      assert Map.has_key?(props, "max_length")
    end

    test "returns empty map for unknown type" do
      assert FieldTypes.default_props("unknown") == %{}
    end
  end

  # --- for_picker/0 ---

  describe "for_picker/0" do
    test "returns list of maps with expected keys" do
      result = FieldTypes.for_picker()

      assert is_list(result)
      assert result != []

      Enum.each(result, fn item ->
        assert Map.has_key?(item, :value)
        assert Map.has_key?(item, :label)
        assert Map.has_key?(item, :category)
        assert Map.has_key?(item, :icon)
      end)
    end
  end

  # --- validate_field/1 ---

  describe "validate_field/1" do
    test "validates a valid text field" do
      field = %{"type" => "text", "key" => "title", "label" => "Title"}
      assert {:ok, ^field} = FieldTypes.validate_field(field)
    end

    test "validates a valid select field with options" do
      field = %{
        "type" => "select",
        "key" => "category",
        "label" => "Category",
        "options" => ["A", "B"]
      }

      assert {:ok, ^field} = FieldTypes.validate_field(field)
    end

    test "rejects missing required keys" do
      assert {:error, msg} = FieldTypes.validate_field(%{"type" => "text"})
      assert msg =~ "Missing required keys"
    end

    test "rejects invalid field type" do
      field = %{"type" => "invalid", "key" => "test", "label" => "Test"}
      assert {:error, msg} = FieldTypes.validate_field(field)
      assert msg =~ "Invalid field type"
    end

    test "rejects select field without options" do
      field = %{"type" => "select", "key" => "cat", "label" => "Category"}
      assert {:error, msg} = FieldTypes.validate_field(field)
      assert msg =~ "requires options"
    end

    test "rejects select field with empty options" do
      field = %{"type" => "select", "key" => "cat", "label" => "Category", "options" => []}
      assert {:error, msg} = FieldTypes.validate_field(field)
      assert msg =~ "requires options"
    end
  end

  # --- new_field/4 ---

  describe "new_field/4" do
    test "creates a text field with defaults" do
      result = FieldTypes.new_field("text", "name", "Name")

      assert result["type"] == "text"
      assert result["key"] == "name"
      assert result["label"] == "Name"
      assert result["required"] == false
      assert Map.has_key?(result, "max_length")
    end

    test "creates a field with required flag" do
      result = FieldTypes.new_field("text", "name", "Name", required: true)
      assert result["required"] == true
    end

    test "creates a select field with options" do
      result = FieldTypes.new_field("select", "status", "Status", options: ["A", "B"])

      assert result["type"] == "select"
      assert result["options"] == ["A", "B"]
    end

    test "merges type-specific default props" do
      result = FieldTypes.new_field("textarea", "bio", "Biography")
      assert Map.has_key?(result, "rows")
    end

    test "accepts custom default value for types without default_props default" do
      result = FieldTypes.new_field("text", "name", "Name", default: "untitled")
      assert result["default"] == "untitled"
    end
  end

  # --- Builder helpers ---

  describe "builder helpers" do
    test "text_field/3" do
      result = FieldTypes.text_field("name", "Name", required: true)
      assert result["type"] == "text"
      assert result["key"] == "name"
      assert result["required"] == true
    end

    test "textarea_field/3" do
      result = FieldTypes.textarea_field("bio", "Bio")
      assert result["type"] == "textarea"
      assert Map.has_key?(result, "rows")
    end

    test "email_field/3" do
      result = FieldTypes.email_field("email", "Email")
      assert result["type"] == "email"
    end

    test "number_field/3" do
      result = FieldTypes.number_field("age", "Age")
      assert result["type"] == "number"
    end

    test "boolean_field/3" do
      result = FieldTypes.boolean_field("active", "Active")
      assert result["type"] == "boolean"
      # Boolean type has default_props %{"default" => false} which merges last
      assert result["default"] == false
    end

    test "rich_text_field/3" do
      result = FieldTypes.rich_text_field("content", "Content")
      assert result["type"] == "rich_text"
    end

    test "select_field/4" do
      result = FieldTypes.select_field("cat", "Category", ["A", "B"])
      assert result["type"] == "select"
      assert result["options"] == ["A", "B"]
    end

    test "radio_field/4" do
      result = FieldTypes.radio_field("priority", "Priority", ["Low", "High"])
      assert result["type"] == "radio"
      assert result["options"] == ["Low", "High"]
    end

    test "checkbox_field/4" do
      result = FieldTypes.checkbox_field("tags", "Tags", ["A", "B", "C"])
      assert result["type"] == "checkbox"
      assert result["options"] == ["A", "B", "C"]
    end

    test "file_field/3" do
      result = FieldTypes.file_field("docs", "Docs")
      assert result["type"] == "file"
      assert Map.has_key?(result, "max_entries")
      assert Map.has_key?(result, "max_file_size")
      assert Map.has_key?(result, "accept")
    end

    test "file_field/3 with custom constraints" do
      result =
        FieldTypes.file_field("docs", "Docs",
          max_entries: 10,
          max_file_size: 52_428_800,
          accept: [".pdf"]
        )

      assert result["max_entries"] == 10
      assert result["max_file_size"] == 52_428_800
      assert result["accept"] == [".pdf"]
    end
  end
end
