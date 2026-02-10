defmodule PhoenixKit.Modules.Shop.Import.ImportFormat do
  @moduledoc """
  Behaviour for CSV import format adapters.

  All CSV format modules (Shopify, Prom.ua, etc.) implement this behaviour
  to provide a uniform interface for the import pipeline.
  """

  alias PhoenixKit.Modules.Shop.ImportConfig

  @doc "Returns true if the given CSV headers match this format."
  @callback detect?(headers :: [String.t()]) :: boolean()

  @doc "Counts the number of products that will be imported from the file."
  @callback count(path :: String.t(), config :: ImportConfig.t() | nil) :: non_neg_integer()

  @doc "Whether the :configure wizard step (option mapping UI) should be shown."
  @callback requires_option_mapping?() :: boolean()

  @doc """
  Parses CSV and returns a list/stream of product attrs maps ready for `Shop.upsert_product/1`.
  """
  @callback parse_and_transform(
              path :: String.t(),
              categories_map :: map(),
              config :: ImportConfig.t() | nil,
              opts :: keyword()
            ) :: Enumerable.t()

  @doc "Returns default attrs for seeding an ImportConfig for this format."
  @callback default_config_attrs() :: map()
end
