defmodule PhoenixKit.Modules.Storage.HeicSupportTest do
  @moduledoc """
  What an iPhone's HEIC photo needed that a JPEG did not: a rendition that keeps the
  original format cannot write HEIC (ImageMagick reads it but has no encoder), and
  the subject finder cannot read it through libvips (the precompiled library has no
  HEVC decoder). A BMP stands in for the second: ImageMagick writes and reads it,
  libvips does not read it. Skipped where ImageMagick is not installed.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Storage.{FocalPoint, ImageProcessor, Sniff, VariantGenerator}

  @compile {:no_warn_undefined, Vix.Vips.Operation}
  alias Vix.Vips.Operation

  @moduletag :tmp_dir
  @moduletag :integration

  defp imagemagick?,
    do: match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))

  # 1600x1000 grey noise with a red 120x120 square centered at (1300, 220).
  defp photo!(dir, name) do
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd("convert", [
        "-size",
        "1600x1000",
        "xc:gray(110)",
        "-attenuate",
        "0.15",
        "+noise",
        "Gaussian",
        "-fill",
        "rgb(255,20,20)",
        "-draw",
        "rectangle 1240,160 1360,280",
        # A photo has no transparency: without this the PNG carries an alpha
        # channel, and a rendition keeping its format would be see-through.
        "-alpha",
        "off",
        path
      ])

    path
  end

  defp size_of(path),
    do: elem(System.cmd("identify", ["-format", "%wx%h", path]), 0) |> String.trim()

  describe "the format of a rendition that keeps the original's" do
    test "is JPEG for a format ImageMagick cannot write", %{tmp_dir: dir} do
      if imagemagick?() do
        opaque = photo!(dir, "opaque.png")

        for ext <- ~w(heic HEIC heif avif) do
          assert VariantGenerator.output_format(nil, %{file_type: "image", ext: ext}, opaque) ==
                   "jpg",
                 ext
        end
      end
    end

    test "is the see-through format when the photo has transparency", %{tmp_dir: dir} do
      if imagemagick?() do
        clear = Path.join(dir, "clear.png")
        {_, 0} = System.cmd("convert", ["-size", "8x8", "xc:none", "png:" <> clear])

        assert VariantGenerator.output_format(nil, %{file_type: "image", ext: "heic"}, clear) ==
                 VariantGenerator.alpha_format()
      end
    end

    test "is left alone for a format ImageMagick writes, and for one that is asked for", %{
      tmp_dir: dir
    } do
      if imagemagick?() do
        opaque = photo!(dir, "opaque.png")

        for ext <- ~w(jpg png webp gif) do
          assert VariantGenerator.output_format(nil, %{file_type: "image", ext: ext}, opaque) ==
                   nil
        end

        # A rendition that says its format keeps it, whatever the original is.
        assert VariantGenerator.output_format("webp", %{file_type: "image", ext: "heic"}, opaque) ==
                 "webp"

        assert VariantGenerator.output_format("jpg", %{file_type: "image", ext: "heic"}, opaque) ==
                 "jpg"
      end
    end
  end

  describe "ImageProcessor.preview_jpeg/3" do
    test "makes a small JPEG of a format libvips cannot read", %{tmp_dir: dir} do
      if imagemagick?() do
        bmp = Path.join(dir, "photo.bmp")
        {_, 0} = System.cmd("convert", [photo!(dir, "src.png"), "bmp:" <> bmp])
        out = Path.join(dir, "preview.jpg")

        assert {:ok, ^out} = ImageProcessor.preview_jpeg(bmp, out, 512)
        assert size_of(out) == "512x320"
        assert {:ok, %{format: :jpeg}} = Sniff.sniff(out)
      end
    end

    test "never enlarges", %{tmp_dir: dir} do
      if imagemagick?() do
        small = Path.join(dir, "small.png")
        {_, 0} = System.cmd("convert", ["-size", "200x100", "xc:red", small])
        out = Path.join(dir, "small.jpg")

        assert {:ok, _} = ImageProcessor.preview_jpeg(small, out, 512)
        assert size_of(out) == "200x100"
      end
    end

    test "turns a see-through image opaque, on white", %{tmp_dir: dir} do
      if imagemagick?() do
        clear = Path.join(dir, "clear.png")
        {_, 0} = System.cmd("convert", ["-size", "40x40", "xc:none", "png:" <> clear])
        out = Path.join(dir, "clear.jpg")

        assert {:ok, _} = ImageProcessor.preview_jpeg(clear, out, 512)

        {pixel, 0} = System.cmd("convert", [out, "-format", "%[pixel:p{5,5}]", "info:"])
        assert String.trim(pixel) =~ ~r/white|gray\(255\)|srgb\(255,255,255\)/
      end
    end

    test "refuses what is not an image, and a missing file", %{tmp_dir: dir} do
      text = Path.join(dir, "note.txt")
      File.write!(text, "not a photo")

      assert {:error, _} = ImageProcessor.preview_jpeg(text, Path.join(dir, "o.jpg"))

      assert {:error, _} =
               ImageProcessor.preview_jpeg(Path.join(dir, "nope.png"), Path.join(dir, "o.jpg"))
    end
  end

  describe "the subject of a photo libvips cannot read" do
    test "is found through an ImageMagick preview", %{tmp_dir: dir} do
      if imagemagick?() and FocalPoint.detection_available?() do
        bmp = Path.join(dir, "photo.bmp")
        {_, 0} = System.cmd("convert", [photo!(dir, "src.png"), "bmp:" <> bmp])

        # libvips alone has no BMP loader.
        assert {:error, _} = Operation.thumbnail(bmp, 512, size: :VIPS_SIZE_DOWN)

        assert {:ok, {x, y}} = FocalPoint.detect(bmp)
        assert_in_delta x, 0.81, 0.06
        assert_in_delta y, 0.22, 0.06
      end
    end

    test "leaves no preview behind", %{tmp_dir: dir} do
      if imagemagick?() and FocalPoint.detection_available?() do
        bmp = Path.join(dir, "photo.bmp")
        {_, 0} = System.cmd("convert", [photo!(dir, "src.png"), "bmp:" <> bmp])
        before = Path.wildcard(Path.join(System.tmp_dir!(), "phoenix_kit_focal_*"))

        assert {:ok, _} = FocalPoint.detect(bmp)

        assert Path.wildcard(Path.join(System.tmp_dir!(), "phoenix_kit_focal_*")) -- before == []
      end
    end

    test "a flat photo of that kind has no subject, and is not tried twice", %{tmp_dir: dir} do
      if imagemagick?() and FocalPoint.detection_available?() do
        bmp = Path.join(dir, "flat.bmp")
        {_, 0} = System.cmd("convert", ["-size", "800x600", "xc:gray50", "bmp:" <> bmp])

        assert FocalPoint.detect(bmp) == :error
      end
    end

    test "something that is not a photo has none", %{tmp_dir: dir} do
      text = Path.join(dir, "note.txt")
      File.write!(text, "not a photo")

      assert FocalPoint.detect(text) == :error
    end
  end
end
