defmodule PhoenixKit.Modules.Storage.HeifHdrTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage.Hdr
  alias PhoenixKit.Modules.Storage.HdrResize
  alias PhoenixKit.Modules.Storage.HeifHdr
  alias PhoenixKit.TestSupport.HeifGainMap

  @moduletag :tmp_dir

  # The pictures are encoded by ffmpeg and read by ImageMagick and ffmpeg again, the
  # same tools a real HEIC goes through.
  unless HeifGainMap.available?() and HeifHdr.available?(),
    do: @moduletag(skip: "ffmpeg (7.1+, libaom) and ImageMagick with AVIF are not installed")

  defp source(ctx, opts \\ []) do
    path = Path.join(ctx.tmp_dir, "src.avif")
    HeifGainMap.build(path, opts)
    path
  end

  defp dest(ctx), do: Path.join(ctx.tmp_dir, "out.jpg")

  defp dims(path) do
    {out, 0} =
      System.cmd("identify", ["-quiet", "-format", "%wx%h", path <> "[0]"],
        stderr_to_stdout: true
      )

    out
  end

  # The map is the second picture of the file.
  defp gain_map_of(ctx, path) do
    {:ok, %{gain: gain}} = path |> File.read!() |> HdrResize.split()
    out = Path.join(ctx.tmp_dir, "gain_#{System.unique_integer([:positive])}.jpg")
    File.write!(out, gain)
    out
  end

  # The mean brightness of the top and the bottom half of a picture.
  defp halves(path) do
    mean = fn gravity ->
      {out, 0} =
        System.cmd(
          "convert",
          [
            path <> "[0]",
            "-channel",
            "R",
            "-separate",
            "-gravity",
            gravity,
            "-crop",
            "100%x50%+0+0"
          ] ++
            ["+repage", "-format", "%[fx:mean]", "info:"],
          stderr_to_stdout: true
        )

      last_number(out)
    end

    {mean.("North"), mean.("South")}
  end

  test "a smaller copy is an HDR photo: the picture, the map scaled by the same ratio", ctx do
    src = source(ctx)

    assert {:ok, %{width: 160, height: 120, gain_map_bytes: bytes}} =
             HeifHdr.resize(src, dest(ctx), 160)

    assert dims(dest(ctx)) == "160x120"

    assert %{
             "gain_map" => true,
             "container" => "jpeg",
             "kinds" => ["ultrahdr"],
             "headroom" => headroom,
             "gain_map_bytes" => ^bytes
           } = Hdr.read(dest(ctx))

    assert_in_delta headroom, 4.0, 1.0e-6

    gain = gain_map_of(ctx, dest(ctx))
    assert dims(gain) == "80x60"
    {info, 0} = System.cmd("identify", ["-quiet", "-format", "%[colorspace]", gain])
    assert info == "Gray"
  end

  test "the map's parameters go across as they are, in the picture's and the map's XMP", ctx do
    src = source(ctx, params: %{gain_map_min: -0.5, gain_map_max: 1.5, gamma: 0.9})
    assert {:ok, _} = HeifHdr.resize(src, dest(ctx), 160)

    {:ok, %{gain: gain, primary: primary}} = dest(ctx) |> File.read!() |> HdrResize.split()

    assert gain =~ ~s(hdrgm:GainMapMin="-0.500000")
    assert gain =~ ~s(hdrgm:GainMapMax="1.500000")
    assert gain =~ ~s(hdrgm:Gamma="0.900000")
    assert gain =~ ~s(hdrgm:OffsetSDR="0.015625")
    assert gain =~ ~s(hdrgm:HDRCapacityMin="0.000000")
    assert gain =~ ~s(hdrgm:HDRCapacityMax="2.000000")
    assert gain =~ ~s(hdrgm:BaseRenditionIsHDR="False")

    # the picture names the map and its true length
    assert primary =~ ~s(Item:Semantic="GainMap")
    assert primary =~ ~s(Item:Length="#{byte_size(gain)}")
  end

  test "never larger than the source", ctx do
    assert {:ok, %{width: 320, height: 240}} = HeifHdr.resize(source(ctx), dest(ctx), 5000)
    assert dims(dest(ctx)) == "320x240"
  end

  test "a crop is cut where the focal point says, the map cut at the same place", ctx do
    src = source(ctx)

    assert {:ok, %{width: 100, height: 100}} =
             HeifHdr.crop(src, dest(ctx), {100, 100}, focal: {0.0, 0.5})

    assert dims(dest(ctx)) == "100x100"
    assert dims(gain_map_of(ctx, dest(ctx))) == "50x50"
    assert Hdr.gain_map?(Hdr.read(dest(ctx)))

    # The picture is a ramp, black on the left. Cut from the left edge it is darker
    # than cut from the right, and so is the map: they name the same place.
    left_picture = brightness(dest(ctx))
    left_map = brightness(gain_map_of(ctx, dest(ctx)))

    assert {:ok, _} = HeifHdr.crop(src, dest(ctx), {100, 100}, focal: {1.0, 0.5})

    assert brightness(dest(ctx)) > left_picture + 0.2
    assert brightness(gain_map_of(ctx, dest(ctx))) > left_map + 0.2
  end

  defp brightness(path) do
    {out, 0} =
      System.cmd(
        "convert",
        [path <> "[0]", "-channel", "R", "-separate", "-format", "%[fx:mean]", "info:"],
        stderr_to_stdout: true
      )

    last_number(out)
  end

  # ImageMagick 7 prints a deprecation notice for `convert` before its answer.
  defp last_number(out) do
    {number, _} = out |> String.split() |> List.last() |> Float.parse()
    number
  end

  test "a box larger than the photo shrinks to fit, keeping its shape", ctx do
    assert {:ok, %{width: 240, height: 240}} = HeifHdr.crop(source(ctx), dest(ctx), {640, 640})
    assert dims(dest(ctx)) == "240x240"
  end

  test "a turned photo is made upright, the map turned with it", ctx do
    # The ramp runs left to right as stored; a quarter turn anti-clockwise puts the
    # white end at the top, in the picture and in the map alike.
    src = source(ctx, rotation: 1)

    assert {:ok, %{width: 120, height: 160}} = HeifHdr.resize(src, dest(ctx), 120)
    assert dims(dest(ctx)) == "120x160"

    {top, bottom} = halves(dest(ctx))
    assert top > bottom + 0.2

    gain = gain_map_of(ctx, dest(ctx))
    assert dims(gain) == "60x80"
    {gain_top, gain_bottom} = halves(gain)
    assert gain_top > gain_bottom + 0.2
  end

  test "an upright photo's ramp stays left to right", ctx do
    assert {:ok, _} = HeifHdr.resize(source(ctx), dest(ctx), 160)
    {top, bottom} = halves(dest(ctx))
    assert_in_delta top, bottom, 0.05
  end

  test "strip_metadata keeps the picture a gain-map photo with only what describes it", ctx do
    assert {:ok, _} = HeifHdr.resize(source(ctx), dest(ctx), 160, strip_metadata: true)
    assert %{"gain_map" => true, "kinds" => ["ultrahdr"]} = Hdr.read(dest(ctx))

    {:ok, %{primary: primary}} = dest(ctx) |> File.read!() |> HdrResize.split()
    refute primary =~ "Exif"
  end

  describe "a map this does not carry over is an error, so the caller makes an SDR rendition" do
    test "a map with a value per colour channel", ctx do
      assert {:error, :multichannel_gain_map} =
               HeifHdr.resize(source(ctx, flags: 0x80), dest(ctx), 160)

      refute File.exists?(dest(ctx))
    end

    test "a map that goes from the HDR picture to the SDR one", ctx do
      assert {:error, :backward_gain_map} =
               HeifHdr.resize(source(ctx, flags: 0x20), dest(ctx), 160)
    end

    test "a map whose proportions are not the picture's", ctx do
      assert {:error, :gain_map_mismatch} =
               HeifHdr.resize(source(ctx, gain_map_size: {40, 120}), dest(ctx), 160)
    end

    test "a tone map of a newer version", ctx do
      assert {:error, :unsupported_tone_map} =
               HeifHdr.resize(source(ctx, params: %{min_version: 1}), dest(ctx), 160)
    end

    test "a photo with no tone map, a JPEG, and a missing file", ctx do
      plain = Path.join(ctx.tmp_dir, "plain.jpg")
      {_, 0} = System.cmd("convert", ["-size", "64x64", "xc:red", plain])

      assert {:error, _} = HeifHdr.resize(plain, dest(ctx), 32)
      assert {:error, _} = HeifHdr.crop(plain, dest(ctx), {32, 32})
      assert {:error, _} = HeifHdr.resize(Path.join(ctx.tmp_dir, "nope.heic"), dest(ctx), 32)
    end

    test "leaves no temporary files behind", ctx do
      before =
        File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "pk_heif_hdr_"))

      HeifHdr.resize(source(ctx, flags: 0x80), dest(ctx), 160)
      HeifHdr.resize(source(ctx), dest(ctx), 160)

      after_ =
        File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "pk_heif_hdr_"))

      assert after_ -- before == []
    end
  end

  describe "version_ok?/1" do
    test "releases from 7.1 can compose a tile grid" do
      for v <- ["7.1", "7.1.2", "8.0", "9.0.2", "n7.1.1", "10.2"] do
        assert HeifHdr.version_ok?(
                 "ffmpeg version #{v} Copyright (c) 2000-2026 the FFmpeg developers"
               )
      end
    end

    test "older ones cannot, and say so" do
      for v <- ["7.0", "6.1.1", "n5.1", "4.4.2"] do
        log =
          capture_log(fn ->
            refute HeifHdr.version_ok?("ffmpeg version #{v} Copyright (c) the FFmpeg developers")
          end)

        assert log =~ "need ffmpeg 7.1"
      end
    end

    test "a build with no release number is tried" do
      assert HeifHdr.version_ok?(
               "ffmpeg version N-118000-g1a2b3c4d Copyright (c) the FFmpeg developers"
             )

      assert HeifHdr.version_ok?("something else entirely")
    end
  end
end
