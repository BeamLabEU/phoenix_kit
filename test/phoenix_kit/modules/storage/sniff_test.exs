defmodule PhoenixKit.Modules.Storage.SniffTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Sniff

  @moduletag :tmp_dir

  defp format(bytes), do: Sniff.sniff_binary(bytes)

  test "recognises the raster formats by their signatures" do
    assert {:ok, %{format: :png, mime: "image/png"}} =
             format(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0>>)

    assert {:ok, %{format: :jpeg}} = format(<<0xFF, 0xD8, 0xFF, 0xE0, 0>>)
    assert {:ok, %{format: :gif}} = format("GIF89a....")
    assert {:ok, %{format: :webp}} = format("RIFF" <> <<1, 2, 3, 4>> <> "WEBPVP8 ")
    assert {:ok, %{format: :tiff}} = format(<<"II", 42, 0, 8, 0>>)
    assert {:ok, %{format: :heic}} = format(<<0, 0, 0, 24>> <> "ftypheic" <> "0000")
    assert {:ok, %{format: :avif}} = format(<<0, 0, 0, 24>> <> "ftypavif" <> "0000")
  end

  test "recognises the camera raw formats that have headers of their own" do
    assert {:ok, %{format: :cr3, mime: "image/x-canon-cr3"}} =
             format(<<0, 0, 0, 24>> <> "ftypcrx " <> "0000")

    assert {:ok, %{format: :raf}} = format("FUJIFILMCCD-RAW 0201FF383501")
    assert {:ok, %{format: :orf}} = format("IIRS" <> <<8, 0, 0, 0>>)
    assert {:ok, %{format: :orf}} = format("IIRO" <> <<8, 0, 0, 0>>)
    assert {:ok, %{format: :rw2}} = format(<<"IIU", 0, 24, 0, 0, 0>>)

    # The TIFF-shaped ones (NEF, CR2, DNG…) are TIFFs to the bytes.
    assert {:ok, %{format: :tiff}} = format(<<"MM", 0, 42, 0, 0, 0, 8>>)

    for format <- Sniff.camera_raw_formats(), do: refute(Sniff.raster?(format))
  end

  test "a BMP needs its header, not just the letters BM" do
    header = fn dib -> <<"BM", 70::little-32, 0::32, 54::little-32, dib::little-32, 0, 0>> end

    for dib <- [12, 40, 52, 56, 64, 108, 124],
        do: assert({:ok, %{format: :bmp, mime: "image/bmp"}} = format(header.(dib)))

    # Text that merely starts with the two letters is not an image.
    assert :unknown = format("BMI,weight,height\n70,180\n")
    assert :unknown = format("BMW 3-series, 2019\n")
    assert :unknown = format("BM")
    assert :unknown = format(header.(41))
  end

  test "recognises what must never reach ImageMagick" do
    assert {:ok, %{format: :svg}} = format(~s(<?xml version="1.0"?>\n<svg xmlns="x">))
    assert {:ok, %{format: :svg}} = format(~s(  <svg width="10">))
    assert {:ok, %{format: :pdf}} = format("%PDF-1.7\n")
    assert {:ok, %{format: :postscript}} = format("%!PS-Adobe-3.0")
    assert {:ok, %{format: :mp4}} = format(<<0, 0, 0, 24>> <> "ftypisom" <> "0000")
  end

  test "text and unknown bytes are unknown; a split UTF-8 character does not crash" do
    assert :unknown = format("push graphic-context\nviewbox 0 0 10 10")
    assert :unknown = format("hello")
    assert :unknown = format(<<"<p>é", 0xC3>>)
    assert :unknown = format("")
  end

  test "only raster formats get a pinned coder" do
    for f <- Sniff.raster_formats(), do: assert(is_binary(Sniff.magick_coder(f)))
    for f <- [:svg, :pdf, :postscript, :ico, :zip, nil], do: assert(Sniff.magick_coder(f) == nil)
  end

  test "sniff/1 reads the file, and a missing file is unknown", %{tmp_dir: dir} do
    path = Path.join(dir, "named.jpg")
    File.write!(path, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0>>)
    assert {:ok, %{format: :png}} = Sniff.sniff(path)
    assert :unknown = Sniff.sniff(Path.join(dir, "absent"))
  end
end
