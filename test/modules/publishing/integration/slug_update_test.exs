defmodule PhoenixKit.Integration.Publishing.SlugUpdateTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  describe "slug update on existing post" do
    setup do
      {:ok, group} = Groups.add_group("Slug Test", mode: "slug", slug: "slug-test")
      %{group: group}
    end

    test "can create post with explicit slug and update it", %{group: group} do
      # Create post with title and slug
      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "Original Title", slug: "original-title"})

      assert post.slug == "original-title"

      # Update to a different slug
      result =
        Publishing.update_post(group["slug"], post, %{
          "slug" => "new-slug",
          "title" => "Original Title",
          "content" => "Some content",
          "status" => "draft"
        })

      assert {:ok, updated} = result
      assert updated.slug == "new-slug"
    end

    test "can create post with auto-generated slug from title", %{group: group} do
      {:ok, post} =
        Posts.create_post(group["slug"], %{title: "My Great Post"})

      assert post.slug == "my-great-post"
    end

    test "can create post with empty title (gets untitled slug)", %{group: group} do
      {:ok, post} =
        Posts.create_post(group["slug"], %{title: ""})

      assert post.slug == "untitled"
    end

    test "can update slug from untitled to real slug", %{group: group} do
      # This simulates the bug: post created with "untitled" slug, user types title, slug changes
      {:ok, post} = Posts.create_post(group["slug"], %{title: ""})
      assert post.slug == "untitled"

      result =
        Publishing.update_post(group["slug"], post, %{
          "slug" => "hello",
          "title" => "Hello",
          "content" => "content",
          "status" => "draft"
        })

      assert {:ok, updated} = result
      assert updated.slug == "hello"
    end
  end
end
