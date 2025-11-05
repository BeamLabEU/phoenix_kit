defmodule PhoenixKit.Storage.ImageProcessor do
  @moduledoc """
  ImageMagick-based image processing module.

  Handles image operations using ImageMagick command-line tools:
  - `identify` - Extract image metadata (dimensions, format)
  - `convert`/`magick` - Resize and format conversion

  This replaces Vix with ImageMagick, which is more widely trusted
  and has better long-term support.
  """

  require Logger

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
    try do
      case System.cmd("identify", ["-format", "%wx%h", file_path], stderr_to_stdout: true) do
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

    try do
      # Extract current dimensions
      case extract_dimensions(input_path) do
        {:ok, {current_width, current_height}} ->
          # Calculate resize parameters
          resize_spec = calculate_resize_spec(current_width, current_height, width, height)

          # Build ImageMagick convert command
          args = build_convert_args(input_path, output_path, resize_spec, quality, format)

          Logger.info(
            "Resizing image: #{input_path} -> #{output_path}, resize spec: #{resize_spec}"
          )

          case System.cmd("convert", args, stderr_to_stdout: true) do
            {_output, 0} ->
              Logger.info("Successfully resized image to #{output_path}")
              {:ok, output_path}

            {output, exit_code} ->
              Logger.error("convert failed with exit code #{exit_code}: #{output}")
              {:error, "ImageMagick convert failed: #{output}"}
          end

        {:error, reason} ->
          {:error, "Failed to extract image dimensions: #{reason}"}
      end
    rescue
      e ->
        Logger.error("Image resize failed: #{inspect(e)}")
        {:error, "Image resize failed: #{inspect(e)}"}
    end
  end

  # Private functions

  defp calculate_resize_spec(current_width, current_height, target_width, target_height) do
    case {target_width, target_height} do
      {w, h} when w != nil and h != nil ->
        # Both width and height specified - fit within bounds preserving aspect ratio
        # Use ImageMagick's extent notation: scale to fit, then extend to exact size if needed
        # The '>' suffix means only shrink, never enlarge
        "#{w}x#{h}>"

      {w, nil} when w != nil ->
        # Only width specified - maintain aspect ratio
        "#{w}x"

      {nil, h} when h != nil ->
        # Only height specified - maintain aspect ratio
        "x#{h}"

      _ ->
        # No dimensions - return original size
        "#{current_width}x#{current_height}"
    end
  end

  defp build_convert_args(input_path, output_path, resize_spec, quality, format) do
    args = [input_path]

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
end
