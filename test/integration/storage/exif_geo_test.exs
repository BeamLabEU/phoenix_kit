defmodule PhoenixKit.Integration.Storage.ExifGeoTest do
  @moduledoc """
  A photo's EXIF end to end, against real JPEG bytes carrying a hand-built EXIF
  segment (camera and a GPS position): read at processing time, read again on
  request for a photo that predates it, recorded without touching the rest of
  `metadata`, and the position found again by a box on the map.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Geo
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Test.ExifFixture
  alias PhoenixKit.Users.Auth

  unless ExifFixture.available?() and System.find_executable("identify"),
    do: @moduletag(:skip)

  @buckets_cache :phoenix_kit_buckets_cache

  # 45°28'11.99" N, 10°43'15.53" E.
  @gps %{
    make: "Apple",
    model: "iPhone 17 Pro",
    date_time_original: "2026:10:05 18:42:46",
    offset_time_original: "+02:00",
    gps_latitude_ref: "N",
    gps_latitude: [{45, 1}, {28, 1}, {1199, 100}],
    gps_longitude_ref: "E",
    gps_longitude: [{10, 1}, {43, 1}, {1553, 100}]
  }

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_exif_#{n}")
    sources = Path.join(System.tmp_dir!(), "pk_exif_src_#{n}")
    File.mkdir_p!(sources)

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "exif-test-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {:ok, user} =
      Auth.register_user(%{
        "email" => "exif-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(tmp_root)
      File.rm_rf(sources)
    end)

    %{user: user, sources: sources}
  end

  defp store_jpeg!(ctx, tags) do
    path = Path.join(ctx.sources, "#{System.unique_integer([:positive])}.jpg")
    ExifFixture.write_jpeg!(path, tags)
    checksum = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "image", ctx.user.uuid, checksum, "jpg", "p.jpg")

    file
  end

  defp reload(file), do: Repo.get!(StorageFile, file.uuid)

  defp set_metadata!(file, metadata) do
    Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid),
      set: [metadata: metadata]
    )

    reload(file)
  end

  describe "processing a photo" do
    test "records its camera, dates and position", ctx do
      file = store_jpeg!(ctx, @gps)

      ProcessFileJob.perform(%Oban.Job{args: %{"file_uuid" => file.uuid, "filename" => "p.jpg"}})
      row = reload(file)

      assert row.metadata["exif"]["camera"] == %{"make" => "Apple", "model" => "iPhone 17 Pro"}
      assert row.metadata["exif"]["dates"]["original"] == "2026-10-05T18:42:46"
      assert row.metadata["exif"]["dates"]["offset"] == "+02:00"
      assert_in_delta row.latitude, 45.469997, 1.0e-5
      assert_in_delta row.longitude, 10.720981, 1.0e-5
      assert_in_delta row.metadata["exif"]["gps"]["latitude"], 45.469997, 1.0e-5
    end

    test "a photo with no EXIF is recorded as read, and has no position", ctx do
      file = store_jpeg!(ctx, %{})

      ProcessFileJob.perform(%Oban.Job{args: %{"file_uuid" => file.uuid, "filename" => "p.jpg"}})
      row = reload(file)

      assert row.metadata["exif"] == %{}
      assert {row.latitude, row.longitude} == {nil, nil}
    end
  end

  describe "Storage.read_exif/1" do
    test "reads a photo that predates it, and leaves the rest of metadata alone", ctx do
      file = store_jpeg!(ctx, @gps)
      file = set_metadata!(file, %{"rotation" => 90, "tags" => ["sea"]})

      assert {:ok, row} = Storage.read_exif(file)

      assert row.metadata["rotation"] == 90
      assert row.metadata["tags"] == ["sea"]
      assert row.metadata["exif"]["camera"]["model"] == "iPhone 17 Pro"
      assert_in_delta row.latitude, 45.469997, 1.0e-5
      assert reload(file).latitude == row.latitude
    end

    test "reading again replaces what was read", ctx do
      file = store_jpeg!(ctx, @gps)
      {:ok, _} = Storage.read_exif(file)

      Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid),
        set: [latitude: 1.0, longitude: 2.0]
      )

      assert {:ok, row} = Storage.read_exif(file.uuid)
      assert_in_delta row.latitude, 45.469997, 1.0e-5
    end

    test "something that is not an image, and a file that is gone", ctx do
      file = store_jpeg!(ctx, @gps)

      Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid),
        set: [file_type: "document"]
      )

      assert Storage.read_exif(file.uuid) == {:error, :not_an_image}
      assert Storage.read_exif(Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "exif_tags/1 is every tag of the original, and stores nothing", ctx do
      file = store_jpeg!(ctx, @gps)

      assert {:ok, tags} = Storage.exif_tags(file)
      assert tags["Make"] == "Apple"
      # ImageMagick 6 prints the list with a space after each comma, 7 without.
      assert String.replace(tags["GPSLatitude"], " ", "") == "45/1,28/1,1199/100"
      assert reload(file).metadata == file.metadata
    end
  end

  describe "a box on the map" do
    setup ctx do
      spot = fn name, lat, lon ->
        file = store_jpeg!(ctx, %{})

        Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid),
          set: [latitude: lat, longitude: lon, original_file_name: name]
        )

        file
      end

      spot.("graz", 47.07, 15.44)
      spot.("verona", 45.44, 10.99)
      spot.("fiji_east", -17.7, 179.5)
      spot.("fiji_west", -16.5, -179.5)
      spot.("nowhere", nil, nil)
      :ok
    end

    defp names(opts) do
      {files, total} = Storage.list_files_in_scope(nil, opts)
      assert total == length(files)

      files
      |> Enum.map(& &1.original_file_name)
      |> Enum.filter(&(&1 in ~w(graz verona fiji_east fiji_west nowhere)))
      |> Enum.sort()
    end

    test "only the photos inside the box" do
      assert names(bounds: {46.0, 14.0, 48.0, 16.0}) == ["graz"]
      assert names(bounds: {45.0, 10.0, 48.0, 16.0}) == ["graz", "verona"]
      assert names(bounds: {0.0, 0.0, 10.0, 10.0}) == []
    end

    test "a box across the antimeridian finds both sides" do
      assert names(bounds: {-20.0, 170.0, -10.0, -170.0}) == ["fiji_east", "fiji_west"]
      # …and the plain box over the same longitudes finds neither.
      assert names(bounds: {-20.0, -170.0, -10.0, 170.0}) == []
    end

    test "a box as wide as the world finds everything with a position" do
      assert names(bounds: {-90.0, -180.0, 90.0, 180.0}) == [
               "fiji_east",
               "fiji_west",
               "graz",
               "verona"
             ]
    end

    test "a longitude past 180 is the same place" do
      # 190° is -170°: a map panned past the edge of the world.
      assert names(bounds: {-20.0, 170.0, -10.0, 190.0}) == ["fiji_east", "fiji_west"]
      assert names(bounds: {-20.0, 180.0, -10.0, 190.0}) == ["fiji_west"]
    end

    test "no bounds lists everything, a file with no position included" do
      assert "nowhere" in names([])
    end
  end

  describe "Geo.parse_bounds/1" do
    test "a coordinate of hundreds of digits is not a bounds, and does not raise" do
      assert Geo.parse_bounds("1,0,1," <> String.duplicate("9", 400)) == nil
    end

    test "from a string, a list and a map" do
      assert Geo.parse_bounds("46,14,48,16") == {46.0, 14.0, 48.0, 16.0}
      assert Geo.parse_bounds(["46", "14", "48", "16"]) == {46.0, 14.0, 48.0, 16.0}

      assert Geo.parse_bounds(%{"south" => "1", "west" => "2", "north" => "3", "east" => "4"}) ==
               {1.0, 2.0, 3.0, 4.0}
    end

    test "anything else is nothing" do
      assert Geo.parse_bounds("46,14,48") == nil
      assert Geo.parse_bounds("a,b,c,d") == nil
      assert Geo.parse_bounds("48,14,46,16") == nil, "south above north"
      assert Geo.parse_bounds(nil) == nil
    end
  end
end
