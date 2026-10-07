defmodule PhoenixKitWeb.Components.MediaBrowserReadonlyTest do
  @moduledoc """
  The `:readonly` attr (default `false`, issue #840) embeds the browser for
  viewing only: every write-capable affordance — upload, rename, move,
  trash, new folder, bulk-select entry, rotate, the featured toggle, and
  the image editor — is hidden in the markup AND refused server-side (the
  markup is a courtesy, not the boundary — every blocked `handle_event`
  clause matches on `socket.assigns.readonly == true` ahead of the real
  clause, so a stray console event still no-ops). Navigation, the modal
  viewer, and downloads keep working, and a `featured` badge stays visible
  (display only) even though its kebab toggle disappears.
  """

  use PhoenixKitWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  # ---------------------------------------------------------------------------
  # Helpers (same fixtures media_browser_featured_test.exs uses)
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
        file_checksum: "sha256:test-#{n}",
        user_file_checksum: "user-sha256:test-#{n}",
        size: 1024,
        status: "active",
        folder_uuid: folder_uuid,
        user_uuid: ensure_user!()
      })

    file
  end

  defp ensure_user! do
    case Process.get(:test_owner_user_uuid) do
      nil ->
        n = System.unique_integer([:positive])

        {:ok, user} =
          Auth.register_user(%{
            email: "media-browser-readonly-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
  end

  # `render_component` mounts fresh every time, always hitting init_socket/1,
  # which unconditionally sets `:view_mode` from `load_user_view_mode/1` (a
  # per-user persisted preference) — so a `view_mode:` assign passed straight
  # to `render_component` is silently discarded. This seeds the real
  # persisted preference (same path `set_view_mode`'s handler writes through:
  # `Auth.update_user_custom_fields/3`) so the component actually mounts into
  # the requested mode.
  defp user_with_view_mode!(mode) do
    uuid = ensure_user!()
    user = Auth.get_user(uuid)

    {:ok, updated} =
      Auth.update_user_custom_fields(
        user,
        Map.put(user.custom_fields || %{}, "media_view_mode", mode),
        ensure_definitions: false
      )

    updated
  end

  # ---------------------------------------------------------------------------
  # Render — normal mode (regression, unchanged by this feature)
  # ---------------------------------------------------------------------------

  describe "render — readonly false (default)" do
    test "write affordances render as before" do
      folder = create_folder!()
      _file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid
        )

      doc = LazyHTML.from_fragment(html)

      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_upload"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_select_mode"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="open_new_folder_modal"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="prepare_move_file"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[role="menuitem"])))
    end
  end

  # ---------------------------------------------------------------------------
  # Render — readonly true
  # ---------------------------------------------------------------------------

  describe "render — readonly true" do
    test "toolbar and overflow menu hide Add Media / Select / New folder, keep Search" do
      folder = create_folder!()

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true
        )

      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_upload"])))
      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_select_mode"])))
      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="open_new_folder_modal"])))
      refute Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="toggle_search"])))
    end

    test "the stacks-view New-folder tile is hidden" do
      folder = create_folder!()
      # An empty scope hits the "Empty state" branch (heex:1230), which
      # preempts ALL THREE of the grid/stacks/list branches regardless of
      # view_mode — a file is needed so the stacks branch actually renders.
      _file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          phoenix_kit_current_user: user_with_view_mode!("stacks")
        )

      # Sanity: actually rendered in stacks mode, not just claiming to.
      assert html =~ ~s(id="pk-stacks-test-browser")
      doc = LazyHTML.from_fragment(html)
      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="open_new_folder_modal"])))
    end

    test "the upload zone card is hidden even if show_upload is forced true" do
      folder = create_folder!()

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          show_upload: true,
          parent_uploads: %{media_files: %{entries: []}}
        )

      refute html =~ "Upload Media"
    end

    test "folder kebab menu is entirely absent (grid and list)" do
      folder = create_folder!()
      _sub = create_folder!(%{parent_uuid: folder.uuid})

      html_grid =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          phoenix_kit_current_user: user_with_view_mode!("grid")
        )

      html_list =
        render_component(MediaBrowser,
          id: "test-browser-list",
          scope_folder_id: folder.uuid,
          readonly: true,
          phoenix_kit_current_user: user_with_view_mode!("list")
        )

      # Sanity: each actually rendered in the mode it claims to.
      assert html_grid =~ "data-media-grid"
      assert html_list =~ "<table"

      for html <- [html_grid, html_list] do
        doc = LazyHTML.from_fragment(html)
        assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="start_rename_folder"])))
        assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="change_folder_color"])))
        assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="prepare_move_folder"])))
        assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="delete_folder"])))
      end
    end

    test "file kebab hides Rotate / Move / Delete / Edit image, download stays reachable" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      html_grid =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          phoenix_kit_current_user: user_with_view_mode!("grid")
        )

      html_list =
        render_component(MediaBrowser,
          id: "test-browser-list",
          scope_folder_id: folder.uuid,
          readonly: true,
          phoenix_kit_current_user: user_with_view_mode!("list")
        )

      # Sanity: each actually rendered in the mode it claims to.
      assert html_grid =~ "data-media-grid"
      assert html_list =~ "<table"

      for html <- [html_grid, html_list] do
        doc = LazyHTML.from_fragment(html)

        assert Enum.empty?(
                 LazyHTML.query(
                   doc,
                   ~s(button[phx-click="rotate_file"][phx-value-file-uuid="#{file.uuid}"])
                 )
               )

        assert Enum.empty?(
                 LazyHTML.query(
                   doc,
                   ~s(button[phx-click="prepare_move_file"][phx-value-file-uuid="#{file.uuid}"])
                 )
               )

        assert Enum.empty?(
                 LazyHTML.query(
                   doc,
                   ~s(button[phx-click="delete_file"][phx-value-file-uuid="#{file.uuid}"])
                 )
               )

        assert Enum.empty?(
                 LazyHTML.query(
                   doc,
                   ~s(button[phx-click="open_image_editor"][phx-value-file-uuid="#{file.uuid}"])
                 )
               )
      end
    end

    test "the sidebar's new-folder/rename/drag affordances are hidden" do
      folder = create_folder!()
      _sub = create_folder!(%{parent_uuid: folder.uuid})

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true
        )

      refute html =~ "data-draggable-folder"
      refute html =~ "data-drop-folder"
    end

    test "drag attributes are stripped from grid/list file and folder tiles" do
      folder = create_folder!()
      _file = create_file!(folder.uuid)
      _sub = create_folder!(%{parent_uuid: folder.uuid})

      html_grid =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          phoenix_kit_current_user: user_with_view_mode!("grid")
        )

      html_list =
        render_component(MediaBrowser,
          id: "test-browser-list",
          scope_folder_id: folder.uuid,
          readonly: true,
          phoenix_kit_current_user: user_with_view_mode!("list")
        )

      # Sanity: each actually rendered in the mode it claims to.
      assert html_grid =~ "data-media-grid"
      assert html_list =~ "<table"

      for html <- [html_grid, html_list] do
        refute html =~ "data-draggable-file"
        refute html =~ "data-draggable-folder"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Featured badge stays; the toggle disappears
  # ---------------------------------------------------------------------------

  describe "readonly + featured" do
    test "the badge still renders, the Set/Unset kebab item does not" do
      folder = create_folder!()
      featured_file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          featured: %{uuid: featured_file.uuid, label: nil}
        )

      doc = LazyHTML.from_fragment(html)

      refute Enum.empty?(LazyHTML.query(doc, ~s([data-role="featured-badge"]))),
             "the badge is display-only and must survive readonly"

      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="set_featured"])))
      assert Enum.empty?(LazyHTML.query(doc, ~s(button[phx-click="unset_featured"])))
    end
  end

  # ---------------------------------------------------------------------------
  # Events — every blocked event is a no-op under readonly. Direct
  # handle_event/3 calls against a minimal socket, the style
  # media_browser_featured_test.exs and media_browser_viewer_url_test.exs use
  # — the blocked clauses only pattern-match on `socket.assigns.readonly`, so
  # no other assign needs to be primed for the guard to fire.
  # ---------------------------------------------------------------------------

  @blocked_events ~w(
    open_new_folder_modal new_folder_input submit_new_folder
    delete_folder move_file_to_folder move_folder_to_folder trash_file trash_folder
    start_rename_folder rename_folder_input rename_folder
    start_edit_folder_description folder_description_input save_folder_description
    start_edit_folder_header folder_header_input open_cover_picker open_logo_picker
    remove_folder_cover remove_folder_logo set_header_size toggle_header_option
    save_folder_header change_folder_color
    toggle_select_mode long_press_select open_image_editor toggle_select_folder
    toggle_select select_all
    show_move_modal toggle_move_folder prepare_move_file prepare_move_folder
    move_selected_to_folder delete_selected
    rotate_file delete_file set_featured unset_featured restore_selected
    empty_trash delete_all_orphaned toggle_upload show_upload
  )

  describe "every mutating handle_event is a no-op under readonly" do
    test "the socket comes back byte-for-byte unchanged, for every blocked event" do
      for event <- @blocked_events do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, id: "mb", readonly: true}
        }

        assert {:noreply, ^socket} = MediaBrowser.handle_event(event, %{}, socket),
               "expected #{event} to no-op under readonly"
      end
    end

    test "readonly: false (or absent) does not trip the guard — sanity check" do
      # A handful of representatives whose real clause needs no other setup
      # than the params it's given, confirming the new guard clauses only
      # intercept the readonly:true case and never shadow the real one.
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, id: "mb", readonly: false}}

      {:noreply, socket} =
        MediaBrowser.handle_event("new_folder_input", %{"name" => "x"}, socket)

      assert socket.assigns.new_folder_name == "x"

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, id: "mb", readonly: false, show_upload: false}
      }

      {:noreply, socket} = MediaBrowser.handle_event("toggle_upload", %{}, socket)
      assert socket.assigns.show_upload, "the real clause ran and flipped the assign"
    end
  end

  # ---------------------------------------------------------------------------
  # DB-level belt-and-braces: representative events per bucket, confirmed
  # against real fixtures that persisted state is untouched.
  # ---------------------------------------------------------------------------

  defp readonly_socket(extra \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, id: "mb", readonly: true}, extra)
    }
  end

  describe "DB is untouched by blocked events" do
    test "submit_new_folder creates no folder" do
      folder = create_folder!()
      before_count = length(Storage.list_folders(folder.uuid, nil))

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "submit_new_folder",
          %{"name" => "should-not-be-created-#{System.unique_integer([:positive])}"},
          readonly_socket()
        )

      assert length(Storage.list_folders(folder.uuid, nil)) == before_count
    end

    test "rename_folder leaves the folder's name untouched" do
      folder = create_folder!(%{name: "original-name"})

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "rename_folder",
          %{"folder_uuid" => folder.uuid, "name" => "renamed"},
          readonly_socket()
        )

      assert Storage.get_folder(folder.uuid).name == "original-name"
    end

    test "trash_file leaves the file active" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "trash_file",
          %{"file_uuid" => file.uuid},
          readonly_socket()
        )

      assert Storage.get_file(file.uuid).status == "active"
    end

    test "move_selected_to_folder leaves the file's folder untouched" do
      folder = create_folder!()
      other_folder = create_folder!()
      file = create_file!(folder.uuid)

      {:noreply, _socket} =
        MediaBrowser.handle_event(
          "move_selected_to_folder",
          %{"folder-uuid" => other_folder.uuid},
          readonly_socket()
        )

      assert Storage.get_file(file.uuid).folder_uuid == folder.uuid
    end

    test "toggle_upload never flips show_upload on" do
      socket = readonly_socket(%{show_upload: false})

      {:noreply, socket} = MediaBrowser.handle_event("toggle_upload", %{}, socket)

      refute socket.assigns.show_upload
    end
  end

  # ---------------------------------------------------------------------------
  # process_pending_upload/2 must ALSO check readonly directly — `pending_upload`
  # is broadcast (via handle_parent_info/2) to every registered MediaBrowser
  # instance on the page, not just the one whose upload input was used, so a
  # readonly browser co-located with a writable one (or any host with its own
  # live_file_input elsewhere) would otherwise get files written into its
  # scope regardless of readonly. Genuinely two-phase (see
  # drain_upload_queue/1's own comment): a first update/2 call only queues,
  # a second (action: :drain_upload_queue) moves the item into
  # :upload_processing, and a third actually invokes process_pending_upload/2.
  # ---------------------------------------------------------------------------

  describe "process_pending_upload under readonly" do
    defp upload_entry(client_name) do
      %Phoenix.LiveView.UploadEntry{
        client_name: client_name,
        client_type: "image/jpeg",
        client_size: 1024,
        client_last_modified: nil,
        client_relative_path: nil,
        progress: 100,
        upload_ref: "ref-1",
        ref: "entry-1",
        uuid: Ecto.UUID.generate(),
        valid?: true,
        done?: true,
        cancelled?: false
      }
    end

    defp write_temp_upload!(name) do
      path =
        Path.join(
          System.tmp_dir!(),
          "mb-readonly-upload-#{System.unique_integer([:positive])}-#{name}"
        )

      File.write!(path, "fake image bytes")
      path
    end

    test "a broadcast pending_upload is discarded without storing the file" do
      path = write_temp_upload!("evil.jpg")
      entry = upload_entry("evil.jpg")

      socket =
        readonly_socket(%{
          uploaded_files: [],
          last_uploaded_file_uuids: []
        })

      log =
        capture_log(fn ->
          {:ok, socket} = MediaBrowser.update(%{pending_upload: {path, entry}}, socket)
          {:ok, socket} = MediaBrowser.update(%{action: :drain_upload_queue}, socket)
          {:ok, socket} = MediaBrowser.update(%{action: :drain_upload_queue}, socket)

          refute File.exists?(path)
          assert socket.assigns.last_uploaded_file_uuids == []
        end)

      assert log =~ "process_pending_upload"
      assert log =~ "readonly"
    end

    test "regression: a non-readonly socket never takes the readonly-blocked branch" do
      path = write_temp_upload!("ok.jpg")
      entry = upload_entry("ok.jpg")

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          id: "mb",
          readonly: false,
          uploaded_files: [],
          last_uploaded_file_uuids: []
        }
      }

      log =
        capture_log(fn ->
          {:ok, socket} = MediaBrowser.update(%{pending_upload: {path, entry}}, socket)
          {:ok, socket} = MediaBrowser.update(%{action: :drain_upload_queue}, socket)
          {:ok, socket} = MediaBrowser.update(%{action: :drain_upload_queue}, socket)

          # No storage bucket is configured in this test, so the store fails.
          # A failed upload's bytes are KEPT now — named in the problems
          # panel with a Retry, where they used to be deleted along with any
          # chance of finding out which file it was — so the non-readonly
          # branch is the one that holds the file and records the problem.
          assert File.exists?(path)

          assert [%{client_name: "ok.jpg", retry: true}] =
                   MediaBrowser.upload_problems(socket.assigns)

          File.rm(path)
        end)

      # And the readonly branch is the only one that logs
      # "process_pending_upload ... readonly".
      refute log =~ "process_pending_upload"
    end
  end

  # ---------------------------------------------------------------------------
  # file_card/1 (the stacks-view per-file tile) had no `readonly` attr at all —
  # grid/list already gate the equivalent kebab items and the drag attribute.
  # ---------------------------------------------------------------------------

  describe "stacks-view file_card hides write actions under readonly" do
    test "kebab has none of the write items, and no data-draggable-file" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          readonly: true,
          phoenix_kit_current_user: user_with_view_mode!("stacks")
        )

      # Sanity: actually rendered in stacks mode.
      assert html =~ ~s(id="pk-stacks-test-browser")

      doc = LazyHTML.from_fragment(html)

      for click <-
            ~w(open_image_editor set_featured unset_featured rotate_file prepare_move_file delete_file) do
        assert Enum.empty?(
                 LazyHTML.query(
                   doc,
                   ~s(button[phx-click="#{click}"][phx-value-file-uuid="#{file.uuid}"])
                 )
               ),
               "expected #{click} to be absent from the stacks file card under readonly"
      end

      refute html =~ ~s(data-draggable-file="#{file.uuid}")
    end

    test "regression: the kebab's write items are present in normal mode" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      html =
        render_component(MediaBrowser,
          id: "test-browser",
          scope_folder_id: folder.uuid,
          phoenix_kit_current_user: user_with_view_mode!("stacks")
        )

      assert html =~ ~s(id="pk-stacks-test-browser")

      doc = LazyHTML.from_fragment(html)

      refute Enum.empty?(
               LazyHTML.query(
                 doc,
                 ~s(button[phx-click="rotate_file"][phx-value-file-uuid="#{file.uuid}"])
               )
             )

      assert html =~ ~s(data-draggable-file="#{file.uuid}")
    end
  end

  # ---------------------------------------------------------------------------
  # A handful of buttons had no `readonly` check at all — their phx-click
  # handlers were already guarded server-side (see @blocked_events above), so
  # clicking silently no-op'd, but the buttons stayed visibly present and
  # clickable. The state each needs (current_folder, filter_trash,
  # filter_orphaned) is internal render state, not a passable assign — a bare
  # render_component always starts fresh at the scope root with
  # filter_trash: false (see Fix 5's comment above) — so these are driven
  # through a real host LiveView (or, for the orphaned case, `initial_params`,
  # the same mechanism the admin media page's URL-sync uses).
  # ---------------------------------------------------------------------------

  defmodule ReadonlyHost do
    @moduledoc false
    use Phoenix.LiveView

    alias PhoenixKitWeb.Components.MediaBrowser

    defp set_assign(socket, key, value), do: Phoenix.Component.assign(socket, key, value)

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> MediaBrowser.setup_uploads()
       |> set_assign(:folder_uuid, session["folder_uuid"])
       |> set_assign(:readonly, session["readonly"])}
    end

    def handle_event("validate", _params, socket), do: {:noreply, socket}

    def handle_info({MediaBrowser, _, _} = msg, socket) do
      MediaBrowser.handle_parent_info(msg, socket)
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={MediaBrowser}
        id="mb"
        scope_folder_id={@folder_uuid}
        readonly={@readonly}
      />
      """
    end
  end

  defp open_readonly_host(folder, readonly) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), ReadonlyHost,
        session: %{"folder_uuid" => folder.uuid, "readonly" => readonly}
      )

    view
  end

  defp create_orphaned_file! do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "orphan_#{n}.jpg",
        file_name: "orphan_#{n}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "sha256:orphan-#{n}",
        user_file_checksum: "user-sha256:orphan-#{n}",
        size: 1024,
        status: "active",
        folder_uuid: nil,
        user_uuid: ensure_user!()
      })

    file
  end

  describe "readonly hides dead write buttons that were only guarded server-side" do
    test "the Edit-header trigger and the description placeholder are hidden inside a folder" do
      folder = create_folder!()
      sub = create_folder!(%{parent_uuid: folder.uuid})
      view = open_readonly_host(folder, true)

      # Scoped to the sidebar — the same folder/event also renders a second
      # `navigate_folder` button as its own grid-view tile in the main
      # content area, which makes the bare selector ambiguous.
      view
      |> element(
        "#media-browser-sidebar button[phx-click='navigate_folder'][phx-value-folder-uuid='#{sub.uuid}']"
      )
      |> render_click()

      refute render(view) =~ "start_edit_folder_header"
    end

    test "regression: both are offered in normal mode" do
      folder = create_folder!()
      sub = create_folder!(%{parent_uuid: folder.uuid})
      view = open_readonly_host(folder, false)

      view
      |> element(
        "#media-browser-sidebar button[phx-click='navigate_folder'][phx-value-folder-uuid='#{sub.uuid}']"
      )
      |> render_click()

      assert render(view) =~ "start_edit_folder_header"
    end

    test "Empty Trash is hidden in the trash view" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      {:ok, _} = Storage.trash_file(file)
      view = open_readonly_host(folder, true)

      view
      |> element("button[phx-click='toggle_trash_filter']")
      |> render_click()

      refute has_element?(view, "button[phx-click='empty_trash']")
    end

    test "regression: Empty Trash is offered in normal mode" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      {:ok, _} = Storage.trash_file(file)
      view = open_readonly_host(folder, false)

      view
      |> element("button[phx-click='toggle_trash_filter']")
      |> render_click()

      assert has_element?(view, "button[phx-click='empty_trash']")
    end

    test "Delete all orphaned is hidden at the unscoped root's orphaned view" do
      _orphan = create_orphaned_file!()

      html =
        render_component(MediaBrowser,
          id: "test-browser-orphaned",
          readonly: true,
          initial_params: %{filter_orphaned: true}
        )

      refute html =~ "delete_all_orphaned"
    end

    test "regression: Delete all orphaned is offered in normal mode" do
      _orphan = create_orphaned_file!()

      html =
        render_component(MediaBrowser,
          id: "test-browser-orphaned-normal",
          initial_params: %{filter_orphaned: true}
        )

      assert html =~ "delete_all_orphaned"
    end
  end
end
