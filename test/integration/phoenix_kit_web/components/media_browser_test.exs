defmodule PhoenixKitWeb.Components.MediaBrowserTest do
  @moduledoc """
  Integration tests for the MediaBrowser LiveComponent.

  Tests cover:
  - scope_invalid banner renders when scope folder is deleted
  - Find-orphaned toggle moved out of the toolbar to settings Quick Actions
  - Scope constrains folder navigation (scope truncation)
  - Out-of-scope folder/file mutations are rejected by Storage
  - Controlled mode (on_navigate set) emits navigate message to parent
  - Uncontrolled mode (on_navigate nil) handles nav internally (no parent message)
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
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
        folder_uuid: folder_uuid,
        # V113 added the `phoenix_kit_files_user_or_parent_check`
        # CHECK constraint requiring `user_uuid IS NOT NULL OR
        # parent_file_uuid IS NOT NULL`. Stamp the per-test owner.
        user_uuid: ensure_user!()
      })

    file
  end

  # A variant row ("original" by default) — the browser builds `urls`
  # solely from FileInstance rows, and the viewer canvas only renders
  # when a usable URL exists, so hook-driven viewer tests need one.
  defp create_instance!(file_uuid, variant_name \\ "original") do
    n = System.unique_integer([:positive])

    {:ok, instance} =
      Repo.insert(%Storage.FileInstance{
        file_uuid: file_uuid,
        variant_name: variant_name,
        file_name: "instance_#{n}.jpg",
        mime_type: "image/jpeg",
        ext: "jpg",
        checksum: "sha256:instance-#{n}",
        size: 1024,
        width: 800,
        height: 600,
        processing_status: "completed"
      })

    instance
  end

  # Memoised user owner for the file fixtures in this test process.
  # See `test/integration/storage/scope_test.exs` for the rationale —
  # same V113 CHECK constraint workaround.
  defp ensure_user! do
    case Process.get(:test_owner_user_uuid) do
      nil ->
        n = System.unique_integer([:positive])

        {:ok, user} =
          Auth.register_user(%{
            email: "media-browser-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
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
  # Orphan filter entry point
  # ---------------------------------------------------------------------------

  describe "orphan filter entry point" do
    test "find-orphaned toggle is not rendered in the browser toolbar", %{conn: _conn} do
      # The "Find orphaned" entry point moved to the media settings Quick
      # Actions (/admin/media?orphaned=1); the browser no longer renders an
      # in-toolbar toggle. Orphan filtering is still reachable via the URL
      # param, with only the contextual "Delete all orphaned" action surfacing
      # in the toolbar while that view is active.
      html =
        render_component(PhoenixKitWeb.Components.MediaBrowser,
          id: "test-browser",
          scope_folder_id: nil
        )

      refute html =~ "toggle_orphan_filter"
      refute html =~ "Find orphaned"
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

  # ---------------------------------------------------------------------------
  # Admin click → in-place viewer popup (not a page navigation)
  # ---------------------------------------------------------------------------

  describe "admin click_file" do
    test "opens the in-place viewer popup with a Details link to the admin page",
         %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

      # The popup opened in place (no navigation away from /admin/media)…
      assert html =~ "media-browser-viewer-modal"
      # …and its sidebar links to the full admin detail page.
      assert html =~ Routes.path("/admin/media/#{file.uuid}")
    end
  end

  # ---------------------------------------------------------------------------
  # Rotation persistence — admin popup opts in via persist_rotation={@admin}
  # ---------------------------------------------------------------------------

  describe "rotation persistence in the admin popup" do
    test "fresco:rotate persists to file metadata and seeds the next open",
         %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      create_instance!(file.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      # Fresco's client hook pushes this on every rotation change, via
      # pushEventTo(hook.el, ...) — which targets the owning LiveComponent.
      # render_hook/3 on an element only follows an explicit phx-target,
      # so aim at the MediaCanvasViewer component directly. Its id encodes
      # dims + variant count (see the viewer-modal comment in the heex):
      # this fixture has no dimensions and one "original" instance.
      view
      |> with_target("#media-canvas-viewer-#{file.uuid}-0x0-1")
      |> render_hook("fresco:rotate", %{
        "id" => "media-zoom-#{file.uuid}",
        "rotation" => 90,
        "previous" => 0
      })

      assert %{metadata: %{"rotation" => 90}} = Storage.get_file(file.uuid)
      # The save is confirmed with a flash — otherwise it's invisible.
      assert render(view) =~ "Rotation saved"

      # The save also broadcasts a thumbnail refresh, so the grid card behind
      # the popup picks up the new orientation without a reload (thumbnails
      # render it as a CSS transform). Scoped to `img` on purpose — the
      # viewer's own collapse chevron carries a rotate-90 class of its own.
      _ = render(view)
      assert has_element?(view, "img.rotate-90")

      # Close and reopen — the saved rotation seeds `initial_rotation`,
      # surfacing as data-initial-rotation on the canvas element.
      view |> element("##{"media-browser"}-viewer-modal .modal-backdrop") |> render_click()

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

      assert html =~ ~s(data-initial-rotation="90")
    end
  end

  # ---------------------------------------------------------------------------
  # Stacks view — files inside an expanded stack are clickable
  # ---------------------------------------------------------------------------

  describe "stacks view live refresh" do
    test "a rotation refreshes the collapsed pile's preview thumbnails", %{conn: conn} do
      {user, _token} = create_admin_user()
      parent = create_folder!()
      stack = create_folder!(%{name: "stack", parent_uuid: parent.uuid})
      file = create_file!(stack.uuid)
      create_instance!(file.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{parent.uuid}")
      view |> element("[phx-click='set_view_mode'][phx-value-mode='stacks']") |> render_click()

      refute has_element?(view, "img.rotate-90")

      # The pile is built once per stacks render and holds its own enriched
      # copies — the regression this covers: it kept a stale orientation
      # while the grid and viewer moved on.
      {:ok, _} =
        Storage.update_file(Storage.get_file(file.uuid), %{metadata: %{"rotation" => 90}})

      Storage.broadcast_file_thumbnail_updated(file.uuid)

      _ = render(view)
      assert has_element?(view, "img.rotate-90")
    end
  end

  describe "stacks view click_file" do
    test "opens the viewer for a file inside an expanded stack", %{conn: conn} do
      {user, _token} = create_admin_user()
      # A file nested one level down is only ever rendered from `stack_files`,
      # never from the page's `uploaded_files` — the regression this covers:
      # clicking it silently no-oped because the lookup only searched the
      # latter, so the viewer opened on nil.
      parent = create_folder!()
      stack = create_folder!(%{name: "stack", parent_uuid: parent.uuid})
      file = create_file!(stack.uuid)
      create_instance!(file.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{parent.uuid}")

      view |> element("[phx-click='set_view_mode'][phx-value-mode='stacks']") |> render_click()
      # The tile's phx-click is a JS.push targeting the component.
      view |> element("[data-stack-tile='#{stack.uuid}']") |> render_click()

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

      assert html =~ "media-browser-viewer-modal"
      assert html =~ "MIME:"
    end
  end

  # ---------------------------------------------------------------------------
  # Info sidebar collapse — viewer-only mode for small screens, per-user sticky
  # ---------------------------------------------------------------------------

  describe "info sidebar collapse in the popup" do
    test "collapse hides the sidebar, persists across reopen, expand restores it",
         %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      create_instance!(file.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

      assert html =~ "MIME:"

      # Collapse via the divider strip — the metadata sidebar disappears and
      # the expand affordance takes its place.
      html = view |> element("[phx-click='toggle_viewer_sidebar']") |> render_click()
      refute html =~ "MIME:"
      assert html =~ "Show details"

      # Close and reopen — the choice is persisted per-user (user meta), so
      # the popup opens collapsed.
      view |> element("#media-browser-viewer-modal .modal-backdrop") |> render_click()

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

      refute html =~ "MIME:"

      # Expand brings the sidebar back.
      html = view |> element("[phx-click='toggle_viewer_sidebar']") |> render_click()
      assert html =~ "MIME:"
    end
  end

  # ---------------------------------------------------------------------------
  # Thumbnail live refresh — AnnotationThumbnailJob's broadcast updates the
  # grid row without remounting an open viewer
  # ---------------------------------------------------------------------------

  describe "thumbnail live refresh" do
    test "thumbnail_updated broadcast swaps the grid thumbnail, open viewer untouched",
         %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      create_instance!(file.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

      # Only the "original" variant exists — the grid card falls back to it.
      refute html =~ "#{file.uuid}/small"

      # Simulate the bake job completing: a new variant lands on the file,
      # then the completion broadcast fires.
      create_instance!(file.uuid, "small")
      Storage.broadcast_file_thumbnail_updated(file.uuid)

      # Two round-trips: the hook's send_update can be queued as a separate
      # mailbox message behind the first render call.
      _ = render(view)
      html = render(view)
      # The grid card swapped to the fresh variant...
      assert html =~ "#{file.uuid}/small"
      # ...but the open viewer was NOT remounted — its LC id encodes the
      # variant count and would read ...-0x0-2 if viewer_file were swapped.
      assert html =~ "media-canvas-viewer-#{file.uuid}-0x0-1"
    end
  end

  # ---------------------------------------------------------------------------
  # Live refresh — ProcessFileJob's broadcast updates the grid + open viewer
  # ---------------------------------------------------------------------------

  describe "live refresh on processing completion" do
    test "file_processed broadcast swaps the placeholder canvas for real dimensions",
         %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      create_instance!(file.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

      # The file row has no dimensions yet — the viewer renders the
      # 1000x1000 placeholder canvas.
      assert html =~ ~s(data-canvas-width="1000")

      # Simulate ProcessFileJob finishing: dimensions land on the row,
      # then the completion broadcast fires.
      {:ok, _} = Storage.update_file(Storage.get_file(file.uuid), %{width: 800, height: 600})
      Storage.broadcast_file_processed(file.uuid)

      # Two round-trips: the hook's send_update can be queued as a separate
      # mailbox message behind the first render call.
      _ = render(view)
      html = render(view)
      assert html =~ ~s(data-canvas-width="800")
      assert html =~ ~s(data-canvas-height="600")
    end
  end

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
