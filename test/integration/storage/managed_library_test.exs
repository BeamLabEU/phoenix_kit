defmodule PhoenixKit.Modules.Storage.ManagedLibraryTest do
  @moduledoc """
  A hidden system library that a module shows in Media and keeps read-only
  (`create_system_library(attrs, hidden: true, media_listing: …, managed: true)`):

    * who finds it (`list_system_libraries_for/1`, `media_viewer_uuid/2`) —
      the table of `media_listing`;
    * every user operation on its files and folders is `{:error, :managed}`
      in the Storage context, and works with `managed: :owner`;
    * the processing of a stored file (`update_file`, `update_file_instance`)
      is not a user operation and still runs;
    * `can?(:edit)` is false for all, and burn, the annotated thumbnail, the
      image editor (`system: true` included) refuse before any owner branch;
    * its files stay private: no permanent URL, never orphans;
    * the savepoint of a folder or link insert keeps the caller's transaction.

  Skipped when ImageMagick isn't installed.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.TestSupport.LinkCopyHelpers

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    AnnotationThumbnail,
    AnnotationThumbnailJob,
    ApplyImageEditJob,
    EtcherAdapter,
    FolderLink,
    ImageEditing,
    Libraries,
    Library
  }

  alias PhoenixKit.Users.{Auth, Permissions, Role, Roles}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.AnnotationBurnController, as: Burn

  @moduletag :tmp_dir

  unless imagemagick?(),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  setup %{tmp_dir: tmp} do
    if imagemagick?() do
      env = setup_storage(tmp)
      n = env.n

      {:ok, media_role} = Roles.create_role(%{name: "Media holders #{n}"})
      {:ok, _} = Permissions.grant_permission(media_role.uuid, "media")

      {:ok, editor_role} = Roles.create_role(%{name: "Media editors #{n}"})

      for key <- ~w(media media.view_all media.manage),
          do: {:ok, _} = Permissions.grant_permission(editor_role.uuid, key)

      {:ok, library} =
        Libraries.create_system_library(%{name: "Mail files #{n}", slug: "mail-files-#{n}"},
          hidden: true,
          media_listing: :uploaders,
          managed: true
        )

      uploader = role_user!("uploader", n, media_role)
      editor = role_user!("editor", n, editor_role)
      plain = role_user!("plain", n, nil)
      {admin, _token} = PhoenixKitWeb.ConnCase.create_admin_user()

      file = upload!(uploader, image!(tmp, "mail.jpg"), library_uuid: library.uuid)

      {:ok, folder} =
        Storage.create_folder(%{name: "Order 1", library_uuid: library.uuid}, nil,
          managed: :owner
        )

      {:ok, other_folder} =
        Storage.create_folder(%{name: "Order 2", library_uuid: library.uuid}, nil,
          managed: :owner
        )

      {:ok, file} = Storage.move_file_to_folder(file.uuid, folder.uuid, nil, managed: :owner)

      Map.merge(env, %{
        library: library,
        uploader: uploader,
        editor: editor,
        plain: plain,
        admin: admin,
        mail: file,
        folder: folder,
        other_folder: other_folder
      })
    else
      {:ok, skip: true}
    end
  end

  defp role_user!(tag, n, role) do
    user = user!(tag, n)
    if role, do: {:ok, _} = Roles.assign_role(user, role.name)
    Repo.get!(Auth.User, user.uuid)
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  # An Owner by the roles the scope carries (the first registered user is not
  # always one in a test database).
  defp owner_scope(user),
    do: %{scope(user) | cached_roles: [Role.system_roles().owner]}

  defp fresh(file), do: Storage.get_file(file.uuid)

  # A file of the managed library that a test may spoil.
  defp another_file!(ctx, color) do
    upload!(ctx.uploader, image!(ctx.tmp, "#{color}.jpg", color), library_uuid: ctx.library.uuid)
  end

  test "a media manager cannot change a managed library’s CDN preferences", ctx do
    scope = scope(ctx.editor)
    assert Scope.has_module_access?(scope, "media.manage")

    assert {:error, :managed} =
             Storage.CDN.save_library(scope, ctx.library.uuid, %{
               "connection" => "bucket",
               "mode" => "inherit"
             })
  end

  describe "creating and changing the listing" do
    test "a hidden library is born with what it asks for", ctx do
      assert Libraries.media_listing(ctx.library) == :uploaders
      assert Libraries.managed?(ctx.library)
      assert Libraries.managed?(ctx.library.uuid)
      assert Libraries.managed?(ctx.mail)
      assert Libraries.hidden?(ctx.library)
      assert ctx.library.visibility == "private"
    end

    test "without the options it is hidden for good, and not managed", ctx do
      {:ok, plain} =
        Libraries.create_system_library(%{name: "Plain #{ctx.n}", slug: "plain-#{ctx.n}"},
          hidden: true
        )

      assert Libraries.media_listing(plain) == :none
      refute Libraries.managed?(plain)
      refute plain in Libraries.list_system_libraries_for(scope(ctx.admin))
    end

    test "a bad listing or flag is an error on :settings, and nothing is created", ctx do
      for opts <- [[media_listing: :everyone], [managed: "yes"]] do
        assert {:error, changeset} =
                 Libraries.create_system_library(
                   %{name: "Bad #{ctx.n}", slug: "bad-#{ctx.n}"},
                   [hidden: true] ++ opts
                 )

        assert Keyword.has_key?(changeset.errors, :settings)
      end

      refute Repo.get_by(Library, slug: "bad-#{ctx.n}")
    end

    test "a site library ignores both", ctx do
      {:ok, site} =
        Libraries.create_system_library(%{name: "Site #{ctx.n}"},
          media_listing: :admins,
          managed: true
        )

      refute Libraries.managed?(site)
      assert site.settings == %{}
    end

    test "update_system_library_listing/2 moves updated_at", ctx do
      old = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(l in Library, where: l.uuid == ^ctx.library.uuid),
        set: [updated_at: old]
      )

      assert {:ok, updated} =
               Libraries.update_system_library_listing(ctx.library, media_listing: :admins)

      assert DateTime.compare(updated.updated_at, old) == :gt
    end

    test "update_system_library_listing/2 sets only the keys given and is idempotent", ctx do
      assert {:ok, updated} =
               Libraries.update_system_library_listing(ctx.library, media_listing: :own_only)

      assert Libraries.media_listing(updated) == :own_only
      assert Libraries.managed?(updated)

      assert {:ok, updated} = Libraries.update_system_library_listing(updated, managed: false)
      refute Libraries.managed?(updated)
      assert Libraries.media_listing(updated) == :own_only

      assert {:ok, again} = Libraries.update_system_library_listing(updated, managed: false)
      assert again.settings == updated.settings
    end

    test "it turns an existing hidden library into a shown, managed one", ctx do
      {:ok, old} =
        Libraries.create_system_library(%{name: "Old #{ctx.n}", slug: "old-#{ctx.n}"},
          hidden: true
        )

      assert {:ok, new} =
               Libraries.update_system_library_listing(old,
                 media_listing: :admins,
                 managed: true
               )

      assert Libraries.media_listing(new) == :admins
      assert Libraries.managed?(new)
      assert new in Libraries.list_system_libraries_for(scope(ctx.admin))
    end

    test "refuses a site library and a bad value, and changes nothing", ctx do
      {:ok, site} = Libraries.create_system_library(%{name: "Site #{ctx.n}"})

      assert {:error, :not_hidden} =
               Libraries.update_system_library_listing(site, managed: true)

      assert {:error, :invalid_value} =
               Libraries.update_system_library_listing(ctx.library, media_listing: :all)

      assert {:error, :invalid_value} =
               Libraries.update_system_library_listing(ctx.library, managed: :owner)

      assert Libraries.get_library(site.uuid).settings == %{}
      assert Libraries.get_library(ctx.library.uuid).settings == ctx.library.settings
    end

    test "a user library and Media are never managed", ctx do
      refute Libraries.managed?(Libraries.media_uuid())
      refute Libraries.managed?(nil)
      refute Libraries.managed?(Ecto.UUID.generate())
      refute Libraries.managed?("not a uuid")
      assert Libraries.check_managed(ctx.mail) == {:error, :managed}
      assert Libraries.check_managed(ctx.mail, managed: :owner) == :ok
    end
  end

  describe "who finds it (test 9)" do
    defp listed?(ctx, user), do: ctx.library in Libraries.list_system_libraries_for(scope(user))

    defp with_listing(ctx, listing) do
      {:ok, library} =
        Libraries.update_system_library_listing(ctx.library, media_listing: listing)

      %{ctx | library: library}
    end

    test ":none shows it to no one", ctx do
      ctx = with_listing(ctx, :none)

      for user <- [ctx.admin, ctx.editor, ctx.uploader, ctx.plain],
          do: refute(listed?(ctx, user))
    end

    test ":admins shows it to an Owner/Admin only", ctx do
      ctx = with_listing(ctx, :admins)

      assert listed?(ctx, ctx.admin)
      assert ctx.library in Libraries.list_system_libraries_for(owner_scope(ctx.admin))
      refute listed?(ctx, ctx.editor)
      refute listed?(ctx, ctx.uploader)
      refute listed?(ctx, ctx.plain)
    end

    test ":uploaders shows it to an Owner/Admin and to any holder of media", ctx do
      ctx = with_listing(ctx, :uploaders)

      assert listed?(ctx, ctx.admin)
      assert listed?(ctx, ctx.editor)
      assert listed?(ctx, ctx.uploader)
      refute listed?(ctx, ctx.plain)
    end

    test ":own_only shows it to an Owner/Admin and to any holder of media", ctx do
      ctx = with_listing(ctx, :own_only)

      assert listed?(ctx, ctx.admin)
      assert listed?(ctx, ctx.editor)
      assert listed?(ctx, ctx.uploader)
      refute listed?(ctx, ctx.plain)
    end

    test "whose files it lists: all for an Owner/Admin, the viewer's own otherwise", ctx do
      admin = scope(ctx.admin)
      editor = scope(ctx.editor)
      uploader = scope(ctx.uploader)

      for listing <- [:admins, :uploaders] do
        ctx = with_listing(ctx, listing)
        assert Libraries.media_viewer_uuid(admin, ctx.library) == nil
        assert Libraries.media_viewer_uuid(owner_scope(ctx.admin), ctx.library) == nil
      end

      ctx = with_listing(ctx, :uploaders)
      assert Libraries.media_viewer_uuid(uploader, ctx.library) == ctx.uploader.uuid
      # media.view_all does not widen "only their own".
      assert Libraries.media_viewer_uuid(editor, ctx.library) == ctx.editor.uuid
    end

    test ":own_only is the viewer's own even for an Owner/Admin and a view_all holder", ctx do
      ctx = with_listing(ctx, :own_only)

      assert Libraries.media_viewer_uuid(scope(ctx.admin), ctx.library) == ctx.admin.uuid
      assert Libraries.media_viewer_uuid(owner_scope(ctx.admin), ctx.library) == ctx.admin.uuid
      assert Libraries.media_viewer_uuid(scope(ctx.editor), ctx.library) == ctx.editor.uuid
      # …and it limits the browser only: an Owner/Admin still reads any file.
      assert Libraries.can?(scope(ctx.admin), ctx.mail, :read)
    end

    test "a site library keeps the viewer's rights, and every viewer is offered Media", ctx do
      {:ok, site} = Libraries.create_system_library(%{name: "Brand #{ctx.n}"})

      for user <- [ctx.admin, ctx.editor, ctx.uploader] do
        list = Libraries.list_system_libraries_for(scope(user))
        assert site in list
        assert Enum.any?(list, & &1.is_default)
      end

      assert Libraries.media_viewer_uuid(scope(ctx.admin), site) == nil
      assert Libraries.media_viewer_uuid(scope(ctx.editor), site) == nil
      assert Libraries.media_viewer_uuid(scope(ctx.uploader), site) == ctx.uploader.uuid
    end

    test "the plain list of site libraries still leaves it out", ctx do
      refute ctx.library in Libraries.list_system_libraries()
      refute Libraries.listed_for?(scope(ctx.admin), %{ctx.library | slug: nil})
      assert Libraries.get_system_library(ctx.library.uuid) == nil
      assert Libraries.get_system_library_by_slug(ctx.library.slug) == nil
      assert Libraries.get_hidden_library_by_slug(ctx.library.slug).uuid == ctx.library.uuid
    end
  end

  describe "files: user operations are refused (test 10)" do
    test "trash_file, by struct and by uuid; remove from a folder or from none", ctx do
      assert {:error, :managed} = Storage.trash_file(ctx.mail)
      assert {:error, :managed} = Storage.trash_file(ctx.mail.uuid)
      assert {:error, :managed} = Storage.remove_file_from_folder(ctx.mail, ctx.folder.uuid)
      assert {:error, :managed} = Storage.remove_file_from_folder(ctx.mail, nil)

      assert %{status: "active", trashed_at: nil} = fresh(ctx.mail)
    end

    test "delete_file_completely, by struct and by uuid", ctx do
      assert {:error, :managed} = Storage.delete_file_completely(ctx.mail)
      assert {:error, :managed} = Storage.delete_file_completely(ctx.mail.uuid)

      assert fresh(ctx.mail)
      assert all_keys_exist?(Map.values(keys(ctx.mail)))
    end

    test "moving: move_file_to_folder, move_file_between_folders, attach_file_to_folder", ctx do
      assert {:error, :managed} = Storage.move_file_to_folder(ctx.mail.uuid, nil)

      assert {:error, :managed} =
               Storage.move_file_to_folder(ctx.mail.uuid, ctx.other_folder.uuid)

      assert {:error, :managed} =
               Storage.move_file_to_folder(ctx.mail.uuid, ctx.other_folder.uuid, ctx.folder.uuid)

      assert {:error, :managed} =
               Storage.move_file_between_folders(
                 ctx.mail.uuid,
                 ctx.folder.uuid,
                 ctx.other_folder.uuid,
                 nil
               )

      assert {:error, :managed} = Storage.attach_file_to_folder(ctx.mail, ctx.other_folder.uuid)

      assert fresh(ctx.mail).folder_uuid == ctx.folder.uuid
      assert Storage.folder_link(ctx.other_folder.uuid, ctx.mail.uuid) == nil
    end

    test "a file does not leave the library or arrive in it by a move", ctx do
      media_file = upload!(ctx.uploader, image!(ctx.tmp, "media.jpg", "blue"))
      {:ok, media_folder} = Storage.create_folder(%{name: "Media folder #{ctx.n}"})

      assert {:error, _} = Storage.move_file_to_folder(media_file.uuid, ctx.folder.uuid)
      assert {:error, :managed} = Storage.move_file_to_folder(ctx.mail.uuid, media_folder.uuid)
      assert fresh(media_file).folder_uuid == nil
      assert fresh(ctx.mail).folder_uuid == ctx.folder.uuid
    end

    test "update_file_metadata (a rotation, a burn's fingerprint), by struct and by uuid", ctx do
      rotate = &Map.put(&1, "rotation", 90)

      assert {:error, :managed} = Storage.update_file_metadata(ctx.mail, rotate)
      assert {:error, :managed} = Storage.update_file_metadata(ctx.mail.uuid, rotate)
      refute Map.has_key?(fresh(ctx.mail).metadata || %{}, "rotation")
    end

    test "the title, alt text and description in one language or in several", ctx do
      assert {:error, :managed} = Storage.update_file_details(ctx.mail, %{"title" => "Mine"})

      assert {:error, :managed} =
               Storage.update_file_details_languages(ctx.mail, %{"en" => %{"title" => "Mine"}})

      assert {:error, :managed} =
               Storage.update_file_details_languages(
                 ctx.mail,
                 %{"en" => %{"title" => "Mine"}},
                 metadata: %{"tags" => ["x"]}
               )

      refute inspect(fresh(ctx.mail).metadata) =~ "Mine"
    end

    test "featured: the browser writes nothing, the details form is refused above", ctx do
      # `set_featured`/`unset_featured` only tell the host (a host-owned write);
      # what a host could write into the file itself is refused here.
      assert {:error, :managed} =
               Storage.update_file_metadata(ctx.mail, &Map.put(&1, "featured", true))
    end

    test "with managed: :owner every one of them works", ctx do
      owner = [managed: :owner]

      assert {:ok, _} =
               Storage.update_file_metadata(ctx.mail, &Map.put(&1, "rotation", 90), owner)

      assert {:ok, _} = Storage.update_file_details(ctx.mail, %{"title" => "Mine"}, owner)

      assert {:ok, _} =
               Storage.update_file_details_languages(
                 ctx.mail,
                 %{"en" => %{"title" => "Mine too"}},
                 owner
               )

      assert {:ok, moved} =
               Storage.move_file_to_folder(ctx.mail.uuid, ctx.other_folder.uuid, nil, owner)

      assert moved.folder_uuid == ctx.other_folder.uuid

      assert {:ok, _} =
               Storage.move_file_between_folders(
                 ctx.mail.uuid,
                 ctx.other_folder.uuid,
                 ctx.folder.uuid,
                 nil,
                 owner
               )

      assert fresh(ctx.mail).folder_uuid == ctx.folder.uuid
      assert {:ok, _} = Storage.attach_file_to_folder(ctx.mail, ctx.other_folder.uuid, owner)
      assert Storage.folder_link(ctx.other_folder.uuid, ctx.mail.uuid)

      link = Storage.folder_link(ctx.other_folder.uuid, ctx.mail.uuid)
      assert {:ok, _} = Storage.delete_folder_link(link.uuid, owner)

      assert {:ok, _} = Storage.delete_file_completely(ctx.mail.uuid, owner)
      assert fresh(ctx.mail) == nil
    end

    test "there is no trash: not even the owner module trashes or restores a file", ctx do
      other = another_file!(ctx, "green")

      # `trash_file/1`, `remove_file_from_folder/2` and `restore_*` take no owner option.
      assert {:error, :managed} = Storage.trash_file(other)
      assert {:error, :managed} = Storage.remove_file_from_folder(ctx.mail, ctx.folder.uuid)
      assert {:error, :managed} = Storage.remove_file_from_folder(other, nil)
      assert {:error, :managed} = Storage.restore_file(other)
      assert {:error, :managed} = Storage.restore_file(other.uuid)
      assert {:error, :managed} = Storage.restore_file_into(other, nil)

      # A file trashed before its library became managed stays where it is.
      Repo.update_all(from(f in Storage.File, where: f.uuid == ^other.uuid),
        set: [status: "trashed", trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      assert {:error, :managed} = Storage.restore_file(fresh(other))
      assert {:error, :managed} = Storage.restore_file_into(fresh(other), nil)

      assert {:error, :managed} =
               Storage.move_file_between_folders(other.uuid, nil, ctx.folder.uuid, nil)

      assert fresh(other).status == "trashed"
    end

    test "emptying and pruning the trash log a file that cannot be deleted and do not count it",
         ctx do
      other = another_file!(ctx, "green")

      Repo.update_all(from(f in Storage.File, where: f.uuid == ^other.uuid),
        set: [status: "trashed", trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 0} = Storage.prune_trash(-1)
          assert {:ok, 0} = Storage.empty_trash(nil, library_uuid: ctx.library.uuid)
        end)

      assert log =~ other.uuid
      assert log =~ ":managed"
      assert fresh(other)
      assert all_keys_exist?(Map.values(keys(other)))

      # A file that can be deleted is still counted.
      media = upload!(ctx.uploader, image!(ctx.tmp, "gone.jpg", "teal"))
      assert {:ok, _} = Storage.trash_file(media)

      {{:ok, deleted}, _log} =
        ExUnit.CaptureLog.with_log(fn -> Storage.prune_trash(-1) end)

      assert deleted >= 1
      assert fresh(media) == nil
    end

    test "the owner's delete takes the record and only the keys nobody else names", ctx do
      donor = upload!(ctx.uploader, image!(ctx.tmp, "donor.jpg", "yellow"))

      {:ok, copy} =
        Storage.link_copy(donor, ctx.uploader.uuid,
          library_uuid: ctx.library.uuid,
          original_filename: "mail.jpg"
        )

      shared = Map.values(keys(copy))
      assert {:ok, _} = Storage.delete_file_completely(copy, managed: :owner)
      assert fresh(copy) == nil
      assert all_keys_exist?(shared)
    end
  end

  describe "folders: user operations are refused (test 10)" do
    test "create_folder, at the root and under a parent there", ctx do
      assert {:error, :managed} =
               Storage.create_folder(%{name: "Mine", library_uuid: ctx.library.uuid})

      assert {:error, :managed} =
               Storage.create_folder(%{name: "Mine", parent_uuid: ctx.folder.uuid})

      assert {:error, :managed} =
               Storage.create_folder(%{"name" => "Mine", "library_uuid" => ctx.library.uuid})

      assert {:error, :managed} =
               Storage.create_folder(
                 %{name: "Mine", parent_uuid: ctx.folder.uuid},
                 ctx.folder.uuid
               )

      refute Repo.get_by(Storage.Folder, name: "Mine")
    end

    test "update_folder (rename, recolour, move), trash, restore, delete, delete completely",
         ctx do
      assert {:error, :managed} = Storage.update_folder(ctx.folder, %{name: "Renamed"})
      assert {:error, :managed} = Storage.update_folder(ctx.folder, %{color: "#ff0000"})

      assert {:error, :managed} =
               Storage.update_folder(ctx.folder, %{parent_uuid: ctx.other_folder.uuid})

      assert {:error, :managed} = Storage.trash_folder(ctx.folder)
      assert {:error, :managed} = Storage.trash_folder(ctx.folder, nil)
      assert {:error, :managed} = Storage.restore_folder(ctx.folder)
      assert {:error, :managed} = Storage.delete_folder(ctx.folder)
      assert {:error, :managed} = Storage.delete_folder_completely(ctx.folder)

      assert %{name: "Order 1", trashed_at: nil, parent_uuid: nil} =
               Storage.get_folder(ctx.folder.uuid)

      assert fresh(ctx.mail).status == "active"
    end

    test "a folder of Media is not moved into it, nor out of it", ctx do
      {:ok, media_folder} = Storage.create_folder(%{name: "Media only #{ctx.n}"})

      assert {:error, _} = Storage.update_folder(media_folder, %{parent_uuid: ctx.folder.uuid})

      assert {:error, :managed} =
               Storage.update_folder(ctx.folder, %{parent_uuid: media_folder.uuid})

      assert Storage.get_folder(media_folder.uuid).parent_uuid == nil
    end

    test "folder links: create and delete", ctx do
      assert {:error, :managed} = Storage.create_folder_link(ctx.other_folder.uuid, ctx.mail.uuid)

      assert {:ok, link} =
               Storage.create_folder_link(ctx.other_folder.uuid, ctx.mail.uuid, nil,
                 managed: :owner
               )

      assert {:error, :managed} = Storage.delete_folder_link(link.uuid)
      assert Repo.get(FolderLink, link.uuid)
      assert {:ok, _} = Storage.delete_folder_link(link.uuid, managed: :owner)
      refute Repo.get(FolderLink, link.uuid)
    end

    test "with managed: :owner they all work", ctx do
      owner = [managed: :owner]

      assert {:ok, root} =
               Storage.create_folder(%{name: "Root", library_uuid: ctx.library.uuid}, nil, owner)

      assert {:ok, sub} =
               Storage.create_folder(%{name: "Sub", parent_uuid: root.uuid}, nil, owner)

      assert sub.library_uuid == ctx.library.uuid
      assert {:ok, sub} = Storage.update_folder(sub, %{name: "Sub 2"}, nil, owner)
      assert sub.name == "Sub 2"
      # No trash, even for the owner.
      assert {:error, :managed} = Storage.trash_folder(root)
      assert {:error, :managed} = Storage.restore_folder(root)
      assert {:ok, _} = Storage.delete_folder(sub, nil, owner)
      assert {:ok, _} = Storage.delete_folder_completely(root, nil, owner)
      assert Storage.get_folder(root.uuid) == nil
    end

    test "the library's own folders are still listed and found, read-only", ctx do
      assert ctx.folder.uuid in Enum.map(
               Storage.list_folders(nil, nil, library_uuid: ctx.library.uuid),
               & &1.uuid
             )
    end
  end

  describe "a stored file is processed (test 10)" do
    test "a full copy written into the library becomes active, with its sizes", ctx do
      path = image!(ctx.tmp, "full-copy.jpg", "purple")
      file = upload!(ctx.uploader, path, library_uuid: ctx.library.uuid)

      assert file.status == "active"
      assert file.width && file.height
      assert file.library_uuid == ctx.library.uuid
      assert map_size(keys(file)) > 1
      assert Libraries.managed?(file)
    end

    test "a fresh copy has not been processed yet, and the job runs on a managed library", ctx do
      path = image!(ctx.tmp, "slow.jpg", "orange")
      sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

      {:ok, file} =
        Storage.store_file_in_buckets(path, "image", ctx.uploader.uuid, sha, "jpg", "slow.jpg",
          library_uuid: ctx.library.uuid,
          dedup: false
        )

      assert file.status == "processing"
      file = run_job!(file, "slow.jpg")
      assert file.status == "active"
      assert file.width
    end

    test "update_file and update_file_instance are not user operations: they stay open", ctx do
      assert {:ok, updated} = Storage.update_file(ctx.mail, %{width: 17})
      assert updated.width == 17

      original = instance(ctx.mail, "original")
      assert {:ok, _} = Storage.update_file_instance(original, %{width: 17})
    end

    test "the capture date is recorded for the file", ctx do
      date = ~U[2024-05-06 07:08:09Z]

      assert {:ok, updated} =
               Storage.update_file(ctx.mail, %{taken_at: date, taken_at_source: "exif"})

      assert updated.taken_at == date
      assert updated.taken_at_source == "exif"
    end
  end

  describe "editing and burning (test 12)" do
    test "can?(:edit) is false for everyone, an Owner included; :read is unchanged", ctx do
      for scope <- [
            owner_scope(ctx.admin),
            scope(ctx.admin),
            scope(ctx.uploader),
            scope(ctx.editor)
          ] do
        refute Libraries.can?(scope, ctx.mail, :edit)
      end

      assert Libraries.can?(scope(ctx.uploader), ctx.mail, :read)
      assert Libraries.can?(scope(ctx.admin), ctx.mail, :read)
      refute Libraries.can?(scope(ctx.editor), ctx.mail, :read)
    end

    test "a file of Media is still editable by its uploader and an Admin", ctx do
      media_file = upload!(ctx.uploader, image!(ctx.tmp, "m.jpg", "teal"))

      assert Libraries.can?(scope(ctx.uploader), media_file, :edit)
      assert Libraries.can?(scope(ctx.admin), media_file, :edit)
    end

    test "burn: the owner, an Admin and a media editor are refused before the owner branch",
         ctx do
      user = Repo.get!(Auth.User, ctx.uploader.uuid)

      refute Burn.allowed?(ctx.mail, user, scope(user))
      refute Burn.allowed?(ctx.mail, ctx.admin, scope(ctx.admin))
      refute Burn.allowed?(ctx.mail, ctx.editor, scope(ctx.editor))

      media_file = upload!(ctx.uploader, image!(ctx.tmp, "m2.jpg", "teal"))
      assert Burn.allowed?(media_file, user, scope(user))
    end

    test "the burn endpoint answers 403 and writes no variant", ctx do
      user = Repo.get!(Auth.User, ctx.uploader.uuid)
      markup = image!(ctx.tmp, "markup.jpg", "white")
      before = instances(ctx.mail)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:phoenix_kit_current_user, user)
        |> Burn.create(%{
          "file_uuid" => ctx.mail.uuid,
          "image" => %Plug.Upload{path: markup, filename: "burn.jpg", content_type: "image/jpeg"},
          "variants" => "burned"
        })

      assert conn.status == 403
      assert instances(ctx.mail) == before
      refute instance(ctx.mail, "burned")
    end

    test "the annotated thumbnail is not baked: refresh, enqueue and the job refuse", ctx do
      {:ok, _} = Annotations.create(annotation(ctx, ctx.mail))
      before = Enum.map(instances(ctx.mail), & &1.variant_name)

      assert {:error, :managed} = AnnotationThumbnail.refresh(ctx.mail.uuid)
      assert :ok = AnnotationThumbnailJob.enqueue(ctx.mail.uuid)
      refute Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker(AnnotationThumbnailJob)))

      assert {:cancel, :managed} =
               AnnotationThumbnailJob.perform(%Oban.Job{args: %{"file_uuid" => ctx.mail.uuid}})

      assert Enum.map(instances(ctx.mail), & &1.variant_name) == before
      refute instance(ctx.mail, "thumbnail_annotated")
    end

    test "the image editor: scope, owner and system: true are all refused", ctx do
      for opts <- [
            [scope: scope(ctx.uploader)],
            [scope: scope(ctx.admin)],
            [scope: owner_scope(ctx.admin)],
            [system: true],
            [system: true, scope: scope(ctx.admin)]
          ] do
        assert {:error, :managed} = ImageEditing.edit(ctx.mail, %{"rotate" => 90}, opts)
        assert {:error, :managed} = ImageEditing.revert(ctx.mail, opts)
        assert {:error, :managed} = ImageEditing.retry(ctx.mail, opts)
        assert {:error, :managed} = ImageEditing.save_copy(ctx.mail, %{"rotate" => 90}, opts)
        assert {:error, :managed} = ImageEditing.delete_unedited_original(ctx.mail, opts)
        refute ImageEditing.can_edit?(ctx.mail, opts)
      end

      assert {:error, :managed} = ImageEditing.bake(ctx.mail.uuid, ctx.mail.edit_revision)

      assert %{edits: nil, edit_state: nil} = fresh(ctx.mail)
      refute Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker(ApplyImageEditJob)))
    end

    test "the same calls on a file of Media still edit it (system: true)", ctx do
      media_file = upload!(ctx.uploader, image!(ctx.tmp, "m3.jpg", "teal"))
      assert {:ok, _} = ImageEditing.edit(media_file, %{"rotate" => 90}, system: true)
    end

    test "there is no image editing for the library's owner either", ctx do
      for opts <- [[system: true, managed: :owner], [managed: :owner]] do
        refute ImageEditing.can_edit?(ctx.mail, opts)
        assert {:error, :managed} = ImageEditing.edit(ctx.mail, %{"rotate" => 90}, opts)
        assert {:error, :managed} = ImageEditing.revert(ctx.mail, opts)
        assert {:error, :managed} = ImageEditing.retry(ctx.mail, opts)
        assert {:error, :managed} = ImageEditing.save_copy(ctx.mail, %{"rotate" => 90}, opts)
        assert {:error, :managed} = ImageEditing.delete_unedited_original(ctx.mail, opts)
      end

      assert %{edit_state: nil, edits: nil} = fresh(ctx.mail)
      refute Repo.exists?(from(j in Oban.Job, where: j.worker == ^worker(ApplyImageEditJob)))
    end

    test "a queued edit job of a file that became managed changes nothing", ctx do
      {:ok, plain} =
        Libraries.create_system_library(%{name: "Later #{ctx.n}", slug: "later-#{ctx.n}"},
          hidden: true
        )

      file = upload!(ctx.uploader, image!(ctx.tmp, "later.jpg", "pink"), library_uuid: plain.uuid)
      {:ok, _} = Libraries.update_system_library_listing(plain, managed: true)

      assert {:cancel, :managed} =
               ApplyImageEditJob.perform(%Oban.Job{
                 args: %{"file_uuid" => file.uuid, "mode" => "apply"}
               })

      assert {:cancel, :managed} =
               ApplyImageEditJob.perform(%Oban.Job{
                 args: %{"file_uuid" => file.uuid, "mode" => "copy", "edits" => %{"rotate" => 90}}
               })
    end

    test "annotations: drawing, changing and rubbing out are refused for the file", ctx do
      assert {:error, :managed} = EtcherAdapter.create(etcher_attrs(ctx.mail))

      {:ok, annotation} = Annotations.create(annotation(ctx, ctx.mail))

      assert {:error, :managed} = EtcherAdapter.update(annotation.uuid, %{"title" => "x"})
      assert {:error, :managed} = EtcherAdapter.delete(annotation.uuid)
      assert Annotations.get(annotation.uuid)

      assert {:ok, _} = EtcherAdapter.create(etcher_attrs(ctx.mail), managed: :owner)
      assert {:ok, _} = EtcherAdapter.update(annotation.uuid, %{"title" => "x"}, managed: :owner)
      assert :ok = EtcherAdapter.delete(annotation.uuid, managed: :owner)
    end

    test "annotations on a file of Media are drawn as before", ctx do
      media_file = upload!(ctx.uploader, image!(ctx.tmp, "m4.jpg", "teal"))
      assert {:ok, a} = EtcherAdapter.create(etcher_attrs(media_file))
      assert {:ok, _} = EtcherAdapter.update(a.uuid, %{"title" => "x"})
      assert :ok = EtcherAdapter.delete(a.uuid)
    end

    defp annotation(_ctx, file),
      do: %{
        file_uuid: file.uuid,
        kind: "rectangle",
        geometry: %{"x" => 0.1, "y" => 0.1, "w" => 0.2, "h" => 0.2}
      }

    defp etcher_attrs(file),
      do: %{
        "target_type" => "file",
        "target_uuid" => file.uuid,
        "kind" => "rectangle",
        "geometry" => %{"x" => 0.1, "y" => 0.1, "w" => 0.2, "h" => 0.2}
      }

    defp worker(module), do: module |> Module.split() |> Enum.join(".")
  end

  describe "private files (test 13)" do
    test "the library stays private: no permanent URL", ctx do
      assert ctx.library.visibility == "private"
      assert Libraries.private?(ctx.library.uuid)
      assert Libraries.private_file?(ctx.mail)
    end

    test "its files are never orphans, and are left out of nameless listings", ctx do
      refute ctx.mail.uuid in Enum.map(Storage.find_orphaned_files(), & &1.uuid)

      refute ctx.mail.uuid in Enum.map(
               Storage.find_orphaned_files(library_uuid: ctx.library.uuid),
               & &1.uuid
             )

      orphaned =
        from(f in Storage.File, where: f.uuid == ^ctx.mail.uuid)
        |> Libraries.exclude_user_libraries()
        |> Repo.all()

      assert orphaned == []
    end
  end

  describe "link_copy and relink_file with a managed library" do
    test "a managed donor goes to another library only for the managed owner", ctx do
      target = library!(ctx.n)
      opts = [library_uuid: target.uuid]

      assert {:error, :managed} = Storage.link_copy(ctx.mail, ctx.plain.uuid, opts)

      assert Repo.aggregate(
               from(f in Storage.File, where: f.library_uuid == ^target.uuid),
               :count
             ) == 0

      assert {:ok, copy} = Storage.link_copy(ctx.mail, ctx.plain.uuid, [managed: :owner] ++ opts)
      assert copy.library_uuid == target.uuid
    end

    test "a managed donor into its own managed library needs no owner", ctx do
      assert {:ok, copy} =
               Storage.link_copy(ctx.mail, ctx.uploader.uuid, library_uuid: ctx.library.uuid)

      assert copy.library_uuid == ctx.library.uuid
    end

    test "relink_file on a managed record is :managed, as a value and before anything is done",
         ctx do
      path = image!(ctx.tmp, "mail.jpg")
      record = upload!(ctx.uploader, path, library_uuid: ctx.library.uuid, dedup: false)
      donor = upload!(ctx.uploader, path)
      before = keys(record)

      assert {:error, :managed} = Storage.relink_file(record, donor, [])
      assert {:error, :managed} = Storage.relink_file(record, donor, delete_old: true)
      assert keys(record) == before

      assert {:ok, updated, _left} = Storage.relink_file(record, donor, managed: :owner)
      assert keys(updated) == keys(donor)
    end
  end

  describe "folder and link inserts keep the caller's transaction (savepoint)" do
    test "a name taken under the parent is an error value, and the transaction goes on", ctx do
      name = "Same name #{ctx.n}"
      attrs = %{name: name, library_uuid: ctx.library.uuid}

      assert {:ok, {:ok, _first, {:error, changeset}, found}} =
               Repo.transaction(fn ->
                 {:ok, first} = Storage.create_folder(attrs, nil, managed: :owner)
                 second = Storage.create_folder(attrs, nil, managed: :owner)
                 # A poisoned transaction would refuse this query.
                 found =
                   Repo.one(from(f in Storage.Folder, where: f.name == ^name, select: count()))

                 {:ok, first, second, found}
               end)

      assert Keyword.has_key?(changeset.errors, :name)
      assert found == 1
      assert Repo.aggregate(from(f in Storage.Folder, where: f.name == ^name), :count) == 1
    end

    test "a subfolder's name taken is the same", ctx do
      assert {:ok, {{:error, _}, 1}} =
               Repo.transaction(fn ->
                 {:ok, parent} =
                   Storage.create_folder(
                     %{name: "P #{ctx.n}", library_uuid: ctx.library.uuid},
                     nil,
                     managed: :owner
                   )

                 attrs = %{name: "Child", parent_uuid: parent.uuid}
                 {:ok, _} = Storage.create_folder(attrs, nil, managed: :owner)
                 second = Storage.create_folder(attrs, nil, managed: :owner)

                 {second,
                  Repo.aggregate(
                    from(f in Storage.Folder, where: f.parent_uuid == ^parent.uuid),
                    :count
                  )}
               end)
    end

    test "a link that is already there is an error value, and the transaction goes on", ctx do
      assert {:ok, {{:error, changeset}, 1}} =
               Repo.transaction(fn ->
                 args = [ctx.other_folder.uuid, ctx.mail.uuid, nil, [managed: :owner]]
                 {:ok, _} = apply(Storage, :create_folder_link, args)
                 second = apply(Storage, :create_folder_link, args)

                 {second,
                  Repo.aggregate(
                    from(l in FolderLink, where: l.file_uuid == ^ctx.mail.uuid),
                    :count
                  )}
               end)

      assert Keyword.has_key?(changeset.errors, :folder_uuid)
    end

    test "the conflict outside a transaction is the same error value", ctx do
      attrs = %{name: "Twice #{ctx.n}", library_uuid: ctx.library.uuid}
      assert {:ok, _} = Storage.create_folder(attrs, nil, managed: :owner)
      assert {:error, %Ecto.Changeset{}} = Storage.create_folder(attrs, nil, managed: :owner)
    end
  end
end
