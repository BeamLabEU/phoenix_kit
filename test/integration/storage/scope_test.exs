defmodule PhoenixKit.Integration.Storage.ScopeTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Folder

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_folder!(attrs) do
    {:ok, folder} = Storage.create_folder(attrs)
    folder
  end

  defp create_file!(folder_uuid) do
    {:ok, file} =
      Repo.insert(%StorageFile{
        original_file_name: "test_#{System.unique_integer([:positive])}.jpg",
        file_name: "test_#{System.unique_integer([:positive])}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        size: 1024,
        status: "active",
        folder_uuid: folder_uuid
      })

    file
  end

  # Builds: scope → child_a → grandchild
  #                → child_b
  # Plus a sibling (outside scope): sibling
  defp build_tree do
    scope = create_folder!(%{name: "scope"})
    child_a = create_folder!(%{name: "child_a", parent_uuid: scope.uuid})
    child_b = create_folder!(%{name: "child_b", parent_uuid: scope.uuid})
    grandchild = create_folder!(%{name: "grandchild", parent_uuid: child_a.uuid})
    sibling = create_folder!(%{name: "sibling"})

    %{scope: scope, child_a: child_a, child_b: child_b, grandchild: grandchild, sibling: sibling}
  end

  # ---------------------------------------------------------------------------
  # within_scope?/2
  # ---------------------------------------------------------------------------

  describe "within_scope?/2" do
    test "nil scope is always true" do
      assert Storage.within_scope?("any-uuid", nil)
      assert Storage.within_scope?(nil, nil)
    end

    test "folder_uuid matches scope_folder_id" do
      %{scope: scope} = build_tree()
      assert Storage.within_scope?(scope.uuid, scope.uuid)
    end

    test "descendant of scope returns true" do
      %{scope: scope, child_a: child_a, grandchild: grandchild} = build_tree()
      assert Storage.within_scope?(child_a.uuid, scope.uuid)
      assert Storage.within_scope?(grandchild.uuid, scope.uuid)
    end

    test "sibling of scope returns false" do
      %{scope: scope, sibling: sibling} = build_tree()
      refute Storage.within_scope?(sibling.uuid, scope.uuid)
    end

    test "ancestor of scope returns false" do
      %{scope: scope, child_a: child_a} = build_tree()
      # child_a's parent is scope — scope is ancestor of child_a, not the other way
      # Test: is scope within child_a's scope? No.
      refute Storage.within_scope?(scope.uuid, child_a.uuid)
    end

    test "nil folder_uuid with non-nil scope returns false (real root outside scope)" do
      %{scope: scope} = build_tree()
      refute Storage.within_scope?(nil, scope.uuid)
    end
  end

  # ---------------------------------------------------------------------------
  # list_folder_tree/1
  # ---------------------------------------------------------------------------

  describe "list_folder_tree/1" do
    test "no scope returns real-root tree" do
      %{scope: scope} = build_tree()
      tree = Storage.list_folder_tree()
      uuids = tree_uuids(tree)
      assert scope.uuid in uuids
    end

    test "with scope returns only descendants, scope itself excluded" do
      %{
        scope: scope,
        child_a: child_a,
        child_b: child_b,
        grandchild: grandchild,
        sibling: sibling
      } =
        build_tree()

      tree = Storage.list_folder_tree(scope.uuid)
      uuids = tree_uuids(tree)

      assert child_a.uuid in uuids
      assert child_b.uuid in uuids
      assert grandchild.uuid in uuids
      refute scope.uuid in uuids
      refute sibling.uuid in uuids
    end

    test "tree structure is correct: grandchild nested under child_a" do
      %{scope: scope, child_a: child_a, grandchild: grandchild} = build_tree()
      tree = Storage.list_folder_tree(scope.uuid)

      child_a_node = Enum.find(tree, fn node -> node.folder.uuid == child_a.uuid end)
      assert child_a_node
      assert Enum.any?(child_a_node.children, fn node -> node.folder.uuid == grandchild.uuid end)
    end
  end

  # ---------------------------------------------------------------------------
  # folder_breadcrumbs/2
  # ---------------------------------------------------------------------------

  describe "folder_breadcrumbs/2" do
    test "no scope returns full chain from root" do
      %{scope: scope, child_a: child_a, grandchild: grandchild} = build_tree()
      crumbs = Storage.folder_breadcrumbs(grandchild.uuid)
      uuids = Enum.map(crumbs, & &1.uuid)
      assert scope.uuid in uuids
      assert child_a.uuid in uuids
      assert grandchild.uuid in uuids
    end

    test "with scope stops before scope (scope not included)" do
      %{scope: scope, child_a: child_a, grandchild: grandchild} = build_tree()
      crumbs = Storage.folder_breadcrumbs(grandchild.uuid, scope.uuid)
      uuids = Enum.map(crumbs, & &1.uuid)

      refute scope.uuid in uuids
      assert child_a.uuid in uuids
      assert grandchild.uuid in uuids
    end

    test "breadcrumbs for direct child of scope contains only the child" do
      %{scope: scope, child_a: child_a} = build_tree()
      crumbs = Storage.folder_breadcrumbs(child_a.uuid, scope.uuid)
      uuids = Enum.map(crumbs, & &1.uuid)

      assert uuids == [child_a.uuid]
    end

    test "returns empty list when folder is outside scope" do
      %{scope: scope, sibling: sibling} = build_tree()
      crumbs = Storage.folder_breadcrumbs(sibling.uuid, scope.uuid)
      assert crumbs == []
    end
  end

  # ---------------------------------------------------------------------------
  # list_folders/2
  # ---------------------------------------------------------------------------

  describe "list_folders/2" do
    test "no scope, nil parent returns real root folders" do
      scope = create_folder!(%{name: "scope_lf"})
      _child = create_folder!(%{name: "child_lf", parent_uuid: scope.uuid})

      root_folders = Storage.list_folders()
      uuids = Enum.map(root_folders, & &1.uuid)
      assert scope.uuid in uuids
    end

    test "with scope and nil parent returns children of scope" do
      scope = create_folder!(%{name: "scope_lf2"})
      child = create_folder!(%{name: "child_lf2", parent_uuid: scope.uuid})
      _sibling = create_folder!(%{name: "sibling_lf2"})

      folders = Storage.list_folders(nil, scope.uuid)
      uuids = Enum.map(folders, & &1.uuid)

      assert child.uuid in uuids
      refute scope.uuid in uuids
    end

    test "explicit parent_uuid ignores scope" do
      scope = create_folder!(%{name: "scope_lf3"})
      child = create_folder!(%{name: "child_lf3", parent_uuid: scope.uuid})
      grandchild = create_folder!(%{name: "grandchild_lf3", parent_uuid: child.uuid})

      folders = Storage.list_folders(child.uuid, scope.uuid)
      uuids = Enum.map(folders, & &1.uuid)

      assert grandchild.uuid in uuids
      refute child.uuid in uuids
    end
  end

  # ---------------------------------------------------------------------------
  # list_files_in_scope/2
  # ---------------------------------------------------------------------------

  describe "list_files_in_scope/2" do
    test "returns files across all descendants of scope" do
      %{scope: scope, child_a: child_a, grandchild: grandchild} = build_tree()
      f1 = create_file!(scope.uuid)
      f2 = create_file!(child_a.uuid)
      f3 = create_file!(grandchild.uuid)

      {files, count} = Storage.list_files_in_scope(scope.uuid)
      uuids = Enum.map(files, & &1.uuid)

      assert f1.uuid in uuids
      assert f2.uuid in uuids
      assert f3.uuid in uuids
      assert count >= 3
    end

    test "excludes files from sibling folders" do
      %{scope: scope, sibling: sibling} = build_tree()
      _in_scope = create_file!(scope.uuid)
      out_of_scope = create_file!(sibling.uuid)

      {files, _} = Storage.list_files_in_scope(scope.uuid)
      uuids = Enum.map(files, & &1.uuid)

      refute out_of_scope.uuid in uuids
    end

    test "rejects out-of-scope folder_uuid opt with error" do
      %{scope: scope, sibling: sibling} = build_tree()

      assert {:error, :out_of_scope} =
               Storage.list_files_in_scope(scope.uuid, folder_uuid: sibling.uuid)
    end

    test "folder_uuid within scope filters to that folder" do
      %{scope: scope, child_a: child_a, child_b: child_b} = build_tree()
      f_a = create_file!(child_a.uuid)
      f_b = create_file!(child_b.uuid)

      {files, _} = Storage.list_files_in_scope(scope.uuid, folder_uuid: child_a.uuid)
      uuids = Enum.map(files, & &1.uuid)

      assert f_a.uuid in uuids
      refute f_b.uuid in uuids
    end

    test "search restricted to scope descendants" do
      %{scope: scope, sibling: sibling} = build_tree()
      in_scope = create_file!(scope.uuid)
      out_of_scope = create_file!(sibling.uuid)

      # Update file names to search for
      {:ok, in_scope} =
        Repo.update(Ecto.Changeset.change(in_scope, original_file_name: "findme_in.jpg"))

      {:ok, out_of_scope} =
        Repo.update(Ecto.Changeset.change(out_of_scope, original_file_name: "findme_out.jpg"))

      {files, _} = Storage.list_files_in_scope(scope.uuid, search: "findme")
      uuids = Enum.map(files, & &1.uuid)

      assert in_scope.uuid in uuids
      refute out_of_scope.uuid in uuids
    end

    test "include_orphaned: true with nil scope returns null-folder files" do
      f_orphan = create_file!(nil)
      f_in_folder = create_file!(create_folder!(%{name: "lfs_folder"}).uuid)

      {files, _} = Storage.list_files_in_scope(nil, include_orphaned: true)
      uuids = Enum.map(files, & &1.uuid)

      assert f_orphan.uuid in uuids
      refute f_in_folder.uuid in uuids
    end

    test "pagination works" do
      scope = create_folder!(%{name: "scope_pag"})

      for _ <- 1..5, do: create_file!(scope.uuid)

      {page1, total} = Storage.list_files_in_scope(scope.uuid, page: 1, per_page: 2)
      {page2, _} = Storage.list_files_in_scope(scope.uuid, page: 2, per_page: 2)

      assert length(page1) == 2
      assert length(page2) == 2
      assert total >= 5
    end
  end

  # ---------------------------------------------------------------------------
  # count_orphaned_files/1
  # ---------------------------------------------------------------------------

  describe "count_orphaned_files/1" do
    test "returns 0 when scope is set" do
      %{scope: scope} = build_tree()
      assert Storage.count_orphaned_files(scope.uuid) == 0
    end

    test "returns integer when scope is nil" do
      count = Storage.count_orphaned_files()
      assert is_integer(count)
    end
  end

  # ---------------------------------------------------------------------------
  # create_folder/2
  # ---------------------------------------------------------------------------

  describe "create_folder/2" do
    test "rewrites nil parent_uuid to scope_folder_id" do
      scope = create_folder!(%{name: "scope_cf"})

      {:ok, folder} = Storage.create_folder(%{name: "new_folder"}, scope.uuid)
      assert folder.parent_uuid == scope.uuid
    end

    test "allows creation with parent inside scope" do
      %{scope: scope, child_a: child_a} = build_tree()

      {:ok, folder} = Storage.create_folder(%{name: "nested"}, scope.uuid)
      _ = folder

      {:ok, folder2} =
        Storage.create_folder(%{name: "deeply_nested", parent_uuid: child_a.uuid}, scope.uuid)

      assert folder2.parent_uuid == child_a.uuid
    end

    test "rejects parent outside scope" do
      %{scope: scope, sibling: sibling} = build_tree()

      assert {:error, :out_of_scope} =
               Storage.create_folder(%{name: "bad", parent_uuid: sibling.uuid}, scope.uuid)
    end
  end

  # ---------------------------------------------------------------------------
  # update_folder/3
  # ---------------------------------------------------------------------------

  describe "update_folder/3" do
    test "rejects updating folder outside scope" do
      %{scope: scope, sibling: sibling} = build_tree()

      assert {:error, :out_of_scope} =
               Storage.update_folder(sibling, %{name: "renamed"}, scope.uuid)
    end

    test "rejects moving folder to parent outside scope" do
      %{scope: scope, child_a: child_a, sibling: sibling} = build_tree()

      assert {:error, :out_of_scope} =
               Storage.update_folder(child_a, %{parent_uuid: sibling.uuid}, scope.uuid)
    end

    test "allows rename within scope" do
      %{scope: scope, child_a: child_a} = build_tree()
      {:ok, updated} = Storage.update_folder(child_a, %{name: "child_a_renamed"}, scope.uuid)
      assert updated.name == "child_a_renamed"
    end

    test "allows move within scope" do
      %{scope: scope, child_a: child_a, child_b: child_b} = build_tree()

      {:ok, updated} =
        Storage.update_folder(child_a, %{parent_uuid: child_b.uuid}, scope.uuid)

      assert updated.parent_uuid == child_b.uuid
    end

    # Gap #5: cycle-detection preserved under scope
    test "rejects creating a cycle even within scope" do
      %{scope: scope, child_a: child_a, grandchild: grandchild} = build_tree()
      # Moving child_a under its own descendant (grandchild) would create a cycle.
      # The storage layer checks for cycles regardless of scope.
      assert {:error, :cycle} =
               Storage.update_folder(child_a, %{parent_uuid: grandchild.uuid}, scope.uuid)
    end
  end

  # ---------------------------------------------------------------------------
  # delete_folder/2
  # ---------------------------------------------------------------------------

  describe "delete_folder/2" do
    test "rejects deleting folder outside scope" do
      %{scope: scope, sibling: sibling} = build_tree()
      assert {:error, :out_of_scope} = Storage.delete_folder(sibling, scope.uuid)
    end

    test "allows deleting folder within scope" do
      scope = create_folder!(%{name: "scope_del"})
      child = create_folder!(%{name: "child_del", parent_uuid: scope.uuid})

      assert {:ok, _} = Storage.delete_folder(child, scope.uuid)
      assert is_nil(Storage.get_folder(child.uuid))
    end
  end

  # ---------------------------------------------------------------------------
  # move_file_to_folder/3
  # ---------------------------------------------------------------------------

  describe "move_file_to_folder/3" do
    test "rejects when target folder is outside scope" do
      %{scope: scope, child_a: child_a, sibling: sibling} = build_tree()
      file = create_file!(child_a.uuid)

      assert {:error, :out_of_scope} =
               Storage.move_file_to_folder(file.uuid, sibling.uuid, scope.uuid)
    end

    test "rejects when source file is in a folder outside scope (not orphan)" do
      %{scope: scope, child_a: child_a, sibling: sibling} = build_tree()
      file = create_file!(sibling.uuid)

      assert {:error, :out_of_scope} =
               Storage.move_file_to_folder(file.uuid, child_a.uuid, scope.uuid)
    end

    test "rejects moving orphaned file (folder_uuid nil) when scope is set" do
      %{scope: scope, child_a: child_a} = build_tree()
      orphan = create_file!(nil)

      assert {:error, :out_of_scope} =
               Storage.move_file_to_folder(orphan.uuid, child_a.uuid, scope.uuid)
    end

    # Gap #6: nil target (real root) is outside any non-nil scope
    test "rejects moving file to nil (real root) when scope is set" do
      %{scope: scope, child_a: child_a} = build_tree()
      file = create_file!(child_a.uuid)

      # nil target = real root = outside scope; within_scope?(nil, scope) → false
      assert {:error, :out_of_scope} =
               Storage.move_file_to_folder(file.uuid, nil, scope.uuid)
    end

    test "allows moving file within scope" do
      %{scope: scope, child_a: child_a, child_b: child_b} = build_tree()
      file = create_file!(child_a.uuid)

      assert {:ok, updated} = Storage.move_file_to_folder(file.uuid, child_b.uuid, scope.uuid)
      assert updated.folder_uuid == child_b.uuid
    end
  end

  # ---------------------------------------------------------------------------
  # create_folder_link/3
  # ---------------------------------------------------------------------------

  describe "create_folder_link/3" do
    test "rejects when target folder is outside scope" do
      %{scope: scope, child_a: child_a, sibling: sibling} = build_tree()
      file = create_file!(child_a.uuid)

      assert {:error, :out_of_scope} =
               Storage.create_folder_link(sibling.uuid, file.uuid, scope.uuid)
    end

    test "rejects when file's primary folder is outside scope" do
      %{scope: scope, child_a: child_a, sibling: sibling} = build_tree()
      file = create_file!(sibling.uuid)

      assert {:error, :out_of_scope} =
               Storage.create_folder_link(child_a.uuid, file.uuid, scope.uuid)
    end

    test "allows creating link when both folder and file are within scope" do
      %{scope: scope, child_a: child_a, child_b: child_b} = build_tree()
      file = create_file!(child_a.uuid)

      assert {:ok, _link} = Storage.create_folder_link(child_b.uuid, file.uuid, scope.uuid)
    end
  end

  # ---------------------------------------------------------------------------
  # UUID search in list_files_in_scope
  # ---------------------------------------------------------------------------

  describe "list_files_in_scope with UUID search" do
    test "partial UUID prefix matches file" do
      file = create_file!(nil)
      prefix = String.slice(file.uuid, 0, 8)
      {results, _count} = Storage.list_files_in_scope(nil, search: prefix)
      uuids = Enum.map(results, & &1.uuid)
      assert file.uuid in uuids
    end

    test "non-matching UUID prefix returns no results for that file" do
      file = create_file!(nil)
      # Overwrite all hex digits to guarantee no match
      bogus = String.replace(file.uuid, ~r/[0-9a-f]/, "z")
      {results, _count} = Storage.list_files_in_scope(nil, search: bogus)
      uuids = Enum.map(results, & &1.uuid)
      refute file.uuid in uuids
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp tree_uuids(nodes) do
    Enum.flat_map(nodes, fn node ->
      [node.folder.uuid | tree_uuids(node.children)]
    end)
  end
end
