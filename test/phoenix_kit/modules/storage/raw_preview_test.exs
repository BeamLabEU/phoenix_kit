defmodule PhoenixKit.Modules.Storage.RawPreviewTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.RawPreview

  @moduletag :tmp_dir

  defp jpeg!(dir, size, extra \\ []) do
    path = Path.join(dir, "#{size}-#{System.unique_integer([:positive])}.jpg")

    {_, 0} =
      System.cmd("magick", ["-size", size] ++ extra ++ ["plasma:", "-quality", "70", path],
        stderr_to_stdout: true
      )

    File.read!(path)
  end

  # IFD0 with one entry: Orientation (0x0112, SHORT, 1) = `value`.
  defp tiff(:little, value),
    do:
      <<"II", 42, 0, 8::little-32, 1::little-16, 0x0112::little-16, 3::little-16, 1::little-32,
        value::little-16, 0::16, 0::32>>

  defp tiff(:big, value),
    do: <<"MM", 0, 42, 8::32, 1::16, 0x0112::16, 3::16, 1::32, value::16, 0::16, 0::32>>

  test "finds the largest JPEG among those a raw file holds", %{tmp_dir: dir} do
    small = jpeg!(dir, "160x120")
    large = jpeg!(dir, "640x480", ["-interlace", "Plane"])

    bin =
      tiff(:little, 1) <>
        :crypto.strong_rand_bytes(300) <> small <> <<0, 1, 2>> <> large <> "tail"

    assert %{width: 640, height: 480, offset: offset, length: length} = RawPreview.find(bin)
    assert binary_part(bin, offset, length) == large
  end

  test "lossless JPEG (a sensor's data) and stray bytes are not previews" do
    lossless = <<0xFF, 0xD8, 0xFF, 0xC3, 0, 11, 8, 0, 100, 0, 100, 1, 1, 0x11, 0>>
    assert RawPreview.find(lossless <> <<0xFF, 0xD9>>) == nil
    assert RawPreview.find(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0>>) == nil
    assert RawPreview.find("no pictures here") == nil
  end

  test "reads the orientation from the raw file's TIFF header, either byte order" do
    assert RawPreview.orientation(tiff(:little, 6)) == 6
    assert RawPreview.orientation(tiff(:big, 8)) == 8
    assert RawPreview.orientation(<<"IIRS">> <> binary_part(tiff(:little, 3), 4, 18)) == 3
    assert RawPreview.orientation("FUJIFILMCCD-RAW 0201") == nil
  end

  test "reads a CR3's from its CMT1 box" do
    cmt1 = tiff(:little, 6)
    bin = <<24::32, "ftypcrx ", 0::32, 0::32>> <> <<byte_size(cmt1) + 8::32, "CMT1">> <> cmt1
    assert RawPreview.orientation(bin) == 6
  end

  test "names each orientation as ImageMagick does" do
    assert Enum.map(1..8, &RawPreview.magick_orient/1) ==
             ~w(TopLeft TopRight BottomRight BottomLeft LeftTop RightTop RightBottom LeftBottom)
  end
end
