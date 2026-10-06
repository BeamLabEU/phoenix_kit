defmodule PhoenixKit.Modules.Storage.LibrariesTest do
  @moduledoc """
  Storage libraries (V202), end to end against the database: Media holds
  everything that names no library, a second system library keeps its own
  folders, listings and uploads, nothing crosses from one library into the
  other, and access checks are what they were before libraries.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Library, StorageProfile}
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @media Libraries.media_uuid()
  @buckets_cache :phoenix_kit_buckets_cache

  defp library!(name \\ "Library #{System.unique_integer([:positive])}") do
    {:ok, library} = Libraries.create_system_library(%{name: name})
    library
  end

  describe "choosing storage when a system library is created" do
    alias PhoenixKit.Modules.Storage.{Profiles, VariantSets}

    test "a library names its profile and variant set once, at creation" do
      {:ok, profile} =
        Profiles.create_profile(%{name: "Chosen #{System.unique_integer([:positive])}"})

      {:ok, set} =
        VariantSets.create_variant_set(%{name: "Set #{System.unique_integer([:positive])}"})

      {:ok, library} =
        Libraries.create_system_library(%{
          name: "Chosen #{System.unique_integer([:positive])}",
          storage_profile_uuid: profile.uuid,
          variant_set_uuid: set.uuid
        })

      assert library.storage_profile_uuid == profile.uuid
      assert library.variant_set_uuid == set.uuid
    end

    test "blank, or the Default's own uuid, is stored as the Default (nil)" do
      {:ok, blank} =
        Libraries.create_system_library(%{
          name: "Blank #{System.unique_integer([:positive])}",
          storage_profile_uuid: "",
          variant_set_uuid: ""
        })

      {:ok, default} =
        Libraries.create_system_library(%{
          name: "Default #{System.unique_integer([:positive])}",
          storage_profile_uuid: Profiles.default_uuid(),
          variant_set_uuid: VariantSets.default_uuid()
        })

      for library <- [blank, default] do
        assert library.storage_profile_uuid == nil
        assert library.variant_set_uuid == nil
      end
    end

    test "a profile or set that does not exist refuses the library, and creates nothing" do
      name = "Refused #{System.unique_integer([:positive])}"

      assert {:error, changeset} =
               Libraries.create_system_library(%{
                 name: name,
                 storage_profile_uuid: Ecto.UUID.generate()
               })

      assert %{storage_profile_uuid: ["is not a storage profile"]} = errors_on(changeset)

      assert {:error, changeset} =
               Libraries.create_system_library(%{
                 name: name,
                 variant_set_uuid: Ecto.UUID.generate()
               })

      assert %{variant_set_uuid: ["is not a variant set"]} = errors_on(changeset)
      refute Enum.any?(Libraries.list_system_libraries(), &(&1.name == name))
    end

    test "a user's own profile is not one a site library can be created on" do
      user = user!()

      mine =
        Repo.insert!(%StorageProfile{
          name: "Mine #{System.unique_integer([:positive])}",
          owner_uuid: user.uuid
        })

      assert {:error, changeset} =
               Libraries.create_system_library(%{
                 name: "Theirs #{System.unique_integer([:positive])}",
                 storage_profile_uuid: mine.uuid
               })

      assert %{storage_profile_uuid: ["is not a storage profile"]} = errors_on(changeset)
    end
  end

  defp folder!(attrs) do
    {:ok, folder} =
      Storage.create_folder(Map.put_new(attrs, :name, "f-#{System.unique_integer([:positive])}"))

    folder
  end

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "libraries-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    user
  end

  defp with_local_bucket(fun) do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_libraries_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "libraries-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    try do
      fun.()
    after
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end
  end

  defp store!(user, library_uuid, content) do
    source =
      Path.join(System.tmp_dir!(), "pk_libraries_#{System.unique_integer([:positive])}.txt")

    File.write!(source, content)
    checksum = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)
    opts = if library_uuid, do: [library_uuid: library_uuid], else: []

    result =
      ExUnit.CaptureLog.with_log(fn ->
        Storage.store_file_in_buckets(
          source,
          "document",
          user.uuid,
          checksum,
          "txt",
          "a.txt",
          opts
        )
      end)

    File.rm(source)
    elem(result, 0)
  end

  describe "the libraries" do
    test "Media exists, is the default system library, and is listed first" do
      other = library!("Aardvark #{System.unique_integer([:positive])}")

      assert [%Library{uuid: @media, name: "Media", is_default: true} | rest] =
               Libraries.list_system_libraries()

      assert Enum.any?(rest, &(&1.uuid == other.uuid))
      assert Libraries.get_system_library(other.uuid)
      assert Libraries.system_library?(other.uuid)
    end

    test "a new library gets its own key prefix; names are unique, ignoring case" do
      library = library!("Brand")
      assert library.key_prefix =~ ~r/\Alib-[0-9a-f]{12}\z/
      assert {:error, changeset} = Libraries.create_system_library(%{name: "brand"})
      assert changeset.errors[:name]
      assert {:error, changeset} = Libraries.create_system_library(%{name: "  "})
      assert changeset.errors[:name]
    end

    test "a new library's URL slug comes from its name, suffixed while taken" do
      tag = System.unique_integer([:positive])
      first = library!("Brand Assets #{tag}")
      assert first.slug == "brand-assets-#{tag}"

      second = library!("brand assets! #{tag}")
      assert second.slug == "brand-assets-#{tag}-2"

      assert Libraries.get_system_library_by_slug(first.slug).uuid == first.uuid
      refute Libraries.get_system_library_by_slug("no-such-#{tag}")
      refute Libraries.get_system_library_by_slug(nil)
    end

    test "slugify keeps ASCII letters and digits, drops accents, and never returns empty" do
      assert Library.slugify("  Café  Déjà-vu 2026 ") == "cafe-deja-vu-2026"
      assert Library.slugify("Фото") == "library"
      assert Library.slugify("---") == "library"
    end

    test "renaming keeps kind and prefix" do
      library = library!()
      assert {:ok, renamed} = Libraries.rename_library(library, "Renamed #{library.uuid}")
      assert renamed.key_prefix == library.key_prefix
      assert renamed.slug == library.slug
      assert renamed.kind == "system"
    end

    test "only an empty, non-default library can be deleted" do
      assert {:error, :default} = Libraries.delete_library(Libraries.get_library(@media))

      library = library!()
      folder!(%{library_uuid: library.uuid})
      assert {:error, :not_empty} = Libraries.delete_library(library)

      empty = library!()
      assert {:ok, _} = Libraries.delete_library(empty)
      refute Libraries.get_library(empty.uuid)
    end

    test "a malformed uuid is simply not a library" do
      refute Libraries.get_library("not-a-uuid")
      refute Libraries.get_system_library(nil)
    end
  end

  describe "folders" do
    test "a folder that names no library is Media's; a subfolder takes its parent's" do
      assert folder!(%{}).library_uuid == @media

      library = library!()
      root = folder!(%{library_uuid: library.uuid})
      assert root.library_uuid == library.uuid

      # Whatever the attrs say, a subfolder is in its parent's library.
      child = folder!(%{parent_uuid: root.uuid, library_uuid: @media})
      assert child.library_uuid == library.uuid
    end

    test "the same root name can exist once per library" do
      library = library!()
      name = "Shared #{System.unique_integer([:positive])}"
      folder!(%{name: name})
      assert folder!(%{name: name, library_uuid: library.uuid})
      assert {:error, changeset} = Storage.create_folder(%{name: name})
      assert changeset.errors[:name]
    end

    test "a folder cannot move under a parent in another library, nor change library" do
      library = library!()
      media_folder = folder!(%{})
      other_root = folder!(%{library_uuid: library.uuid})

      assert {:error, :other_library} =
               Storage.update_folder(media_folder, %{parent_uuid: other_root.uuid})

      assert {:ok, renamed} =
               Storage.update_folder(media_folder, %{
                 name: "x-#{media_folder.uuid}",
                 library_uuid: library.uuid
               })

      assert renamed.library_uuid == @media
    end

    test "root listings, the tree and search narrow to a library; nil lists every library" do
      library = library!()
      tag = System.unique_integer([:positive])
      media_folder = folder!(%{name: "needle-media-#{tag}"})
      other_folder = folder!(%{name: "needle-other-#{tag}", library_uuid: library.uuid})

      uuids = &Enum.map(&1, fn f -> f.uuid end)

      in_other = Storage.list_folders(nil, nil, library_uuid: library.uuid)
      assert other_folder.uuid in uuids.(in_other)
      refute media_folder.uuid in uuids.(in_other)

      everywhere = Storage.list_folders(nil, nil)
      assert media_folder.uuid in uuids.(everywhere)
      assert other_folder.uuid in uuids.(everywhere)

      tree = Storage.list_folder_tree(nil, library_uuid: @media)
      assert media_folder.uuid in Enum.map(tree, & &1.folder.uuid)
      refute other_folder.uuid in Enum.map(tree, & &1.folder.uuid)

      assert [found] = Storage.search_folders("needle-", nil, nil, library_uuid: library.uuid)
      assert found.uuid == other_folder.uuid
    end
  end

  describe "files" do
    test "an upload that names no library lands in Media under the uploader's key prefix" do
      with_local_bucket(fn ->
        user = user!()
        assert {:ok, file} = store!(user, nil, "media #{System.unique_integer()}")
        assert file.library_uuid == @media
        assert String.starts_with?(file.file_path, String.slice(user.uuid, 0, 2) <> "/")
      end)
    end

    test "an upload into a library is keyed under the library's prefix and listed only there" do
      with_local_bucket(fn ->
        library = library!()
        user = user!()
        assert {:ok, file} = store!(user, library.uuid, "other #{System.unique_integer()}")

        assert file.library_uuid == library.uuid
        assert String.starts_with?(file.file_path, library.key_prefix <> "/")

        {files, _} = Storage.list_files_in_scope(nil, library_uuid: library.uuid, per_page: 100)
        assert file.uuid in Enum.map(files, & &1.uuid)

        {files, _} = Storage.list_files_in_scope(nil, library_uuid: @media, per_page: 100)
        refute file.uuid in Enum.map(files, & &1.uuid)
      end)
    end

    test "a file cannot be homed in, or linked into, a folder of another library" do
      with_local_bucket(fn ->
        library = library!()
        {:ok, file} = store!(user!(), nil, "cross #{System.unique_integer()}")
        other_folder = folder!(%{library_uuid: library.uuid})

        assert {:error, :other_library} = Storage.attach_file_to_folder(file, other_folder.uuid)

        assert {:error, :other_library} =
                 Storage.move_file_to_folder(file.uuid, other_folder.uuid)

        assert {:error, :other_library} = Storage.create_folder_link(other_folder.uuid, file.uuid)

        media_home = folder!(%{})
        media_other = folder!(%{})
        assert {:ok, _} = Storage.attach_file_to_folder(file, media_home.uuid)
        assert {:ok, link} = Storage.create_folder_link(media_other.uuid, file.uuid)
        assert link.library_uuid == @media
      end)
    end

    test "trash and orphan listings narrow to a library" do
      with_local_bucket(fn ->
        library = library!()
        user = user!()
        {:ok, in_media} = store!(user, nil, "t1 #{System.unique_integer()}")
        {:ok, in_other} = store!(user, library.uuid, "t2 #{System.unique_integer()}")
        {:ok, _} = Storage.trash_file(in_media)
        {:ok, _} = Storage.trash_file(in_other)

        trashed = Storage.list_trashed_files(nil, library_uuid: library.uuid)
        assert Enum.map(trashed, & &1.uuid) == [in_other.uuid]
        assert Storage.count_trashed_files(nil, library_uuid: library.uuid) == 1

        assert {:ok, 1} = Storage.empty_trash(nil, library_uuid: library.uuid)
        assert Storage.get_file(in_media.uuid)
        refute Storage.get_file(in_other.uuid)
      end)
    end
  end

  describe "access" do
    test "the uploader may read and edit; a stranger may not" do
      uploader = user!()
      stranger = user!()
      file = %{user_uuid: uploader.uuid, library_uuid: @media}

      assert Libraries.can?(Scope.for_user(uploader), file, :read)
      assert Libraries.can?(Scope.for_user(uploader), file, :edit)
      refute Libraries.can?(Scope.for_user(stranger), file, :read)
      refute Libraries.can?(Scope.for_user(stranger), file, :edit)
      refute Libraries.can?(nil, file, :read)
      refute Libraries.can?(Scope.for_user(uploader), file, :delete)
    end

    test "an unknown action is refused even for the uploader" do
      user = user!()
      refute Libraries.can?(Scope.for_user(user), %{user_uuid: user.uuid}, :manage)
    end
  end
end
