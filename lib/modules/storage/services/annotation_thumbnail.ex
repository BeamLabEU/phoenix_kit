defmodule PhoenixKit.Modules.Storage.AnnotationThumbnail do
  @moduledoc """
  Bakes Etcher annotation shapes into a single PNG thumbnail variant.

  A file with annotations gets one extra variant — `"thumbnail_annotated"` — a
  small square PNG with the shapes drawn on top (via ImageMagick `convert
  -draw`). The media browser grid uses it instead of the plain thumbnail, so the
  markup is visible without rendering shapes live for every viewer.

  It's a single deterministic variant slot: each regeneration overwrites it (no
  history piles up). When the last annotation is removed, the variant is dropped
  and the grid falls back to the plain thumbnail.

  Shapes are stored in image-pixel coordinates, so they're drawn at original
  scale on the original image (the geometry → draw mapping lives in
  `Etcher.Raster`, which owns the shape format), then the whole thing is resized
  + center-cropped to the thumbnail square — the crop clips edge shapes exactly
  like the grid.

  Regeneration is meant to run in the background (see `AnnotationThumbnailJob`),
  debounced so a flurry of edits collapses into one render.
  """

  # `Etcher.Raster` (the server-side shape renderer) ships in newer Etcher; tolerate
  # older versions at compile time and degrade gracefully at runtime.
  @compile {:no_warn_undefined, Etcher.Raster}

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage.ImageProcessor
  require Logger

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Settings

  @variant_name "thumbnail_annotated"
  # Square size of the baked thumbnail (px).
  @size 400
  # Media setting gating the whole feature (baking + display). Off by default.
  @setting_key "storage_annotated_thumbnails_enabled"

  @doc "The variant name this module produces."
  def variant_name, do: @variant_name

  @doc """
  The site-wide default for annotated thumbnails (media setting; default
  `false`). A library may choose otherwise (`enabled_for?/1`, which is what
  generation and display ask) — see the media settings page, "Media
  Configuration" section for this default and the Libraries tab for the
  per-library choice.
  """
  def enabled?, do: Settings.get_boolean_setting(@setting_key, false)

  @doc """
  Whether annotated thumbnails are on for a library: its own choice
  (`Libraries.setting/2`, per library) when it has made one, otherwise the site
  setting (`enabled?/0`). Takes a library or a library uuid (nil is Media).
  """
  @spec enabled_for?(term()) :: boolean()
  def enabled_for?(library) do
    case Libraries.setting(library, :annotated_thumbnails) do
      nil -> enabled?()
      own -> own
    end
  end

  @doc "`enabled_for?/1` for the library `file` is in."
  @spec enabled_for_file?(map()) :: boolean()
  def enabled_for_file?(%{library_uuid: library_uuid}), do: enabled_for?(library_uuid)

  @doc """
  `enabled_for?/1` for the library of the file with `file_uuid`. A file that is
  not there follows the site setting.
  """
  @spec enabled_for_file_uuid?(term()) :: boolean()
  def enabled_for_file_uuid?(file_uuid) do
    case Ecto.UUID.cast(file_uuid) do
      {:ok, uuid} ->
        library_uuid =
          PhoenixKit.RepoHelper.repo().one(
            from(f in Storage.File, where: f.uuid == ^uuid, select: f.library_uuid)
          )

        enabled_for?(library_uuid)

      :error ->
        enabled?()
    end
  end

  @doc """
  The libraries of `library_uuids` that have annotated thumbnails on, as a set
  of uuid strings (nil stands for Media) — one query for a page of files.
  """
  @spec enabled_among([term()]) :: MapSet.t(String.t())
  def enabled_among(library_uuids) do
    own = Libraries.setting_among(library_uuids, :annotated_thumbnails)
    default? = enabled?()

    library_uuids
    |> Enum.map(&to_string(&1 || Libraries.media_uuid()))
    |> Enum.uniq()
    |> Enum.filter(&Map.get(own, &1, default?))
    |> MapSet.new()
  end

  @doc """
  Regenerate (or remove) the baked annotated thumbnail for `file_uuid`.

  Returns `{:ok, instance}` when (re)generated, `{:ok, :removed}` when there's
  nothing to draw, or `{:error, reason}`.
  """
  def refresh(file_uuid) when is_binary(file_uuid) do
    case Storage.get_file(file_uuid) do
      %Storage.File{file_type: "image"} = file ->
        if enabled_for_file?(file) do
          annotations = Annotations.list_for_file(file_uuid)

          case draw_args(annotations, file) do
            [] ->
              remove_variant(file)
              {:ok, :removed}

            draw_args ->
              generate(file, draw_args)
          end
        else
          # Feature toggled off — drop any stale baked variant.
          remove_variant(file)
          {:ok, :removed}
        end

      _ ->
        # Non-image (or missing) file — nothing to annotate.
        {:ok, :removed}
    end
  rescue
    e ->
      Logger.warning("AnnotationThumbnail.refresh failed for #{file_uuid}: #{inspect(e)}")
      {:error, :exception}
  end

  defp generate(file, draw_args) do
    with {:ok, original_path, file, source} <- Storage.retrieve_original(file.uuid) do
      output = temp_png()

      # Both temp files go whatever the outcome — a failed convert used to
      # leave the downloaded original behind on every refresh.
      try do
        with :ok <- run_convert(original_path, output, draw_args) do
          # Drop any existing instance first so a fresh one is created with the new
          # checksum (create_variant_instance returns the existing row otherwise).
          remove_variant(file)

          VariantGenerator.store_prepared_variant(file, @variant_name, output, "png", "image/png",
            source_key: source.file_name
          )
        end
      after
        File.rm(original_path)
        File.rm(output)
      end
    end
    |> case do
      {:ok, _} = ok ->
        ok

      error ->
        Logger.warning("AnnotationThumbnail.generate failed for #{file.uuid}: #{inspect(error)}")
        {:error, :generate_failed}
    end
  end

  defp run_convert(input_path, output_path, draw_args) do
    # Decoder pinned to the sniffed raster format, with ImageProcessor's
    # resource limits, like every other ImageMagick call.
    case ImageProcessor.pinned_input(input_path) do
      {:ok, input} -> convert_pinned(input, output_path, draw_args)
      {:error, reason} -> {:error, reason}
    end
  end

  defp convert_pinned(input, output_path, draw_args) do
    # `draw_args` already carries `-fill none` + the per-shape `-stroke/-draw`
    # (from Etcher.Raster); we just splice it in before the resize/crop so shapes
    # are drawn in the source image's pixel space and scale with it.
    args =
      ImageProcessor.limit_args() ++
        [input] ++
        draw_args ++
        ["-resize", "#{@size}x#{@size}^", "-gravity", "center", "-extent", "#{@size}x#{@size}"] ++
        ["png:#{output_path}"]

    case System.cmd("convert", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, "convert exited #{code}: #{out}"}
    end
  end

  # Etcher owns the geometry → draw mapping. Convert our `Annotation` structs to
  # the generic wire shape and hand them to `Etcher.Raster`, supplying the render
  # policy (stroke width scaled to the source image so it survives the
  # down-scale). Degrades to no overlay when the installed Etcher predates the
  # server renderer.
  defp draw_args(annotations, file) do
    if Code.ensure_loaded?(Etcher.Raster) do
      {canvas_w, canvas_h} = canvas_size(file)

      annotations
      |> raster_annotations()
      |> Etcher.Raster.to_draw_args(
        stroke_width: max(round(max(canvas_w, canvas_h) / 200), 3),
        # Label sizes are stored against a reference canvas, like ink weights.
        # A Raster that scales them needs the picture's own size; these are
        # honoured from Etcher 0.17, which is the floor.
        canvas_width: canvas_w,
        canvas_height: canvas_h
      )
    else
      []
    end
  end

  @doc false
  # The wire shape `Etcher.Raster` actually reads. A label's words live in the
  # `title` column; Raster draws `metadata.title` (the same projection
  # `load_annotations_for/1` makes for the live overlay). A top-level `"title"`
  # key is ignored, which is why a named shape used to bake as an empty box.
  # The column wins over a stale metadata copy. Public so the unit test can
  # pin the projection Raster consumes.
  def raster_annotations(annotations) when is_list(annotations) do
    Enum.map(annotations, &raster_annotation/1)
  end

  defp raster_annotation(a) do
    metadata =
      case a.metadata do
        %{} = meta -> meta
        _ -> %{}
      end

    metadata =
      case a.title do
        title when is_binary(title) ->
          case String.trim(title) do
            "" -> metadata
            trimmed -> Map.put(metadata, "title", trimmed)
          end

        _ ->
          metadata
      end

    %{
      "kind" => a.kind,
      "geometry" => a.geometry,
      "style" => a.style,
      "metadata" => metadata
    }
  end

  defp canvas_size(file) do
    case {positive_dim(file.width), positive_dim(file.height)} do
      {w, h} when w > 0 and h > 0 ->
        {w, h}

      _ ->
        dim = base_dimension(file)
        {dim, dim}
    end
  end

  defp positive_dim(n) when is_integer(n) and n > 0, do: n
  defp positive_dim(n) when is_float(n) and n > 0, do: round(n)
  defp positive_dim(_), do: 0

  # ── helpers ──────────────────────────────────────────────────────────────

  defp remove_variant(file) do
    case Storage.get_file_instance_by_name(file.uuid, @variant_name) do
      %Storage.FileInstance{} = instance -> Storage.delete_file_instance(instance)
      _ -> :ok
    end
  end

  defp base_dimension(file) do
    max(file.width || 0, file.height || 0)
    |> case do
      0 -> 1000
      dim -> dim
    end
  end

  defp temp_png do
    name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "phoenix_kit_annotated_#{name}.png")
  end
end
