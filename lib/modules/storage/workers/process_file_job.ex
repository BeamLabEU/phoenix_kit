defmodule PhoenixKit.Modules.Storage.ProcessFileJob do
  @moduledoc """
  Oban job for background processing of uploaded files.

  This job handles:
  - Generating file variants (thumbnails, resizes)
  - Extracting metadata (dimensions, duration, and when an image or video was
    taken — see `PhoenixKit.Modules.Storage.CaptureDate`)
  - Updating file status

  Unique per `file_uuid` while still pending or running, because the job
  regenerates **every** variant of a file rather than one: a gallery page whose
  thumbnails do not exist yet asks `FileController` for a dozen variants at
  once, and without this each request would enqueue another full run of the
  same work. The key is the file, not the variant, for the same reason — the
  args carry no variant at all.

  `:completed` is deliberately NOT a unique state (same reasoning as
  `AnnotationThumbnailJob`): once a run finishes, a later request — a new
  dimension added to the kit, a replaced original, a run that failed to write
  an instance — must be able to enqueue again instead of being silently
  swallowed until the period lapses.
  """
  # Computed from the *installed* Oban so the list stays valid across versions:
  # `:suspended` exists in some releases and not others, and naming a state the
  # installed Oban does not know is a hard compile error in the host app.
  @unique_states Oban.Job.states() -- [:completed, :cancelled, :discarded]

  use Oban.Worker,
    queue: :file_processing,
    max_attempts: 3,
    unique: [period: 300, keys: [:file_uuid], states: @unique_states]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.CaptureDate
  alias PhoenixKit.Modules.Storage.Exif
  alias PhoenixKit.Modules.Storage.Hdr
  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKit.Modules.Storage.PdfProcessor
  alias PhoenixKit.Modules.Storage.VariantGenerator

  @doc """
  Process a file and generate variants.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"file_uuid" => file_uuid, "filename" => filename} = _args
      }) do
    Logger.info("ProcessFileJob: EXECUTING for file_uuid=#{file_uuid}, filename=#{filename}")

    file = Storage.get_file(file_uuid)

    if is_nil(file) do
      Logger.error("ProcessFileJob: File not found for file_uuid=#{file_uuid}")
      {:error, :file_not_found}
    else
      Logger.info(
        "ProcessFileJob: Starting processing for file_uuid=#{file_uuid}, type=#{file.file_type}"
      )

      # Broadcast on both outcomes — subscribers just reload the file row,
      # which now carries either the fresh dimensions/variants or the
      # failed status.
      case process_file(file) do
        {:ok, variants} ->
          Logger.info(
            "ProcessFileJob: Successfully processed file_uuid=#{file_uuid}, generated=#{length(variants)} variants"
          )

          Storage.broadcast_file_processed(file_uuid)
          :ok

        {:error, reason} ->
          Logger.error(
            "ProcessFileJob: Failed to process file_uuid=#{file_uuid}, error=#{inspect(reason)}"
          )

          Storage.broadcast_file_processed(file_uuid)
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
        {:ok, []}
    end
  end

  defp process_image(file) do
    Logger.info("ProcessFileJob: process_image/1 called for file_uuid=#{file.uuid}")

    with {:ok, temp_path, source} <- retrieve_and_log_file(file.uuid) do
      with_temp_file(temp_path, fn ->
        with {:ok, metadata} <- extract_and_log_image_metadata(temp_path),
             metadata = with_capture_date(metadata, temp_path, file),
             metadata = with_exif(metadata, temp_path, file),
             :ok <- update_and_log_metadata(file, source, metadata),
             :ok <- log_dimensions_info() do
          generate_and_log_variants(file)
        end
      end)
    end
    |> case do
      {:ok, variants} ->
        {:ok, variants}

      {:error, reason} = error ->
        Logger.error("ProcessFileJob: Failed to process image: #{inspect(reason)}")
        error
    end
  end

  defp retrieve_and_log_file(file_uuid) do
    case Storage.retrieve_original(file_uuid) do
      {:ok, temp_path, _file, instance} ->
        Logger.info("ProcessFileJob: Retrieved file to temp_path=#{temp_path}")
        {:ok, temp_path, instance.file_name}

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

  defp update_and_log_metadata(file, source, metadata) do
    case update_file_with_metadata(file, source, metadata) do
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
    with {:ok, temp_path, source} <- retrieve_and_log_file(file.uuid) do
      with_temp_file(temp_path, fn ->
        with {:ok, metadata} <- extract_video_metadata(temp_path),
             metadata = with_capture_date(metadata, temp_path, file),
             :ok <- update_file_with_metadata(file, source, metadata) do
          VariantGenerator.generate_variants(file)
        end
      end)
    end
  end

  defp process_document(file) do
    if file.mime_type == "application/pdf" do
      process_pdf(file)
    else
      process_plain_document(file)
    end
  end

  defp process_plain_document(file) do
    with {:ok, temp_path, source} <- retrieve_and_log_file(file.uuid) do
      with_temp_file(temp_path, fn ->
        with {:ok, metadata} <- extract_document_metadata(temp_path, file.mime_type),
             :ok <- update_file_with_metadata(file, source, metadata) do
          Logger.info("ProcessFileJob: Processed document file_uuid=#{file.uuid}")
          {:ok, []}
        end
      end)
    end
  end

  defp process_pdf(file) do
    with {:ok, temp_path, source} <- retrieve_and_log_file(file.uuid) do
      with_temp_file(temp_path, fn ->
        with {:ok, metadata} <- extract_pdf_metadata(temp_path),
             :ok <-
               update_and_log_metadata(
                 file,
                 source,
                 PdfProcessor.file_attrs(file.metadata, metadata)
               ) do
          generate_and_log_variants(file)
        end
      end)
    end
    |> case do
      {:ok, variants} ->
        {:ok, variants}

      {:error, reason} = error ->
        Logger.error("ProcessFileJob: Failed to process PDF: #{inspect(reason)}")
        error
    end
  end

  # Runs `fun` and removes the downloaded copy whatever the outcome. A failed
  # step used to leave it behind, and a file that can never be processed fails
  # on every attempt of every re-queued job.
  defp with_temp_file(temp_path, fun) do
    fun.()
  after
    File.rm(temp_path)
  end

  # When the image or video was taken, read from the same bytes as its
  # dimensions and recorded in the same guarded transaction. An edited image
  # is skipped: an edit keeps only the ICC profile, so its bytes carry no
  # EXIF, and reading them would find the file name or the upload time at
  # best. It keeps the date it was given before the edit, or is dated from its
  # unedited backup by `Storage.Workers.CaptureDateBackfillJob`.
  defp with_capture_date(metadata, _path, %{original_file_uuid: backup}) when is_binary(backup),
    do: metadata

  defp with_capture_date(metadata, path, file),
    do: Map.merge(metadata, CaptureDate.resolve(path, file))

  # The camera, exposure, dates and GPS position the photo's EXIF carries
  # (`Storage.Exif`), read from the same bytes and recorded in the same guarded
  # transaction. An edited image is skipped for the reason above: it carries no
  # EXIF, and `Storage.read_exif/1` reads its unedited backup's.
  defp with_exif(metadata, _path, %{original_file_uuid: backup}) when is_binary(backup),
    do: metadata

  defp with_exif(metadata, path, _file) do
    metadata
    |> Map.merge(path |> Exif.read() |> Exif.file_attrs())
    |> Map.put(:hdr, Hdr.read(path))
  end

  defp extract_pdf_metadata(temp_path) do
    {:ok, metadata} = PdfProcessor.extract_metadata(temp_path)
    Logger.info("ProcessFileJob: Extracted PDF metadata=#{inspect(metadata)}")
    {:ok, metadata}
  end

  # The dimensions as displayed: after the EXIF orientation, which browsers,
  # the tile generator and image edits all apply. A phone photo stored
  # sideways is recorded upright.
  defp extract_image_metadata(file_path) do
    case ImageProcessor.oriented_info(file_path) do
      {:ok, {width, height, _frames}} ->
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

  # ffprobe omits absent entries and prints `N/A` for unknown ones — WebM /
  # Matroska carry duration on the format, not the stream — so parse
  # key=value lines defensively instead of positionally.
  defp parse_ffprobe_output(output) do
    kv =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> Map.put_new(acc, String.trim(key), String.trim(value))
          _ -> acc
        end
      end)

    %{}
    |> put_parsed(:width, kv["width"], &Integer.parse/1)
    |> put_parsed(:height, kv["height"], &Integer.parse/1)
    |> put_parsed(:duration, kv["duration"], fn v ->
      case Float.parse(v) do
        {f, rest} -> {round(f), rest}
        :error -> :error
      end
    end)
  end

  defp put_parsed(map, _key, nil, _parser), do: map

  defp put_parsed(map, key, value, parser) do
    case parser.(value) do
      {parsed, _rest} -> Map.put(map, key, parsed)
      :error -> map
    end
  end

  defp extract_video_metadata(file_path) do
    case System.cmd("ffprobe", [
           "-v",
           "error",
           "-select_streams",
           "v:0",
           "-show_entries",
           "stream=width,height,duration:format=duration",
           "-of",
           "default=noprint_wrappers=1",
           file_path
         ]) do
      {output, 0} ->
        {:ok, parse_ffprobe_output(output)}

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

  # The EXIF summary joins the row's `metadata` rather than replacing it: the
  # rotation and tags in there are not this run's to touch.
  defp merge_exif(attrs, current) do
    {hdr, attrs} = Map.pop(attrs, :hdr)

    case Map.pop(attrs, :exif) do
      {nil, attrs} ->
        attrs

      {exif, attrs} ->
        meta = Map.merge(current.metadata || %{}, %{"exif" => exif, "hdr" => hdr || %{}})
        Map.put(attrs, :metadata, meta)
    end
  end

  # The metadata describes the original this run downloaded (`source`, its
  # key). An image edit can swap that original meanwhile; writing the old
  # dimensions over the edited file's would be wrong, so the update only
  # happens while `source` is still the file's original (keys are
  # content-addressed: the same key is the same bytes). A capture date is
  # dropped from the update when it would replace a stronger one
  # (`CaptureDate.admit/2`) — a re-run must never downgrade an EXIF date to a
  # file name, nor touch a manual one.
  @doc false
  def update_file_with_metadata(file, source, metadata) do
    attrs = Map.merge(%{status: "active"}, metadata)
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
      current =
        repo.one(
          from(f in PhoenixKit.Modules.Storage.File,
            where: f.uuid == ^file.uuid,
            lock: "FOR UPDATE"
          )
        )

      cond do
        is_nil(current) ->
          :gone

        not Storage.original_key?(file.uuid, source) ->
          :changed

        true ->
          Storage.update_file(current, merge_exif(CaptureDate.admit(attrs, current), current))
      end
    end)
    |> case do
      {:ok, {:ok, _updated_file}} ->
        :ok

      {:ok, :changed} ->
        Logger.info("ProcessFileJob: #{file.uuid} changed while processing; metadata left as is")
        :ok

      {:ok, :gone} ->
        {:error, :file_not_found}

      {:ok, {:error, reason}} ->
        Logger.error("Failed to update file metadata: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
