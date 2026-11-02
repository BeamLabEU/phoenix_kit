defmodule PhoenixKit.Modules.Storage.SvgRaster do
  @moduledoc """
  A PNG of an SVG, which is what an SVG's metadata, sizes and previews are made from
  (`ProcessFileJob`, `VariantGenerator`), the way a PDF's are made from a JPEG of its
  first page. The SVG itself is stored and served as it is: as a download, never
  inline (`FileController.disposition_for/1`), so a script in it never runs as the site.

  ## Why this is safe enough to run on an upload

  SVG is kept out of `Sniff.raster_formats/0` because ImageMagick, left to choose,
  can read it with its own renderer (MSVG) or an external delegate. Here the decoder
  is pinned to `rsvg:` (librsvg, linked into ImageMagick), never `svg:` or `msvg:`,
  and only after the bytes sniff as SVG. librsvg runs no scripts, fetches nothing
  from the network, and loads a referenced file only from the SVG's own folder or
  below. So the SVG is copied alone into a fresh private folder and rendered there:
  there is nothing beside it to reference. Every call carries `ImageProcessor`'s
  resource limits (memory, pixel area, time).

  The picture is drawn with its longest side `long_side` pixels (4096 by default) on
  a transparent background: a vector has no size of its own, and that is enough for
  every rendition.
  """

  alias PhoenixKit.Modules.Storage.{ImageProcessor, Sniff}

  @mime "image/svg+xml"
  @long_side 4096
  # librsvg's reference resolution: a document's user unit is a pixel at 96 dpi.
  @base_dpi 96

  @doc "Whether a file of this MIME type is drawn through here."
  @spec svg?(String.t() | nil) :: boolean()
  def svg?(mime) when is_binary(mime), do: String.downcase(mime) == @mime
  def svg?(_mime), do: false

  @doc """
  Draws the SVG at `svg_path` into a new PNG and returns its path. The caller
  removes it. `{:error, reason}` for a file that is not an SVG or does not render.
  """
  @spec to_png(Path.t(), pos_integer()) :: {:ok, Path.t()} | {:error, term()}
  def to_png(svg_path, long_side \\ @long_side) do
    dir = private_dir()
    source = Path.join(dir, "image.svg")
    png = Path.join(System.tmp_dir!(), "phoenix_kit_svg_#{token()}.png")

    try do
      with {:ok, %{format: :svg}} <- Sniff.sniff(svg_path),
           :ok <- File.cp(svg_path, source),
           {:ok, {w, h}} <- intrinsic_size(source),
           :ok <- render(source, png, density(w, h, long_side), long_side) do
        {:ok, png}
      else
        {:ok, %{format: format}} ->
          {:error, {:not_svg, format}}

        :unknown ->
          {:error, {:not_svg, :unknown}}

        {:error, _} = error ->
          File.rm(png)
          error
      end
    after
      File.rm_rf(dir)
    end
  end

  defp intrinsic_size(source) do
    case System.cmd(
           "magick",
           ["identify", "-quiet"] ++
             ImageProcessor.limit_args() ++ ["-format", "%w %h", "rsvg:" <> source],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        with [w, h] <- output |> String.trim() |> String.split(),
             {w, ""} when w > 0 <- Integer.parse(w),
             {h, ""} when h > 0 <- Integer.parse(h) do
          {:ok, {w, h}}
        else
          _ -> {:error, {:svg_size, output}}
        end

      {output, status} ->
        {:error, {:svg_size, status, output}}
    end
  end

  # The density that draws the longest side at `long_side` pixels.
  defp density(w, h, long_side), do: Float.round(@base_dpi * long_side / max(w, h), 4)

  defp render(source, png, density, long_side) do
    args =
      ["-quiet"] ++
        ImageProcessor.limit_args() ++
        [
          "-background",
          "none",
          "-density",
          :erlang.float_to_binary(density, decimals: 4),
          "rsvg:" <> source,
          # Rounding can leave a pixel over.
          "-resize",
          "#{long_side}x#{long_side}>",
          "png:" <> png
        ]

    case System.cmd("magick", args, stderr_to_stdout: true) do
      {_output, 0} -> if File.exists?(png), do: :ok, else: {:error, :svg_no_output}
      {output, status} -> {:error, {:svg_render, status, output}}
    end
  end

  defp private_dir do
    dir = Path.join(System.tmp_dir!(), "phoenix_kit_svg_#{token()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  defp token, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
