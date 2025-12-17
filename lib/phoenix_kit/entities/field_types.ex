defmodule PhoenixKit.Entities.FieldTypes do
  @moduledoc """
  Field type definitions and utilities for the Entities system.

  This module defines all supported field types for entity definitions,
  including their properties, validation rules, and rendering information.

  ## Supported Field Types

  ### Basic Text Types
  - **text**: Single-line text input
  - **textarea**: Multi-line text area
  - **email**: Email address with validation
  - **url**: URL with validation
  - **rich_text**: Rich HTML editor (TinyMCE/CKEditor-like)

  ### Numeric Types
  - **number**: Numeric input (integer or decimal)

  ### Boolean Types
  - **boolean**: True/false toggle or checkbox

  ### Date/Time Types
  - **date**: Date picker (YYYY-MM-DD format)

  ### Choice Types
  - **select**: Dropdown selection (single choice)
  - **radio**: Radio button group (single choice)
  - **checkbox**: Checkbox group (multiple choices)

  ## Usage Examples

      # Get all field types
      field_types = PhoenixKit.Entities.FieldTypes.all()

      # Get field type info
      text_info = PhoenixKit.Entities.FieldTypes.get_type("text")

      # Get field types by category
      basic_types = PhoenixKit.Entities.FieldTypes.by_category(:basic)

      # Check if field type requires options
      PhoenixKit.Entities.FieldTypes.requires_options?("select") # => true
  """

  @type field_type :: String.t()
  @type field_category ::
          :basic | :numeric | :boolean | :datetime | :choice

  @field_types %{
    "text" => %{
      name: "text",
      label: "Text",
      description: "Single-line text input",
      category: :basic,
      icon: "hero-pencil",
      requires_options: false,
      default_props: %{
        "placeholder" => "",
        "max_length" => 255
      }
    },
    "textarea" => %{
      name: "textarea",
      label: "Text Area",
      description: "Multi-line text input",
      category: :basic,
      icon: "hero-document-text",
      requires_options: false,
      default_props: %{
        "placeholder" => "",
        "rows" => 4,
        "max_length" => 5000
      }
    },
    "email" => %{
      name: "email",
      label: "Email",
      description: "Email address with validation",
      category: :basic,
      icon: "hero-envelope",
      requires_options: false,
      default_props: %{
        "placeholder" => "user@example.com"
      }
    },
    "url" => %{
      name: "url",
      label: "URL",
      description: "Website URL with validation",
      category: :basic,
      icon: "hero-link",
      requires_options: false,
      default_props: %{
        "placeholder" => "https://example.com"
      }
    },
    "rich_text" => %{
      name: "rich_text",
      label: "Rich Text Editor",
      description: "WYSIWYG HTML editor",
      category: :basic,
      icon: "hero-document-text",
      requires_options: false,
      default_props: %{
        "toolbar" => "basic"
      }
    },
    "number" => %{
      name: "number",
      label: "Number",
      description: "Numeric input (integer or decimal)",
      category: :numeric,
      icon: "hero-hashtag",
      requires_options: false,
      default_props: %{
        "min" => nil,
        "max" => nil,
        "step" => 1
      }
    },
    "boolean" => %{
      name: "boolean",
      label: "Boolean",
      description: "True/false toggle",
      category: :boolean,
      icon: "hero-check-circle",
      requires_options: false,
      default_props: %{
        "default" => false
      }
    },
    "date" => %{
      name: "date",
      label: "Date",
      description: "Date picker",
      category: :datetime,
      icon: "hero-calendar",
      requires_options: false,
      default_props: %{
        "format" => "Y-m-d"
      }
    },
    "select" => %{
      name: "select",
      label: "Select Dropdown",
      description: "Dropdown selection (single choice)",
      category: :choice,
      icon: "hero-chevron-down",
      requires_options: true,
      default_props: %{
        "placeholder" => "Select an option...",
        "allow_empty" => true
      }
    },
    "radio" => %{
      name: "radio",
      label: "Radio Buttons",
      description: "Radio button group (single choice)",
      category: :choice,
      icon: "hero-check-circle",
      requires_options: true,
      default_props: %{}
    },
    "checkbox" => %{
      name: "checkbox",
      label: "Checkboxes",
      description: "Checkbox group (multiple choices)",
      category: :choice,
      icon: "hero-check",
      requires_options: true,
      default_props: %{
        "allow_multiple" => true
      }
    }
  }

  @doc """
  Returns all field types as a map.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.all()
      %{"text" => %{name: "text", ...}, ...}
  """
  def all do
    @field_types
  end

  @doc """
  Returns a list of all field type names.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.list_types()
      ["text", "textarea", "number", ...]
  """
  def list_types do
    Map.keys(@field_types)
  end

  @doc """
  Gets information about a specific field type.

  Returns nil if the type doesn't exist.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.get_type("text")
      %{name: "text", label: "Text", ...}

      iex> PhoenixKit.Entities.FieldTypes.get_type("invalid")
      nil
  """
  def get_type(type_name) when is_binary(type_name) do
    Map.get(@field_types, type_name)
  end

  @doc """
  Checks if a field type exists.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.valid_type?("text")
      true

      iex> PhoenixKit.Entities.FieldTypes.valid_type?("invalid")
      false
  """
  def valid_type?(type_name) when is_binary(type_name) do
    Map.has_key?(@field_types, type_name)
  end

  @doc """
  Returns field types grouped by category.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.by_category(:basic)
      [%{name: "text", ...}, %{name: "textarea", ...}, ...]
  """
  def by_category(category) when is_atom(category) do
    @field_types
    |> Map.values()
    |> Enum.filter(fn type -> type.category == category end)
  end

  @doc """
  Returns all categories with their field types.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.categories()
      %{
        basic: [%{name: "text", ...}, ...],
        numeric: [%{name: "number", ...}],
        ...
      }
  """
  def categories do
    @field_types
    |> Map.values()
    |> Enum.group_by(& &1.category)
  end

  @doc """
  Returns a list of category names with labels.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.category_list()
      [
        {:basic, "Basic"},
        {:numeric, "Numeric"},
        ...
      ]
  """
  def category_list do
    [
      {:basic, "Basic"},
      {:numeric, "Numeric"},
      {:boolean, "Boolean"},
      {:datetime, "Date & Time"},
      {:choice, "Choice"}
    ]
  end

  @doc """
  Checks if a field type requires options to be defined.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.requires_options?("select")
      true

      iex> PhoenixKit.Entities.FieldTypes.requires_options?("text")
      false
  """
  def requires_options?(type_name) when is_binary(type_name) do
    case get_type(type_name) do
      nil -> false
      type_info -> Map.get(type_info, :requires_options, false)
    end
  end

  @doc """
  Gets the default properties for a field type.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.default_props("text")
      %{"placeholder" => "", "max_length" => 255}
  """
  def default_props(type_name) when is_binary(type_name) do
    case get_type(type_name) do
      nil -> %{}
      type_info -> Map.get(type_info, :default_props, %{})
    end
  end

  @doc """
  Returns field types suitable for a field picker UI.

  Formats the data for use in select dropdowns or type choosers.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.for_picker()
      [
        %{value: "text", label: "Text", category: "Basic", icon: "hero-pencil"},
        ...
      ]
  """
  def for_picker do
    category_labels = Map.new(category_list())

    @field_types
    |> Map.values()
    |> Enum.map(fn type ->
      %{
        value: type.name,
        label: type.label,
        description: type.description,
        category: Map.get(category_labels, type.category, "Other"),
        icon: type.icon,
        requires_options: type.requires_options
      }
    end)
    |> Enum.sort_by(& &1.category)
  end

  @doc """
  Validates a field definition map.

  Checks that the field has all required properties and valid values.

  ## Examples

      iex> field = %{"type" => "text", "key" => "title", "label" => "Title"}
      iex> PhoenixKit.Entities.FieldTypes.validate_field(field)
      {:ok, field}

      iex> invalid_field = %{"type" => "invalid", "key" => "test"}
      iex> PhoenixKit.Entities.FieldTypes.validate_field(invalid_field)
      {:error, "Invalid field type: invalid"}
  """
  def validate_field(field) when is_map(field) do
    with {:ok, field} <- validate_required_keys(field),
         {:ok, field} <- validate_type(field) do
      validate_options(field)
    end
  end

  defp validate_required_keys(field) do
    required = ["type", "key", "label"]
    missing = required -- Map.keys(field)

    if Enum.empty?(missing) do
      {:ok, field}
    else
      {:error, "Missing required keys: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_type(field) do
    if valid_type?(field["type"]) do
      {:ok, field}
    else
      {:error, "Invalid field type: #{field["type"]}"}
    end
  end

  defp validate_options(field) do
    if requires_options?(field["type"]) do
      options = Map.get(field, "options", [])

      if is_list(options) && not Enum.empty?(options) do
        {:ok, field}
      else
        {:error, "Field type '#{field["type"]}' requires options"}
      end
    else
      {:ok, field}
    end
  end

  @doc """
  Creates a new field definition with default values.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.new_field("text", "my_field", "My Field")
      %{
        "type" => "text",
        "key" => "my_field",
        "label" => "My Field",
        "required" => false,
        "default" => "",
        "validation" => %{},
        "placeholder" => "",
        "max_length" => 255
      }

      # With options for choice fields
      iex> PhoenixKit.Entities.FieldTypes.new_field("select", "category", "Category", options: ["Tech", "Business"])
      %{
        "type" => "select",
        "key" => "category",
        "label" => "Category",
        "required" => false,
        "options" => ["Tech", "Business"],
        ...
      }

      # With required flag
      iex> PhoenixKit.Entities.FieldTypes.new_field("text", "name", "Name", required: true)
      %{"type" => "text", "key" => "name", "label" => "Name", "required" => true, ...}
  """
  def new_field(type, key, label, opts \\ [])

  def new_field(type, key, label, opts)
      when is_binary(type) and is_binary(key) and is_binary(label) do
    options = Keyword.get(opts, :options, [])
    required = Keyword.get(opts, :required, false)
    default = Keyword.get(opts, :default, nil)

    base_field = %{
      "type" => type,
      "key" => key,
      "label" => label,
      "required" => required,
      "default" => default,
      "validation" => %{}
    }

    # Add options for choice fields
    base_field =
      if requires_options?(type) or options != [] do
        Map.put(base_field, "options", options)
      else
        base_field
      end

    # Merge with type-specific default props
    props = default_props(type)
    Map.merge(base_field, props)
  end

  @doc """
  Helper to create a select field with options.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.select_field("category", "Category", ["Tech", "Business", "Other"])
      %{"type" => "select", "key" => "category", "label" => "Category", "options" => ["Tech", "Business", "Other"], ...}

      iex> PhoenixKit.Entities.FieldTypes.select_field("status", "Status", ["Active", "Inactive"], required: true)
      %{"type" => "select", "key" => "status", "label" => "Status", "options" => ["Active", "Inactive"], "required" => true, ...}
  """
  def select_field(key, label, options, opts \\ []) when is_list(options) do
    new_field("select", key, label, Keyword.put(opts, :options, options))
  end

  @doc """
  Helper to create a radio button field with options.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.radio_field("priority", "Priority", ["Low", "Medium", "High"])
      %{"type" => "radio", "key" => "priority", "label" => "Priority", "options" => ["Low", "Medium", "High"], ...}
  """
  def radio_field(key, label, options, opts \\ []) when is_list(options) do
    new_field("radio", key, label, Keyword.put(opts, :options, options))
  end

  @doc """
  Helper to create a checkbox field with options.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.checkbox_field("tags", "Tags", ["Featured", "Popular", "New"])
      %{"type" => "checkbox", "key" => "tags", "label" => "Tags", "options" => ["Featured", "Popular", "New"], ...}
  """
  def checkbox_field(key, label, options, opts \\ []) when is_list(options) do
    new_field("checkbox", key, label, Keyword.put(opts, :options, options))
  end

  @doc """
  Helper to create a text field.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.text_field("name", "Full Name", required: true)
      %{"type" => "text", "key" => "name", "label" => "Full Name", "required" => true, ...}
  """
  def text_field(key, label, opts \\ []) do
    new_field("text", key, label, opts)
  end

  @doc """
  Helper to create a textarea field.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.textarea_field("bio", "Biography")
      %{"type" => "textarea", "key" => "bio", "label" => "Biography", ...}
  """
  def textarea_field(key, label, opts \\ []) do
    new_field("textarea", key, label, opts)
  end

  @doc """
  Helper to create an email field.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.email_field("email", "Email Address", required: true)
      %{"type" => "email", "key" => "email", "label" => "Email Address", "required" => true, ...}
  """
  def email_field(key, label, opts \\ []) do
    new_field("email", key, label, opts)
  end

  @doc """
  Helper to create a number field.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.number_field("age", "Age")
      %{"type" => "number", "key" => "age", "label" => "Age", ...}
  """
  def number_field(key, label, opts \\ []) do
    new_field("number", key, label, opts)
  end

  @doc """
  Helper to create a boolean field.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.boolean_field("active", "Is Active", default: true)
      %{"type" => "boolean", "key" => "active", "label" => "Is Active", "default" => true, ...}
  """
  def boolean_field(key, label, opts \\ []) do
    new_field("boolean", key, label, opts)
  end

  @doc """
  Helper to create a rich text field.

  ## Examples

      iex> PhoenixKit.Entities.FieldTypes.rich_text_field("content", "Content", required: true)
      %{"type" => "rich_text", "key" => "content", "label" => "Content", "required" => true, ...}
  """
  def rich_text_field(key, label, opts \\ []) do
    new_field("rich_text", key, label, opts)
  end
end
