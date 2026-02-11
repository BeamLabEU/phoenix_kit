defmodule PhoenixKit.Modules.Sitemap.Sources.Source do
  @moduledoc """
  Behaviour for sitemap data sources.

  Each source module must implement this behaviour to provide URL entries
  for sitemap generation.

  ## Required Callbacks

  - `source_name/0` - Unique atom identifier for the source
  - `enabled?/0` - Whether this source is active
  - `collect/1` - Collect URL entries from this source

  ## Optional Callbacks

  - `sitemap_filename/0` - Custom filename for the module's sitemap file
  - `sub_sitemaps/1` - Split into multiple sub-sitemap files (e.g., per-blog, per-entity-type)
  """

  require Logger

  alias PhoenixKit.Modules.Sitemap.UrlEntry

  @doc """
  Returns the unique name/identifier for this source.
  """
  @callback source_name() :: atom()

  @doc """
  Checks if this source is enabled and should be included in sitemap.
  """
  @callback enabled?() :: boolean()

  @doc """
  Collects all URL entries from this source.
  """
  @callback collect(opts :: keyword()) :: [UrlEntry.t()]

  @doc """
  Returns the base filename for this source's sitemap file (without .xml extension).

  Default: `"sitemap-\#{source_name()}"`
  """
  @callback sitemap_filename() :: String.t()

  @doc """
  Returns a list of sub-sitemaps for sources that produce multiple files.

  Return `nil` for a single file, or a list of `{group_name, entries}` tuples
  for per-group splitting (e.g., per-blog, per-entity-type).

  Each group will be saved as `sitemap-{source}-{group_name}.xml`.
  """
  @callback sub_sitemaps(opts :: keyword()) :: [{String.t(), [UrlEntry.t()]}] | nil

  @optional_callbacks [sitemap_filename: 0, sub_sitemaps: 1]

  @doc """
  Helper function to check if a source module is valid.
  """
  @spec valid_source?(module()) :: boolean()
  def valid_source?(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        function_exported?(module, :source_name, 0) and
          function_exported?(module, :enabled?, 0) and
          function_exported?(module, :collect, 1)

      {:error, _} ->
        false
    end
  end

  def valid_source?(_), do: false

  @doc """
  Returns the sitemap filename for a source module.

  Calls the optional `sitemap_filename/0` callback if implemented,
  otherwise returns `"sitemap-\#{source_name()}"`.
  """
  @spec get_sitemap_filename(module()) :: String.t()
  def get_sitemap_filename(source_module) do
    if function_exported?(source_module, :sitemap_filename, 0) do
      source_module.sitemap_filename()
    else
      "sitemap-#{source_module.source_name()}"
    end
  end

  @doc """
  Returns sub-sitemaps for a source module, or nil if not implemented.
  """
  @spec get_sub_sitemaps(module(), keyword()) :: [{String.t(), [UrlEntry.t()]}] | nil
  def get_sub_sitemaps(source_module, opts \\ []) do
    if function_exported?(source_module, :sub_sitemaps, 1) do
      source_module.sub_sitemaps(opts)
    else
      nil
    end
  end

  @doc """
  Safely collects entries from a source, handling errors gracefully.
  """
  @spec safe_collect(module(), keyword()) :: [UrlEntry.t()]
  def safe_collect(source_module, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if valid_source?(source_module) and (force or source_module.enabled?()) do
      source_module.collect(opts)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "Sitemap source #{inspect(source_module)} failed to collect: #{inspect(error)}"
      )

      []
  end
end
