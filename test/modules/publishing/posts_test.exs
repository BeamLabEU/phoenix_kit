defmodule PhoenixKit.Modules.Publishing.PostsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Posts

  # ============================================================================
  # db_post?/1
  # ============================================================================

  describe "db_post?/1" do
    test "returns true when post has uuid" do
      assert Posts.db_post?(%{uuid: "019cce93-ed2e-7e1b-9e62-af160709fd94"})
    end

    test "returns false when uuid is nil" do
      refute Posts.db_post?(%{uuid: nil})
    end

    test "returns false when no uuid key" do
      refute Posts.db_post?(%{slug: "test"})
    end
  end

  # ============================================================================
  # extract_slug_version_and_language/2
  # ============================================================================

  describe "extract_slug_version_and_language/2" do
    test "extracts slug only" do
      assert {"hello-world", nil, nil} =
               Posts.extract_slug_version_and_language("blog", "hello-world")
    end

    test "extracts slug and version" do
      assert {"hello-world", 2, nil} =
               Posts.extract_slug_version_and_language("blog", "hello-world/v2")
    end

    test "extracts slug, version, and language" do
      assert {"hello-world", 2, "en"} =
               Posts.extract_slug_version_and_language("blog", "hello-world/v2/en")
    end

    test "extracts slug and language without version" do
      assert {"hello-world", nil, "en"} =
               Posts.extract_slug_version_and_language("blog", "hello-world/en")
    end

    test "handles nil identifier" do
      assert {"", nil, nil} = Posts.extract_slug_version_and_language("blog", nil)
    end

    test "drops group prefix when present" do
      assert {"hello-world", 1, "en"} =
               Posts.extract_slug_version_and_language("blog", "blog/hello-world/v1/en")
    end

    test "handles leading slash" do
      assert {"hello-world", nil, nil} =
               Posts.extract_slug_version_and_language("blog", "/hello-world")
    end

    test "does not drop group prefix when it's the only element" do
      assert {"blog", nil, nil} =
               Posts.extract_slug_version_and_language("blog", "blog")
    end

    test "handles empty string identifier" do
      assert {"", nil, nil} =
               Posts.extract_slug_version_and_language("blog", "")
    end
  end

  # ============================================================================
  # Facade delegation consistency
  # ============================================================================

  describe "facade consistency" do
    test "all public functions are accessible through Publishing facade" do
      alias PhoenixKit.Modules.Publishing

      # These should all be delegated and callable (they may fail at DB level,
      # but the delegation should not raise UndefinedFunctionError)
      assert function_exported?(Publishing, :list_posts, 1)
      assert function_exported?(Publishing, :list_posts, 2)
      assert function_exported?(Publishing, :create_post, 1)
      assert function_exported?(Publishing, :create_post, 2)
      assert function_exported?(Publishing, :read_post, 2)
      assert function_exported?(Publishing, :read_post, 3)
      assert function_exported?(Publishing, :read_post, 4)
      assert function_exported?(Publishing, :read_post_by_uuid, 1)
      assert function_exported?(Publishing, :read_post_by_uuid, 2)
      assert function_exported?(Publishing, :read_post_by_uuid, 3)
      assert function_exported?(Publishing, :update_post, 3)
      assert function_exported?(Publishing, :update_post, 4)
      assert function_exported?(Publishing, :trash_post, 2)
      assert function_exported?(Publishing, :count_posts_on_date, 2)
      assert function_exported?(Publishing, :list_times_on_date, 2)
      assert function_exported?(Publishing, :find_by_url_slug, 3)
      assert function_exported?(Publishing, :find_by_previous_url_slug, 3)
      assert function_exported?(Publishing, :db_post?, 1)
      assert function_exported?(Publishing, :should_create_new_version?, 3)
      assert function_exported?(Publishing, :extract_slug_version_and_language, 2)
    end
  end
end
