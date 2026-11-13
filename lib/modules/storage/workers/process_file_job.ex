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
  alias PhoenixKit.Modules.Storage.CameraRaw
  alias PhoenixKit.Modules.Storage.CaptureDate
  alias PhoenixKit.Modules.Storage.DrawnSource
  alias PhoenixKit.Modules.Storage.Exif
  alias PhoenixKit.Modules.Storage.Hdr
  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKit.Modules.Storage.ManualLocation
  alias PhoenixKit.Modules.Storage.PdfProcessor
  alias PhoenixKit.Modules.Storage.ProbeCache
  alias PhoenixKit.Modules.Storage.VariantGenerator

  @doc """
  Process a file and generate variants.

  A file that is still `"processing"` when its last attempt fails is marked
  `"failed"`. Nothing else ever would: the upload left it `"processing"` and
  only a successful run flips it to `"active"`, so a file whose original
  cannot be read or whose metadata cannot be extracted sat there for good,
  showing as processing in every view. `"failed"` is a state the interface
  and the reconciler already know how to show and retry; a later successful
  run still makes the file `"active"`.
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_uuid" => file_uuid}} = job) do
    run(job)
  rescue
    error ->
      mark_failed_on_last_attempt(job, file_uuid)
      reraise error, __STACKTRACE__
  else
    {:error, _reason} = error ->
      mark_failed_on_last_attempt(job, file_uuid)
      error

    other ->
      other
  end

  defp run(%Oban.Job{args: %{"file_uuid" => file_uuid, "filename" => filename}}) do
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

  @doc """
  Reads a new file's size, capture date and EXIF from a copy of it the caller has on
  disk, and makes the file active with them, before this job has run.

  An upload's bytes are on the server's disk when it is stored, and the job starts by
  fetching them back from a bucket (for a video, all of it) to learn the same things.
  Called right after `Storage.store_file_in_buckets/7`, with the file that was
  stored, this lets a timeline give the file its place at once, as a file whose sizes
  are still being made, and says so (`Storage.broadcast_file_processed/1`). The job
  then runs as usual and reads the same again.

  Only a photo or a video that is still `"processing"`, and not one that has to be
  drawn first (camera raw, SVG): developing a raw file is the job's work. Returns `:ok`
  or `:skipped`; never raises.
  """
  @spec read_metadata(String.t(), Path.t()) :: :ok | :skipped
  def read_metadata(file_uuid, path) do
    with %Storage.File{status: "processing"} = file <- Storage.get_file(file_uuid),
         %{file_name: source} <- Storage.get_file_instance_by_name(file.uuid, "original"),
         {:ok, metadata} <- local_metadata(file, path),
         true <- is_integer(metadata[:width]) and is_integer(metadata[:height]),
         :ok <- update_file_with_metadata(file, source, metadata) do
      Storage.broadcast_file_processed(file.uuid)
      :ok
    else
      _ -> :skipped
    end
  rescue
    error ->
      Logger.warning("ProcessFileJob: read_metadata failed: #{Exception.message(error)}")
      :skipped
  end

  defp local_metadata(%{file_type: "image"} = file, path) do
    if DrawnSource.drawn?(file.mime_type) do
      :skipped
    else
      ProbeCache.run(fn ->
        warm_probes(path, path)
        image_metadata(file, path, path)
      end)
    end
  end

  defp local_metadata(%{file_type: "video"} = file, path), do: video_metadata(file, path)
  defp local_metadata(_file, _path), do: :skipped

  # What is read from a picture (`picture`; `tagged` is where its EXIF is, the raw file
  # itself for a developed one) and from a video.
  defp image_metadata(file, tagged, picture) do
    with {:ok, metadata} <- extract_and_log_image_metadata(picture) do
      {:ok,
       metadata
       |> with_capture_date(tagged, file)
       |> with_exif(tagged, picture, file)
       |> with_animation(picture, file)}
    end
  end

  defp video_metadata(file, path) do
    with {:ok, metadata} <- extract_video_metadata(path),
         do: {:ok, with_capture_date(metadata, path, file)}
  end

  # A file this run made active is told to the page as soon as its metadata is in, so
  # it takes its place before its sizes are made. One that was active already (a
  # regeneration, or `read_metadata/2` got there first) has its place.
  defp announce_read(%{status: "processing", uuid: uuid}) do
    Storage.broadcast_file_processed(uuid)
    :ok
  end

  defp announce_read(_file), do: :ok

  defp mark_failed_on_last_attempt(%Oban.Job{attempt: attempt, max_attempts: max}, file_uuid)
       when attempt >= max do
    {count, _} =
      PhoenixKit.RepoHelper.repo().update_all(
        from(f in PhoenixKit.Modules.Storage.File,
          where: f.uuid == ^file_uuid and f.status == "processing"
        ),
        set: [status: "failed", updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
      )

    if count > 0 do
      Logger.error("ProcessFileJob: gave up on file_uuid=#{file_uuid}; marked it failed")
      Storage.broadcast_file_processed(file_uuid)
    end

    :ok
  end

  defp mark_failed_on_last_attempt(_job, _file_uuid), do: :ok

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

  # One `ProbeCache` for the whole of it: what reading the picture's metadata learns
  # about it (its size) is not asked again by each of its sizes.
  defp process_image(file), do: ProbeCache.run(fn -> read_and_make_image(file) end)

  defp read_and_make_image(file) do
    Logger.info("ProcessFileJob: process_image/1 called for file_uuid=#{file.uuid}")

    with {:ok, temp_path, source} <- retrieve_and_log_file(file.uuid),
         {:ok, picture} <- picture_of(file, temp_path) do
      with_temp_file([temp_path, picture], fn ->
        # A raw file's EXIF is in the raw file, not in the JPEG developed from it.
        tagged = if CameraRaw.mime?(file.mime_type), do: temp_path, else: picture
        warm_probes(picture, tagged)

        with {:ok, metadata} <- image_metadata(file, tagged, picture),
             :ok <- update_and_log_metadata(file, source, metadata),
             :ok <- announce_read(file),
             :ok <- log_dimensions_info() do
          generate_and_log_variants(file, {picture, source})
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

  # What the steps below ask of the picture one after another, and its sizes after
  # them, each a full decode: asked all at once here, so each step finds its answer
  # ready or on its way (`ProbeCache` hands a second asker the first one's answer).
  defp warm_probes(picture, tagged) do
    cache = ProbeCache.current()

    for probe <- [
          fn -> ImageProcessor.oriented_info(picture) end,
          fn -> ImageProcessor.extract_dimensions(picture) end,
          fn -> ImageProcessor.has_alpha_channel?(picture) end,
          fn -> Exif.read(tagged) end
        ] do
      Task.start(fn ->
        ProbeCache.adopt(cache)

        try do
          probe.()
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)
    end

    :ok
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

  # Every size is made from the copy this job already fetched (`source`), and the page
  # is told as soon as the small stills are stored: a photo or a video shows in a grid
  # then, while its large size or its video renditions are still being made.
  defp variant_opts(file, source) do
    [source: source, on_early: fn -> Storage.broadcast_file_processed(file.uuid) end]
  end

  defp generate_and_log_variants(file, source) do
    case VariantGenerator.generate_variants(file, variant_opts(file, source)) do
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
        with {:ok, metadata} <- video_metadata(file, temp_path),
             :ok <- update_file_with_metadata(file, source, metadata),
             :ok <- announce_read(file) do
          VariantGenerator.generate_variants(file, variant_opts(file, {temp_path, source}))
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
          generate_and_log_variants(file, {temp_path, source})
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
  defp with_temp_file(paths, fun) do
    fun.()
  after
    paths |> List.wrap() |> Enum.uniq() |> Enum.each(&File.rm/1)
  end

  # What an image's size and metadata are read from: the file itself, or a picture
  # drawn from it (`DrawnSource`: a PNG of an SVG, a JPEG developed from a raw file).
  defp picture_of(file, path) do
    case DrawnSource.picture(file.mime_type, path) do
      {:ok, picture} ->
        {:ok, picture}

      {:error, reason} = error ->
        File.rm(path)
        Logger.warning("ProcessFileJob: #{file.uuid} could not be drawn: #{inspect(reason)}")
        error
    end
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
  # An animated GIF or WebP records how many frames it has and how long it runs
  # (`metadata["animation"]`), which the file's storage page shows. A still picture
  # records nothing.
  defp with_animation(metadata, path, file) do
    ext = file.ext |> to_string() |> String.trim_leading(".") |> String.downcase()

    with true <- ext in ~w(gif webp),
         {:ok, %{frames: frames} = info} when frames > 1 <- ImageProcessor.animation_info(path) do
      Map.put(metadata, :animation, info)
    else
      _ -> metadata
    end
  end

  defp with_exif(metadata, _tagged, picture, %{original_file_uuid: backup})
       when is_binary(backup),
       do: Map.put(metadata, :hdr, Hdr.read(picture))

  defp with_exif(metadata, tagged, picture, _file) do
    metadata
    |> Map.merge(tagged |> Exif.read() |> Exif.file_attrs())
    |> Map.put(:hdr, Hdr.read(picture))
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
    |> put_parsed(:duration, kv["duration"], &parse_duration/1)
  end

  # Whole seconds, as the column keeps them. A clip of any length is at least 1: rounding a
  # clip shorter than half a second gave 0, which the file's changeset refuses (`greater than
  # 0`), and the whole update failed with it, leaving the file without its size, date or
  # previews. A length of 0 or less is not one, and is left out.
  defp parse_duration(value) do
    case Float.parse(value) do
      {seconds, rest} when seconds > 0 -> {max(round(seconds), 1), rest}
      {_none, _rest} -> :error
      :error -> :error
    end
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
  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp merge_exif(attrs, current) do
    {hdr, attrs} = Map.pop(attrs, :hdr)
    {exif, attrs} = Map.pop(attrs, :exif)
    {animation, attrs} = Map.pop(attrs, :animation)
    meta = current.metadata || %{}
    meta = if is_nil(hdr), do: meta, else: Map.put(meta, "hdr", hdr)
    meta = if is_nil(exif), do: meta, else: Map.put(meta, "exif", exif)
    meta = if is_nil(animation), do: meta, else: Map.put(meta, "animation", stringify(animation))

    if is_nil(hdr) and is_nil(exif) and is_nil(animation),
      do: attrs,
      else: Map.put(attrs, :metadata, meta)
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
          attrs
          |> CaptureDate.admit(current)
          |> ManualLocation.admit(current)
          |> merge_exif(current)
          |> then(&Storage.update_file(current, &1))
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
