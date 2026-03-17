defmodule PhoenixKit.Integration.Publishing.TranslationReloadTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  describe "read_post_by_uuid with language parameter" do
    setup do
      {:ok, group} = Groups.add_group("Translation Test", mode: "slug", slug: "translation-test")
      {:ok, post} = Posts.create_post(group["slug"], %{title: "English Title", slug: "test-post"})

      # Save the primary language content
      {:ok, saved_post} =
        Publishing.update_post(group["slug"], post, %{
          "title" => "English Title",
          "content" => "English content",
          "status" => "draft"
        })

      # Add a translation language
      {:ok, _} =
        Publishing.add_language_to_post(group["slug"], saved_post[:uuid], "uk", 1)

      # Save translated content
      {:ok, translated_post} =
        Publishing.read_post_by_uuid(saved_post[:uuid], "uk", 1)

      {:ok, _} =
        Publishing.update_post(group["slug"], translated_post, %{
          "title" => "Ukrainian Title",
          "content" => "Ukrainian content",
          "status" => "draft"
        })

      %{group: group, post_uuid: saved_post[:uuid]}
    end

    test "reading without language returns primary language content", %{post_uuid: uuid} do
      {:ok, post} = Publishing.read_post_by_uuid(uuid)
      assert post.metadata.title == "English Title"
      assert post.content == "English content"
    end

    test "reading with specific language returns that language's content", %{post_uuid: uuid} do
      {:ok, post} = Publishing.read_post_by_uuid(uuid, "uk")
      assert post.metadata.title == "Ukrainian Title"
      assert post.content == "Ukrainian content"
    end

    test "reload_translated_content should read correct language", %{post_uuid: uuid} do
      # This test verifies the pattern used in reload_translated_content:
      # re_read_post(socket, current_language) should return the translated content,
      # NOT the primary language content.
      {:ok, primary} = Publishing.read_post_by_uuid(uuid, nil)
      {:ok, translated} = Publishing.read_post_by_uuid(uuid, "uk")

      # Primary should return English
      assert primary.language == "en-US"
      assert primary.metadata.title == "English Title"

      # Translated should return Ukrainian
      assert translated.language == "uk"
      assert translated.metadata.title == "Ukrainian Title"

      # They should be different
      refute primary.content == translated.content
    end
  end
end
