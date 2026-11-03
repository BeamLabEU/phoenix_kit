defmodule PhoenixKit.Modules.Storage.SvgRasterTest do
  @moduledoc """
  An SVG's sizes and previews are drawn from a PNG of it, made by librsvg in a folder
  of its own. Skipped where ImageMagick has no librsvg coder.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{ImageProcessor, SvgRaster, VariantGenerator}

  @moduletag :tmp_dir
  @moduletag :integration

  defp rsvg? do
    match?({_, 0}, System.cmd("magick", ["-version"], stderr_to_stdout: true)) and
      System.cmd("magick", ["-list", "format"], stderr_to_stdout: true)
      |> elem(0)
      |> String.contains?("RSVG")
  end

  defp write!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  @svg """
  <?xml version="1.0"?>
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 80" width="120" height="80">
    <script>alert(1)</script>
    <rect x="10" y="10" width="100" height="60" fill="#e33"/>
    <image href="file:///etc/passwd" width="10" height="10"/>
    <image href="secret.png" width="10" height="10"/>
  </svg>
  """

  test "draws the SVG with its longest side at the size asked, see-through", %{tmp_dir: dir} do
    if rsvg?() do
      # A file beside the SVG that it names is not where it is drawn, so it is not read.
      {_, 0} =
        System.cmd("magick", ["-size", "4x4", "xc:blue", "png:" <> Path.join(dir, "secret.png")])

      assert {:ok, png} = SvgRaster.to_png(write!(dir, "logo.svg", @svg), 600)
      assert {:ok, {600, 400}} = ImageProcessor.extract_dimensions(png)
      assert ImageProcessor.has_alpha_channel?(png)

      # Where the blue square would be (0,0 to 50,50 at this size) is see-through.
      {pixel, 0} =
        System.cmd("magick", [png, "-format", "%[fx:int(255*p{25,25}.a)]", "info:"])

      assert pixel == "0"
      File.rm!(png)
    end
  end

  test "refuses what is not an SVG", %{tmp_dir: dir} do
    assert {:error, {:not_svg, _}} = SvgRaster.to_png(write!(dir, "x.svg", "not a picture"))
  end

  test "leaves nothing behind in the temporary folder", %{tmp_dir: dir} do
    if rsvg?() do
      before =
        File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "phoenix_kit_svg_"))

      {:ok, png} = SvgRaster.to_png(write!(dir, "logo.svg", @svg), 64)
      File.rm!(png)

      later =
        File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "phoenix_kit_svg_"))

      assert later -- before == []
    end
  end

  test "a size that keeps an SVG's format is a picture", %{tmp_dir: dir} do
    if rsvg?() do
      {:ok, png} = SvgRaster.to_png(write!(dir, "logo.svg", @svg), 64)

      assert VariantGenerator.output_format(nil, %{file_type: "image", ext: "svg"}, png) ==
               VariantGenerator.alpha_format()

      assert VariantGenerator.output_format("webp", %{file_type: "image", ext: "svg"}, png) ==
               "webp"

      File.rm!(png)
    end
  end

  test "is for image/svg+xml only" do
    assert SvgRaster.svg?("image/svg+xml")
    assert SvgRaster.svg?("IMAGE/SVG+XML")
    refute SvgRaster.svg?("image/png")
    refute SvgRaster.svg?(nil)
  end
end
