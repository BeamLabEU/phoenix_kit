defmodule PhoenixKit.Modules.Sitemap.Sources.Source do
  @moduledoc """
  Behaviour for sitemap data sources.

  Each source module must implement this behaviour to provide URL entries
  for sitemap generation. Sources can collect data from various PhoenixKit
  modules like Entities, Blogging, Pages, etc.

  ## Implementing a Source

      defmodule PhoenixKit.Modules.Sitemap.Sources.MyModule do
        @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

        alias PhoenixKit.Modules.Sitemap.UrlEntry

        @impl true
        def source_name, do: :my_module

        @impl true
        def enabled?, do: MyModule.enabled?()

        @impl true
        def collect(_opts) do
          if enabled?() do
            # Collect URLs from your module
            [
              UrlEntry.new(%{
                loc: "https://example.com/my-page",
                lastmod: DateTime.utc_now(),
                changefreq: "weekly",
                priority: 0.8,
                title: "My Page",
                category: "My Module",
                source: :my_module
              })
            ]
          else
            []
          end
        end
      end

  ## Adding Source to Generator

  After implementing the source, add it to the generator's source list
  in `PhoenixKit.Modules.Sitemap.Generator.collect_all_entries/2`.
  """

  require Logger

  alias PhoenixKit.Modules.Sitemap.UrlEntry

  @doc """
  Returns the unique name/identifier for this source.

  Used for logging, filtering, and organizing sitemap entries.
  """
  @callback source_name() :: atom()

  @doc """
  Checks if this source is enabled and should be included in sitemap.

  Should return false if the underlying module is disabled or
  if sitemap collection is turned off for this source.
  """
  @callback enabled?() :: boolean()

  @doc """
  Collects all URL entries from this source.

  Options may include:
  - `:language` - Preferred language for content
  - `:base_url` - Base URL for building full URLs

  Should return an empty list if the source is disabled.
  """
  @callback collect(opts :: keyword()) :: [UrlEntry.t()]

  @doc """
  Helper function to check if a source module is valid.

  Ensures the module is loaded before checking for exported functions.
  """
  @spec valid_source?(module()) :: boolean()
  def valid_source?(module) when is_atom(module) do
    # Ensure module is loaded before checking function exports
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
  Safely collects entries from a source, handling errors gracefully.
  """
  @spec safe_collect(module(), keyword()) :: [UrlEntry.t()]
  def safe_collect(source_module, opts \\ []) do
    if valid_source?(source_module) and source_module.enabled?() do
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
