defmodule PhoenixKit.Modules.Sitemap.LLMText.Sources.SourceTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

  # A valid stub source
  defmodule ValidSource do
    @behaviour PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

    def source_name, do: :valid_stub
    def enabled?, do: true

    def collect_index_entries(_language),
      do: [%{title: "Page", url: "/page", description: "Desc", group: "General"}]

    def serve_page(["page.md"], _language), do: {:ok, "# Page\nContent"}
    def serve_page(_, _), do: :not_found
  end

  # A disabled source
  defmodule DisabledSource do
    @behaviour PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

    def source_name, do: :disabled_stub
    def enabled?, do: false

    def collect_index_entries(_language),
      do: [%{title: "Hidden", url: "/hidden", description: "Hidden", group: "Hidden"}]

    def serve_page(_, _), do: {:ok, "# Hidden"}
  end

  # A crashing source
  defmodule CrashingSource do
    @behaviour PhoenixKit.Modules.Sitemap.LLMText.Sources.Source

    def source_name, do: :crashing_stub
    def enabled?, do: true
    def collect_index_entries(_language), do: raise("collect_index_entries crash")
    def serve_page(_, _), do: raise("serve_page crash")
  end

  # An invalid module (missing callbacks)
  defmodule InvalidSource do
    def source_name, do: :invalid
  end

  describe "valid_source?/1" do
    test "returns true for a module with all 4 callbacks" do
      assert Source.valid_source?(ValidSource) == true
    end

    test "returns false for a module missing callbacks" do
      assert Source.valid_source?(InvalidSource) == false
    end

    test "returns false for a non-existent module" do
      assert Source.valid_source?(NonExistentModule.Foo) == false
    end

    test "returns false for non-atom" do
      assert Source.valid_source?("not_a_module") == false
    end
  end

  describe "safe_collect_index_entries/2" do
    test "returns entries when source is valid and enabled" do
      result = Source.safe_collect_index_entries(ValidSource, "en")
      assert [%{title: "Page", url: "/page"}] = result
    end

    test "returns [] when source is disabled" do
      result = Source.safe_collect_index_entries(DisabledSource, "en")
      assert result == []
    end

    test "returns [] when source crashes" do
      result = Source.safe_collect_index_entries(CrashingSource, "en")
      assert result == []
    end

    test "returns [] for invalid module" do
      result = Source.safe_collect_index_entries(InvalidSource, "en")
      assert result == []
    end

    test "accepts nil language" do
      result = Source.safe_collect_index_entries(ValidSource, nil)
      assert [%{title: "Page"}] = result
    end
  end

  describe "safe_serve_page/3" do
    test "returns {:ok, content} when source is valid and enabled" do
      result = Source.safe_serve_page(ValidSource, ["page.md"], "en")
      assert {:ok, _content} = result
    end

    test "returns :not_found when source is disabled" do
      result = Source.safe_serve_page(DisabledSource, ["hidden.md"], "en")
      assert result == :not_found
    end

    test "returns :not_found when source crashes" do
      result = Source.safe_serve_page(CrashingSource, ["some.md"], "en")
      assert result == :not_found
    end

    test "returns :not_found for invalid module" do
      result = Source.safe_serve_page(InvalidSource, ["page.md"], "en")
      assert result == :not_found
    end

    test "accepts nil language" do
      result = Source.safe_serve_page(ValidSource, ["page.md"], nil)
      assert {:ok, _content} = result
    end
  end
end
