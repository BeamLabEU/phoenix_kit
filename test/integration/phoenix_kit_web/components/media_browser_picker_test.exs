defmodule PhoenixKitWeb.Components.MediaBrowserPickerTest do
  @moduledoc """
  The media browser as a picker (`picker`): a host opens it to choose files
  for a slot. A click picks (single replaces, multiple keeps the order the
  files were picked in, up to `max_select`); folders are browsed, never
  picked; the pick survives navigation; Confirm / Cancel report to the host.
  Every pick is checked on the server, `folder_actions: false` hides AND
  refuses the folder writes, and an upload in the picker picks itself — and
  holds the picker open until it has landed.

  A browser the host stops rendering is unregistered
  (`MediaBrowser.unregister_browser/1`), so an upload is never routed or
  copied to it; with no browser left the upload stays in the inbox as an
  upload problem instead of being deleted.
  """

  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.UploadInbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  @buckets_cache :phoenix_kit_buckets_cache

  defmodule Target do
    @moduledoc false
    use Phoenix.LiveComponent
    import Plug.Conn, only: []

    def update(%{picked: picked}, socket) do
      send(socket.assigns.test_pid, {:target, :picked, picked})
      {:ok, socket}
    end

    def update(%{picker_uploading: uploading?}, socket) do
      send(socket.assigns.test_pid, {:target, :uploading, uploading?})
      {:ok, socket}
    end

    def update(assigns, socket), do: {:ok, assign(socket, assigns)}

    def render(assigns), do: ~H"<div id={@id}></div>"
  end

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView
    import Plug.Conn, only: []

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
         browsers: session["browsers"] || ["pick"],
         selected: session["selected"] || [],
         notify?: session["notify"] || false,
         uploads_on?: Map.get(session, "uploads_on", true)
       )}
    end

    def render(assigns) do
      ~H"""
      <div>
        <%= for id <- @browsers do %>
          <.live_component
            :if={id == "files"}
            module={MediaBrowser}
            id={id}
            scope_folder_id={@scope}
            folder_actions={Map.get(@opts, :files_folder_actions, true)}
            parent_uploads={@uploads}
            phoenix_kit_current_user={@phoenix_kit_current_user}
          />
          <.live_component
            :if={id != "files"}
            module={MediaBrowser}
            id={id}
            picker
            pick_mode={Map.get(@opts, :pick_mode, :multiple)}
            max_select={@opts[:max_select]}
            selected={@selected}
            notify={if @notify?, do: {PhoenixKitWeb.Components.MediaBrowserPickerTest.Target, "target"}}
            folder_labels={Map.get(@opts, :folder_labels, %{})}
            folder_actions={Map.get(@opts, :folder_actions, true)}
            only_file_type={@opts[:only_file_type]}
            readonly={Map.get(@opts, :readonly, false)}
            scope_folder_id={@scope}
            initial_params={@opts[:initial_params] || %{}}
            featured={@opts[:featured]}
            parent_uploads={if @uploads_on?, do: @uploads}
            phoenix_kit_current_user={@phoenix_kit_current_user}
          />
        <% end %>
        <.live_component
          :if={@notify?}
          module={PhoenixKitWeb.Components.MediaBrowserPickerTest.Target}
          id="target"
          test_pid={@test_pid}
        />
      </div>
      """
    end

    def handle_event("validate", _params, socket), do: {:noreply, socket}

    def handle_event("set_selected", %{"uuids" => uuids}, socket),
      do: {:noreply, assign(socket, :selected, uuids)}

    def handle_event("reset", %{"uuids" => uuids}, socket) do
      send_update(MediaBrowser, id: "pick", picker_reset: uuids)
      {:noreply, socket}
    end

    def handle_event("uploads_on", _params, socket),
      do: {:noreply, assign(socket, :uploads_on?, true)}

    def handle_event("show", params, socket) do
      ids = params["ids"] || []
      Enum.each(socket.assigns.browsers -- ids, &MediaBrowser.unregister_browser/1)
      {:noreply, assign(socket, :browsers, ids)}
    end

    def handle_info({MediaBrowser, id, {:picked, uuids}}, socket) do
      send(socket.assigns.test_pid, {:picked, id, uuids})
      {:noreply, socket}
    end

    def handle_info({MediaBrowser, id, :pick_cancelled}, socket) do
      send(socket.assigns.test_pid, {:cancelled, id})
      {:noreply, socket}
    end

    def handle_info({MediaBrowser, id, {:picker_uploading, uploading?}}, socket) do
      send(socket.assigns.test_pid, {:uploading, id, uploading?})
      {:noreply, socket}
    end

    def handle_info({MediaBrowser, _, _} = msg, socket),
      do: MediaBrowser.handle_parent_info(msg, socket)

    def handle_info(_msg, socket), do: {:noreply, socket}
  end

  # A host wired by hand, with only the shared upload.
  defmodule SharedUploadHost do
    @moduledoc false
    use Phoenix.LiveView
    import Plug.Conn, only: []

    alias PhoenixKitWeb.Components.MediaBrowser

    def mount(_params, session, socket) do
      {:ok,
       socket
       |> assign(:phoenix_kit_current_user, session["user"])
       |> assign(test_pid: session["test_pid"], scope: session["scope"])
       |> allow_upload(:media_files,
         accept: :any,
         max_entries: 10,
         auto_upload: true,
         progress: &MediaBrowser.parent_progress/3
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={MediaBrowser}
        id="pick"
        picker
        scope_folder_id={@scope}
        parent_uploads={@uploads}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />
      """
    end

    def handle_event("validate", _params, socket), do: {:noreply, socket}

    def handle_info({MediaBrowser, id, {:picked, uuids}}, socket) do
      send(socket.assigns.test_pid, {:picked, id, uuids})
      {:noreply, socket}
    end

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
    root = Path.join(System.tmp_dir!(), "pk_picker_#{n}")
    inbox = Path.join(System.tmp_dir!(), "pk_picker_inbox_#{n}")
    previous_inbox = Application.get_env(:phoenix_kit, :upload_inbox_dir)
    Application.put_env(:phoenix_kit, :upload_inbox_dir, inbox)

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "picker-#{n}",
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

      if previous_inbox,
        do: Application.put_env(:phoenix_kit, :upload_inbox_dir, previous_inbox),
        else: Application.delete_env(:phoenix_kit, :upload_inbox_dir)

      File.rm_rf(root)
      File.rm_rf(inbox)
    end)

    {:ok, user} =
      Auth.register_user(%{
        email: "picker-#{n}@example.com",
        password: "ValidPassword123!"
      })

    Process.put(:owner_uuid, user.uuid)
    scope = folder!("Order")
    %{user: user, scope: scope, inbox: inbox}
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
          file_checksum: "picker-#{n}",
          user_file_checksum: "picker-u-#{n}",
          size: 1,
          status: "active",
          folder_uuid: folder && folder.uuid,
          user_uuid: Process.get(:owner_uuid)
        },
        attrs
      )
    )
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

  defp click_file(view, file, browser \\ "pick") do
    view
    |> element(~s(##{browser} [phx-click="click_file"][phx-value-file-uuid="#{file.uuid}"]))
    |> render_click()
  end

  defp hook(view, event, params \\ %{}, browser \\ "pick") do
    view |> element("##{browser}") |> render_hook(event, params)
  end

  defp confirm(view),
    do: view |> element(~s(#pick button[phx-click="pick_confirm"])) |> render_click()

  defp open_folder(view, folder) do
    view
    |> element(
      ~s(#pick-media-browser-sidebar button[phx-click="navigate_folder"][phx-value-folder-uuid="#{folder.uuid}"])
    )
    |> render_click()
  end

  defp upload(view, names, browser \\ "pick") do
    # Large enough that a transfer can stop half way (`render_upload/3`).
    files =
      Enum.map(
        names,
        &%{
          name: &1,
          content: "#{&1}-#{System.unique_integer()}-" <> :binary.copy("x", 1000),
          type: "image/png"
        }
      )

    # A picker has an upload of its own (see `MediaBrowser.setup_uploads/1`).
    file_input(view, "##{browser}-folder-drop-upload-form", :media_picker_files, files)
  end

  # The browser stores, then waits out its batch window and the picker's
  # idle check before it settles.
  defp settle(view) do
    Process.sleep(900)
    render(view)
  end

  defp stored(user) do
    Repo.all(
      from(f in StorageFile, where: f.user_uuid == ^user.uuid, order_by: [asc: f.inserted_at])
    )
  end

  defp inbox_items(inbox, user), do: Path.wildcard(Path.join([inbox, user.uuid, "*.json"]))

  defp ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id]")
    |> LazyHTML.attribute("id")
  end

  # ---------------------------------------------------------------------------
  # Picking
  # ---------------------------------------------------------------------------

  describe "single" do
    test "a click picks, the next click replaces it, Confirm reports it", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      b = file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{pick_mode: :single}})

      click_file(view, a)
      click_file(view, b)
      confirm(view)

      assert_receive {:picked, "pick", [uuid]}
      assert uuid == b.uuid
    end

    test "a double click picks that file and confirms", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{pick_mode: :single}})

      hook(view, "pick_quick_confirm", %{"file-uuid" => a.uuid})

      assert_receive {:picked, "pick", [uuid]}
      assert uuid == a.uuid
    end

    test "the root carries the pick mode the double-click script reads", %{conn: conn} = ctx do
      view = open(conn, ctx, %{"opts" => %{pick_mode: :single}})
      assert has_element?(view, ~s(#pick[data-pick-mode="single"]))
    end
  end

  describe "multiple" do
    test "picks keep the order they were made in; a second click takes one out",
         %{conn: conn} = ctx do
      [a, b, c] = for _ <- 1..3, do: file!(ctx.scope)
      view = open(conn, ctx)

      click_file(view, b)
      click_file(view, a)
      click_file(view, c)
      click_file(view, a)
      confirm(view)

      assert_receive {:picked, "pick", uuids}
      assert uuids == [b.uuid, c.uuid]
    end

    test "max_select stops further picks and says so", %{conn: conn} = ctx do
      [a, b, c] = for _ <- 1..3, do: file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{max_select: 2}})

      click_file(view, a)
      click_file(view, b)
      html = click_file(view, c)
      assert html =~ "Maximum 2 files"

      confirm(view)
      assert_receive {:picked, "pick", uuids}
      assert uuids == [a.uuid, b.uuid]
    end

    test "a double click does not confirm", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)

      hook(view, "pick_quick_confirm", %{"file-uuid" => a.uuid})
      refute_receive {:picked, _, _}, 100
    end

    test "the pick survives navigating between folders", %{conn: conn} = ctx do
      one = folder!("Kitchen", ctx.scope)
      two = folder!("Hall", ctx.scope)
      a = file!(one)
      b = file!(two)
      view = open(conn, ctx)

      open_folder(view, one)
      click_file(view, a)
      open_folder(view, two)
      html = click_file(view, b)
      assert html =~ "2 selected"

      confirm(view)
      assert_receive {:picked, "pick", uuids}
      assert uuids == [a.uuid, b.uuid]
    end

    test "max_select 1 says it in the singular", %{conn: conn} = ctx do
      [a, b] = for _ <- 1..2, do: file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{max_select: 1}})

      click_file(view, a)
      html = click_file(view, b)

      assert html =~ "Maximum 1 file"
      refute html =~ "Maximum 1 files"
    end

    test "a refused pick logs the fact, not what the client sent", %{conn: conn} = ctx do
      view = open(conn, ctx)
      sentinel = "client-sent-#{System.unique_integer([:positive])}"

      log = capture_log(fn -> hook(view, "click_file", %{"file-uuid" => sentinel}) end)

      assert log =~ "pick refused"
      refute log =~ sentinel
    end

    test "the upload-resume hook of a picker names its browser; a plain one does not",
         %{
           conn: conn
         } = ctx do
      view = open(conn, ctx, %{"browsers" => ["pick", "files"]})

      assert has_element?(view, ~s(#pick-upload-resume[data-browser="pick"][data-picker="true"]))
      assert has_element?(view, "#files-upload-resume")
      refute has_element?(view, "#files-upload-resume[data-browser]")
      refute has_element?(view, "#files-upload-resume[data-picker]")
    end

    test "folders are browsed, never picked", %{conn: conn} = ctx do
      sub = folder!("Kitchen", ctx.scope)
      view = open(conn, ctx)

      capture_log(fn ->
        hook(view, "click_file", %{"file-uuid" => sub.uuid})
        hook(view, "toggle_select_folder", %{"folder-uuid" => sub.uuid})
      end)

      confirm(view)

      assert_receive {:picked, "pick", []}
    end
  end

  describe "pre-selection" do
    test "`selected` is read on the first mount only", %{conn: conn} = ctx do
      [a, b] = for _ <- 1..2, do: file!(ctx.scope)
      view = open(conn, ctx, %{"selected" => [a.uuid]})

      assert has_element?(view, ~s(#pick [data-pick-order="1"] [phx-value-file-uuid="#{a.uuid}"]))

      # A host re-render (an upload tick, a changed assign) leaves the
      # working pick alone.
      render_click(view, "set_selected", %{"uuids" => [b.uuid]})
      confirm(view)

      assert_receive {:picked, "pick", uuids}
      assert uuids == [a.uuid]
    end

    test "`picker_reset` replaces the working pick", %{conn: conn} = ctx do
      [a, b, c] = for _ <- 1..3, do: file!(ctx.scope)
      view = open(conn, ctx, %{"selected" => [a.uuid]})

      render_click(view, "reset", %{"uuids" => [c.uuid, b.uuid]})
      confirm(view)

      assert_receive {:picked, "pick", uuids}
      assert uuids == [c.uuid, b.uuid]
    end
  end

  describe "confirm and cancel" do
    test "Cancel reports :pick_cancelled", %{conn: conn} = ctx do
      view = open(conn, ctx)
      view |> element(~s(#pick button[phx-click="pick_cancel"])) |> render_click()
      assert_receive {:cancelled, "pick"}
    end

    test "with `notify`, the host component gets `picked:`", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"notify" => true})

      click_file(view, a)
      confirm(view)
      assert_receive {:target, :picked, uuids}
      assert uuids == [a.uuid]

      view |> element(~s(#pick button[phx-click="pick_cancel"])) |> render_click()
      assert_receive {:target, :picked, :cancelled}
      refute_receive {:picked, _, _}, 50
    end

    test "a file trashed after it was picked is not reported", %{conn: conn} = ctx do
      [a, b] = for _ <- 1..2, do: file!(ctx.scope)
      view = open(conn, ctx)

      click_file(view, a)
      click_file(view, b)
      {:ok, _} = Storage.trash_file(a)
      confirm(view)

      assert_receive {:picked, "pick", uuids}
      assert uuids == [b.uuid]
    end
  end

  describe "the server checks every pick" do
    test "another type, outside the scope, or in the trash is refused", %{conn: conn} = ctx do
      outside = file!(folder!("Elsewhere"))
      pdf = file!(ctx.scope, %{file_type: "document", mime_type: "application/pdf"})
      trashed = file!(ctx.scope, %{status: "trashed"})
      ok = file!(ctx.scope)

      view = open(conn, ctx, %{"opts" => %{only_file_type: "image"}})

      capture_log(fn ->
        for file <- [outside, pdf, trashed, ok] do
          hook(view, "click_file", %{"file-uuid" => file.uuid})
        end

        hook(view, "click_file", %{"file-uuid" => "not-a-uuid"})
      end)

      confirm(view)
      assert_receive {:picked, "pick", uuids}
      assert uuids == [ok.uuid]
    end

    test "a file linked into the scope from outside can be picked", %{conn: conn} = ctx do
      linked = file!(folder!("Elsewhere"))
      {:ok, _} = Storage.attach_file_to_folder(linked, ctx.scope.uuid)
      view = open(conn, ctx)

      hook(view, "click_file", %{"file-uuid" => linked.uuid})
      confirm(view)

      assert_receive {:picked, "pick", [uuid]}
      assert uuid == linked.uuid
    end

    test "a readonly picker still picks — a pick writes nothing", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{readonly: true}})

      click_file(view, a)
      confirm(view)
      assert_receive {:picked, "pick", [uuid]}
      assert uuid == a.uuid
    end

    test "the pick events are not writes" do
      for event <- ~w(click_file pick_confirm pick_cancel pick_quick_confirm) do
        refute event in MediaBrowser.write_events()
      end
    end
  end

  describe "picker layout" do
    test "the grid is always shown and the view switch is gone", %{conn: conn} = ctx do
      {:ok, _} =
        Auth.update_user_custom_fields(ctx.user, %{"media_view_mode" => "list"},
          ensure_definitions: false
        )

      ctx = %{ctx | user: Auth.get_user(ctx.user.uuid)}
      file!(ctx.scope)
      view = open(conn, ctx)

      assert has_element?(view, "#pick [data-media-grid]")
      refute has_element?(view, ~s(#pick [phx-click="set_view_mode"]))

      capture_log(fn -> hook(view, "set_view_mode", %{"mode" => "list"}) end)
      assert has_element?(view, "#pick [data-media-grid]")
    end

    test "the picker writes no view or folder-tree preference", %{conn: conn} = ctx do
      sub = folder!("Kitchen", ctx.scope)
      folder!("Shelf", sub)
      view = open(conn, ctx)

      hook(view, "toggle_folder_expand", %{"folder-uuid" => sub.uuid})
      hook(view, "toggle_sidebar")
      capture_log(fn -> hook(view, "set_view_mode", %{"mode" => "stacks"}) end)

      fields = Auth.get_user(ctx.user.uuid).custom_fields || %{}
      refute Map.has_key?(fields, "media_view_mode")
      refute Map.has_key?(fields, "media_expanded_folders")
      refute Map.has_key?(fields, "media_sidebar_collapsed")
    end

    test "no bulk-select controls, no box select; a tile click opens no viewer",
         %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)

      refute has_element?(view, ~s(#pick [phx-click="toggle_select_mode"]))
      refute has_element?(view, "#pick [data-box-area]")
      assert has_element?(view, ~s(#pick-instant-viewer[data-armed="false"]))

      click_file(view, a)
      refute has_element?(view, "#pick-viewer-modal")

      capture_log(fn ->
        hook(view, "box_select", %{"files" => [a.uuid], "folders" => []})
        hook(view, "toggle_select_mode")
      end)

      refute has_element?(view, ~s(#pick button[phx-click="delete_selected"]))
    end

    test "the toolbar shows the count with Confirm and Cancel", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)

      html = click_file(view, a)
      assert html =~ "1 selected"
      assert has_element?(view, ~s(#pick button[phx-click="pick_confirm"]))
      assert has_element?(view, ~s(#pick button[phx-click="pick_cancel"]))
    end
  end

  describe "folder_labels" do
    test "a label replaces the folder's name in the tree, the trail and the tiles",
         %{conn: conn} = ctx do
      sub = folder!("sub", ctx.scope)
      inner = folder!("inner", sub)

      view =
        open(conn, ctx, %{
          "opts" => %{folder_labels: %{sub.uuid => "60-1 — Kitchen", inner.uuid => "Shelf"}}
        })

      html = render(view)
      assert html =~ "60-1 — Kitchen"
      refute html =~ sub.name

      html = open_folder(view, sub)
      assert has_element?(view, "#pick nav.breadcrumbs", "60-1 — Kitchen")
      assert has_element?(view, "#pick [data-media-grid]", "Shelf")
      refute html =~ sub.name
      refute html =~ inner.name
    end
  end

  describe "folder_actions: false" do
    test "the folder writes are hidden", %{conn: conn} = ctx do
      sub = folder!("Kitchen", ctx.scope)
      file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{folder_actions: false}})

      refute has_element?(view, ~s(#pick [phx-click="open_new_folder_modal"]))
      refute has_element?(view, ~s(#pick [phx-click="start_rename_folder"]))
      refute has_element?(view, ~s(#pick [phx-click="toggle_trash_filter"]))
      refute has_element?(view, ~s(#pick [phx-click="delete_folder"]))
      refute has_element?(view, ~s(#pick [phx-click="prepare_move_folder"]))
      refute has_element?(view, ~s(#pick [phx-click="prepare_move_file"]))
      refute has_element?(view, "#pick [data-draggable-folder]")
      refute has_element?(view, "#pick [data-draggable-file]")

      open_folder(view, sub)
      refute has_element?(view, ~s(#pick [phx-click="start_edit_folder_header"]))
    end

    test "…and refused on the server", %{conn: conn} = ctx do
      sub = folder!("Kitchen", ctx.scope)
      other = folder!("Hall", ctx.scope)
      a = file!(sub)
      view = open(conn, ctx, %{"opts" => %{folder_actions: false}})

      capture_log(fn ->
        hook(view, "open_new_folder_modal")
        hook(view, "submit_new_folder", %{"name" => "Pantry"})
        hook(view, "rename_folder", %{"folder_uuid" => sub.uuid, "name" => "Renamed"})
        hook(view, "trash_folder", %{"folder_uuid" => other.uuid})
        hook(view, "move_file_to_folder", %{"file_uuid" => a.uuid, "folder_uuid" => other.uuid})

        hook(view, "move_folder_to_folder", %{
          "folder_uuid" => other.uuid,
          "target_uuid" => sub.uuid
        })

        hook(view, "toggle_trash_filter")
      end)

      refute Repo.exists?(from(f in Storage.Folder, where: like(f.name, "Pantry%")))
      assert Storage.get_folder(sub.uuid).name == sub.name
      assert is_nil(Storage.get_folder(other.uuid).trashed_at)
      assert Storage.get_folder(other.uuid).parent_uuid == ctx.scope.uuid
      assert Repo.get(StorageFile, a.uuid).folder_uuid == sub.uuid
      refute has_element?(view, "#pick-new-folder-form")
      refute render(view) =~ "Trash is empty"
    end

    test "every folder event is refused with the socket untouched" do
      for event <- MediaBrowser.folder_action_events() do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, id: "mb", folder_actions: false}
        }

        assert {:noreply, ^socket} =
                 capture_log_result(fn -> MediaBrowser.handle_event(event, %{}, socket) end),
               "expected #{event} to be refused with folder actions off"
      end
    end

    test "the folder events are the ones the hidden controls send" do
      for event <-
            ~w(open_new_folder_modal submit_new_folder start_rename_folder rename_folder
               change_folder_color trash_folder delete_folder restore_folder
               move_folder_to_folder prepare_move_folder move_file_to_folder prepare_move_file
               move_selected_to_folder show_move_modal toggle_trash_filter empty_trash
               start_edit_folder_header save_folder_header start_edit_folder_description
               save_folder_description) do
        assert event in MediaBrowser.folder_action_events(), "#{event} is not classified"
      end
    end

    test "uploading by dropping on the panel stays", %{conn: conn} = ctx do
      view = open(conn, ctx, %{"opts" => %{folder_actions: false}})
      assert has_element?(view, "#pick-folder-drop-upload-form")
      assert has_element?(view, ~s(#pick-folder-drop-upload[phx-hook="FolderDropUpload"]))
    end
  end

  defp capture_log_result(fun) do
    ref = make_ref()
    capture_log(fn -> send(self(), {ref, fun.()}) end)

    receive do
      {^ref, result} -> result
    end
  end

  # ---------------------------------------------------------------------------
  # Uploads
  # ---------------------------------------------------------------------------

  describe "an upload in the picker" do
    test "single: the uploaded file replaces the pick", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{pick_mode: :single}, "selected" => [a.uuid]})

      input = upload(view, ["kitchen.png"])
      render_upload(input, "kitchen.png")
      settle(view)
      confirm(view)

      [stored] = stored(ctx.user) -- [Repo.get(StorageFile, a.uuid)]
      assert_receive {:picked, "pick", [uuid]}
      assert uuid == stored.uuid
    end

    test "multiple: the uploaded file is added, up to max_select", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{max_select: 2}, "selected" => [a.uuid]})

      input = upload(view, ["one.png", "two.png"])
      render_upload(input, "one.png")
      settle(view)
      render_upload(input, "two.png")
      settle(view)
      confirm(view)

      one = Enum.find(stored(ctx.user), &(&1.original_file_name == "one.png"))
      assert_receive {:picked, "pick", uuids}
      assert uuids == [a.uuid, one.uuid]
    end

    test "Confirm and Cancel wait for the upload; the host is told", %{conn: conn} = ctx do
      view = open(conn, ctx)

      input = upload(view, ["kitchen.png"])
      render_upload(input, "kitchen.png", 50)

      assert_receive {:uploading, "pick", true}
      html = render(view)
      assert html =~ "Wait for the uploads to finish"
      assert has_element?(view, ~s(#pick button[phx-click="pick_confirm"][disabled]))
      assert has_element?(view, ~s(#pick button[phx-click="pick_cancel"][disabled]))

      capture_log(fn ->
        hook(view, "pick_confirm")
        hook(view, "pick_cancel")
      end)

      refute_receive {:picked, _, _}, 50
      refute_receive {:cancelled, _}, 50

      render_upload(input, "kitchen.png", 50)
      settle(view)
      assert_receive {:uploading, "pick", false}, 2000

      confirm(view)
      [stored] = stored(ctx.user)
      assert_receive {:picked, "pick", [uuid]}
      assert uuid == stored.uuid
    end

    test "with `notify`, the host component is told about the upload", %{conn: conn} = ctx do
      view = open(conn, ctx, %{"notify" => true})

      input = upload(view, ["kitchen.png"])
      render_upload(input, "kitchen.png", 50)
      assert_receive {:target, :uploading, true}

      render_upload(input, "kitchen.png", 50)
      settle(view)
      assert_receive {:target, :uploading, false}, 2000
    end
  end

  describe "an upload counts as on its way" do
    # A socket past its first mount, so `update/2` touches no storage.
    defp picker_socket(assigns) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(
            %{
              __changed__: %{},
              id: "p",
              picker: true,
              uploaded_files: [],
              upload_in_flight: false
            },
            assigns
          )
      }
    end

    defp uploads(entries), do: %{media_picker_files: %{entries: entries}}

    test "while the page receives a transfer" do
      {:ok, socket} =
        MediaBrowser.update(%{parent_uploads: uploads([%{ref: "0"}])}, picker_socket(%{}))

      assert socket.assigns.picker_uploading
      assert_received {MediaBrowser, "p", {:picker_uploading, true}}
    end

    test "while a received file waits in the browser's own queue" do
      entry = %{client_name: "kitchen.png", client_size: 1}

      for queued <- [
            %{upload_process_queue: [{"/tmp/x", entry}]},
            %{upload_processing: {"/tmp/x", entry}},
            %{pending_batch: [{:ok, %{file_uuid: "x"}}]}
          ] do
        {:ok, socket} = MediaBrowser.update(%{parent_uploads: uploads([])}, picker_socket(queued))

        assert socket.assigns.picker_uploading,
               "#{inspect(Map.keys(queued))} is an upload on its way"

        assert_received {MediaBrowser, "p", {:picker_uploading, true}}
      end
    end

    test "a browser that is not a picker reports nothing" do
      {:ok, _socket} =
        MediaBrowser.update(
          %{parent_uploads: %{media_files: %{entries: [%{ref: "0"}]}}},
          picker_socket(%{picker: false})
        )

      refute_received {MediaBrowser, _, _}
    end
  end

  # ---------------------------------------------------------------------------
  # Browsers that are gone
  # ---------------------------------------------------------------------------

  defp inbox_upload!(user, name) do
    tmp = Path.join(System.tmp_dir!(), "pk_picker_src_#{System.unique_integer([:positive])}")
    File.write!(tmp, "#{name}-#{System.unique_integer()}")

    {:ok, _item, path} =
      UploadInbox.put(user.uuid, tmp, %{
        client_name: name,
        client_type: "image/png",
        client_size: 10
      })

    File.rm(tmp)

    entry = %{
      uuid: Ecto.UUID.generate(),
      client_name: name,
      client_type: "image/png",
      client_size: 10,
      client_last_modified: nil
    }

    {path, entry}
  end

  defp registered(view), do: :sys.get_state(view.pid).socket.assigns[:media_browser_ids]

  describe "unregister_browser/1" do
    test "takes the browser out of the routing", %{conn: conn} = ctx do
      view = open(conn, ctx, %{"browsers" => ["pick", "files"]})
      assert MapSet.equal?(registered(view), MapSet.new(["pick", "files"]))

      render_click(view, "show", %{"ids" => ["files"]})
      assert MapSet.equal?(registered(view), MapSet.new(["files"]))
    end

    test "switching browsers: the upload goes to the one shown, no copy is left",
         %{conn: conn} = ctx do
      view = open(conn, ctx, %{"browsers" => ["pick", "files"]})
      render_click(view, "show", %{"ids" => ["files"]})

      {path, entry} = inbox_upload!(ctx.user, "kitchen.png")
      send(view.pid, {MediaBrowser, :process_pending_upload, {path, entry}})
      settle(view)

      assert [%{original_file_name: "kitchen.png"}] = stored(ctx.user)
      assert inbox_items(ctx.inbox, ctx.user) == [], "no copy waits for a browser that is gone"
    end

    test "with no browser left the upload stays as an upload problem", %{conn: conn} = ctx do
      view = open(conn, ctx)
      render_click(view, "show", %{"ids" => []})

      {path, entry} = inbox_upload!(ctx.user, "kitchen.png")
      send(view.pid, {MediaBrowser, :process_pending_upload, {path, entry}})
      render(view)

      assert File.exists?(path), "the bytes are kept"

      assert [%{client_name: "kitchen.png", status: "failed", error: error}] =
               UploadInbox.list(ctx.user.uuid)

      assert error == "No open media browser could receive this upload."
      assert stored(ctx.user) == []

      # The next browser opened lists it, with Retry.
      render_click(view, "show", %{"ids" => ["pick"]})
      html = render(view)
      assert html =~ "kitchen.png"
      assert has_element?(view, ~s(#pick button[phx-click="retry_upload"]))
    end
  end

  describe "the picker's own upload" do
    test "a browser that is not a picker uploads through :media_files as before",
         %{conn: conn} = ctx do
      view = open(conn, ctx, %{"browsers" => ["files"]})

      refute render(view) =~ "media_picker_files"

      files = [%{name: "hall.png", content: :binary.copy("y", 500), type: "image/png"}]
      input = file_input(view, "#folder-drop-upload-form", :media_files, files)
      render_upload(input, "hall.png")
      settle(view)

      assert [%{original_file_name: "hall.png", folder_uuid: folder}] = stored(ctx.user)
      assert folder == ctx.scope.uuid
    end

    test "an upload in the picker is not copied into the other browser", %{conn: conn} = ctx do
      view = open(conn, ctx, %{"browsers" => ["files", "pick"]})

      input = upload(view, ["kitchen.png"])
      render_upload(input, "kitchen.png")
      settle(view)
      confirm(view)

      assert [stored] = stored(ctx.user)
      assert_receive {:picked, "pick", [uuid]}
      assert uuid == stored.uuid
      assert inbox_items(ctx.inbox, ctx.user) == []
      refute Repo.exists?(from(l in Storage.FolderLink, where: l.file_uuid == ^stored.uuid))
    end

    test "a picker's upload of another type is refused, like any upload", %{conn: conn} = ctx do
      view = open(conn, ctx, %{"opts" => %{only_file_type: "image"}})
      {path, entry} = inbox_upload!(ctx.user, "notes.pdf")

      entry =
        %{entry | client_type: "application/pdf"} |> Map.put(:upload_config, :media_picker_files)

      send(view.pid, {MediaBrowser, :process_pending_upload, {path, entry}})
      settle(view)

      assert stored(ctx.user) == []
      assert [%{client_name: "notes.pdf", status: "failed"}] = UploadInbox.list(ctx.user.uuid)
    end

    test "a host that allowed only :media_files: the picker uses it", %{conn: conn} = ctx do
      {:ok, view, _html} =
        live_isolated(conn, SharedUploadHost,
          session: %{"test_pid" => self(), "scope" => ctx.scope.uuid, "user" => ctx.user}
        )

      files = [%{name: "kitchen.png", content: :binary.copy("z", 500), type: "image/png"}]
      input = file_input(view, "#pick-folder-drop-upload-form", :media_files, files)
      render_upload(input, "kitchen.png")
      settle(view)
      confirm(view)

      assert [stored] = stored(ctx.user)
      assert_receive {:picked, "pick", [uuid]}
      assert uuid == stored.uuid
    end
  end

  describe "handle_parent_info/2 and the picker's messages" do
    test "a picker message that reaches the delegate does not crash it, and is logged" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      for payload <- [{:picked, ["a"]}, :pick_cancelled, {:picker_uploading, true}] do
        log =
          capture_log(fn ->
            assert {:noreply, ^socket} =
                     MediaBrowser.handle_parent_info({MediaBrowser, "pick", payload}, socket)
          end)

        assert log =~ "pick"
      end
    end

    test "unregister_browser/1 sends the unregister message to the calling process" do
      MediaBrowser.unregister_browser("pick")
      assert_received {MediaBrowser, :unregister, "pick"}
    end
  end

  # ---------------------------------------------------------------------------
  # Review round: an uploaded file, preselection, the kebab, gestures
  # ---------------------------------------------------------------------------

  # A real 1×1 PNG: the store keeps what the bytes are, not what the name says.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  defp upload_bytes(view, name, content) do
    input =
      file_input(view, "#pick-folder-drop-upload-form", :media_picker_files, [
        %{name: name, content: content, type: "image/png"}
      ])

    capture_log(fn ->
      render_upload(input, name)
      settle(view)
    end)
  end

  describe "an uploaded file is picked only if a click could pick it" do
    test "a typed picker picks an upload of its type", %{conn: conn} = ctx do
      view = open(conn, ctx, %{"opts" => %{only_file_type: "image"}})
      upload_bytes(view, "kitchen.png", @png)
      confirm(view)

      [stored] = stored(ctx.user)
      assert stored.file_type == "image"
      assert_receive {:picked, "pick", [uuid]}
      assert uuid == stored.uuid
    end

    test "a typed picker does not pick a duplicate kept as another type", %{conn: conn} = ctx do
      content = "notes-" <> :binary.copy("n", 800)

      # The same bytes uploaded earlier as a document: the store hands that
      # row back for the later "image".
      first = open(conn, ctx)

      input =
        file_input(first, "#pick-folder-drop-upload-form", :media_picker_files, [
          %{name: "notes.pdf", content: content, type: "application/pdf"}
        ])

      capture_log(fn ->
        render_upload(input, "notes.pdf")
        settle(first)
      end)

      view = open(conn, ctx, %{"opts" => %{only_file_type: "image"}})
      upload_bytes(view, "kitchen.png", content)
      html = render(view)

      assert [%{file_type: type}] = stored(ctx.user)
      refute type == "image", "precondition: dedup handed back the document"
      assert html =~ "0 selected"

      confirm(view)
      assert_receive {:picked, "pick", []}
    end

    test "a duplicate of a file in the trash is not picked", %{conn: conn} = ctx do
      view = open(conn, ctx, %{"opts" => %{pick_mode: :single}})
      content = "kitchen-" <> :binary.copy("q", 800)

      upload_bytes(view, "kitchen.png", content)
      [first] = stored(ctx.user)
      {:ok, _} = Storage.trash_file(first)
      render(view)

      upload_bytes(view, "kitchen-again.png", content)
      html = render(view)

      assert [%{status: "trashed"}] = stored(ctx.user),
             "precondition: dedup handed back the trashed row"

      assert html =~ "0 selected"

      confirm(view)
      assert_receive {:picked, "pick", []}
    end
  end

  describe "pre-selection is checked" do
    test "`selected` drops what the picker could not pick and keeps max_select",
         %{conn: conn} = ctx do
      [a, b, c] = for _ <- 1..3, do: file!(ctx.scope)
      outside = file!(folder!("Elsewhere"))
      trashed = file!(ctx.scope, %{status: "trashed"})

      view =
        open(conn, ctx, %{
          "opts" => %{max_select: 2},
          "selected" => [outside.uuid, a.uuid, trashed.uuid, b.uuid, c.uuid]
        })

      confirm(view)
      assert_receive {:picked, "pick", uuids}
      assert uuids == [a.uuid, b.uuid]
    end

    test "`picker_reset` is checked the same way", %{conn: conn} = ctx do
      [a, b, c] = for _ <- 1..3, do: file!(ctx.scope)
      outside = file!(folder!("Elsewhere"))
      view = open(conn, ctx, %{"opts" => %{max_select: 2}})

      render_click(view, "reset", %{"uuids" => [outside.uuid, c.uuid, a.uuid, b.uuid]})
      confirm(view)

      assert_receive {:picked, "pick", uuids}
      assert uuids == [c.uuid, a.uuid]
    end
  end

  describe "the file menu in a picker" do
    test "keeps Download and Move to Trash, drops Rotate, Edit image and featured",
         %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx, %{"opts" => %{featured: %{uuid: nil, label: nil}}})
      tile = ~s(#pick-file-kebab-grid-#{a.uuid})

      assert has_element?(view, ~s(#{tile} [phx-click="delete_file"]))
      refute has_element?(view, ~s(#{tile} [phx-click="rotate_file"]))
      refute has_element?(view, ~s(#{tile} [phx-click="open_image_editor"]))
      refute has_element?(view, ~s(#{tile} [phx-click="set_featured"]))
      refute has_element?(view, ~s(#pick [data-role="featured-toggle"]))
    end

    test "Rotate and Edit image are refused on the server", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)

      capture_log(fn ->
        hook(view, "rotate_file", %{"file-uuid" => a.uuid, "dir" => "right"})
        hook(view, "open_image_editor", %{"file-uuid" => a.uuid})
      end)

      assert Map.get(Repo.get(StorageFile, a.uuid).metadata || %{}, "rotation") == nil
      refute has_element?(view, "#pick-image-editor-modal")
    end

    test "a file already in the trash is never deleted for good, whatever the view",
         %{conn: conn} = ctx do
      trashed = file!(ctx.scope, %{status: "trashed"})
      view = open(conn, ctx)

      capture_log(fn -> hook(view, "delete_file", %{"file-uuid" => trashed.uuid}) end)
      assert Repo.get(StorageFile, trashed.uuid), "the active view's Delete must not destroy it"

      # The selection the file menu's Move fills, then a forged bulk delete
      # from the active view: that only ever moves to the Trash.
      hook(view, "prepare_move_file", %{"file-uuid" => trashed.uuid})
      hook(view, "close_move_modal")
      hook(view, "prepare_move_file", %{"file-uuid" => trashed.uuid})
      capture_log(fn -> hook(view, "delete_selected") end)
      assert Repo.get(StorageFile, trashed.uuid)
    end

    test "Move to Trash still works", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)

      hook(view, "delete_file", %{"file-uuid" => a.uuid})
      assert Repo.get(StorageFile, a.uuid).status == "trashed"
    end

    test "every picker file write, and deleting for good, is refused untouched" do
      for event <- MediaBrowser.picker_file_write_events() do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, id: "mb", picker: true}}

        assert {:noreply, ^socket} =
                 capture_log_result(fn -> MediaBrowser.handle_event(event, %{}, socket) end),
               "expected #{event} to be refused in a picker"
      end

      for event <- ~w(delete_file delete_folder delete_selected) do
        socket = %Phoenix.LiveView.Socket{
          assigns: %{__changed__: %{}, id: "mb", picker: true, filter_trash: true}
        }

        assert {:noreply, ^socket} =
                 capture_log_result(fn -> MediaBrowser.handle_event(event, %{}, socket) end),
               "expected #{event} to be refused in a picker's trash view"
      end

      for event <- ~w(rotate_file open_image_editor set_featured unset_featured empty_trash) do
        assert event in MediaBrowser.picker_file_write_events()
      end
    end
  end

  describe "bulk select is off in a picker" do
    test "every picker-off event is refused with the socket untouched" do
      for event <- MediaBrowser.picker_off_events() do
        socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, id: "mb", picker: true}}

        assert {:noreply, ^socket} =
                 capture_log_result(fn -> MediaBrowser.handle_event(event, %{}, socket) end),
               "expected #{event} to be refused in a picker"
      end

      for event <-
            ~w(toggle_select_mode long_press_select toggle_select toggle_select_folder
               select_all box_select set_view_mode) do
        assert event in MediaBrowser.picker_off_events()
      end
    end

    test "none of them picks or selects anything", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      sub = folder!("Kitchen", ctx.scope)
      view = open(conn, ctx)

      capture_log(fn ->
        hook(view, "long_press_select", %{"type" => "file", "uuid" => a.uuid})
        hook(view, "toggle_select", %{"file-uuid" => a.uuid})
        hook(view, "toggle_select_folder", %{"folder-uuid" => sub.uuid})
        hook(view, "select_all")
      end)

      refute has_element?(view, ~s(#pick [data-selected="true"]))
      refute has_element?(view, ~s(#pick [phx-click="delete_selected"]))
      confirm(view)
      assert_receive {:picked, "pick", []}
    end
  end

  describe "a browser that is not a picker, with folder_actions: false" do
    defp files_view(conn, ctx) do
      open(conn, ctx, %{"browsers" => ["files"], "opts" => %{files_folder_actions: false}})
    end

    test "files keep their selection gestures; nothing takes a drag move", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      sub = folder!("Kitchen", ctx.scope)
      view = files_view(conn, ctx)

      assert has_element?(view, ~s(#files [data-draggable-file="#{a.uuid}"]))
      assert has_element?(view, "#files [data-box-area]")
      refute has_element?(view, "#files [data-draggable-folder]")
      refute has_element?(view, ~s(#files [data-drop-folder="#{sub.uuid}"]))
      refute has_element?(view, "#media-browser-sidebar [data-drop-folder]")
      refute has_element?(view, "#files [data-drop-trash]")
    end

    test "select all and a box take the files, never a folder", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      b = file!(ctx.scope)
      sub = folder!("Kitchen", ctx.scope)
      view = files_view(conn, ctx)

      hook(view, "toggle_select_mode", %{}, "files")
      html = hook(view, "select_all", %{}, "files")
      assert html =~ "2 selected"

      hook(view, "deselect_all", %{}, "files")

      html =
        hook(
          view,
          "box_select",
          %{"files" => [a.uuid, b.uuid], "folders" => [sub.uuid], "additive" => false},
          "files"
        )

      assert html =~ "2 selected"

      refute has_element?(
               view,
               ~s(#files [data-selected="true"] [phx-value-folder-uuid="#{sub.uuid}"])
             )
    end

    test "a long press on a folder selects nothing", %{conn: conn} = ctx do
      sub = folder!("Kitchen", ctx.scope)
      view = files_view(conn, ctx)

      capture_log(fn ->
        hook(view, "long_press_select", %{"type" => "folder", "uuid" => sub.uuid}, "files")
      end)

      refute has_element?(view, ~s(#files [data-selected="true"]))
    end
  end

  describe "the upload state follows the browser's own events" do
    test "an event that leaves nothing in flight starts the idle check" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          id: "p",
          picker: true,
          picker_uploading: true,
          upload_process_queue: [],
          pending_batch: []
        }
      }

      {:noreply, socket} = MediaBrowser.handle_event("noop", %{}, socket)
      assert socket.assigns.picker_idle_check
    end
  end

  describe "a picker that gets its upload after the first render" do
    test "registers for the picker's upload when it appears", %{conn: conn} = ctx do
      view = open(conn, ctx, %{"uploads_on" => false})

      refute MapSet.member?(
               :sys.get_state(view.pid).socket.assigns[:media_picker_ids] || MapSet.new(),
               "pick"
             )

      render_click(view, "uploads_on")
      render(view)
      assert MapSet.member?(:sys.get_state(view.pid).socket.assigns.media_picker_ids, "pick")
    end
  end

  describe "a second Confirm" do
    test "reports the pick once", %{conn: conn} = ctx do
      a = file!(ctx.scope)
      view = open(conn, ctx)

      click_file(view, a)
      confirm(view)
      confirm(view)

      assert_receive {:picked, "pick", [_]}
      refute_receive {:picked, "pick", _}, 100
    end

    test "after the pick changed, Confirm reports again", %{conn: conn} = ctx do
      [a, b] = for _ <- 1..2, do: file!(ctx.scope)
      view = open(conn, ctx)

      click_file(view, a)
      confirm(view)
      click_file(view, b)
      confirm(view)

      assert_receive {:picked, "pick", [_]}
      assert_receive {:picked, "pick", [_, _]}
    end
  end

  # ---------------------------------------------------------------------------
  # DOM ids
  # ---------------------------------------------------------------------------

  describe "DOM ids" do
    test "a picker beside another browser shares no id with it", %{conn: conn} = ctx do
      sub = folder!("Kitchen", ctx.scope)
      file!(ctx.scope)
      file!(sub)
      view = open(conn, ctx, %{"browsers" => ["files", "pick"]})

      html = render(view)
      all = ids(html)
      assert all -- Enum.uniq(all) == []
      assert "pick-media-browser-sidebar" in all
      assert "pick-folder-drop-upload-form" in all
      assert "media-browser-sidebar" in all, "the other browser keeps the ids it always had"
      assert "folder-drop-upload-form" in all
    end

    test "the picker's search, new-folder and header ids carry its id", %{conn: conn} = ctx do
      sub = folder!("Kitchen", ctx.scope)
      view = open(conn, ctx)

      hook(view, "toggle_search")
      assert has_element?(view, "#pick-media-search-input")

      hook(view, "open_new_folder_modal")
      assert has_element?(view, "#pick-new-folder-name-input")

      open_folder(view, sub)
      hook(view, "start_edit_folder_header", %{"folder-uuid" => sub.uuid})
      assert has_element?(view, "#pick-folder-header-form")
      assert has_element?(view, ~s(label[for="pick-folder-header-name"]))
      assert has_element?(view, "#pick-folder-header-name")
      assert has_element?(view, ~s(button[form="pick-folder-header-form"]))
    end
  end
end
