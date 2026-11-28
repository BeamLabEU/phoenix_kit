defmodule PhoenixKit.Modules.Storage.WatermarkRenderer do
  @moduledoc """
  Draws a variant set's watermark (`PhoenixKit.Modules.Storage.Watermark`) on a
  rendition that has just been made, in place.

  It runs on the rendition, never on the original, through the same ImageMagick
  path as every other size: the decoder pinned to the sniffed format
  (`ImageProcessor.pinned_input/2`), the resource limits of every call
  (`ImageProcessor.limit_args/0`), and arguments passed as a list (no shell). The
  text goes to `label:` with ImageMagick's own escapes neutralised (`escape_text/1`:
  `%` escapes, a leading `@` that would read a file, backslashes), so a text can
  never read a file or a property. A picture over #{100} megapixels, or a logo over
  #{40}, is refused.

  `VariantGenerator` calls `render/3`; when it fails, the rendition is kept
  without the watermark and the error is logged: an upload never breaks on it.
  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Modules.Storage.Watermark

  @max_pixels 100_000_000
  @max_logo_pixels 40_000_000
  @min_strip 24

  @doc """
  Draws `watermark` on the picture at `path` and writes it back to `path`.

  Options:

    * `:quality` — the output quality (default 85);
    * `:logo_path` — a logo already on disk; without it the logo is read from
      `watermark.logo_file_uuid` (the stored file's original) and removed after,
      once `VariantSets.watermark_logo/1` allows it (an image anyone may see).

  Returns `{:ok, path}` or `{:error, reason}`; on an error `path` is untouched.
  """
  @spec render(String.t(), Watermark.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def render(path, %Watermark{} = watermark, opts \\ []) do
    text = Watermark.render_text(watermark)

    with_logo(watermark, opts, fn logo ->
      if text == "" and is_nil(logo) do
        {:error, :nothing_to_draw}
      else
        draw(path, watermark, text, logo, Keyword.get(opts, :quality, 85))
      end
    end)
  rescue
    e ->
      Logger.error("Watermark raised: #{Exception.message(e)}")
      {:error, :watermark_failed}
  end

  # The logo: the caller's file, or the stored file's original in a temp copy
  # removed afterwards. A logo that cannot be read is an error, not a text-only
  # watermark: the admin asked for the logo.
  defp with_logo(%Watermark{logo_file_uuid: nil}, opts, fun),
    do: fun.(Keyword.get(opts, :logo_path))

  defp with_logo(%Watermark{logo_file_uuid: uuid}, opts, fun) do
    case Keyword.get(opts, :logo_path) do
      path when is_binary(path) ->
        fun.(path)

      nil ->
        # Checked again here, not only when saved: the logo's file may have moved
        # to a private library, or its library been hidden, since.
        with {:ok, _file} <- logo_allowed(uuid) do
          case Storage.retrieve_original(uuid) do
            {:ok, path, %{file_type: "image"}, _instance} ->
              try do
                fun.(path)
              after
                File.rm(path)
              end

            {:ok, path, _file, _instance} ->
              File.rm(path)
              {:error, :logo_not_an_image}

            {:error, reason} ->
              {:error, {:logo_unavailable, reason}}
          end
        end
    end
  end

  defp logo_allowed(uuid) do
    case VariantSets.watermark_logo(uuid) do
      {:ok, file} -> {:ok, file}
      {:error, reason} -> {:error, {:logo_refused, reason}}
    end
  end

  defp draw(path, watermark, text, logo, quality) do
    out = Path.rootname(path) <> ".wm" <> Path.extname(path)
    format = path |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    with {:ok, input} <- ImageProcessor.pinned_input(path, "[0]"),
         {:ok, {width, height}} <- ImageProcessor.extract_dimensions(path),
         :ok <- budget(width * height, @max_pixels),
         {:ok, logo_input} <- logo_input(logo) do
      layers =
        case watermark.mode do
          "corner" -> corner_args(watermark, text, logo_input, width, height)
          _strip -> strip_args(watermark, text, logo_input, width, height)
        end

      args =
        ImageProcessor.limit_args() ++
          [input, "+repage"] ++
          layers ++ ["+repage", "-quality", Integer.to_string(quality), "#{format}:#{out}"]

      run_convert(args, out, path)
    end
  end

  @doc false
  # Runs `convert` (or the `cmd` given: a test's stand-in) to write `out`, then
  # moves `out` over `path`. `out` is removed on every path but the move itself:
  # a failed exit, a move that fails (convert can exit 0 without writing `out`,
  # or the disk is full) and anything that raises. After a move there is no
  # `out` left and the removal does nothing.
  def run_convert(args, out, path, cmd \\ &System.cmd/3) do
    case cmd.("convert", args, stderr_to_stdout: true) do
      {_output, 0} ->
        case File.rename(out, path) do
          :ok ->
            {:ok, path}

          {:error, reason} ->
            Logger.error("Watermark could not be moved into place: #{inspect(reason)}")
            {:error, :watermark_failed}
        end

      {output, code} ->
        Logger.error("Watermark failed (#{code}): #{String.slice(output, 0, 500)}")
        {:error, :watermark_failed}
    end
  after
    File.rm(out)
  end

  defp logo_input(nil), do: {:ok, nil}

  defp logo_input(logo) do
    with {:ok, input} <- ImageProcessor.pinned_input(logo, "[0]"),
         {:ok, {w, h}} <- ImageProcessor.extract_dimensions(logo),
         :ok <- budget(w * h, @max_logo_pixels) do
      {:ok, input}
    end
  end

  defp budget(pixels, max) when pixels <= max, do: :ok
  defp budget(_pixels, _max), do: {:error, :too_large}

  @doc false
  # The bar: `below` appends it under the picture (always opaque), `over` lays it
  # on the bottom of the picture. Logo on the left, text on the right, each fitted
  # into its half (the text into the whole width when there is no logo).
  def strip_args(watermark, text, logo, width, height) do
    over? = watermark.strip_position == "over"
    bar = max(@min_strip, round(width * watermark.strip_height_percent / 100))
    bar = if over?, do: min(bar, max(div(height, 3), 1)), else: bar
    pad = max(4, round(bar * 0.25))
    inner = max(bar - 2 * round(bar * 0.15), 1)
    half = max(div(width - 3 * pad, 2), 1)
    text_w = if logo, do: half, else: max(width - 2 * pad, 1)
    text_h = max(round(bar * 0.55), 8)
    alpha = if over?, do: watermark.background_opacity, else: 100

    logo_args =
      if logo,
        do:
          ["(", logo, "-resize", "#{half}x#{inner}", ")"] ++
            ["-gravity", "west", "-geometry", "+#{pad}+0", "-composite"],
        else: []

    text_args =
      if text != "",
        do:
          ["(", "-size", "#{text_w}x#{text_h}", "-background", "none"] ++
            [
              "-fill",
              watermark.text_color,
              "-gravity",
              "east",
              "label:" <> escape_text(text),
              ")"
            ] ++
            ["-gravity", "east", "-geometry", "+#{pad}+0", "-composite"],
        else: []

    bar_args =
      ["(", "-size", "#{width}x#{bar}", "xc:" <> rgba(watermark.background_color, alpha)] ++
        logo_args ++ text_args ++ [")"]

    if over?,
      do: bar_args ++ ["-gravity", "south", "-geometry", "+0+0", "-composite", "+gravity"],
      else: bar_args ++ ["+gravity", "-append"]
  end

  @doc false
  # The mark: the logo fitted into its share of the width (and half the height),
  # the text under it, made see-through by `opacity`, set `margin` from the corner.
  def corner_args(watermark, text, logo, width, height) do
    mark_w = max(16, round(width * watermark.mark_size_percent / 100))
    mark_h = max(div(height, 2), 1)
    text_h = max(10, round(mark_w / 6))
    margin = round(width * watermark.margin_percent / 100)

    parts =
      [
        logo && ["(", logo, "-resize", "#{mark_w}x#{mark_h}", ")"],
        text != "" &&
          ["(", "-size", "#{mark_w}x#{text_h}", "-background", "none"] ++
            ["-fill", watermark.text_color, "-gravity", "center", "label:" <> escape_text(text)] ++
            [")"]
      ]
      |> Enum.filter(& &1)

    joined =
      if length(parts) > 1, do: ["-background", "none", "-gravity", "center", "-append"], else: []

    factor = :erlang.float_to_binary(watermark.opacity / 100, decimals: 2)

    ["("] ++
      List.flatten(parts) ++
      joined ++
      ["-alpha", "set", "-channel", "A", "-evaluate", "multiply", factor, "+channel", ")"] ++
      ["-gravity", gravity(watermark.corner), "-geometry", "+#{margin}+#{margin}"] ++
      ["-composite", "+gravity"]
  end

  defp gravity("bottom_left"), do: "southwest"
  defp gravity("top_right"), do: "northeast"
  defp gravity("top_left"), do: "northwest"
  defp gravity(_bottom_right), do: "southeast"

  # `#rrggbb` (validated by the schema) with an alpha byte.
  defp rgba(color, opacity) do
    alpha = round(255 * opacity / 100)
    color <> String.pad_leading(Integer.to_string(alpha, 16), 2, "0")
  end

  @doc """
  The text as ImageMagick's `label:` reads it literally: a backslash and `%`
  doubled (no percent escape such as `%[fx:…]` or `%w` is expanded), a leading `@`
  escaped (it would read a file). Control characters are already gone
  (`Watermark.render_text/1`).
  """
  @spec escape_text(String.t()) :: String.t()
  def escape_text(text) do
    escaped = text |> String.replace("\\", "\\\\") |> String.replace("%", "%%")
    if String.starts_with?(escaped, "@"), do: "\\" <> escaped, else: escaped
  end
end
