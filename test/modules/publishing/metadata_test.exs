defmodule PhoenixKit.Modules.Publishing.MetadataTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Metadata

  # ============================================================================
  # extract_title_from_content/1
  # ============================================================================

  describe "extract_title_from_content/1" do
    test "extracts H1 heading" do
      assert Metadata.extract_title_from_content("# Hello World") == "Hello World"
    end

    test "extracts H1 from multiline content" do
      content = """
      Some text

      # The Title

      More content
      """

      assert Metadata.extract_title_from_content(content) == "The Title"
    end

    test "returns Untitled for empty string" do
      assert Metadata.extract_title_from_content("") == "Untitled"
    end

    test "returns Untitled for nil" do
      assert Metadata.extract_title_from_content(nil) == "Untitled"
    end

    test "falls back to first line when no H1" do
      assert Metadata.extract_title_from_content("Just text\nMore text") == "Just text"
    end

    test "ignores content inside components" do
      content = """
      <Hero title="Welcome">
        # This should be ignored
      </Hero>

      # Real Title
      """

      assert Metadata.extract_title_from_content(content) == "Real Title"
    end

    test "extracts title from Headline component" do
      content = "<Headline>My Headline</Headline>"
      assert Metadata.extract_title_from_content(content) == "My Headline"
    end

    test "extracts title from Hero component title attribute" do
      content = ~s(<Hero title="Welcome Home" background="dark" />)
      assert Metadata.extract_title_from_content(content) == "Welcome Home"
    end
  end
end
