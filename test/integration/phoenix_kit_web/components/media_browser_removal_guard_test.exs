defmodule PhoenixKitWeb.Components.MediaBrowserRemovalGuardTest do
  @moduledoc """
  The removal guard (`config :phoenix_kit, :file_removal_guard, Mod`, or the
  browser's `removal_guard` attribute): every media browser event that can make
  a file disappear — trash a file (tile, kebab, viewer, drag), delete for good,
  delete a selection, trash or delete a folder, empty the trash — asks the
  module where the files are in use, and the person on a server dialog. A file
  only unlinked or re-homed is not asked about. With no guard the browser
  behaves as it always did.
  """

  use PhoenixKitWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Components.MediaBrowser

  @state_key :removal_guard_test

  defmodule TestRemovalGuard do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Storage.RemovalGuard

    defp state, do: Application.get_env(:phoenix_kit, :removal_guard_test, %{})

    @impl true
    def places(uuids, ctx) do
      state = state()
      send(state.pid, {:places, uuids, ctx})
      if state[:raise], do: raise("sentinel-#{inspect(uuids)}")
      if state[:sleep], do: Process.sleep(state[:sleep])
      if state[:kill], do: Process.exit(self(), :kill)

      if state[:report_locale] do
        send(
          state.pid,
          {:locale, Gettext.get_locale(PhoenixKitWeb.Gettext), Gettext.get_locale()}
        )
      end

      if hook = state[:on_places], do: hook.()

      if fun = state[:answer] do
        fun.(uuids)
      else
        for uuid <- uuids, place = Map.get(state[:places] || %{}, uuid) do
          Map.put(place, :file_uuid, uuid)
        end
      end
    end

    @impl true
    def release(uuids, ctx) do
      state = state()
      send(state.pid, {:release, uuids, ctx})

      case state[:release] do
        :raise ->
          raise "release-sentinel"

        {:error, _} = error ->
          error

        _ ->
          left = Map.drop(state[:places] || %{}, uuids)
          Application.put_env(:phoenix_kit, :removal_guard_test, %{state | places: left})
          :ok
      end
    end

    @impl true
    def release_label(_ctx) do
      state = state()
      if Map.has_key?(state, :label), do: state.label, else: "Unlink everywhere"
    end
  end

  # No `release` at all.
  defmodule ReadOnlyGuard do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Storage.RemovalGuard

    @impl true
    def places(uuids, _ctx) do
      for uuid <- uuids, do: %{file_uuid: uuid, label: "Order 1", detail: nil, href: "/o/1"}
    end
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
       |> tap(fn _ -> put_locale((session["opts"] || %{})[:locale]) end)
       |> assign(scope: session["scope"], opts: session["opts"] || %{})}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={MediaBrowser}
        id="mb"
        scope_folder_id={@scope}
        picker={Map.get(@opts, :picker, false)}
        readonly={Map.get(@opts, :readonly, false)}
        removal_guard={Map.get(@opts, :removal_guard)}
        phoenix_kit_current_scope={Map.get(@opts, :scope_attr)}
        own_files_only={Map.get(@opts, :own_files_only)}
        parent_uploads={@uploads}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />
      """
    end

    defp put_locale(nil), do: :ok

    defp put_locale(locale) do
      Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
      Gettext.put_locale(locale)
    end

    def handle_event("validate", _params, socket), do: {:noreply, socket}

    def handle_info({MediaBrowser, _, _} = msg, socket),
      do: MediaBrowser.handle_parent_info(msg, socket)

    def handle_info(_msg, socket), do: {:noreply, socket}
  end

  setup do
    Application.put_env(:phoenix_kit, @state_key, %{pid: self(), places: %{}})
    Application.put_env(:phoenix_kit, :file_removal_guard, TestRemovalGuard)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, @state_key)
      Application.delete_env(:phoenix_kit, :file_removal_guard)
    end)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{email: "removal-#{n}@example.com", password: "ValidPassword123!"})

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

  defp file!(folder, name \\ nil, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    name = name || "photo-#{n}.png"

    Repo.insert!(
      struct(
        %StorageFile{
          original_file_name: name,
          file_name: name,
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          file_checksum: "removal-#{n}",
          user_file_checksum: "removal-u-#{n}",
          size: 1,
          status: "active",
          folder_uuid: folder && folder.uuid,
          user_uuid: Process.get(:owner_uuid)
        },
        attrs
      )
    )
  end

  defp trashed!(folder, name \\ nil) do
    file = file!(folder, name)
    {:ok, trashed} = Storage.trash_file(file)
    trashed
  end

  defp attach!(file, label \\ "Order 7", opts \\ []) do
    state = Application.get_env(:phoenix_kit, @state_key)
    place = %{label: label, detail: opts[:detail], href: opts[:href]}

    Application.put_env(:phoenix_kit, @state_key, %{
      state
      | places: Map.put(state.places, file.uuid, place)
    })
  end

  defp guard_state(changes) do
    state = Application.get_env(:phoenix_kit, @state_key)
    Application.put_env(:phoenix_kit, @state_key, Map.merge(state, changes))
  end

  defp open(conn, ctx, opts \\ %{}) do
    {:ok, view, _html} =
      live_isolated(conn, Host,
        session: %{"scope" => ctx.scope.uuid, "user" => ctx.user, "opts" => opts}
      )

    view
  end

  defp hook(view, event, params \\ %{}),
    do: view |> element("#mb") |> render_hook(event, params)

  defp status(file),
    do: Repo.get(StorageFile, file.uuid) && Repo.get(StorageFile, file.uuid).status

  # The browser's flash (a component's `put_flash` is held in its own assigns).
  defp flash(view) do
    {components, _, _} = :sys.get_state(view.pid).components

    components
    |> Map.values()
    |> Enum.find_value("", fn
      {MediaBrowser, _id, assigns, _private, _prints} ->
        assigns.flash |> Map.values() |> Enum.join(" ")

      {MediaBrowser, assigns, _private, _prints} ->
        assigns.flash |> Map.values() |> Enum.join(" ")

      _ ->
        nil
    end)
  end

  defp modal?(view), do: has_element?(view, "#mb-removal-modal")

  defp press(view, what),
    do: view |> element("#mb-removal-#{what}") |> render_click()

  defp trash_view(view),
    do: view |> element("[phx-click='toggle_trash_filter']") |> render_click()

  defp refute_asked, do: refute_received({:places, _, _})

  describe "without a guard the browser is as it was" do
    test "no module configured: trash_file acts at once, no dialog, client confirms stay",
         %{
           conn: conn
         } = ctx do
      Application.delete_env(:phoenix_kit, :file_removal_guard)
      file = file!(ctx.scope)
      gone = trashed!(ctx.scope)
      view = open(conn, ctx)

      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      refute modal?(view)
      assert status(file) == "trashed"
      assert flash(view) =~ "File moved to trash"
      refute_asked()

      html = trash_view(view)
      assert html =~ "data-confirm"
      assert html =~ "Permanently delete"
      assert Repo.get(StorageFile, gone.uuid)
    end

    test "removal_guard={false} switches a configured module off for one browser",
         %{conn: conn} = ctx do
      file = file!(ctx.scope)
      attach!(file)
      view = open(conn, ctx, %{removal_guard: false})

      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      refute modal?(view)
      assert status(file) == "trashed"
      refute_asked()
      assert trash_view(view) =~ "data-confirm"
    end

    test "a configured module drops the client confirms (one question, on the server)",
         %{
           conn: conn
         } = ctx do
      trashed!(ctx.scope)
      view = open(conn, ctx)

      html = trash_view(view)

      refute html =~ "Permanently delete 1 trashed file?"
      refute html =~ "Permanently delete all"
      refute html =~ "This cannot be undone.\""
      assert has_element?(view, "[phx-click='empty_trash']")
      refute has_element?(view, "[phx-click='empty_trash'][data-confirm]")
      refute has_element?(view, "[phx-click='delete_file'][data-confirm]")
    end
  end

  describe "trash_file" do
    test "no place: a dialog lists the file, and the confirmation trashes it",
         %{conn: conn} = ctx do
      file = file!(ctx.scope, "kitchen.png")
      view = open(conn, ctx)

      html = hook(view, "trash_file", %{"file_uuid" => file.uuid})

      assert modal?(view)
      assert html =~ "Move 1 file to trash?"
      assert html =~ "kitchen.png"
      assert status(file) == "active", "nothing happens before the confirmation"
      assert_received {:places, [uuid], %{action: :trash_file}}
      assert uuid == file.uuid

      press(view, "confirm")

      refute modal?(view)
      assert status(file) == "trashed"
      assert flash(view) =~ "File moved to trash"
    end

    test "Cancel closes the dialog and removes nothing", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx)
      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      press(view, "cancel")

      refute modal?(view)
      assert status(file) == "active"
    end

    test "the tile menu's Move to Trash (delete_file on a live file) asks too",
         %{conn: conn} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx)

      view
      |> element(~s(#mb [phx-click="delete_file"][phx-value-file-uuid="#{file.uuid}"]))
      |> render_click()

      assert modal?(view)
      assert_received {:places, _, %{action: :delete_file}}
      press(view, "confirm")
      assert status(file) == "trashed"
    end

    test "a file in use: the places are listed, nothing is removed, no confirm button",
         %{
           conn: conn
         } = ctx do
      file = file!(ctx.scope, "kitchen.png")
      attach!(file, "Order 7", detail: "Kitchen", href: "/orders/7")
      view = open(conn, ctx)

      html = hook(view, "trash_file", %{"file_uuid" => file.uuid})

      assert html =~ "Cannot delete: the file is in use"
      assert html =~ "Order 7"
      assert html =~ "Kitchen"
      assert html =~ ~s(href="/orders/7")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(rel="noopener")
      refute has_element?(view, "#mb-removal-confirm")
      assert status(file) == "active"
    end

    test "a place the person may not see shows no label, detail or link", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      state = Application.get_env(:phoenix_kit, @state_key)

      guard_state(%{
        places: Map.put(state.places, file.uuid, %{label: nil, detail: "secret", href: "/secret"})
      })

      view = open(conn, ctx)

      html = hook(view, "trash_file", %{"file_uuid" => file.uuid})

      assert html =~ "Not available to you"
      refute html =~ "secret"
      refute has_element?(view, ~s(#mb-removal-places a))
    end

    test "a javascript: href is not made a link", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      attach!(file, "Order 7", href: "javascript:alert(1)")
      view = open(conn, ctx)

      html = hook(view, "trash_file", %{"file_uuid" => file.uuid})

      assert html =~ "Order 7"
      refute html =~ "javascript:"
    end

    test "release frees the file, the guard is asked again, and the confirmation removes it",
         %{
           conn: conn
         } = ctx do
      file = file!(ctx.scope)
      attach!(file)
      view = open(conn, ctx)
      hook(view, "trash_file", %{"file_uuid" => file.uuid})
      assert has_element?(view, "#mb-removal-release", "Unlink everywhere")

      html = press(view, "release")

      assert_received {:release, [uuid], %{action: :trash_file}}
      assert uuid == file.uuid
      assert html =~ "Move 1 file to trash?"
      assert status(file) == "active", "released is not removed: the person still has to confirm"

      press(view, "confirm")
      assert status(file) == "trashed"
    end

    test "release_label nil: no button", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      attach!(file)
      guard_state(%{label: nil})
      view = open(conn, ctx)

      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      assert has_element?(view, "#mb-removal-places")
      refute has_element?(view, "#mb-removal-release")
    end

    test "a module without release/2 offers no button", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx, %{removal_guard: ReadOnlyGuard})

      html = hook(view, "trash_file", %{"file_uuid" => file.uuid})

      assert html =~ "Order 1"
      refute has_element?(view, "#mb-removal-release")
    end

    test "release answering {:error, message} shows the message; the file stays",
         %{conn: conn} = ctx do
      file = file!(ctx.scope)
      attach!(file)
      guard_state(%{release: {:error, "Order 7 is locked"}})
      view = open(conn, ctx)
      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      html = press(view, "release")

      assert html =~ "Order 7 is locked"
      assert has_element?(view, "#mb-removal-places")
      assert status(file) == "active"
    end

    test "release answering {:error, other} shows a generic text", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      attach!(file)
      guard_state(%{release: {:error, :boom}})
      view = open(conn, ctx)
      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      html = press(view, "release")

      assert html =~ "The files could not be freed. Nothing was removed."
      refute html =~ "boom"
    end

    test "a release that raises: generic text, nothing removed, the log holds no uuid",
         %{
           conn: conn
         } = ctx do
      file = file!(ctx.scope)
      attach!(file)
      guard_state(%{release: :raise})
      view = open(conn, ctx)
      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      log = capture_log(fn -> press(view, "release") end)

      assert render(view) =~ "The files could not be freed. Nothing was removed."
      assert status(file) == "active"
      assert log =~ "TestRemovalGuard.release failed"
      refute log =~ file.uuid
      refute log =~ "release-sentinel"
    end

    test "a places that raises: nothing is removed, the dialog says so, the log names no request data",
         %{
           conn: conn
         } = ctx do
      file = file!(ctx.scope)
      guard_state(%{raise: true})
      view = open(conn, ctx)

      log = capture_log(fn -> hook(view, "trash_file", %{"file_uuid" => file.uuid}) end)

      assert modal?(view)
      assert render(view) =~ "The files could not be checked, so nothing was removed."
      refute has_element?(view, "#mb-removal-confirm")
      assert status(file) == "active"
      assert log =~ "TestRemovalGuard.places failed"
      refute log =~ file.uuid
      refute log =~ "sentinel"
    end

    test "an answer that is not the contract fails closed", %{conn: conn} = ctx do
      file = file!(ctx.scope)

      defmodule WrongShape do
        @moduledoc false
        def places(_uuids, _ctx), do: :nope
      end

      view = open(conn, ctx, %{removal_guard: WrongShape})

      capture_log(fn -> hook(view, "trash_file", %{"file_uuid" => file.uuid}) end)

      assert render(view) =~ "The files could not be checked"
      assert status(file) == "active"
    end

    test "ctx.scope is the attribute when given, the user's scope otherwise",
         %{conn: conn, user: user} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx)
      hook(view, "trash_file", %{"file_uuid" => file.uuid})
      assert_received {:places, _, %{scope: %Scope{} = scope}}
      assert Scope.user_uuid(scope) == user.uuid

      narrowed = %Scope{} = Scope.for_user(user)
      narrowed = %{narrowed | cached_roles: ["Narrowed"]}
      view = open(conn, ctx, %{scope_attr: narrowed})
      hook(view, "trash_file", %{"file_uuid" => file.uuid})
      assert_received {:places, _, %{scope: %Scope{cached_roles: ["Narrowed"]}}}
    end
  end

  describe "only what disappears is asked about" do
    test "a file only linked into the viewed folder is unlinked, the guard is not asked",
         %{
           conn: conn
         } = ctx do
      home = folder!("Home")
      file = file!(home)
      {:ok, _} = Storage.create_folder_link(ctx.scope.uuid, file.uuid)
      view = open(conn, ctx)
      attach!(file)

      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      refute modal?(view)
      assert flash(view) =~ "File removed from this folder"
      assert status(file) == "active"
      refute_asked()
    end

    test "a file linked into another live folder is re-homed, the guard is not asked",
         %{
           conn: conn
         } = ctx do
      other = folder!("Other")
      file = file!(ctx.scope)
      {:ok, _} = Storage.create_folder_link(other.uuid, file.uuid)
      view = open(conn, ctx)

      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      refute modal?(view)
      assert Repo.get(StorageFile, file.uuid).folder_uuid == other.uuid
      refute_asked()
    end

    test "Delete all orphaned does not pass the guard", %{conn: conn} = ctx do
      view = open(conn, ctx)

      hook(view, "delete_all_orphaned")

      refute modal?(view)
      refute_asked()
    end
  end

  describe "trash view" do
    test "Delete Permanently on a trashed file asks, then deletes", %{conn: conn} = ctx do
      file = trashed!(ctx.scope, "old.png")
      view = open(conn, ctx)
      trash_view(view)

      html = hook(view, "delete_file", %{"file-uuid" => file.uuid})

      assert html =~ "Delete 1 file for good?"
      assert html =~ "This cannot be undone."
      assert_received {:places, _, %{action: :delete_file}}
      assert Repo.get(StorageFile, file.uuid)

      press(view, "confirm")
      assert is_nil(Repo.get(StorageFile, file.uuid))
    end

    test "Empty trash skips what is attached: deleted N, kept M", %{conn: conn} = ctx do
      one = trashed!(ctx.scope)
      two = trashed!(ctx.scope)
      kept = trashed!(ctx.scope, "attached.png")
      attach!(kept)
      view = open(conn, ctx)
      trash_view(view)

      html = hook(view, "empty_trash")

      assert html =~ "Delete 2 files for good?"
      assert html =~ "1 file is in use and stays in the trash"
      assert html =~ "attached.png"
      assert_received {:places, uuids, %{action: :empty_trash}}
      assert length(uuids) == 3

      press(view, "confirm")

      assert is_nil(Repo.get(StorageFile, one.uuid))
      assert is_nil(Repo.get(StorageFile, two.uuid))
      assert status(kept) == "trashed"
      assert flash(view) =~ "2 deleted, 1 kept: in use"
    end

    test "Empty trash with every file attached deletes nothing and has no confirm",
         %{conn: conn} = ctx do
      kept = trashed!(ctx.scope)
      attach!(kept)
      view = open(conn, ctx)
      trash_view(view)

      html = hook(view, "empty_trash")

      assert html =~ "Cannot delete: the file is in use"
      refute has_element?(view, "#mb-removal-confirm")
      assert status(kept) == "trashed"
    end

    test "Empty trash: a file attached after the dialog is shown is asked again, not deleted",
         %{
           conn: conn
         } = ctx do
      one = trashed!(ctx.scope)
      two = trashed!(ctx.scope)
      view = open(conn, ctx)
      trash_view(view)
      hook(view, "empty_trash")
      attach!(two)

      html = press(view, "confirm")

      assert html =~ "The files changed. Check the list and confirm again."
      assert Repo.get(StorageFile, one.uuid), "the dialog shown was about both"
      assert Repo.get(StorageFile, two.uuid)

      press(view, "confirm")
      assert is_nil(Repo.get(StorageFile, one.uuid))
      assert status(two) == "trashed"
    end

    test "deleting a selection in the trash skips what is attached", %{conn: conn} = ctx do
      one = trashed!(ctx.scope)
      kept = trashed!(ctx.scope)
      attach!(kept)
      view = open(conn, ctx)
      trash_view(view)
      hook(view, "toggle_select_mode")
      hook(view, "toggle_select", %{"file-uuid" => one.uuid})
      hook(view, "toggle_select", %{"file-uuid" => kept.uuid})

      hook(view, "delete_selected")
      press(view, "confirm")

      assert is_nil(Repo.get(StorageFile, one.uuid))
      assert status(kept) == "trashed"
      assert flash(view) =~ "1 deleted, 1 kept: in use"
    end

    test "delete_folder in the trash view asks over the subtree and deletes the folder",
         %{
           conn: conn
         } = ctx do
      folder = folder!("Old", ctx.scope)
      inside = file!(folder)
      {:ok, _} = Storage.trash_folder(folder)
      view = open(conn, ctx)
      trash_view(view)

      hook(view, "delete_folder", %{"id" => folder.uuid})

      assert modal?(view)
      assert_received {:places, [uuid], %{action: :delete_folder, folder_uuid: folder_uuid}}
      assert uuid == inside.uuid
      assert folder_uuid == folder.uuid

      press(view, "confirm")
      assert is_nil(Storage.get_folder(folder.uuid))
      assert is_nil(Repo.get(StorageFile, inside.uuid))
    end
  end

  describe "folders" do
    test "trash_folder asks for the files of the whole subtree, and a link inside it saves none",
         %{
           conn: conn
         } = ctx do
      a = folder!("A", ctx.scope)
      sub = folder!("Sub", a)
      x = file!(a, "x.png")
      y = file!(sub, "y.png")
      {:ok, _} = Storage.create_folder_link(sub.uuid, x.uuid)
      view = open(conn, ctx)

      html = hook(view, "trash_folder", %{"folder_uuid" => a.uuid})

      assert html =~ "Move 1 folder and its contents to trash?"
      assert_received {:places, uuids, %{action: :trash_folder, folder_uuid: folder_uuid}}
      assert Enum.sort(uuids) == Enum.sort([x.uuid, y.uuid])
      assert folder_uuid == a.uuid
      assert status(x) == "active"

      press(view, "confirm")
      assert status(x) == "trashed"
      assert status(y) == "trashed"
      assert Storage.get_folder(a.uuid).trashed_at
    end

    test "a file linked from outside the subtree is re-homed: not asked about",
         %{conn: conn} = ctx do
      a = folder!("A", ctx.scope)
      out = folder!("Out", ctx.scope)
      x = file!(a)
      y = file!(a)
      {:ok, _} = Storage.create_folder_link(out.uuid, x.uuid)
      view = open(conn, ctx)

      hook(view, "trash_folder", %{"folder_uuid" => a.uuid})

      assert_received {:places, [uuid], _}
      assert uuid == y.uuid
      refute_received {:places, _, _}
    end

    test "a folder whose files are in use is not trashed", %{conn: conn} = ctx do
      a = folder!("A", ctx.scope)
      x = file!(a)
      attach!(x)
      view = open(conn, ctx)

      html = hook(view, "trash_folder", %{"folder_uuid" => a.uuid})

      assert html =~ "Cannot delete: the file is in use"
      assert is_nil(Storage.get_folder(a.uuid).trashed_at)
      assert status(x) == "active"
    end

    test "an empty folder is still confirmed, with no call to the guard", %{conn: conn} = ctx do
      a = folder!("A", ctx.scope)
      view = open(conn, ctx)

      html = hook(view, "delete_folder", %{"id" => a.uuid})

      assert html =~ "Move 1 folder and its contents to trash?"
      refute_asked()
      assert is_nil(Storage.get_folder(a.uuid).trashed_at)

      press(view, "confirm")
      assert Storage.get_folder(a.uuid).trashed_at
    end

    test "delete_selected with a folder and a file asks over both", %{conn: conn} = ctx do
      a = folder!("A", ctx.scope)
      inside = file!(a)
      loose = file!(ctx.scope)
      view = open(conn, ctx)
      hook(view, "toggle_select_mode")
      hook(view, "toggle_select", %{"file-uuid" => loose.uuid})
      hook(view, "toggle_select_folder", %{"folder-uuid" => a.uuid})

      hook(view, "delete_selected")

      assert_received {:places, uuids, %{action: :delete_selected}}
      assert Enum.sort(uuids) == Enum.sort([inside.uuid, loose.uuid])

      press(view, "confirm")
      assert status(inside) == "trashed"
      assert status(loose) == "trashed"
      assert Storage.get_folder(a.uuid).trashed_at
    end
  end

  describe "the viewer" do
    test "Move to trash in a picker's viewer asks in a dialog drawn above the viewer",
         %{conn: conn} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx, %{picker: true})

      view
      |> element(~s(#mb [phx-click="view_file"][phx-value-file-uuid="#{file.uuid}"]))
      |> render_click()

      assert has_element?(view, "#mb-viewer-modal")

      view
      |> element(~s(#mb-viewer-modal [phx-click="trash_file"]))
      |> render_click()

      assert has_element?(view, ~s(#mb-removal-modal[popover="manual"]))
      assert has_element?(view, "#mb-viewer-modal"), "the viewer is still open under it"
      assert status(file) == "active"

      press(view, "cancel")

      assert has_element?(view, "#mb-viewer-modal"),
             "closing the dialog does not close the viewer"

      view
      |> element(~s(#mb-viewer-modal [phx-click="trash_file"]))
      |> render_click()

      press(view, "confirm")
      assert status(file) == "trashed"
      refute has_element?(view, "#mb-viewer-modal")
    end

    test "Delete forever in the viewer of a trashed file: no client confirm, a server dialog",
         %{
           conn: conn
         } = ctx do
      file = trashed!(ctx.scope)
      view = open(conn, ctx)
      trash_view(view)

      view
      |> element(~s(#mb [phx-click="click_file"][phx-value-file-uuid="#{file.uuid}"]))
      |> render_click()

      assert has_element?(view, ~s(#mb-viewer-modal [phx-click="delete_file"]))
      refute has_element?(view, ~s(#mb-viewer-modal [phx-click="delete_file"][data-confirm]))

      view |> element(~s(#mb-viewer-modal [phx-click="delete_file"])) |> render_click()
      assert modal?(view)
      press(view, "confirm")
      assert is_nil(Repo.get(StorageFile, file.uuid))
    end
  end

  describe "the dialog's events" do
    test "a confirmation with another token, or none pending, does nothing",
         %{conn: conn} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx)

      hook(view, "removal_confirm", %{"token" => "nope"})
      assert status(file) == "active"

      hook(view, "trash_file", %{"file_uuid" => file.uuid})
      hook(view, "removal_confirm", %{"token" => "forged"})
      hook(view, "removal_release", %{"token" => "forged"})

      assert modal?(view)
      assert status(file) == "active"
      refute_received {:release, _, _}
    end

    test "a readonly browser refuses the dialog's events", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx, %{readonly: true})

      log =
        capture_log(fn ->
          hook(view, "trash_file", %{"file_uuid" => file.uuid})
          hook(view, "removal_confirm", %{"token" => "x"})
          hook(view, "removal_release", %{"token" => "x"})
        end)

      refute modal?(view)
      assert status(file) == "active"
      assert log =~ "removal_confirm"
      refute_asked()
    end

    test "the confirmation goes through the gates again: another user's file is refused",
         %{conn: conn} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx, %{own_files_only: Ecto.UUID.generate()})

      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      assert flash(view) =~ "You can only change files you uploaded"
      refute modal?(view)
      assert status(file) == "active"
      refute_asked()
    end

    test "the module's own list of writes holds the dialog's events" do
      assert "removal_confirm" in MediaBrowser.write_events()
      assert "removal_release" in MediaBrowser.write_events()
      refute "removal_cancel" in MediaBrowser.write_events()
    end
  end

  describe "review fixes" do
    test "the confirmation judges the gates again: a file rewritten to another owner is not removed",
         %{conn: conn, user: user} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx, %{own_files_only: user.uuid})
      hook(view, "trash_file", %{"file_uuid" => file.uuid})
      assert modal?(view)

      {:ok, other} =
        Auth.register_user(%{
          email: "other-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid),
        set: [user_uuid: other.uuid]
      )

      capture_log(fn -> press(view, "confirm") end)

      assert status(file) == "active"
      assert flash(view) =~ "You can only change files you uploaded"
    end

    test "a file that reaches the trash while the guard answers is not deleted",
         %{conn: conn} = ctx do
      shown = trashed!(ctx.scope)
      kept = trashed!(ctx.scope)
      attach!(kept)
      view = open(conn, ctx)
      trash_view(view)
      hook(view, "empty_trash")
      test_pid = self()

      guard_state(%{
        on_places: fn ->
          late = trashed!(ctx.scope)
          send(test_pid, {:late, late.uuid})
        end
      })

      press(view, "confirm")

      assert_received {:late, late_uuid}
      assert is_nil(Repo.get(StorageFile, shown.uuid))
      assert Repo.get(StorageFile, late_uuid), "the file the dialog never listed stays"
      assert status(kept) == "trashed"
    end

    test "a slow guard fails closed after the timeout", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      Application.put_env(:phoenix_kit, :file_removal_guard_timeout, 50)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :file_removal_guard_timeout) end)
      guard_state(%{sleep: 1_000})
      view = open(conn, ctx)

      log = capture_log(fn -> hook(view, "trash_file", %{"file_uuid" => file.uuid}) end)

      assert render(view) =~ "The files could not be checked, so nothing was removed."
      assert status(file) == "active"
      assert log =~ "timed out"
    end

    test "the dialog's events without a token, or with another, do nothing",
         %{conn: conn} = ctx do
      file = file!(ctx.scope)
      view = open(conn, ctx)
      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      for event <- ~w(removal_confirm removal_release removal_cancel) do
        hook(view, event, %{})
        hook(view, event, %{"token" => "other"})
      end

      assert modal?(view)
      assert status(file) == "active"

      press(view, "cancel")
      refute modal?(view)
    end

    test "a place for a uuid in another case still holds the file", %{conn: conn} = ctx do
      file = file!(ctx.scope)

      guard_state(%{
        answer: fn [uuid] ->
          [%{file_uuid: String.upcase(uuid), label: "Order 9", detail: nil, href: nil}]
        end
      })

      view = open(conn, ctx)

      html = hook(view, "trash_file", %{"file_uuid" => file.uuid})

      assert html =~ "Cannot delete: the file is in use"
      assert status(file) == "active"
    end

    test "a place for a file that was not asked about breaks the contract: fail closed",
         %{
           conn: conn
         } = ctx do
      file = file!(ctx.scope)

      guard_state(%{
        answer: fn _ -> [%{file_uuid: Ecto.UUID.generate(), label: "Order 9"}] end
      })

      view = open(conn, ctx)

      capture_log(fn -> hook(view, "trash_file", %{"file_uuid" => file.uuid}) end)

      assert render(view) =~ "The files could not be checked, so nothing was removed."
      refute has_element?(view, "#mb-removal-confirm")
      assert status(file) == "active"
    end

    test "a guard killed from outside fails closed and the page lives", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      guard_state(%{kill: true})
      view = open(conn, ctx)

      log = capture_log(fn -> hook(view, "trash_file", %{"file_uuid" => file.uuid}) end)

      assert Process.alive?(view.pid)
      assert render(view) =~ "The files could not be checked, so nothing was removed."
      assert status(file) == "active"
      assert log =~ "TestRemovalGuard.places failed"
    end

    test "the guard runs with the page's locale", %{conn: conn} = ctx do
      file = file!(ctx.scope)
      guard_state(%{report_locale: true})
      view = open(conn, ctx, %{locale: "ru"})

      hook(view, "trash_file", %{"file_uuid" => file.uuid})

      assert_received {:locale, "ru", "ru"}
    end
  end
end
