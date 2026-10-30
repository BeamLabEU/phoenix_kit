defmodule PhoenixKitWeb.Components.MediaBrowserPickerViewerTest do
  @moduledoc """
  The viewer of a picker (`picker`): a tile's eye opens `MediaCanvasViewer`
  on the file without touching the pick, the viewer steps through the page
  loaded in the open folder, and its Select / Deselect button changes the
  pick under the same server check a click has. The viewer writes nothing to
  the file (rotation, annotations, title and description are refused as under
  `readonly`), but Move to trash is offered — also with `folder_actions:
  false` — and a file removed that way leaves the pick. Escape closes the
  viewer only. Inside a host modal the viewer is lifted into the browser's
  top layer (`popover`), so the modal's transformed box cannot clip it.
  """

  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  @buckets_cache :phoenix_kit_buckets_cache

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView
    import Plug.Conn, only: []
    import PhoenixKitWeb.Components.Core.Modal

    alias PhoenixKitWeb.Components.MediaBrowser

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> assign(:phoenix_kit_current_user, session["user"])
       |> MediaBrowser.setup_uploads()
       |> assign(
         test_pid: session["test_pid"],
         scope: session["scope"],
         opts: session["opts"] || %{},
         in_modal?: session["in_modal"] || false,
         plain?: session["plain"] || false
       )}
    end

    def render(assigns) do
      ~H"""
      <div>
        <%= if @plain? do %>
          <.live_component
            module={MediaBrowser}
            id="files"
            scope_folder_id={@scope}
            parent_uploads={@uploads}
            phoenix_kit_current_user={@phoenix_kit_current_user}
          />
        <% else %>
          <%= if @in_modal? do %>
            <.modal id="slot-modal" show on_close="close_picker" max_width="7xl">
              <.picker {assigns} />
            </.modal>
          <% else %>
            <.picker {assigns} />
          <% end %>
        <% end %>
      </div>
      """
    end

    defp picker(assigns) do
      ~H"""
      <.live_component
        module={MediaBrowser}
        id="pick"
        picker
        pick_mode={Map.get(@opts, :pick_mode, :multiple)}
        max_select={@opts[:max_select]}
        folder_actions={Map.get(@opts, :folder_actions, true)}
        readonly={Map.get(@opts, :readonly, false)}
        scope_folder_id={@scope}
        parent_uploads={@uploads}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />
      """
    end

    def handle_event("close_picker", _params, socket) do
      send(socket.assigns.test_pid, :host_modal_closed)
      {:noreply, socket}
    end

    def handle_info({MediaBrowser, id, {:picked, uuids}}, socket) do
      send(socket.assigns.test_pid, {:picked, id, uuids})
      {:noreply, socket}
    end

    def handle_info({MediaBrowser, id, :pick_cancelled}, socket) do
      send(socket.assigns.test_pid, {:cancelled, id})
      {:noreply, socket}
    end

    def handle_info({MediaBrowser, _id, {:picker_uploading, _}}, socket), do: {:noreply, socket}

    def handle_info({MediaBrowser, _, _} = msg, socket),
      do: MediaBrowser.handle_parent_info(msg, socket)

    def handle_info(_msg, socket), do: {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_picker_viewer_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "picker-viewer-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    {:ok, user} =
      Auth.register_user(%{
        email: "picker-viewer-#{n}@example.com",
        password: "ValidPassword123!"
      })

    Process.put(:owner_uuid, user.uuid)
    %{user: user, scope: folder!("Order")}
  end

  defp folder!(name, parent \\ nil) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: "#{name}-#{System.unique_integer([:positive])}",
        parent_uuid: parent && parent.uuid
      })

    folder
  end

  defp file!(folder, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %StorageFile{
          original_file_name: "kitchen-#{n}.png",
          file_name: "kitchen-#{n}.png",
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          file_checksum: "picker-viewer-#{n}",
          user_file_checksum: "picker-viewer-u-#{n}",
          size: 1,
          status: "active",
          folder_uuid: folder && folder.uuid,
          user_uuid: Process.get(:owner_uuid)
        },
        attrs
      )
    )
  end

  # Files listed newest first: `ago` seconds old each, so their order on the
  # page is fixed.
  defp files_in_order!(folder, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    for i <- 1..count, do: file!(folder, %{inserted_at: DateTime.add(now, -i * 60)})
  end

  defp open(conn, ctx, session \\ %{}) do
    {:ok, view, _html} =
      live_isolated(conn, Host,
        session:
          Map.merge(
            %{"test_pid" => self(), "scope" => ctx.scope.uuid, "user" => ctx.user},
            session
          )
      )

    view
  end

  defp click_file(view, file) do
    view
    |> element(~s(#pick [phx-click="click_file"][phx-value-file-uuid="#{file.uuid}"]))
    |> render_click()
  end

  defp eye(view, file) do
    view
    |> element(~s(#pick button[phx-click="view_file"][phx-value-file-uuid="#{file.uuid}"]))
    |> render_click()
  end

  defp viewer_open_on?(view, file),
    do: has_element?(view, ~s(#pick-viewer-modal [id^="media-canvas-viewer-#{file.uuid}-"]))

  defp viewer_pick_button(view),
    do: element(view, ~s(#pick-viewer-modal button[phx-click="viewer_pick"]))

  defp step(view, dir) do
    view
    |> element(~s(#pick-viewer-modal button[phx-click="step_viewer"][phx-value-dir="#{dir}"]))
    |> render_click()
  end

  defp hook(view, event, params), do: view |> element("#pick") |> render_hook(event, params)

  defp confirm(view) do
    view |> element(~s(#pick button[phx-click="pick_confirm"])) |> render_click()
    assert_receive {:picked, "pick", uuids}
    uuids
  end

  # The viewer's own component (MediaCanvasViewer), as an event from its
  # canvas or its sidebar reaches it (the burn hook's element targets it).
  defp viewer_hook(view, file, event, params) do
    view
    |> element("#pk-burn-#{file.uuid}")
    |> render_hook(event, params)
  end

  # ---------------------------------------------------------------------------
  # The eye
  # ---------------------------------------------------------------------------

  describe "the eye" do
    test "opens the viewer on the file and leaves the pick as it was", %{conn: conn} = ctx do
      [a, b] = files_in_order!(ctx.scope, 2)
      view = open(conn, ctx)

      click_file(view, a)
      eye(view, b)
      assert viewer_open_on?(view, b)

      # On a picked file too: still picked, once.
      eye(view, a)
      assert viewer_open_on?(view, a)
      assert has_element?(view, ~s(#pick [data-pick-order="1"] [phx-value-file-uuid="#{a.uuid}"]))

      view |> element(~s(#pick-viewer-modal button[phx-click="close_viewer"])) |> render_click()
      refute has_element?(view, "#pick-viewer-modal")

      assert confirm(view) == [a.uuid]
    end

    test "sits beside the tile's click target, so it does not pick", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)

      refute has_element?(
               view,
               ~s(#pick [phx-click="click_file"] button[phx-click="view_file"])
             )

      eye(view, a)
      assert confirm(view) == []
    end

    test "a browser that is not a picker has no eye, and refuses one (a click opens its viewer)",
         %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"plain" => true})

      refute has_element?(view, ~s(#files button[phx-click="view_file"]))

      capture_log(fn ->
        view |> element("#files") |> render_hook("view_file", %{"file-uuid" => a.uuid})
      end)

      refute has_element?(view, "#files-viewer-modal")
    end

    # The eye is the picker's only way into the viewer: a touch screen has no
    # hover to reveal it.
    test "stays visible on a touch screen", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)

      assert has_element?(
               view,
               ~s(#pick button[phx-click="view_file"][phx-value-file-uuid="#{a.uuid}"][class*="pointer-coarse:opacity-100"])
             )
    end

    test "a file that is not on the page opens nothing", %{conn: conn} = ctx do
      elsewhere = file!(folder!("Elsewhere"))
      view = open(conn, ctx)

      hook(view, "view_file", %{"file-uuid" => elsewhere.uuid})
      refute has_element?(view, "#pick-viewer-modal")
    end
  end

  describe "stepping" do
    test "goes through the page loaded in the open folder, and no further",
         %{conn: conn} = ctx do
      [a, b, c] = files_in_order!(ctx.scope, 3)
      sub = folder!("Kitchen", ctx.scope)
      _not_on_the_page = file!(sub)
      view = open(conn, ctx)

      eye(view, a)
      step(view, "next")
      assert viewer_open_on?(view, b)
      step(view, "next")
      assert viewer_open_on?(view, c)
      refute has_element?(view, ~s(#pick-viewer-modal button[phx-value-dir="next"]))

      step(view, "prev")
      assert viewer_open_on?(view, b)
      assert confirm(view) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Picking in the viewer
  # ---------------------------------------------------------------------------

  describe "Select / Deselect in the viewer" do
    test "multiple: Select adds the file shown, Deselect takes it out", %{conn: conn} = ctx do
      [a, b] = files_in_order!(ctx.scope, 2)
      view = open(conn, ctx)

      click_file(view, a)
      eye(view, b)
      assert render(viewer_pick_button(view)) =~ "Select"

      viewer_pick_button(view) |> render_click()
      assert has_element?(view, ~s(#pick [data-pick-order="2"] [phx-value-file-uuid="#{b.uuid}"]))
      assert render(viewer_pick_button(view)) =~ "Deselect"
      assert viewer_open_on?(view, b), "picking in the viewer keeps it open"

      viewer_pick_button(view) |> render_click()
      assert render(viewer_pick_button(view)) =~ "Select"
      assert confirm(view) == [a.uuid]
    end

    test "the button follows the file shown as the viewer steps", %{conn: conn} = ctx do
      [a, b] = files_in_order!(ctx.scope, 2)
      view = open(conn, ctx)

      click_file(view, a)
      eye(view, a)
      assert render(viewer_pick_button(view)) =~ "Deselect"

      step(view, "next")
      assert viewer_open_on?(view, b)
      refute render(viewer_pick_button(view)) =~ "Deselect"
    end

    test "single: Select replaces the pick, Deselect empties it", %{conn: conn} = ctx do
      [a, b] = files_in_order!(ctx.scope, 2)
      view = open(conn, ctx, %{"opts" => %{pick_mode: :single}})

      click_file(view, a)
      eye(view, b)
      viewer_pick_button(view) |> render_click()
      assert confirm(view) == [b.uuid]

      eye(view, b)
      viewer_pick_button(view) |> render_click()
      assert confirm(view) == []
    end

    test "multiple at max_select: Select is disabled and says why; a forged one is refused",
         %{conn: conn} = ctx do
      [a, b] = files_in_order!(ctx.scope, 2)
      view = open(conn, ctx, %{"opts" => %{max_select: 1}})

      click_file(view, a)
      eye(view, b)

      assert has_element?(view, ~s(#pick-viewer-modal button[phx-click="viewer_pick"][disabled]))
      assert render(element(view, "#pick-viewer-modal")) =~ "Maximum 1 files"

      hook(view, "viewer_pick", %{"file-uuid" => b.uuid})
      assert confirm(view) == [a.uuid]

      # Deselect stays possible at the limit.
      eye(view, a)
      refute has_element?(view, ~s(#pick-viewer-modal button[phx-click="viewer_pick"][disabled]))
      viewer_pick_button(view) |> render_click()
      assert confirm(view) == []
    end

    test "is checked on the server like a click", %{conn: conn} = ctx do
      outside = file!(folder!("Elsewhere"))
      trashed = file!(ctx.scope, %{status: "trashed"})
      view = open(conn, ctx)

      capture_log(fn ->
        for uuid <- [outside.uuid, trashed.uuid, "not-a-uuid"] do
          hook(view, "viewer_pick", %{"file-uuid" => uuid})
        end
      end)

      assert confirm(view) == []
    end

    test "a browser that is not a picker ignores it", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"plain" => true})

      view |> element("#files") |> render_hook("viewer_pick", %{"file-uuid" => a.uuid})

      view
      |> element(~s(#files [phx-click="click_file"][phx-value-file-uuid="#{a.uuid}"]))
      |> render_click()

      refute has_element?(view, ~s(#files-viewer-modal button[phx-click="viewer_pick"]))
    end
  end

  # ---------------------------------------------------------------------------
  # The viewer writes nothing to the file
  # ---------------------------------------------------------------------------

  describe "no writes" do
    test "rotation, annotations and the title are refused; no editor is offered",
         %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)
      eye(view, a)

      html = render(element(view, "#pick-viewer-modal"))
      refute html =~ ~s(phx-click="edit_image")
      refute html =~ "media-meta-form-"
      refute html =~ ~s(phx-click="set_featured")

      viewer_hook(view, a, "fresco:rotate", %{"rotation" => 90})

      shape = %{"uuid" => Ecto.UUID.generate(), "kind" => "rectangle", "geometry" => %{}}
      viewer_hook(view, a, "etcher:annotations-changed", %{"annotations" => [shape]})

      viewer_hook(view, a, "save_media_details", %{
        "details" => %{"en" => %{"title" => "Forged title", "alt" => "x"}}
      })

      row = Storage.get_file(a.uuid)
      refute Map.has_key?(row.metadata || %{}, "rotation")
      refute inspect(row.metadata) =~ "Forged title"
      assert PhoenixKit.Annotations.list_for_file(a.uuid) == []
    end

    # The control: the same event, sent the same way, does reach the viewer
    # and write when the browser is not a picker.
    test "a browser that is not a picker saves the rotation", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"plain" => true})

      view
      |> element(~s(#files [phx-click="click_file"][phx-value-file-uuid="#{a.uuid}"]))
      |> render_click()

      viewer_hook(view, a, "fresco:rotate", %{"rotation" => 90})
      assert Storage.get_file(a.uuid).metadata["rotation"] == 90
    end
  end

  # ---------------------------------------------------------------------------
  # Move to trash
  # ---------------------------------------------------------------------------

  describe "Move to trash" do
    for folder_actions <- [true, false] do
      test "is offered and works (folder_actions: #{folder_actions}); the file leaves the pick",
           %{conn: conn} = ctx do
        [a, b] = files_in_order!(ctx.scope, 2)
        view = open(conn, ctx, %{"opts" => %{folder_actions: unquote(folder_actions)}})

        click_file(view, a)
        click_file(view, b)
        eye(view, a)

        view
        |> element(~s(#pick-viewer-modal button[phx-click="trash_file"]))
        |> render_click()

        assert Storage.get_file(a.uuid).status == "trashed"
        refute has_element?(view, "#pick-viewer-modal")
        assert confirm(view) == [b.uuid]
      end
    end

    # A file linked into the open folder is only taken out of it: no trash
    # broadcast comes, and it must leave the pick all the same.
    test "a file only unlinked from the open folder leaves the pick too", %{conn: conn} = ctx do
      sub = folder!("Kitchen", ctx.scope)
      a = file!(sub)
      {:ok, _} = Storage.attach_file_to_folder(a, ctx.scope.uuid)
      view = open(conn, ctx)

      click_file(view, a)
      eye(view, a)

      view
      |> element(~s(#pick-viewer-modal button[phx-click="trash_file"]))
      |> render_click()

      assert Storage.get_file(a.uuid).status == "active"
      assert confirm(view) == []
    end

    test "a readonly picker offers no trash", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{readonly: true}})
      eye(view, a)

      refute has_element?(view, ~s(#pick-viewer-modal button[phx-click="trash_file"]))
    end
  end

  # The tile menu's Move to Trash in a picker (`delete_file` on a live file).
  describe "Move to Trash from the tile menu" do
    defp kebab_trash(view, file) do
      view
      |> element(~s(#pick-file-kebab-grid-#{file.uuid} button[phx-click="delete_file"]))
      |> render_click()
    end

    test "a trashed file leaves the pick", %{conn: conn} = ctx do
      [a, b] = files_in_order!(ctx.scope, 2)
      view = open(conn, ctx)

      click_file(view, a)
      click_file(view, b)
      kebab_trash(view, a)

      assert Storage.get_file(a.uuid).status == "trashed"
      assert confirm(view) == [b.uuid]
    end

    test "a file only unlinked from the open folder leaves the pick", %{conn: conn} = ctx do
      linked = file!(folder!("Elsewhere"))
      {:ok, _} = Storage.attach_file_to_folder(linked, ctx.scope.uuid)
      view = open(conn, ctx)

      click_file(view, linked)
      kebab_trash(view, linked)

      assert Storage.get_file(linked.uuid).status == "active"
      assert confirm(view) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Escape and the host modal
  # ---------------------------------------------------------------------------

  describe "Escape" do
    test "closes the viewer only: the pick and the picker stay", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"in_modal" => true})

      click_file(view, a)
      eye(view, a)
      view |> element("#pick-viewer-modal") |> render_hook("viewer_keydown", %{"key" => "Escape"})

      refute has_element?(view, "#pick-viewer-modal")
      assert has_element?(view, "#slot-modal #pick")
      refute_received {:cancelled, _}
      refute_received :host_modal_closed
      assert confirm(view) == [a.uuid]
    end
  end

  describe "inside a host modal" do
    test "the viewer is lifted into the top layer, out of the modal's box", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"in_modal" => true})
      eye(view, a)

      assert has_element?(view, ~s(#slot-modal #pick-viewer-modal[popover="manual"]))
      assert has_element?(view, ~s(#pick-viewer-modal[phx-hook="ViewerKeydown"]))
    end

    test "a browser that is not a picker keeps its viewer in place", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"plain" => true})

      view
      |> element(~s(#files [phx-click="click_file"][phx-value-file-uuid="#{a.uuid}"]))
      |> render_click()

      assert has_element?(view, "#files-viewer-modal")
      refute has_element?(view, "#files-viewer-modal[popover]")
    end
  end

  describe "the sidebar fold" do
    test "a picker's viewer folds the sidebar without writing the user's preference",
         %{
           conn: conn
         } = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)
      eye(view, a)

      view
      |> element(
        ~s(#pick-viewer-modal button[phx-click="toggle_viewer_sidebar"][class*="right-14"]),
        ""
      )
      |> render_click()

      user = Auth.get_user(ctx.user.uuid)
      assert (user.custom_fields || %{})["media_viewer_info_collapsed"] == nil
    end
  end

  test "the viewer's pick events are not writes" do
    refute "view_file" in MediaBrowser.write_events()
    refute "viewer_pick" in MediaBrowser.write_events()
  end
end
