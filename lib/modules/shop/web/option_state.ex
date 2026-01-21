defmodule PhoenixKit.Modules.Shop.Web.OptionState do
  @moduledoc """
  Encapsulates option-related state for product form.

  This module manages all option-related data in a single struct,
  replacing the multiple assigns previously used in product_form.ex:
  - `new_value_inputs` -> `state.new_inputs`
  - `selected_option_values` -> `state.selected`
  - `original_option_values` -> `state.available`
  - `metadata["_price_modifiers"]` -> `state.modifiers`
  - `option_schema` -> `state.schema`

  ## Usage

      # Initialize state from product and schema
      state = OptionState.new(product, option_schema)

      # Toggle a value selection
      state = OptionState.toggle_value(state, "size", "M", ["S", "M", "L"])

      # Add a new custom value
      state = OptionState.add_value(state, "size", "XL")

      # Remove a value
      state = OptionState.remove_value(state, "size", "XL")

      # Update a price modifier
      state = OptionState.update_modifier(state, "size", "M", "5.00")

      # Convert back to metadata for saving
      metadata = OptionState.to_metadata(state)
  """

  defstruct [
    # Merged global + category option schema
    schema: [],
    # All available values per option key (original + manually added)
    available: %{},
    # Currently selected values per option key
    selected: %{},
    # Price modifiers per option/value (string format)
    modifiers: %{},
    # Temporary input field values for "add value" inputs
    new_inputs: %{}
  ]

  @type t :: %__MODULE__{
          schema: list(map()),
          available: %{String.t() => list(String.t())},
          selected: %{String.t() => list(String.t())},
          modifiers: %{String.t() => %{String.t() => String.t()}},
          new_inputs: %{String.t() => String.t()}
        }

  @doc """
  Creates a new OptionState from a product and option schema.

  ## Examples

      product = %Product{metadata: %{"_option_values" => %{"size" => ["M", "L"]}}}
      schema = [%{"key" => "size", "type" => "select", "options" => ["S", "M", "L"]}]

      state = OptionState.new(product, schema)
      # => %OptionState{
      #   schema: [...],
      #   available: %{"size" => ["S", "M", "L"]},
      #   selected: %{"size" => ["M", "L"]},
      #   modifiers: %{},
      #   new_inputs: %{}
      # }
  """
  def new(product, option_schema) when is_list(option_schema) do
    metadata = (product && product.metadata) || %{}
    option_values = Map.get(metadata, "_option_values", %{})
    price_modifiers = Map.get(metadata, "_price_modifiers", %{})

    # Build available values from option_values (imported/saved)
    available = option_values

    # Selected = saved option values (if present) or all available
    selected = option_values

    %__MODULE__{
      schema: option_schema,
      available: available,
      selected: selected,
      modifiers: normalize_modifiers(price_modifiers),
      new_inputs: %{}
    }
  end

  def new(nil, option_schema), do: new(%{metadata: %{}}, option_schema)

  @doc """
  Toggles a value selection on/off.

  If the value is selected, it will be deselected. If not selected, it will be selected.
  The `all_values` parameter is used to determine when all values are selected
  (in which case the key is removed from selected map).

  ## Examples

      state = OptionState.toggle_value(state, "size", "M", ["S", "M", "L"])
  """
  def toggle_value(%__MODULE__{} = state, option_key, value, all_values)
      when is_binary(option_key) and is_binary(value) and is_list(all_values) do
    current = Map.get(state.selected, option_key, all_values)

    updated =
      if value in current do
        Enum.reject(current, &(&1 == value))
      else
        current ++ [value]
      end

    # Normalize selection state
    new_selected =
      cond do
        # None selected - keep explicit empty list
        updated == [] ->
          Map.put(state.selected, option_key, [])

        # All selected - remove key to indicate "all"
        Enum.sort(updated) == Enum.sort(all_values) ->
          Map.delete(state.selected, option_key)

        # Partial selection
        true ->
          Map.put(state.selected, option_key, updated)
      end

    %{state | selected: new_selected}
  end

  @doc """
  Adds a new value to an option.

  The value is added to both `available` and `selected` maps.
  Returns `{:ok, state}` or `{:error, reason}`.

  ## Examples

      {:ok, state} = OptionState.add_value(state, "size", "XL")
      {:error, "already exists"} = OptionState.add_value(state, "size", "M")
  """
  def add_value(%__MODULE__{} = state, option_key, value)
      when is_binary(option_key) and is_binary(value) do
    value = String.trim(value)

    if value == "" do
      {:error, "value cannot be empty"}
    else
      # Get all existing values (schema + available)
      schema_values = get_schema_values(state.schema, option_key)
      available_values = Map.get(state.available, option_key, [])
      all_existing = Enum.uniq(schema_values ++ available_values)

      if value in all_existing do
        {:error, "value '#{value}' already exists"}
      else
        # Add to available
        new_available =
          Map.update(state.available, option_key, [value], fn existing ->
            existing ++ [value]
          end)

        # Add to selected (new value is selected by default)
        current_selected = Map.get(state.selected, option_key, all_existing)
        new_selected = Map.put(state.selected, option_key, current_selected ++ [value])

        # Clear input
        new_inputs = Map.put(state.new_inputs, option_key, "")

        {:ok, %{state | available: new_available, selected: new_selected, new_inputs: new_inputs}}
      end
    end
  end

  @doc """
  Removes a value from an option.

  Removes from `available`, `selected`, and any associated modifiers.

  ## Examples

      state = OptionState.remove_value(state, "size", "XL")
  """
  def remove_value(%__MODULE__{} = state, option_key, value)
      when is_binary(option_key) and is_binary(value) do
    # Remove from available
    new_available =
      case Map.get(state.available, option_key) do
        nil ->
          state.available

        values ->
          updated = Enum.reject(values, &(&1 == value))

          if updated == [] do
            Map.delete(state.available, option_key)
          else
            Map.put(state.available, option_key, updated)
          end
      end

    # Remove from selected
    new_selected =
      case Map.get(state.selected, option_key) do
        nil ->
          state.selected

        values ->
          updated = Enum.reject(values, &(&1 == value))

          if updated == [] do
            Map.delete(state.selected, option_key)
          else
            Map.put(state.selected, option_key, updated)
          end
      end

    # Remove modifier
    new_modifiers = remove_modifier(state.modifiers, option_key, value)

    %{state | available: new_available, selected: new_selected, modifiers: new_modifiers}
  end

  @doc """
  Updates a price modifier for a specific option value.

  ## Examples

      state = OptionState.update_modifier(state, "size", "M", "5.00")
  """
  def update_modifier(%__MODULE__{} = state, option_key, value, modifier_value)
      when is_binary(option_key) and is_binary(value) do
    new_modifiers =
      if modifier_value == nil or modifier_value == "" or modifier_value == "0" do
        remove_modifier(state.modifiers, option_key, value)
      else
        option_mods = Map.get(state.modifiers, option_key, %{})
        option_mods = Map.put(option_mods, value, modifier_value)
        Map.put(state.modifiers, option_key, option_mods)
      end

    %{state | modifiers: new_modifiers}
  end

  @doc """
  Updates the new value input for an option key.

  ## Examples

      state = OptionState.update_new_input(state, "size", "XL")
  """
  def update_new_input(%__MODULE__{} = state, option_key, value)
      when is_binary(option_key) do
    %{state | new_inputs: Map.put(state.new_inputs, option_key, value || "")}
  end

  @doc """
  Converts the state back to a metadata map for saving.

  Returns a map with `_option_values` and `_price_modifiers` keys.
  Empty maps are omitted.

  ## Examples

      state = %OptionState{
        selected: %{"size" => ["M", "L"]},
        modifiers: %{"size" => %{"M" => "5.00"}}
      }

      OptionState.to_metadata(state)
      # => %{
      #   "_option_values" => %{"size" => ["M", "L"]},
      #   "_price_modifiers" => %{"size" => %{"M" => "5.00"}}
      # }
  """
  def to_metadata(%__MODULE__{} = state) do
    metadata = %{}

    # Add _option_values if present
    metadata =
      if state.available != %{} do
        Map.put(metadata, "_option_values", state.available)
      else
        metadata
      end

    # Add _price_modifiers if present
    metadata =
      if state.modifiers != %{} do
        Map.put(metadata, "_price_modifiers", state.modifiers)
      else
        metadata
      end

    metadata
  end

  @doc """
  Checks if a value is currently selected for an option.

  ## Examples

      OptionState.value_selected?(state, "size", "M", ["S", "M", "L"])
      # => true
  """
  def value_selected?(%__MODULE__{} = state, option_key, value, all_values) do
    case Map.get(state.selected, option_key) do
      nil -> value in all_values
      selected -> value in selected
    end
  end

  @doc """
  Gets all values available for an option (schema + custom added).

  ## Examples

      OptionState.get_all_values(state, "size")
      # => ["S", "M", "L", "XL"]
  """
  def get_all_values(%__MODULE__{} = state, option_key) do
    schema_values = get_schema_values(state.schema, option_key)
    custom_values = Map.get(state.available, option_key, [])
    Enum.uniq(schema_values ++ custom_values)
  end

  @doc """
  Gets selected values for an option (or all if not explicitly set).

  ## Examples

      OptionState.get_selected_values(state, "size", ["S", "M", "L"])
      # => ["M", "L"]
  """
  def get_selected_values(%__MODULE__{} = state, option_key, all_values) do
    Map.get(state.selected, option_key, all_values)
  end

  @doc """
  Gets the modifier value for an option/value pair.

  ## Examples

      OptionState.get_modifier(state, "size", "M")
      # => "5.00"
  """
  def get_modifier(%__MODULE__{} = state, option_key, value) do
    get_in(state.modifiers, [option_key, value])
  end

  @doc """
  Checks if option has custom selection (not all values selected).

  ## Examples

      OptionState.has_custom_selection?(state, "size")
      # => true
  """
  def has_custom_selection?(%__MODULE__{} = state, option_key) do
    Map.has_key?(state.selected, option_key)
  end

  @doc """
  Adds a completely new option with an initial value.

  Returns `{:ok, state}` or `{:error, reason}`.

  ## Examples

      {:ok, state} = OptionState.add_new_option(state, "material", "Wood")
  """
  def add_new_option(%__MODULE__{} = state, option_key, value)
      when is_binary(option_key) and is_binary(value) do
    key = option_key |> String.trim() |> String.downcase() |> String.replace(~r/\s+/, "_")
    value = String.trim(value)

    cond do
      key == "" or value == "" ->
        {:error, "option key and value are required"}

      # Check if value already exists in this option
      value in get_all_values(state, key) ->
        {:error, "value '#{value}' already exists in '#{key}'"}

      # Check if this is adding to existing option
      Map.has_key?(state.available, key) or
          Enum.any?(state.schema, &(&1["key"] == key)) ->
        # Add value to existing option
        add_value(state, key, value)

      # New option entirely
      true ->
        new_available = Map.put(state.available, key, [value])
        new_selected = Map.put(state.selected, key, [value])
        {:ok, %{state | available: new_available, selected: new_selected}}
    end
  end

  # Private helpers

  defp get_schema_values(schema, option_key) do
    case Enum.find(schema, &(&1["key"] == option_key)) do
      nil -> []
      opt -> opt["options"] || []
    end
  end

  defp remove_modifier(modifiers, option_key, value) do
    case Map.get(modifiers, option_key) do
      nil ->
        modifiers

      option_mods ->
        updated = Map.delete(option_mods, value)

        if updated == %{} do
          Map.delete(modifiers, option_key)
        else
          Map.put(modifiers, option_key, updated)
        end
    end
  end

  # Normalize modifiers to ensure all values are strings
  defp normalize_modifiers(modifiers) when is_map(modifiers) do
    Enum.map(modifiers, fn {key, values} when is_map(values) ->
      normalized_values =
        Enum.map(values, fn
          {k, v} when is_binary(v) -> {k, v}
          {k, %{"value" => v}} when is_binary(v) -> {k, v}
          {k, _} -> {k, "0"}
        end)
        |> Map.new()

      {key, normalized_values}
    end)
    |> Map.new()
  end

  defp normalize_modifiers(_), do: %{}
end
