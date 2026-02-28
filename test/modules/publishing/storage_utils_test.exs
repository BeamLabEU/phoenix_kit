defmodule PhoenixKit.Modules.Publishing.StorageUtilsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Storage

  # ============================================================================
  # content_changed?/2
  # ============================================================================

  describe "content_changed?/2" do
    test "detects content change" do
      post = %{content: "old content", metadata: %{title: "Title"}}
      params = %{"content" => "new content"}

      assert Storage.content_changed?(post, params)
    end

    test "detects title change" do
      post = %{content: "same content", metadata: %{title: "Old Title"}}
      params = %{"title" => "New Title"}

      assert Storage.content_changed?(post, params)
    end

    test "returns false when nothing changed" do
      post = %{content: "same content", metadata: %{title: "Same Title"}}
      params = %{"content" => "same content", "title" => "Same Title"}

      refute Storage.content_changed?(post, params)
    end

    test "ignores whitespace differences" do
      post = %{content: "  content  ", metadata: %{title: "  Title  "}}
      params = %{"content" => "content", "title" => "Title"}

      refute Storage.content_changed?(post, params)
    end

    test "handles nil content" do
      post = %{content: nil, metadata: %{title: "Title"}}
      params = %{}

      refute Storage.content_changed?(post, params)
    end
  end

  # ============================================================================
  # status_change_only?/2
  # ============================================================================

  describe "status_change_only?/2" do
    test "returns true when only status changed" do
      post = %{
        content: "content",
        metadata: %{title: "Title", status: "draft", featured_image_uuid: nil}
      }

      params = %{"status" => "published", "content" => "content", "title" => "Title"}

      assert Storage.status_change_only?(post, params)
    end

    test "returns false when content also changed" do
      post = %{
        content: "old content",
        metadata: %{title: "Title", status: "draft", featured_image_uuid: nil}
      }

      params = %{"status" => "published", "content" => "new content"}

      refute Storage.status_change_only?(post, params)
    end

    test "returns false when status unchanged" do
      post = %{
        content: "content",
        metadata: %{title: "Title", status: "draft", featured_image_uuid: nil}
      }

      params = %{"status" => "draft"}

      refute Storage.status_change_only?(post, params)
    end

    test "returns false when featured image also changed" do
      post = %{
        content: "content",
        metadata: %{title: "Title", status: "draft", featured_image_uuid: nil}
      }

      params = %{"status" => "published", "featured_image_uuid" => "img-123"}

      refute Storage.status_change_only?(post, params)
    end
  end

  # ============================================================================
  # should_create_new_version?/3
  # ============================================================================

  describe "should_create_new_version?/3" do
    test "always returns false (auto-versioning disabled)" do
      post = %{content: "old", metadata: %{title: "Old", status: "published"}}
      params = %{"content" => "new", "title" => "New"}

      refute Storage.should_create_new_version?(post, params, "en")
    end
  end
end
