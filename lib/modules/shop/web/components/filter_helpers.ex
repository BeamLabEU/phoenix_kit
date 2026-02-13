defmodule PhoenixKit.Modules.Shop.Web.Components.FilterHelpers do
  @moduledoc """
  Shared helpers for storefront filter state management.

  Used by both ShopCatalog and CatalogCategory LiveViews to:
  - Load enabled filters and aggregate values
  - Parse filter params from URL query string
  - Build query opts for product listing
  - Build URLs with filter params
  """

  alias PhoenixKit.Modules.Shop

  @doc """
  Loads enabled filters and their aggregated values.

  Returns `{filters, filter_values}` tuple.

  Options:
  - `:category_uuid` - Scope aggregation to a category by UUID
  """
  def load_filter_data(opts \\ []) do
    filters = Shop.get_enabled_storefront_filters()
    filter_values = Shop.aggregate_filter_values(opts)
    {filters, filter_values}
  end

  @doc """
  Parses URL query params into active filter state.

  Returns a map: `%{"price" => %{min: Decimal, max: Decimal}, "vendor" => ["V1", "V2"], ...}`
  """
  def parse_filter_params(params, filters) do
    Enum.reduce(filters, %{}, fn filter, acc ->
      case parse_single_filter(filter, params) do
        nil -> acc
        value -> Map.put(acc, filter["key"], value)
      end
    end)
  end

  defp parse_single_filter(%{"type" => "price_range", "key" => key}, params) do
    min_val = parse_decimal(params["#{key}_min"])
    max_val = parse_decimal(params["#{key}_max"])

    if min_val || max_val do
      %{min: min_val, max: max_val}
    else
      nil
    end
  end

  defp parse_single_filter(%{"type" => type, "key" => key}, params)
       when type in ["vendor", "metadata_option"] do
    case params[key] do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> String.split(value, ",", trim: true)
      values when is_list(values) -> values
    end
  end

  defp parse_single_filter(_filter, _params), do: nil

  @doc """
  Converts active filter state into keyword opts for `Shop.list_products_with_count/1`.
  """
  def build_query_opts(active_filters, filters) do
    Enum.reduce(filters, [], fn filter, opts ->
      case Map.get(active_filters, filter["key"]) do
        nil ->
          opts

        %{min: min_val, max: max_val} ->
          opts
          |> maybe_add_opt(:price_min, min_val)
          |> maybe_add_opt(:price_max, max_val)

        values when is_list(values) and values != [] ->
          case filter["type"] do
            "vendor" ->
              Keyword.put(opts, :vendors, values)

            "metadata_option" ->
              existing = Keyword.get(opts, :metadata_filters, [])
              meta = %{key: filter["option_key"] || filter["key"], values: values}
              Keyword.put(opts, :metadata_filters, existing ++ [meta])

            _ ->
              opts
          end

        _ ->
          opts
      end
    end)
  end

  @doc """
  Builds a query string from active filter state (e.g. `"?price_min=10&price_max=100"` or `""`).

  Used to append filter params to navigation links so filter state persists
  across page transitions.
  """
  def build_query_string(active_filters, filters) do
    params = build_params_map(active_filters, filters)
    if params == %{}, do: "", else: "?" <> URI.encode_query(params)
  end

  @doc """
  Builds a URL path with filter query params.

  Merges filter state into a clean query string, preserving page param only
  when `keep_page` is true.
  """
  def build_filter_url(base_path, active_filters, filters, opts \\ []) do
    page = Keyword.get(opts, :page)
    params = build_params_map(active_filters, filters)
    params = if page && page > 1, do: Map.put(params, "page", page), else: params

    if params == %{} do
      base_path
    else
      query = URI.encode_query(params)
      "#{base_path}?#{query}"
    end
  end

  defp build_params_map(active_filters, filters) do
    Enum.reduce(filters, %{}, fn filter, acc ->
      case Map.get(active_filters, filter["key"]) do
        nil ->
          acc

        %{min: min_val, max: max_val} ->
          acc
          |> maybe_put_param("#{filter["key"]}_min", min_val)
          |> maybe_put_param("#{filter["key"]}_max", max_val)

        values when is_list(values) and values != [] ->
          Map.put(acc, filter["key"], Enum.join(values, ","))

        _ ->
          acc
      end
    end)
  end

  @doc """
  Returns true if any filters are currently active.
  """
  def has_active_filters?(active_filters) do
    active_filters != %{} and
      Enum.any?(active_filters, fn
        {_key, %{min: nil, max: nil}} -> false
        {_key, []} -> false
        {_key, nil} -> false
        _ -> true
      end)
  end

  @doc """
  Counts the number of active filter values (for mobile badge).
  """
  def active_filter_count(active_filters) do
    Enum.reduce(active_filters, 0, fn
      {_key, %{min: min_val, max: max_val}}, count ->
        count + if(min_val, do: 1, else: 0) + if max_val, do: 1, else: 0

      {_key, values}, count when is_list(values) ->
        count + length(values)

      _, count ->
        count
    end)
  end

  @doc """
  Toggles a value in a checkbox-type filter.
  Returns updated active_filters map.
  """
  def toggle_filter_value(active_filters, filter_key, value) do
    current = Map.get(active_filters, filter_key, [])

    updated =
      if value in current do
        List.delete(current, value)
      else
        current ++ [value]
      end

    if updated == [] do
      Map.delete(active_filters, filter_key)
    else
      Map.put(active_filters, filter_key, updated)
    end
  end

  @doc """
  Updates price range filter.
  Returns updated active_filters map.
  """
  def update_price_filter(active_filters, filter_key, min_val, max_val) do
    min_dec = parse_decimal(min_val)
    max_dec = parse_decimal(max_val)

    if min_dec || max_dec do
      Map.put(active_filters, filter_key, %{min: min_dec, max: max_dec})
    else
      Map.delete(active_filters, filter_key)
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {decimal, ""} -> decimal
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(val) when is_number(val), do: Decimal.new(val)
  defp parse_decimal(%Decimal{} = val), do: val

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp maybe_put_param(params, _key, nil), do: params

  defp maybe_put_param(params, key, %Decimal{} = val) do
    Map.put(params, key, Decimal.to_string(val))
  end

  defp maybe_put_param(params, key, val), do: Map.put(params, key, to_string(val))
end
