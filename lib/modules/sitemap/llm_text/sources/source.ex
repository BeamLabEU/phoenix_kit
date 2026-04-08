defmodule PhoenixKit.Modules.Sitemap.LLMText.Sources.Source do
  @moduledoc """
  Behaviour for LLM text data sources.

  Each source module must implement this behaviour to provide content
  for LLM-friendly text served on-the-fly at request time.

  ## Required Callbacks

  - `source_name/0` - Unique atom identifier for the source
  - `enabled?/0` - Whether this source is active
  - `collect_index_entries/1` - Collect index entries for llms.txt for a given language
  - `serve_page/2` - Serve individual page content for given path parts and language

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

  Language is a code like "en", "uk", "et". May be nil (use default).
  """
  @callback collect_index_entries(language :: String.t() | nil) :: [index_entry()]

  @doc """
  Serves an individual page for the given path parts and language.

  path_parts are path segments AFTER the language prefix, e.g.:
    - ["blog", "post-slug.md"]          (publishing)
    - ["shop", "product", "vase.md"]    (shop product)

  Returns {:ok, markdown_content} or :not_found.
  The source should return :not_found for paths it doesn't own.
  """
  @callback serve_page(path_parts :: [String.t()], language :: String.t() | nil) ::
              {:ok, String.t()} | :not_found

  @doc """
  Checks if a source module implements all required callbacks.
  """
  @spec valid_source?(module()) :: boolean()
  def valid_source?(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        function_exported?(module, :source_name, 0) and
          function_exported?(module, :enabled?, 0) and
          function_exported?(module, :collect_index_entries, 1) and
          function_exported?(module, :serve_page, 2)

      {:error, _} ->
        false
    end
  end

  def valid_source?(_), do: false

  @doc """
  Safely collects index entries from a source for the given language.
  Returns [] if disabled or on error.
  """
  @spec safe_collect_index_entries(module(), String.t() | nil) :: [index_entry()]
  def safe_collect_index_entries(source_module, language) do
    if valid_source?(source_module) and source_module.enabled?() do
      source_module.collect_index_entries(language)
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
  Safely serves a page from a source.
  Returns {:ok, content} or :not_found.
  """
  @spec safe_serve_page(module(), [String.t()], String.t() | nil) ::
          {:ok, String.t()} | :not_found
  def safe_serve_page(source_module, path_parts, language) do
    if valid_source?(source_module) and source_module.enabled?() do
      source_module.serve_page(path_parts, language)
    else
      :not_found
    end
  rescue
    error ->
      Logger.warning(
        "Sitemap.LLMText source #{inspect(source_module)} failed to serve page #{inspect(path_parts)}: #{inspect(error)}"
      )

      :not_found
  end

  @doc """
  Strips common Markdown formatting from a string, returning plain text.

  Shared utility used by sources to produce clean descriptions.
  """
  @spec strip_markdown(String.t() | any()) :: String.t()
  def strip_markdown(text) when is_binary(text) do
    text
    |> String.replace(~r/^#+\s+/m, "")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
    |> String.replace(~r/\*([^*]+)\*/, "\\1")
    |> String.replace(~r/>\s+/m, "")
    |> String.replace(~r/---+/m, "")
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def strip_markdown(_), do: ""
end
