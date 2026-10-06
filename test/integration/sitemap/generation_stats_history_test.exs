defmodule PhoenixKit.Integration.Sitemap.GenerationStatsHistoryTest do
  @moduledoc """
  The generation stats are machine stamps — rewritten on every generation and
  every cache invalidation — so they are stored without the settings history
  (`PhoenixKit.Settings.History`, "Machine stamps").
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.History

  @keys ~w(sitemap_last_generated sitemap_url_count sitemap_module_stats)

  test "generation and clearing store the stats and record no history" do
    {:ok, _} =
      Sitemap.update_generation_stats(%{url_count: 3, timestamp: ~U[2026-10-06 10:00:00Z]})

    {:ok, _} = Sitemap.update_module_stats([%{filename: "sitemap-pages.xml", url_count: 3}])

    {:ok, _} =
      Sitemap.update_generation_stats(%{url_count: 5, timestamp: ~U[2026-10-07 10:00:00Z]})

    assert Settings.get_setting("sitemap_last_generated") == "2026-10-07T10:00:00Z"
    assert Settings.get_setting("sitemap_url_count") == "5"

    assert %{"modules" => [%{"url_count" => 3}]} =
             Settings.get_json_setting("sitemap_module_stats")

    :ok = Sitemap.clear_generation_stats()
    assert Settings.get_setting("sitemap_url_count") == "0"

    for key <- @keys, do: assert(History.list(key) == [], "#{key} recorded history")
  end

  test "the cached documents are stored without history" do
    {:ok, _} = Sitemap.cache_xml("<urlset>one</urlset>")
    {:ok, _} = Sitemap.cache_xml("<urlset>two</urlset>")
    {:ok, _} = Sitemap.cache_html("<html>one</html>")
    {:ok, _} = Sitemap.cache_html("<html>two</html>")

    assert Settings.get_setting("sitemap_xml_cache") == "<urlset>two</urlset>"
    assert Settings.get_setting("sitemap_html_cache") == "<html>two</html>"
    assert History.list("sitemap_xml_cache") == []
    assert History.list("sitemap_html_cache") == []
  end
end
