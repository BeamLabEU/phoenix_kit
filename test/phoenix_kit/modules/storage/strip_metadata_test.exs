defmodule PhoenixKit.Modules.Storage.StripMetadataTest do
  @moduledoc """
  A rendition can leave the camera's metadata out: the device, the time, the GPS
  position, maker notes. The colour profile stays and the picture is shown as it was,
  because the orientation is applied to the pixels (or, for an HDR photo, is the one
  tag kept). Skipped where ImageMagick is not installed.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{Dimension, Hdr, HdrResize, ImageProcessor}
  alias PhoenixKit.Test.ExifFixture
  alias PhoenixKit.TestSupport.GainMapJpeg

  @moduletag :tmp_dir

  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  @tags %{
    make: "Cam",
    gps_latitude_ref: "N",
    gps_latitude: [{59, 1}, {26, 1}, {0, 1}],
    gps_longitude_ref: "E",
    gps_longitude: [{24, 1}, {45, 1}, {0, 1}]
  }

  # A 64x48 JPEG that says it was taken with a camera, at a place.
  defp photo(ctx, extra \\ %{}) do
    ExifFixture.write_jpeg!(Path.join(ctx.tmp_dir, "photo.jpg"), Map.merge(@tags, extra))
  end

  defp identify(path, format) do
    {out, 0} = System.cmd("identify", ["-format", format, path <> "[0]"], stderr_to_stdout: true)
    String.trim(out)
  end

  defp make(path), do: identify(path, "%[EXIF:Make]")
  defp gps(path), do: identify(path, "%[exif:*]")

  test "a size that is not told to strip keeps the metadata, as it always did", ctx do
    out = Path.join(ctx.tmp_dir, "keep.jpg")
    assert {:ok, ^out} = ImageProcessor.resize(photo(ctx), out, 32, nil)
    assert make(out) == "Cam"
    assert gps(out) =~ "GPSInfo"
  end

  test "a resized size without metadata has neither the camera nor the place", ctx do
    out = Path.join(ctx.tmp_dir, "strip.jpg")
    assert {:ok, ^out} = ImageProcessor.resize(photo(ctx), out, 32, nil, strip_metadata: true)
    assert identify(out, "%wx%h") == "32x24"
    refute make(out) == "Cam"
    refute gps(out) =~ "GPSInfo"
  end

  test "so does a cropped one, centred or around the subject", ctx do
    center = Path.join(ctx.tmp_dir, "center.jpg")

    assert {:ok, ^center} =
             ImageProcessor.resize_and_crop_center(photo(ctx), center, 20, 20,
               strip_metadata: true
             )

    focus = Path.join(ctx.tmp_dir, "focus.jpg")

    assert {:ok, ^focus} =
             ImageProcessor.resize_and_crop_focus(photo(ctx), focus, 20, 20, {0.5, 0.5},
               strip_metadata: true
             )

    for out <- [center, focus] do
      assert identify(out, "%wx%h") == "20x20"
      refute make(out) == "Cam"
      refute gps(out) =~ "GPSInfo"
    end
  end

  test "a turned photo is shown the same way up once the tag is gone", ctx do
    # 64x48 as stored, with orientation 6: shown 48 wide and 64 tall.
    turned = photo(ctx, %{orientation: 6})
    assert identify(turned, "%[orientation]") == "RightTop"

    kept = Path.join(ctx.tmp_dir, "kept.jpg")
    {:ok, _} = ImageProcessor.resize(turned, kept, 32, nil)
    assert identify(kept, "%[orientation]") == "RightTop"

    out = Path.join(ctx.tmp_dir, "stripped.jpg")
    assert {:ok, ^out} = ImageProcessor.resize(turned, out, 32, nil, strip_metadata: true)
    assert identify(out, "%[orientation]") in ["TopLeft", "Undefined"]
    # 32 wide as stored (24 tall), then turned: the same picture shown 24 wide, 32 tall.
    assert identify(out, "%wx%h") == "24x32"
    assert identify(kept, "%wx%h") == "32x24"
  end

  test "a turned photo's box crop keeps its shape", ctx do
    turned = photo(ctx, %{orientation: 6})
    out = Path.join(ctx.tmp_dir, "box.jpg")

    assert {:ok, ^out} =
             ImageProcessor.resize_and_crop_center(turned, out, 40, 20, strip_metadata: true)

    assert identify(out, "%wx%h") == "40x20"
  end

  describe "an HDR photo" do
    defp hdr(ctx, tags) do
      path = Path.join(ctx.tmp_dir, "hdr.jpg")
      GainMapJpeg.build(path, exif: ExifFixture.segment(Map.merge(@tags, tags)))
      path
    end

    test "keeps its gain map and drops the camera's EXIF", ctx do
      src = hdr(ctx, %{})
      assert make(src) == "Cam"

      out = Path.join(ctx.tmp_dir, "out.jpg")
      assert {:ok, %{width: 800}} = HdrResize.resize(src, out, 800, strip_metadata: true)

      assert %{"gain_map" => true} = Hdr.read(out)
      refute make(out) == "Cam"
      refute gps(out) =~ "GPSInfo"
    end

    test "keeps the EXIF when not told to strip", ctx do
      out = Path.join(ctx.tmp_dir, "kept.jpg")
      assert {:ok, _} = HdrResize.resize(hdr(ctx, %{}), out, 800)
      assert make(out) == "Cam"
    end

    test "keeps the orientation, and only that, of a turned photo", ctx do
      out = Path.join(ctx.tmp_dir, "turned.jpg")

      assert {:ok, _} =
               HdrResize.resize(hdr(ctx, %{orientation: 8}), out, 800, strip_metadata: true)

      assert identify(out, "%[orientation]") == "LeftBottom"
      refute make(out) == "Cam"
      assert %{"gain_map" => true} = Hdr.read(out)
    end

    test "an upright photo is left with no EXIF at all", ctx do
      out = Path.join(ctx.tmp_dir, "upright.jpg")
      assert {:ok, _} = HdrResize.resize(hdr(ctx, %{}), out, 800, strip_metadata: true)
      refute File.read!(out) =~ "Exif"
    end
  end

  test "a size strips unless it says otherwise", _ctx do
    assert Dimension.strip_metadata?(%Dimension{})
    assert Dimension.strip_metadata?(Dimension.new([]))
    refute Dimension.strip_metadata?(Dimension.new(strip_metadata: false))
  end
end
