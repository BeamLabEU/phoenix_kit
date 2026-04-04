defmodule PhoenixKit.Modules.Sitemap.LLMText.Sources.Source do
  @moduledoc """
  Behaviour for LLM text data sources.

  Each source module must implement this behaviour to provide content
  for LLM-friendly text files (llms.txt index and individual page files).

  ## Required Callbacks

  - `source_name/0` - Unique atom identifier for the source
  - `enabled?/0` - Whether this source is active
  - `collect_index_entries/0` - Collect index entries for llms.txt
  - `collect_page_files/0` - Collect individual page files

  ## Index Entry Format

  Each index entry is a map with:
  - `:title` - Page title (string)
  - `:url` - Full URL to the page (string)
  - `:description` - Brief description (string)
  - `:group` - Group name for organizing entries (string)
  """

  require Logger

  @type index_entry :: %{
          title: String.t(),
          url: String.t(),
          description: String.t(),
          group: String.t()
        }

  @doc """
  Returns the unique name/identifier for this source.
  """
  @callback source_name() :: atom()

  @doc """
  Checks if this source is enabled and should be included.
  """
  @callback enabled?() :: boolean()

  @doc """
  Collects index entries for llms.txt from this source.
  """
  @callback collect_index_entries() :: [index_entry()]

  @doc """
  Collects individual page files from this source.

  Returns a list of `{relative_path, content}` tuples.
  The relative_path is relative to the llms storage directory.
  """
  @callback collect_page_files() :: [{path :: String.t(), content :: String.t()}]

  @doc """
  Checks if a source module implements all required callbacks.
  """
  @spec valid_source?(module()) :: boolean()
  def valid_source?(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        function_exported?(module, :source_name, 0) and
          function_exported?(module, :enabled?, 0) and
          function_exported?(module, :collect_index_entries, 0) and
          function_exported?(module, :collect_page_files, 0)

      {:error, _} ->
        false
    end
  end

  def valid_source?(_), do: false

  @doc """
  Safely collects index entries from a source, returning [] if disabled or on error.
  """
  @spec safe_collect_index_entries(module()) :: [index_entry()]
  def safe_collect_index_entries(source_module) do
    if valid_source?(source_module) and source_module.enabled?() do
      source_module.collect_index_entries()
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "Sitemap.LLMText source #{inspect(source_module)} failed to collect index entries: #{inspect(error)}"
      )

      []
  end

  @doc """
  Safely collects page files from a source, returning [] if disabled or on error.
  """
  @spec safe_collect_page_files(module()) :: [{String.t(), String.t()}]
  def safe_collect_page_files(source_module) do
    if valid_source?(source_module) and source_module.enabled?() do
      source_module.collect_page_files()
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "Sitemap.LLMText source #{inspect(source_module)} failed to collect page files: #{inspect(error)}"
      )

      []
  end
end
