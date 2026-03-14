defmodule PhoenixKit.Modules.Publishing.PublishingAPITest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing

  # ============================================================================
  # Module Loading
  # ============================================================================

  describe "module loading" do
    test "Publishing module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing)
    end

    test "DBStorage module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.DBStorage)
    end

    test "ListingCache module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.ListingCache)
    end

    test "LanguageHelpers module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.LanguageHelpers)
    end

    test "SlugHelpers module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.SlugHelpers)
    end

    test "Metadata module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.Metadata)
    end

    test "PubSub module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.PubSub)
    end

    test "All schema modules are defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.PublishingGroup)
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.PublishingPost)
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.PublishingVersion)
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.PublishingContent)
    end

    test "Mapper module is defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.DBStorage.Mapper)
    end

    test "Worker modules are defined" do
      assert Code.ensure_loaded?(
               PhoenixKit.Modules.Publishing.Workers.MigratePrimaryLanguageWorker
             )
    end

    test "Refactored submodules are defined" do
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.Groups)
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.Posts)
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.Versions)
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.TranslationManager)
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.StaleFixer)
      assert Code.ensure_loaded?(PhoenixKit.Modules.Publishing.Shared)
    end
  end

  # ============================================================================
  # slugify/1
  # ============================================================================

  describe "slugify/1" do
    test "converts to lowercase" do
      assert Publishing.slugify("Hello World") == "hello-world"
    end

    test "replaces spaces with hyphens" do
      assert Publishing.slugify("my blog post") == "my-blog-post"
    end

    test "removes special characters" do
      assert Publishing.slugify("Hello! World?") == "hello-world"
    end

    test "trims leading and trailing hyphens" do
      assert Publishing.slugify("  Hello  ") == "hello"
    end

    test "handles multiple consecutive spaces" do
      assert Publishing.slugify("hello   world") == "hello-world"
    end

    test "handles empty string" do
      assert Publishing.slugify("") == ""
    end

    test "handles unicode characters" do
      result = Publishing.slugify("Héllo Wörld")
      assert is_binary(result)
      assert result =~ ~r/^[a-z0-9-]*$/
    end
  end

  # ============================================================================
  # valid_slug?/1
  # ============================================================================

  describe "valid_slug?/1" do
    test "accepts lowercase alphanumeric with hyphens" do
      assert Publishing.valid_slug?("hello-world")
      assert Publishing.valid_slug?("my-post-123")
      assert Publishing.valid_slug?("a")
    end

    test "rejects empty string" do
      refute Publishing.valid_slug?("")
    end

    test "rejects non-string values" do
      refute Publishing.valid_slug?(nil)
      refute Publishing.valid_slug?(123)
    end

    test "rejects uppercase" do
      refute Publishing.valid_slug?("Hello")
    end

    test "rejects special characters" do
      refute Publishing.valid_slug?("hello world")
      refute Publishing.valid_slug?("hello_world")
      refute Publishing.valid_slug?("hello.world")
    end
  end

  # ============================================================================
  # db_post?/1
  # ============================================================================

  describe "db_post?/1" do
    test "returns true when post has uuid" do
      assert Publishing.db_post?(%{uuid: "some-uuid"})
    end

    test "returns false when post has nil uuid" do
      refute Publishing.db_post?(%{uuid: nil})
    end

    test "returns false when post has no uuid key" do
      refute Publishing.db_post?(%{slug: "test"})
    end
  end

  # ============================================================================
  # extract_slug_version_and_language/2
  # ============================================================================

  describe "extract_slug_version_and_language/2" do
    test "extracts slug only" do
      assert Publishing.extract_slug_version_and_language("blog", "hello-world") ==
               {"hello-world", nil, nil}
    end

    test "extracts slug and version" do
      assert Publishing.extract_slug_version_and_language("blog", "hello-world/v2") ==
               {"hello-world", 2, nil}
    end

    test "extracts slug, version, and language" do
      assert Publishing.extract_slug_version_and_language("blog", "hello-world/v2/en") ==
               {"hello-world", 2, "en"}
    end

    test "handles nil identifier" do
      assert Publishing.extract_slug_version_and_language("blog", nil) == {"", nil, nil}
    end

    test "drops group prefix when present" do
      assert Publishing.extract_slug_version_and_language("blog", "blog/hello-world/v1/en") ==
               {"hello-world", 1, "en"}
    end

    test "handles leading slash" do
      assert Publishing.extract_slug_version_and_language("blog", "/hello-world") ==
               {"hello-world", nil, nil}
    end
  end

  # ============================================================================
  # preset_types/0
  # ============================================================================

  describe "preset_types/0" do
    test "returns a list of preset types" do
      types = Publishing.preset_types()
      assert is_list(types)
      refute Enum.empty?(types)

      # Each type should have label and value
      Enum.each(types, fn type ->
        assert Map.has_key?(type, :label) or Map.has_key?(type, "label") or
                 Map.has_key?(type, :value) or Map.has_key?(type, "value")
      end)
    end
  end
end
