defmodule PhoenixKit.Storage.VariantGenerator do
  @moduledoc """
  Variant generation system for images and videos.

  This module handles the creation of different variants (thumbnails, resizes,
  quality adjustments) for uploaded files based on dimension configurations.

  ## Supported Operations

  ### Images
  - Resize to specific dimensions
  - Generate thumbnails (square crops)
  - Quality adjustments
  - Format conversion (JPEG, PNG, WebP)

  ### Videos
  - Quality variants (360p, 720p, 1080p)
  - Thumbnail extraction
  - Format conversion (MP4)

  ## Dependencies

  Requires external tools to be installed:
  - Images: ImageMagick (`convert` and `identify` commands)
  - Videos: FFmpeg

  """

  alias PhoenixKit.Storage
  alias PhoenixKit.Storage.ImageProcessor
  alias PhoenixKit.Storage.Manager

  require Logger

  @doc """
  Generates variants for a file based on enabled dimensions.

  ## Parameters

  - `file` - The file struct to generate variants for
  - `opts` - Options for variant generation

  ## Options

  - `:async` - Whether to generate variants asynchronously (default: true)
  - `:dimensions` - List of specific dimensions to generate (default: all enabled)

  ## Returns

  - `{:ok, variants}` - List of generated file instances
  - `{:error, reason}` - Error if generation fails
  """
  def generate_variants(file, opts \\ []) do
    async = Keyword.get(opts, :async, true)
    specific_dimensions = Keyword.get(opts, :dimensions, [])

    if should_generate_variants?(file) do
      dimensions = get_dimensions_for_generation(file.file_type, specific_dimensions)

      case dimensions do
        [] -> {:ok, []}
        _ -> run_variant_processing(file, dimensions, async)
      end
    else
      {:ok, []}
    end
  end

  defp run_variant_processing(file, dimensions, true) do
    task = Task.async(fn -> process_variants(file, dimensions) end)
    # 30 second timeout
    Task.await(task, 30_000)
  end

  defp run_variant_processing(file, dimensions, false) do
    process_variants(file, dimensions)
  end

  @doc """
  Generates a specific variant for a file.

  ## Parameters

  - `file` - The file struct
  - `dimension` - The dimension configuration

  ## Returns

  - `{:ok, file_instance}` - Generated variant
  - `{:error, reason}` - Error if generation fails
  """
  def generate_variant(file, dimension) do
    variant_name = dimension.name
    Logger.info("Generating variant: #{variant_name} for file: #{file.id}")

    # Generate variant filename using MD5 hash + variant name
    variant_ext = determine_variant_extension(file.ext, dimension.format)
    # Extract MD5 hash from file_path for naming
    [_, _, md5_hash | _] = String.split(file.file_path, "/")
    variant_filename = "#{md5_hash}_#{variant_name}.#{variant_ext}"
    variant_mime_type = determine_variant_mime_type(file.mime_type, dimension.format)

    # Build the variant storage path - SAME directory structure as original!
    # file.file_path is like: "01/ab/0123456789abcdef" (user_prefix/hash_prefix/md5_hash)
    # Full path structure: "{user_prefix}/{hash_prefix}/{md5_hash}/{variant_filename}"
    # Example: "01/ab/0123456789abcdef/image-thumbnail.jpg"
    [user_prefix, hash_prefix, md5_hash | _] = String.split(file.file_path, "/")
    variant_storage_path = "#{user_prefix}/#{hash_prefix}/#{md5_hash}/#{variant_filename}"

    # Generate temp path for processing
    variant_path = generate_temp_path(variant_ext)

    # Download original file to temp location
    with {:ok, original_path} <- retrieve_original_file(file),
         {:ok, variant_path} <-
           process_variant(original_path, variant_path, file.mime_type, dimension),
         {:ok, file_stats} <- get_variant_file_stats(variant_path),
         {:ok, _storage_info} <-
           store_variant_file(variant_path, variant_name, variant_storage_path),
         {:ok, instance} <-
           create_variant_instance(
             file,
             variant_name,
             variant_storage_path,
             variant_mime_type,
             variant_ext,
             file_stats
           ) do
      cleanup_temp_files([original_path, variant_path])
      Logger.info("Variant #{variant_name} created successfully in database")
      {:ok, instance}
    else
      {:error, reason} = error ->
        Logger.error("Variant #{variant_name} failed: #{inspect(reason)}")
        error
    end
  end

  # Private functions

  defp get_variant_file_stats(variant_path) do
    with {:ok, stat} <- File.stat(variant_path) do
      checksum = calculate_file_checksum(variant_path)
      width = get_width_from_file(variant_path)
      height = get_height_from_file(variant_path)
      {:ok, %{size: stat.size, checksum: checksum, width: width, height: height}}
    end
  end

  defp store_variant_file(variant_path, variant_name, storage_path) do
    Logger.info("Storing variant #{variant_name} to storage buckets at path: #{storage_path}")

    case Manager.store_file(variant_path, generate_variants: false, path_prefix: storage_path) do
      {:ok, _storage_info} = success ->
        Logger.info("Variant #{variant_name} stored successfully in buckets")
        success

      error ->
        error
    end
  end

  defp create_variant_instance(file, variant_name, storage_path, mime_type, ext, stats) do
    instance_attrs = %{
      variant_name: variant_name,
      file_name: storage_path,
      mime_type: mime_type,
      ext: ext,
      checksum: stats.checksum,
      size: stats.size,
      width: stats.width,
      height: stats.height,
      processing_status: "completed",
      file_id: file.id
    }

    Storage.create_file_instance(instance_attrs)
  end

  defp cleanup_temp_files(paths) do
    Enum.each(paths, &File.rm/1)
  end

  defp should_generate_variants?(file) do
    file.file_type in ["image", "video"] and
      Storage.get_auto_generate_variants()
  end

  defp get_dimensions_for_generation(file_type, specific_dimensions) do
    base_query = Storage.list_dimensions_for_type(file_type)

    dimensions =
      if Enum.empty?(specific_dimensions) do
        base_query
      else
        Enum.filter(base_query, &(&1.name in specific_dimensions))
      end

    # Filter out the "original" dimension as that's handled separately
    Enum.filter(dimensions, &(&1.name != "original"))
  end

  defp process_variants(file, dimensions) do
    results =
      dimensions
      |> Enum.map(&Task.async(fn -> generate_variant(file, &1) end))
      |> Task.await_many(30_000)

    # Separate successful and failed results
    {successful, failed} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    if Enum.empty?(successful) and not Enum.empty?(failed) do
      {:error, "All variant generations failed"}
    else
      variants = Enum.map(successful, fn {:ok, variant} -> variant end)
      {:ok, variants}
    end
  end

  defp determine_variant_mime_type(original_mime, format_override) do
    if format_override do
      case format_override do
        "jpg" -> "image/jpeg"
        "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "webp" -> "image/webp"
        "mp4" -> "video/mp4"
        _ -> original_mime
      end
    else
      original_mime
    end
  end

  defp determine_variant_extension(original_ext, format_override) do
    if format_override do
      # Return extension WITHOUT leading dot - generate_temp_path will add it
      if String.starts_with?(format_override, ".") do
        String.trim_leading(format_override, ".")
      else
        format_override
      end
    else
      # Return original extension without leading dot
      String.trim_leading(original_ext, ".")
    end
  end

  defp retrieve_original_file(file) do
    case Storage.retrieve_file(file.id) do
      {:ok, path, _file} -> {:ok, path}
      error -> error
    end
  end

  defp process_variant(original_path, variant_path, mime_type, dimension) do
    case String.starts_with?(mime_type, "image/") do
      true ->
        process_image_variant(original_path, variant_path, mime_type, dimension)

      false ->
        case String.starts_with?(mime_type, "video/") do
          true ->
            process_video_variant(original_path, variant_path, mime_type, dimension)

          false ->
            {:error, "Unsupported file type for variant generation"}
        end
    end
  end

  defp process_image_variant(input_path, output_path, _mime_type, dimension) do
    Logger.info(
      "process_image_variant: input=#{input_path} output=#{output_path} width=#{dimension.width} height=#{dimension.height}"
    )

    quality = dimension.quality || 85
    format = dimension.format

    # Use center-crop for dimensions with both width and height (e.g., thumbnails)
    # Use regular resize for dimensions with only one specified (maintains aspect ratio)
    case {dimension.width, dimension.height} do
      {w, h} when w != nil and h != nil ->
        # Both dimensions specified - use center-crop with gravity
        Logger.info("Using center-crop for #{dimension.name} (#{w}x#{h})")

        ImageProcessor.resize_and_crop_center(input_path, output_path, w, h,
          quality: quality,
          format: format,
          background: "white"
        )

      _ ->
        # Only one dimension specified - use regular resize to maintain aspect ratio
        ImageProcessor.resize(input_path, output_path, dimension.width, dimension.height,
          quality: quality,
          format: format
        )
    end
  end

  defp process_video_variant(input_path, output_path, _mime_type, dimension) do
    # Build FFmpeg command
    args = build_ffmpeg_args(input_path, output_path, dimension)

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        # Get video dimensions
        case get_video_dimensions(output_path) do
          {:ok, {_width, _height}} ->
            # Dimensions will be calculated later when creating instance
            {:ok, output_path}

          {:error, reason} ->
            {:error, reason}
        end

      {output, exit_code} ->
        {:error, "FFmpeg failed with exit code #{exit_code}: #{output}"}
    end
  end

  defp build_ffmpeg_args(input_path, output_path, dimension) do
    # -y to overwrite output file
    args = ["-i", input_path, "-y"]

    # Handle video quality variants
    args =
      case dimension.name do
        "360p" ->
          args ++ ["-vf", "scale=640:360", "-crf", "28"]

        "720p" ->
          args ++ ["-vf", "scale=1280:720", "-crf", "25"]

        "1080p" ->
          args ++ ["-vf", "scale=1920:1080", "-crf", "23"]

        "video_thumbnail" ->
          args ++ ["-ss", "00:00:01.000", "-vframes", "1", "-vf", "scale=640:360"]

        _ ->
          if dimension.width and dimension.height do
            args ++ ["-vf", "scale=#{dimension.width}:#{dimension.height}"]
          else
            args
          end
      end

    # Handle quality (override for specific variants)
    args =
      if dimension.quality and dimension.name not in ["360p", "720p", "1080p"] do
        quality = convert_video_quality(dimension.quality)
        args ++ ["-crf", quality]
      else
        args
      end

    args ++ [output_path]
  end

  defp convert_video_quality(quality) when is_integer(quality) do
    # FFmpeg CRF uses 0-51 (lower = higher quality)
    # Map image quality (1-100) to CRF (51-0)
    crf = 51 - trunc(quality / 100 * 51)
    Integer.to_string(crf)
  end

  defp get_video_dimensions(video_path) do
    case System.cmd("ffprobe", [
           "-v",
           "quiet",
           "-print_format",
           "csv=p=0",
           "-select_streams",
           "v:0",
           "-show_entries",
           "stream=width,height",
           video_path
         ]) do
      {dimensions, 0} ->
        case String.split(String.trim(dimensions), ",") do
          [width, height] ->
            {:ok, {String.to_integer(width), String.to_integer(height)}}

          _ ->
            {:error, "Invalid dimension format"}
        end

      {output, exit_code} ->
        {:error, "Failed to probe video: #{output} (exit code: #{exit_code})"}
    end
  end

  defp calculate_file_checksum(file_path) do
    file_path
    |> File.read!()
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
  end

  defp get_width_from_file(file_path) do
    ImageProcessor.get_width(file_path)
  end

  defp get_height_from_file(file_path) do
    ImageProcessor.get_height(file_path)
  end

  defp generate_temp_path(extension) do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_variant_#{random_name}.#{extension}")
  end
end
