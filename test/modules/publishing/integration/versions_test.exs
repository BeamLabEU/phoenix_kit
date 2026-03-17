defmodule PhoenixKit.Integration.Publishing.VersionsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Publishing.Groups
  alias PhoenixKit.Modules.Publishing.Posts
  alias PhoenixKit.Modules.Publishing.Versions

  defp unique_name, do: "Versions Group #{System.unique_integer([:positive])}"

  defp create_group_and_post(opts \\ []) do
    mode = Keyword.get(opts, :mode, "slug")
    title = Keyword.get(opts, :title, "Versioned Post")

    {:ok, group} = Groups.add_group(unique_name(), mode: mode)
    {:ok, post} = Posts.create_post(group["slug"], %{title: title})

    {group, post}
  end

  # ============================================================================
  # list_versions/2
  # ============================================================================

  describe "list_versions/2" do
    test "new post has version 1" do
      {group, post} = create_group_and_post()
      versions = Versions.list_versions(group["slug"], post[:slug] || post[:uuid])
      assert versions == [1]
    end

    test "multiple versions are listed in order" do
      {group, post} = create_group_and_post()
      {:ok, v2} = Versions.create_new_version(group["slug"], post, %{}, %{})
      {:ok, _v3} = Versions.create_new_version(group["slug"], v2, %{}, %{})

      versions = Versions.list_versions(group["slug"], post[:slug] || post[:uuid])
      assert versions == [1, 2, 3]
    end
  end

  # ============================================================================
  # create_new_version/4
  # ============================================================================

  describe "create_new_version/4" do
    test "creates version 2 by cloning latest" do
      {group, post} = create_group_and_post()
      {:ok, new_post} = Versions.create_new_version(group["slug"], post, %{}, %{})

      assert new_post[:version] == 2
      assert 1 in new_post[:available_versions]
      assert 2 in new_post[:available_versions]
    end

    test "clones content from source version" do
      {group, post} = create_group_and_post(title: "Clone Me")
      {:ok, v2_post} = Versions.create_new_version(group["slug"], post, %{}, %{})
      assert v2_post[:metadata][:title] == "Clone Me"
    end

    test "creates successive versions" do
      {group, post} = create_group_and_post()
      {:ok, v2} = Versions.create_new_version(group["slug"], post, %{}, %{})
      {:ok, v3} = Versions.create_new_version(group["slug"], v2, %{}, %{})

      assert v3[:version] == 3
      versions = Versions.list_versions(group["slug"], post[:slug] || post[:uuid])
      assert versions == [1, 2, 3]
    end

    test "new version starts as draft" do
      {group, post} = create_group_and_post(title: "Publish V1")
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      {:ok, v2} = Versions.create_new_version(group["slug"], post, %{}, %{})
      assert v2[:metadata][:status] == "draft"
    end

    test "clones all languages from source version" do
      {group, post} = create_group_and_post(title: "Multilang")

      alias PhoenixKit.Modules.Publishing.TranslationManager
      {:ok, _} = TranslationManager.add_language_to_post(group["slug"], post[:uuid], "de", nil)

      {:ok, v2} = Versions.create_new_version(group["slug"], post, %{}, %{})

      # V2 should have both en and de
      {:ok, v2_post} = Posts.read_post(group["slug"], post[:uuid], nil, 2)
      v2_langs = v2_post[:available_languages]
      assert "en" in v2_langs
      assert "de" in v2_langs
    end

    test "returns post map with available_versions updated" do
      {group, post} = create_group_and_post()
      {:ok, v2} = Versions.create_new_version(group["slug"], post, %{}, %{})

      assert is_list(v2[:available_versions])
      assert length(v2[:available_versions]) == 2
    end
  end

  # ============================================================================
  # publish_version/4
  # ============================================================================

  describe "publish_version/4" do
    test "publishes a version with title" do
      {group, post} = create_group_and_post(title: "Publish Me")
      assert :ok = Versions.publish_version(group["slug"], post[:uuid], 1)
    end

    test "published version status is published" do
      {group, post} = create_group_and_post(title: "Check Published")
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      status =
        Versions.get_version_status(group["slug"], post[:slug] || post[:uuid], 1, "en")

      assert status == "published"
    end

    test "archives previously published version" do
      {group, post} = create_group_and_post(title: "V1 Title")
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      {:ok, v2} = Versions.create_new_version(group["slug"], post, %{}, %{})
      Posts.update_post(group["slug"], v2, %{"title" => "V2 Title"}, %{})
      :ok = Versions.publish_version(group["slug"], post[:uuid], 2)

      v1_status =
        Versions.get_version_status(group["slug"], post[:slug] || post[:uuid], 1, "en")

      assert v1_status == "archived"
    end

    test "only one version published at a time" do
      {group, post} = create_group_and_post(title: "Multi V")
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      {:ok, v2} = Versions.create_new_version(group["slug"], post, %{}, %{})
      Posts.update_post(group["slug"], v2, %{"title" => "V2"}, %{})
      :ok = Versions.publish_version(group["slug"], post[:uuid], 2)

      v1 = Versions.get_version_status(group["slug"], post[:slug] || post[:uuid], 1, "en")
      v2_status = Versions.get_version_status(group["slug"], post[:slug] || post[:uuid], 2, "en")

      assert v1 == "archived"
      assert v2_status == "published"
    end

    test "rejects publishing version without title" do
      {:ok, group} = Groups.add_group(unique_name(), mode: "slug")
      {:ok, post} = Posts.create_post(group["slug"], %{})

      assert {:error, :title_required} =
               Versions.publish_version(group["slug"], post[:uuid], 1)
    end

    test "rejects publishing trashed post" do
      {group, post} = create_group_and_post(title: "Trashed")
      {:ok, _} = Posts.trash_post(group["slug"], post[:uuid])

      assert {:error, :post_trashed} =
               Versions.publish_version(group["slug"], post[:uuid], 1)
    end

    test "rejects publishing nonexistent version" do
      {group, post} = create_group_and_post(title: "Missing V")

      assert {:error, :version_not_found} =
               Versions.publish_version(group["slug"], post[:uuid], 99)
    end
  end

  # ============================================================================
  # get_published_version/2
  # ============================================================================

  describe "get_published_version/2" do
    test "returns published version number" do
      {group, post} = create_group_and_post(title: "Published V")
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      assert {:ok, 1} =
               Versions.get_published_version(group["slug"], post[:slug] || post[:uuid])
    end

    test "returns error when no version is published" do
      {group, post} = create_group_and_post(title: "No Pub")

      result = Versions.get_published_version(group["slug"], post[:slug] || post[:uuid])
      assert match?({:error, _}, result)
    end
  end

  # ============================================================================
  # get_version_status/4
  # ============================================================================

  describe "get_version_status/4" do
    test "returns draft for new version" do
      {group, post} = create_group_and_post()

      status =
        Versions.get_version_status(group["slug"], post[:slug] || post[:uuid], 1, "en")

      assert status == "draft"
    end

    test "returns published after publishing" do
      {group, post} = create_group_and_post(title: "Pub Status")
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      status =
        Versions.get_version_status(group["slug"], post[:slug] || post[:uuid], 1, "en")

      assert status == "published"
    end
  end

  # ============================================================================
  # delete_version/3
  # ============================================================================

  describe "delete_version/3" do
    test "archives a draft version" do
      {group, post} = create_group_and_post()
      {:ok, _v2} = Versions.create_new_version(group["slug"], post, %{}, %{})
      assert :ok = Versions.delete_version(group["slug"], post[:uuid], 1)
    end

    test "cannot delete published version" do
      {group, post} = create_group_and_post(title: "Published")
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      assert {:error, :cannot_delete_live} =
               Versions.delete_version(group["slug"], post[:uuid], 1)
    end

    test "cannot delete last remaining version" do
      {group, post} = create_group_and_post()

      assert {:error, :last_version} =
               Versions.delete_version(group["slug"], post[:uuid], 1)
    end

    test "cannot delete nonexistent version" do
      {group, post} = create_group_and_post()

      result = Versions.delete_version(group["slug"], post[:uuid], 99)
      assert match?({:error, _}, result)
    end

    test "deleted version is archived, not hard-deleted" do
      {group, post} = create_group_and_post()
      {:ok, _v2} = Versions.create_new_version(group["slug"], post, %{}, %{})
      :ok = Versions.delete_version(group["slug"], post[:uuid], 1)

      # Version still exists in the list
      versions = Versions.list_versions(group["slug"], post[:slug] || post[:uuid])
      assert 1 in versions
    end
  end

  # ============================================================================
  # Full version workflow
  # ============================================================================

  describe "full version workflow" do
    test "create → publish v1 → create v2 → edit v2 → publish v2 → v1 archived" do
      {group, post} = create_group_and_post(title: "V1 Content")

      # Publish v1 first
      :ok = Versions.publish_version(group["slug"], post[:uuid], 1)

      # Create v2
      {:ok, v2} = Versions.create_new_version(group["slug"], post, %{}, %{})
      assert v2[:version] == 2
      assert v2[:metadata][:title] == "V1 Content"

      # Edit v2
      {:ok, _} = Posts.update_post(group["slug"], v2, %{"title" => "V2 Content"}, %{})

      # Publish v2
      :ok = Versions.publish_version(group["slug"], post[:uuid], 2)

      # V1 should now be archived (was published, got superseded)
      v1_status =
        Versions.get_version_status(group["slug"], post[:slug] || post[:uuid], 1, "en")

      assert v1_status == "archived"

      # V2 should be published
      v2_status =
        Versions.get_version_status(group["slug"], post[:slug] || post[:uuid], 2, "en")

      assert v2_status == "published"

      # Reading without version gives v2 (latest)
      {:ok, latest} = Posts.read_post(group["slug"], post[:uuid], nil, nil)
      assert latest[:version] == 2
    end
  end
end
