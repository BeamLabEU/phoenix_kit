defmodule PhoenixKit.Modules.Shop.Import.FormatDetector do
  @moduledoc """
  Auto-detect CSV format from file headers.

  Iterates known format modules and calls `detect?/1` on each.
  First match wins, so order matters.
  """

  alias PhoenixKit.Modules.Shop.Import.CSVValidator
  alias PhoenixKit.Modules.Shop.Import.{PromUaFormat, ShopifyFormat}

  # Ordered list — first match wins.
  # PromUaFormat first because its markers are more specific (Ukrainian columns).
  @formats [PromUaFormat, ShopifyFormat]

  @doc """
  Detect format module from CSV file path.
  Returns `{:ok, format_module}` or `{:error, :unknown_format}`.
  """
  def detect(path) do
    case CSVValidator.extract_headers(path) do
      {:ok, headers} -> detect_from_headers(headers)
      {:error, _} = error -> error
    end
  end

  @doc "Detect format module from pre-extracted headers."
  def detect_from_headers(headers) do
    case Enum.find(@formats, & &1.detect?(headers)) do
      nil -> {:error, :unknown_format}
      mod -> {:ok, mod}
    end
  end

  @doc "Returns human-readable format name."
  def format_name(ShopifyFormat), do: "Shopify"
  def format_name(PromUaFormat), do: "Prom.ua"
  def format_name(_), do: "Unknown"
end
