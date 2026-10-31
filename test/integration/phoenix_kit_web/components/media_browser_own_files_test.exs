defmodule PhoenixKitWeb.Components.MediaBrowserOwnFilesTest do
  @moduledoc """
  A user library's contributor changes only the files they uploaded
  (`own_files_only`): a write naming someone else's file, a bulk action on a
  selection holding one, and emptying the trash are refused. The browser's
  list of writes is exactly the events that refuse to run when it is
  readonly, so a read (opening a file) is never refused.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "own-files-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp file!(user) do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "a.png",
        file_name: "a.png",
        file_path: "x/a.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    file
  end

  defp socket(contributor, selected \\ []) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        id: "mb",
        flash: %{},
        readonly: false,
        library_uuid: nil,
        own_files_only: contributor.uuid,
        selected_files: MapSet.new(selected)
      }
    }
  end

  # The browser's flash goes to the host LiveView as a message (a
  # component's own flash never reaches the page).
  defp refused?({:noreply, _socket}) do
    receive do
      {MediaBrowser, _, {:flash, :error, "You can only change files you uploaded"}} -> true
    after
      0 -> false
    end
  end

  test "someone else's file is refused; the selection and the trash too" do
    contributor = user!()
    others = file!(user!())

    assert refused?(
             MediaBrowser.handle_event(
               "trash_file",
               %{"file_uuid" => others.uuid},
               socket(contributor)
             )
           )

    assert refused?(
             MediaBrowser.handle_event("delete_selected", %{}, socket(contributor, [others.uuid]))
           )

    assert refused?(MediaBrowser.handle_event("empty_trash", %{}, socket(contributor)))

    assert Storage.get_file(others.uuid).status == "active"
  end

  test "a folder write whose subtree holds someone else's file is refused" do
    contributor = user!()
    other = user!()
    {:ok, parent} = Storage.create_folder(%{name: "shared-#{System.unique_integer([:positive])}"})

    {:ok, child} =
      Storage.create_folder(%{name: "inner-#{System.unique_integer()}", parent_uuid: parent.uuid})

    others = file!(other)

    Repo.update_all(from(f in Storage.File, where: f.uuid == ^others.uuid),
      set: [folder_uuid: child.uuid]
    )

    assert refused?(
             MediaBrowser.handle_event(
               "trash_folder",
               %{"folder_uuid" => parent.uuid},
               socket(contributor)
             )
           )

    assert refused?(
             MediaBrowser.handle_event(
               "delete_folder",
               %{"id" => parent.uuid},
               socket(contributor)
             )
           )

    selecting_folder =
      put_in(socket(contributor).assigns[:selected_folders], MapSet.new([parent.uuid]))

    assert refused?(MediaBrowser.handle_event("delete_selected", %{}, selecting_folder))
    assert refused?(MediaBrowser.handle_event("restore_selected", %{}, selecting_folder))

    assert refused?(
             MediaBrowser.handle_event(
               "move_folder_to_folder",
               %{"folder_uuid" => child.uuid, "target_uuid" => ""},
               socket(contributor)
             )
           )

    assert Storage.get_file(others.uuid).status == "active"
  end

  test "reading is not a write, so viewing someone else's file is not refused" do
    others = file!(user!())

    refute "click_file" in MediaBrowser.write_events()
    refute "toggle_search" in MediaBrowser.write_events()
    assert others.uuid
  end

  test "the list of writes is exactly the events that refuse to run when readonly" do
    source = File.read!("lib/phoenix_kit_web/components/media_browser.ex")

    readonly_events =
      ~r/def handle_event\("([a-z_]+)", _params, socket\)\s+when socket\.assigns\.readonly == true/
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    assert readonly_events != []
    assert Enum.sort(MediaBrowser.write_events()) == readonly_events
  end
end
