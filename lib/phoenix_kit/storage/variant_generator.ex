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
  - Images: ImageMagick or GraphicsMagick
  - Videos: FFmpeg

  """

  alias PhoenixKit.Storage
  alias PhoenixKit.Storage.FileInstance
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

    case should_generate_variants?(file) do
      false ->
        {:ok, []}

      true ->
        dimensions = get_dimensions_for_generation(file.file_type, specific_dimensions)

        if Enum.empty?(dimensions) do
          {:ok, []}
        else
          if async do
            task = Task.async(fn -> process_variants(file, dimensions) end)
            # 30 second timeout
            Task.await(task, 30_000)
          else
            process_variants(file, dimensions)
          end
        end
    end
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
    case retrieve_original_file(file) do
      {:ok, original_path} ->
        # Process the variant
        case process_variant(original_path, variant_path, file.mime_type, dimension) do
          {:ok, variant_path} ->
            # Calculate checksum and size
            checksum = calculate_file_checksum(variant_path)
            {:ok, stat} = File.stat(variant_path)
            size = stat.size

            # Get dimensions from processed file
            width = get_width_from_file(variant_path)
            height = get_height_from_file(variant_path)

            # Store the variant file in storage - use the same path structure as original!
            Logger.info(
              "Storing variant #{variant_name} to storage buckets at path: #{variant_storage_path}"
            )

            case Manager.store_file(variant_path,
                   generate_variants: false,
                   path_prefix: variant_storage_path
                 ) do
              {:ok, storage_info} ->
                Logger.info("Variant #{variant_name} stored successfully in buckets")
                # Clean up temp files
                File.rm(original_path)
                File.rm(variant_path)

                # Create file instance record with real data
                instance_attrs = %{
                  variant_name: variant_name,
                  file_name: variant_filename,
                  mime_type: variant_mime_type,
                  ext: variant_ext,
                  checksum: checksum,
                  size: size,
                  width: width,
                  height: height,
                  processing_status: "completed",
                  file_id: file.id
                }

                case Storage.create_file_instance(instance_attrs) do
                  {:ok, instance} ->
                    Logger.info("Variant #{variant_name} created successfully in database")
                    {:ok, instance}

                  {:error, changeset} ->
                    Logger.error(
                      "Variant #{variant_name} failed to create instance: #{inspect(changeset)}"
                    )

                    {:error, changeset}
                end

              {:error, reason} ->
                Logger.error("Variant #{variant_name} failed to store file: #{inspect(reason)}")
                # Clean up temp files
                File.rm(original_path)
                File.rm(variant_path)
                {:error, reason}
            end

          {:error, reason} ->
            # Clean up temp files
            File.rm(original_path)
            File.rm(variant_path)
            Logger.error("Variant #{variant_name} processing failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Variant #{variant_name} failed to retrieve original: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

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

  defp generate_variant_filename(original_filename, variant_name, format_override) do
    # Extract base name without extension
    base_name = Path.rootname(original_filename)

    # Determine format
    format = format_override || Path.extname(original_filename) |> String.trim_leading(".")

    "#{base_name}-#{variant_name}.#{format}"
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

    try do
      # Load image with Vix
      case Vix.Vips.Image.new_from_file(input_path) do
        {:ok, image} ->
          # Resize image based on dimension settings
          resized_image =
            case {dimension.width, dimension.height} do
              {w, h} when w != nil and h != nil ->
                # Both width and height specified - resize to fit within bounds
                Logger.info("Resizing to #{w}x#{h}")
                current_width = Vix.Vips.Image.width(image)
                current_height = Vix.Vips.Image.height(image)
                scale_by_width = w / current_width
                scale_by_height = h / current_height

                # Use smaller scale to fit both width and height (works for vertical and horizontal images)
                scale = min(scale_by_width, scale_by_height)
                {:ok, resized} = Vix.Vips.Operation.resize(image, scale)
                resized

              {w, nil} when w != nil ->
                # Only width specified - maintain aspect ratio
                Logger.info("Resizing to width #{w}")
                current_width = Vix.Vips.Image.width(image)
                scale = w / current_width
                {:ok, resized} = Vix.Vips.Operation.resize(image, scale)
                resized

              {nil, h} when h != nil ->
                # Only height specified - maintain aspect ratio
                Logger.info("Resizing to height #{h}")
                current_height = Vix.Vips.Image.height(image)
                scale = h / current_height
                {:ok, resized} = Vix.Vips.Operation.resize(image, scale)
                resized

              _ ->
                # No dimensions specified - use original size
                Logger.info("No dimensions specified, using original size")
                image
            end

          # Write resized image to output path
          case Vix.Vips.Image.write_to_file(resized_image, output_path) do
            :ok ->
              Logger.info("Successfully saved resized image to #{output_path}")
              {:ok, output_path}

            {:error, reason} ->
              {:error, "Failed to write resized image: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to load image: #{inspect(reason)}"}
      end
    rescue
      e ->
        {:error, "Image processing failed: #{inspect(e)}"}
    end
  end

  defp process_video_variant(input_path, output_path, _mime_type, dimension) do
    # Build FFmpeg command
    args = build_ffmpeg_args(input_path, output_path, dimension)

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        # Get video dimensions
        case get_video_dimensions(output_path) do
          {:ok, {width, height}} ->
            # Dimensions will be calculated later when creating instance
            {:ok, output_path}

          error ->
            error
        end

      {output, exit_code} ->
        {:error, "FFmpeg failed with exit code #{exit_code}: #{output}"}
    end
  end

  defp build_imagemagick_args(input_path, output_path, dimension) do
    args = [input_path]

    # Handle resizing
    args =
      case {dimension.width, dimension.height} do
        {width, height} when width != nil and height != nil ->
          # Both dimensions specified
          args ++ ["-resize", "#{width}x#{height}"]

        {width, nil} when width != nil ->
          # Only width specified, maintain aspect ratio
          args ++ ["-resize", "#{width}"]

        {nil, height} when height != nil ->
          # Only height specified, maintain aspect ratio
          args ++ ["-resize", "x#{height}"]

        _ ->
          # No dimensions, use original size
          args
      end

    # Handle quality
    args =
      if dimension.quality do
        quality = convert_image_quality(dimension.quality)
        args ++ ["-quality", quality]
      else
        args
      end

    # Handle thumbnail (square crop)
    args =
      if dimension.name == "thumbnail" do
        args ++ ["-thumbnail", "150x150^", "-gravity", "center", "-extent", "150x150"]
      else
        args
      end

    args ++ [output_path]
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

  defp convert_image_quality(quality) when is_integer(quality) do
    # ImageMagick uses 1-100 for quality
    Integer.to_string(quality)
  end

  defp convert_vix_quality(quality) when is_integer(quality) do
    # Vix uses Q value (1-100, lower = higher compression)
    quality
  end

  defp convert_video_quality(quality) when is_integer(quality) do
    # FFmpeg CRF uses 0-51 (lower = higher quality)
    # Map image quality (1-100) to CRF (51-0)
    crf = 51 - trunc(quality / 100 * 51)
    Integer.to_string(crf)
  end

  defp get_image_dimensions(image_path) do
    case Vix.Vips.Image.new_from_file(image_path) do
      {:ok, image} ->
        width = Vix.Vips.Image.width(image)
        height = Vix.Vips.Image.height(image)
        {width, height}

      {:error, reason} ->
        {:error, "Failed to identify image: #{inspect(reason)}"}
    end
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
            {String.to_integer(width), String.to_integer(height)}

          _ ->
            {:error, "Invalid dimension format"}
        end

      {output, exit_code} ->
        {:error, "Failed to probe video: #{output} (exit code: #{exit_code})"}
    end
  end

  defp update_instance_with_file_info(instance, file_path, {width, height}) do
    Storage.update_instance_with_file_info(instance, file_path, {width, height})
  end

  defp store_variant_file(variant_path, instance) do
    case Manager.store_file(variant_path, []) do
      {:ok, _storage_info} ->
        # Mark instance as completed
        Storage.update_instance_status(instance, "completed")
        {:ok, instance}

      {:error, reason} ->
        # Mark instance as failed
        Storage.update_instance_status(instance, "failed")
        {:error, reason}
    end
  end

  defp calculate_file_checksum(file_path) do
    file_path
    |> File.read!()
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
  end

  defp get_width_from_file(file_path) do
    case Vix.Vips.Image.new_from_file(file_path) do
      {:ok, image} ->
        Vix.Vips.Image.width(image)

      {:error, _} ->
        nil
    end
  end

  defp get_height_from_file(file_path) do
    case Vix.Vips.Image.new_from_file(file_path) do
      {:ok, image} ->
        Vix.Vips.Image.height(image)

      {:error, _} ->
        nil
    end
  end

  defp generate_temp_path(extension) do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_variant_#{random_name}.#{extension}")
  end
end
