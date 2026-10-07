defmodule PhoenixKit.Modules.Storage.FocalPoint do
  @moduledoc """
  Where the subject of a photo is, so a rendition can crop around it.

  A **focal point** is `{x, y}`, fractions of the photo **as it is displayed**
  (after its EXIF orientation), `0.0..1.0` from the left and from the top. It is
  kept in the file's `metadata` JSON (`"focal"`: `x`, `y` and `source`), so it
  needs no column. A fixed rendition whose crop mode is `focus` (V210) crops a
  window of its shape centered on it (`ImageProcessor.resize_and_crop_focus/6`);
  every such rendition of the photo (a square thumbnail, a 4:3, a 16:9) uses the
  same point, and a photo with none is cropped at the center.

  ## Where it comes from

  * `"manual"`: set by a person (`put/4`); wins over everything and is never
    replaced by detection.
  * `"auto"`: found by `detect/1`, which asks libvips where the photo draws the
    eye (`smartcrop` with `attention`: edges, colour, skin tone) on a copy shrunk to
    #{512}px, which costs a few milliseconds. It needs the optional `vix`
    package; without it, or when detection fails, there is no point and the crop
    stays at the center.

  `ensure/2` is what the generator calls the first time a photo needs one: the
  stored point, else a detected one (stored for next time), else `nil`.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Dimension
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.RepoHelper

  require Logger

  # Hosts without the optional dependency must compile without warnings too.
  @compile {:no_warn_undefined, Vix.Vips.Image}
  @compile {:no_warn_undefined, Vix.Vips.Operation}

  # The long side of the copy detection looks at.
  @shrink_to 512
  # The same ceiling the ImageMagick calls keep: no decoding a decompression bomb.
  @max_pixels 40_000_000
  @sources ~w(auto manual)

  @type point :: {float(), float()}

  @doc "Whether detection is available (the optional `vix` package is loaded)."
  @spec detection_available?() :: boolean()
  def detection_available?, do: Code.ensure_loaded?(Vix.Vips.Operation)

  @doc """
  The focal point stored on `file` and where it came from, or `nil`:
  `{{x, y}, "auto" | "manual"}`.
  """
  @spec get(map()) :: {point(), String.t()} | nil
  def get(%{metadata: metadata}), do: from_metadata(metadata)
  def get(_file), do: nil

  defp from_metadata(%{"focal" => %{"x" => x, "y" => y} = focal})
       when is_number(x) and is_number(y) and x >= 0 and x <= 1 and y >= 0 and y <= 1 do
    {{x / 1, y / 1}, Map.get(focal, "source", "auto")}
  end

  defp from_metadata(_metadata), do: nil

  @doc """
  Records a focal point for `file`: `x` and `y` between 0 and 1, `source` `"auto"`
  or `"manual"`. A detected point never replaces a manual one (`{:ok, :kept}`).
  Only the `"focal"` key of the metadata changes. A change of point also
  invalidates generated subject crops and queues reconciliation.

  Detected points are accepted only while the file's checksum is unchanged.
  Pass `source_key:` when the bytes came from `Storage.retrieve_original/1`;
  that original must still belong to the file when the point is recorded.
  """
  @spec put(map(), number(), number(), String.t(), keyword()) ::
          {:ok, point()} | {:ok, :kept} | {:error, :invalid | :stale_source}
  def put(file, x, y, source, opts \\ [])

  def put(%{uuid: uuid} = file, x, y, source, opts)
      when is_number(x) and is_number(y) and x >= 0 and x <= 1 and y >= 0 and y <= 1 and
             source in @sources do
    focal = %{"x" => Float.round(x / 1, 4), "y" => Float.round(y / 1, 4), "source" => source}

    # `source = auto` writes only where no manual point is: one statement, so a
    # person's choice made while detection runs is not lost.
    query =
      if source == "manual" do
        from(f in StorageFile, where: f.uuid == ^uuid)
      else
        from(f in StorageFile,
          where:
            f.uuid == ^uuid and
              fragment("coalesce(?->'focal'->>'source', '') <> 'manual'", f.metadata)
        )
      end

    RepoHelper.repo().transaction(fn ->
      current =
        RepoHelper.repo().one(from(f in StorageFile, where: f.uuid == ^uuid, lock: "FOR UPDATE"))

      check_source!(file, current, source, Keyword.get(opts, :source_key))

      {count, _} =
        from(f in query,
          update: [
            set: [
              metadata:
                fragment(
                  "coalesce(?, '{}'::jsonb) || ?",
                  f.metadata,
                  type(^%{"focal" => focal}, :map)
                )
            ]
          ]
        )
        |> RepoHelper.repo().update_all([])

      point = {focal["x"], focal["y"]}

      if count == 1 do
        if point_from_file(current) != point, do: invalidate_crops(current)
        point
      else
        :kept
      end
    end)
  end

  def put(_file, _x, _y, _source, _opts), do: {:error, :invalid}

  defp check_source!(file, current, "auto", source_key) when not is_nil(current) do
    checksum_changed? =
      Map.has_key?(file, :file_checksum) and current.file_checksum != file.file_checksum

    original_changed? =
      not is_nil(source_key) and not Storage.original_key?(file.uuid, source_key)

    if checksum_changed? or original_changed?, do: RepoHelper.repo().rollback(:stale_source)
  end

  defp check_source!(_file, _current, _source, _source_key), do: :ok

  @doc "Forgets the stored focal point and requests regeneration of its subject crops."
  @spec clear(map()) :: :ok
  def clear(%{uuid: uuid}) do
    RepoHelper.repo().transaction(fn ->
      current =
        RepoHelper.repo().one(from(f in StorageFile, where: f.uuid == ^uuid, lock: "FOR UPDATE"))

      from(f in StorageFile,
        where: f.uuid == ^uuid,
        update: [set: [metadata: fragment("coalesce(?, '{}'::jsonb) - 'focal'", f.metadata)]]
      )
      |> RepoHelper.repo().update_all([])

      if point_from_file(current), do: invalidate_crops(current)
    end)

    :ok
  end

  defp point_from_file(file) do
    case get(file) do
      {point, _source} -> point
      nil -> nil
    end
  end

  # Changing the point changes the pixels without changing a rendition's spec.
  # Invalidate only generated focus crops (never an annotation with no spec).
  defp invalidate_crops(file) do
    names =
      file
      |> VariantGenerator.expected_variants()
      |> Enum.filter(fn {dimension, _name, _format} -> Dimension.focus_crop?(dimension) end)
      |> Enum.map(fn {_dimension, name, _format} -> name end)

    {count, _} =
      from(i in FileInstance,
        where: i.file_uuid == ^file.uuid and i.variant_name in ^names and not is_nil(i.spec_hash)
      )
      |> RepoHelper.repo().update_all(set: [spec_hash: "focal_changed"])

    if count > 0, do: VariantSets.record_variants(file, false, nil)
  end

  @doc """
  The focal point to crop `file` around, from its original at `local_path`: the
  stored one, else a detected one (stored, so the next rendition does not detect
  again), else `nil`. Never raises: a photo detection cannot read is cropped at
  the center.
  """
  @spec ensure(map(), Path.t(), keyword()) :: point() | nil
  def ensure(%{uuid: uuid} = file, local_path, opts \\ []) do
    # Read again: a person may have set one since `file` was loaded.
    stored =
      RepoHelper.repo().one(from(f in StorageFile, where: f.uuid == ^uuid, select: f.metadata))

    case from_metadata(stored) do
      {point, _source} ->
        point

      nil ->
        source_key =
          Keyword.get_lazy(opts, :source_key, fn ->
            case Storage.get_file_instance_by_name(uuid, "original") do
              %{file_name: key} -> key
              nil -> nil
            end
          end)

        detect_and_store(file, local_path, source_key)
    end
  rescue
    error ->
      Logger.warning("FocalPoint.ensure failed: #{Exception.message(error)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("FocalPoint.ensure failed: #{inspect(reason)}")
      nil
  end

  defp detect_and_store(file, local_path, source_key) do
    case detect(local_path) do
      {:ok, {x, y}} ->
        case put(file, x, y, "auto", source_key: source_key) do
          {:ok, {_x, _y} = point} -> point
          # A manual point appeared meanwhile.
          {:ok, :kept} -> get_stored(file)
          {:error, :stale_source} -> nil
          _ -> nil
        end

      :error ->
        nil
    end
  end

  defp get_stored(%{uuid: uuid}) do
    stored =
      RepoHelper.repo().one(from(f in StorageFile, where: f.uuid == ^uuid, select: f.metadata))

    case from_metadata(stored) do
      {point, _source} -> point
      nil -> nil
    end
  end

  @doc """
  Where the photo at `path` draws the eye, as `{:ok, {x, y}}` (fractions of the
  displayed photo), or `:error` when detection is unavailable or cannot read it.
  """
  @spec detect(Path.t()) :: {:ok, point()} | :error
  def detect(path) do
    if detection_available?(), do: run_detection(path), else: :error
  end

  defp run_detection(path) do
    with {:ok, {w, h}} <- ImageProcessor.extract_dimensions(path),
         true <- w * h <= @max_pixels do
      # A NIF call: bounded in time, and a failure is "no focal point".
      task = Task.async(fn -> safe_attention(path) end)

      case Task.yield(task, 10_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _timeout_or_exit -> :error
      end
    else
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # A linked task must catch decoder failures itself: rescuing in the caller
  # does not prevent a task's exception from exiting the caller too.
  #
  # A photo libvips cannot decode (an iPhone's HEIC: the precompiled library has
  # no HEVC decoder, which ImageMagick has) is not "no subject": it is looked at
  # again through a small JPEG preview ImageMagick makes of it.
  defp safe_attention(path) do
    case try_attention(path) do
      :unreadable -> from_preview(path)
      found -> found
    end
  end

  defp try_attention(path) do
    attention(path)
  rescue
    _ -> :unreadable
  catch
    _, _ -> :unreadable
  end

  defp from_preview(path) do
    preview =
      Path.join(
        System.tmp_dir!(),
        "phoenix_kit_focal_#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}.jpg"
      )

    try do
      with {:ok, _} <- ImageProcessor.preview_jpeg(path, preview, @shrink_to),
           found when found != :unreadable <- try_attention(preview) do
        Logger.info("FocalPoint: libvips could not decode a photo; used an ImageMagick preview")
        found
      else
        _ -> :error
      end
    after
      File.rm(preview)
    end
  end

  # Shrink on load (which also applies the EXIF orientation), then ask where the
  # attention is. The coordinates are on the shrunk copy, so they are divided by
  # its size.
  defp attention(path) do
    alias Vix.Vips.{Image, Operation}

    with {:ok, small} <- Operation.thumbnail(path, @shrink_to, size: :VIPS_SIZE_DOWN),
         width = Image.width(small),
         height = Image.height(small),
         true <- width > 1 and height > 1,
         {:ok, {_cropped, found}} <-
           Operation.smartcrop(small, max(div(width, 2), 1), max(div(height, 2), 1),
             interesting: :VIPS_INTERESTING_ATTENTION
           ) do
      found = Map.new(found)
      x = found[:"attention-x"]
      y = found[:"attention-y"]

      cond do
        not (is_number(x) and is_number(y)) -> :error
        # A photo with nothing that draws the eye (flat, or blank) is reported at
        # the corner: that is "nothing found", not a subject in the corner.
        x == 0 and y == 0 -> :error
        true -> {:ok, {clamp(x / width), clamp(y / height)}}
      end
    else
      # Too small to look at: nothing to find, and nothing a preview would change.
      false -> :error
      # libvips could not open or decode it.
      _ -> :unreadable
    end
  end

  defp clamp(value), do: value |> max(0.0) |> min(1.0) |> Kernel./(1)
end
