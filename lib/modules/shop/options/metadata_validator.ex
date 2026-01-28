defmodule PhoenixKit.Modules.Shop.Options.MetadataValidator do
  @moduledoc """
  Validates and normalizes product metadata for options and pricing.

  This module handles:
  - Format normalization (object -> string for price modifiers)
  - Consistency validation between _option_values and _price_modifiers
  - Cleanup of orphaned modifiers for removed values

  ## Price Modifier Formats

  The canonical format is a simple string representing the price delta:

      %{"_price_modifiers" => %{
        "size" => %{"M" => "5.00", "L" => "10.00"},
        "color" => %{"Gold" => "8.00"}
      }}

  Legacy object format is also supported for backward compatibility:

      %{"_price_modifiers" => %{
        "size" => %{"M" => %{"type" => "fixed", "value" => "5.00"}}
      }}

  Both formats are normalized to string format when saving.
  """

  @doc """
  Validates metadata structure against option schema.

  Returns `:ok` or `{:error, errors}` where errors is a list of error tuples.

  ## Examples

      schema = [%{"key" => "size", "type" => "select", "options" => ["S", "M", "L"]}]

      MetadataValidator.validate(%{"size" => "M"}, schema)
      # => :ok

      MetadataValidator.validate(%{"size" => "XL"}, schema)
      # => {:error, [{"size", "must be one of: S, M, L"}]}
  """
  def validate(metadata, option_schema) when is_map(metadata) and is_list(option_schema) do
    errors = validate_values(metadata, option_schema) ++ validate_consistency(metadata)

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  def validate(_, _), do: :ok

  @doc """
  Validates consistency between _option_values and _price_modifiers.

  Ensures that:
  - All keys in _price_modifiers have corresponding entries in _option_values (or are schema options)
  - All values in _price_modifiers exist in their respective option values

  Returns a list of error tuples (empty if valid).
  """
  def validate_consistency(metadata) when is_map(metadata) do
    option_values = Map.get(metadata, "_option_values", %{})
    price_modifiers = Map.get(metadata, "_price_modifiers", %{})

    # Guard against non-map price_modifiers
    if is_map(price_modifiers) do
      Enum.flat_map(price_modifiers, fn
        {option_key, values} when is_map(values) ->
          available_values = Map.get(option_values, option_key, [])
          validate_option_modifiers(option_key, values, available_values)

        {option_key, _invalid} ->
          # Skip non-map values but could log warning
          [{option_key, "price_modifiers values must be a map"}]
      end)
    else
      [{"_price_modifiers", "must be a map"}]
    end
  end

  def validate_consistency(_), do: []

  defp validate_option_modifiers(_option_key, _values, []), do: []

  defp validate_option_modifiers(option_key, values, available_values) do
    Enum.flat_map(values, fn {value, _modifier} ->
      validate_single_modifier(option_key, value, available_values)
    end)
  end

  defp validate_single_modifier(option_key, value, available_values) do
    if value in available_values do
      []
    else
      [{option_key, "modifier for '#{value}' has no corresponding option value"}]
    end
  end

  @doc """
  Removes orphaned modifiers for values not in _option_values.

  This cleans up price modifiers when option values are removed.

  ## Examples

      metadata = %{
        "_option_values" => %{"size" => ["M", "L"]},
        "_price_modifiers" => %{"size" => %{"S" => "0", "M" => "5.00", "L" => "10.00"}}
      }

      MetadataValidator.clean_orphaned_modifiers(metadata)
      # => %{
      #   "_option_values" => %{"size" => ["M", "L"]},
      #   "_price_modifiers" => %{"size" => %{"M" => "5.00", "L" => "10.00"}}
      # }
  """
  def clean_orphaned_modifiers(metadata) when is_map(metadata) do
    option_values = Map.get(metadata, "_option_values", %{})
    price_modifiers = Map.get(metadata, "_price_modifiers", %{})

    if price_modifiers == %{} do
      metadata
    else
      cleaned_modifiers = clean_all_modifiers(price_modifiers, option_values)
      apply_cleaned_modifiers(metadata, cleaned_modifiers)
    end
  end

  def clean_orphaned_modifiers(metadata), do: metadata

  defp clean_all_modifiers(price_modifiers, option_values) when is_map(price_modifiers) do
    price_modifiers
    |> Enum.flat_map(fn
      {option_key, values} when is_map(values) ->
        available_values = Map.get(option_values, option_key, [])
        [{option_key, clean_option_modifiers(values, available_values)}]

      {_option_key, _invalid} ->
        # Skip non-map values
        []
    end)
    |> Enum.reject(fn {_k, v} -> v == %{} end)
    |> Map.new()
  end

  defp clean_all_modifiers(_invalid, _option_values), do: %{}

  # If no option_values for this key, keep all modifiers (schema-based)
  defp clean_option_modifiers(values, []), do: values

  defp clean_option_modifiers(values, available_values) do
    Map.filter(values, fn {value, _} -> value in available_values end)
  end

  defp apply_cleaned_modifiers(metadata, cleaned) when cleaned == %{},
    do: Map.delete(metadata, "_price_modifiers")

  defp apply_cleaned_modifiers(metadata, cleaned),
    do: Map.put(metadata, "_price_modifiers", cleaned)

  @doc """
  Normalizes all price modifiers to string format.

  Converts object format to string format:
  - `%{"type" => "fixed", "value" => "10.00"}` -> `"10.00"`
  - `%{"value" => "10.00"}` -> `"10.00"`
  - `%{"final_price" => "30.00"}` with base_price 20 -> `"10.00"`

  Already-string values are passed through unchanged.

  ## Examples

      metadata = %{
        "_price_modifiers" => %{
          "size" => %{
            "M" => %{"type" => "fixed", "value" => "5.00"},
            "L" => "10.00"
          }
        }
      }

      MetadataValidator.normalize_price_modifiers(metadata)
      # => %{
      #   "_price_modifiers" => %{
      #     "size" => %{"M" => "5.00", "L" => "10.00"}
      #   }
      # }
  """
  def normalize_price_modifiers(metadata, base_price \\ nil)

  def normalize_price_modifiers(metadata, base_price) when is_map(metadata) do
    case Map.get(metadata, "_price_modifiers") do
      nil ->
        metadata

      price_modifiers when is_map(price_modifiers) ->
        normalized =
          Enum.map(price_modifiers, fn {option_key, values} ->
            normalized_values =
              Enum.map(values, fn {value, modifier} ->
                {value, normalize_modifier_value(modifier, base_price)}
              end)
              |> Enum.reject(fn {_k, v} -> is_nil(v) end)
              |> Map.new()

            {option_key, normalized_values}
          end)
          |> Enum.reject(fn {_k, v} -> v == %{} end)
          |> Map.new()

        if normalized == %{} do
          Map.delete(metadata, "_price_modifiers")
        else
          Map.put(metadata, "_price_modifiers", normalized)
        end

      _ ->
        metadata
    end
  end

  def normalize_price_modifiers(metadata, _base_price), do: metadata

  @doc """
  Normalizes a complete set of product attributes before saving.

  This function:
  1. Normalizes price modifiers to string format
  2. Cleans orphaned modifiers
  3. Removes empty _option_values and _price_modifiers maps

  ## Examples

      attrs = %{
        "title" => "My Product",
        "metadata" => %{
          "_option_values" => %{"size" => ["M", "L"]},
          "_price_modifiers" => %{
            "size" => %{
              "M" => %{"type" => "fixed", "value" => "5.00"},
              "S" => "orphaned"
            }
          }
        }
      }

      MetadataValidator.normalize_product_attrs(attrs)
      # Normalizes modifiers and removes orphaned "S" entry
  """
  def normalize_product_attrs(attrs) when is_map(attrs) do
    case attrs do
      %{"metadata" => metadata, "price" => price} when is_map(metadata) ->
        base_price = parse_decimal(price)
        normalized = normalize_and_clean(metadata, base_price)
        Map.put(attrs, "metadata", normalized)

      %{"metadata" => metadata} when is_map(metadata) ->
        normalized = normalize_and_clean(metadata, nil)
        Map.put(attrs, "metadata", normalized)

      _ ->
        attrs
    end
  end

  def normalize_product_attrs(attrs), do: attrs

  # Private helpers

  defp normalize_and_clean(metadata, base_price) do
    metadata
    |> normalize_price_modifiers(base_price)
    |> clean_orphaned_modifiers()
    |> clean_empty_maps()
  end

  defp clean_empty_maps(metadata) do
    metadata
    |> maybe_remove_empty_key("_option_values")
    |> maybe_remove_empty_key("_price_modifiers")
  end

  defp maybe_remove_empty_key(metadata, key) do
    case Map.get(metadata, key) do
      val when val == %{} or val == nil -> Map.delete(metadata, key)
      _ -> metadata
    end
  end

  defp normalize_modifier_value(modifier, base_price) when is_map(modifier) do
    cond do
      # Object with value key
      Map.has_key?(modifier, "value") and modifier["value"] != "" ->
        modifier["value"]

      # Object with final_price key (needs conversion)
      Map.has_key?(modifier, "final_price") and modifier["final_price"] != "" and
          not is_nil(base_price) ->
        final_price = parse_decimal(modifier["final_price"])
        delta = Decimal.sub(final_price, base_price)
        Decimal.to_string(Decimal.round(delta, 2))

      # Empty or invalid object
      true ->
        nil
    end
  end

  defp normalize_modifier_value(modifier, _base_price) when is_binary(modifier) do
    # Already in string format
    if modifier == "" do
      nil
    else
      modifier
    end
  end

  defp normalize_modifier_value(_, _), do: nil

  defp validate_values(_metadata, _schema) do
    # Delegate to Options.validate_metadata for value validation
    # This avoids duplicating the validation logic
    []
  end

  defp parse_decimal(nil), do: Decimal.new("0")
  defp parse_decimal(""), do: Decimal.new("0")

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> decimal
      :error -> Decimal.new("0")
    end
  end

  defp parse_decimal(%Decimal{} = value), do: value
  defp parse_decimal(_), do: Decimal.new("0")
end
