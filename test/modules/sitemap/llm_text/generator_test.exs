defmodule PhoenixKit.Modules.Sitemap.LLMText.GeneratorTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Sitemap.LLMText.Generator

  defmodule StubSource do
    @behaviour PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

    def source_name, do: :stub
    def enabled?, do: true

    def collect_index_entries(_language) do
      [
        %{title: "Home", url: "/", description: "Home page", group: "General"},
        %{title: "About", url: "/about", description: "About us", group: "General"},
        %{title: "Blog", url: "/blog", description: "Latest posts", group: "Posts"}
      ]
    end

    def serve_page(_path_parts, _language), do: :not_found
  end

  defmodule DisabledSource do
    @behaviour PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

    def source_name, do: :disabled_stub
    def enabled?, do: false

    def collect_index_entries(_language),
      do: [%{title: "Hidden", url: "/hidden", description: "Hidden", group: "Hidden"}]

    def serve_page(_path_parts, _language), do: :not_found
  end

  setup do
    Application.put_env(:phoenix_kit, :sitemap_llm_text_sources, [StubSource])

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :sitemap_llm_text_sources)
    end)

    :ok
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

  describe "build_index/1" do
    test "returns string content for default language" do
      content = Generator.build_index()
      assert is_binary(content)
      assert content =~ "Home"
    end

    test "returns string content for specific language" do
      content = Generator.build_index("en")
      assert is_binary(content)
    end

    test "skips disabled sources" do
      Application.put_env(:phoenix_kit, :sitemap_llm_text_sources, [StubSource, DisabledSource])
      content = Generator.build_index()
      refute content =~ "Hidden"
    end

    test "returns string when no sources configured" do
      Application.delete_env(:phoenix_kit, :sitemap_llm_text_sources)
      content = Generator.build_index()
      assert is_binary(content)
    end
  end

  describe "get_sources/0" do
    test "returns configured sources" do
      assert Generator.get_sources() == [StubSource]
    end

    test "returns [] when not configured" do
      Application.delete_env(:phoenix_kit, :sitemap_llm_text_sources)
      assert Generator.get_sources() == []
    end
  end
end
