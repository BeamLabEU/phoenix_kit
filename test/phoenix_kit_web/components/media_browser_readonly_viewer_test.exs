defmodule PhoenixKitWeb.Components.MediaBrowserReadonlyViewerTest do
  @moduledoc """
  Issue #840's `readonly` attr has to close three holes one level down, in
  the `MediaCanvasViewer` child the modal viewer embeds: `can_annotate`
  (Etcher shapes), `edit_target` AND `details_path` (title/alt/description
  save — MediaCanvasViewer's `save_media_details` clause only refuses the
  write when BOTH are nil, so `readonly` nils both, even with `admin: true`
  where `details_path` would otherwise stay truthy), and `persist_rotation`.

  The Edit-image button and the meta-edit form are this component's own
  markup, so they're asserted end to end through a real host LiveView.
  `can_annotate`, `persist_rotation`, and (belt-and-braces, alongside the
  end-to-end markup check) `save_media_details` are asserted with direct
  `MediaCanvasViewer.handle_event/3` calls using the exact assigns a
  readonly `MediaBrowser` hands the child — Etcher's and Fresco's own
  rendered markup belong to those packages, not to this component.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileDetails
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser
  alias PhoenixKitWeb.Components.MediaCanvasViewer

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
            email: "media-browser-readonly-viewer-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
  end

  # ---------------------------------------------------------------------------
  # edit_target — end to end through a real host, with admin: true so the
  # `details_path` gate is exercised too: under readonly the browser now nils
  # BOTH `details_path` and `edit_target`, which is what closes the viewer's
  # meta-edit form (`can_edit_media_meta?/2` is details_path OR edit_target).
  # ---------------------------------------------------------------------------

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    alias PhoenixKitWeb.Components.MediaBrowser

    defp set_assign(socket, key, value), do: Phoenix.Component.assign(socket, key, value)

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> MediaBrowser.setup_uploads()
       |> set_assign(:folder_uuid, session["folder_uuid"])
       |> set_assign(:readonly, session["readonly"])
       |> set_assign(:admin, session["admin"])}
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
        admin={@admin}
      />
      """
    end
  end

  # The viewer LiveComponent's DOM id carries the file uuid plus a suffix;
  # resolve it from the rendered page so `with_target/2` hits the real
  # component instead of a hand-built socket.
  defp viewer_cid(view, file) do
    [_, cid] = Regex.run(~r/id="(media-canvas-viewer-#{file.uuid}[^"]*)"/, render(view))
    cid
  end

  defp open_host(folder, readonly, admin) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{"folder_uuid" => folder.uuid, "readonly" => readonly, "admin" => admin}
      )

    view
  end

  describe "MediaCanvasViewer's edit_target and details_path under readonly" do
    test "Edit image is absent even with admin: true" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, true, true)

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      assert has_element?(view, "#mb-viewer-modal")
      refute has_element?(view, "[phx-click='edit_image']")
    end

    test "regression: Edit image is still offered in normal mode with admin: true" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, false, true)

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      assert has_element?(view, "[phx-click='edit_image']")
    end

    test "the meta-edit form (title/alt/description save) is absent even with admin: true" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, true, true)

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      assert has_element?(view, "#mb-viewer-modal")

      # The form lives behind the "Title & description" toggle; under
      # readonly the toggle itself must be gone, so there is no way to open
      # it. Then drive the save through the live viewer component anyway and
      # prove the row is untouched — this is the regression guard for the
      # `details_path` bypass (the viewer's own clause refuses only when
      # BOTH details_path and edit_target are nil).
      refute has_element?(view, "[phx-click='toggle_media_details']")
      refute has_element?(view, "#media-meta-form-#{file.uuid}")

      cid = viewer_cid(view, file)

      view
      |> with_target("##{cid}")
      |> render_submit("save_media_details", %{
        "title" => "hacked",
        "alt" => "h",
        "description" => "h"
      })

      details = FileDetails.from_file(Storage.get_file(file.uuid))
      refute details.title == "hacked"
      refute details.description == "h"
    end

    test "submitting the rendered form itself saves, and the form is not inside another form" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, false, true)

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      cid = viewer_cid(view, file)

      html = render(view)
      form_id = "media-meta-form-#{file.uuid}"

      # An HTML form inside a form is flattened by the browser's parser: the
      # inner one's submit would then be the outer one's.
      nested =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("form form")
        |> Enum.to_list()

      assert nested == [], "a form is nested inside another form"

      [input] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("##{form_id} input[name$='[title]']")
        |> Enum.take(1)

      [name] = LazyHTML.attribute(input, "name")

      lang =
        name |> String.replace_prefix("details[", "") |> String.replace_suffix("][title]", "")

      view
      |> form("##{form_id}", %{"details" => %{lang => %{"title" => "from the form"}}})
      |> render_submit()

      assert FileDetails.from_file(Storage.get_file(file.uuid), lang).title == "from the form"
    end

    test "normal mode with admin: true still offers the toggle, the form, and a working save" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      view = open_host(folder, false, true)

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      assert has_element?(view, "[phx-click='toggle_media_details']")

      cid = viewer_cid(view, file)

      # Open from the start: a section nobody knows to open is one nobody fills in.
      assert has_element?(view, "#media-meta-form-#{file.uuid}")

      # The chevron still folds it.
      view |> with_target("##{cid}") |> render_click("toggle_media_details", %{})
      refute has_element?(view, "#media-meta-form-#{file.uuid}")
      view |> with_target("##{cid}") |> render_click("toggle_media_details", %{})
      assert has_element?(view, "#media-meta-form-#{file.uuid}")

      view |> with_target("##{cid}") |> render_submit("save_media_details", %{"title" => "legit"})

      assert FileDetails.from_file(Storage.get_file(file.uuid)).title == "legit"
    end

    test "the EXIF panel is offered where the title editor is, and nowhere else" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      # Where the host gave the viewer a road to the metadata editor: offered.
      view = open_host(folder, false, true)

      view
      |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
      |> render_click()

      assert has_element?(view, "#media-exif-#{file.uuid}")

      # Where it did not (a public lightbox): the panel is not drawn, and the
      # events that would read or show a photo's EXIF do nothing.
      socket =
        viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{
          details_path: nil,
          edit_target: nil,
          exif_tags: nil,
          exif_status: nil,
          file_exif: nil
        })

      for event <- ["read_exif", "show_exif"] do
        assert {:noreply, ^socket} = MediaCanvasViewer.handle_event(event, %{}, socket)
      end

      assert Storage.get_file(file.uuid).metadata["exif"] == nil
    end

    test "belt-and-braces: save_media_details no-ops once both details_path and edit_target are nil" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      # The exact assign shape the readonly + admin: true `.live_component`
      # call now produces (see media_browser.html.heex) — both nil, closing
      # the gap where `details_path` alone used to be enough.
      socket =
        viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{
          details_path: nil,
          edit_target: nil
        })

      {:noreply, _socket} =
        MediaCanvasViewer.handle_event(
          "save_media_details",
          %{"title" => "hacked"},
          socket
        )

      reloaded = Storage.get_file(file.uuid)
      title = FileDetails.from_file(reloaded).title

      refute title == "hacked"
      assert title in [nil, ""]
    end
  end

  # ---------------------------------------------------------------------------
  # can_annotate / persist_rotation — direct handle_event/3 calls against the
  # exact assign shape the readonly-wired `.live_component` call produces.
  # ---------------------------------------------------------------------------

  defp viewer_socket(file, overrides) do
    base = %{
      __changed__: %{},
      id: "canvas-test",
      file: file,
      board: nil,
      can_annotate: false,
      edit_target: nil,
      persist_rotation: false,
      details_path: nil,
      write_scope: nil
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base, overrides)}
  end

  describe "MediaCanvasViewer honors can_annotate: false" do
    test "etcher:annotations-changed is refused outright — the socket comes back unchanged" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      socket = viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{})

      assert {:noreply, ^socket} =
               MediaCanvasViewer.handle_event(
                 "etcher:annotations-changed",
                 %{"annotations" => [%{"uuid" => "shape-1", "kind" => "rectangle"}]},
                 socket
               )
    end

    test "annotation_reply is refused — Reply stays on a readonly tooltip" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      socket = viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{})

      assert {:noreply, ^socket} =
               MediaCanvasViewer.handle_event(
                 "annotation_reply",
                 %{"uuid" => "shape-1"},
                 socket
               )
    end
  end

  describe "MediaCanvasViewer honors persist_rotation: false" do
    test "fresco:rotate does not persist" do
      folder = create_folder!()
      file = create_file!(folder.uuid)
      socket = viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{})

      {:noreply, _socket} =
        MediaCanvasViewer.handle_event("fresco:rotate", %{"rotation" => 90}, socket)

      reloaded = Storage.get_file(file.uuid)
      refute Map.get(reloaded.metadata || %{}, "rotation")
    end

    test "regression: fresco:rotate persists when persist_rotation is true" do
      folder = create_folder!()
      file = create_file!(folder.uuid)

      socket =
        viewer_socket(%{file_uuid: file.uuid, folder_uuid: folder.uuid}, %{
          persist_rotation: true
        })

      {:noreply, _socket} =
        MediaCanvasViewer.handle_event("fresco:rotate", %{"rotation" => 90}, socket)

      reloaded = Storage.get_file(file.uuid)
      assert Map.get(reloaded.metadata || %{}, "rotation") == 90
    end
  end
end
