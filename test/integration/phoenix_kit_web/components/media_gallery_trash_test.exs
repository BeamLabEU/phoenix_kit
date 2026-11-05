defmodule PhoenixKitWeb.Components.MediaGalleryTrashTest do
  @moduledoc """
  The gallery tile's "Move to trash" (⋮ menu): it goes through the same removal
  guard and dialog the media browser uses. A file that is not in use is trashed
  after the dialog's confirmation; a file in use lists its places and offers the
  host's release; either way a trashed file leaves the selection and the host is
  told with `{:changed, uuids}`. The server judges every event again: a file
  that is not in the selection, one the person may not change, a readonly
  gallery.
  """

  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWeb.Components.MediaGallery

  @state_key :gallery_trash_test

  defmodule TestGuard do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Storage.RemovalGuard

    defp state, do: Application.get_env(:phoenix_kit, :gallery_trash_test, %{})

    @impl true
    def places(uuids, ctx) do
      state = state()
      send(state.pid, {:places, uuids, ctx})
      if state[:raise], do: raise("boom")

      for uuid <- uuids, place = Map.get(state[:places] || %{}, uuid) do
        Map.put(place, :file_uuid, uuid)
      end
    end

    @impl true
    def release(uuids, ctx) do
      state = state()
      send(state.pid, {:release, uuids, ctx})
      if state[:release_raise], do: raise("release boom")

      case state[:release_error] do
        nil ->
          Application.put_env(:phoenix_kit, :gallery_trash_test, %{state | places: %{}})
          :ok

        message ->
          {:error, message}
      end
    end

    @impl true
    def release_label(_ctx), do: "Unpin everywhere"
  end

  # Reads places only: no release to offer.
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

    alias PhoenixKitWeb.Components.MediaGallery

    def mount(_params, session, socket) do
      {:ok,
       assign(socket,
         user: session["user"],
         selected: session["selected"],
         opts: session["opts"] || %{},
         test_pid: session["test_pid"]
       )}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={MediaGallery}
        id="g"
        selected={@selected}
        phoenix_kit_current_user={@user}
        readonly={Map.get(@opts, :readonly, false)}
        removal_guard={Map.get(@opts, :removal_guard)}
      />
      """
    end

    def handle_info({MediaGallery, "g", {:changed, uuids}}, socket) do
      send(socket.assigns.test_pid, {:changed, uuids})
      {:noreply, assign(socket, :selected, uuids)}
    end

    # The test changes what the host passes down between two events.
    def handle_info({:host, :user, user}, socket), do: {:noreply, assign(socket, :user, user)}

    def handle_info({:host, :selected, uuids}, socket),
      do: {:noreply, assign(socket, :selected, uuids)}

    def handle_info({:host, :readonly, value}, socket),
      do: {:noreply, assign(socket, :opts, Map.put(socket.assigns.opts, :readonly, value))}

    def handle_info(_msg, socket), do: {:noreply, socket}
  end

  setup do
    Application.put_env(:phoenix_kit, @state_key, %{pid: self(), places: %{}})
    Application.put_env(:phoenix_kit, :file_removal_guard, TestGuard)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, @state_key)
      Application.delete_env(:phoenix_kit, :file_removal_guard)
    end)

    n = System.unique_integer([:positive])

    # The first user of an install is its Owner: this one is just in front of
    # the person the tests act as, who is an ordinary user.
    {:ok, _first} =
      Auth.register_user(%{
        email: "gallery-first-#{n}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} =
      Auth.register_user(%{
        email: "gallery-trash-#{n}@example.com",
        password: "ValidPassword123!"
      })

    %{user: user}
  end

  defp file!(user, name \\ nil) do
    n = System.unique_integer([:positive])
    name = name || "photo-#{n}.png"

    Repo.insert!(%StorageFile{
      original_file_name: name,
      file_name: name,
      mime_type: "image/png",
      file_type: "image",
      ext: "png",
      file_checksum: "gallery-trash-#{n}",
      user_file_checksum: "gallery-trash-u-#{n}",
      size: 1,
      status: "active",
      user_uuid: user.uuid
    })
  end

  defp attach!(file, label \\ "Order 7") do
    state = Application.get_env(:phoenix_kit, @state_key)
    place = %{label: label, detail: nil, href: nil}

    Application.put_env(:phoenix_kit, @state_key, %{
      state
      | places: Map.put(state.places, file.uuid, place)
    })
  end

  defp guard_state(changes) do
    state = Application.get_env(:phoenix_kit, @state_key)
    Application.put_env(:phoenix_kit, @state_key, Map.merge(state, changes))
  end

  defp open(conn, ctx, selected, opts \\ %{}) do
    {:ok, view, _html} =
      live_isolated(conn, Host,
        session: %{
          "user" => ctx.user,
          "selected" => Enum.map(selected, & &1.uuid),
          "opts" => opts,
          "test_pid" => self()
        }
      )

    view
  end

  defp trash_item(file), do: "[data-role='trash-image-g-#{file.uuid}']"
  defp tile(file), do: "[data-id='#{file.uuid}']"
  defp modal?(view), do: has_element?(view, "#g-removal-modal")
  defp press(view, what), do: view |> element("#g-removal-#{what}") |> render_click()
  # An event from the open dialog's element, as a person could send it from a
  # console (`render_hook` needs a hooked element that targets the gallery).
  defp hook(view, event, params),
    do: view |> element("#g-removal-modal") |> render_hook(event, params)

  # What the host passes down changes while a dialog is open.
  defp host_sets(view, key, value) do
    send(view.pid, {:host, key, value})
    render(view)
  end

  defp other_user! do
    {:ok, other} =
      Auth.register_user(%{
        email: "gallery-other-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    other
  end

  # The file stops being in use: the confirmation would now be allowed to trash.
  defp attach_free(_file), do: guard_state(%{places: %{}})

  defp status(file), do: Repo.get(StorageFile, file.uuid).status

  defp token(view) do
    [_, token] = Regex.run(~r/id="g-removal-modal"[^>]*data-token="([^"]+)"/, render(view))
    token
  end

  describe "the menu" do
    test "offers Move to trash for a file the person uploaded", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      assert has_element?(view, trash_item(file))
      assert has_element?(view, "[data-role='remove-image-g-#{file.uuid}']")
    end

    test "has only Remove from selection for a file the person may not change",
         %{conn: conn} = ctx do
      {:ok, other} =
        Auth.register_user(%{
          email: "gallery-other-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      file = file!(other)
      view = open(conn, ctx, [file])

      assert has_element?(view, "[data-role='remove-image-g-#{file.uuid}']")
      refute has_element?(view, trash_item(file))
    end
  end

  describe "a file that is not in use" do
    test "the dialog asks, the confirmation trashes it and takes it out of the selection",
         %{conn: conn} = ctx do
      file = file!(ctx.user, "kitchen.png")
      keep = file!(ctx.user)
      view = open(conn, ctx, [file, keep])

      html = view |> element(trash_item(file)) |> render_click()

      assert modal?(view)
      assert html =~ "Move 1 file to trash?"
      assert html =~ "kitchen.png"
      assert status(file) == "active", "nothing happens before the confirmation"
      assert_received {:places, [uuid], %{action: :trash_file}}
      assert uuid == file.uuid
      refute_received {:changed, _}

      press(view, "confirm")

      refute modal?(view)
      assert status(file) == "trashed"
      assert_received {:changed, uuids}
      assert uuids == [keep.uuid]
      refute has_element?(view, tile(file))
      assert has_element?(view, tile(keep))
    end

    test "with no guard configured the dialog still asks first", %{conn: conn} = ctx do
      Application.delete_env(:phoenix_kit, :file_removal_guard)
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()

      assert modal?(view)
      assert status(file) == "active"
      refute_received {:places, _, _}

      press(view, "confirm")

      assert status(file) == "trashed"
      assert_received {:changed, []}
    end

    test "Cancel closes the dialog and changes nothing", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      press(view, "cancel")

      refute modal?(view)
      assert status(file) == "active"
      assert has_element?(view, tile(file))
      refute_received {:changed, _}
    end

    test "a confirmation naming another token does nothing", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      hook(view, "removal_confirm", %{"token" => "forged"})

      assert modal?(view)
      assert status(file) == "active"
    end

    test "a file put in use after the dialog was drawn is not trashed by the confirmation",
         %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      attach!(file)
      html = press(view, "confirm")

      assert status(file) == "active"
      assert modal?(view)
      assert html =~ "The files changed"
      assert html =~ "Order 7"
      refute has_element?(view, "#g-removal-confirm")
      refute_received {:changed, _}
    end
  end

  describe "a file in use" do
    test "lists the places, offers the release and removes nothing", %{conn: conn} = ctx do
      file = file!(ctx.user, "kitchen.png")
      attach!(file, "Order 7")
      view = open(conn, ctx, [file])

      html = view |> element(trash_item(file)) |> render_click()

      assert modal?(view)
      assert html =~ "Cannot delete: the file is in use"
      assert html =~ "kitchen.png"
      assert html =~ "Order 7"
      assert has_element?(view, "#g-removal-release", "Unpin everywhere")
      refute has_element?(view, "#g-removal-confirm")
      assert status(file) == "active"
    end

    test "the release frees the file, the dialog asks again, the confirmation trashes it",
         %{conn: conn} = ctx do
      file = file!(ctx.user)
      attach!(file)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      html = press(view, "release")

      assert_received {:release, [uuid], %{action: :trash_file}}
      assert uuid == file.uuid
      assert html =~ "Move 1 file to trash?"
      assert status(file) == "active", "the release alone trashes nothing"
      refute_received {:changed, _}

      press(view, "confirm")

      assert status(file) == "trashed"
      assert_received {:changed, []}
    end

    test "a guard with no release has no release button, and a forged release does nothing",
         %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file], %{removal_guard: ReadOnlyGuard})

      view |> element(trash_item(file)) |> render_click()

      refute has_element?(view, "#g-removal-release")
      hook(view, "removal_release", %{"token" => token(view)})
      hook(view, "removal_confirm", %{"token" => token(view)})

      assert modal?(view)
      assert status(file) == "active"
      refute_received {:changed, _}
    end

    test "removal_guard={false} goes without the configured guard", %{conn: conn} = ctx do
      file = file!(ctx.user)
      attach!(file)
      view = open(conn, ctx, [file], %{removal_guard: false})

      view |> element(trash_item(file)) |> render_click()
      press(view, "confirm")

      assert status(file) == "trashed"
      refute_received {:places, _, _}
    end
  end

  describe "a guard that fails" do
    test "nothing is removed, and the dialog says the files could not be checked",
         %{conn: conn} = ctx do
      file = file!(ctx.user)
      guard_state(%{raise: true})
      view = open(conn, ctx, [file])

      html =
        capture_log(fn ->
          view |> element(trash_item(file)) |> render_click()
        end)

      assert html =~ "TestGuard.places failed"
      assert modal?(view)
      assert render(view) =~ "Could not check the files"
      refute has_element?(view, "#g-removal-confirm")
      assert status(file) == "active"
    end
  end

  describe "events the menu never sends" do
    # The menu's own button, with the uuid a console would put in its place.
    defp forge(view, button_of, uuid),
      do: view |> element(trash_item(button_of)) |> render_click(%{"uuid" => uuid})

    test "a file that is not in the selection is not asked about or trashed",
         %{conn: conn} = ctx do
      mine = file!(ctx.user)
      elsewhere = file!(ctx.user)
      view = open(conn, ctx, [mine])

      forge(view, mine, elsewhere.uuid)

      refute modal?(view)
      assert status(elsewhere) == "active"
      refute_received {:places, _, _}
    end

    test "a file the person may not change is not asked about or trashed", %{conn: conn} = ctx do
      {:ok, other} =
        Auth.register_user(%{
          email: "gallery-other-#{System.unique_integer([:positive])}@example.com",
          password: "ValidPassword123!"
        })

      mine = file!(ctx.user)
      theirs = file!(other)
      view = open(conn, ctx, [mine, theirs])

      refute has_element?(view, trash_item(theirs))
      forge(view, mine, theirs.uuid)

      refute modal?(view)
      assert status(theirs) == "active"
      refute_received {:places, _, _}
    end

    test "a confirmation with no token is ignored", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      hook(view, "removal_confirm", %{})

      assert modal?(view)
      assert status(file) == "active"
    end
  end

  describe "no current user" do
    test "the menu offers no Move to trash", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, %{ctx | user: nil}, [file])

      assert has_element?(view, "[data-role='remove-image-g-#{file.uuid}']")
      refute has_element?(view, trash_item(file))
    end

    test "a person signed out while the dialog is open cannot confirm", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      host_sets(view, :user, nil)
      press(view, "confirm")

      assert status(file) == "active"
      refute modal?(view)
      refute_received {:changed, _}
    end

    test "a person signed out while the dialog is open cannot trash another file",
         %{conn: conn} = ctx do
      file = file!(ctx.user)
      other = file!(ctx.user)
      view = open(conn, ctx, [file, other])

      view |> element(trash_item(file)) |> render_click()
      host_sets(view, :user, nil)

      refute has_element?(view, trash_item(other))
      hook(view, "trash_image", %{"uuid" => other.uuid})

      refute modal?(view)
      assert status(other) == "active"
      refute_received {:changed, _}
    end
  end

  describe "the situation changes between the dialog and the confirmation" do
    test "a person who lost the right to change the file cannot confirm", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      host_sets(view, :user, other_user!())

      refute has_element?(view, trash_item(file)), "the menu is judged again for the new person"
      press(view, "confirm")

      assert status(file) == "active"
      refute modal?(view)
      refute_received {:changed, _}
    end

    test "the same person whose rights were narrowed meanwhile cannot confirm",
         %{conn: conn} = ctx do
      # Someone else's file is the person's to change only through `media` with
      # `media.view_all`; the host passes the same user before and after.
      {:ok, role} =
        Roles.create_role(%{name: "Gallery editors #{System.unique_integer([:positive])}"})

      {:ok, _} = Permissions.grant_permission(role.uuid, "media")
      {:ok, _} = Permissions.grant_permission(role.uuid, "media.view_all")
      {:ok, _} = Roles.assign_role(ctx.user, role.name)

      file = file!(other_user!())
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      assert modal?(view)

      :ok = Permissions.revoke_permission(role.uuid, "media.view_all")
      press(view, "confirm")

      assert status(file) == "active"
      refute modal?(view)
      refute_received {:changed, _}
    end

    test "a file taken out of the selection cannot be confirmed", %{conn: conn} = ctx do
      file = file!(ctx.user)
      keep = file!(ctx.user)
      view = open(conn, ctx, [file, keep])

      view |> element(trash_item(file)) |> render_click()
      host_sets(view, :selected, [keep.uuid])
      press(view, "confirm")

      assert status(file) == "active"
      refute modal?(view)
      refute_received {:changed, _}
    end

    test "a file trashed meanwhile closes the dialog", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()

      Repo.get!(StorageFile, file.uuid)
      |> Ecto.Changeset.change(status: "trashed")
      |> Repo.update!()

      press(view, "confirm")

      refute modal?(view)
      refute_received {:changed, _}
    end

    test "a guard that fails at the confirmation removes nothing", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      guard_state(%{raise: true})

      capture_log(fn -> press(view, "confirm") end)

      assert render(view) =~ "Could not check the files"
      refute has_element?(view, "#g-removal-confirm")
      assert status(file) == "active"
      refute_received {:changed, _}
    end
  end

  describe "the release" do
    setup %{user: user} do
      file = file!(user)
      attach!(file)
      %{held: file}
    end

    test "is not run for a person who lost the right to change the file",
         %{conn: conn, held: file} = ctx do
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      host_sets(view, :user, other_user!())
      press(view, "release")

      refute_received {:release, _, _}
      refute modal?(view)
      assert status(file) == "active"
    end

    test "is not run for a file taken out of the selection", %{conn: conn, held: file} = ctx do
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      host_sets(view, :selected, [])
      press(view, "release")

      refute_received {:release, _, _}
      refute modal?(view)
    end

    test "is not run for a file trashed meanwhile", %{conn: conn, held: file} = ctx do
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()

      Repo.get!(StorageFile, file.uuid)
      |> Ecto.Changeset.change(status: "trashed")
      |> Repo.update!()

      press(view, "release")

      refute_received {:release, _, _}
      refute modal?(view)
    end

    test "that answers an error keeps the dialog, shows the message and removes nothing",
         %{conn: conn, held: file} = ctx do
      guard_state(%{release_error: "Pinned by order 7"})
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      html = press(view, "release")

      assert_received {:release, _, _}
      assert modal?(view)
      assert html =~ "Pinned by order 7"
      assert has_element?(view, "#g-removal-release")
      refute has_element?(view, "#g-removal-confirm")
      assert status(file) == "active"
      refute_received {:changed, _}
    end

    test "that raises keeps the dialog with the generic message and removes nothing",
         %{conn: conn, held: file} = ctx do
      guard_state(%{release_raise: true})
      view = open(conn, ctx, [file])

      view |> element(trash_item(file)) |> render_click()
      capture_log(fn -> press(view, "release") end)

      assert modal?(view)
      assert render(view) =~ "The files could not be freed. Nothing was removed."
      assert status(file) == "active"
      refute_received {:changed, _}
    end
  end

  describe "a readonly gallery" do
    test "shows the eye and no menu", %{conn: conn} = ctx do
      file = file!(ctx.user)
      view = open(conn, ctx, [file], %{readonly: true})

      assert has_element?(view, "[data-role='preview-image-g-#{file.uuid}']")
      refute has_element?(view, "[data-id='#{file.uuid}'] [data-row-menu-wrapper]")
      refute has_element?(view, trash_item(file))

      refute modal?(view)
      assert status(file) == "active"
    end

    test "refuses trash, confirm and release events sent through the live view",
         %{conn: conn} = ctx do
      file = file!(ctx.user)
      attach!(file)
      view = open(conn, ctx, [file])

      # A dialog left open by a gallery that becomes readonly: the element to
      # send the events from is still there, the server must refuse them.
      view |> element(trash_item(file)) |> render_click()
      token = token(view)
      host_sets(view, :readonly, true)

      hook(view, "trash_image", %{"uuid" => file.uuid})
      hook(view, "removal_release", %{"token" => token})
      attach_free(file)
      hook(view, "removal_confirm", %{"token" => token})

      refute_received {:release, _, _}
      refute_received {:changed, _}
      assert status(file) == "active"
    end
  end
end
