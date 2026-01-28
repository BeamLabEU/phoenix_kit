defmodule PhoenixKit.Modules.Shop.OptionTypes do
  @moduledoc """
  Supported option types for product options.

  ## Supported Types

  - `text` - Free-form text input
  - `number` - Numeric input (optional min/max/step validation)
  - `boolean` - Checkbox/toggle
  - `select` - Single choice dropdown (requires options)
  - `multiselect` - Multiple choice selection (requires options)

  ## Option Schema Format (Simple)

      %{
        "key" => "material",
        "label" => "Material",
        "type" => "select",
        "options" => ["PLA", "ABS", "PETG"],
        "default" => "PLA",
        "required" => false,
        "unit" => nil,
        "position" => 0,
        "affects_price" => true,
        "modifier_type" => "fixed",
        "price_modifiers" => %{
          "PLA" => "0",
          "ABS" => "5.00",
          "PETG" => "10.00"
        }
      }

  ## Option Schema Format (Enhanced with Localization)

      %{
        "key" => "color",
        "label" => %{"en" => "Color", "ru" => "Цвет"},
        "type" => "select",
        "allow_multiple_slots" => true,
        "options" => [
          %{"value" => "red", "label" => %{"en" => "Red", "ru" => "Красный"}, "hex" => "#FF0000"},
          %{"value" => "blue", "label" => %{"en" => "Blue", "ru" => "Синий"}, "hex" => "#0000FF"}
        ]
      }

  ## Multiple Slots

  When `allow_multiple_slots: true`, the same global option can be used
  multiple times in a product with different slot names. For example:

  - Global option "color" can be used as "cup_color" and "liquid_color"
  - Slots are stored in product metadata["_option_slots"]
  - Each slot references the source global option key

  ## Price Modifiers

  For `select` and `multiselect` types, you can enable price modifiers:
  - `affects_price` - Boolean indicating if this option affects product price
  - `modifier_type` - "fixed" or "percent"
  - `price_modifiers` - Map of option value to price delta (as string decimal)
  - `allow_override` - Boolean, allows overriding price modifiers per-product

  ## Modifier Types

  - `fixed` - Add exact amount to base price (e.g., +$10)
  - `percent` - Add percentage of base price (e.g., +20% of $20 = +$4)

  ## Allow Override

  When `allow_override: true`, the price modifier values can be customized
  for each individual product. The global values serve as defaults.
  Overridden values are stored in product's metadata["_price_modifiers"].

  ## Price Calculation Order

  1. Sum all fixed modifiers
  2. Add to base price (intermediate price)
  3. Sum all percent modifiers
  4. Apply percent to intermediate price

  Example:
  - Base price: $20
  - Material: PETG (+$10 fixed)
  - Finish: Premium (+20% percent)
  - Final: ($20 + $10) * 1.20 = $36
  """

  @supported_types ["text", "number", "boolean", "select", "multiselect"]
  @modifier_types ["fixed", "percent"]

  @doc """
  Returns list of supported option types.
  """
  def supported_types, do: @supported_types

  @doc """
  Returns list of supported modifier types.
  """
  def modifier_types, do: @modifier_types

  @doc """
  Checks if a type is valid.
  """
  def valid_type?(type) when is_binary(type), do: type in @supported_types
  def valid_type?(_), do: false

  @doc """
  Checks if a modifier type is valid.
  """
  def valid_modifier_type?(type) when is_binary(type), do: type in @modifier_types
  def valid_modifier_type?(_), do: false

  @doc """
  Extracts option values from options list.

  Works with both simple string format and enhanced map format:
  - Simple: ["Red", "Blue"] -> ["Red", "Blue"]
  - Enhanced: [%{"value" => "red", "label" => ...}] -> ["red"]
  """
  def get_option_values(options) when is_list(options) do
    Enum.map(options, &extract_option_value/1)
  end

  def get_option_values(_), do: []

  defp extract_option_value(opt) when is_binary(opt), do: opt
  defp extract_option_value(%{"value" => value}) when is_binary(value), do: value
  defp extract_option_value(_), do: nil

  @doc """
  Gets localized label for an option or option value.

  Handles both string labels and localized map labels.
  Falls back to default language or first available.
  """
  def get_label(label, language \\ "en")

  def get_label(label, _language) when is_binary(label), do: label

  def get_label(label, language) when is_map(label) do
    # Try exact language match
    case Map.get(label, language) do
      nil ->
        # Try "en" as fallback
        case Map.get(label, "en") do
          nil ->
            # Use first available value
            case Map.values(label) do
              [first | _] -> first
              [] -> ""
            end

          en_label ->
            en_label
        end

      lang_label ->
        lang_label
    end
  end

  def get_label(_, _), do: ""

  @doc """
  Checks if option allows multiple slots.
  """
  def allows_multiple_slots?(%{"allow_multiple_slots" => true}), do: true
  def allows_multiple_slots?(_), do: false

  @doc """
  Checks if a type requires options array.
  """
  def requires_options?("select"), do: true
  def requires_options?("multiselect"), do: true
  def requires_options?(_), do: false

  @doc """
  Checks if a type supports price modifiers.
  """
  def supports_price_modifiers?("select"), do: true
  def supports_price_modifiers?("multiselect"), do: true
  def supports_price_modifiers?(_), do: false

  @doc """
  Validates an option definition map.

  ## Required Keys

  - `key` - Unique identifier (string)
  - `label` - Display label (string)
  - `type` - One of supported types

  ## Optional Keys

  - `options` - Required for select/multiselect types
  - `default` - Default value
  - `required` - Whether field is required (boolean)
  - `unit` - Unit label (e.g., "cm", "kg")
  - `position` - Sort order (integer)
  - `affects_price` - Whether this option affects price (boolean)
  - `modifier_type` - "fixed" or "percent" (defaults to "fixed")
  - `price_modifiers` - Map of option value to price modifier

  ## Examples

      iex> OptionTypes.validate_option(%{"key" => "material", "label" => "Material", "type" => "text"})
      {:ok, %{"key" => "material", "label" => "Material", "type" => "text"}}

      iex> OptionTypes.validate_option(%{"key" => "color", "label" => "Color", "type" => "select", "options" => ["Red", "Blue"]})
      {:ok, %{"key" => "color", "label" => "Color", "type" => "select", "options" => ["Red", "Blue"]}}

      iex> OptionTypes.validate_option(%{"key" => "test"})
      {:error, "Missing required keys: label, type"}
  """
  def validate_option(opt) when is_map(opt) do
    with :ok <- validate_required_keys(opt),
         :ok <- validate_key_format(opt),
         :ok <- validate_label_format(opt),
         :ok <- validate_type(opt),
         :ok <- validate_allow_multiple_slots(opt),
         :ok <- validate_select_options(opt),
         :ok <- validate_price_modifiers(opt) do
      {:ok, normalize_option(opt)}
    end
  end

  def validate_option(_), do: {:error, "Option must be a map"}

  @doc """
  Validates a list of option definitions.
  Returns {:ok, options} or {:error, reason} on first failure.
  """
  def validate_options(options) when is_list(options) do
    results = Enum.map(options, &validate_option/1)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    case errors do
      [] -> {:ok, Enum.map(results, fn {:ok, opt} -> opt end)}
      [{:error, reason} | _] -> {:error, reason}
    end
  end

  def validate_options(_), do: {:error, "Options must be a list"}

  # Private functions

  defp validate_required_keys(opt) do
    required = ["key", "label", "type"]
    missing = Enum.reject(required, &Map.has_key?(opt, &1))

    case missing do
      [] -> :ok
      keys -> {:error, "Missing required keys: #{Enum.join(keys, ", ")}"}
    end
  end

  defp validate_key_format(%{"key" => key}) when is_binary(key) do
    if String.match?(key, ~r/^[a-z][a-z0-9_]*$/) do
      :ok
    else
      {:error, "Key must be lowercase alphanumeric with underscores, starting with a letter"}
    end
  end

  defp validate_key_format(_), do: {:error, "Key must be a string"}

  # Label can be a string or a localized map
  defp validate_label_format(%{"label" => label}) when is_binary(label), do: :ok

  defp validate_label_format(%{"label" => label}) when is_map(label) do
    # Localized format: %{"en" => "Color", "ru" => "Цвет"}
    if Enum.all?(label, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      :ok
    else
      {:error, "Localized label must be a map of language code => string"}
    end
  end

  defp validate_label_format(_), do: {:error, "Label must be a string or localized map"}

  # allow_multiple_slots is optional boolean
  defp validate_allow_multiple_slots(%{"allow_multiple_slots" => value}) when is_boolean(value),
    do: :ok

  defp validate_allow_multiple_slots(%{"allow_multiple_slots" => _}),
    do: {:error, "allow_multiple_slots must be a boolean"}

  defp validate_allow_multiple_slots(_), do: :ok

  defp validate_type(%{"type" => type}) do
    if valid_type?(type) do
      :ok
    else
      {:error, "Invalid type '#{type}'. Must be one of: #{Enum.join(@supported_types, ", ")}"}
    end
  end

  defp validate_select_options(%{"type" => type, "options" => options})
       when type in ["select", "multiselect"] do
    cond do
      not is_list(options) ->
        {:error, "Options must be a list for #{type} type"}

      Enum.empty?(options) ->
        {:error, "Options cannot be empty for #{type} type"}

      Enum.all?(options, &is_binary/1) ->
        # Simple string format - valid
        :ok

      Enum.all?(options, &valid_option_map?/1) ->
        # Enhanced map format - valid
        :ok

      true ->
        {:error, "Options must be strings or maps with 'value' key"}
    end
  end

  defp validate_select_options(%{"type" => type}) when type in ["select", "multiselect"] do
    {:error, "Options are required for #{type} type"}
  end

  defp validate_select_options(_), do: :ok

  # Validates an option map has required 'value' key
  defp valid_option_map?(opt) when is_map(opt) do
    value = opt["value"]
    is_binary(value) and value != ""
  end

  defp valid_option_map?(_), do: false

  # Validate price modifiers for select/multiselect types
  defp validate_price_modifiers(%{"type" => type, "affects_price" => true} = opt)
       when type in ["select", "multiselect"] do
    modifier_type = Map.get(opt, "modifier_type", "fixed")

    if modifier_type in @modifier_types do
      validate_price_modifiers_map(opt)
    else
      {:error, "modifier_type must be one of: #{Enum.join(@modifier_types, ", ")}"}
    end
  end

  defp validate_price_modifiers(%{"type" => type, "affects_price" => true})
       when type not in ["select", "multiselect"] do
    {:error, "Price modifiers are only supported for select and multiselect types"}
  end

  defp validate_price_modifiers(_), do: :ok

  defp validate_price_modifiers_map(opt) do
    case opt do
      %{"price_modifiers" => modifiers} when is_map(modifiers) ->
        # Extract option values using helper that handles both formats
        option_values = get_option_values(opt["options"] || [])

        # Check that all options have modifiers
        missing = Enum.filter(option_values, fn o -> !Map.has_key?(modifiers, o) end)

        cond do
          missing != [] ->
            {:error, "Missing price modifiers for options: #{Enum.join(missing, ", ")}"}

          not valid_modifiers?(modifiers) ->
            {:error, "Price modifiers must be valid decimal strings (e.g., \"5.00\")"}

          true ->
            :ok
        end

      %{"price_modifiers" => _} ->
        {:error, "Price modifiers must be a map"}

      _ ->
        {:error, "Price modifiers are required when affects_price is true"}
    end
  end

  # Check if all modifier values are valid decimal strings
  defp valid_modifiers?(modifiers) when is_map(modifiers) do
    Enum.all?(modifiers, fn {_key, value} ->
      is_binary(value) and valid_decimal_string?(value)
    end)
  end

  defp valid_decimal_string?(str) do
    case Decimal.parse(str) do
      {_decimal, ""} -> true
      _ -> false
    end
  end

  defp normalize_option(opt) do
    opt
    |> Map.put_new("required", false)
    |> Map.put_new("position", 0)
    |> normalize_affects_price()
  end

  # Ensure affects_price is false for non-select types
  defp normalize_affects_price(%{"type" => type} = opt)
       when type not in ["select", "multiselect"] do
    opt
    |> Map.delete("affects_price")
    |> Map.delete("modifier_type")
    |> Map.delete("price_modifiers")
  end

  defp normalize_affects_price(%{"affects_price" => true} = opt) do
    # Ensure price_modifiers has "0" as default for missing options
    # Use helper that handles both simple and enhanced formats
    option_values = get_option_values(opt["options"] || [])
    modifiers = opt["price_modifiers"] || %{}

    normalized_modifiers =
      Enum.reduce(option_values, modifiers, fn o, acc ->
        Map.put_new(acc, o, "0")
      end)

    opt
    |> Map.put("price_modifiers", normalized_modifiers)
    |> Map.put_new("modifier_type", "fixed")
    |> Map.put_new("allow_override", false)
  end

  defp normalize_affects_price(opt) do
    opt
    |> Map.put_new("affects_price", false)
    |> Map.delete("allow_override")
  end
end
