defmodule PhoenixKitWeb.Components.MediaBrowserTest do
  @moduledoc """
  Integration tests for the MediaBrowser LiveComponent.

  Tests cover:
  - scope_invalid banner renders when scope folder is deleted
  - Orphan filter button hidden when scope_folder_id is set
  - Scope constrains folder navigation (scope truncation)
  - Out-of-scope folder/file mutations are rejected by Storage
  - Controlled mode (on_navigate set) emits navigate message to parent
  - Uncontrolled mode (on_navigate nil) handles nav internally (no parent message)
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Utils.Routes

  @media_path Routes.path("/admin/media")

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_folder!(attrs \\ %{}) do
    name = Map.get(attrs, :name, "folder_#{System.unique_integer([:positive])}")
    {:ok, folder} = Storage.create_folder(Map.put(attrs, :name, name))
    folder
  end

  defp create_file!(folder_uuid) do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "file_#{n}.jpg",
        file_name: "file_#{n}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        # `file_checksum`/`user_file_checksum` are `NOT NULL` in V95.
        file_checksum: "sha256:test-#{n}",
        user_file_checksum: "user-sha256:test-#{n}",
        size: 1024,
        status: "active",
        folder_uuid: folder_uuid
      })

    file
  end

  defp fake_uuid do
    "00000000-0000-7000-8000-#{System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(12, "0")}"
  end

  defp flatten_tree_uuids(nodes) do
    Enum.flat_map(nodes, fn %{folder: folder, children: children} ->
      [folder.uuid | flatten_tree_uuids(children)]
    end)
  end

  # ---------------------------------------------------------------------------
  # scope_invalid banner rendering
  # ---------------------------------------------------------------------------

  describe "scope_invalid banner" do
    test "shows alert-warning when scope_folder_id points to nonexistent folder", %{conn: _conn} do
      deleted_uuid = fake_uuid()

      html =
        render_component(PhoenixKitWeb.Components.MediaBrowser,
          id: "test-browser",
          scope_folder_id: deleted_uuid
        )

      assert html =~ "alert-warning"
      assert html =~ "scope folder no longer exists"
    end

    test "does not show scope_invalid banner when scope_folder_id is nil", %{conn: _conn} do
      html =
        render_component(PhoenixKitWeb.Components.MediaBrowser,
          id: "test-browser",
          scope_folder_id: nil
        )

      refute html =~ "alert-warning"
      refute html =~ "scope folder no longer exists"
    end

    test "does not show scope_invalid banner when scope folder exists", %{conn: _conn} do
      scope = create_folder!()

      html =
        render_component(PhoenixKitWeb.Components.MediaBrowser,
          id: "test-browser",
          scope_folder_id: scope.uuid
        )

      refute html =~ "scope folder no longer exists"
    end
  end

  # ---------------------------------------------------------------------------
  # Orphan filter visibility under scope
  # ---------------------------------------------------------------------------

  describe "orphan filter visibility" do
    test "orphan filter button visible when no scope", %{conn: _conn} do
      html =
        render_component(PhoenixKitWeb.Components.MediaBrowser,
          id: "test-browser",
          scope_folder_id: nil
        )

      assert html =~ "toggle_orphan_filter"
    end

    test "orphan filter button hidden when scope_folder_id is set", %{conn: _conn} do
      scope = create_folder!()

      html =
        render_component(PhoenixKitWeb.Components.MediaBrowser,
          id: "test-browser",
          scope_folder_id: scope.uuid
        )

      refute html =~ "toggle_orphan_filter"
    end
  end

  # ---------------------------------------------------------------------------
  # Scope truncation — Storage-level: list_folders respects scope boundary
  # These mirror what init_socket/apply_nav_params call internally
  # ---------------------------------------------------------------------------

  describe "scope truncation (folder tree)" do
    test "list_folders with scope returns only direct children of scope root" do
      scope = create_folder!()
      child = create_folder!(%{name: "child", parent_uuid: scope.uuid})
      _sibling = create_folder!(%{name: "sibling"})

      folders = Storage.list_folders(nil, scope.uuid)
      uuids = Enum.map(folders, & &1.uuid)

      assert child.uuid in uuids
      # siblings outside scope are not returned
      refute scope.uuid in uuids
    end

    test "list_folders with scope nil returns real root folders" do
      root_folder = create_folder!()
      _child = create_folder!(%{name: "child", parent_uuid: root_folder.uuid})

      folders = Storage.list_folders(nil, nil)
      uuids = Enum.map(folders, & &1.uuid)

      assert root_folder.uuid in uuids
    end

    test "list_folder_tree with scope returns flattened subtree" do
      # `list_folder_tree/1` returns nested tree nodes shaped as
      # `%{folder: %Folder{}, children: [%{folder: ..., children: ...}, ...]}`
      # — see `build_tree_nodes/2` in `lib/modules/storage/storage.ex:880`.
      # Flatten via DFS and project to UUIDs to assert membership.
      scope = create_folder!()
      child = create_folder!(%{name: "child", parent_uuid: scope.uuid})
      grandchild = create_folder!(%{name: "grandchild", parent_uuid: child.uuid})
      _outside = create_folder!()

      tree = Storage.list_folder_tree(scope.uuid)
      uuids = flatten_tree_uuids(tree)

      assert child.uuid in uuids
      assert grandchild.uuid in uuids
      refute scope.uuid in uuids
    end
  end

  # ---------------------------------------------------------------------------
  # Out-of-scope folder mutations (Storage-level validations)
  # These correspond to the component's event handlers for "new_folder",
  # "delete_folder", "rename_folder" etc.
  # ---------------------------------------------------------------------------

  describe "out-of-scope mutations rejected" do
    test "create_folder outside scope returns :out_of_scope" do
      scope = create_folder!()
      outside = create_folder!()

      assert {:error, :out_of_scope} =
               Storage.create_folder(%{name: "bad", parent_uuid: outside.uuid}, scope.uuid)
    end

    test "delete_folder outside scope returns :out_of_scope" do
      scope = create_folder!()
      outside = create_folder!()

      assert {:error, :out_of_scope} = Storage.delete_folder(outside, scope.uuid)
    end

    test "update_folder outside scope returns :out_of_scope" do
      scope = create_folder!()
      outside = create_folder!()

      assert {:error, :out_of_scope} =
               Storage.update_folder(outside, %{name: "renamed"}, scope.uuid)
    end

    test "move_file_to_folder with out-of-scope target returns :out_of_scope" do
      scope = create_folder!()
      child = create_folder!(%{name: "child", parent_uuid: scope.uuid})
      outside = create_folder!()
      file = create_file!(child.uuid)

      assert {:error, :out_of_scope} =
               Storage.move_file_to_folder(file.uuid, outside.uuid, scope.uuid)
    end

    test "move_file_to_folder with nil target (real root) when scope set returns :out_of_scope" do
      scope = create_folder!()
      child = create_folder!(%{name: "child", parent_uuid: scope.uuid})
      file = create_file!(child.uuid)

      assert {:error, :out_of_scope} =
               Storage.move_file_to_folder(file.uuid, nil, scope.uuid)
    end
  end

  # ---------------------------------------------------------------------------
  # Controlled mode — navigate events reach parent LiveView
  # Tested via the /admin/media route (which uses on_navigate: true)
  # ---------------------------------------------------------------------------

  describe "controlled mode (on_navigate: true)" do
    test "navigate event from component is handled by parent and triggers push_patch",
         %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path)

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: folder.uuid, q: "", page: 1, filter_orphaned: false}}}
      )

      assert_patch(view, @media_path <> "?folder=#{folder.uuid}")
    end

    test "navigate event with search term triggers push_patch with q param", %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path)

      send(
        view.pid,
        {PhoenixKitWeb.Components.MediaBrowser, "media-browser",
         {:navigate, %{folder: nil, q: "photo", page: 1, filter_orphaned: false}}}
      )

      assert_patch(view, @media_path <> "?q=photo")
    end
  end

  # ---------------------------------------------------------------------------
  # Uncontrolled mode — component handles nav internally, no parent message
  # Verified by confirming render_component (one-shot init) has correct state
  # ---------------------------------------------------------------------------

  describe "uncontrolled mode (on_navigate: nil)" do
    test "component renders successfully without on_navigate assign", %{conn: _conn} do
      html =
        render_component(PhoenixKitWeb.Components.MediaBrowser,
          id: "test-browser",
          on_navigate: nil
        )

      # Should render the browser body (no scope_invalid, no error)
      assert html =~ "test-browser"
      refute html =~ "scope folder no longer exists"
    end

    test "component renders successfully with on_navigate: true", %{conn: _conn} do
      html =
        render_component(PhoenixKitWeb.Components.MediaBrowser,
          id: "test-browser",
          on_navigate: true
        )

      assert html =~ "test-browser"
      refute html =~ "scope folder no longer exists"
    end
  end
end
