defmodule PhoenixKit.Modules.LLMText.Sources.SourceTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.LLMText.Sources.Source

  # A valid stub source
  defmodule ValidSource do
    @behaviour PhoenixKit.Modules.LLMText.Sources.Source

    def source_name, do: :valid_stub
    def enabled?, do: true

    def collect_index_entries,
      do: [%{title: "Page", url: "/page", description: "Desc", group: "General"}]

    def collect_page_files, do: [{"page.md", "# Page\nContent"}]
  end

  # A disabled source
  defmodule DisabledSource do
    @behaviour PhoenixKit.Modules.LLMText.Sources.Source

    def source_name, do: :disabled_stub
    def enabled?, do: false

    def collect_index_entries,
      do: [%{title: "Hidden", url: "/hidden", description: "Hidden", group: "Hidden"}]

    def collect_page_files, do: [{"hidden.md", "# Hidden"}]
  end

  # A crashing source
  defmodule CrashingSource do
    @behaviour PhoenixKit.Modules.LLMText.Sources.Source

    def source_name, do: :crashing_stub
    def enabled?, do: true
    def collect_index_entries, do: raise("collect_index_entries crash")
    def collect_page_files, do: raise("collect_page_files crash")
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

  describe "safe_collect_page_files/1" do
    test "returns files when source is valid and enabled" do
      result = Source.safe_collect_page_files(ValidSource)
      assert result == [{"page.md", "# Page\nContent"}]
    end

    test "returns [] when source is disabled" do
      result = Source.safe_collect_page_files(DisabledSource)
      assert result == []
    end

    test "returns [] when source crashes" do
      result = Source.safe_collect_page_files(CrashingSource)
      assert result == []
    end

    test "returns [] for invalid module" do
      result = Source.safe_collect_page_files(InvalidSource)
      assert result == []
    end
  end

  describe "safe_collect_index_entries/1" do
    test "returns entries when source is valid and enabled" do
      result = Source.safe_collect_index_entries(ValidSource)
      assert [%{title: "Page", url: "/page"}] = result
    end

    test "returns [] when source is disabled" do
      result = Source.safe_collect_index_entries(DisabledSource)
      assert result == []
    end

    test "returns [] when source crashes" do
      result = Source.safe_collect_index_entries(CrashingSource)
      assert result == []
    end
  end
end
