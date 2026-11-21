defmodule PhoenixKit.Modules.Storage.HdrResizeTest do
  @moduledoc """
  A resized gain-map JPEG is still an HDR photo: two pictures, a directory that
  describes them, the map's length in the XMP, and the map's own parameters carried
  over untouched.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Hdr
  alias PhoenixKit.Modules.Storage.HdrResize
  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKit.Test.ExifFixture
  alias PhoenixKit.TestSupport.GainMapJpeg

  @moduletag :tmp_dir

  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  defp source(ctx, opts \\ []) do
    path = Path.join(ctx.tmp_dir, "src.jpg")
    GainMapJpeg.build(path, opts)
    path
  end

  defp dims(path) do
    {out, 0} =
      System.cmd("identify", ["-quiet", "-format", "%wx%h", path <> "[0]"],
        stderr_to_stdout: true
      )

    out
  end

  test "the fixture itself is read as an HDR photo", ctx do
    path = source(ctx)
    assert %{"gain_map" => true, "kinds" => ["ultrahdr"], "headroom" => h} = Hdr.read(path)
    assert_in_delta h, 8.0, 0.001
  end

  test "a smaller copy keeps the map, scaled by the same ratio", ctx do
    src = source(ctx)
    dest = Path.join(ctx.tmp_dir, "out.jpg")

    assert {:ok, %{width: 800, height: 600, gain_map_bytes: gm}} =
             HdrResize.resize(src, dest, 800)

    assert dims(dest) == "800x600"

    assert %{"gain_map" => true, "kinds" => ["ultrahdr"], "gain_map_bytes" => ^gm} =
             Hdr.read(dest)

    assert File.stat!(dest).size < File.stat!(src).size
  end

  test "the map's length in the picture's XMP is the new one, and the directory agrees", ctx do
    src = source(ctx)
    dest = Path.join(ctx.tmp_dir, "out.jpg")
    {:ok, %{gain_map_bytes: gm}} = HdrResize.resize(src, dest, 640)

    bin = File.read!(dest)
    assert [_, length] = Regex.run(~r/Item:Semantic="GainMap"[^>]*Item:Length="(\d+)"/s, bin)
    assert String.to_integer(length) == gm

    # The map is the last `gm` bytes and is a JPEG of its own.
    map = binary_part(bin, byte_size(bin) - gm, gm)
    assert <<0xFF, 0xD8, 0xFF, _::binary>> = map
    map_path = Path.join(ctx.tmp_dir, "map.jpg")
    File.write!(map_path, map)
    assert dims(map_path) == "160x120", "the map is scaled by the same ratio as the picture"

    # The map keeps its parameters.
    assert map =~ ~s(hdrgm:GainMapMax="3.0")
  end

  test "the extended XMP is dropped, with its pointer", ctx do
    src = source(ctx, extended_xmp: true)
    assert File.read!(src) =~ "HasExtendedXMP"

    dest = Path.join(ctx.tmp_dir, "out.jpg")
    assert {:ok, _} = HdrResize.resize(src, dest, 800)

    bin = File.read!(dest)
    refute bin =~ "HasExtendedXMP"
    refute bin =~ "xmp/extension"
    assert %{"gain_map" => true} = Hdr.read(dest)
  end

  test "a picture already smaller than asked stays its size", ctx do
    src = source(ctx, width: 400, height: 300)
    dest = Path.join(ctx.tmp_dir, "out.jpg")
    assert {:ok, %{width: 400}} = HdrResize.resize(src, dest, 1920)
    assert %{"gain_map" => true} = Hdr.read(dest)
  end

  for orientation <- 5..8 do
    test "a quarter-turned photo fixes its displayed width (orientation #{orientation})", ctx do
      src =
        source(ctx,
          width: 2400,
          height: 1800,
          exif: ExifFixture.segment(%{orientation: unquote(orientation)})
        )

      dest = Path.join(ctx.tmp_dir, "turned-resize.jpg")
      assert {:ok, %{width: 800, height: 1067}} = HdrResize.resize(src, dest, 800)
      assert {:ok, {800, 1067, _}} = ImageProcessor.oriented_info(dest)
      assert %{"gain_map" => true} = Hdr.read(dest)
    end
  end

  test "a very thin turned photo and its map can shrink to one displayed pixel", ctx do
    src =
      source(ctx,
        width: 4,
        height: 400,
        exif: ExifFixture.segment(%{orientation: 6})
      )

    dest = Path.join(ctx.tmp_dir, "thin.jpg")
    assert {:ok, %{width: 1, height: 1}} = HdrResize.resize(src, dest, 1)
    assert {:ok, {1, 1, _}} = ImageProcessor.oriented_info(dest)
    assert %{"gain_map" => true} = Hdr.read(dest)
  end

  test "a rewritten XMP packet too large for a JPEG segment is refused", ctx do
    xml = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about='#{String.duplicate("\"", 13_000)}'/>
    </rdf:RDF></x:xmpmeta>
    """

    src = source(ctx, primary_xmp: xml)
    dest = Path.join(ctx.tmp_dir, "too-large.jpg")
    assert {:error, "HDR XMP exceeds the JPEG segment limit"} = HdrResize.resize(src, dest, 800)
    refute File.exists?(dest)
  end

  test "an ordinary JPEG, and something that is not a JPEG, are refused", ctx do
    plain = Path.join(ctx.tmp_dir, "plain.jpg")
    {_, 0} = System.cmd("convert", ["-size", "200x100", "xc:red", plain], stderr_to_stdout: true)
    dest = Path.join(ctx.tmp_dir, "out.jpg")

    assert {:error, :no_gain_map} = HdrResize.resize(plain, dest, 100)
    refute File.exists?(dest)

    text = Path.join(ctx.tmp_dir, "t.txt")
    File.write!(text, "hello")
    assert {:error, :not_a_jpeg} = HdrResize.resize(text, dest, 100)
    assert {:error, :enoent} = HdrResize.resize(Path.join(ctx.tmp_dir, "nope"), dest, 100)
  end

  describe "crop/4" do
    # The mean brightness (0..1) of a picture, after `ops`.
    defp mean(path, ops \\ []) do
      {out, 0} =
        System.cmd("convert", [path <> "[0]"] ++ ops ++ ["-format", "%[fx:mean]", "info:"],
          stderr_to_stdout: true
        )

      # ImageMagick 7 prints "WARNING: The convert command is deprecated" on
      # stderr, which is folded into `out`; the number is the last word.
      out |> String.split() |> List.last() |> String.to_float()
    end

    # The gain map of `path`, written next to it.
    defp gain_of(path, ctx) do
      bin = File.read!(path)
      {:ok, %{gain: gain}} = HdrResize.split(bin)
      out = Path.join(ctx.tmp_dir, "gain_#{System.unique_integer([:positive])}.jpg")
      File.write!(out, gain)
      out
    end

    test "is a box of the asked size that is still an HDR photo", ctx do
      src = source(ctx)
      dest = Path.join(ctx.tmp_dir, "out.jpg")

      assert {:ok, %{width: 300, height: 300, gain_map_bytes: gm}} =
               HdrResize.crop(src, dest, {300, 300})

      assert dims(dest) == "300x300"

      assert %{"gain_map" => true, "kinds" => ["ultrahdr"], "gain_map_bytes" => ^gm} =
               Hdr.read(dest)

      bin = File.read!(dest)
      assert [_, length] = Regex.run(~r/Item:Semantic="GainMap"[^>]*Item:Length="(\d+)"/s, bin)
      assert String.to_integer(length) == gm

      # The map covers the same part of the picture, at the same fraction of the size
      assert dims(gain_of(dest, ctx)) == "75x75"
      assert binary_part(bin, byte_size(bin) - gm, gm) =~ ~s(hdrgm:GainMapMax="3.0")
    end

    test "the map is cut where the picture is: the subject's part of both", ctx do
      # Portrait: a square box slides up and down. The picture runs white to black
      # downwards, the map from dark grey to light grey.
      src = source(ctx, width: 1200, height: 1600)
      top = Path.join(ctx.tmp_dir, "top.jpg")
      bottom = Path.join(ctx.tmp_dir, "bottom.jpg")

      {:ok, _} = HdrResize.crop(src, top, {300, 300}, focal: {0.5, 0.0})
      {:ok, _} = HdrResize.crop(src, bottom, {300, 300}, focal: {0.5, 1.0})

      # The picture: the top three quarters against the bottom three quarters
      assert_in_delta mean(top), 0.625, 0.03
      assert_in_delta mean(bottom), 0.375, 0.03

      # The map: the same parts of it (20..80% grey from the top down)
      assert_in_delta mean(gain_of(top, ctx)), 0.425, 0.04
      assert_in_delta mean(gain_of(bottom, ctx)), 0.575, 0.04
    end

    test "no focal point is the middle", ctx do
      src = source(ctx, width: 1200, height: 1600)
      a = Path.join(ctx.tmp_dir, "a.jpg")
      b = Path.join(ctx.tmp_dir, "b.jpg")

      {:ok, _} = HdrResize.crop(src, a, {300, 300})
      {:ok, _} = HdrResize.crop(src, b, {300, 300}, focal: {0.5, 0.5})

      assert_in_delta mean(a), mean(b), 0.005
      assert_in_delta mean(a), 0.5, 0.03
    end

    test "a box bigger than the picture shrinks to it, and keeps its shape", ctx do
      src = source(ctx, width: 400, height: 300)
      dest = Path.join(ctx.tmp_dir, "out.jpg")

      assert {:ok, %{width: 300, height: 300}} = HdrResize.crop(src, dest, {1000, 1000})
      assert dims(dest) == "300x300"
      assert %{"gain_map" => true} = Hdr.read(dest)
    end

    # Every way a camera can turn a photo: the box is cut where the photo is shown,
    # which ImageMagick (`-auto-orient`, then `-crop`) tells us independently.
    for orientation <- 1..8, focal <- [{0.0, 0.0}, {1.0, 1.0}], box <- [{300, 100}, {100, 300}] do
      test "a turned photo (orientation #{orientation}) is cut where it is shown, focal #{inspect(focal)}, box #{inspect(box)}",
           ctx do
        orientation = unquote(orientation)
        focal = unquote(Macro.escape(focal))
        {bw, bh} = unquote(Macro.escape(box))

        src = source(ctx, exif: ExifFixture.segment(%{orientation: orientation}))
        dest = Path.join(ctx.tmp_dir, "out.jpg")

        assert {:ok, %{width: ^bw, height: ^bh}} =
                 HdrResize.crop(src, dest, {bw, bh}, focal: focal)

        # What was asked, on the photo as shown
        {shown_w, shown_h} = if orientation in 5..8, do: {1200, 1600}, else: {1600, 1200}

        {cw, ch, left, top} =
          ImageProcessor.focus_window(
            focal,
            {shown_w, shown_h},
            {bw, bh}
          )

        oracle =
          mean(src, [
            "-auto-orient",
            "+repage",
            "-crop",
            "#{cw}x#{ch}+#{left}+#{top}",
            "+repage",
            "-resize",
            "#{bw}x#{bh}!"
          ])

        assert_in_delta mean(dest, ["-auto-orient"]), oracle, 0.03
        assert %{"gain_map" => true} = Hdr.read(dest)
      end
    end
  end
end
