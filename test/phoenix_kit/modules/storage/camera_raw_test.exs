defmodule PhoenixKit.Modules.Storage.CameraRawTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{CameraRaw, CaptureDate, DrawnSource, Exif}

  @moduletag :tmp_dir

  test "knows each raw extension's type, in any case" do
    assert CameraRaw.mime_for_extension("NEF") == "image/x-nikon-nef"
    assert CameraRaw.mime_for_extension(".dng") == "image/x-adobe-dng"
    assert CameraRaw.mime_for_extension("jpg") == nil
    assert CameraRaw.mime?("image/x-canon-cr3")
    refute CameraRaw.mime?("image/tiff")

    assert CameraRaw.mime_types()["image/x-fuji-raf"] == ["raf"]
    assert length(CameraRaw.extensions()) == map_size(CameraRaw.mime_types())
  end

  test "a raw file is drawn, as an SVG is; a JPEG is its own picture" do
    assert DrawnSource.drawn?("image/x-sony-arw")
    assert DrawnSource.drawn?("image/svg+xml")
    refute DrawnSource.drawn?("image/jpeg")
  end

  test "libraw's reading becomes EXIF tags Exif and CaptureDate take" do
    props =
      CameraRaw.parse_properties("""
      dng:camera.model.name=EOS R6 Mark III
      dng:create.date=2026-01-22T15:41:52+00:00
      dng:exposure.time=1/2e+01
      dng:f.number=7
      dng:focal.length=5e+01 mm
      dng:focal.length.in.35mm.format=0 mm
      dng:iso.setting=1e+02
      dng:make=Canon
      dng:software=
      """)

    tags = CameraRaw.to_exif(props)

    assert tags == %{
             "Make" => "Canon",
             "Model" => "EOS R6 Mark III",
             "DateTimeOriginal" => "2026:01:22 15:41:52",
             "ExposureTime" => "1/20",
             "FNumber" => "7",
             "ISOSpeedRatings" => "100",
             "FocalLength" => "50"
           }

    assert CaptureDate.from_exif(tags).taken_at == ~U[2026-01-22 15:41:52Z]

    assert %{"camera" => %{"make" => "Canon"}, "exposure" => %{"exposure_time" => "1/20"}} =
             Exif.summary(tags)
  end

  test "a camera with its clock never set has no date" do
    assert CameraRaw.to_exif(%{"create.date" => "1970-01-01T00:00:00+00:00"}) == %{}
  end

  test "what does not have a raw file's shape is not developed", %{tmp_dir: dir} do
    path = Path.join(dir, "a.nef")
    File.write!(path, "not a photo")
    assert {:error, :not_raw} = CameraRaw.develop(path)
    assert CameraRaw.exif_tags(path) == %{}
  end
end
