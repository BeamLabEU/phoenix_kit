defmodule PhoenixKit.Modules.Sitemap.LLMText.Sources.PublishingTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Sitemap.LLMText.Sources.Publishing

  describe "source_name/0" do
    test "returns :publishing" do
      assert Publishing.source_name() == :publishing
    end
  end

  describe "enabled?/0" do
    test "returns false when Publishing module is not available" do
      assert Publishing.enabled?() == false
    end
  end

  describe "build_file_path/2" do
    test "builds path as group_slug/post_slug.txt" do
      assert Publishing.build_file_path("blog", "hello-world") == "blog/hello-world.txt"
    end

    test "works with any group and slug" do
      assert Publishing.build_file_path("news", "2024-01-15-10-30") ==
               "news/2024-01-15-10-30.txt"
    end
  end

  describe "extract_description/1" do
    test "returns metadata.description atom key when present" do
      post = %{metadata: %{description: "A great post", status: "published"}, content: "body"}
      assert Publishing.extract_description(post) == "A great post"
    end

    test "returns metadata description string key when present" do
      post = %{metadata: %{"description" => "A great post"}, content: "body"}
      assert Publishing.extract_description(post) == "A great post"
    end

    test "falls back to first 160 chars of content when description is absent" do
      long_content = String.duplicate("word ", 50)
      post = %{metadata: %{status: "published"}, content: long_content}
      result = Publishing.extract_description(post)
      assert String.length(result) <= 160
      assert String.starts_with?(result, "word")
    end

    test "returns empty string when description is empty and no content" do
      post = %{metadata: %{description: ""}, content: ""}
      assert Publishing.extract_description(post) == ""
    end

    test "returns empty string when metadata has no description and content is nil" do
      post = %{metadata: %{status: "published"}}
      assert Publishing.extract_description(post) == ""
    end

    test "collapses whitespace in content fallback" do
      post = %{metadata: %{}, content: "Hello\n\nWorld  more text"}
      result = Publishing.extract_description(post)
      refute result =~ "\n"
      assert result =~ "Hello"
    end

    test "strips markdown headings in content fallback" do
      post = %{metadata: %{}, content: "## My Heading\n\nSome paragraph text."}
      result = Publishing.extract_description(post)
      refute result =~ "#"
      assert result =~ "My Heading"
    end

    test "strips bold and italic markdown in content fallback" do
      post = %{metadata: %{}, content: "**bold** and *italic* text"}
      result = Publishing.extract_description(post)
      assert result =~ "bold"
      assert result =~ "italic"
      refute result =~ "**"
      refute result =~ ~r/\*[^*]/
    end

    test "strips markdown links in content fallback" do
      post = %{metadata: %{}, content: "See [the docs](https://example.com) for details."}
      result = Publishing.extract_description(post)
      assert result =~ "the docs"
      refute result =~ "https://example.com"
      refute result =~ "["
    end
  end

  describe "build_post_content/3" do
    test "includes title as h1 heading" do
      post = %{
        metadata: %{description: "desc", status: "published"},
        content: "Post body.",
        mode: :slug,
        url_slug: "my-post",
        slug: "my-post"
      }

      result = Publishing.build_post_content(post, "blog", "My Post")
      assert result =~ "# My Post"
    end

    test "includes source URL line" do
      post = %{
        metadata: %{description: "", status: "published"},
        content: "Body.",
        mode: :slug,
        url_slug: "my-post",
        slug: "my-post"
      }

      result = Publishing.build_post_content(post, "blog", "Title")
      assert result =~ "> Source:"
    end

    test "includes post body content" do
      post = %{
        metadata: %{description: "", status: "published"},
        content: "This is the body.",
        mode: :slug,
        url_slug: "my-post",
        slug: "my-post"
      }

      result = Publishing.build_post_content(post, "blog", "Title")
      assert result =~ "This is the body."
    end

    test "includes description when present" do
      post = %{
        metadata: %{description: "A great description", status: "published"},
        content: "Body.",
        mode: :slug,
        url_slug: "my-post",
        slug: "my-post"
      }

      result = Publishing.build_post_content(post, "blog", "Title")
      assert result =~ "A great description"
    end

    test "handles missing content gracefully" do
      post = %{
        metadata: %{description: "", status: "published"},
        mode: :slug,
        url_slug: "my-post",
        slug: "my-post"
      }

      result = Publishing.build_post_content(post, "blog", "Title")
      assert is_binary(result)
      assert result =~ "# Title"
    end
  end
end
