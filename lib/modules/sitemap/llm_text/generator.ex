defmodule PhoenixKit.Modules.Sitemap.LLMText.Generator do
  @moduledoc """
  Generator for LLM-friendly text content.

  Produces llms.txt index content on-the-fly from configured sources.

  ## Usage

      # Build index for default language
      Generator.build_index()

      # Build index for a specific language
      Generator.build_index("en")
      Generator.build_index("uk")
  """

  alias PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

  @doc """
  Builds llms.txt index content for a specific language.

  Queries all configured sources and merges their index entries.
  """
  @spec build_index(String.t() | nil) :: String.t()
  def build_index(language \\ nil) do
    sources = get_sources()
    entries = Enum.flat_map(sources, &Source.safe_collect_index_entries(&1, language))
    build_index_content(entries)
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
    Application.get_env(:phoenix_kit, :sitemap_llm_text_sources, [])
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
