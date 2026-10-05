defmodule PhoenixKit.Integration.Storage.TrashBroadcastTest do
  @moduledoc """
  Trashing, restoring, and permanently deleting a file (or a folder's whole
  subtree) must broadcast on the files topic so an open MediaBrowser reacts
  live instead of keeping a stale card (issue #841) — one event per file for
  a single-file operation, one bulk event per folder operation.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_folder!(attrs) do
    {:ok, folder} = Storage.create_folder(attrs)
    folder
  end

  defp create_file!(folder_uuid) do
    n = System.unique_integer([:positive])

    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "test_#{n}.jpg",
        file_name: "test_#{n}.jpg",
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
            email: "trash-broadcast-test-#{n}@example.com",
            password: "ValidPassword123!"
          })

        Process.put(:test_owner_user_uuid, user.uuid)
        user.uuid

      uuid ->
        uuid
    end
  end

  setup do
    Storage.subscribe_to_file_events()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Single-file operations
  # ---------------------------------------------------------------------------

  describe "trash_file/1" do
    test "broadcasts :phoenix_kit_file_trashed and still returns {:ok, file}" do
      folder = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      file = create_file!(folder.uuid)
      file_uuid = file.uuid

      assert {:ok, updated} = Storage.trash_file(file)
      assert updated.status == "trashed"
      # Pinned, not a bare capture: this subscribes to the GLOBAL files
      # topic with no per-test scoping, and other async test files trash
      # files of their own during the same run — an unpinned capture can
      # match a stranger's broadcast instead of this test's own.
      assert_receive {:phoenix_kit_file_trashed, ^file_uuid}
    end
  end

  describe "restore_file/1" do
    test "broadcasts :phoenix_kit_file_restored and still returns {:ok, file}" do
      folder = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      file = create_file!(folder.uuid)
      file_uuid = file.uuid
      {:ok, file} = Storage.trash_file(file)
      assert_receive {:phoenix_kit_file_trashed, ^file_uuid}

      assert {:ok, updated} = Storage.restore_file(file)
      assert updated.status == "active"
      assert_receive {:phoenix_kit_file_restored, ^file_uuid}
    end
  end

  describe "delete_file_completely/1" do
    test "broadcasts :phoenix_kit_file_deleted and still returns {:ok, file}" do
      folder = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      file = create_file!(folder.uuid)
      file_uuid = file.uuid

      assert {:ok, deleted} = Storage.delete_file_completely(file)
      assert_receive {:phoenix_kit_file_deleted, ^file_uuid}
      assert deleted.uuid == file_uuid
    end
  end

  # ---------------------------------------------------------------------------
  # Folder-level sweeps — do_trash_folder/do_restore_folder move files in bulk
  # via update_all, bypassing trash_file/restore_file entirely. The swept files
  # are announced in ONE bulk message per operation (`{:phoenix_kit_files_*,
  # [uuid]}`), not one per file: a folder of thousands of files was thousands
  # of messages, and as many re-renders, for every subscriber.
  # ---------------------------------------------------------------------------

  describe "trash_folder/2" do
    test "announces every file in the subtree in one :phoenix_kit_files_trashed" do
      root = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})

      child =
        create_folder!(%{
          name: "child_#{System.unique_integer([:positive])}",
          parent_uuid: root.uuid
        })

      file_a = create_file!(root.uuid)
      file_b = create_file!(child.uuid)
      expected = Enum.sort([file_a.uuid, file_b.uuid])

      assert {:ok, _} = Storage.trash_folder(root)

      # Pinned to this test's own uuids: other async tests broadcast on the
      # same global topic, so a batch that is not this one is skipped.
      assert receive_batch(expected) == expected
      for uuid <- expected, do: refute_received({:phoenix_kit_file_trashed, ^uuid})
    end

    test "leaves a file already in the trash alone, and does not announce it" do
      root = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      earlier = trash_at!(create_file!(root.uuid), ~U[2026-01-01 10:00:00Z])
      fresh = create_file!(root.uuid)

      assert {:ok, _} = Storage.trash_folder(root)

      fresh_uuid = fresh.uuid
      assert_receive {:phoenix_kit_files_trashed, [^fresh_uuid]}
      # It keeps its own stamp, which is what lets restoring the folder skip it.
      assert Repo.get!(StorageFile, earlier.uuid).trashed_at == ~U[2026-01-01 10:00:00Z]
    end
  end

  describe "restore_folder/2" do
    test "announces the files it restored in one :phoenix_kit_files_restored" do
      root = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      file = create_file!(root.uuid)
      file_uuid = file.uuid
      {:ok, _} = Storage.trash_folder(root)
      assert_receive {:phoenix_kit_files_trashed, [^file_uuid]}

      assert {:ok, _} = Storage.restore_folder(Repo.reload!(root))

      assert_receive {:phoenix_kit_files_restored, [^file_uuid]}
      assert Repo.get!(StorageFile, file_uuid).status == "active"
    end

    test "restores only what the folder's own trashing trashed" do
      root = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      swept = create_file!(root.uuid)
      # Trashed on its own before the folder was...
      before = trash_at!(create_file!(root.uuid), ~U[2026-01-01 10:00:00Z])

      {:ok, _} = Storage.trash_folder(root)
      swept_uuid = swept.uuid
      assert_receive {:phoenix_kit_files_trashed, [^swept_uuid]}

      # ...and one trashed on its own after, at a different moment.
      later = trash_at!(create_file!(root.uuid), ~U[2026-01-02 10:00:00Z])

      assert {:ok, _} = Storage.restore_folder(Repo.reload!(root))

      assert_receive {:phoenix_kit_files_restored, [^swept_uuid]}
      assert Repo.get!(StorageFile, swept.uuid).status == "active"
      assert Repo.get!(StorageFile, before.uuid).status == "trashed"
      assert Repo.get!(StorageFile, later.uuid).status == "trashed"
    end

    test "restoring a folder that is not in the trash restores nothing" do
      root = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      loose = trash_at!(create_file!(root.uuid), ~U[2026-01-01 10:00:00Z])

      assert {:ok, _} = Storage.restore_folder(root)

      assert Repo.get!(StorageFile, loose.uuid).status == "trashed"
      loose_uuid = loose.uuid
      refute_received {:phoenix_kit_files_restored, [^loose_uuid]}
    end
  end

  describe "delete_folder_completely/2" do
    test "announces every deleted file in one :phoenix_kit_files_deleted" do
      root = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      file_a = create_file!(root.uuid)
      file_b = create_file!(root.uuid)
      expected = Enum.sort([file_a.uuid, file_b.uuid])

      assert {:ok, _} = Storage.delete_folder_completely(root)

      assert receive_batch(expected, :phoenix_kit_files_deleted) == expected
      for uuid <- expected, do: refute_received({:phoenix_kit_file_deleted, ^uuid})
    end

    test "announces a file re-homed into a trashed folder as trashed" do
      # A file also linked into a folder outside the one being deleted
      # survives by moving there; when that folder is itself in the trash,
      # the file takes its trash stamp — and a page showing it must hear so.
      root = create_folder!(%{name: "root_#{System.unique_integer([:positive])}"})
      elsewhere = create_folder!(%{name: "elsewhere_#{System.unique_integer([:positive])}"})
      file = create_file!(root.uuid)
      {:ok, _} = Storage.create_folder_link(elsewhere.uuid, file.uuid)
      {:ok, _} = Storage.trash_folder(elsewhere)

      assert {:ok, _} = Storage.delete_folder_completely(root)

      file_uuid = file.uuid
      assert_receive {:phoenix_kit_files_trashed, [^file_uuid]}
      assert %{status: "trashed", folder_uuid: home} = Repo.get!(StorageFile, file_uuid)
      assert home == elsewhere.uuid
    end
  end

  # The batch holding exactly this test's uuids, skipping other tests' batches
  # on the shared topic. Deletion broadcasts need the same scoping as trash.
  defp receive_batch(expected, event \\ :phoenix_kit_files_trashed) do
    receive do
      {^event, uuids} when is_list(uuids) ->
        if Enum.sort(uuids) == expected, do: expected, else: receive_batch(expected, event)
    after
      1_000 -> flunk("no #{event} batch for #{inspect(expected)}")
    end
  end

  # Trashes at a chosen moment so a test can distinguish a folder's operation.
  defp trash_at!(file, at) do
    {1, _} =
      Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid),
        set: [status: "trashed", trashed_at: at]
      )

    Repo.reload!(file)
  end
end
