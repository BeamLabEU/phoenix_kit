defmodule PhoenixKit.Modules.Publishing.PubSubTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub

  # ============================================================================
  # Topic Generation
  # ============================================================================

  describe "topic generation" do
    test "groups_topic returns consistent topic" do
      assert PublishingPubSub.groups_topic() == "publishing:groups"
    end

    test "posts_topic includes blog slug" do
      assert PublishingPubSub.posts_topic("blog") == "publishing:blog:posts"
      assert PublishingPubSub.posts_topic("faq") == "publishing:faq:posts"
    end

    test "post_versions_topic includes blog and post slugs" do
      topic = PublishingPubSub.post_versions_topic("blog", "hello-world")
      assert topic == "publishing:blog:post:hello-world:versions"
    end

    test "post_translations_topic includes blog and post slugs" do
      topic = PublishingPubSub.post_translations_topic("blog", "hello-world")
      assert topic == "publishing:blog:post:hello-world:translations"
    end

    test "editor_form_topic includes form key" do
      topic = PublishingPubSub.editor_form_topic("blog:hello-world:en")
      assert topic == "publishing:editor_forms:blog:hello-world:en"
    end

    test "editor_presence_topic includes form key" do
      topic = PublishingPubSub.editor_presence_topic("blog:hello-world:en")
      assert topic == "publishing:presence:editor:blog:hello-world:en"
    end

    test "cache_topic includes blog slug" do
      assert PublishingPubSub.cache_topic("blog") == "publishing:blog:cache"
    end

    test "group_editors_topic includes group slug" do
      assert PublishingPubSub.group_editors_topic("blog") == "publishing:blog:editors"
    end

    test "bulk_operation_topic includes blog slug" do
      assert PublishingPubSub.bulk_operation_topic("blog") == "publishing:blog:bulk_operations"
    end
  end

  # ============================================================================
  # DB Import Broadcast Functions
  # ============================================================================

  describe "DB import broadcast functions" do
    test "broadcast_db_import_started/2 is defined" do
      assert function_exported?(PublishingPubSub, :broadcast_db_import_started, 2)
    end

    test "broadcast_db_import_completed/3 is defined" do
      assert function_exported?(PublishingPubSub, :broadcast_db_import_completed, 3)
    end

    test "broadcast_db_migration_started/1 is defined" do
      assert function_exported?(PublishingPubSub, :broadcast_db_migration_started, 1)
    end

    test "broadcast_db_migration_group_progress/3 is defined" do
      assert function_exported?(PublishingPubSub, :broadcast_db_migration_group_progress, 3)
    end

    test "broadcast_db_migration_completed/1 is defined" do
      assert function_exported?(PublishingPubSub, :broadcast_db_migration_completed, 1)
    end
  end

  # ============================================================================
  # Form Key Generation
  # ============================================================================

  describe "generate_form_key/3" do
    test "generates key from uuid and language" do
      key = PublishingPubSub.generate_form_key("blog", %{uuid: "abc-123", language: "en"}, :edit)
      assert key == "blog:abc-123:en"
    end

    test "generates key from slug and language" do
      key =
        PublishingPubSub.generate_form_key(
          "blog",
          %{slug: "hello-world", language: "en"},
          :edit
        )

      assert key == "blog:hello-world:en"
    end

    test "generates key for new post mode" do
      key = PublishingPubSub.generate_form_key("blog", %{language: "en"}, :new)
      assert key == "blog:new:en"
    end

    test "generates fallback key for new mode without language" do
      key = PublishingPubSub.generate_form_key("blog", %{}, :new)
      assert key == "blog:new"
    end
  end
end
