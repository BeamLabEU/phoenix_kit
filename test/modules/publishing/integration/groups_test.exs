defmodule PhoenixKit.Integration.Publishing.GroupsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts

  defp unique_name, do: "Test Group #{System.unique_integer([:positive])}"

  # ============================================================================
  # add_group/2
  # ============================================================================

  describe "add_group/2" do
    test "creates group with defaults (timestamp mode, blog type)" do
      {:ok, group} = Groups.add_group(unique_name())

      assert group["slug"]
      assert group["mode"] == "timestamp"
      assert group["status"] == "active"
      assert group["type"] == "blog"
      assert group["item_singular"] == "post"
      assert group["item_plural"] == "posts"
    end

    test "creates slug-mode group" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      assert group["mode"] == "slug"
    end

    test "creates faq type group" do
      {:ok, group} = Groups.add_group(unique_name(), type: "faq")
      assert group["item_singular"] == "question"
      assert group["item_plural"] == "questions"
    end

    test "creates legal type group" do
      {:ok, group} = Groups.add_group(unique_name(), type: "legal")
      assert group["item_singular"] == "document"
      assert group["item_plural"] == "documents"
    end

    test "creates group with custom slug" do
      slug = "custom-slug-#{System.unique_integer([:positive])}"
      {:ok, group} = Groups.add_group(unique_name(), slug: slug)
      assert group["slug"] == slug
    end

    test "creates group with custom item names" do
      {:ok, group} =
        Groups.add_group(unique_name(), item_singular: "recipe", item_plural: "recipes")

      assert group["item_singular"] == "recipe"
      assert group["item_plural"] == "recipes"
    end

    test "creates group with all options combined" do
      {:ok, group} =
        Groups.add_group(unique_name(),
          mode: "slug",
          type: "faq",
          item_singular: "entry",
          item_plural: "entries"
        )

      assert group["mode"] == "slug"
      assert group["item_singular"] == "entry"
      assert group["item_plural"] == "entries"
    end

    test "auto-generates unique slug for duplicate names" do
      name = unique_name()
      {:ok, first} = Groups.add_group(name)
      {:ok, second} = Groups.add_group(name)
      assert first["slug"] != second["slug"]
    end

    test "rejects empty name" do
      assert {:error, :invalid_name} = Groups.add_group("")
    end

    test "rejects whitespace-only name" do
      assert {:error, :invalid_name} = Groups.add_group("   ")
    end

    test "invalid mode falls back to default" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "invalid")
      assert group["mode"] == "timestamp"
    end

    test "normalizes mode case" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "SLUG")
      assert group["mode"] == "slug"
    end

    test "auto-generates slug from name" do
      {:ok, group} = Groups.add_group("My Great Blog")
      assert group["slug"] =~ "my-great-blog"
    end

    test "map opts work same as keyword opts" do
      {:ok, group} = Groups.add_group(unique_name(), %{mode: "slug", type: "faq"})
      assert group["mode"] == "slug"
    end
  end

  # ============================================================================
  # get_group/1
  # ============================================================================

  describe "get_group/1" do
    test "returns group by slug" do
      {:ok, created} = Groups.add_group(unique_name())
      assert {:ok, found} = Groups.get_group(created["slug"])
      assert found["slug"] == created["slug"]
      assert found["name"] == created["name"]
    end

    test "returns all data fields" do
      {:ok, created} = Groups.add_group(unique_name(), type: "faq", mode: "slug")
      {:ok, found} = Groups.get_group(created["slug"])

      assert found["mode"] == "slug"
      assert found["status"] == "active"
      assert found["item_singular"] == "question"
    end

    test "returns trashed group (get_group finds any status)" do
      {:ok, group} = Groups.add_group(unique_name())
      {:ok, _} = Groups.trash_group(group["slug"])
      {:ok, found} = Groups.get_group(group["slug"])
      assert found["status"] == "trashed"
    end

    test "returns error for nonexistent slug" do
      assert {:error, :not_found} = Groups.get_group("nonexistent-slug")
    end
  end

  # ============================================================================
  # list_groups/0 and list_groups/1
  # ============================================================================

  describe "list_groups/0 and list_groups/1" do
    test "lists active groups" do
      {:ok, group} = Groups.add_group(unique_name())
      groups = Groups.list_groups()
      slugs = Enum.map(groups, & &1["slug"])
      assert group["slug"] in slugs
    end

    test "excludes trashed groups from default listing" do
      {:ok, group} = Groups.add_group(unique_name())
      {:ok, _} = Groups.trash_group(group["slug"])
      groups = Groups.list_groups()
      slugs = Enum.map(groups, & &1["slug"])
      refute group["slug"] in slugs
    end

    test "lists trashed groups when filtered" do
      {:ok, group} = Groups.add_group(unique_name())
      {:ok, _} = Groups.trash_group(group["slug"])
      trashed = Groups.list_groups("trashed")
      slugs = Enum.map(trashed, & &1["slug"])
      assert group["slug"] in slugs
    end

    test "returns maps with expected keys" do
      {:ok, _} = Groups.add_group(unique_name())
      [group | _] = Groups.list_groups()

      assert Map.has_key?(group, "slug")
      assert Map.has_key?(group, "name")
      assert Map.has_key?(group, "mode")
      assert Map.has_key?(group, "status")
    end
  end

  # ============================================================================
  # update_group/2
  # ============================================================================

  describe "update_group/2" do
    test "updates group name" do
      {:ok, group} = Groups.add_group(unique_name())
      new_name = unique_name()
      {:ok, updated} = Groups.update_group(group["slug"], %{name: new_name})
      assert updated["name"] == new_name
    end

    test "updates group slug" do
      {:ok, group} = Groups.add_group(unique_name())
      new_slug = "updated-slug-#{System.unique_integer([:positive])}"
      {:ok, updated} = Groups.update_group(group["slug"], %{slug: new_slug})
      assert updated["slug"] == new_slug
      assert {:error, :not_found} = Groups.get_group(group["slug"])
    end

    test "preserves unchanged fields on partial update" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, updated} = Groups.update_group(group["slug"], %{name: "New Name"})
      assert updated["mode"] == "slug"
      assert updated["slug"] == group["slug"]
    end

    test "rejects empty name update" do
      {:ok, group} = Groups.add_group(unique_name())
      assert {:error, :invalid_name} = Groups.update_group(group["slug"], %{name: ""})
    end

    test "returns error for nonexistent group" do
      assert {:error, :not_found} = Groups.update_group("nonexistent", %{name: "New"})
    end
  end

  # ============================================================================
  # trash_group/1 and restore_group/1
  # ============================================================================

  describe "trash and restore lifecycle" do
    test "trash_group/1 soft-deletes group" do
      {:ok, group} = Groups.add_group(unique_name())
      assert {:ok, _slug} = Groups.trash_group(group["slug"])
      {:ok, found} = Groups.get_group(group["slug"])
      assert found["status"] == "trashed"
    end

    test "restore_group/1 restores trashed group" do
      {:ok, group} = Groups.add_group(unique_name())
      {:ok, _} = Groups.trash_group(group["slug"])
      assert {:ok, _slug} = Groups.restore_group(group["slug"])
      {:ok, found} = Groups.get_group(group["slug"])
      assert found["status"] == "active"
    end

    test "trashed group not in default listing, restored group is" do
      {:ok, group} = Groups.add_group(unique_name())
      slug = group["slug"]

      {:ok, _} = Groups.trash_group(slug)
      refute slug in Enum.map(Groups.list_groups(), & &1["slug"])

      {:ok, _} = Groups.restore_group(slug)
      assert slug in Enum.map(Groups.list_groups(), & &1["slug"])
    end
  end

  # ============================================================================
  # remove_group/2
  # ============================================================================

  describe "remove_group/2" do
    test "hard-deletes empty group" do
      {:ok, group} = Groups.add_group(unique_name())
      assert {:ok, _} = Groups.remove_group(group["slug"])
      assert {:error, :not_found} = Groups.get_group(group["slug"])
    end

    test "refuses to delete group with posts unless forced" do
      {:ok, group} = Groups.add_group(unique_name())
      {:ok, _post} = Posts.create_post(group["slug"], %{})
      assert {:error, {:has_posts, count}} = Groups.remove_group(group["slug"])
      assert count >= 1
    end

    test "force-deletes group with posts" do
      {:ok, group} = Groups.add_group(unique_name())
      {:ok, _post} = Posts.create_post(group["slug"], %{})
      assert {:ok, _} = Groups.remove_group(group["slug"], force: true)
      assert {:error, :not_found} = Groups.get_group(group["slug"])
    end

    test "force-delete cascades to all posts and versions" do
      {:ok, group} = Groups.add_group(unique_name())
      {:ok, post} = Posts.create_post(group["slug"], %{title: "Will Be Deleted"})
      {:ok, _} = Groups.remove_group(group["slug"], force: true)

      # Post should be gone
      assert {:error, _} = Posts.read_post(group["slug"], post[:uuid], nil, nil)
    end

    test "can remove trashed group" do
      {:ok, group} = Groups.add_group(unique_name())
      {:ok, _} = Groups.trash_group(group["slug"])
      assert {:ok, _} = Groups.remove_group(group["slug"])
      assert {:error, :not_found} = Groups.get_group(group["slug"])
    end
  end

  # ============================================================================
  # group_name/1 and get_group_mode/1
  # ============================================================================

  describe "group_name/1" do
    test "returns group name by slug" do
      {:ok, group} = Groups.add_group(unique_name())
      assert Groups.group_name(group["slug"]) == group["name"]
    end

    test "returns nil for nonexistent slug" do
      assert Groups.group_name("nonexistent") == nil
    end
  end

  describe "get_group_mode/1" do
    test "returns timestamp for timestamp-mode group" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "timestamp")
      assert Groups.get_group_mode(group["slug"]) == "timestamp"
    end

    test "returns slug for slug-mode group" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      assert Groups.get_group_mode(group["slug"]) == "slug"
    end
  end

  # ============================================================================
  # preset_types/0 and valid_types/0
  # ============================================================================

  describe "preset_types/0" do
    test "returns list of type definitions with required fields" do
      types = Groups.preset_types()
      assert length(types) >= 3

      for type <- types do
        assert Map.has_key?(type, :type)
        assert Map.has_key?(type, :label)
        assert Map.has_key?(type, :item_singular)
        assert Map.has_key?(type, :item_plural)
      end
    end
  end

  describe "valid_types/0" do
    test "includes all preset types" do
      valid = Groups.valid_types()
      assert "blog" in valid
      assert "faq" in valid
      assert "legal" in valid
    end
  end
end
