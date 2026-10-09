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
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.MediaBrowser

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

  # ---------------------------------------------------------------------------
  # ?file= URL param: a file outside the loaded listing is fetched directly
  # ---------------------------------------------------------------------------

  describe "?file= fallback fetch" do
    # A socket past first mount whose listing is empty and already matches
    # the nav params, so update/2 goes straight to the viewer sync and the
    # file can only come from the direct-fetch fallback.
    defp viewer_socket(assigns) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(
            %{
              __changed__: %{},
              uploaded_files: [],
              stack_files: %{},
              current_folder: nil,
              search_query: "",
              current_page: 1,
              filter_orphaned: false,
              file_view: nil,
              viewer_file: nil,
              viewer_siblings: [],
              upload_in_flight: false,
              show_upload: false,
              scope_folder_id: nil,
              only_file_type: nil
            },
            assigns
          )
      }
    end

    defp open_via_url(file, socket) do
      nav = %{folder: nil, q: "", page: 1, filter_orphaned: false, view: nil, file: file}
      {:ok, socket} = MediaBrowser.update(%{nav_params: nav}, socket)
      socket.assigns.viewer_file
    end

    test "opens an in-scope file that is not in the listing" do
      scope = create_folder!()
      file = create_file!(create_folder!(%{parent_uuid: scope.uuid}).uuid)

      assert %{file_uuid: uuid} =
               open_via_url(file.uuid, viewer_socket(%{scope_folder_id: scope.uuid}))

      assert uuid == file.uuid
    end

    test "refuses a file outside the browser's scope folder" do
      scope = create_folder!()
      outside = create_file!(create_folder!().uuid)

      assert open_via_url(outside.uuid, viewer_socket(%{scope_folder_id: scope.uuid})) == nil
    end

    test "refuses a file of another type when only_file_type is set" do
      file = create_file!(create_folder!().uuid)

      assert open_via_url(file.uuid, viewer_socket(%{only_file_type: "audio"})) == nil
    end

    test "a malformed uuid leaves the viewer closed instead of raising" do
      assert open_via_url("not-a-uuid", viewer_socket(%{})) == nil
    end
  end

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

  describe "the viewer's media details" do
    setup %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      create_instance!(file.uuid)
      %{conn: log_in_user(conn, user), user: user, folder: folder, photo: file}
    end

    defp set_columns(file, set) do
      Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid), set: set)
    end

    defp open_in_viewer(ctx) do
      {:ok, view, _html} = live(ctx.conn, @media_path <> "?folder=#{ctx.folder.uuid}")

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{ctx.photo.uuid}']")
        |> render_click()

      {view, html}
    end

    test "lists who uploaded the file and its uuid, for the admin context", ctx do
      {_view, html} = open_in_viewer(ctx)

      assert html =~ "Media details"
      assert html =~ "Uploaded by:"
      assert html =~ ctx.photo.uuid
    end

    test "shows the size in pixels, and a panorama says so", ctx do
      set_columns(ctx.photo, width: 8947, height: 3317)
      {_view, html} = open_in_viewer(ctx)

      assert html =~ "8947 × 3317 px"
      assert html =~ "29.7 MP"
      assert html =~ "Panorama"
    end

    test "a photo whose EXIF was never read offers to read it", ctx do
      {view, html} = open_in_viewer(ctx)

      assert html =~ "EXIF has not been read yet."
      assert has_element?(view, ~s(#media-browser-viewer-modal button[phx-click="read_exif"]))
    end

    test "a photo with EXIF shows its camera and where it was taken", ctx do
      set_columns(ctx.photo,
        metadata: %{"exif" => %{"camera" => %{"make" => "Apple", "model" => "iPhone 17 Pro"}}},
        latitude: 45.5,
        longitude: 10.7
      )

      {view, html} = open_in_viewer(ctx)

      assert html =~ "Apple iPhone 17 Pro"
      assert html =~ "https://www.openstreetmap.org/?mlat=45.5&amp;mlon=10.7"
      assert has_element?(view, ~s(#media-browser-viewer-modal button[phx-click="show_exif"]))
    end

    test "tags are edited beside the title and saved with it", ctx do
      {view, _html} = open_in_viewer(ctx)

      view
      |> form("#media-meta-form-#{ctx.photo.uuid}", %{"tags" => "sea, boats"})
      |> render_submit()

      assert Storage.get_file(ctx.photo.uuid).metadata["tags"] == ["sea", "boats"]
      assert render(view) =~ "sea, boats"
    end

    test "offers Move to trash, and the viewer closes once the file is trashed", ctx do
      {view, html} = open_in_viewer(ctx)
      assert html =~ "Move to trash"

      view
      |> element("#media-browser-viewer-modal button[phx-click='trash_file']")
      |> render_click()

      assert Storage.get_file(ctx.photo.uuid).status == "trashed"
      refute render(view) =~ "media-browser-viewer-modal"
    end

    test "a trashed file offers Restore and Delete forever instead", ctx do
      {:ok, _} = Storage.trash_file(ctx.photo)
      {:ok, view, _html} = live(ctx.conn, @media_path <> "?folder=#{ctx.folder.uuid}")
      view |> element("[phx-click='toggle_trash_filter']") |> render_click()

      html =
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{ctx.photo.uuid}']")
        |> render_click()

      assert html =~ "In the trash"
      assert html =~ "Delete forever"
      refute html =~ "Move to trash"

      view
      |> element("#media-browser-viewer-modal button[phx-click='restore_file']")
      |> render_click()

      assert Storage.get_file(ctx.photo.uuid).status == "active"
      refute render(view) =~ "media-browser-viewer-modal"
    end
  end

  # ---------------------------------------------------------------------------
  # Rotation persistence — the popup opts in unconditionally (any user who can
  # open and rotate a file saves its shared orientation). Exercised via the
  # admin route since that's the only in-suite MediaBrowser host.
  # ---------------------------------------------------------------------------

  describe "rotation persistence in the popup" do
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
      # dims + variant count + the original's version (see
      # `MediaBrowser.viewer_component_id/1`): this fixture has no dimensions
      # and one "original" instance.
      view
      |> with_target("[id^='media-canvas-viewer-#{file.uuid}-0x0-1-']")
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
  # Per-file kebab rotate — saves the rotation like the viewer's rotate button
  # ---------------------------------------------------------------------------

  describe "kebab rotate" do
    test "Rotate right/left steps the file's saved rotation by ±90", %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      create_instance!(file.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")

      right =
        "[phx-click='rotate_file'][phx-value-file-uuid='#{file.uuid}'][phx-value-dir='right']"

      left = "[phx-click='rotate_file'][phx-value-file-uuid='#{file.uuid}'][phx-value-dir='left']"

      view |> element(right) |> render_click()
      assert %{metadata: %{"rotation" => 90}} = Storage.get_file(file.uuid)

      view |> element(left) |> render_click()
      assert %{metadata: %{"rotation" => 0}} = Storage.get_file(file.uuid)

      # Left from 0 wraps to 270 (the other direction).
      view |> element(left) |> render_click()
      assert %{metadata: %{"rotation" => 270}} = Storage.get_file(file.uuid)
    end
  end

  # ---------------------------------------------------------------------------
  # Image editor — opened from a file's menu or the viewer
  # ---------------------------------------------------------------------------

  describe "image editor" do
    setup %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      create_instance!(file.uuid)
      %{conn: log_in_user(conn, user), folder: folder, photo: file}
    end

    defp edit_item(file),
      do: "[phx-click='open_image_editor'][phx-value-file-uuid='#{file.uuid}']"

    test "opens from the file's menu, over the browser, and closes", ctx do
      {:ok, view, _html} = live(ctx.conn, @media_path <> "?folder=#{ctx.folder.uuid}")

      html = view |> element(edit_item(ctx.photo)) |> render_click()
      assert html =~ "media-browser-image-editor-modal"
      assert html =~ ~s(id="media-browser-image-editor-#{ctx.photo.uuid}-form")

      html =
        view |> element("#media-browser-image-editor-modal .modal-backdrop") |> render_click()

      refute html =~ "media-browser-image-editor-modal"

      # Esc closes it too.
      view |> element(edit_item(ctx.photo)) |> render_click()

      html =
        view
        |> element("#media-browser-image-editor-modal")
        |> render_keydown(%{"key" => "Escape"})

      refute html =~ "media-browser-image-editor-modal"
    end

    test "is not offered for an image it cannot write back, or in the trash", ctx do
      gif = create_file!(ctx.folder.uuid)
      {:ok, gif} = gif |> Ecto.Changeset.change(mime_type: "image/gif") |> Repo.update()
      create_instance!(gif.uuid)

      {:ok, view, _html} = live(ctx.conn, @media_path <> "?folder=#{ctx.folder.uuid}")

      assert has_element?(view, edit_item(ctx.photo))
      refute has_element?(view, edit_item(gif))
    end

    test "opens from the viewer's sidebar, closing the viewer", ctx do
      {:ok, view, _html} = live(ctx.conn, @media_path <> "?folder=#{ctx.folder.uuid}")

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{ctx.photo.uuid}']")
      |> render_click()

      view |> element("[phx-click='edit_image']") |> render_click()
      html = render(view)

      assert html =~ "media-browser-image-editor-modal"
      refute html =~ "media-browser-viewer-modal"
    end

    test "is told when the file has been processed", ctx do
      {:ok, view, _html} = live(ctx.conn, @media_path <> "?folder=#{ctx.folder.uuid}")
      view |> element(edit_item(ctx.photo)) |> render_click()

      Repo.update_all(
        from(f in StorageFile, where: f.uuid == ^ctx.photo.uuid),
        set: [edit_state: "failed", edits: %{"rotate" => 90}]
      )

      send(view.pid, {:phoenix_kit_file_processed, ctx.photo.uuid})

      # It travels as two send_updates (the browser, then the editor), each
      # queued behind the render that follows it: the third render sees both.
      _ = render(view)
      _ = render(view)
      assert render(view) =~ "The edit could not be applied."
    end
  end

  # ---------------------------------------------------------------------------
  # Select mode — Esc exits it like the toolbar Cancel
  # ---------------------------------------------------------------------------

  describe "select mode" do
    test "Escape exits select mode and clears the selection", %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      _file = create_file!(folder.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")

      # Enter select mode via the overflow menu's Select (the only
      # toggle_select_mode control rendered while not selecting).
      html = view |> element("[phx-click='toggle_select_mode']") |> render_click()
      assert html =~ ~s(phx-click="select_all")

      # Esc exits — the window-keydown is attached only while selecting.
      html = view |> element("#media-browser") |> render_keydown(%{"key" => "Escape"})
      refute html =~ ~s(phx-click="select_all")
    end

    test "a maintenance broadcast does not crash an admin's LiveView", %{conn: conn} do
      # Regression: the maintenance on_mount hook returned {:cont, _} for an
      # admin scope, handing {:maintenance_status_changed, _} to the LV's own
      # handle_info — which has no clause for it, so any admin with the page
      # open died in FunctionClauseError whenever a maintenance toggle
      # broadcast (or the hook's own end-of-window timer) fired. The hook now
      # halts: for an admin the message is fully handled.
      {user, _token} = create_admin_user()
      folder = create_folder!()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")

      send(view.pid, {:maintenance_status_changed, %{active: false}})

      assert render(view) =~ "media-browser"
    end
  end

  # ---------------------------------------------------------------------------
  # Trash is scoped to the folder you're in — not other roots' trash
  # ---------------------------------------------------------------------------

  describe "trash view scoping" do
    test "opening trash inside a folder shows only that folder's trash", %{conn: conn} do
      {user, _token} = create_admin_user()
      r1 = create_folder!(%{name: "root_one"})
      r2 = create_folder!(%{name: "root_two"})
      here = create_file!(r1.uuid)
      elsewhere = create_file!(r2.uuid)
      {:ok, _} = Storage.trash_file(here)
      {:ok, _} = Storage.trash_file(elsewhere)
      conn = log_in_user(conn, user)

      # Land inside r1, then open Trash. Before the fix the browser passed a
      # nil scope, so trash showed every root's trashed files.
      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{r1.uuid}")
      html = view |> element("[phx-click='toggle_trash_filter']") |> render_click()

      assert html =~ here.uuid
      refute html =~ elsewhere.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # A trashed file's own thumbnail must stay reachable for whoever can view
  # the Trash tab (issue #841 part 3) — `enrich_files/1` builds it through the
  # very `/file/:uuid/:variant/:token` route `FileController.show/2` now
  # gates on `status: "trashed"`.
  # ---------------------------------------------------------------------------

  describe "trash view thumbnail servability" do
    test "a trashed file's signed thumbnail route is still authorized for its viewer",
         %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      create_instance!(file.uuid, "thumbnail")
      {:ok, file} = Storage.trash_file(file)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")
      html = view |> element("[phx-click='toggle_trash_filter']") |> render_click()
      assert html =~ file.uuid

      # A deliberately wrong token distinguishes "authorized here, rejected
      # downstream for an unrelated reason" (401 Invalid token) from "blocked
      # by the trashed-file gate itself" (404) — proving the route is
      # reachable without needing real bucket bytes for a literal 200.
      real_url = URLSigner.signed_url(file.uuid, "thumbnail")
      bogus_url = String.replace(real_url, ~r/[0-9a-f]+\z/, "deadbeef")

      assert get(conn, bogus_url).status == 401

      # Regression: the same URL, unauthenticated, is still blocked entirely
      # — trashing the file did not accidentally open it to anyone.
      assert get(build_conn(), bogus_url).status == 404
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
      # the expand affordance takes its place. Targeted via the seam
      # toggle's own attribute: the corner toggle (`lg:hidden`, for mobile)
      # answers the same phx-click and renders alongside it, so the bare
      # selector matches two buttons.
      html = view |> element("[data-sidebar-seam-toggle]") |> render_click()
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

  # ---------------------------------------------------------------------------
  # Trash live refresh — Storage.trash_file/restore_file/delete_file_completely
  # broadcast so an open browser reacts instead of keeping a stale card
  # (issue #841)
  # ---------------------------------------------------------------------------

  describe "trash live refresh" do
    test "file_trashed broadcast drops the card from the active view and closes the viewer",
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

      assert html =~ "media-browser-viewer-modal"
      assert html =~ file.uuid

      {:ok, _} = Storage.trash_file(file)

      # Two round-trips: the hook's send_update can be queued as a separate
      # mailbox message behind the first render call.
      _ = render(view)
      html = render(view)

      refute html =~ file.uuid
      refute html =~ "media-browser-viewer-modal"
    end

    test "file_restored broadcast drops the card from an open trash view",
         %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      {:ok, file} = Storage.trash_file(file)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")
      html = view |> element("[phx-click='toggle_trash_filter']") |> render_click()

      assert html =~ file.uuid

      {:ok, _} = Storage.restore_file(file)

      _ = render(view)
      html = render(view)

      refute html =~ file.uuid
    end

    test "file_deleted broadcast drops the card everywhere and closes the viewer",
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

      assert html =~ "media-browser-viewer-modal"
      assert html =~ file.uuid

      {:ok, _} = Storage.delete_file_completely(file)

      _ = render(view)
      html = render(view)

      refute html =~ file.uuid
      refute html =~ "media-browser-viewer-modal"
    end

    # A folder operation announces its files in ONE bulk message; the
    # browser drops them all in one update rather than one per file.
    test "a folder trashed elsewhere drops every one of its cards", %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file_a = create_file!(folder.uuid)
      file_b = create_file!(folder.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, @media_path <> "?folder=#{folder.uuid}")
      assert html =~ file_a.uuid and html =~ file_b.uuid

      {:ok, _} = Storage.trash_folder(folder)

      _ = render(view)
      html = render(view)

      refute html =~ file_a.uuid
      refute html =~ file_b.uuid
    end

    test "a file removed elsewhere leaves the bulk selection too", %{conn: conn} do
      {user, _token} = create_admin_user()
      folder = create_folder!()
      file = create_file!(folder.uuid)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, @media_path <> "?folder=#{folder.uuid}")
      view |> element("[phx-click='toggle_select_mode']") |> render_click()

      html =
        view
        |> element("[phx-click='toggle_select'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

      assert html =~ "1 selected"

      {:ok, _} = Storage.trash_file(file)

      _ = render(view)
      html = render(view)

      # The counter (and "N item(s) deleted") counted a file no longer shown.
      refute html =~ "1 selected"
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
