defmodule PhoenixKit.Modules.Publishing.MetadataTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Metadata

  # ============================================================================
  # parse_with_content/1
  # ============================================================================

  describe "parse_with_content/1" do
    test "parses frontmatter and content" do
      input = """
      ---
      slug: hello-world
      status: published
      published_at: 2025-01-15T10:00:00Z
      ---

      # Hello World

      This is the content.
      """

      {:ok, metadata, content} = Metadata.parse_with_content(input)

      assert metadata.slug == "hello-world"
      assert metadata.status == "published"
      assert metadata.published_at == "2025-01-15T10:00:00Z"
      assert metadata.title == "Hello World"
      assert content =~ "Hello World"
      assert content =~ "This is the content."
    end

    test "extracts title from first H1 heading" do
      input = """
      ---
      slug: test
      status: draft
      published_at: 2025-01-01T00:00:00Z
      ---

      Some preamble text

      # My Title

      Content here
      """

      {:ok, metadata, _content} = Metadata.parse_with_content(input)
      assert metadata.title == "My Title"
    end

    test "falls back to first line when no H1 heading" do
      input = """
      ---
      slug: test
      status: draft
      published_at: 2025-01-01T00:00:00Z
      ---

      Just some plain text without a heading
      """

      {:ok, metadata, _content} = Metadata.parse_with_content(input)
      assert metadata.title == "Just some plain text without a heading"
    end

    test "returns Untitled for empty content" do
      input = """
      ---
      slug: empty
      status: draft
      published_at: 2025-01-01T00:00:00Z
      ---

      """

      {:ok, metadata, _content} = Metadata.parse_with_content(input)
      assert metadata.title == "Untitled"
    end

    test "parses version fields" do
      input = """
      ---
      slug: versioned-post
      status: draft
      published_at: 2025-01-01T00:00:00Z
      version: 3
      version_created_at: 2025-02-01T00:00:00Z
      version_created_from: 2
      allow_version_access: true
      ---

      # Test
      """

      {:ok, metadata, _content} = Metadata.parse_with_content(input)
      assert metadata.version == 3
      assert metadata.version_created_at == "2025-02-01T00:00:00Z"
      assert metadata.version_created_from == 2
      assert metadata.allow_version_access == true
    end

    test "parses url_slug and previous_url_slugs" do
      input = """
      ---
      slug: my-post
      status: published
      published_at: 2025-01-01T00:00:00Z
      url_slug: custom-url
      previous_url_slugs: old-url,older-url
      ---

      # Test
      """

      {:ok, metadata, _content} = Metadata.parse_with_content(input)
      assert metadata.url_slug == "custom-url"
      assert metadata.previous_url_slugs == ["old-url", "older-url"]
    end

    test "parses primary_language" do
      input = """
      ---
      slug: multilang
      status: draft
      published_at: 2025-01-01T00:00:00Z
      primary_language: es
      ---

      # Hola
      """

      {:ok, metadata, _content} = Metadata.parse_with_content(input)
      assert metadata.primary_language == "es"
    end

    test "parses audit metadata fields" do
      input = """
      ---
      slug: audited
      status: draft
      published_at: 2025-01-01T00:00:00Z
      created_at: 2025-01-01T00:00:00Z
      created_by_uuid: 42
      created_by_email: user@example.com
      updated_by_uuid: 43
      updated_by_email: editor@example.com
      ---

      # Test
      """

      {:ok, metadata, _content} = Metadata.parse_with_content(input)
      assert metadata.created_at == "2025-01-01T00:00:00Z"
      assert metadata.created_by_uuid == "42"
      assert metadata.created_by_email == "user@example.com"
      assert metadata.updated_by_uuid == "43"
      assert metadata.updated_by_email == "editor@example.com"
    end

    test "handles legacy XML format" do
      input =
        ~s(<Page title="Legacy Post" status="published" slug="legacy" published_at="2024-01-01T00:00:00Z">\nContent\n</Page>)

      {:ok, metadata, _content} = Metadata.parse_with_content(input)
      assert metadata.slug == "legacy"
      assert metadata.status == "published"
    end
  end

  # ============================================================================
  # serialize/1
  # ============================================================================

  describe "serialize/1" do
    test "serializes required fields" do
      metadata = %{
        slug: "hello",
        status: "published",
        published_at: "2025-01-01T00:00:00Z"
      }

      result = Metadata.serialize(metadata)
      assert result =~ "---"
      assert result =~ "slug: hello"
      assert result =~ "status: published"
      assert result =~ "published_at: 2025-01-01T00:00:00Z"
    end

    test "includes optional fields when present" do
      metadata = %{
        slug: "test",
        status: "draft",
        published_at: "2025-01-01T00:00:00Z",
        featured_image_uuid: "img-123",
        version: 2,
        primary_language: "en",
        allow_version_access: true
      }

      result = Metadata.serialize(metadata)
      assert result =~ "featured_image_uuid: img-123"
      assert result =~ "version: 2"
      assert result =~ "primary_language: en"
      assert result =~ "allow_version_access: true"
    end

    test "omits nil and empty optional fields" do
      metadata = %{
        slug: "minimal",
        status: "draft",
        published_at: "2025-01-01T00:00:00Z",
        featured_image_uuid: nil,
        version: nil,
        url_slug: nil
      }

      result = Metadata.serialize(metadata)
      refute result =~ "featured_image_uuid"
      refute result =~ "version:"
      refute result =~ "url_slug"
    end

    test "serializes allow_version_access true" do
      metadata = %{
        slug: "test",
        status: "draft",
        published_at: "2025-01-01T00:00:00Z",
        allow_version_access: true
      }

      result = Metadata.serialize(metadata)
      assert result =~ "allow_version_access: true"
    end

    test "omits allow_version_access when false" do
      metadata = %{
        slug: "test",
        status: "draft",
        published_at: "2025-01-01T00:00:00Z",
        allow_version_access: false
      }

      result = Metadata.serialize(metadata)
      refute result =~ "allow_version_access"
    end

    test "serializes previous_url_slugs as comma-separated" do
      metadata = %{
        slug: "current",
        status: "published",
        published_at: "2025-01-01T00:00:00Z",
        previous_url_slugs: ["old-slug", "older-slug"]
      }

      result = Metadata.serialize(metadata)
      assert result =~ "previous_url_slugs: old-slug,older-slug"
    end
  end

  # ============================================================================
  # Round-trip: serialize -> parse
  # ============================================================================

  describe "serialize/parse round-trip" do
    test "metadata survives round-trip" do
      original = %{
        slug: "round-trip",
        status: "published",
        published_at: "2025-06-15T14:30:00Z",
        version: 2,
        version_created_at: "2025-06-10T10:00:00Z",
        version_created_from: 1,
        allow_version_access: true,
        url_slug: "custom-url",
        previous_url_slugs: ["old-url"],
        primary_language: "en",
        featured_image_uuid: "img-abc",
        created_at: "2025-06-01T00:00:00Z",
        created_by_email: "author@test.com"
      }

      serialized = Metadata.serialize(original)
      full_content = serialized <> "\n\n# Title\n\nBody text"
      {:ok, parsed, _content} = Metadata.parse_with_content(full_content)

      assert parsed.slug == original.slug
      assert parsed.status == original.status
      assert parsed.published_at == original.published_at
      assert parsed.version == original.version
      assert parsed.version_created_from == original.version_created_from
      assert parsed.allow_version_access == original.allow_version_access
      assert parsed.url_slug == original.url_slug
      assert parsed.previous_url_slugs == original.previous_url_slugs
      assert parsed.primary_language == original.primary_language
      assert parsed.featured_image_uuid == original.featured_image_uuid
    end
  end

  # ============================================================================
  # default_metadata/0
  # ============================================================================

  describe "default_metadata/0" do
    test "returns valid defaults" do
      defaults = Metadata.default_metadata()

      assert defaults.status == "draft"
      assert defaults.title == ""
      assert defaults.slug == ""
      assert defaults.version == 1
      assert defaults.allow_version_access == false
      assert defaults.url_slug == nil
      assert defaults.previous_url_slugs == nil
      assert defaults.primary_language == nil
      assert is_binary(defaults.published_at)
    end
  end

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
