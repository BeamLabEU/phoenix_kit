defmodule PhoenixKit.Modules.Sitemap.StreamingSourceTest do
  # Writes module files into the shared sitemaps dir; names are unique to
  # this file, but keep it serial with the other sitemap tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Sitemap.FileStorage
  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.Modules.Sitemap.HtmlGenerator
  alias PhoenixKit.Modules.Sitemap.Sources.Source
  alias PhoenixKit.Modules.Sitemap.UrlEntry

  # A stream of `n` synthetic entries that records every pull in an ETS
  # table, refuses to be enumerated twice, and checks — at the moment it
  # yields entry 100_002 — whether file 1 is already on disk. If the
  # generator materialised the stream first, no file would exist yet.
  defmodule BigSource do
    @moduledoc false
    @behaviour Source

    @impl true
    def source_name, do: :stream_test_big
    @impl true
    def enabled?, do: true
    @impl true
    def stream_repo, do: nil

    @impl true
    def stream(_opts) do
      [{:size, n}] = :ets.lookup(:stream_test_probe, :size)

      Stream.resource(
        fn ->
          if :ets.update_counter(:stream_test_probe, :starts, 1) > 1,
            do: raise("stream enumerated twice")

          1
        end,
        fn
          i when i > n ->
            {:halt, i}

          i ->
            :ets.update_counter(:stream_test_probe, :pulls, 1)

            if i == 100_002 do
              :ets.insert(
                :stream_test_probe,
                {:file1_before_chunk3, FileStorage.module_exists?("sitemap-stream_test_big-1")}
              )
            end

            {[UrlEntry.new(%{loc: "https://example.test/p/#{i}", source: :stream_test_big})],
             i + 1}
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule FailingSource do
    @moduledoc false
    @behaviour Source

    @impl true
    def source_name, do: :stream_test_failing
    @impl true
    def enabled?, do: true
    @impl true
    def stream_repo, do: nil

    @impl true
    def stream(_opts) do
      Stream.map(1..120_000, fn
        60_001 -> raise "database went away"
        i -> UrlEntry.new(%{loc: "https://example.test/f/#{i}"})
      end)
    end
  end

  defmodule CollectSource do
    @moduledoc false
    @behaviour Source

    @impl true
    def source_name, do: :stream_test_collect
    @impl true
    def enabled?, do: true
    @impl true
    def collect(_opts), do: [UrlEntry.new(%{loc: "https://example.test/collected"})]
  end

  defmodule BrokenStreamCall do
    @moduledoc false
    @behaviour Source

    @impl true
    def source_name, do: :stream_test_broken
    @impl true
    def enabled?, do: true
    @impl true
    def stream(_opts), do: raise("boom")
  end

  defmodule NotEnumerable do
    @moduledoc false
    @behaviour Source

    @impl true
    def source_name, do: :stream_test_not_enum
    @impl true
    def enabled?, do: true
    @impl true
    def stream(_opts), do: :oops
  end

  defmodule DisabledStream do
    @moduledoc false
    @behaviour Source

    @impl true
    def source_name, do: :stream_test_disabled
    @impl true
    def enabled?, do: false
    @impl true
    def stream(_opts), do: [UrlEntry.new(%{loc: "https://example.test/d"})]
  end

  defmodule DuplicateSource do
    @moduledoc false
    @behaviour Source

    @impl true
    def source_name, do: :stream_test_dupes
    @impl true
    def enabled?, do: true
    @impl true
    def stream_repo, do: nil

    @impl true
    def stream(_opts) do
      Stream.map([1, 2, 2, 3], &UrlEntry.new(%{loc: "https://example.test/d/#{&1}"}))
    end
  end

  setup do
    if :ets.whereis(:stream_test_probe) == :undefined do
      :ets.new(:stream_test_probe, [:named_table, :public, :set])
    end

    :ets.delete_all_objects(:stream_test_probe)
    :ets.insert(:stream_test_probe, [{:size, 0}, {:starts, 0}, {:pulls, 0}])

    on_exit(fn ->
      for file <- FileStorage.list_module_files(),
          String.starts_with?(file, "sitemap-stream_test_") do
        FileStorage.delete_module(file)
      end
    end)

    :ok
  end

  defp file_xml(filename) do
    {:ok, xml} = FileStorage.load_module(filename)
    xml
  end

  defp loc_count(xml), do: length(String.split(xml, "<loc>")) - 1

  describe "index mode, streaming source" do
    test "120_001 entries become three files, written chunk by chunk" do
      :ets.insert(:stream_test_probe, {:size, 120_001})

      infos = Generator.generate_module(BigSource, xsl_enabled: false)

      assert Enum.map(infos, &{&1.filename, &1.url_count}) == [
               {"sitemap-stream_test_big-1", 50_000},
               {"sitemap-stream_test_big-2", 50_000},
               {"sitemap-stream_test_big-3", 20_001}
             ]

      assert Enum.sum(Enum.map(infos, & &1.url_count)) == 120_001

      assert loc_count(file_xml("sitemap-stream_test_big-1")) == 50_000
      assert loc_count(file_xml("sitemap-stream_test_big-3")) == 20_001
      assert file_xml("sitemap-stream_test_big-3") =~ "https://example.test/p/120001"
      refute FileStorage.module_exists?("sitemap-stream_test_big")

      # Consumed once, every entry pulled exactly once, and file 1 was on
      # disk before the third chunk was read: never materialised.
      assert :ets.lookup(:stream_test_probe, :starts) == [{:starts, 1}]
      assert :ets.lookup(:stream_test_probe, :pulls) == [{:pulls, 120_001}]

      assert :ets.lookup(:stream_test_probe, :file1_before_chunk3) == [
               {:file1_before_chunk3, true}
             ]
    end

    test "a stream that fits one file keeps the plain file name" do
      :ets.insert(:stream_test_probe, {:size, 50_000})

      assert [%{filename: "sitemap-stream_test_big", url_count: 50_000}] =
               Generator.generate_module(BigSource, xsl_enabled: false)

      refute FileStorage.module_exists?("sitemap-stream_test_big-1")
    end

    test "an empty stream writes nothing and removes the old file" do
      FileStorage.save_module("sitemap-stream_test_big", "<urlset/>")

      assert Generator.generate_module(BigSource, xsl_enabled: false) == []
      refute FileStorage.module_exists?("sitemap-stream_test_big")
    end

    # A source's earlier, differently sized run left files this run does not
    # write; index mode serves every module file on disk, so they were served.
    test "files of an earlier, larger or differently split run are removed" do
      seed = fn names -> for n <- names, do: FileStorage.save_module(n, "<urlset/>") end

      files = fn ->
        Enum.filter(
          FileStorage.list_module_files(),
          &String.starts_with?(&1, "sitemap-stream_test_big")
        )
        |> Enum.sort()
      end

      old_split =
        ~w(sitemap-stream_test_big-1 sitemap-stream_test_big-2 sitemap-stream_test_big-3)

      # Another source's file whose name only starts the same way stays.
      FileStorage.save_module("sitemap-stream_test_bigger", "<urlset/>")

      # Empty now: every numbered file goes.
      seed.(old_split)
      assert Generator.generate_module(BigSource, xsl_enabled: false) == []
      assert files.() == ["sitemap-stream_test_bigger"]

      # Fits one file now: the bare file stays, the numbered ones go.
      seed.(old_split)
      :ets.insert(:stream_test_probe, [{:size, 50_000}, {:starts, 0}])
      Generator.generate_module(BigSource, xsl_enabled: false)
      assert files.() == ["sitemap-stream_test_big", "sitemap-stream_test_bigger"]

      # Two files now: the old bare file and the old third file go.
      seed.(["sitemap-stream_test_big-3"])
      :ets.insert(:stream_test_probe, [{:size, 50_001}, {:starts, 0}])
      Generator.generate_module(BigSource, xsl_enabled: false)

      assert files.() == [
               "sitemap-stream_test_big-1",
               "sitemap-stream_test_big-2",
               "sitemap-stream_test_bigger"
             ]
    end

    test "a collected source drops the numbered files of an earlier split run" do
      for n <- ~w(sitemap-stream_test_collect-1 sitemap-stream_test_collect-2),
          do: FileStorage.save_module(n, "<urlset/>")

      assert [%{filename: "sitemap-stream_test_collect"}] =
               Generator.generate_module(CollectSource, xsl_enabled: false)

      assert Enum.filter(
               FileStorage.list_module_files(),
               &String.starts_with?(&1, "sitemap-stream_test_collect")
             ) == ["sitemap-stream_test_collect"]
    end

    test "duplicate locs within a chunk are dropped, stream order is kept" do
      assert [%{url_count: 3}] = Generator.generate_module(DuplicateSource, xsl_enabled: false)

      xml = file_xml("sitemap-stream_test_dupes")
      [one, two, three] = for n <- 1..3, do: :binary.match(xml, "/d/#{n}<") |> elem(0)
      assert one < two and two < three
    end

    test "a stream that raises mid-way is logged, its files are dropped, other sources still generate" do
      # A stale file from an earlier run of the same source goes too.
      FileStorage.save_module("sitemap-stream_test_failing-3", "<urlset/>")

      log =
        capture_log(fn ->
          assert Generator.generate_module(FailingSource, xsl_enabled: false) == []
        end)

      assert log =~ "FailingSource"
      assert log =~ "database went away"

      refute Enum.any?(
               FileStorage.list_module_files(),
               &String.starts_with?(&1, "sitemap-stream_test_failing")
             )

      assert [%{filename: "sitemap-stream_test_collect", url_count: 1}] =
               Generator.generate_module(CollectSource, xsl_enabled: false)
    end
  end

  describe "Source helpers" do
    test "a stream-only source is valid and streaming; collect paths skip it" do
      assert Source.valid_source?(BigSource)
      assert Source.streaming?(BigSource)
      refute Source.streaming?(CollectSource)

      assert Source.safe_collect(BigSource) == []
      assert :ets.lookup(:stream_test_probe, :starts) == [{:starts, 0}]
    end

    test "safe_stream returns the stream lazily for an enabled streaming source" do
      :ets.insert(:stream_test_probe, {:size, 3})

      assert {:ok, stream} = Source.safe_stream(BigSource)
      assert :ets.lookup(:stream_test_probe, :starts) == [{:starts, 0}]
      assert length(Enum.to_list(stream)) == 3
    end

    test "safe_stream skips disabled, collect-only, raising and non-enumerable sources" do
      assert Source.safe_stream(DisabledStream) == :skip
      assert {:ok, _} = Source.safe_stream(DisabledStream, force: true)
      assert Source.safe_stream(CollectSource) == :skip

      log =
        capture_log(fn ->
          assert Source.safe_stream(BrokenStreamCall) == :skip
          assert Source.safe_stream(NotEnumerable) == :skip
        end)

      assert log =~ "BrokenStreamCall"
      assert log =~ "NotEnumerable"
    end

    test "a failure while reading surfaces as StreamError, also through suspension" do
      {:ok, stream} = Source.safe_stream(FailingSource)

      capture_log(fn ->
        assert_raise Source.StreamError, ~r/database went away/, fn -> Stream.run(stream) end

        # zip suspends the inner enumerable between elements
        assert_raise Source.StreamError, fn ->
          stream |> Stream.zip(Stream.cycle([:x])) |> Stream.run()
        end
      end)
    end
  end

  describe "HTML sitemap" do
    test "streamed files are linked with a count, not listed URL by URL" do
      {:ok, html} =
        HtmlGenerator.generate(
          [
            style: "flat",
            streamed_files: [
              %{
                filename: "sitemap-products-1",
                url_count: 50_000,
                loc: "https://example.test/sitemaps/sitemap-products-1.xml"
              }
            ]
          ],
          [UrlEntry.new(%{loc: "https://example.test/about", title: "About"})],
          :html_flat,
          cache: false
        )

      assert html =~ ~s(href="https://example.test/sitemaps/sitemap-products-1.xml")
      assert html =~ "(50000 pages)"
      assert html =~ "About"
    end

    test "without streamed files the page has no extra section" do
      for style <- ["flat", "grouped", "hierarchical"] do
        {:ok, html} = HtmlGenerator.generate([style: style], [], :html_flat, cache: false)
        refute html =~ "sitemap-streamed-files"
      end
    end
  end
end
