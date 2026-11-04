defmodule PhoenixKit.Modules.Storage.ListFilesSubtreeTest do
  @moduledoc """
  `Storage.list_files_in_scope/2` with `subtree: true`: the files of a folder
  and of everything below it, under the same filters as a folder listing —
  library, viewer — and without the folders in the trash.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaBrowser.Helpers

  defp user!(tag) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "subtree-#{tag}-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp folder!(name, parent) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: "#{name}-#{System.unique_integer([:positive])}",
        parent_uuid: parent && parent.uuid
      })

    folder
  end

  defp file!(folder, owner, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Repo.insert!(
      struct(
        %StorageFile{
          original_file_name: "subtree-#{n}.png",
          file_name: "subtree-#{n}.png",
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          file_checksum: "subtree-#{n}",
          user_file_checksum: "subtree-u-#{n}",
          size: 1,
          status: "active",
          folder_uuid: folder && folder.uuid,
          user_uuid: owner.uuid
        },
        attrs
      )
    )
  end

  defp uuids({files, _total}), do: files |> Enum.map(& &1.uuid) |> Enum.sort()

  test "a folder in the trash is not walked, and a file linked only into one is not listed" do
    owner = user!("owner")
    root = folder!("Root", nil)
    live = folder!("Live", root)
    gone = folder!("Gone", root)
    under_gone = folder!("UnderGone", gone)

    a = file!(live, owner)
    elsewhere = file!(folder!("Elsewhere", nil), owner)
    {:ok, _} = Storage.create_folder_link(gone.uuid, elsewhere.uuid)
    {:ok, _} = Storage.create_folder_link(under_gone.uuid, elsewhere.uuid)

    assert uuids(Storage.list_files_in_scope(root.uuid, subtree: true)) ==
             Enum.sort([a.uuid, elsewhere.uuid])

    {:ok, _} = Storage.trash_folder(Repo.get(Storage.Folder, gone.uuid))

    assert uuids(Storage.list_files_in_scope(root.uuid, subtree: true)) == [a.uuid]

    # Standing in the trashed folder lists nothing.
    assert {[], 0} = Storage.list_files_in_scope(nil, folder_uuid: gone.uuid, subtree: true)
  end

  test "the viewer sees the files of the subtree that are theirs" do
    alice = user!("alice")
    bob = user!("bob")
    root = folder!("Root", nil)
    child = folder!("Child", root)

    mine = file!(child, alice)
    _bobs = file!(child, bob)
    mine_top = file!(root, alice)

    opts = [subtree: true, viewer_uuid: alice.uuid]

    assert uuids(Storage.list_files_in_scope(root.uuid, opts)) ==
             Enum.sort([mine.uuid, mine_top.uuid])

    assert {_, 3} = Storage.list_files_in_scope(root.uuid, subtree: true)
  end

  test "the library is kept" do
    owner = user!("owner")

    {:ok, other} =
      Libraries.create_system_library(%{name: "Subtree #{System.unique_integer([:positive])}"})

    root = folder!("Root", nil)
    child = folder!("Child", root)

    media = file!(child, owner)
    foreign = file!(child, owner, %{library_uuid: other.uuid})

    assert uuids(
             Storage.list_files_in_scope(root.uuid,
               subtree: true,
               library_uuid: Libraries.media_uuid()
             )
           ) == [media.uuid]

    assert uuids(Storage.list_files_in_scope(root.uuid, subtree: true, library_uuid: other.uuid)) ==
             [foreign.uuid]
  end

  test "folder_name_chains/1 gives the chains folder_breadcrumbs/1 does, for many folders at once" do
    a = folder!("A", nil)
    b = folder!("B", a)
    c = folder!("C", b)
    d = folder!("D", a)
    missing = Ecto.UUID.generate()

    chains = Storage.folder_name_chains([c.uuid, d.uuid, c.uuid, nil, missing])

    assert Map.keys(chains) |> Enum.sort() == Enum.sort([c.uuid, d.uuid])

    for folder <- [c, d] do
      assert chains[folder.uuid] == Enum.map(Storage.folder_breadcrumbs(folder.uuid), & &1.name)
    end

    assert Helpers.breadcrumb_paths([c.uuid])[c.uuid] ==
             Helpers.breadcrumb_path(c.uuid)
  end

  test "folder_links_among/2 gives the links of many files in one go, homes not counted" do
    owner = user!("owner")
    home = folder!("Home", nil)
    target = folder!("Target", nil)
    a = file!(home, owner)
    b = file!(home, owner)
    c = file!(target, owner)
    {:ok, _} = Storage.create_folder_link(target.uuid, a.uuid)

    assert Storage.folder_links_among([a.uuid, b.uuid, c.uuid], [target.uuid, home.uuid]) ==
             [{a.uuid, target.uuid}]

    assert Storage.folder_links_among([], [target.uuid]) == []
    assert Storage.folder_links_among([a.uuid], []) == []
  end

  test "folder_subtree_uuids/2 with live: true leaves out folders in the trash and what is under them" do
    root = folder!("Root", nil)
    live = folder!("Live", root)
    gone = folder!("Gone", root)
    under_gone = folder!("UnderGone", gone)

    assert Enum.sort(Storage.folder_subtree_uuids(root.uuid)) ==
             Enum.sort([root.uuid, live.uuid, gone.uuid, under_gone.uuid])

    {:ok, _} = Storage.trash_folder(Repo.get(Storage.Folder, gone.uuid))

    assert Enum.sort(Storage.folder_subtree_uuids(root.uuid, live: true)) ==
             Enum.sort([root.uuid, live.uuid])

    # The default still walks all of it, as trash and restore need.
    assert gone.uuid in Storage.folder_subtree_uuids(root.uuid)
    assert Storage.folder_subtree_uuids(gone.uuid, live: true) == []
  end
end
