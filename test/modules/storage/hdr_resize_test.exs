defmodule PhoenixKit.Modules.Storage.HdrResizeTest do
  @moduledoc """
  A resized gain-map JPEG is still an HDR photo: two pictures, a directory that
  describes them, the map's length in the XMP, and the map's own parameters carried
  over untouched.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Hdr
  alias PhoenixKit.Modules.Storage.HdrResize
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
    {out, 0} = System.cmd("identify", ["-format", "%wx%h", path <> "[0]"], stderr_to_stdout: true)
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
end
