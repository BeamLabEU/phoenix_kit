defmodule PhoenixKit.Integration.MediaBrowserScopeTest do
  @moduledoc """
  Integration tests for the data-layer behaviors that MediaBrowser relies on
  for scope enforcement, orphan detection, and scope_invalid state.

  These tests exercise Storage functions directly rather than the LiveComponent
  (which requires a full Phoenix endpoint). They validate that the primitives
  MediaBrowser calls produce the correct results for each code path.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_folder!(attrs \\ %{}) do
    name = Map.get(attrs, :name, "folder_#{System.unique_integer([:positive])}")
    {:ok, folder} = Storage.create_folder(Map.put(attrs, :name, name))
    folder
  end

  defp create_file!(folder_uuid) do
    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "file_#{System.unique_integer([:positive])}.jpg",
        file_name: "file_#{System.unique_integer([:positive])}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        size: 1024,
        status: "active",
        folder_uuid: folder_uuid
      })

    file
  end

  defp fake_uuid,
    do:
      "00000000-0000-7000-8000-#{System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(12, "0")}"

  # ---------------------------------------------------------------------------
  # scope_invalid detection
  # (mirrors: `not is_nil(scope) and is_nil(Storage.get_folder(scope))` in init_socket)
  # ---------------------------------------------------------------------------

  describe "scope_invalid detection" do
    test "returns false when scope is nil (unscoped browser)" do
      scope = nil
      scope_invalid = not is_nil(scope) and is_nil(Storage.get_folder(scope))
      refute scope_invalid
    end

    test "returns false when scope folder exists" do
      scope = create_folder!()
      scope_invalid = not is_nil(scope.uuid) and is_nil(Storage.get_folder(scope.uuid))
      refute scope_invalid
    end

    test "returns true when scope UUID points to deleted/nonexistent folder" do
      uuid = fake_uuid()
      scope_invalid = not is_nil(uuid) and is_nil(Storage.get_folder(uuid))
      assert scope_invalid
    end
  end

  # ---------------------------------------------------------------------------
  # include_orphaned: true at real root
  # (mirrors: `at_real_root = is_nil(scope) and is_nil(folder_uuid) and search in [nil, ""]` in load_scoped_files)
  # ---------------------------------------------------------------------------

  describe "orphaned-file root detection" do
    test "orphans returned when scope=nil, folder=nil, search empty" do
      orphan = create_file!(nil)
      in_folder = create_file!(create_folder!().uuid)

      {files, _} = Storage.list_files_in_scope(nil, include_orphaned: true)
      uuids = Enum.map(files, & &1.uuid)

      assert orphan.uuid in uuids
      refute in_folder.uuid in uuids
    end

    test "orphans not returned without include_orphaned when folder given" do
      folder = create_folder!()
      orphan = create_file!(nil)
      in_folder = create_file!(folder.uuid)

      {files, _} = Storage.list_files_in_scope(nil, folder_uuid: folder.uuid)
      uuids = Enum.map(files, & &1.uuid)

      assert in_folder.uuid in uuids
      refute orphan.uuid in uuids
    end

    test "orphans not returned when scope is set (scope disables orphan filter)" do
      scope = create_folder!()
      orphan = create_file!(nil)

      # With a scope set, there are no orphans within scope (nil folder_uuid is outside scope)
      # list_files_in_scope with scope only returns files inside scope tree
      {files, _} = Storage.list_files_in_scope(scope.uuid)
      uuids = Enum.map(files, & &1.uuid)

      refute orphan.uuid in uuids
    end
  end

  # ---------------------------------------------------------------------------
  # scoped_fallback? logic
  # (mirrors apply_nav_params: `not is_nil(folder_uuid)` when folder outside scope)
  # ---------------------------------------------------------------------------

  describe "scoped_fallback? detection" do
    test "no fallback when folder_uuid is nil" do
      # folder_uuid nil → clean navigation to root, no fallback needed
      folder_uuid = nil
      folder = if folder_uuid, do: Storage.get_folder(folder_uuid), else: nil
      scope = create_folder!()

      in_scope = folder && Storage.within_scope?(folder.uuid, scope.uuid)
      scoped_fallback? = not is_nil(folder_uuid) and not in_scope
      refute scoped_fallback?
    end

    test "no fallback when folder is within scope" do
      scope = create_folder!()
      child = create_folder!(%{name: "child", parent_uuid: scope.uuid})
      folder_uuid = child.uuid

      folder = Storage.get_folder(folder_uuid)
      in_scope = folder && Storage.within_scope?(folder.uuid, scope.uuid)
      scoped_fallback? = not is_nil(folder_uuid) and not in_scope
      refute scoped_fallback?
    end

    test "fallback triggered when folder is outside scope" do
      scope = create_folder!()
      outside = create_folder!()
      folder_uuid = outside.uuid

      folder = Storage.get_folder(folder_uuid)
      in_scope = folder && Storage.within_scope?(folder.uuid, scope.uuid)
      scoped_fallback? = not is_nil(folder_uuid) and not in_scope
      assert scoped_fallback?
    end

    test "fallback triggered when folder UUID does not exist" do
      scope = create_folder!()
      folder_uuid = fake_uuid()

      folder = Storage.get_folder(folder_uuid)
      in_scope = folder && Storage.within_scope?(folder.uuid, scope.uuid)
      scoped_fallback? = not is_nil(folder_uuid) and not in_scope
      assert scoped_fallback?
    end
  end

  # ---------------------------------------------------------------------------
  # Scoped mutators — out-of-scope rejections (complements scope_test.exs)
  # Tests that the event handler pattern (match {:error, :out_of_scope}) works
  # ---------------------------------------------------------------------------

  describe "mutator out-of-scope rejections" do
    test "create_folder with out-of-scope parent returns {:error, :out_of_scope}" do
      scope = create_folder!()
      outside = create_folder!()

      assert {:error, :out_of_scope} =
               Storage.create_folder(%{name: "bad", parent_uuid: outside.uuid}, scope.uuid)
    end

    test "delete_folder outside scope returns {:error, :out_of_scope}" do
      scope = create_folder!()
      outside = create_folder!()
      assert {:error, :out_of_scope} = Storage.delete_folder(outside, scope.uuid)
    end

    test "update_folder outside scope returns {:error, :out_of_scope}" do
      scope = create_folder!()
      outside = create_folder!()

      assert {:error, :out_of_scope} =
               Storage.update_folder(outside, %{name: "renamed"}, scope.uuid)
    end

    test "move_file_to_folder with out-of-scope target returns {:error, :out_of_scope}" do
      scope = create_folder!()
      child = create_folder!(%{name: "child", parent_uuid: scope.uuid})
      outside = create_folder!()
      file = create_file!(child.uuid)

      assert {:error, :out_of_scope} =
               Storage.move_file_to_folder(file.uuid, outside.uuid, scope.uuid)
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_set_folder upload target logic
  # (mirrors: `current_folder_uuid || scope_folder_id` in maybe_set_folder)
  # ---------------------------------------------------------------------------

  describe "upload target selection (scope fallback)" do
    test "scope folder used as upload target when no current folder" do
      scope = create_folder!()
      current_folder_uuid = nil

      # mirrors: folder_uuid = current_folder_uuid(socket) || scope_folder_id(socket)
      upload_target = current_folder_uuid || scope.uuid
      assert upload_target == scope.uuid
    end

    test "current folder takes priority over scope" do
      scope = create_folder!()
      current = create_folder!(%{name: "current", parent_uuid: scope.uuid})

      upload_target = current.uuid || scope.uuid
      assert upload_target == current.uuid
    end

    test "no target when both nil (unscoped, no folder selected)" do
      current_folder_uuid = nil
      scope_folder_id = nil

      upload_target = current_folder_uuid || scope_folder_id
      assert is_nil(upload_target)
    end
  end
end
