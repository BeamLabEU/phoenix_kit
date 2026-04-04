defmodule PhoenixKit.Modules.LLMText.Generator do
  @moduledoc """
  Generator for LLM-friendly text files.

  Produces:
  - `llms.txt` - Index file linking to all LLM-readable pages
  - Individual page `.md` files per source

  ## Usage

      # Regenerate all sources and rebuild index
      Generator.run_all()

      # Regenerate a single source and rebuild index
      Generator.run_source(MyApp.LLMText.BlogSource)

      # Only rebuild the index from all sources
      Generator.rebuild_index()
  """

  require Logger

  alias PhoenixKit.Modules.LLMText.FileStorage
  alias PhoenixKit.Modules.LLMText.Sources.Source

  @doc """
  Regenerates files for one source and rebuilds the llms.txt index.
  """
  @spec run_source(module()) :: :ok
  def run_source(source_module) do
    Logger.info("LLMText.Generator: Running source #{inspect(source_module)}")

    files = Source.safe_collect_page_files(source_module)

    Enum.each(files, fn {path, content} ->
      case FileStorage.write(path, content) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("LLMText.Generator: Failed to write #{path}: #{inspect(reason)}")
      end
    end)

    rebuild_index()
  end

  @doc """
  Regenerates all sources and rebuilds the llms.txt index.
  """
  @spec run_all() :: :ok
  def run_all do
    sources = get_sources()
    Logger.info("LLMText.Generator: Running all #{length(sources)} sources")

    Enum.each(sources, fn source_module ->
      files = Source.safe_collect_page_files(source_module)

      Enum.each(files, fn {path, content} ->
        case FileStorage.write(path, content) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("LLMText.Generator: Failed to write #{path}: #{inspect(reason)}")
        end
      end)
    end)

    rebuild_index()
  end

  @doc """
  Rebuilds the llms.txt index from all sources without regenerating page files.
  """
  @spec rebuild_index() :: :ok
  def rebuild_index do
    sources = get_sources()
    Logger.debug("LLMText.Generator: Rebuilding index from #{length(sources)} sources")

    entries =
      sources
      |> Enum.flat_map(&Source.safe_collect_index_entries/1)

    content = build_index_content(entries)

    case FileStorage.write_index(content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("LLMText.Generator: Failed to write index: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Builds the llms.txt markdown content from a list of index entries.

  Groups entries by their `:group` field. Group order follows first-seen order.
  Within each group, entries appear in the order they were provided.
  """
  @spec build_index_content([Source.index_entry()]) :: String.t()
  def build_index_content(entries) do
    site_name = get_site_name()
    site_description = get_site_description()

    # Build ordered groups (first-seen order) using prepend + reverse for O(n) performance
    {groups_reversed, groups_map} =
      Enum.reduce(entries, {[], %{}}, fn entry, {order, map} ->
        group = Map.get(entry, :group, "General")

        if Map.has_key?(map, group) do
          {order, Map.update!(map, group, &[entry | &1])}
        else
          {[group | order], Map.put(map, group, [entry])}
        end
      end)

    groups_ordered = Enum.reverse(groups_reversed)

    header =
      if site_description && site_description != "" do
        "# #{site_name}\n\n> #{site_description}\n\n"
      else
        "# #{site_name}\n\n"
      end

    sections =
      Enum.map_join(groups_ordered, "\n\n", fn group ->
        group_entries = Map.get(groups_map, group, []) |> Enum.reverse()

        links =
          Enum.map_join(group_entries, "\n", fn entry ->
            title = Map.get(entry, :title, "")
            url = Map.get(entry, :url, "")
            description = Map.get(entry, :description, "")

            if description && description != "" do
              "- [#{title}](#{url}): #{description}"
            else
              "- [#{title}](#{url})"
            end
          end)

        "## #{group}\n\n#{links}"
      end)

    header <> sections
  end

  @doc """
  Returns the configured LLM text sources.
  """
  @spec get_sources() :: [module()]
  def get_sources do
    Application.get_env(:phoenix_kit, :llm_text_sources, [])
  end

  # Private helpers

  defp get_site_name do
    PhoenixKit.Settings.get_setting("site_name", "Site")
  rescue
    _ -> "Site"
  end

  defp get_site_description do
    PhoenixKit.Settings.get_setting("site_description", "")
  rescue
    _ -> ""
  end
end
