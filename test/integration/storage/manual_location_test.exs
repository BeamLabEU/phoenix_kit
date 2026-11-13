defmodule PhoenixKit.Modules.Storage.ManualLocationTest do
  @moduledoc """
  Places set by a person (`ManualLocation`), against the database: setting one on
  several files, a name kept only with its own position, who may, clearing, the way
  back to the EXIF's place, and that an automatic writer leaves a place set by hand.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Libraries, ManualLocation}
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope

  setup do
    {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
    {:ok, _} = Settings.update_setting("storage_user_library_limit", "3")

    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "Placers #{n}"})
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage")
    {:ok, _} = Permissions.grant_permission(role.uuid, "storage.create_library")

    # The first account registered may become the Owner, who may do anything.
    _first = user!(nil)

    owner = user!(role)
    {:ok, library} = Libraries.create_user_library(scope(owner), %{"name" => "Lib #{n}"})

    Storage.subscribe_to_file_changes()

    %{role: role, owner: owner, library: library}
  end

  defp user!(role) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "places-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    if role, do: {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  defp scope(user), do: Scope.for_user(Repo.get!(Auth.User, user.uuid))

  # Tallinn's town hall, as a phone's EXIF would put it.
  @exif_gps %{"latitude" => 59.437, "longitude" => 24.7453}

  defp file!(user, library, name, extra \\ %{}) do
    {:ok, file} =
      %{
        original_file_name: name,
        file_name: name,
        file_path: "x/#{name}",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid,
        library_uuid: library.uuid
      }
      |> Map.merge(extra)
      |> Storage.create_file()

    file
  end

  defp from_exif(user, library, name) do
    file!(user, library, name, %{
      latitude: @exif_gps["latitude"],
      longitude: @exif_gps["longitude"],
      metadata: %{"exif" => %{"gps" => @exif_gps}}
    })
  end

  defp reload(file), do: Repo.get!(StorageFile, file.uuid)

  describe "set/4" do
    test "places several files at one position, by hand, with its name", ctx do
      a = file!(ctx.owner, ctx.library, "a.jpg")
      b = from_exif(ctx.owner, ctx.library, "b.jpg")

      assert {:ok, uuids} =
               ManualLocation.set([a.uuid, b.uuid], {58.3776252, 26.7290383}, scope(ctx.owner),
                 name: "  Tartu, Estonia "
               )

      assert Enum.sort(uuids) == Enum.sort([a.uuid, b.uuid])
      assert_receive {:phoenix_kit_files_changed, _}

      for file <- [reload(a), reload(b)] do
        assert file.latitude == 58.377625
        assert file.longitude == 26.729038
        assert ManualLocation.manual?(file)
        assert ManualLocation.place_name(file) == "Tartu, Estonia"
      end

      # The EXIF's own summary stays, for the way back.
      assert reload(b).metadata["exif"]["gps"] == @exif_gps
    end

    test "a name belongs to its position only", ctx do
      a = file!(ctx.owner, ctx.library, "a.jpg")
      {:ok, _} = ManualLocation.set([a.uuid], {58.38, 26.72}, scope(ctx.owner), name: "Tartu")

      moved = %{reload(a) | latitude: 59.0}
      assert ManualLocation.place_name(moved) == nil

      {:ok, _} = ManualLocation.set([a.uuid], {59.0, 25.0}, scope(ctx.owner))
      assert ManualLocation.place_name(reload(a)) == nil
    end

    test "refuses a position off the globe, and someone who may not edit", ctx do
      a = file!(ctx.owner, ctx.library, "a.jpg")

      assert {:error, :invalid_position} =
               ManualLocation.set([a.uuid], {91.0, 0.0}, scope(ctx.owner))

      assert {:error, :invalid_position} =
               ManualLocation.set([a.uuid], {"59", "24"}, scope(ctx.owner))

      stranger = user!(ctx.role)

      assert {:error, :forbidden} =
               ManualLocation.set([a.uuid], {59.0, 24.0}, scope(stranger))

      assert {:error, :not_found} =
               ManualLocation.set([Ecto.UUID.generate()], {59.0, 24.0}, scope(ctx.owner))

      assert reload(a).latitude == nil
    end
  end

  describe "clear/2 and reset/2" do
    test "clearing removes the place for good, reset gives the EXIF's back", ctx do
      a = from_exif(ctx.owner, ctx.library, "a.jpg")

      {:ok, [_]} = ManualLocation.clear([a.uuid], scope(ctx.owner))
      cleared = reload(a)
      assert cleared.latitude == nil and cleared.longitude == nil
      assert ManualLocation.manual?(cleared)

      {:ok, [_]} = ManualLocation.reset([a.uuid], scope(ctx.owner))
      back = reload(a)
      assert back.latitude == 59.437 and back.longitude == 24.7453
      refute ManualLocation.manual?(back)
    end

    test "reset leaves a file whose place was not set by hand, and gives none without EXIF",
         ctx do
      a = from_exif(ctx.owner, ctx.library, "a.jpg")
      b = file!(ctx.owner, ctx.library, "b.jpg")
      {:ok, _} = ManualLocation.set([b.uuid], {10.0, 10.0}, scope(ctx.owner), name: "Somewhere")

      assert {:ok, [reset]} = ManualLocation.reset([a.uuid, b.uuid], scope(ctx.owner))
      assert reset == b.uuid

      b = reload(b)
      assert b.latitude == nil and b.longitude == nil
      refute Map.has_key?(b.metadata, "place")
      assert reload(a).latitude == 59.437
    end
  end

  describe "automatic writers" do
    test "admit/2 keeps a place set by hand from a processing job", ctx do
      a = from_exif(ctx.owner, ctx.library, "a.jpg")
      attrs = %{latitude: 1.0, longitude: 2.0, width: 10}

      assert ManualLocation.admit(attrs, reload(a)) == attrs

      {:ok, _} = ManualLocation.set([a.uuid], {58.0, 26.0}, scope(ctx.owner))
      assert ManualLocation.admit(attrs, reload(a)) == %{width: 10}
    end

    test "a processing job's metadata write leaves the place set by hand", ctx do
      a = from_exif(ctx.owner, ctx.library, "a.jpg")
      {:ok, _} = ManualLocation.set([a.uuid], {58.0, 26.0}, scope(ctx.owner))

      {:ok, _} =
        Storage.create_file_instance(%{
          file_uuid: a.uuid,
          variant_name: "original",
          file_name: "orig-a.jpg",
          mime_type: "image/jpeg",
          ext: "jpg",
          checksum: Ecto.UUID.generate(),
          size: 1
        })

      # As the job writes what it read from the original: the EXIF position again.
      assert :ok =
               ProcessFileJob.update_file_with_metadata(reload(a), "orig-a.jpg", %{
                 latitude: 1.0,
                 longitude: 2.0,
                 width: 640
               })

      a = reload(a)
      assert a.latitude == 58.0 and a.longitude == 26.0
      assert a.width == 640
    end
  end
end
