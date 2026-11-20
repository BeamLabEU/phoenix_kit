defmodule PhoenixKitWeb.Components.MediaBrowserMarkIntegrationTest do
  @moduledoc """
  The `:mark` attr end to end, through a tiny host LiveView — what
  `media_browser_mark_test.exs` cannot reach without a database: real files
  in the listing, the viewer sidebar's toggle, and the gates that sit in front
  of every event naming a uuid (the library and `viewer_uuid` ones).
  """

  use PhoenixKitWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  defp create_folder! do
    {:ok, folder} = Storage.create_folder(%{name: "folder_#{System.unique_integer([:positive])}"})
    folder
  end

  defp create_user! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        email: "media-browser-mark-test-#{n}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp create_file!(folder_uuid, user_uuid, attrs \\ []) do
    n = System.unique_integer([:positive])

    base = %StorageFile{
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
      user_uuid: user_uuid
    }

    {:ok, file} = base |> struct(attrs) |> Repo.insert()
    file
  end

  defp create_pdf!(folder_uuid, user_uuid) do
    create_file!(folder_uuid, user_uuid,
      original_file_name: "doc.pdf",
      file_name: "doc.pdf",
      mime_type: "application/pdf",
      file_type: "document",
      ext: "pdf"
    )
  end

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
       |> set_assign(:mark, session["mark"])
       |> set_assign(:viewer_uuid, session["viewer_uuid"])
       |> set_assign(:current_user, session["current_user"])
       |> set_assign(:test_pid, session["test_pid"])}
    end

    def handle_event("validate", _params, socket), do: {:noreply, socket}

    # Before the generic delegator — see MediaBrowser's moduledoc note on `:mark`.
    def handle_info({MediaBrowser, _id, {:set_mark, uuid, on?}}, socket) do
      send(socket.assigns.test_pid, {:set_mark_received, uuid, on?})
      {:noreply, socket}
    end

    def handle_info({MediaBrowser, _, _} = msg, socket) do
      MediaBrowser.handle_parent_info(msg, socket)
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={MediaBrowser}
        id="mb"
        scope_folder_id={@folder_uuid}
        mark={@mark}
        viewer_uuid={@viewer_uuid}
        phoenix_kit_current_user={@current_user}
      />
      """
    end
  end

  defp open_host(folder, mark, opts \\ []) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{
          "folder_uuid" => folder.uuid,
          "mark" => mark,
          "viewer_uuid" => opts[:viewer_uuid],
          "current_user" => nil,
          "test_pid" => self()
        }
      )

    view
  end

  defp mark_map(uuids), do: %{uuids: uuids, icon: "hero-flag", on_label: "Yes", off_label: "No"}

  describe "tile toggle" do
    test "a click marks, the next click unmarks, on an image and on a PDF; the host hears both" do
      folder = create_folder!()
      user = create_user!()
      image = create_file!(folder.uuid, user.uuid)
      pdf = create_pdf!(folder.uuid, user.uuid)
      view = open_host(folder, mark_map([]))

      for file <- [image, pdf] do
        view
        |> element(~s(button[data-role="mark-off"][data-mark-file="#{file.uuid}"]))
        |> render_click()

        assert_receive {:set_mark_received, uuid, true}
        assert uuid == file.uuid
        assert has_element?(view, ~s(button[data-role="mark-on"][data-mark-file="#{file.uuid}"]))

        view
        |> element(~s(button[data-role="mark-on"][data-mark-file="#{file.uuid}"]))
        |> render_click()

        assert_receive {:set_mark_received, uuid, false}
        assert uuid == file.uuid
        assert has_element?(view, ~s(button[data-role="mark-off"][data-mark-file="#{file.uuid}"]))
      end
    end

    test "off by default: no control, and the event is refused with nothing sent" do
      folder = create_folder!()
      file = create_file!(folder.uuid, create_user!().uuid)
      view = open_host(folder, nil)

      refute has_element?(view, ~s([data-role^="mark-"]))

      capture_log(fn ->
        view |> with_target("#mb") |> render_click("toggle_mark", %{"file-uuid" => file.uuid})
      end)

      refute_receive {:set_mark_received, _, _}
    end

    test "a file the browser does not show is refused, whatever uuid a console sends" do
      folder = create_folder!()
      other_folder = create_folder!()
      user = create_user!()
      _shown = create_file!(folder.uuid, user.uuid)
      elsewhere = create_file!(other_folder.uuid, user.uuid)
      view = open_host(folder, mark_map([]))

      capture_log(fn ->
        view
        |> with_target("#mb")
        |> render_click("toggle_mark", %{"file-uuid" => elsewhere.uuid})
      end)

      refute_receive {:set_mark_received, _, _}
    end

    test "a restricted viewer cannot mark a file someone else uploaded" do
      folder = create_folder!()
      viewer = create_user!()
      other = create_user!()
      theirs = create_file!(folder.uuid, other.uuid)
      mine = create_file!(folder.uuid, viewer.uuid)
      view = open_host(folder, mark_map([]), viewer_uuid: viewer.uuid)

      capture_log(fn ->
        view |> with_target("#mb") |> render_click("toggle_mark", %{"file-uuid" => theirs.uuid})
      end)

      refute_receive {:set_mark_received, _, _}

      view |> with_target("#mb") |> render_click("toggle_mark", %{"file-uuid" => mine.uuid})
      assert_receive {:set_mark_received, uuid, true}
      assert uuid == mine.uuid
    end
  end

  describe "viewer sidebar toggle" do
    defp open_viewer(view, file),
      do:
        view
        |> element("[phx-click='click_file'][phx-value-file-uuid='#{file.uuid}']")
        |> render_click()

    test "a PDF's sidebar carries the toggle, and a click notifies the host" do
      folder = create_folder!()
      pdf = create_pdf!(folder.uuid, create_user!().uuid)
      view = open_host(folder, mark_map([]))

      open_viewer(view, pdf)

      view
      |> element("#mb-viewer-modal button[data-mark-file='#{pdf.uuid}'][phx-click='toggle_mark']")
      |> render_click()

      assert_receive {:set_mark_received, uuid, true}
      assert uuid == pdf.uuid
    end

    test "a trashed file is not offered the toggle" do
      folder = create_folder!()
      user = create_user!()

      file =
        create_file!(folder.uuid, user.uuid,
          status: "trashed",
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      view = open_host(folder, mark_map([]))

      view |> element("[phx-click='toggle_trash_filter']") |> render_click()
      open_viewer(view, file)

      assert has_element?(view, "#mb-viewer-modal")
      refute has_element?(view, "#mb-viewer-modal [phx-click='toggle_mark']")
    end

    test "not offered when the host never opted in" do
      folder = create_folder!()
      pdf = create_pdf!(folder.uuid, create_user!().uuid)
      view = open_host(folder, nil)

      open_viewer(view, pdf)

      refute has_element?(view, "[phx-click='toggle_mark']")
    end
  end
end
