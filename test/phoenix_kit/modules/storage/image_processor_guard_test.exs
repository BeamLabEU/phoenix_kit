defmodule PhoenixKit.Modules.Storage.ImageProcessorGuardTest do
  @moduledoc """
  Every ImageMagick call decodes with the coder the file's bytes name, under
  resource limits: a file named `.jpg` is decoded as the PNG it is, and an
  SVG, an MVG script or a text file never reaches a decoder at all.
  Skipped where ImageMagick is not installed.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ImageProcessor

  @moduletag :tmp_dir
  @moduletag :integration

  defp imagemagick? do
    match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp png(path, size \\ "80x40") do
    {_, 0} = System.cmd("convert", ["-size", size, "xc:skyblue", "png:" <> path])
    path
  end

  test "a PNG named .jpg is decoded as PNG and resized", %{tmp_dir: dir} do
    if imagemagick?() do
      src = png(Path.join(dir, "photo.jpg"))
      assert {:ok, "png:" <> _} = ImageProcessor.pinned_input(src)
      out = Path.join(dir, "small.png")
      assert {:ok, ^out} = ImageProcessor.resize(src, out, 40, nil)
      assert {:ok, {40, 20}} = ImageProcessor.extract_dimensions(out)
    end
  end

  test "SVG, MVG and text are refused before any decoder runs", %{tmp_dir: dir} do
    svg = Path.join(dir, "evil.png")
    File.write!(svg, ~s(<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>))
    mvg = Path.join(dir, "evil.jpg")
    File.write!(mvg, "push graphic-context\nviewbox 0 0 640 480\nimage over 0,0 0,0 'x'")

    for path <- [svg, mvg] do
      assert {:error, "unsupported image format"} = ImageProcessor.pinned_input(path)
      assert {:error, _} = ImageProcessor.extract_dimensions(path)
      assert {:error, _} = ImageProcessor.resize(path, Path.join(dir, "o.png"), 10, nil)

      assert {:error, _} =
               ImageProcessor.resize_and_crop_center(path, Path.join(dir, "o.png"), 10, 10)
    end
  end

  test "every call carries the resource limits" do
    args = ImageProcessor.limit_args()
    for limit <- ~w(memory map disk area width height time), do: assert(limit in args)
  end

  describe "content_mime_type/3 — what the upload is stored as" do
    test "a raster image is stored as the type its bytes are", %{tmp_dir: dir} do
      path = Path.join(dir, "a.jpg")
      File.write!(path, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0>>)
      assert Storage.content_mime_type("image/jpeg", path, "a.jpg") == "image/png"
    end

    test "a claimed image that is not one is stored as what it is", %{tmp_dir: dir} do
      svg = Path.join(dir, "x.png")
      File.write!(svg, ~s(<svg xmlns="x"></svg>))
      assert Storage.content_mime_type("image/png", svg, "x.png") == "image/svg+xml"

      text = Path.join(dir, "y.png")
      File.write!(text, "not an image")
      assert Storage.content_mime_type("image/png", text, "y.png") == "application/octet-stream"
    end

    test "a camera raw file keeps the type its name gives, over the TIFF it looks like", %{
      tmp_dir: dir
    } do
      nef = Path.join(dir, "a.nef")
      File.write!(nef, <<"MM", 0, 42, 0, 0, 0, 8>>)
      assert Storage.content_mime_type("image/x-nikon-nef", nef, "a.nef") == "image/x-nikon-nef"

      raf = Path.join(dir, "a.raf")
      File.write!(raf, "FUJIFILMCCD-RAW 0201")
      assert Storage.content_mime_type("image/x-fuji-raf", raf, "a.raf") == "image/x-fuji-raf"

      # A JPEG called .nef is a JPEG.
      jpeg = Path.join(dir, "b.nef")
      File.write!(jpeg, <<0xFF, 0xD8, 0xFF, 0xE0, 0>>)
      assert Storage.content_mime_type("image/x-nikon-nef", jpeg, "b.nef") == "image/jpeg"
    end

    test "non-image claims are left alone", %{tmp_dir: dir} do
      path = Path.join(dir, "notes.txt")
      File.write!(path, "plain text")
      assert Storage.content_mime_type("text/plain", path, "notes.txt") == "text/plain"
    end
  end
end
