defmodule PhoenixKit.Integration.Sitemap.StreamingSourceTest do
  @moduledoc """
  End-to-end checks for `stream/1` sitemap sources: a `Repo.stream/2` source
  works without opening its own transaction (the generator opens one), a
  streaming source forces index mode even with flat mode on, and a stream
  failing mid-way leaves the other sources' files in place.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.FileStorage
  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.Modules.Sitemap.UrlEntry
  alias PhoenixKit.Settings

  @base_url "https://example.test"

  defmodule RepoStreamSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    import Ecto.Query

    alias PhoenixKit.Test.Repo

    @impl true
    def source_name, do: :stream_it_repo
    @impl true
    def enabled?, do: true

    # The typical pattern: Repo.stream with no transaction of its own.
    @impl true
    def stream(opts) do
      base_url = Keyword.fetch!(opts, :base_url)

      from(s in fragment("SELECT generate_series(1, 60001) AS n"), select: s.n)
      |> Repo.stream(max_rows: 5_000)
      |> Stream.map(&UrlEntry.new(%{loc: "#{base_url}/item/#{&1}", source: :stream_it_repo}))
    end
  end

  defmodule FailingSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :stream_it_failing
    @impl true
    def enabled?, do: true

    @impl true
    def stream(_opts) do
      Stream.map(1..10, fn
        5 -> raise "stream broke"
        i -> UrlEntry.new(%{loc: "https://example.test/broken/#{i}"})
      end)
    end
  end

  defmodule CollectSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :stream_it_collect
    @impl true
    def enabled?, do: true
    @impl true
    def collect(_opts), do: [UrlEntry.new(%{loc: "https://example.test/listed", title: "Listed"})]
  end

  setup do
    previous = Application.get_env(:phoenix_kit, :sitemap)
    {:ok, _} = Settings.update_setting("site_url", @base_url)
    {:ok, _} = Settings.update_boolean_setting("crawlers_no_index", false)
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", true)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :sitemap, previous),
        else: Application.delete_env(:phoenix_kit, :sitemap)

      for file <- FileStorage.list_module_files(),
          String.starts_with?(file, "sitemap-stream_it_") do
        FileStorage.delete_module(file)
      end
    end)

    :ok
  end

  defp use_sources(sources), do: Application.put_env(:phoenix_kit, :sitemap, sources: sources)

  test "a Repo.stream source is read inside the generator's transaction" do
    use_sources([RepoStreamSource])

    assert [
             %{filename: "sitemap-stream_it_repo-1", url_count: 50_000},
             %{filename: "sitemap-stream_it_repo-2", url_count: 10_001}
           ] =
             Generator.generate_module(RepoStreamSource, base_url: @base_url, xsl_enabled: false)

    {:ok, xml} = FileStorage.load_module("sitemap-stream_it_repo-2")
    assert xml =~ "#{@base_url}/item/60001"
  end

  test "flat mode with a streaming source generates the index instead" do
    {:ok, _} = Settings.update_boolean_setting("sitemap_router_discovery_enabled", true)
    use_sources([CollectSource, RepoStreamSource])

    assert Sitemap.flat_mode?()
    refute Generator.flat_mode?()

    log =
      capture_log(fn ->
        assert {:ok, result} = Generator.generate_all(base_url: @base_url, xsl_enabled: false)
        assert result.index_xml =~ "<sitemapindex"
        assert result.index_xml =~ "/sitemaps/sitemap-stream_it_repo-1.xml"
        assert result.index_xml =~ "/sitemaps/sitemap-stream_it_collect.xml"
        assert result.total_urls == 60_002
      end)

    assert log =~ "index mode instead"
  end

  test "without a streaming source flat mode is unchanged and never calls stream/1" do
    {:ok, _} = Settings.update_boolean_setting("sitemap_router_discovery_enabled", true)
    use_sources([CollectSource])

    assert Generator.flat_mode?()
    assert {:ok, result} = Generator.generate_all(base_url: @base_url, xsl_enabled: false)
    assert result.index_xml =~ "<urlset"
  end

  test "a stream failing mid-way drops only that source" do
    {:ok, _} = Settings.update_boolean_setting("sitemap_router_discovery_enabled", false)
    use_sources([FailingSource, CollectSource])

    log =
      capture_log(fn ->
        assert {:ok, result} = Generator.generate_all(base_url: @base_url, xsl_enabled: false)
        assert Enum.map(result.modules, & &1.filename) == ["sitemap-stream_it_collect"]
        refute result.index_xml =~ "stream_it_failing"
      end)

    assert log =~ "stream broke"
    refute FileStorage.module_exists?("sitemap-stream_it_failing")
  end

  test "the HTML sitemap links a streamed source's files instead of its URLs" do
    {:ok, _} = Settings.update_boolean_setting("sitemap_router_discovery_enabled", false)
    use_sources([CollectSource, RepoStreamSource])

    {:ok, %{modules: modules}} = Generator.generate_all(base_url: @base_url, xsl_enabled: false)
    Sitemap.update_module_stats(modules)

    {:ok, html} = Generator.generate_html(base_url: @base_url, style: "flat", cache: false)

    assert html =~ "Listed"
    assert html =~ ~r{href="#{@base_url}[^"]*/sitemaps/sitemap-stream_it_repo-1\.xml"}
    assert html =~ "(50000 pages)"
    refute html =~ "/item/1<"
  end
end
