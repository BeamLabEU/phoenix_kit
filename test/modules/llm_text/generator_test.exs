defmodule PhoenixKit.Modules.LLMText.GeneratorTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.LLMText.FileStorage
  alias PhoenixKit.Modules.LLMText.Generator

  defmodule StubSource do
    @behaviour PhoenixKit.Modules.LLMText.Sources.Source

    def source_name, do: :stub
    def enabled?, do: true

    def collect_index_entries do
      [
        %{title: "Home", url: "/", description: "Home page", group: "General"},
        %{title: "About", url: "/about", description: "About us", group: "General"},
        %{title: "Blog", url: "/blog", description: "Latest posts", group: "Posts"}
      ]
    end

    def collect_page_files do
      [
        {"home.md", "# Home\nWelcome"},
        {"about.md", "# About\nAbout us"}
      ]
    end
  end

  defmodule DisabledSource do
    @behaviour PhoenixKit.Modules.LLMText.Sources.Source

    def source_name, do: :disabled_stub
    def enabled?, do: false

    def collect_index_entries,
      do: [%{title: "Hidden", url: "/hidden", description: "Hidden", group: "Hidden"}]

    def collect_page_files, do: [{"hidden.md", "# Hidden"}]
  end

  setup do
    tmp_dir = System.tmp_dir!() |> Path.join("llm_text_gen_test_#{:rand.uniform(1_000_000)}")
    Application.put_env(:phoenix_kit, :llm_text_test_storage_dir, tmp_dir)
    Application.put_env(:phoenix_kit, :llm_text_sources, [StubSource])

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :llm_text_test_storage_dir)
      Application.delete_env(:phoenix_kit, :llm_text_sources)
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "build_index_content/1" do
    test "builds markdown with header and grouped entries" do
      entries = [
        %{title: "Home", url: "/", description: "Home page", group: "General"},
        %{title: "Blog", url: "/blog", description: "Latest posts", group: "Posts"},
        %{title: "About", url: "/about", description: "About us", group: "General"}
      ]

      content = Generator.build_index_content(entries)

      assert content =~ "## General"
      assert content =~ "## Posts"
      assert content =~ "[Home](/)"
      assert content =~ "[Blog](/blog)"
      assert content =~ "[About](/about)"
    end

    test "group order follows first-seen order" do
      entries = [
        %{title: "A", url: "/a", description: "", group: "Second"},
        %{title: "B", url: "/b", description: "", group: "First"},
        %{title: "C", url: "/c", description: "", group: "Second"}
      ]

      content = Generator.build_index_content(entries)
      second_pos = :binary.match(content, "## Second") |> elem(0)
      first_pos = :binary.match(content, "## First") |> elem(0)

      assert second_pos < first_pos
    end

    test "entries without description omit the colon" do
      entries = [%{title: "Page", url: "/page", description: "", group: "General"}]
      content = Generator.build_index_content(entries)
      assert content =~ "[Page](/page)"
      refute content =~ "[Page](/page):"
    end

    test "handles empty entries list" do
      content = Generator.build_index_content([])
      assert is_binary(content)
    end
  end

  describe "run_all/0" do
    test "writes page files from all enabled sources" do
      :ok = Generator.run_all()
      assert FileStorage.exists?("home.md")
      assert FileStorage.exists?("about.md")
    end

    test "writes llms.txt index" do
      :ok = Generator.run_all()
      assert File.exists?(FileStorage.index_path())
      content = File.read!(FileStorage.index_path())
      assert content =~ "Home"
    end

    test "skips disabled sources" do
      Application.put_env(:phoenix_kit, :llm_text_sources, [StubSource, DisabledSource])
      :ok = Generator.run_all()
      refute FileStorage.exists?("hidden.md")
    end
  end

  describe "run_source/1" do
    test "writes files for the given source" do
      :ok = Generator.run_source(StubSource)
      assert FileStorage.exists?("home.md")
      assert FileStorage.exists?("about.md")
    end

    test "rebuilds index after running source" do
      :ok = Generator.run_source(StubSource)
      assert File.exists?(FileStorage.index_path())
    end
  end

  describe "rebuild_index/0" do
    test "writes llms.txt with entries from all enabled sources" do
      :ok = Generator.rebuild_index()
      content = File.read!(FileStorage.index_path())
      assert content =~ "Home"
      assert content =~ "Blog"
    end
  end

  describe "get_sources/0" do
    test "returns configured sources" do
      assert Generator.get_sources() == [StubSource]
    end

    test "returns [] when not configured" do
      Application.delete_env(:phoenix_kit, :llm_text_sources)
      assert Generator.get_sources() == []
    end
  end
end
