defmodule PhoenixKit.Modules.Storage.CaptureDateTest do
  @moduledoc """
  `CaptureDate`'s parsing, resolution order and downgrade guard — pure
  functions over tag maps, ffprobe output and file names, no database.
  Reading real bytes with ImageMagick is covered by
  `capture_date_exif_test.exs`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.CaptureDate

  describe "from_exif/1" do
    test "with an offset: the exact instant, and the LOCAL date" do
      # 23:04 on 31 July in California is 06:04 on 1 August in UTC. A library
      # must file it under July — the reason `taken_on` exists at all.
      assert CaptureDate.from_exif(%{
               "DateTimeOriginal" => "2018:07:31 23:04:05",
               "OffsetTimeOriginal" => "-07:00"
             }) == %{
               taken_at: ~U[2018-08-01 06:04:05Z],
               taken_on: ~D[2018-07-31],
               taken_at_offset: -25_200,
               taken_at_source: "exif"
             }
    end

    test "without an offset: the local time stored as UTC, offset unknown" do
      assert CaptureDate.from_exif(%{"DateTimeOriginal" => "2016:03:12 08:11:00"}) == %{
               taken_at: ~U[2016-03-12 08:11:00Z],
               taken_on: ~D[2016-03-12],
               taken_at_offset: nil,
               taken_at_source: "exif"
             }
    end

    test "falls back to DateTimeDigitized, with its own offset tag" do
      assert %{taken_at: ~U[2019-01-02 01:04:05Z], taken_at_offset: 7200} =
               CaptureDate.from_exif(%{
                 "DateTimeDigitized" => "2019:01:02 03:04:05",
                 "OffsetTimeDigitized" => "+02:00"
               })
    end

    test "prefers DateTimeOriginal over DateTimeDigitized" do
      assert %{taken_on: ~D[2015-06-01]} =
               CaptureDate.from_exif(%{
                 "DateTimeOriginal" => "2015:06:01 10:00:00",
                 "DateTimeDigitized" => "2020:01:01 10:00:00"
               })
    end

    test "rejects the dates cameras write when they have none" do
      assert CaptureDate.from_exif(%{"DateTimeOriginal" => "0000:00:00 00:00:00"}) == nil
      assert CaptureDate.from_exif(%{"DateTimeOriginal" => "    :  :     :  :  "}) == nil
      assert CaptureDate.from_exif(%{"DateTimeOriginal" => ""}) == nil
      assert CaptureDate.from_exif(%{}) == nil
    end

    test "rejects an impossible or future date" do
      assert CaptureDate.from_exif(%{"DateTimeOriginal" => "2018:02:30 10:00:00"}) == nil
      assert CaptureDate.from_exif(%{"DateTimeOriginal" => "1700:01:01 10:00:00"}) == nil
      assert CaptureDate.from_exif(%{"DateTimeOriginal" => "2999:01:01 10:00:00"}) == nil
    end

    test "reads offsets with or without a colon, and drops an impossible one" do
      assert %{taken_at_offset: 19_800} =
               CaptureDate.from_exif(%{
                 "DateTimeOriginal" => "2020:01:01 10:00:00",
                 "OffsetTimeOriginal" => "+05:30"
               })

      assert %{taken_at_offset: 19_800} =
               CaptureDate.from_exif(%{
                 "DateTimeOriginal" => "2020:01:01 10:00:00",
                 "OffsetTimeOriginal" => "+0530"
               })

      # The date is still good; only the offset is discarded.
      assert %{taken_at_offset: nil, taken_on: ~D[2020-01-01]} =
               CaptureDate.from_exif(%{
                 "DateTimeOriginal" => "2020:01:01 10:00:00",
                 "OffsetTimeOriginal" => "+15:00"
               })
    end
  end

  describe "parse_exif_properties/1" do
    test "reads ImageMagick's %[EXIF:*] output into a tag map" do
      output = """
      exif:DateTimeDigitized=2018:07:31 23:04:06
      exif:DateTimeOriginal=2018:07:31 23:04:05
      exif:ExifOffset=26
      exif:OffsetTimeOriginal=-07:00
      """

      assert CaptureDate.parse_exif_properties(output) == %{
               "DateTimeDigitized" => "2018:07:31 23:04:06",
               "DateTimeOriginal" => "2018:07:31 23:04:05",
               "ExifOffset" => "26",
               "OffsetTimeOriginal" => "-07:00"
             }
    end

    test "ignores lines that are not EXIF properties" do
      output = "identify: some warning\nexif:DateTimeOriginal=2018:07:31 23:04:05\n"

      assert CaptureDate.parse_exif_properties(output) == %{
               "DateTimeOriginal" => "2018:07:31 23:04:05"
             }
    end
  end

  describe "video tags" do
    # What `ffprobe -show_entries format_tags=…:stream_tags=creation_time
    # -of default=noprint_wrappers=1` prints for an iPhone video: the stream's
    # tags first, then the container's.
    @iphone """
    TAG:creation_time=2024-03-15T06:11:01.000000Z
    TAG:creation_time=2024-03-15T06:11:00.000000Z
    TAG:com.apple.quicktime.creationdate=2024-03-15T08:11:00+0200
    """

    test "parse_ffprobe_tags/1 keeps the first value seen per tag" do
      assert CaptureDate.parse_ffprobe_tags(@iphone) == %{
               "creation_time" => "2024-03-15T06:11:01.000000Z",
               "com.apple.quicktime.creationdate" => "2024-03-15T08:11:00+0200"
             }
    end

    test "QuickTime's creation date wins: it keeps the local time and offset" do
      assert @iphone |> CaptureDate.parse_ffprobe_tags() |> CaptureDate.from_video_tags() == %{
               taken_at: ~U[2024-03-15 06:11:00Z],
               taken_on: ~D[2024-03-15],
               taken_at_offset: 7200,
               taken_at_source: "container"
             }
    end

    test "creation_time alone: the exact instant, the local date taken from UTC" do
      assert CaptureDate.from_video_tags(%{"creation_time" => "2024-03-15T23:30:00.000000Z"}) ==
               %{
                 taken_at: ~U[2024-03-15 23:30:00Z],
                 taken_on: ~D[2024-03-15],
                 taken_at_offset: nil,
                 taken_at_source: "container"
               }
    end

    test "an epoch on the stream does not hide the container's creation_time" do
      output = """
      TAG:creation_time=1970-01-01T00:00:00.000000Z
      TAG:creation_time=2024-03-15T23:30:00.000000Z
      """

      assert CaptureDate.parse_ffprobe_tags(output)["creation_time"] ==
               "2024-03-15T23:30:00.000000Z"

      assert output |> CaptureDate.parse_ffprobe_tags() |> CaptureDate.from_video_tags() == %{
               taken_at: ~U[2024-03-15 23:30:00Z],
               taken_on: ~D[2024-03-15],
               taken_at_offset: nil,
               taken_at_source: "container"
             }
    end

    test "rejects the epochs a container writes when it has no date" do
      assert CaptureDate.from_video_tags(%{"creation_time" => "1970-01-01T00:00:00.000000Z"}) ==
               nil

      assert CaptureDate.from_video_tags(%{"creation_time" => "1904-01-01T00:00:00.000000Z"}) ==
               nil

      assert CaptureDate.from_video_tags(%{}) == nil
    end
  end

  describe "from_filename/1" do
    for {name, expected} <- [
          {"IMG_20180701_120000.jpg", ~N[2018-07-01 12:00:00]},
          {"VID_20180701_120000.mp4", ~N[2018-07-01 12:00:00]},
          {"PXL_20240315_081100123.jpg", ~N[2024-03-15 08:11:00]},
          {"PXL_20240315_081100123.MP.jpg", ~N[2024-03-15 08:11:00]},
          {"Screenshot_20240315-081100.png", ~N[2024-03-15 08:11:00]},
          {"2018-07-01 12.34.56.jpg", ~N[2018-07-01 12:34:56]},
          {"Screen Shot 2024-03-15 at 08.11.00.png", ~N[2024-03-15 08:11:00]},
          {"IMG-20240315-WA0001.jpg", ~N[2024-03-15 00:00:00]},
          {"holiday 2019-05-20.jpg", ~N[2019-05-20 00:00:00]},
          {"uploads/nested/IMG_20180701_120000.jpg", ~N[2018-07-01 12:00:00]},
          # Telegram Desktop's chat export, day first after the `@`
          {"photos/photo_12@14-05-2021_18-23-45.jpg", ~N[2021-05-14 18:23:45]},
          {"video_files/video_3@01-02-2019_07-05-09.mp4", ~N[2019-02-01 07:05:09]},
          {"round_video_messages/file_7@31-12-2020_23-59-59.mp4", ~N[2020-12-31 23:59:59]},
          {"photo_1@14-05-2021_18-23-45 (1).jpg", ~N[2021-05-14 18:23:45]}
        ] do
      test "reads #{name}" do
        expected = unquote(Macro.escape(expected))

        assert CaptureDate.from_filename(unquote(name)) == %{
                 taken_at: DateTime.from_naive!(expected, "Etc/UTC"),
                 taken_on: NaiveDateTime.to_date(expected),
                 taken_at_offset: nil,
                 taken_at_source: "filename"
               }
      end
    end

    for name <- [
          "IMG_1234.jpg",
          "holiday.jpg",
          "photo_123456789012345.jpg",
          "IMG_20181301_120000.jpg",
          "IMG_20180701_250000.jpg",
          "IMG_20990101_120000.jpg",
          # day first only after Telegram's `@`, and a real day and month
          "photo 14-05-2021_18-23-45.jpg",
          "photo_1@32-05-2021_18-23-45.jpg",
          "photo_1@14-13-2021_18-23-45.jpg"
        ] do
      test "finds no date in #{name}" do
        assert CaptureDate.from_filename(unquote(name)) == nil
      end
    end

    test "nil has no date" do
      assert CaptureDate.from_filename(nil) == nil
    end
  end

  describe "resolve/2" do
    @upload %{
      file_type: "image",
      original_file_name: "IMG_20180701_120000.jpg",
      inserted_at: ~U[2026-09-21 10:00:00Z]
    }

    test "without readable bytes, the date in the file name" do
      assert %{taken_at_source: "filename", taken_on: ~D[2018-07-01]} =
               CaptureDate.resolve(nil, @upload)
    end

    test "without a date in the name either, the upload time" do
      assert CaptureDate.resolve(nil, %{@upload | original_file_name: "holiday.jpg"}) == %{
               taken_at: ~U[2026-09-21 10:00:00Z],
               taken_on: ~D[2026-09-21],
               taken_at_offset: nil,
               taken_at_source: "inserted_at"
             }
    end

    test "a document never reads embedded metadata" do
      assert %{taken_at_source: "filename"} =
               CaptureDate.resolve("/nonexistent.pdf", %{@upload | file_type: "document"})
    end
  end

  describe "replace?/2" do
    for {current, new, expected} <- [
          {nil, "inserted_at", true},
          {"inserted_at", "filename", true},
          {"filename", "exif", true},
          {"exif", "exif", true},
          {"exif", "container", true},
          {"exif", "filename", false},
          {"exif", "inserted_at", false},
          {"container", "filename", false},
          {"manual", "exif", false},
          {"manual", "manual", false},
          {"unknown-legacy-value", "inserted_at", true}
        ] do
      test "#{inspect(current)} -> #{inspect(new)} is #{expected}" do
        assert CaptureDate.replace?(unquote(current), unquote(new)) == unquote(expected)
      end
    end
  end

  describe "admit/2" do
    @weaker %{
      width: 64,
      height: 48,
      taken_at: ~U[2018-07-01 12:00:00Z],
      taken_on: ~D[2018-07-01],
      taken_at_offset: nil,
      taken_at_source: "filename"
    }

    test "drops only the capture date when it would downgrade the current one" do
      assert CaptureDate.admit(@weaker, %{taken_at_source: "exif"}) == %{width: 64, height: 48}
    end

    test "keeps it when it is as strong or stronger" do
      assert CaptureDate.admit(@weaker, %{taken_at_source: "inserted_at"}) == @weaker
      assert CaptureDate.admit(@weaker, %{taken_at_source: nil}) == @weaker
    end

    test "leaves attrs without a capture date alone" do
      assert CaptureDate.admit(%{width: 64}, %{taken_at_source: "manual"}) == %{width: 64}
    end
  end

  test "sources/0 lists every value the schema accepts, strongest first" do
    assert CaptureDate.sources() == ~w(manual exif container filename inserted_at)
  end
end
