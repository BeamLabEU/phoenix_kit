defmodule PhoenixKit.Users.CustomFields do
  @moduledoc """
  Context for managing custom user field definitions.

  This module provides functionality to define, manage, and validate custom fields
  that can be added to user profiles. Field definitions are stored as JSON in the
  settings table, and actual field values are stored in the user's `custom_fields`
  JSONB column.

  ## Field Definition Structure

  Each field definition is a map with the following keys:

  - `key` - Unique identifier for the field (string)
  - `label` - Display label for the field (string)
  - `type` - Field type: text, textarea, number, boolean, date, email, url, select, radio, checkbox
  - `required` - Whether the field is required (boolean)
  - `position` - Display order (integer)
  - `enabled` - Whether the field is active (boolean)
  - `user_accessible` - Whether users can edit this field from their settings page (boolean, default: true)
  - `validation` - Optional validation rules (map)
  - `default` - Default value (string)
  - `options` - For select/radio/checkbox types (list of strings)

  ## Examples

      # Get all field definitions
      CustomFields.list_field_definitions()

      # Add a new field
      CustomFields.add_field_definition(%{
        "key" => "phone",
        "label" => "Phone Number",
        "type" => "text",
        "required" => false,
        "position" => 1,
        "enabled" => true
      })

      # Get system configuration
      CustomFields.get_config()
  """

  alias PhoenixKit.Settings

  @setting_key "custom_user_fields_definitions"

  @supported_types ~w(text textarea number boolean date email url select radio checkbox)

  # Field Definition Management

  @doc """
  Returns the list of all custom field definitions.

  ## Examples

      iex> list_field_definitions()
      [
        %{
          "key" => "phone",
          "label" => "Phone Number",
          "type" => "text",
          ...
        }
      ]
  """
  def list_field_definitions do
    case Settings.get_json_setting_cached(@setting_key, nil) do
      nil ->
        []

      # Handle new wrapped format: %{"fields" => [definitions]}
      %{"fields" => definitions} when is_list(definitions) ->
        definitions

      # Handle old format: direct list (for backward compatibility)
      definitions when is_list(definitions) ->
        definitions

      # Fallback: try reading from string field for backward compatibility
      _ ->
        case Settings.get_setting_cached(@setting_key) do
          nil -> []
          json_string when is_binary(json_string) -> parse_definitions(json_string)
          definitions when is_list(definitions) -> definitions
          _ -> []
        end
    end
  end

  @doc """
  Returns only enabled field definitions, sorted by position.

  ## Examples

      iex> list_enabled_field_definitions()
      [%{"key" => "phone", "enabled" => true, ...}]
  """
  def list_enabled_field_definitions do
    list_field_definitions()
    |> Enum.filter(&(&1["enabled"] == true))
    |> Enum.sort_by(&(&1["position"] || 0))
  end

  @doc """
  Returns only enabled field definitions that are user-accessible, sorted by position.

  These are fields that users can view and edit from their own settings page.
  Admins can always see and edit all fields regardless of this setting.

  Legacy fields without the `user_accessible` key default to `true` (accessible).

  ## Examples

      iex> list_user_accessible_field_definitions()
      [%{"key" => "phone", "enabled" => true, "user_accessible" => true, ...}]
  """
  def list_user_accessible_field_definitions do
    list_field_definitions()
    |> Enum.filter(fn field ->
      # Field must be enabled
      enabled = field["enabled"] == true

      # user_accessible defaults to true if not set (for legacy fields)
      user_accessible = Map.get(field, "user_accessible", true)

      enabled && user_accessible
    end)
    |> Enum.sort_by(&(&1["position"] || 0))
  end

  @doc """
  Gets a single field definition by key.

  Returns `nil` if not found.

  ## Examples

      iex> get_field_definition("phone")
      %{"key" => "phone", "label" => "Phone Number", ...}

      iex> get_field_definition("nonexistent")
      nil
  """
  def get_field_definition(key) when is_binary(key) do
    list_field_definitions()
    |> Enum.find(&(&1["key"] == key))
  end

  @doc """
  Saves the complete list of field definitions.

  ## Examples

      iex> save_field_definitions([%{"key" => "phone", ...}])
      {:ok, _setting}
  """
  def save_field_definitions(definitions) when is_list(definitions) do
    # Wrap the list in a map to match the database schema expectation
    Settings.update_json_setting(@setting_key, %{"fields" => definitions})
  end

  @doc """
  Adds a new field definition.

  Validates the field structure and ensures the key is unique.

  ## Examples

      iex> add_field_definition(%{"key" => "phone", "label" => "Phone", "type" => "text"})
      {:ok, _setting}

      iex> add_field_definition(%{"key" => "phone"})
      {:error, "Field with key 'phone' already exists"}
  """
  def add_field_definition(field_def) when is_map(field_def) do
    with :ok <- validate_field_definition(field_def),
         :ok <- ensure_unique_key(field_def["key"]) do
      definitions = list_field_definitions()
      new_definitions = definitions ++ [normalize_field_definition(field_def)]
      save_field_definitions(new_definitions)
    end
  end

  @doc """
  Updates an existing field definition.

  ## Examples

      iex> update_field_definition("phone", %{"label" => "Mobile Number"})
      {:ok, _setting}

      iex> update_field_definition("nonexistent", %{})
      {:error, "Field with key 'nonexistent' not found"}
  """
  def update_field_definition(key, updates) when is_binary(key) and is_map(updates) do
    definitions = list_field_definitions()

    case Enum.find_index(definitions, &(&1["key"] == key)) do
      nil ->
        {:error, "Field with key '#{key}' not found"}

      index ->
        existing = Enum.at(definitions, index)
        updated = Map.merge(existing, updates) |> normalize_field_definition()
        new_definitions = List.replace_at(definitions, index, updated)
        save_field_definitions(new_definitions)
    end
  end

  @doc """
  Deletes a field definition by key.

  ## Examples

      iex> delete_field_definition("phone")
      {:ok, _setting}
  """
  def delete_field_definition(key) when is_binary(key) do
    definitions = list_field_definitions()
    new_definitions = Enum.reject(definitions, &(&1["key"] == key))
    save_field_definitions(new_definitions)
  end

  @doc """
  Reorders field definitions by updating their position values.

  Accepts a list of keys in the desired order.

  ## Examples

      iex> reorder_field_definitions(["email", "phone", "department"])
      {:ok, _setting}
  """
  def reorder_field_definitions(ordered_keys) when is_list(ordered_keys) do
    definitions = list_field_definitions()

    # Create a map of key -> position
    position_map =
      ordered_keys
      |> Enum.with_index(1)
      |> Enum.into(%{})

    # Update positions
    updated_definitions =
      Enum.map(definitions, fn def ->
        Map.put(def, "position", position_map[def["key"]] || 999)
      end)
      |> Enum.sort_by(& &1["position"])

    save_field_definitions(updated_definitions)
  end

  # System Information

  @doc """
  Gets the current custom fields system configuration.

  Returns a map with field counts.

  ## Examples

      iex> get_config()
      %{
        field_count: 5,
        enabled_field_count: 3
      }
  """
  def get_config do
    definitions = list_field_definitions()
    enabled_definitions = Enum.filter(definitions, &(&1["enabled"] == true))

    %{
      field_count: length(definitions),
      enabled_field_count: length(enabled_definitions)
    }
  end

  # Validation

  @doc """
  Validates a field definition structure.

  Checks for required keys, valid types, and proper structure.

  ## Examples

      iex> validate_field_definition(%{"key" => "phone", "type" => "text"})
      :ok

      iex> validate_field_definition(%{"key" => "phone", "type" => "invalid"})
      {:error, "Invalid field type: invalid"}
  """
  def validate_field_definition(field_def) when is_map(field_def) do
    with :ok <- validate_required_keys(field_def),
         :ok <- validate_field_type(field_def["type"]) do
      validate_field_key(field_def["key"])
    end
  end

  @doc """
  Validates a user's custom field value against a field definition.

  ## Examples

      iex> validate_custom_field_value(%{"type" => "email", "required" => true}, "test@example.com")
      :ok

      iex> validate_custom_field_value(%{"type" => "email", "required" => true}, nil)
      {:error, "Field is required"}
  """
  def validate_custom_field_value(field_def, value) do
    with :ok <- validate_required(field_def, value) do
      validate_type(field_def, value)
    end
  end

  @doc """
  Validates all custom fields for a user against field definitions.

  Returns `:ok` if valid, or `{:error, errors}` with a map of field keys to error messages.

  ## Examples

      iex> validate_user_custom_fields(%User{custom_fields: %{"phone" => "555-1234"}})
      :ok

      iex> validate_user_custom_fields(%User{custom_fields: %{"email" => "invalid"}})
      {:error, %{"email" => "Invalid email format"}}
  """
  def validate_user_custom_fields(user) do
    definitions = list_enabled_field_definitions()
    custom_fields = user.custom_fields || %{}

    errors =
      Enum.reduce(definitions, %{}, fn field_def, acc ->
        key = field_def["key"]
        value = Map.get(custom_fields, key)

        case validate_custom_field_value(field_def, value) do
          :ok -> acc
          {:error, message} -> Map.put(acc, key, message)
        end
      end)

    if map_size(errors) == 0 do
      :ok
    else
      {:error, errors}
    end
  end

  # Private Helpers

  defp parse_definitions(json_string) do
    case Jason.decode(json_string) do
      {:ok, definitions} when is_list(definitions) -> definitions
      _ -> []
    end
  end

  defp normalize_field_definition(field_def) do
    %{
      "key" => field_def["key"],
      "label" => field_def["label"] || field_def["key"],
      "type" => field_def["type"] || "text",
      "required" => normalize_boolean(field_def["required"], false),
      "position" => field_def["position"] || 0,
      "enabled" => normalize_boolean(Map.get(field_def, "enabled"), true),
      "user_accessible" => normalize_boolean(Map.get(field_def, "user_accessible"), true),
      "validation" => field_def["validation"] || %{},
      "default" => field_def["default"] || "",
      "options" => field_def["options"] || []
    }
  end

  # Convert string boolean values to actual booleans
  defp normalize_boolean(value, default) do
    case value do
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      nil -> default
      _ -> default
    end
  end

  defp ensure_unique_key(key) do
    if get_field_definition(key) do
      {:error, "Field with key '#{key}' already exists"}
    else
      :ok
    end
  end

  defp validate_required_keys(field_def) do
    required = ["key", "type"]

    missing =
      Enum.filter(required, fn key ->
        is_nil(field_def[key]) or field_def[key] == ""
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, "Missing required fields: #{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_field_type(type) when type in @supported_types, do: :ok

  defp validate_field_type(type),
    do: {:error, "Invalid field type: #{type}. Supported: #{Enum.join(@supported_types, ", ")}"}

  defp validate_field_key(key) when is_binary(key) do
    if String.match?(key, ~r/^[a-z][a-z0-9_]*$/) do
      :ok
    else
      {:error,
       "Field key must start with lowercase letter and contain only lowercase letters, numbers, and underscores"}
    end
  end

  defp validate_field_key(_), do: {:error, "Field key must be a string"}

  defp validate_required(field_def, value) do
    if field_def["required"] && (is_nil(value) || value == "") do
      {:error, "Field is required"}
    else
      :ok
    end
  end

  defp validate_type(_field_def, nil), do: :ok
  defp validate_type(_field_def, ""), do: :ok

  defp validate_type(%{"type" => "email"} = _field_def, value) do
    if String.match?(value, ~r/^[^\s]+@[^\s]+\.[^\s]+$/) do
      :ok
    else
      {:error, "Invalid email format"}
    end
  end

  defp validate_type(%{"type" => "url"} = _field_def, value) do
    if String.match?(value, ~r/^https?:\/\/.+/) do
      :ok
    else
      {:error, "Invalid URL format"}
    end
  end

  defp validate_type(%{"type" => "number"} = _field_def, value) do
    case Float.parse(to_string(value)) do
      {_num, ""} -> :ok
      _ -> {:error, "Must be a valid number"}
    end
  end

  defp validate_type(%{"type" => "boolean"} = _field_def, value) when is_boolean(value), do: :ok

  defp validate_type(%{"type" => "boolean"} = _field_def, value)
       when value in ["true", "false"],
       do: :ok

  defp validate_type(%{"type" => "boolean"}, _value), do: {:error, "Must be true or false"}

  defp validate_type(%{"type" => "date"} = _field_def, value) do
    case Date.from_iso8601(to_string(value)) do
      {:ok, _date} -> :ok
      _ -> {:error, "Invalid date format (use YYYY-MM-DD)"}
    end
  end

  defp validate_type(_field_def, _value), do: :ok
end
