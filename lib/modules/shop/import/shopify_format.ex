defmodule PhoenixKit.Modules.Shop.Import.ShopifyFormat do
  @moduledoc """
  Shopify CSV format adapter implementing `ImportFormat` behaviour.

  Wraps existing CSVParser, Filter, and ProductTransformer modules
  behind the uniform import format interface. No logic changes — pure delegation.
  """

  @behaviour PhoenixKit.Modules.Shop.Import.ImportFormat

  alias PhoenixKit.Modules.Shop.Import.{CSVParser, Filter, ProductTransformer}
  alias PhoenixKit.Modules.Shop.ImportConfig

  @shopify_markers ["Handle", "Title", "Variant Price"]

  @impl true
  def detect?(headers) do
    header_set = MapSet.new(headers)
    Enum.all?(@shopify_markers, &MapSet.member?(header_set, &1))
  end

  @impl true
  def requires_option_mapping?, do: true

  @impl true
  def count(path, config) do
    CSVParser.parse_and_group(path)
    |> Enum.count(fn {_handle, rows} -> Filter.should_include?(rows, config) end)
  end

  @impl true
  def parse_and_transform(path, categories_map, config, opts) do
    language = Keyword.get(opts, :language)
    option_mappings = Keyword.get(opts, :option_mappings, [])

    CSVParser.parse_and_group(path)
    |> Enum.filter(fn {_handle, rows} -> Filter.should_include?(rows, config) end)
    |> Enum.map(fn {handle, rows} ->
      transform_opts = [language: language, option_mappings: option_mappings]

      if option_mappings != [] do
        ProductTransformer.transform_extended(
          handle,
          rows,
          categories_map,
          config,
          transform_opts
        )
      else
        ProductTransformer.transform(handle, rows, categories_map, config, transform_opts)
      end
    end)
  end

  @impl true
  def default_config_attrs do
    config = ImportConfig.from_legacy_defaults()

    config
    |> Map.from_struct()
    |> Map.drop([:__meta__, :id, :uuid, :inserted_at, :updated_at])
  end
end
