defmodule PhoenixKit.Modules.Storage.ProcessFileJob do
  @moduledoc """
  Oban job for background processing of uploaded files.

  This job handles:
  - Generating file variants (thumbnails, resizes)
  - Extracting metadata (dimensions, duration)
  - Updating file status
  """
  use Oban.Worker, queue: :file_processing, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKit.Modules.Storage.VariantGenerator

  @doc """
  Process a file and generate variants.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"file_id" => file_id, "user_id" => _user_id, "filename" => filename} = _args
      }) do
    Logger.info("ProcessFileJob: EXECUTING for file_id=#{file_id}, filename=#{filename}")

    file = Storage.get_file(file_id)

    if is_nil(file) do
      Logger.error("ProcessFileJob: File not found for file_id=#{file_id}")
      {:error, :file_not_found}
    else
      Logger.info(
        "ProcessFileJob: Starting processing for file_id=#{file_id}, type=#{file.file_type}"
      )

      case process_file(file) do
        {:ok, variants} ->
          Logger.info(
            "ProcessFileJob: Successfully processed file_id=#{file_id}, generated=#{length(variants)} variants"
          )

          :ok

        {:error, reason} ->
          Logger.error(
            "ProcessFileJob: Failed to process file_id=#{file_id}, error=#{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  defp process_file(%PhoenixKit.Modules.Storage.File{} = file) do
    case file.file_type do
      "image" ->
        process_image(file)

      "video" ->
        process_video(file)

      "document" ->
        process_document(file)

      _ ->
        Logger.info("ProcessFileJob: Skipping processing for file type=#{file.file_type}")
        :ok
    end
  end

  defp process_image(file) do
    Logger.info("ProcessFileJob: process_image/1 called for file_id=#{file.id}")

    with {:ok, temp_path} <- retrieve_and_log_file(file.id),
         {:ok, metadata} <- extract_and_log_image_metadata(temp_path),
         :ok <- update_and_log_metadata(file, metadata),
         :ok <- log_dimensions_info(),
         {:ok, variants} <- generate_and_log_variants(file) do
      File.rm(temp_path)
      {:ok, variants}
    else
      {:error, reason} = error ->
        Logger.error("ProcessFileJob: Failed to process image: #{inspect(reason)}")
        error
    end
  end

  defp retrieve_and_log_file(file_id) do
    case Storage.retrieve_file(file_id) do
      {:ok, temp_path, _file} ->
        Logger.info("ProcessFileJob: Retrieved file to temp_path=#{temp_path}")
        {:ok, temp_path}

      error ->
        error
    end
  end

  defp extract_and_log_image_metadata(temp_path) do
    # extract_image_metadata always returns {:ok, metadata}
    {:ok, metadata} = extract_image_metadata(temp_path)
    Logger.info("ProcessFileJob: Extracted metadata=#{inspect(metadata)}")
    {:ok, metadata}
  end

  defp update_and_log_metadata(file, metadata) do
    case update_file_with_metadata(file, metadata) do
      :ok = success ->
        Logger.info("ProcessFileJob: Updated file with metadata")
        success

      error ->
        error
    end
  end

  defp log_dimensions_info do
    dimensions = Storage.list_dimensions_for_type("image")
    Logger.info("ProcessFileJob: Found #{length(dimensions)} dimensions for images")
    :ok
  end

  defp generate_and_log_variants(file) do
    case VariantGenerator.generate_variants(file) do
      {:ok, variants} = success ->
        Logger.info("ProcessFileJob: Generated #{length(variants)} variants successfully")
        success

      error ->
        error
    end
  end

  defp process_video(file) do
    with {:ok, temp_path, _file} <- Storage.retrieve_file(file.id),
         {:ok, metadata} <- extract_video_metadata(temp_path),
         :ok <- update_file_with_metadata(file, metadata) do
      # Generate variants
      case VariantGenerator.generate_variants(file) do
        {:ok, variants} ->
          File.rm(temp_path)
          {:ok, variants}

        {:error, reason} ->
          File.rm(temp_path)
          {:error, reason}
      end
    end
  end

  defp process_document(file) do
    with {:ok, temp_path, _file} <- Storage.retrieve_file(file.id),
         {:ok, metadata} <- extract_document_metadata(temp_path, file.mime_type),
         :ok <- update_file_with_metadata(file, metadata) do
      File.rm(temp_path)
      Logger.info("ProcessFileJob: Processed document file_id=#{file.id}")
      :ok
    end
  end

  defp extract_image_metadata(file_path) do
    case ImageProcessor.extract_dimensions(file_path) do
      {:ok, {width, height}} ->
        {
          :ok,
          %{
            width: width,
            height: height,
            format: "jpeg"
          }
        }

      {:error, reason} ->
        Logger.warning("Failed to extract image metadata: #{inspect(reason)}")
        {:ok, %{}}
    end
  end

  defp extract_video_metadata(file_path) do
    case System.cmd("ffprobe", [
           "-v",
           "error",
           "-select_streams",
           "v:0",
           "-show_entries",
           "stream=width,height,duration",
           "-of",
           "default=noprint_wrappers=1:nokey=1",
           file_path
         ]) do
      {output, 0} ->
        [width, height, duration] = String.split(String.trim(output), "\n")

        {
          :ok,
          %{
            width: String.to_integer(width),
            height: String.to_integer(height),
            duration: String.to_float(duration) |> round()
          }
        }

      {error, _} ->
        Logger.warning("Failed to extract video metadata: #{error}")
        {:ok, %{}}
    end
  end

  defp extract_document_metadata(_file_path, "application/pdf") do
    # For PDFs, we could extract page count, author, etc.
    # This is a simplified version
    {:ok, %{}}
  end

  defp extract_document_metadata(_file_path, _mime_type) do
    {:ok, %{}}
  end

  defp update_file_with_metadata(file, metadata) do
    attrs = Map.merge(%{status: "active"}, metadata)

    case Storage.update_file(file, attrs) do
      {:ok, _updated_file} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to update file metadata: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
