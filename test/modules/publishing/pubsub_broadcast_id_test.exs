defmodule PhoenixKit.Modules.Publishing.PubSubBroadcastIdTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub

  # ============================================================================
  # broadcast_id/1
  # ============================================================================

  describe "broadcast_id/1" do
    test "returns slug when present" do
      post = %{slug: "my-post", uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      assert PublishingPubSub.broadcast_id(post) == "my-post"
    end

    test "falls back to uuid when slug is nil" do
      post = %{slug: nil, uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      assert PublishingPubSub.broadcast_id(post) == "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"
    end

    test "falls back to uuid when slug key is missing" do
      post = %{uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      assert PublishingPubSub.broadcast_id(post) == "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"
    end

    test "returns nil when both slug and uuid are nil" do
      post = %{slug: nil, uuid: nil}
      assert PublishingPubSub.broadcast_id(post) == nil
    end

    test "returns nil for nil post" do
      assert PublishingPubSub.broadcast_id(nil) == nil
    end

    test "prefers slug over uuid" do
      post = %{slug: "hello-world", uuid: "019cfcf7-0000-0000-0000-000000000000"}
      assert PublishingPubSub.broadcast_id(post) == "hello-world"
    end
  end

  # ============================================================================
  # Topic consistency
  # ============================================================================

  describe "topic consistency" do
    test "subscription and broadcast use the same topic for slug-mode posts" do
      post = %{slug: "my-post", uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      broadcast_id = PublishingPubSub.broadcast_id(post)

      # The subscription topic should match what the worker would broadcast to
      topic = PublishingPubSub.post_translations_topic("blog", broadcast_id)
      assert topic == "publishing:blog:post:my-post:translations"
    end

    test "subscription and broadcast use the same topic for timestamp-mode posts (no slug)" do
      post = %{slug: nil, uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      broadcast_id = PublishingPubSub.broadcast_id(post)

      topic = PublishingPubSub.post_translations_topic("news", broadcast_id)
      assert topic == "publishing:news:post:019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18:translations"
    end

    test "version topic uses same broadcast_id pattern" do
      post = %{slug: nil, uuid: "019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18"}
      broadcast_id = PublishingPubSub.broadcast_id(post)

      topic = PublishingPubSub.post_versions_topic("news", broadcast_id)
      assert topic == "publishing:news:post:019cfcf7-8234-7ea5-b8fb-f6d5ae74ea18:versions"
    end
  end
end
