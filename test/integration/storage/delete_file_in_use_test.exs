defmodule PhoenixKit.Modules.Storage.DeleteFileInUseTest do
  @moduledoc """
  A file something else refers to cannot be deleted for good, and saying so must
  not cost the person everything else they asked for.

  Modules attach media through tables with a `RESTRICT` key on the file (a
  comment's attachments, a catalogue's PDFs): the database refuses to remove a
  file one of them still points at. That refusal used to RAISE out of
  `repo().delete` — through "Delete permanently", the single-file delete,
  "Empty trash" and the scheduled trash clean-up alike. In the media page the
  raise took the LiveView down: the page reconnected on the main view, the trash
  filter gone, and not one of the selected files deleted.

  A stand-in table with the same key stands in for a module's, so this holds
  whichever modules are installed.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, Folder}
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser

  setup do
    # DDL is transactional in Postgres: the sandbox takes it back with the test.
    Repo.query!("""
    CREATE TABLE zz_attachments (
      uuid uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      file_uuid uuid NOT NULL REFERENCES phoenix_kit_files(uuid) ON DELETE RESTRICT
    )
    """)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "in-use-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    %{user: user}
  end

  defp file!(user, name) do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "#{name}.png",
        file_name: "#{name}-#{System.unique_integer([:positive])}.png",
        file_path: "x/#{name}-#{System.unique_integer([:positive])}.png",
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

  defp trashed!(user, name \\ "f") do
    {:ok, trashed} = user |> file!(name) |> Storage.trash_file()
    trashed
  end

  defp attach!(file),
    do:
      Repo.query!("INSERT INTO zz_attachments (file_uuid) VALUES ($1)", [
        Ecto.UUID.dump!(file.uuid)
      ])

  defp release!(file),
    do:
      Repo.query!("DELETE FROM zz_attachments WHERE file_uuid = $1", [Ecto.UUID.dump!(file.uuid)])

  defp exists?(file), do: not is_nil(Repo.get(File, file.uuid))

  describe "delete_file_completely/1" do
    test "refuses a file something refers to, instead of raising", %{user: u} do
      file = trashed!(u)
      attach!(file)

      assert {:error, :in_use} = Storage.delete_file_completely(file)
      assert exists?(file), "and the file is untouched"
    end

    test "deletes it once nothing refers to it any more", %{user: u} do
      file = trashed!(u)
      attach!(file)
      assert {:error, :in_use} = Storage.delete_file_completely(file)

      release!(file)
      assert {:ok, _} = Storage.delete_file_completely(file)
      refute exists?(file)
    end

    test "an unreferenced file is deleted as before", %{user: u} do
      file = trashed!(u)
      assert {:ok, _} = Storage.delete_file_completely(file)
      refute exists?(file)
    end
  end

  describe "emptying the trash" do
    test "deletes what it can and leaves the file that is in use", %{user: u} do
      free_a = trashed!(u, "a")
      free_b = trashed!(u, "b")
      used = trashed!(u, "used")
      attach!(used)

      assert {:ok, 2} = Storage.empty_trash(nil, [])

      refute exists?(free_a)
      refute exists?(free_b)
      assert exists?(used), "the one in use stays in the trash"
      assert Repo.get(File, used.uuid).status == "trashed"
    end
  end

  describe "deleting a trashed folder for good" do
    setup %{user: u} do
      {:ok, folder} =
        Storage.create_folder(%{
          name: "doomed-#{System.unique_integer([:positive])}",
          user_uuid: u.uuid
        })

      {:ok, child} =
        Storage.create_folder(%{name: "child", user_uuid: u.uuid, parent_uuid: folder.uuid})

      %{folder: folder, child: child}
    end

    defp home!(file, folder),
      do:
        Repo.update_all(from(f in File, where: f.uuid == ^file.uuid),
          set: [folder_uuid: folder.uuid]
        )

    test "with nothing in use, the whole tree goes", %{user: u, folder: folder, child: child} do
      a = file!(u, "a")
      b = file!(u, "b")
      home!(a, folder)
      home!(b, child)
      {:ok, _} = Storage.trash_folder(Repo.get!(Folder, folder.uuid), nil)

      assert {:ok, _} = Storage.delete_folder_completely(Repo.get!(Folder, folder.uuid))

      refute exists?(a)
      refute exists?(b)
      assert is_nil(Repo.get(Folder, folder.uuid))
      assert is_nil(Repo.get(Folder, child.uuid))
    end

    test "a file in use is not deleted — and not quietly moved to the media root either",
         %{user: u, folder: folder, child: child} do
      free = file!(u, "free")
      used = file!(u, "used")
      home!(free, child)
      home!(used, child)
      attach!(used)
      {:ok, _} = Storage.trash_folder(Repo.get!(Folder, folder.uuid), nil)

      assert {:error, :in_use} = Storage.delete_folder_completely(Repo.get!(Folder, folder.uuid))

      refute exists?(free), "what could go, went"
      assert exists?(used)
      # The folders that still hold the file stay, so it is not orphaned into
      # the root by the folder key (ON DELETE SET NULL).
      assert Repo.get!(File, used.uuid).folder_uuid == child.uuid
      assert Repo.get(Folder, child.uuid)
      assert Repo.get(Folder, folder.uuid)
    end

    test "a sibling folder with nothing in use is removed, the blocked branch is not",
         %{user: u, folder: folder, child: child} do
      {:ok, clean} =
        Storage.create_folder(%{name: "clean", user_uuid: u.uuid, parent_uuid: folder.uuid})

      used = file!(u, "used")
      other = file!(u, "other")
      home!(used, child)
      home!(other, clean)
      attach!(used)
      {:ok, _} = Storage.trash_folder(Repo.get!(Folder, folder.uuid), nil)

      assert {:error, :in_use} = Storage.delete_folder_completely(Repo.get!(Folder, folder.uuid))

      refute exists?(other)
      assert is_nil(Repo.get(Folder, clean.uuid)), "the clean branch is gone"
      assert Repo.get(Folder, child.uuid), "the blocked one stays"
    end
  end

  describe "the media browser" do
    defp browser(selected_files, selected_folders \\ []) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          id: "mb",
          flash: %{},
          readonly: false,
          library_uuid: nil,
          own_files_only: nil,
          scope_folder_id: nil,
          current_folder: nil,
          expanded_stacks: [],
          filter_trash: true,
          filter_orphaned: false,
          file_view: "folders",
          current_page: 1,
          per_page: 50,
          search_query: "",
          sort_by: "newest",
          only_file_type: nil,
          uploaded_files: [],
          folders: [],
          stacks: [],
          expanded_stack: nil,
          total_count: 0,
          selected_files: MapSet.new(selected_files),
          selected_folders: MapSet.new(selected_folders)
        }
      }
    end

    test "Delete permanently on a selection with one file in use deletes the rest and says so",
         %{user: u} do
      free_a = trashed!(u, "a")
      free_b = trashed!(u, "b")
      used = trashed!(u, "used")
      attach!(used)

      socket = browser([free_a.uuid, free_b.uuid, used.uuid])

      # It used to raise here, which is what takes the page down.
      assert {:noreply, _socket} = MediaBrowser.handle_event("delete_selected", %{}, socket)

      refute exists?(free_a)
      refute exists?(free_b)
      assert exists?(used)
      assert_received {MediaBrowser, "mb", {:flash, :info, info}}
      assert info =~ "2"
      assert_received {MediaBrowser, "mb", {:flash, :error, error}}
      assert error =~ "in use", "the message says why, not just that something failed: #{error}"
    end

    test "deleting the one file in use says it is in use and does not claim success", %{user: u} do
      used = trashed!(u, "used")
      attach!(used)

      assert {:noreply, _} =
               MediaBrowser.handle_event("delete_file", %{"file-uuid" => used.uuid}, browser([]))

      assert exists?(used)
      assert_received {MediaBrowser, "mb", {:flash, :error, error}}
      assert error =~ "in use"
      refute_received {MediaBrowser, "mb", {:flash, :info, _}}
    end
  end
end
