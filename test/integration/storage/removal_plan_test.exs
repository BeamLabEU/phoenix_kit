defmodule PhoenixKit.Modules.Storage.RemovalPlanTest do
  @moduledoc """
  `Storage.removal_plan/2` says which files an action makes disappear (trash,
  delete) and which it only moves or unlinks. The operations decide through
  the same primitives, so the plan and the fact cannot drift: each case below
  asserts the plan, then runs the operation and asserts the fact matches.
  """

  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Users.Auth

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "removal-plan-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp file!(user) do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "t.png",
        file_name: "t.png",
        file_path: "x/t-#{System.unique_integer([:positive])}.png",
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

  defp folder!(user, name, parent \\ nil) do
    {:ok, folder} =
      Storage.create_folder(%{
        name: "#{name}-#{System.unique_integer([:positive])}",
        parent_uuid: parent && parent.uuid,
        user_uuid: user.uuid
      })

    folder
  end

  defp home!(file, folder) do
    {:ok, _} = Storage.move_file_to_folder(file.uuid, folder.uuid, nil)
    Repo.get(File, file.uuid)
  end

  defp empty, do: %{trash: [], delete: [], rehome: [], unlink: []}

  setup do
    %{user: user!()}
  end

  describe "a file removed from a folder" do
    test "homed there and held nowhere else: trash", %{user: user} do
      a = folder!(user, "a")
      file = home!(file!(user), a)

      assert Storage.removal_plan(:remove_file, {file, a.uuid}) == %{empty() | trash: [file.uuid]}
      assert {:ok, :trashed, _} = Storage.remove_file_from_folder(file, a.uuid)
    end

    test "viewed outside any folder: trash", %{user: user} do
      file = file!(user)

      assert Storage.removal_plan(:remove_file, {file, nil}) == %{empty() | trash: [file.uuid]}
    end

    test "homed there and linked into a live folder: rehome, nothing disappears", %{user: user} do
      a = folder!(user, "a")
      b = folder!(user, "b")
      file = home!(file!(user), a)
      {:ok, _} = Storage.create_folder_link(b.uuid, file.uuid)

      assert Storage.removal_plan(:remove_file, {file, a.uuid}) == %{
               empty()
               | rehome: [file.uuid]
             }

      assert {:ok, :rehomed, _} = Storage.remove_file_from_folder(file, a.uuid)
    end

    test "homed there and linked only into a trashed folder: trash", %{user: user} do
      a = folder!(user, "a")
      b = folder!(user, "b")
      file = home!(file!(user), a)
      {:ok, _} = Storage.create_folder_link(b.uuid, file.uuid)
      {:ok, _} = Storage.trash_folder(b)

      assert Storage.removal_plan(:remove_file, {file, a.uuid}) == %{empty() | trash: [file.uuid]}
      assert {:ok, :trashed, _} = Storage.remove_file_from_folder(file, a.uuid)
    end

    test "linked into the folder, home elsewhere: unlink", %{user: user} do
      a = folder!(user, "a")
      b = folder!(user, "b")
      file = home!(file!(user), a)
      {:ok, _} = Storage.create_folder_link(b.uuid, file.uuid)

      assert Storage.removal_plan(:remove_file, {file, b.uuid}) == %{
               empty()
               | unlink: [file.uuid]
             }

      assert {:ok, :unlinked, _} = Storage.remove_file_from_folder(file, b.uuid)
    end

    test "not held by the folder, or already in the trash: nothing", %{user: user} do
      a = folder!(user, "a")
      b = folder!(user, "b")
      file = home!(file!(user), a)

      assert Storage.removal_plan(:remove_file, {file, b.uuid}) == empty()

      {:ok, trashed} = Storage.trash_file(file)
      assert Storage.removal_plan(:remove_file, {trashed, a.uuid}) == empty()
    end
  end

  describe "files deleted for good" do
    test "every live row is listed once", %{user: user} do
      one = file!(user)
      two = file!(user)

      plan = Storage.removal_plan(:delete_files, [one, two.uuid, one.uuid, Ecto.UUID.generate()])

      assert Enum.sort(plan.delete) == Enum.sort([one.uuid, two.uuid])
      assert %{plan | delete: []} == empty()
    end
  end

  describe "a folder trashed" do
    test "a file linked from inside the same subtree is still trashed", %{user: user} do
      a = folder!(user, "a")
      sub = folder!(user, "sub", a)
      x = home!(file!(user), a)
      {:ok, _} = Storage.create_folder_link(sub.uuid, x.uuid)

      assert Storage.removal_plan(:trash_folder, a) == %{empty() | trash: [x.uuid]}
      assert {:ok, _} = Storage.trash_folder(a)
      assert Repo.get(File, x.uuid).status == "trashed"
    end

    test "a file linked from outside the subtree is rehomed", %{user: user} do
      a = folder!(user, "a")
      out = folder!(user, "out")
      x = home!(file!(user), a)
      y = home!(file!(user), a)
      {:ok, _} = Storage.create_folder_link(out.uuid, x.uuid)

      assert Storage.removal_plan(:trash_folder, a) ==
               %{empty() | trash: [y.uuid], rehome: [x.uuid]}

      assert {:ok, _} = Storage.trash_folder(a)
      assert Repo.get(File, x.uuid).status == "active"
      assert Repo.get(File, y.uuid).status == "trashed"
    end

    test "files already in the trash are not listed again", %{user: user} do
      a = folder!(user, "a")
      x = home!(file!(user), a)
      {:ok, _} = Storage.trash_file(x)

      assert Storage.removal_plan(:trash_folder, a) == empty()
    end
  end

  describe "a folder deleted for good" do
    test "files confined to the subtree are deleted, shared ones rehomed", %{user: user} do
      a = folder!(user, "a")
      sub = folder!(user, "sub", a)
      out = folder!(user, "out")
      x = home!(file!(user), sub)
      shared = home!(file!(user), a)
      linked_inside = home!(file!(user), a)
      {:ok, _} = Storage.create_folder_link(out.uuid, shared.uuid)
      {:ok, _} = Storage.create_folder_link(sub.uuid, linked_inside.uuid)

      plan = Storage.removal_plan(:delete_folder, a)

      assert Enum.sort(plan.delete) == Enum.sort([x.uuid, linked_inside.uuid])
      assert plan.rehome == [shared.uuid]
      assert plan.trash == [] and plan.unlink == []

      assert {:ok, _} = Storage.delete_folder_completely(a)
      assert is_nil(Repo.get(File, x.uuid))
      assert is_nil(Repo.get(File, linked_inside.uuid))
      assert Repo.get(File, shared.uuid)
    end

    test "a live file whose only other folder is in the trash is trashed, not re-homed", %{
      user: user
    } do
      a = folder!(user, "a")
      gone = folder!(user, "gone")
      x = home!(file!(user), a)
      {:ok, _} = Storage.create_folder_link(gone.uuid, x.uuid)
      {:ok, _} = Storage.trash_folder(gone)

      assert Storage.removal_plan(:delete_folder, a) == %{empty() | delete: [], trash: [x.uuid]}

      assert {:ok, _} = Storage.delete_folder_completely(a)
      assert Repo.get(File, x.uuid).status == "trashed"
    end

    test "a file already in the trash moves on quietly: re-homed", %{user: user} do
      a = folder!(user, "a")
      gone = folder!(user, "gone")
      x = home!(file!(user), a)
      {:ok, _} = Storage.create_folder_link(gone.uuid, x.uuid)
      {:ok, _} = Storage.trash_folder(gone)
      {:ok, _} = Storage.trash_file(Repo.get(File, x.uuid))

      assert Storage.removal_plan(:delete_folder, a) == %{empty() | rehome: [x.uuid]}
    end

    test "a managed library's files and folders plan nothing: the operation refuses them", %{
      user: user
    } do
      n = System.unique_integer([:positive])

      {:ok, library} =
        Storage.Libraries.create_system_library(
          %{name: "Managed #{n}", slug: "managed-plan-#{n}"},
          hidden: true,
          media_listing: :uploaders,
          managed: true
        )

      {:ok, folder} =
        Storage.create_folder(%{name: "Held #{n}", library_uuid: library.uuid}, nil,
          managed: :owner
        )

      file = file!(user)

      Repo.update_all(from(f in File, where: f.uuid == ^file.uuid),
        set: [library_uuid: library.uuid, folder_uuid: folder.uuid]
      )

      file = Repo.get(File, file.uuid)

      assert Storage.removal_plan(:trash_folder, folder) == empty()
      assert Storage.removal_plan(:delete_folder, folder) == empty()
      assert Storage.removal_plan(:remove_file, {file, folder.uuid}) == empty()
      assert Storage.removal_plan(:delete_files, [file]) == empty()
    end
  end

  describe "empty_trash with except:" do
    test "leaves the named files in the trash and deletes the rest", %{user: user} do
      keep = file!(user)
      gone = file!(user)
      {:ok, _} = Storage.trash_file(keep)
      {:ok, _} = Storage.trash_file(gone)

      assert {:ok, 1} = Storage.empty_trash(nil, except: [keep.uuid])

      assert Repo.get(File, keep.uuid).status == "trashed"
      assert is_nil(Repo.get(File, gone.uuid))
    end
  end
end
