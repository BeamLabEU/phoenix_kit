defmodule PhoenixKit.Modules.Storage.ImageProcessor do
  @moduledoc """
  ImageMagick-based image processing module.

  Handles image operations using ImageMagick command-line tools:
  - `identify` - Extract image metadata (dimensions, format)
  - `convert`/`magick` - Resize and format conversion

  This replaces Vix with ImageMagick, which is more widely trusted
  and has better long-term support.
  """

  require Logger

  alias PhoenixKit.Modules.Storage.ImageEdit
  alias PhoenixKit.Modules.Storage.Sniff

  # Resource ceilings on EVERY ImageMagick call, applied here rather than
  # trusted to the host's policy.xml: a decompression bomb is a small file
  # that decodes to gigabytes, and "the sysadmin configured ImageMagick" is
  # not a control this code can rely on.
  @limit_args [
    "-limit",
    "memory",
    "256MiB",
    "-limit",
    "map",
    "512MiB",
    "-limit",
    "disk",
    "1GiB",
    "-limit",
    "area",
    "128MP",
    "-limit",
    "width",
    "16KP",
    "-limit",
    "height",
    "16KP",
    "-limit",
    "time",
    "60"
  ]

  # 100 megapixels for resizing (variants): above any real camera, and the
  # header is read and refused before the decoder starts.
  @resize_max_pixels 100_000_000

  @doc """
  Get the width of an image file using ImageMagick identify.

  Returns the width in pixels or nil if extraction fails.
  """
  def get_width(file_path) do
    case extract_dimensions(file_path) do
      {:ok, {width, _height}} -> width
      {:error, _reason} -> nil
    end
  end

  @doc """
  Get the height of an image file using ImageMagick identify.

  Returns the height in pixels or nil if extraction fails.
  """
  def get_height(file_path) do
    case extract_dimensions(file_path) do
      {:ok, {_width, height}} -> height
      {:error, _reason} -> nil
    end
  end

  @doc """
  Extract both width and height from an image file.

  Uses ImageMagick's `identify` command to extract image dimensions.

  Returns:
  - `{:ok, {width, height}}` - Dimensions in pixels
  - `{:error, reason}` - If extraction fails
  """
  def extract_dimensions(file_path) do
    with {:ok, input} <- pinned_input(file_path, "[0]") do
      identify_dimensions(input)
    end
  end

  defp identify_dimensions(input) do
    case System.cmd("identify", @limit_args ++ ["-format", "%wx%h", input],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.split(String.trim(output), "x") do
          [width_str, height_str] ->
            case {Integer.parse(width_str), Integer.parse(height_str)} do
              {{width, ""}, {height, ""}} ->
                {:ok, {width, height}}

              _ ->
                {:error, "Failed to parse dimensions: #{output}"}
            end

          _ ->
            {:error, "Invalid dimension format: #{output}"}
        end

      {output, exit_code} ->
        {:error, "identify failed with exit code #{exit_code}: #{output}"}
    end
  rescue
    e ->
      {:error, "Failed to extract dimensions: #{inspect(e)}"}
  end

  @doc """
  Resize an image to fit within specified dimensions.

  Maintains aspect ratio by scaling to fit within bounds.
  Optionally converts format based on output_format parameter.

  Parameters:
  - `input_path` - Path to input image file
  - `output_path` - Path to save resized image
  - `width` - Target width (nil to use original)
  - `height` - Target height (nil to use original)
  - `opts` - Additional options
    - `:quality` - JPEG quality 1-100 (default: 85)
    - `:format` - Output format override (jpg, png, webp, etc)

  Returns:
  - `{:ok, output_path}` - Success
  - `{:error, reason}` - If resize fails
  """
  def resize(input_path, output_path, width, height, opts \\ []) do
    quality = Keyword.get(opts, :quality, 85)
    format = Keyword.get(opts, :format, nil)

    # Extract current dimensions (pinned and limited like every call here),
    # and refuse an oversized header before the decoder ever runs.
    with {:ok, input} <- pinned_input(input_path, frame_for(output_path, format)),
         {:ok, {current_width, current_height}} <- extract_dimensions(input_path),
         :ok <- check_pixel_budget(current_width, current_height, @resize_max_pixels) do
      # Calculate resize parameters
      resize_spec = calculate_resize_spec(current_width, current_height, width, height)

      # Build ImageMagick convert command
      args = @limit_args ++ build_convert_args(input, output_path, resize_spec, quality, format)

      Logger.info("Resizing image: #{input_path} -> #{output_path}, resize spec: #{resize_spec}")

      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("Successfully resized image to #{output_path}")
          {:ok, output_path}

        {output, exit_code} ->
          Logger.error("convert failed with exit code #{exit_code}: #{output}")
          {:error, "ImageMagick convert failed: #{output}"}
      end
    else
      {:error, reason} ->
        {:error, "Failed to read the image: #{reason}"}
    end
  rescue
    e ->
      Logger.error("Image resize failed: #{inspect(e)}")
      {:error, "Image resize failed: #{inspect(e)}"}
  end

  @doc """
  Resize and center-crop an image to exact dimensions.

  Zooms into the image to fill the target dimensions completely, then
  center-crops to extract the exact target size. No padding borders - the
  entire output is filled with the image content.

  This is ideal for thumbnails where you want perfect squares (e.g., 150x150)
  with the image zoomed in and centered, no white/black borders.

  The algorithm:
  1. Resizes image to fill the target box (scales to cover both dimensions)
  2. Centers the image using gravity
  3. Crops from center to exact target dimensions

  Parameters:
  - `input_path` - Path to input image file
  - `output_path` - Path to save cropped image
  - `width` - Target width (required)
  - `height` - Target height (required)
  - `opts` - Additional options
    - `:quality` - JPEG quality 1-100 (default: 85)
    - `:format` - Output format override (jpg, png, webp, etc)
    - `:background` - Background color (rarely used, default: "white")

  Returns:
  - `{:ok, output_path}` - Success
  - `{:error, reason}` - If processing fails
  """
  def resize_and_crop_center(input_path, output_path, width, height, opts \\ []) do
    quality = Keyword.get(opts, :quality, 85)
    format = Keyword.get(opts, :format, nil)
    alpha? = has_alpha_channel?(input_path)

    background =
      if Keyword.has_key?(opts, :background) do
        Keyword.get(opts, :background, "white")
      else
        if alpha?, do: "none", else: "white"
      end

    # (It used to switch a "jpg" of a see-through image to WebP here — while
    # the caller went on naming and recording the output as JPEG. The
    # variant generator now picks a transparent format itself; a direct
    # caller asking for JPEG gets a white background, never black.)
    with {:w, true} <- {:w, not (is_nil(width) or is_nil(height))},
         {:ok, input} <- pinned_input(input_path, frame_for(output_path, format)),
         {:ok, {cur_w, cur_h}} <- extract_dimensions(input_path),
         :ok <- check_pixel_budget(cur_w, cur_h, @resize_max_pixels) do
      # Never enlarge: a crop box bigger than the original shrinks, keeping
      # its shape, until it fits inside the original.
      {width, height} = cap_to_original({width, height}, {cur_w, cur_h})

      Logger.info(
        "Center-cropping image: #{input_path} -> #{output_path}, target: #{width}x#{height}"
      )

      # Build ImageMagick convert command for center-crop
      args =
        @limit_args ++
          build_center_crop_args(
            input,
            output_path,
            width,
            height,
            quality,
            format,
            background
          )

      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("Successfully center-cropped image to #{output_path}")
          {:ok, output_path}

        {output, exit_code} ->
          Logger.error("convert failed with exit code #{exit_code}: #{output}")
          {:error, "ImageMagick convert failed: #{output}"}
      end
    else
      {:w, false} -> {:error, "Both width and height are required for center-crop resizing"}
      {:error, reason} -> {:error, "Failed to read the image: #{reason}"}
    end
  rescue
    e ->
      Logger.error("Image center-crop failed: #{inspect(e)}")
      {:error, "Image center-crop failed: #{inspect(e)}"}
  end

  @doc """
  Crops an image to `width` x `height` around a focal point: the largest window
  of that shape that fits in the photo, centered on `{x, y}` (fractions of the
  photo as it is displayed, 0..1) as far as the edges allow, then scaled to the
  size. A subject near an edge stays in the frame where `resize_and_crop_center/5`
  would cut it off. Like it, never enlarges: a box bigger than the photo shrinks,
  keeping its shape.

  The photo is auto-oriented first, because the focal point is in displayed
  coordinates. Accepts the same `:quality`, `:format` and `:background` options.
  """
  def resize_and_crop_focus(input_path, output_path, width, height, focal, opts \\ []) do
    quality = Keyword.get(opts, :quality, 85)
    format = Keyword.get(opts, :format, nil)
    alpha? = has_alpha_channel?(input_path)

    background =
      if Keyword.has_key?(opts, :background),
        do: Keyword.get(opts, :background, "white"),
        else: if(alpha?, do: "none", else: "white")

    with {:w, true} <- {:w, not (is_nil(width) or is_nil(height))},
         {:ok, input} <- pinned_input(input_path, frame_for(output_path, format)),
         {:ok, {cur_w, cur_h, _frames}} <- oriented_info(input_path),
         :ok <- check_pixel_budget(cur_w, cur_h, @resize_max_pixels) do
      {width, height} = cap_to_original({width, height}, {cur_w, cur_h})
      window = focus_window(focal, {cur_w, cur_h}, {width, height})

      Logger.info(
        "Focus-cropping image: #{input_path} -> #{output_path}, target: #{width}x#{height}, window: #{inspect(window)}"
      )

      args =
        @limit_args ++
          build_focus_crop_args(
            input,
            output_path,
            window,
            {width, height},
            quality,
            format,
            background
          )

      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, output_path}

        {output, exit_code} ->
          Logger.error("convert failed with exit code #{exit_code}: #{output}")
          {:error, "ImageMagick convert failed: #{output}"}
      end
    else
      {:w, false} -> {:error, "Both width and height are required for focus-crop resizing"}
      {:error, reason} -> {:error, "Failed to read the image: #{reason}"}
    end
  rescue
    e ->
      Logger.error("Image focus-crop failed: #{inspect(e)}")
      {:error, "Image focus-crop failed: #{inspect(e)}"}
  end

  @doc false
  # The crop window `{crop_width, crop_height, left, top}` of the shape
  # `{width, height}` inside a `{cur_w, cur_h}` photo, centered on the focal point
  # where the edges allow and kept inside the photo where they do not.
  @spec focus_window(
          {number(), number()},
          {pos_integer(), pos_integer()},
          {pos_integer(), pos_integer()}
        ) :: {pos_integer(), pos_integer(), non_neg_integer(), non_neg_integer()}
  def focus_window({fx, fy}, {cur_w, cur_h}, {width, height}) do
    {crop_w, crop_h} =
      if cur_w * height >= cur_h * width do
        {min(max(round(cur_h * width / height), 1), cur_w), cur_h}
      else
        {cur_w, min(max(round(cur_w * height / width), 1), cur_h)}
      end

    left = round(fx * cur_w - crop_w / 2) |> max(0) |> min(cur_w - crop_w)
    top = round(fy * cur_h - crop_h / 2) |> max(0) |> min(cur_h - crop_h)

    {crop_w, crop_h, left, top}
  end

  defp build_focus_crop_args(
         input_path,
         output_path,
         {crop_w, crop_h, left, top},
         {width, height},
         quality,
         format,
         background
       ) do
    # The window is cut from the oriented photo at full resolution, then scaled to
    # the exact size: it has the target's shape, so `!` only absorbs rounding.
    args = [input_path, "-auto-orient", "-background", background]

    args =
      if format in ["jpg", "jpeg"],
        do: args ++ ["-alpha", "remove", "-alpha", "off"],
        else: args

    args =
      args ++
        [
          "-crop",
          "#{crop_w}x#{crop_h}+#{left}+#{top}",
          "+repage",
          "-resize",
          "#{width}x#{height}!",
          "-quality",
          to_string(quality)
        ]

    if format, do: args ++ ["#{format}:#{output_path}"], else: args ++ [output_path]
  end

  # 40 megapixels — comfortably above any real camera or screenshot, far
  # below what it takes to hurt. `-resize` bounds the OUTPUT; the decoder
  # still rasterizes the input in full first, so a 5MB PNG declaring
  # 50000x50000 is ~10GB of RAM before a single pixel is written. The
  # `-limit` flags turn that into a failure rather than an outage, but
  # reading the header and refusing costs nothing and never starts it.
  @sanitize_max_pixels 40_000_000

  defp check_pixel_budget(width, height, max_pixels)
       when is_integer(width) and is_integer(height) and width * height > max_pixels,
       do: {:error, "image is too large"}

  defp check_pixel_budget(_width, _height, _max_pixels), do: :ok

  @doc """
  Re-encodes an image to known-good bytes, discarding everything else.

  For uploads from people you do not trust. The point is not to *inspect*
  the file — that is a losing game — but to stop serving the uploader's
  bytes at all: what ends up stored is this encoder's output, produced by
  decoding the input and writing a fresh image. A polyglot file (valid
  GIF, valid JavaScript), an EXIF payload, a trailing ZIP, an embedded
  colour profile — none of them survive being decoded to pixels and
  written out again.

  Also enforces a maximum edge length, because a 30000×30000 PNG is a
  decompression bomb whatever its byte size, and rejects anything
  ImageMagick cannot read as an image regardless of what the upload
  claimed to be.

  Returns `{:ok, output_path}` or `{:error, reason}`. Never raises.

  ## ⚠️ Nothing in core calls this yet

  It is a primitive, not a policy: no upload path in PhoenixKit routes
  through it, so adding it did not change what any existing endpoint
  stores. A caller that accepts untrusted uploads — a public portal
  submission, an avatar from an unauthenticated form — has to invoke it
  itself and store the OUTPUT path, discarding the original. Wiring it
  into `Storage.upload/*` wholesale is not a drop-in: it re-encodes, which
  is right for images from strangers and wrong for a designer uploading a
  master PNG they expect back byte-for-byte.

  ## Options

    * `:max_edge` — longest side in pixels (default 2500); larger images
      are scaled down, never up
    * `:quality` — output quality (default 82)
    * `:format` — output format (default "jpeg"; use "png" to keep
      transparency)

  ## Example

      ImageProcessor.sanitize(upload.path, dest, format: "png")
  """
  @spec sanitize(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def sanitize(input_path, output_path, opts \\ []) do
    max_edge = Keyword.get(opts, :max_edge, 2500)
    quality = Keyword.get(opts, :quality, 82)
    format = Keyword.get(opts, :format, "jpeg")

    max_pixels = Keyword.get(opts, :max_pixels, @sanitize_max_pixels)

    with {:ok, {width, height}} <- extract_dimensions(input_path),
         :ok <- check_pixel_budget(width, height, max_pixels),
         {:ok, detected} <- detect_format(input_path) do
      args =
        [
          # Resource ceilings, applied HERE rather than trusted to the
          # host's policy.xml. A decompression bomb is a small file that
          # decodes to gigabytes, and "the sysadmin configured ImageMagick
          # correctly" is not a control this code can rely on.
          "-limit",
          "memory",
          "256MiB",
          "-limit",
          "map",
          "512MiB",
          "-limit",
          "disk",
          "1GiB",
          "-limit",
          "area",
          "128MP",
          "-limit",
          "width",
          "16KP",
          "-limit",
          "height",
          "16KP",
          "-limit",
          "time",
          "20"
        ] ++
          [
            # `[0]` takes the FIRST frame only: without it a multi-frame
            # GIF writes N output files, which is a cheap way to burn disk.
            # The format prefix pins how the bytes are decoded, so a file
            # can never be interpreted as a coder we did not allow.
            "#{detected}:#{input_path}[0]",
            "-auto-orient",
            # Strip metadata before anything else: EXIF, IPTC, XMP, colour
            # profiles, comments. GPS coordinates in a bug report screenshot
            # are a privacy leak the reporter did not intend.
            "-strip",
            "-alpha",
            if(format == "png", do: "on", else: "remove"),
            "-resize",
            "#{max_edge}x#{max_edge}>",
            "-quality",
            Integer.to_string(quality),
            "#{format}:#{output_path}"
          ]

      Logger.info(
        "Sanitizing #{detected} upload #{input_path} (#{width}x#{height}) -> #{output_path}"
      )

      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_output, 0} ->
          {:ok, output_path}

        {output, exit_code} ->
          Logger.warning("Upload sanitize failed (#{exit_code}): #{output}")
          {:error, "could not process image"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Upload sanitize raised: #{Exception.message(e)}")
      {:error, "could not process image"}
  end

  # Private functions

  @doc false
  @spec limit_args() :: [String.t()]
  def limit_args, do: @limit_args

  @doc false
  # The input spec for ImageMagick with the decoder pinned to the SNIFFED
  # raster format — `"png:/tmp/x"` — so a file is only ever decoded by the
  # coder its bytes say it is, never one chosen from its name or picked by
  # ImageMagick's own guessing (SVG, MVG, MSL, PostScript and friends are
  # never reached). `frame` is appended as is (`"[0]"`).
  @spec pinned_input(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def pinned_input(path, frame \\ "") do
    with {:ok, %{format: format}} <- Sniff.sniff(path),
         coder when is_binary(coder) <- Sniff.magick_coder(format) do
      {:ok, "#{coder}:#{path}#{frame}"}
    else
      _ -> {:error, "unsupported image format"}
    end
  end

  # An animated source (GIF, WebP) resized to a format that holds one picture
  # makes ImageMagick write one file per frame — `out-0.png`, `out-1.png` —
  # and never the `out.png` asked for. Those targets take frame 0; a GIF or
  # WebP target is left whole, so an animation stays one.
  @doc false
  @spec frame_for(String.t(), String.t() | nil) :: String.t()
  def frame_for(output_path, format) do
    target = format || output_path |> Path.extname() |> String.trim_leading(".")
    if String.downcase(target) in ["gif", "webp"], do: "", else: "[0]"
  end

  # What ImageMagick actually thinks this is, checked against a short
  # allowlist. The extension and the browser's content-type are both the
  # uploader's claims; this is the only reading that counts, and it does
  # not depend on the host having configured policy.xml.
  @sanitize_formats ~w(PNG JPEG JPG WEBP GIF)

  @doc """
  The size of the first frame after EXIF auto-orientation — the frame an
  edit's percentages refer to — and the number of frames in the file.

  Returns `{:ok, {width, height, frames}}` or `{:error, reason}`.
  """
  @spec oriented_info(String.t()) ::
          {:ok, {pos_integer(), pos_integer(), pos_integer()}} | {:error, String.t()}
  def oriented_info(file_path) do
    with {:ok, input} <- pinned_input(file_path, "[0]"),
         {:ok, frames} <- frame_count(file_path),
         {output, 0} <-
           System.cmd(
             "convert",
             @limit_args ++ [input, "-auto-orient", "-format", "%w %h", "info:"],
             stderr_to_stdout: true
           ),
         [w, h] <- output |> last_line() |> String.split(),
         {w, ""} <- Integer.parse(w),
         {h, ""} <- Integer.parse(h) do
      {:ok, {w, h, frames}}
    else
      {:error, _} = error -> error
      {output, _status} when is_binary(output) -> {:error, String.trim(output)}
      _ -> {:error, "could not read the image size"}
    end
  end

  defp frame_count(file_path) do
    with {:ok, input} <- pinned_input(file_path) do
      count_frames(input)
    end
  end

  defp count_frames(input) do
    case System.cmd("identify", @limit_args ++ ["-format", "%n\\n", input],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case output
             |> String.split("\n", trim: true)
             |> List.first()
             |> to_string()
             |> Integer.parse() do
          {n, _} when n > 0 -> {:ok, n}
          _ -> {:error, "could not count frames"}
        end

      {output, _} ->
        {:error, String.trim(output)}
    end
  end

  # IM7's `convert` prints a deprecation warning before the answer.
  defp last_line(output),
    do: output |> String.split("\n", trim: true) |> List.last() |> to_string()

  @doc """
  Renders an image edit (`PhoenixKit.Modules.Storage.ImageEdit`) of the
  first frame of `input_path` into `output_path`. `size` is the input's size
  after auto-orientation (`oriented_info/1`).
  """
  @spec render_edit(String.t(), String.t(), map() | nil, {pos_integer(), pos_integer()}) ::
          :ok | {:error, String.t()}
  def render_edit(input_path, output_path, edit, size) do
    with {:ok, input} <- pinned_input(input_path) do
      run_edit(input, output_path, edit, size)
    end
  end

  defp run_edit(input, output_path, edit, size) do
    args = @limit_args ++ ImageEdit.magick_args(edit, size, input, output_path)

    case System.cmd("convert", args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_path), do: :ok, else: {:error, "no output was written"}

      {output, status} ->
        {:error, "ImageMagick exited with #{status}: #{String.trim(output)}"}
    end
  end

  # Pinned and limited like every other call: an unpinned `identify` lets a
  # path such as `xc:red` choose its own coder.
  defp detect_format(path) do
    with {:ok, input} <- pinned_input(path, "[0]") do
      identify_format(input)
    end
  end

  defp identify_format(input) do
    case System.cmd("identify", @limit_args ++ ["-format", "%m", input], stderr_to_stdout: true) do
      {output, 0} ->
        format = output |> String.trim() |> String.upcase()

        if format in @sanitize_formats,
          do: {:ok, format},
          else: {:error, "unsupported image format"}

      _ ->
        {:error, "not a readable image"}
    end
  rescue
    _ -> {:error, "not a readable image"}
  end

  defp calculate_resize_spec(current_width, current_height, target_width, target_height) do
    case {target_width, target_height} do
      {w, h} when w != nil and h != nil ->
        # Both width and height specified - fit within bounds preserving aspect ratio
        # Use ImageMagick's extent notation: scale to fit, then extend to exact size if needed
        # The '>' suffix means only shrink, never enlarge
        "#{w}x#{h}>"

      {w, nil} when w != nil ->
        # Only width specified - maintain aspect ratio; `>` never enlarges,
        # so a 1448px original is not blown up to a 1920px "large". The height is
        # as tall as the photo needs (a vertical panorama).
        "#{w}x>"

      {nil, h} when h != nil ->
        # Only height specified - maintain aspect ratio, never enlarge; the width
        # is as long as the photo needs (a horizontal panorama).
        "x#{h}>"

      _ ->
        # No dimensions - return original size
        "#{current_width}x#{current_height}"
    end
  end

  @doc false
  # Shrinks a crop box that is larger than the original, keeping its aspect
  # ratio, so the crop never upscales.
  @spec cap_to_original({pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}) ::
          {pos_integer(), pos_integer()}
  def cap_to_original({w, h}, {cur_w, cur_h}) do
    scale = Enum.min([cur_w / w, cur_h / h, 1.0])
    {max(round(w * scale), 1), max(round(h * scale), 1)}
  end

  defp build_convert_args(input_path, output_path, resize_spec, quality, format) do
    args = [input_path]

    # A format without transparency is flattened on white; left to
    # ImageMagick, a see-through PNG turned into a JPEG comes out black.
    args =
      if format in ["jpg", "jpeg"],
        do: args ++ ["-background", "white", "-alpha", "remove", "-alpha", "off"],
        else: args

    # Add resize operation
    args = args ++ ["-resize", resize_spec]

    # Add quality setting for JPEG (ImageMagick quality for lossy formats)
    args = args ++ ["-quality", to_string(quality)]

    # Add format conversion if specified
    args =
      if format do
        format_spec = "#{format}:#{output_path}"
        args ++ [format_spec]
      else
        args ++ [output_path]
      end

    args
  end

  defp build_center_crop_args(input_path, output_path, width, height, quality, format, background) do
    args = [input_path]

    # Set background color for padding/extension (rarely used with ^ resize)
    args = args ++ ["-background", background]

    # JPEG has no alpha: flatten onto that background, or ImageMagick's
    # JPEG writer shows the transparent pixels' (usually black) colour.
    args =
      if format in ["jpg", "jpeg"],
        do: args ++ ["-alpha", "remove", "-alpha", "off"],
        else: args

    # Resize to fill/cover the target dimensions (with the ^ flag)
    # The ^ flag means "resize to FILL the box" - scales up to ensure both dimensions
    # are at least the target size, creating overflow that gets cropped
    resize_spec = "#{width}x#{height}^"
    args = args ++ ["-resize", resize_spec]

    # Use gravity center to position image at center before cropping
    args = args ++ ["-gravity", "center"]

    # Crop to exact dimensions from the centered position
    args = args ++ ["-extent", "#{width}x#{height}"]

    # Add quality setting for JPEG (ImageMagick quality for lossy formats)
    args = args ++ ["-quality", to_string(quality)]

    # Add format conversion if specified
    args =
      if format do
        format_spec = "#{format}:#{output_path}"
        args ++ [format_spec]
      else
        args ++ [output_path]
      end

    args
  end

  @doc false
  def has_alpha_channel?(file_path) do
    with {:ok, input} <- pinned_input(file_path, "[0]"),
         {output, 0} <-
           System.cmd("identify", @limit_args ++ ["-format", "%[channels]", input],
             stderr_to_stdout: true
           ) do
      # `%[channels]` starts with a colour model that ends in `a` when there is
      # transparency: srgba, graya, cmyka. `gray` — a black-and-white photo —
      # merely contains the letter, which is why it is read from the end. Newer
      # ImageMagick (7.1.1) follows the model with a channel count ("graya 3.0",
      # "srgb  4.0"), so only the first word is the model.
      output |> String.split() |> List.first("") |> String.ends_with?("a")
    else
      _ -> false
    end
  rescue
    _ -> false
  end
end
