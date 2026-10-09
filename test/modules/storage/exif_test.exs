defmodule PhoenixKit.Modules.Storage.ExifTest do
  @moduledoc """
  `Storage.Exif`: ImageMagick's text dump of a photo's EXIF into a summary worth
  keeping, a position a map can search, and a grouped list to look at.

  The tags are those of a real iPhone 17 Pro photo (ImageMagick prints
  fractions as fractions). DB-free.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Exif

  @tags %{
    "DateTime" => "2026:10:05 18:42:46",
    "DateTimeDigitized" => "2026:10:05 18:42:46",
    "DateTimeOriginal" => "2026:10:05 18:42:46",
    "ExposureTime" => "10/1760",
    "FNumber" => "1433/512",
    "FocalLength" => "1081/64",
    "FocalLengthIn35mmFilm" => "200",
    "Flash" => "16",
    "GPSAltitude" => "101547/967",
    "GPSAltitudeRef" => ".",
    "GPSDateStamp" => "2026:10:05",
    "GPSDestBearing" => "335554/951",
    "GPSImgDirection" => "335554/951",
    "GPSImgDirectionRef" => "T",
    "GPSInfo" => "3106",
    "GPSLatitude" => "45/1,28/1,1199/100",
    "GPSLatitudeRef" => "N",
    "GPSLongitude" => "10/1,43/1,1553/100",
    "GPSLongitudeRef" => "E",
    "GPSSpeed" => "8789/9487",
    "GPSSpeedRef" => "K",
    "GPSTimeStamp" => "16/1,42/1,46/1",
    "ISOSpeedRatings" => "50",
    "LensMake" => "Apple",
    "LensModel" => "iPhone 17 Pro back triple camera 16.891mm f/2.8",
    "Make" => "Apple",
    "MakerNote" => "Apple iOS",
    "BodySerialNumber" => "F2LX1234",
    "Model" => "iPhone 17 Pro",
    "OffsetTimeOriginal" => "+02:00",
    "Orientation" => "1",
    "Software" => "27.0",
    "SubSecTimeOriginal" => "907"
  }

  describe "coordinates/1" do
    test "degrees, minutes and seconds become decimal degrees" do
      assert {lat, lon} = Exif.coordinates(@tags)
      assert_in_delta lat, 45.469997, 1.0e-5
      assert_in_delta lon, 10.720981, 1.0e-5
    end

    test "south and west are negative" do
      tags = %{
        @tags
        | "GPSLatitudeRef" => "S",
          "GPSLongitudeRef" => "W"
      }

      assert {lat, lon} = Exif.coordinates(tags)
      assert lat < 0 and lon < 0
    end

    test "no position, a half position, an impossible one and 0, 0 are all nothing" do
      assert Exif.coordinates(%{}) == nil
      assert Exif.coordinates(Map.delete(@tags, "GPSLongitude")) == nil
      assert Exif.coordinates(%{@tags | "GPSLatitude" => "91/1,0/1,0/1"}) == nil

      zero = %{@tags | "GPSLatitude" => "0/1,0/1,0/1", "GPSLongitude" => "0/1,0/1,0/1"}
      assert Exif.coordinates(zero) == nil
    end
  end

  describe "summary/1" do
    test "the camera, without the serial number or the maker note" do
      summary = Exif.summary(@tags)

      assert summary["camera"] == %{
               "make" => "Apple",
               "model" => "iPhone 17 Pro",
               "lens_make" => "Apple",
               "lens_model" => "iPhone 17 Pro back triple camera 16.891mm f/2.8",
               "software" => "27.0"
             }

      refute inspect(summary) =~ "F2LX1234"
      refute inspect(summary) =~ "MakerNote"
    end

    test "the exposure reads as a photographer reads it" do
      exposure = Exif.summary(@tags)["exposure"]

      assert exposure["f_number"] == 2.8
      assert exposure["focal_length"] == 16.9
      assert exposure["focal_length_35mm"] == 200
      assert exposure["exposure_time"] == "1/176"
      assert exposure["iso"] == 50
      assert exposure["flash"] == false
    end

    test "the dates are local times, with the offset kept apart" do
      assert Exif.summary(@tags)["dates"] == %{
               "original" => "2026-10-05T18:42:46.907",
               "digitized" => "2026-10-05T18:42:46",
               "modified" => "2026-10-05T18:42:46",
               "offset" => "+02:00"
             }
    end

    test "the position, with altitude, speed, direction and the GPS time" do
      gps = Exif.summary(@tags)["gps"]

      assert_in_delta gps["latitude"], 45.469997, 1.0e-5
      assert_in_delta gps["longitude"], 10.720981, 1.0e-5
      assert gps["altitude"] == 105.0
      assert gps["speed_kmh"] == 0.9
      assert gps["direction"] == 352.8
      assert gps["direction_ref"] == "true"
      assert gps["timestamp"] == "2026-10-05T16:42:46Z"
    end

    test "an altitude below sea level is negative, and a speed in mph is km/h" do
      tags = %{@tags | "GPSAltitudeRef" => "1", "GPSSpeed" => "10/1", "GPSSpeedRef" => "M"}
      gps = Exif.summary(tags)["gps"]

      assert gps["altitude"] < 0
      assert gps["speed_kmh"] == 16.1
    end

    test "no GPS means no gps group, and no tags means nothing" do
      refute Map.has_key?(Exif.summary(Map.drop(@tags, ["GPSLatitude"])), "gps")
      assert Exif.summary(%{}) == %{}
    end

    test "a flash that fired, and a zero date that is nothing" do
      tags = %{@tags | "Flash" => "25", "DateTimeDigitized" => "0000:00:00 00:00:00"}
      summary = Exif.summary(tags)

      assert summary["exposure"]["flash"] == true
      refute Map.has_key?(summary["dates"], "digitized")
    end

    test "the summary is JSON-safe" do
      assert {:ok, json} = Jason.encode(Exif.summary(@tags))
      assert {:ok, _} = Jason.decode(json)
    end
  end

  describe "groups/1" do
    test "every tag is grouped, in order, with fractions as numbers" do
      groups = Exif.groups(@tags)

      assert Enum.map(groups, &elem(&1, 0)) == [:camera, :exposure, :dates, :location, :image]

      exposure = groups |> List.keyfind(:exposure, 0) |> elem(1) |> Map.new()
      assert exposure["F Number"] == "2.7988"
      assert exposure["Exposure Time"] == "1/176"
      assert exposure["Focal Length"] == "16.8906"
    end

    test "a GPS position is shown as decimal degrees with its sign" do
      location = Exif.groups(@tags) |> List.keyfind(:location, 0) |> elem(1) |> Map.new()

      assert location["GPS Latitude"] =~ ~r/^45\.46999/
      assert location["GPS Longitude"] =~ ~r/^10\.72098/
      refute Map.has_key?(location, "GPS Info")
    end

    test "labels split CamelCase and keep acronyms together" do
      camera = Exif.groups(@tags) |> List.keyfind(:camera, 0) |> elem(1) |> Map.new()
      assert Map.has_key?(camera, "Lens Model")

      exposure = Exif.groups(@tags) |> List.keyfind(:exposure, 0) |> elem(1) |> Map.new()
      assert Map.has_key?(exposure, "ISO Speed Ratings")
    end

    test "no tags, no groups" do
      assert Exif.groups(%{}) == []
    end
  end

  describe "a photo whose tags the summary keeps nothing of" do
    test "is told from one with no EXIF at all, by the number of tags it carries" do
      assert Exif.summary(%{}) == %{}
      assert Exif.summary(%{"ColorSpace" => "1", "ExifVersion" => "0231"}) == %{"tags" => 2}
    end

    test "an offset to other data is no tag worth counting" do
      assert Exif.summary(%{"ExifOffset" => "26", "GPSInfo" => "300"}) == %{}
      assert Exif.groups(%{"ExifOffset" => "26"}) == []
    end

    test "has no such count once the summary holds something" do
      refute Map.has_key?(Exif.summary(%{"Make" => "Apple", "ColorSpace" => "1"}), "tags")
    end
  end

  describe "tags a file cannot be trusted to keep tidy" do
    @huge String.duplicate("9", 400)

    test "a number of hundreds of digits is no number, and nothing raises" do
      tags = %{
        "FNumber" => @huge <> "/1",
        "FocalLength" => "1/" <> @huge,
        "GPSLatitude" => @huge,
        "GPSLongitude" => "10/1"
      }

      assert Map.keys(Exif.summary(tags)) == ["tags"]
      assert Exif.coordinates(tags) == nil
      assert is_list(Exif.groups(tags))
    end

    test "the whole dump shows a large value without raising" do
      tags = %{"FocalLength" => "999999999999999/1, 1/1"}
      assert [{:exposure, [{"Focal Length", value}]}] = Exif.groups(tags)
      assert value =~ "999999999999999"
    end

    test "exposure fractions with oversized parts are dropped without raising" do
      for value <- [@huge <> "/2", "2/" <> @huge] do
        refute Map.has_key?(Exif.summary(%{"ExposureTime" => value}), "exposure")
        assert is_list(Exif.groups(%{"ExposureTime" => value}))
      end
    end

    test "text that is not UTF-8 is cleaned and the summary encodes as JSON" do
      summary = Exif.summary(%{"Make" => "Ca" <> <<0xE9>> <> "non", "Model" => <<0xC4, 0xE0>>})

      assert summary["camera"]["make"] == "Canon"
      refute Map.has_key?(summary["camera"], "model")
      assert {:ok, _} = Jason.encode(summary)
    end

    test "a GPS timestamp that is not a date and a time is dropped" do
      base = %{"GPSLatitude" => "45/1", "GPSLongitude" => "10/1"}

      gps = fn date, time ->
        Exif.summary(Map.merge(base, %{"GPSDateStamp" => date, "GPSTimeStamp" => time}))["gps"]
      end

      assert gps.("2026:10:05", "16/1,42/1,46/1")["timestamp"] == "2026-10-05T16:42:46Z"
      refute Map.has_key?(gps.("ab:cd:ef", "1/1,2/1,3/1"), "timestamp")
      refute Map.has_key?(gps.("2026:10:05", "25/1,0/1,0/1"), "timestamp")
      refute Map.has_key?(gps.("2026:10:05", "1/1,2/1," <> @huge <> "/1"), "timestamp")
      refute Map.has_key?(gps.("2026:02:30", "1/1,2/1,3/1"), "timestamp")
      refute Map.has_key?(gps.("2026:13:05", "1/1,2/1,3/1"), "timestamp")
      refute Map.has_key?(gps.("2026:10:05", "1/1,2/1,60/1"), "timestamp")
      assert gps.("2024:02:29", "1/1,2/1,3/1")["timestamp"] == "2024-02-29T01:02:03Z"
    end
  end
end
