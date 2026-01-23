defmodule PhoenixKit.Modules.Shop.Options do
  @moduledoc """
  Context for managing product options.

  Provides a two-level option system:
  - **Global options** - Apply to all products (stored in shop_config)
  - **Category options** - Apply to products in specific category (stored in category.option_schema)

  When retrieving options for a product, the system merges global and category options,
  with category options overriding global ones by key.

  ## Usage

      # Get/set global options
      Options.get_global_options()
      Options.update_global_options([%{"key" => "material", "label" => "Material", "type" => "text"}])

      # Get/set category options
      Options.get_category_options(category)
      Options.update_category_options(category, [%{"key" => "mounting_type", ...}])

      # Get merged schema for a product
      Options.get_option_schema_for_product(product)

      # Validate product metadata against schema
      Options.validate_metadata(product.metadata, schema)

  ## Price Calculation

  Options with `affects_price: true` can modify the final product price.
  Two modifier types are supported:

  - `fixed` - Add exact amount (e.g., +$10)
  - `percent` - Add percentage of base price (e.g., +20%)

  ## Allow Override

  Options with `allow_override: true` can have their price modifiers customized
  per-product. Override values are stored in product metadata under `_price_modifiers`.
  When calculating price, the system checks for overrides first, then falls back
  to the default values from the option schema.

  Calculation order:
  1. Sum all fixed modifiers (checking for overrides)
  2. Add to base price (intermediate price)
  3. Sum all percent modifiers (checking for overrides)
  4. Apply percent to intermediate price

  Example:
  - Base price: $20
  - Material: PETG (+$10 fixed)
  - Finish: Premium (+20% percent)
  - Final: ($20 + $10) * 1.20 = $36
  """

  alias PhoenixKit.Modules.Shop.Category
  alias PhoenixKit.Modules.Shop.OptionTypes
  alias PhoenixKit.Modules.Shop.ShopConfig

  @global_schema_key "global_option_schema"

  # ============================================
  # GLOBAL OPTIONS
  # ============================================

  @doc """
  Gets global option schema.

  Returns a list of option definitions that apply to all products.
  """
  def get_global_options do
    case repo().get(ShopConfig, @global_schema_key) do
      nil -> []
      %ShopConfig{value: %{"options" => opts}} when is_list(opts) -> opts
      %ShopConfig{value: _} -> []
    end
  end

  @doc """
  Updates global option schema.

  ## Examples

      Options.update_global_options([
        %{"key" => "material", "label" => "Material", "type" => "select",
          "options" => ["PLA", "ABS", "PETG"], "default" => "PLA"}
      ])
  """
  def update_global_options(options) when is_list(options) do
    with {:ok, validated} <- OptionTypes.validate_options(options) do
      wrapped_value = %{"options" => validated}

      case repo().get(ShopConfig, @global_schema_key) do
        nil ->
          %ShopConfig{}
          |> ShopConfig.changeset(%{key: @global_schema_key, value: wrapped_value})
          |> repo().insert()

        config ->
          config
          |> ShopConfig.changeset(%{value: wrapped_value})
          |> repo().update()
      end
    end
  end

  @doc """
  Adds a single option to global schema.
  """
  def add_global_option(opt) when is_map(opt) do
    with {:ok, validated} <- OptionTypes.validate_option(opt) do
      current = get_global_options()

      # Check for duplicate key
      if Enum.any?(current, &(&1["key"] == validated["key"])) do
        {:error, "Option with key '#{validated["key"]}' already exists"}
      else
        update_global_options(current ++ [validated])
      end
    end
  end

  @doc """
  Removes an option from global schema by key.
  """
  def remove_global_option(key) when is_binary(key) do
    current = get_global_options()
    updated = Enum.reject(current, &(&1["key"] == key))
    update_global_options(updated)
  end

  # ============================================
  # CATEGORY OPTIONS
  # ============================================

  @doc """
  Gets category-specific option schema.
  """
  def get_category_options(%Category{option_schema: schema}) when is_list(schema) do
    schema
  end

  def get_category_options(%Category{}) do
    []
  end

  def get_category_options(category_id) when is_integer(category_id) do
    case repo().get(Category, category_id) do
      nil -> []
      category -> get_category_options(category)
    end
  end

  def get_category_options(_), do: []

  @doc """
  Updates category option schema.
  """
  def update_category_options(%Category{} = category, options) when is_list(options) do
    with {:ok, validated} <- OptionTypes.validate_options(options) do
      category
      |> Category.changeset(%{option_schema: validated})
      |> repo().update()
    end
  end

  @doc """
  Adds a single option to category schema.
  """
  def add_category_option(%Category{} = category, opt) when is_map(opt) do
    with {:ok, validated} <- OptionTypes.validate_option(opt) do
      current = get_category_options(category)

      if Enum.any?(current, &(&1["key"] == validated["key"])) do
        {:error, "Option with key '#{validated["key"]}' already exists in this category"}
      else
        update_category_options(category, current ++ [validated])
      end
    end
  end

  @doc """
  Removes an option from category schema by key.
  """
  def remove_category_option(%Category{} = category, key) when is_binary(key) do
    current = get_category_options(category)
    updated = Enum.reject(current, &(&1["key"] == key))
    update_category_options(category, updated)
  end

  # ============================================
  # MERGED SCHEMA (Global + Category)
  # ============================================

  @doc """
  Gets merged option schema for a product.

  Combines global options with category-specific options.
  Category options override global ones with the same key.

  ## Examples

      # Product with category
      schema = Options.get_option_schema_for_product(product)

      # Product without category (global only)
      schema = Options.get_option_schema_for_product(product_without_category)
  """
  def get_option_schema_for_product(product) do
    global = get_global_options()

    category_opts =
      case product do
        %{category: %Category{} = cat} -> get_category_options(cat)
        %{category_id: nil} -> []
        %{category_id: id} when is_integer(id) -> get_category_options(id)
        _ -> []
      end

    merge_schemas(global, category_opts)
  end

  @doc """
  Merges two option schemas, with the second overriding the first by key.
  """
  def merge_schemas(base, override) when is_list(base) and is_list(override) do
    override_keys = Enum.map(override, & &1["key"])

    filtered_base =
      Enum.reject(base, fn opt ->
        opt["key"] in override_keys
      end)

    # Sort by position
    (filtered_base ++ override)
    |> Enum.sort_by(& &1["position"], :asc)
  end

  # ============================================
  # VALUE VALIDATION
  # ============================================

  @doc """
  Validates product metadata against option schema.

  Returns `:ok` or `{:error, errors}` where errors is a list of `{key, message}` tuples.

  ## Examples

      schema = [%{"key" => "material", "type" => "select", "options" => ["PLA", "ABS"], "required" => true}]

      Options.validate_metadata(%{"material" => "PLA"}, schema)
      # => :ok

      Options.validate_metadata(%{}, schema)
      # => {:error, [{"material", "is required"}]}

      Options.validate_metadata(%{"material" => "Invalid"}, schema)
      # => {:error, [{"material", "must be one of: PLA, ABS"}]}
  """
  def validate_metadata(metadata, schema) when is_map(metadata) and is_list(schema) do
    required_errors =
      schema
      |> Enum.filter(& &1["required"])
      |> Enum.reject(fn opt ->
        value = Map.get(metadata, opt["key"])
        value != nil and value != ""
      end)
      |> Enum.map(fn opt -> {opt["key"], "is required"} end)

    type_errors =
      Enum.flat_map(schema, fn opt ->
        value = Map.get(metadata, opt["key"])
        validate_value_type(opt, value)
      end)

    case required_errors ++ type_errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  def validate_metadata(_, _), do: :ok

  # Skip validation for nil/empty values (handled by required check)
  defp validate_value_type(_opt, nil), do: []
  defp validate_value_type(_opt, ""), do: []

  defp validate_value_type(%{"key" => key, "type" => "number"}, value) do
    cond do
      is_number(value) -> []
      is_binary(value) and String.match?(value, ~r/^-?\d+\.?\d*$/) -> []
      true -> [{key, "must be a number"}]
    end
  end

  defp validate_value_type(%{"key" => key, "type" => "boolean"}, value) do
    if is_boolean(value) or value in ["true", "false"] do
      []
    else
      [{key, "must be a boolean"}]
    end
  end

  defp validate_value_type(%{"key" => key, "type" => "select", "options" => opts}, value) do
    if value in opts do
      []
    else
      [{key, "must be one of: #{Enum.join(opts, ", ")}"}]
    end
  end

  defp validate_value_type(%{"key" => key, "type" => "multiselect", "options" => opts}, value) do
    values = if is_list(value), do: value, else: [value]

    if Enum.all?(values, &(&1 in opts)) do
      []
    else
      [{key, "must be a list of: #{Enum.join(opts, ", ")}"}]
    end
  end

  # text type accepts any string
  defp validate_value_type(%{"type" => "text"}, _value), do: []

  # Unknown type - skip validation
  defp validate_value_type(_, _), do: []

  # ============================================
  # HELPER FUNCTIONS
  # ============================================

  @doc """
  Returns option by key from a schema.
  """
  def get_option_by_key(schema, key) when is_list(schema) and is_binary(key) do
    Enum.find(schema, &(&1["key"] == key))
  end

  @doc """
  Checks if an option key exists in schema.
  """
  def has_option?(schema, key) when is_list(schema) and is_binary(key) do
    Enum.any?(schema, &(&1["key"] == key))
  end

  # ============================================
  # PRICE MODIFIER FUNCTIONS
  # ============================================

  @doc """
  Gets price-affecting options from a schema.

  Returns only options that have `affects_price: true` and are
  of type `select` or `multiselect`.

  ## Examples

      schema = [
        %{"key" => "material", "type" => "select", "affects_price" => true, ...},
        %{"key" => "notes", "type" => "text", ...}
      ]

      Options.get_price_affecting_specs(schema)
      # => [%{"key" => "material", ...}]
  """
  def get_price_affecting_specs(schema) when is_list(schema) do
    Enum.filter(schema, fn opt ->
      opt["affects_price"] == true and opt["type"] in ["select", "multiselect"]
    end)
  end

  def get_price_affecting_specs(_), do: []

  @doc """
  Gets price-affecting options for a specific product.

  Combines global and category options, then filters for price-affecting ones.

  If the product has `_option_values` in metadata, only returns options
  for which the product has values. This allows products without certain
  options (e.g., Size) to skip required validation for those options.

  Additionally, discovers options from product metadata that have price modifiers
  but are not defined in the schema (e.g., imported products with custom options).
  """
  def get_price_affecting_specs_for_product(product) do
    schema_specs =
      product
      |> get_option_schema_for_product()
      |> get_price_affecting_specs()
      |> filter_by_product_option_values(product)

    # Discover additional options from product metadata
    discovered_specs = discover_options_from_metadata(product)

    # Merge: schema specs take priority over discovered
    merge_discovered_specs(schema_specs, discovered_specs)
  end

  # Filters options - keeps only those for which product has values in metadata.
  # If product has no _option_values, returns all options (backward compatibility).
  defp filter_by_product_option_values(specs, product) do
    metadata = product.metadata || %{}
    option_values = Map.get(metadata, "_option_values", %{})

    # Only filter if product has _option_values (imported products)
    if option_values != %{} do
      Enum.filter(specs, fn spec ->
        key = spec["key"]

        case Map.get(option_values, key) do
          values when is_list(values) and values != [] -> true
          _ -> false
        end
      end)
    else
      # No _option_values - return all options (backward compatibility)
      specs
    end
  end

  # Discovers options from product metadata that have price modifiers.
  # Creates "virtual" option specs for keys found in _option_values that also
  # have corresponding _price_modifiers entries.
  defp discover_options_from_metadata(product) do
    metadata = product.metadata || %{}
    option_values = Map.get(metadata, "_option_values", %{})
    price_modifiers = Map.get(metadata, "_price_modifiers", %{})

    # For each key in _option_values that has _price_modifiers
    option_values
    |> Enum.filter(fn {key, values} ->
      is_list(values) and values != [] and Map.has_key?(price_modifiers, key)
    end)
    |> Enum.map(fn {key, values} ->
      %{
        "key" => key,
        "label" => humanize_key(key),
        "type" => "select",
        "options" => values,
        "affects_price" => true,
        "modifier_type" => "fixed",
        "allow_override" => true,
        "price_modifiers" => Map.get(price_modifiers, key, %{}),
        "_discovered" => true
      }
    end)
  end

  # Converts snake_case key to human-readable label.
  # Example: "main_color" -> "Main Color"
  defp humanize_key(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Merges schema specs with discovered specs.
  # Schema specs take priority - discovered specs are only added if their key
  # is not already in the schema.
  defp merge_discovered_specs(schema_specs, discovered_specs) do
    schema_keys = Enum.map(schema_specs, & &1["key"]) |> MapSet.new()

    # Only add discovered specs not already in schema
    new_specs =
      Enum.reject(discovered_specs, fn spec ->
        MapSet.member?(schema_keys, spec["key"])
      end)

    schema_specs ++ new_specs
  end

  @doc """
  Gets the price modifier for a specific option value.

  Returns a Decimal value representing the price delta for the selected option.
  Returns Decimal.new("0") if the option has no modifier or option doesn't affect price.

  For "custom" modifier type, the modifiers come from product metadata.

  ## Examples

      opt = %{
        "key" => "material",
        "affects_price" => true,
        "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
      }

      Options.get_price_modifier(opt, "PETG")
      # => Decimal.new("10.00")

      Options.get_price_modifier(opt, "PLA")
      # => Decimal.new("0")
  """
  def get_price_modifier(%{"affects_price" => true, "price_modifiers" => modifiers}, value)
      when is_map(modifiers) and is_binary(value) do
    case Map.get(modifiers, value) do
      nil ->
        Decimal.new("0")

      modifier when is_binary(modifier) ->
        parse_decimal(modifier)
    end
  end

  def get_price_modifier(_, _), do: Decimal.new("0")

  @doc """
  Gets the effective modifier info (type and value) for an option, checking for product overrides.

  Returns `{modifier_type, modifier_value}` tuple.

  If the option has `allow_override: true` and the product has an override in metadata,
  uses the override type and value. Otherwise uses defaults from option's schema.

  ## Override Structure

  Overrides in metadata can be:
  - New format: `%{"type" => "fixed", "value" => "10.00"}` - custom type and value
  - Legacy format: `"10.00"` - just value, inherits option's default type

  ## Examples

      # Option with custom override (type + value)
      opt = %{"key" => "material", "allow_override" => true, "modifier_type" => "fixed", ...}
      metadata = %{"_price_modifiers" => %{"material" => %{"PETG" => %{"type" => "percent", "value" => "15"}}}}
      get_effective_modifier_info(opt, "PETG", metadata)
      # => {"percent", Decimal.new("15")}

      # Option with legacy override (just value)
      metadata = %{"_price_modifiers" => %{"material" => %{"PETG" => "15.00"}}}
      get_effective_modifier_info(opt, "PETG", metadata)
      # => {"fixed", Decimal.new("15.00")}  # Uses option's default type
  """
  def get_effective_modifier_info(opt, selected_value, metadata)

  def get_effective_modifier_info(
        %{"key" => key, "allow_override" => true, "modifier_type" => default_type} = opt,
        selected_value,
        metadata
      )
      when is_binary(selected_value) and is_map(metadata) do
    case get_override_info(metadata, key, selected_value) do
      {:ok, type, value} ->
        {type || default_type, Decimal.new(value)}

      :not_found ->
        default_value = get_price_modifier(opt, selected_value)
        {default_type, default_value}
    end
  end

  def get_effective_modifier_info(
        %{"modifier_type" => default_type} = opt,
        selected_value,
        _metadata
      ) do
    # No allow_override - use defaults
    {default_type, get_price_modifier(opt, selected_value)}
  end

  def get_effective_modifier_info(opt, selected_value, _metadata) do
    # Fallback: fixed type
    {"fixed", get_price_modifier(opt, selected_value)}
  end

  # Helper to get override info from metadata (type + value)
  defp get_override_info(metadata, option_key, option_value) do
    case metadata do
      %{"_price_modifiers" => %{^option_key => modifiers}} when is_map(modifiers) ->
        case Map.get(modifiers, option_value) do
          # New format: %{"type" => "percent", "value" => "15"}
          %{"type" => type, "value" => value} when is_binary(value) and value != "" ->
            {:ok, type, value}

          %{"value" => value} when is_binary(value) and value != "" ->
            {:ok, nil, value}

          # Legacy format: just a string value
          value when is_binary(value) and value != "" ->
            {:ok, nil, value}

          _ ->
            :not_found
        end

      _ ->
        :not_found
    end
  end

  # Legacy function - kept for backward compatibility
  def get_effective_modifier(opt, selected_value, metadata) do
    {_type, value} = get_effective_modifier_info(opt, selected_value, metadata)
    value
  end

  @doc """
  Gets the price modifier for overridden values from product metadata.

  Used when option has `allow_override: true` and the product has custom values
  stored in metadata under `_price_modifiers` key.

  ## Examples

      product_metadata = %{
        "_price_modifiers" => %{
          "material" => %{"PLA" => "0", "PETG" => "15.00"}
        }
      }

      Options.get_custom_price_modifier(product_metadata, "material", "PETG")
      # => Decimal.new("15.00")
  """
  def get_custom_price_modifier(metadata, option_key, option_value)
      when is_map(metadata) and is_binary(option_key) and is_binary(option_value) do
    case metadata do
      %{"_price_modifiers" => %{^option_key => modifiers}} when is_map(modifiers) ->
        case Map.get(modifiers, option_value) do
          nil -> Decimal.new("0")
          "" -> Decimal.new("0")
          modifier when is_binary(modifier) -> Decimal.new(modifier)
          _ -> Decimal.new("0")
        end

      _ ->
        Decimal.new("0")
    end
  end

  def get_custom_price_modifier(_, _, _), do: Decimal.new("0")

  @doc """
  Calculates total price modifier for selected specifications.

  Takes a list of price-affecting options, a map of selected values, and the base price.
  Returns the final price after applying all modifiers.

  ## Options

  - `product_metadata` - Optional product metadata for custom modifier values.
    When provided, options with `modifier_type: "custom"` will use price values
    from `metadata["_price_modifiers"][option_key][option_value]`.

  ## Calculation Order

  1. Sum all fixed modifiers (from schema price_modifiers)
  2. Sum all custom modifiers (from product metadata)
  3. Add to base price (intermediate price)
  4. Sum all percent modifiers
  5. Apply percent to intermediate price: intermediate * (1 + percent_sum/100)

  ## Examples

      specs = [
        %{"key" => "material", "affects_price" => true, "modifier_type" => "fixed",
          "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}},
        %{"key" => "finish", "affects_price" => true, "modifier_type" => "percent",
          "price_modifiers" => %{"Standard" => "0", "Premium" => "20"}}
      ]

      selected = %{"material" => "PETG", "finish" => "Premium"}
      base_price = Decimal.new("20.00")

      Options.calculate_final_price(specs, selected, base_price)
      # => Decimal.new("36.00")  # ($20 + $10) * 1.20
  """
  def calculate_final_price(specs, selected_specs, base_price, product_metadata \\ %{})

  def calculate_final_price(specs, selected_specs, base_price, product_metadata)
      when is_list(specs) and is_map(selected_specs) do
    base = if is_nil(base_price), do: Decimal.new("0"), else: base_price
    metadata = product_metadata || %{}

    # For each option, get the effective type and value (considering overrides)
    # Then group by effective type
    modifiers =
      Enum.map(specs, fn opt ->
        selected_value = Map.get(selected_specs, opt["key"])

        if selected_value do
          {type, value} = get_effective_modifier_info(opt, selected_value, metadata)
          {type, value}
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Split into fixed and percent based on effective type
    {fixed_modifiers, percent_modifiers} =
      Enum.split_with(modifiers, fn {type, _value} -> type == "fixed" end)

    # Sum fixed modifiers
    fixed_sum =
      Enum.reduce(fixed_modifiers, Decimal.new("0"), fn {_type, value}, acc ->
        Decimal.add(acc, value)
      end)

    # Calculate intermediate price (base + fixed)
    intermediate = Decimal.add(base, fixed_sum)

    # Sum percent modifiers
    percent_sum =
      Enum.reduce(percent_modifiers, Decimal.new("0"), fn {_type, value}, acc ->
        Decimal.add(acc, value)
      end)

    # Apply percent modifier: intermediate * (1 + percent_sum/100)
    if Decimal.compare(percent_sum, Decimal.new("0")) == :gt do
      multiplier = Decimal.add(Decimal.new("1"), Decimal.div(percent_sum, Decimal.new("100")))
      Decimal.mult(intermediate, multiplier) |> Decimal.round(2)
    else
      intermediate
    end
  end

  def calculate_final_price(_, _, base_price, _), do: base_price || Decimal.new("0")

  @doc """
  Calculates total modifier amount (for backward compatibility).

  This function returns just the sum of fixed modifiers.
  For full calculation with percent modifiers, use `calculate_final_price/3`.

  ## Examples

      specs = [
        %{"key" => "material", "affects_price" => true, "price_modifiers" => %{"PETG" => "10.00"}},
        %{"key" => "color", "affects_price" => true, "price_modifiers" => %{"Gold" => "8.00"}}
      ]

      selected = %{"material" => "PETG", "color" => "Gold"}

      Options.calculate_total_modifier(specs, selected)
      # => Decimal.new("18.00")
  """
  def calculate_total_modifier(specs, selected_specs)
      when is_list(specs) and is_map(selected_specs) do
    # Only sum fixed modifiers for backward compatibility
    fixed_specs =
      Enum.filter(specs, fn opt ->
        Map.get(opt, "modifier_type", "fixed") == "fixed"
      end)

    Enum.reduce(fixed_specs, Decimal.new("0"), fn opt, acc ->
      selected_value = Map.get(selected_specs, opt["key"])
      modifier = get_price_modifier(opt, selected_value)
      Decimal.add(acc, modifier)
    end)
  end

  def calculate_total_modifier(_, _), do: Decimal.new("0")

  @doc """
  Gets the min/max price range for a list of options.

  For each option, finds the minimum and maximum modifier values,
  then calculates the final price range considering both fixed and percent modifiers.

  Returns `{min_price, max_price}` as Decimals.

  ## Examples

      specs = [
        %{"key" => "material", "modifier_type" => "fixed",
          "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}},
        %{"key" => "finish", "modifier_type" => "percent",
          "price_modifiers" => %{"Standard" => "0", "Premium" => "20"}}
      ]
      base_price = Decimal.new("20.00")

      Options.get_price_range(specs, base_price)
      # => {Decimal.new("20.00"), Decimal.new("36.00")}
  """
  def get_price_range(specs, base_price, product_metadata \\ %{})

  def get_price_range(specs, base_price, product_metadata) when is_list(specs) do
    base = if is_nil(base_price), do: Decimal.new("0"), else: base_price
    metadata = product_metadata || %{}

    if Enum.empty?(specs) do
      {base, base}
    else
      # Separate by modifier type: fixed vs percent
      {fixed_specs, percent_specs} =
        Enum.split_with(specs, fn opt ->
          Map.get(opt, "modifier_type", "fixed") == "fixed"
        end)

      # Calculate min/max for fixed modifiers (considering overrides)
      {fixed_min, fixed_max} = get_effective_modifier_range(fixed_specs, metadata)

      # Calculate min/max for percent modifiers (considering overrides)
      {percent_min, percent_max} = get_effective_modifier_range(percent_specs, metadata)

      # Calculate min price: (base + fixed_min) * (1 + percent_min/100)
      min_intermediate = Decimal.add(base, fixed_min)

      min_price =
        if Decimal.compare(percent_min, Decimal.new("0")) == :gt do
          multiplier =
            Decimal.add(Decimal.new("1"), Decimal.div(percent_min, Decimal.new("100")))

          Decimal.mult(min_intermediate, multiplier) |> Decimal.round(2)
        else
          min_intermediate
        end

      # Calculate max price: (base + fixed_max) * (1 + percent_max/100)
      max_intermediate = Decimal.add(base, fixed_max)

      max_price =
        if Decimal.compare(percent_max, Decimal.new("0")) == :gt do
          multiplier =
            Decimal.add(Decimal.new("1"), Decimal.div(percent_max, Decimal.new("100")))

          Decimal.mult(max_intermediate, multiplier) |> Decimal.round(2)
        else
          max_intermediate
        end

      {min_price, max_price}
    end
  end

  def get_price_range(_, base_price, _) do
    base = if is_nil(base_price), do: Decimal.new("0"), else: base_price
    {base, base}
  end

  @doc """
  Gets the min/max modifier range for a list of options.

  Returns `{min_total, max_total}` as Decimals.
  """
  def get_modifier_range(specs) when is_list(specs) do
    Enum.reduce(specs, {Decimal.new("0"), Decimal.new("0")}, fn opt, {min_acc, max_acc} ->
      modifiers = opt["price_modifiers"] || %{}
      values = Map.values(modifiers) |> Enum.map(&parse_decimal/1)

      if Enum.empty?(values) do
        {min_acc, max_acc}
      else
        {
          Decimal.add(min_acc, Enum.min(values)),
          Decimal.add(max_acc, Enum.max(values))
        }
      end
    end)
  end

  def get_modifier_range(_), do: {Decimal.new("0"), Decimal.new("0")}

  @doc """
  Gets the min/max modifier range for options, considering product overrides.

  For options with `allow_override: true`, checks if product has override values
  in metadata and uses those instead of defaults.

  Returns `{min_total, max_total}` as Decimals.
  """
  def get_effective_modifier_range(specs, metadata) when is_list(specs) and is_map(metadata) do
    Enum.reduce(specs, {Decimal.new("0"), Decimal.new("0")}, fn opt, {min_acc, max_acc} ->
      option_key = opt["key"]
      allow_override = opt["allow_override"] == true
      default_modifiers = opt["price_modifiers"] || %{}

      # Get modifiers: check for overrides first, then fall back to defaults
      modifiers =
        if allow_override do
          case metadata do
            %{"_price_modifiers" => %{^option_key => mods}} when is_map(mods) ->
              # Merge: override values take precedence
              Map.merge(default_modifiers, mods)

            _ ->
              default_modifiers
          end
        else
          default_modifiers
        end

      values = Map.values(modifiers) |> Enum.map(&parse_decimal/1)

      if Enum.empty?(values) do
        {min_acc, max_acc}
      else
        {
          Decimal.add(min_acc, Enum.min(values)),
          Decimal.add(max_acc, Enum.max(values))
        }
      end
    end)
  end

  def get_effective_modifier_range(specs, _metadata) when is_list(specs) do
    get_modifier_range(specs)
  end

  def get_effective_modifier_range(_, _), do: {Decimal.new("0"), Decimal.new("0")}

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} ->
        decimal

      _ ->
        require Logger
        Logger.warning("[Shop.Options] Invalid price modifier value: #{inspect(value)}")
        Decimal.new("0")
    end
  end

  defp parse_decimal(value) do
    require Logger

    if value not in [nil, ""] do
      Logger.warning("[Shop.Options] Unexpected price modifier type: #{inspect(value)}")
    end

    Decimal.new("0")
  end

  # ============================================
  # PRIVATE
  # ============================================

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
