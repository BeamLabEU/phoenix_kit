defmodule PhoenixKit.Modules.Storage.VariantSets do
  @moduledoc """
  Variant sets: which derived files a library's uploads get (V205). The admin
  calls a derived file a *rendition* and a set a *rendition profile*, like a
  storage profile (Settings → Media → Rendition profiles).

  A library points at a set (`PhoenixKit.Modules.Storage.VariantSet`), and
  the set's sizes are its `PhoenixKit.Modules.Storage.Dimension` rows. A
  library with no set uses the **Default**, seeded by V205 with every size
  the install had, under a fixed uuid (`default_uuid/0`). Size names are
  unique per set, so two sets can each have a `thumbnail` of a different
  size.

  ## Standard slots

  A size's name is part of every file URL, and core and modules ask for
  some by name, so every set has the five standard slots
  (`standard_slots/0`): `thumbnail`, `small`, `medium`, `large` and
  `video_thumbnail`. A set may change their size, format and quality, but
  not delete or rename them, and `small`, `medium` and `large` keep the
  aspect ratio (`aspect_slots/0`); only `thumbnail` may be cropped. A new
  set starts with the Default's standard slots.

  ## Spec hash

  A generated instance records which spec of its size made it
  (`FileInstance.spec_hash`, `spec_hash/2`), and a set records a `revision`
  bumped on every change to it or its sizes. A file records the set and
  revision its variants were made by (`placed_variant_set_uuid` /
  `placed_variant_revision`, NULL meaning the Default at revision 1). The
  reconciler regenerates the instances of a stale file whose spec changed.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.{
    Audit,
    Dimension,
    DimensionOptions,
    Library,
    VariantGenerator,
    VariantSet
  }

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Shape
  alias PhoenixKit.Modules.Storage.Workers.ReconcileJob
  alias PhoenixKit.Settings

  # The version of the size-rendering rules, part of every spec hash.
  # 2: see-through images get PNG (or WebP) sizes, sizes never upscale.
  @pipeline 2

  @default_uuid "00000000-0000-7000-8000-000000000003"

  @doc "The uuid of the Default variant set, fixed on every install."
  @spec default_uuid() :: String.t()
  def default_uuid, do: @default_uuid

  @doc "Whether `uuid` is the Default set's."
  @spec default?(term()) :: boolean()
  def default?(%VariantSet{uuid: uuid}), do: default?(uuid)
  def default?(uuid), do: to_string(uuid) == @default_uuid

  @doc "The sizes every set has."
  @spec standard_slots() :: [String.t()]
  def standard_slots, do: Dimension.standard_slots()

  @doc "The standard slots that always keep the aspect ratio."
  @spec aspect_slots() :: [String.t()]
  def aspect_slots, do: Dimension.aspect_slots()

  @doc "Every set, the Default first."
  @spec list_variant_sets() :: [VariantSet.t()]
  def list_variant_sets do
    from(s in VariantSet, order_by: [desc: s.is_default, asc: fragment("lower(?)", s.name)])
    |> repo().all()
  end

  @doc "The sets a user library may choose."
  @spec list_selectable() :: [VariantSet.t()]
  def list_selectable do
    from(s in VariantSet,
      where: s.selectable or s.is_default,
      order_by: [desc: s.is_default, asc: fragment("lower(?)", s.name)]
    )
    |> repo().all()
  end

  @doc "A set, or nil (also for anything not a uuid)."
  @spec get_variant_set(term()) :: VariantSet.t() | nil
  def get_variant_set(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(VariantSet, uuid)
      :error -> nil
    end
  end

  @doc "The Default set."
  @spec default_variant_set() :: VariantSet.t() | nil
  def default_variant_set, do: get_variant_set(@default_uuid)

  @doc """
  The uuid of the set `library` uses: its own, or the Default. Takes a
  library, a library uuid, or nil (a file with no library is in Media).
  """
  @spec set_uuid_for(Library.t() | term()) :: String.t()
  def set_uuid_for(%Library{variant_set_uuid: nil}), do: @default_uuid
  def set_uuid_for(%Library{variant_set_uuid: uuid}), do: to_string(uuid)
  def set_uuid_for(nil), do: set_uuid_for(Libraries.media_uuid())

  def set_uuid_for(library_uuid) do
    case Libraries.get_library(library_uuid) do
      %Library{} = library -> set_uuid_for(library)
      nil -> @default_uuid
    end
  end

  @doc "The set `library` uses; the Default when its own is gone."
  @spec for_library(Library.t() | term()) :: VariantSet.t() | nil
  def for_library(library) do
    library |> set_uuid_for() |> get_variant_set() || default_variant_set()
  end

  @doc "The set a file's library uses."
  @spec for_file(StorageFile.t()) :: VariantSet.t() | nil
  def for_file(%StorageFile{library_uuid: library_uuid}), do: for_library(library_uuid)

  @doc "A set's sizes, ordered as the admin arranged them."
  @spec list_dimensions(term()) :: [Dimension.t()]
  def list_dimensions(set_uuid) do
    from(d in Dimension,
      where: d.variant_set_uuid == ^set_uuid,
      order_by: [asc: d.order, asc: d.name]
    )
    |> repo().all()
  end

  @doc "The standard slots `set_uuid` has no size for."
  @spec missing_standard_slots(term()) :: [String.t()]
  def missing_standard_slots(set_uuid) do
    present =
      from(d in Dimension, where: d.variant_set_uuid == ^set_uuid, select: d.name)
      |> repo().all()

    standard_slots() -- present
  end

  @doc """
  Creates a set. It starts with a copy of the Default's standard slots,
  so it keeps the contract every set has.
  """
  @spec create_variant_set(map(), keyword()) ::
          {:ok, VariantSet.t()} | {:error, Ecto.Changeset.t()}
  def create_variant_set(attrs, opts \\ []) do
    Audit.transaction(fn -> do_create_variant_set(attrs, opts) end)
  end

  defp do_create_variant_set(attrs, opts) do
    changeset = VariantSet.changeset(%VariantSet{}, attrs)

    transact(fn ->
      with {:ok, set} <- repo().insert(changeset) do
        copy_standard_slots(set.uuid)
        {:ok, set}
      end
    end)
    |> tap(fn
      {:ok, set} ->
        Audit.log("storage.variant_set.created", "storage_variant_set", set.uuid, opts, %{
          "name" => set.name
        })

      _error ->
        :ok
    end)
  end

  defp copy_standard_slots(set_uuid) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    rows =
      from(d in Dimension,
        where: d.variant_set_uuid == ^@default_uuid and d.name in ^standard_slots()
      )
      |> repo().all()
      |> Enum.map(fn d ->
        d
        |> Map.take([
          :name,
          :width,
          :height,
          :quality,
          :format,
          :applies_to,
          :enabled,
          :maintain_aspect_ratio,
          :alternative_formats,
          :order
        ])
        |> Map.merge(%{
          options: %DimensionOptions{
            keep_hdr: Dimension.keep_hdr?(d),
            strip_metadata: Dimension.strip_metadata?(d)
          },
          uuid: UUIDv7.generate(),
          variant_set_uuid: set_uuid,
          inserted_at: now,
          updated_at: now
        })
      end)

    repo().insert_all(Dimension, rows)
  end

  # The fields of a set whose change is written to the history.
  @audited_fields [:name, :selectable, :generate_variants, :generate_tiles]

  @doc """
  Updates a set's name or flags. Turning variant or tile generation on or
  off bumps its revision; a rename or `selectable` does not. A set removed
  since it was loaded returns `{:error, :not_found}`.
  """
  @spec update_variant_set(VariantSet.t(), map(), keyword()) ::
          {:ok, VariantSet.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_variant_set(%VariantSet{} = set, attrs, opts \\ []) do
    Audit.change(set, &do_update_variant_set(&1, attrs, opts))
  end

  defp do_update_variant_set(set, attrs, opts) do
    changeset = VariantSet.changeset(set, attrs)

    transact(fn ->
      with {:ok, updated} <- repo().update(changeset) do
        if Map.drop(changeset.changes, [:name, :selectable]) != %{},
          do: bump_revision(updated.uuid)

        {:ok, updated.uuid}
      end
    end)
    |> case do
      {:ok, uuid} ->
        set = get_variant_set(uuid)
        if set.is_default, do: Audit.after_commit(fn -> sync_settings(set, opts) end)

        Audit.log_update(
          "storage.variant_set.updated",
          "storage_variant_set",
          set.uuid,
          opts,
          Audit.changes(changeset, @audited_fields),
          %{"name" => set.name}
        )

        {:ok, set}

      error ->
        error
    end
  end

  # The Default's flags are what two settings were before variant sets; the
  # rows are kept in step for code that still reads them.
  defp sync_settings(%VariantSet{} = set, opts) do
    Settings.update_setting(
      "storage_auto_generate_variants",
      to_string(set.generate_variants),
      opts
    )

    Settings.update_setting(
      "storage_tile_generation_enabled",
      to_string(set.generate_tiles),
      opts
    )
  end

  @doc """
  Deletes a set and its sizes. The Default cannot be deleted
  (`{:error, :default}`), nor a set a library uses (`{:error, :in_use}`).
  """
  @spec delete_variant_set(VariantSet.t(), keyword()) ::
          {:ok, VariantSet.t()} | {:error, :default | :in_use | Ecto.Changeset.t()}
  def delete_variant_set(%VariantSet{} = set, opts \\ []) do
    Audit.change(set, &do_delete_variant_set(&1, opts))
  end

  defp do_delete_variant_set(set, opts) do
    cond do
      default?(set) ->
        {:error, :default}

      libraries_using(set.uuid) > 0 ->
        {:error, :in_use}

      true ->
        set
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.foreign_key_constraint(:uuid,
          name: :phoenix_kit_storage_libraries_variant_set_fkey,
          message: "is used by a library"
        )
        |> repo().delete()
        |> tap(fn
          {:ok, deleted} ->
            Audit.log("storage.variant_set.deleted", "storage_variant_set", deleted.uuid, opts, %{
              "name" => deleted.name
            })

          _error ->
            :ok
        end)
    end
  end

  @doc "How many libraries (trashed ones included) use `set_uuid` explicitly."
  @spec libraries_using(term()) :: non_neg_integer()
  def libraries_using(set_uuid) do
    from(l in Library, where: l.variant_set_uuid == ^set_uuid, select: count())
    |> repo().one()
  end

  @doc """
  Points `library` at `set_uuid` (nil for the Default). A user library may
  only use a selectable set (`{:error, :not_selectable}`).
  """
  @spec set_library_variant_set(Library.t(), term(), keyword()) ::
          {:ok, Library.t()} | {:error, Ecto.Changeset.t() | :not_found | :not_selectable}
  def set_library_variant_set(%Library{} = library, set_uuid, opts \\ []) do
    Audit.change(library, &do_set_library_variant_set(&1, set_uuid, opts))
  end

  defp do_set_library_variant_set(library, set_uuid, opts) do
    set_uuid = if default?(set_uuid), do: nil, else: set_uuid
    set = set_uuid && get_variant_set(set_uuid)

    cond do
      set_uuid && is_nil(set) ->
        {:error, :not_found}

      library.kind == "user" and match?(%VariantSet{selectable: false}, set) ->
        {:error, :not_selectable}

      true ->
        library
        |> Ecto.Changeset.change(variant_set_uuid: set_uuid)
        |> Ecto.Changeset.foreign_key_constraint(:variant_set_uuid,
          name: :phoenix_kit_storage_libraries_variant_set_fkey
        )
        |> repo().update()
        |> tap(&if(match?({:ok, _}, &1), do: ReconcileJob.enqueue()))
        |> tap(fn
          {:ok, updated} -> audit_library_set(library, updated, opts)
          _error -> :ok
        end)
    end
  end

  # A system library moving to another variant set, by name. A user's library is
  # theirs and private, and is not in the history.
  defp audit_library_set(%Library{kind: "system"} = before, %Library{} = updated, opts) do
    if set_uuid_for(before) != set_uuid_for(updated) do
      Audit.log("storage.library.variant_set_changed", "storage_library", updated.uuid, opts, %{
        "library" => updated.name,
        PhoenixKit.Activity.changes_key() => %{
          "variant_set" => %{
            "from" => set_name(set_uuid_for(before)),
            "to" => set_name(set_uuid_for(updated))
          }
        }
      })
    end

    :ok
  end

  defp audit_library_set(_before, _updated, _opts), do: :ok

  @doc false
  def set_name(uuid) do
    case get_variant_set(uuid) do
      %VariantSet{name: name} -> name
      nil -> to_string(uuid)
    end
  end

  @doc """
  Marks every file stale, so the reconciler remakes each file's sizes whose
  spec hash no longer matches — after an upgrade that changed how sizes are
  rendered (`@pipeline`). Lazy: the reconciler works through files in
  batches in the background; nothing is regenerated in this call.
  """
  @spec remake_all(keyword()) :: :ok | {:error, term()}
  def remake_all(opts \\ []) do
    Audit.transaction(fn -> do_remake_all(opts) end)
  end

  defp do_remake_all(opts) do
    repo().update_all(VariantSet,
      inc: [revision: 1],
      set: [updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )

    ReconcileJob.enqueue()

    Audit.log("storage.variant_set.remade", "storage_variant_set", nil, opts, %{
      "scope" => "every set"
    })

    :ok
  end

  @doc "Requests a check of one set's files and records the person who requested it."
  @spec check_files(VariantSet.t(), keyword()) :: :ok | {:error, term()}
  def check_files(%VariantSet{} = set, opts \\ []) do
    Audit.change(set, fn current ->
      :ok = bump_revision(current.uuid)

      Audit.log("storage.variant_set.remade", "storage_variant_set", current.uuid, opts, %{
        "name" => current.name,
        "scope" => "one set"
      })

      :ok
    end)
  end

  @doc "Bumps a set's revision: every file whose variants it made is stale."
  @spec bump_revision(term()) :: :ok
  def bump_revision(set_uuid) do
    from(s in VariantSet, where: s.uuid == ^set_uuid)
    |> repo().update_all(
      inc: [revision: 1],
      set: [updated_at: DateTime.truncate(DateTime.utc_now(), :second)]
    )

    ReconcileJob.enqueue()
    :ok
  end

  @doc """
  Whether `file`'s library has deep zoom (zoomable tiles) on. Takes a file or a
  file uuid; false for an unknown file. See `deep_zoom_for_library?/1`.
  """
  @spec tiles_for?(StorageFile.t() | term()) :: boolean()
  def tiles_for?(%StorageFile{library_uuid: library_uuid}),
    do: deep_zoom_for_library?(library_uuid)

  def tiles_for?(file_uuid) do
    case Ecto.UUID.cast(file_uuid) do
      {:ok, uuid} ->
        from(f in StorageFile,
          left_join: l in Library,
          on: l.uuid == f.library_uuid,
          join: s in VariantSet,
          on: s.uuid == coalesce(l.variant_set_uuid, type(^@default_uuid, UUIDv7)),
          where: f.uuid == ^uuid,
          select: coalesce(fragment("(?->>'deep_zoom')::boolean", l.settings), s.generate_tiles)
        )
        |> repo().one() == true

      :error ->
        false
    end
  end

  @doc """
  Whether a library (nil is Media) has deep zoom on: its own choice
  (`Libraries.setting(library, :deep_zoom)`), and when it has made none, its
  rendition profile's `generate_tiles` flag, which is what the choice was before it
  moved to the library.
  """
  @spec deep_zoom_for_library?(term()) :: boolean()
  def deep_zoom_for_library?(library_uuid),
    do: MapSet.size(tiles_among([library_uuid])) > 0

  @doc """
  Of `library_uuids` (nil is Media), the ones with deep zoom on (see
  `deep_zoom_for_library?/1`), as a set of strings: one query for a page of
  files.
  """
  @spec tiles_among([term()]) :: MapSet.t(String.t())
  def tiles_among(library_uuids) do
    uuids =
      library_uuids
      |> Enum.map(&(&1 || Libraries.media_uuid()))
      |> Enum.flat_map(&List.wrap(cast(&1)))
      |> Enum.uniq()

    from(l in Library,
      join: s in VariantSet,
      on: s.uuid == coalesce(l.variant_set_uuid, type(^@default_uuid, UUIDv7)),
      where:
        l.uuid in ^uuids and
          coalesce(fragment("(?->>'deep_zoom')::boolean", l.settings), s.generate_tiles),
      select: l.uuid
    )
    |> repo().all()
    |> MapSet.new(&to_string/1)
  end

  @doc """
  Whether any enabled rendition crops around the subject of the photo (what the
  libvips notice needs: nothing else uses it).
  """
  @spec focus_crop_in_use?() :: boolean()
  def focus_crop_in_use? do
    from(d in Dimension,
      where:
        d.enabled and d.maintain_aspect_ratio == false and
          fragment("?->>'crop_mode' = 'focus'", d.options)
    )
    |> repo().exists?()
  end

  @doc "Whether any library has deep zoom on (what the ImageMagick notice needs)."
  @spec tiles_anywhere?() :: boolean()
  def tiles_anywhere? do
    from(l in Library,
      join: s in VariantSet,
      on: s.uuid == coalesce(l.variant_set_uuid, type(^@default_uuid, UUIDv7)),
      where: coalesce(fragment("(?->>'deep_zoom')::boolean", l.settings), s.generate_tiles)
    )
    |> repo().exists?()
  end

  @doc "Whether the set of `file`'s library makes sizes automatically."
  @spec variants_for?(StorageFile.t()) :: boolean()
  def variants_for?(%StorageFile{library_uuid: library_uuid}),
    do: library_flag(library_uuid, :generate_variants)

  defp library_flag(library_uuid, flag) do
    case for_library(library_uuid) do
      %VariantSet{} = set -> Map.fetch!(set, flag)
      nil -> false
    end
  end

  @doc """
  One of the Default set's flags (`:generate_variants` or
  `:generate_tiles`): what the `storage_auto_generate_variants` and
  `storage_tile_generation_enabled` settings were before variant sets.
  `default` when there is no Default set yet.
  """
  @spec default_flag(:generate_variants | :generate_tiles, boolean()) :: boolean()
  def default_flag(flag, default) when flag in [:generate_variants, :generate_tiles] do
    from(s in VariantSet, where: s.uuid == ^@default_uuid, select: field(s, ^flag))
    |> repo().one()
    |> case do
      nil -> default
      value -> value
    end
  end

  @doc """
  Records that `file`'s variants were made by its library's set as it is
  now (`complete?`), or that some are missing (the file is stale for the
  reconciler: `placed_variant_revision = 0`).
  """
  @spec record_variants(StorageFile.t(), boolean(), VariantSet.t() | nil | :current) :: :ok
  def record_variants(%StorageFile{} = file, complete?, set \\ :current) do
    set = if set == :current, do: for_file(file), else: set

    changes =
      if set && complete?,
        do: [placed_variant_set_uuid: set.uuid, placed_variant_revision: set.revision],
        else: [placed_variant_revision: 0]

    from(f in StorageFile, where: f.uuid == ^file.uuid)
    |> repo().update_all(set: changes)

    unless complete?, do: ReconcileJob.enqueue()
    :ok
  end

  @image_formats ~w(jpg jpeg png webp avif gif)

  @doc """
  What to serve in place of `variant` of `file` while it has not been made
  (G17), given the file's `instances`:

    * `{:instance, instance}` — the nearest smaller size the file has;
    * `:placeholder` — no smaller size exists, and the original is larger
      than the size asked for;
    * `:original` — the original is no larger than the size, or `variant`
      is not an image size of the file's set (an unknown name, a video
      transcode), which is what was always served.

  A thumbnail-class request never gets a full-size original: in a grid of
  thousands, a new or renamed size would otherwise send thousands of them.
  """
  @spec stand_in(StorageFile.t(), String.t(), [struct()]) ::
          {:instance, struct()} | :placeholder | :original
  def stand_in(%StorageFile{} = file, variant, instances) do
    set = for_library(file.library_uuid)

    # Only a size that will be made: with the set making no sizes, a
    # disabled size, or one for the other kind of file, nothing is coming,
    # and the original is what was always served.
    with %VariantSet{generate_variants: true} <- set,
         %Dimension{width: width, enabled: true} = dimension when is_integer(width) <-
           size_named(set.uuid, variant),
         true <- dimension.applies_to in [file_kind(file), "both"],
         true <- shape_fits?(dimension, file),
         true <- image_output?(file, dimension, variant) do
      smaller =
        instances
        |> Enum.filter(fn i ->
          i.spec_hash != nil and i.variant_name != variant and
            String.starts_with?(i.mime_type || "", "image/") and is_integer(i.width) and
            i.width <= width
        end)
        |> Enum.max_by(& &1.width, fn -> nil end)

      cond do
        smaller -> {:instance, smaller}
        is_integer(file.width) and file.width <= width -> :original
        true -> :placeholder
      end
    else
      _ -> :original
    end
  end

  # A size by name, or the size an alternative format (`medium_webp`) is of.
  defp size_named(set_uuid, variant) do
    dimensions = list_dimensions(set_uuid)

    Enum.find(dimensions, &(&1.name == variant)) ||
      Enum.find(dimensions, fn d ->
        Enum.any?(d.alternative_formats || [], &(variant == "#{d.name}_#{&1}"))
      end)
  end

  defp file_kind(%StorageFile{file_type: "video"}), do: "video"
  defp file_kind(_file), do: "image"

  defp image_output?(file, dimension, variant) do
    alt_format =
      Enum.find(dimension.alternative_formats || [], &(variant == "#{dimension.name}_#{&1}"))

    format = alt_format || dimension.format

    file.file_type in ["image", "document"] or format in @image_formats
  end

  @doc """
  The name of the size of `file`'s set that fits a purpose (G19), rather
  than a size picked by name: a set may make `small` a square crop, so a
  name alone promises nothing.

  ## Options

    * `:min_width` — the smallest width that will do (default 0);
    * `:aspect` — `:preserve` (the aspect ratio is kept), `:crop`, or
      `:any` (the default);
    * `:output` — `:image` (the default: a still, a video's poster
      included) or `:video` (a transcode, for a video file).

  The narrowest enabled size of the file's kind that is at least
  `:min_width` wide; the widest one when none is; `"original"` when the set
  has none that fit.
  """
  @spec variant_for(StorageFile.t(), keyword()) :: String.t()
  def variant_for(%StorageFile{} = file, opts \\ []) do
    min_width = Keyword.get(opts, :min_width, 0)
    aspect = Keyword.get(opts, :aspect, :any)
    output = Keyword.get(opts, :output, :image)
    kind = file_kind(file)

    candidates =
      file.library_uuid
      |> set_uuid_for()
      |> list_dimensions()
      |> Enum.filter(fn d ->
        d.enabled and d.name != "original" and is_integer(d.width) and
          d.applies_to in [kind, "both"] and shape_fits?(d, file) and aspect_fits?(d, aspect) and
          output_fits?(file, d, output)
      end)

    case Enum.filter(candidates, &(&1.width >= min_width)) do
      [] -> candidates |> Enum.max_by(& &1.width, fn -> nil end) |> name_or_original()
      fitting -> fitting |> Enum.min_by(& &1.width) |> name_or_original()
    end
  end

  # An image file's sizes are all stills; a video's are stills only when
  # their format is an image format (`video_thumbnail`).
  defp output_fits?(%StorageFile{file_type: "video"}, dimension, output) do
    still? = dimension.format in @image_formats
    if output == :video, do: not still?, else: still?
  end

  defp output_fits?(_file, _dimension, output), do: output == :image

  # A size made for a shape is made only for files of that shape (as
  # `VariantGenerator` decides), so it is never one to ask for another's.
  defp shape_fits?(dimension, file) do
    case Dimension.shape(dimension) do
      shape when shape in [nil, "any"] -> true
      shape -> to_string(Shape.classify(file)) == shape
    end
  end

  defp aspect_fits?(_dimension, :any), do: true
  defp aspect_fits?(dimension, :preserve), do: dimension.maintain_aspect_ratio == true
  defp aspect_fits?(dimension, :crop), do: dimension.maintain_aspect_ratio == false

  defp name_or_original(nil), do: "original"
  defp name_or_original(%Dimension{name: name}), do: name

  defp cast(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  @doc """
  The spec hash of the variant `dimension` makes in `format` (its own
  format when not given; nil keeps the original's). Only what changes the
  pixels counts: width, height, quality, format and whether the aspect
  ratio is kept — plus `@pipeline`, the version of the rendering rules
  themselves.

  V205 stamped existing instances with the `v1` text in SQL
  (`PhoenixKit.Migrations.Postgres.V205.spec_hash_sql/1`). Pipeline 2
  (see-through images get PNG sizes instead of black-backed JPEGs; sizes
  never upscale) changes every hash, so the reconciler remakes a file's
  sizes the next time it looks at the file; `remake_all/0` makes it look
  at every file.
  """
  @spec spec_hash(Dimension.t()) :: String.t()
  @spec spec_hash(Dimension.t(), String.t() | nil) :: String.t()
  def spec_hash(%Dimension{} = dimension), do: spec_hash(dimension, dimension.format)

  def spec_hash(%Dimension{} = d, format) do
    aspect = if d.maintain_aspect_ratio, do: "t", else: "f"

    "v1|w=#{d.width}|h=#{d.height}|q=#{d.quality}|f=#{format}|a=#{aspect}|p=#{@pipeline}"
    |> Kernel.<>(crop_part(d))
    |> Kernel.<>(fit_part(d))
    |> Kernel.<>(alpha_part(format))
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end

  # Cropping around the focal point changes the pixels of a fixed rendition, so it
  # is part of the hash; the default (the center) adds nothing, so every existing
  # center hash is unchanged. Version 2 gives each point its own object key;
  # a check of the profile's files also remakes focus crops made before it.
  defp crop_part(d), do: if(Dimension.focus_crop?(d), do: "|c=focus|fp=2", else: "")

  # A fixed height makes a different picture from a fixed width, so it is part of
  # the hash; the default (the width) adds nothing.
  defp fit_part(d), do: if(Dimension.fixed_height?(d), do: "|b=height", else: "")

  # `variant_alpha_format` changes the pixels of a see-through image's
  # JPEG-configured sizes, so a non-default value is part of the hash. The
  # default adds nothing, so existing hashes are unchanged.
  # Only a size that can come out JPEG (configured JPEG, or keeping the
  # original's format) is affected; a PNG or WebP size never is, so changing
  # the setting does not mark every size of every file outdated.
  defp alpha_part(format) when format in [nil, "", "jpg", "jpeg"] do
    case VariantGenerator.alpha_format() do
      "png" -> ""
      other -> "|af=#{other}"
    end
  end

  defp alpha_part(_format), do: ""

  @doc false
  # The pipeline-1 text V205 stamped in SQL, kept so its migration test can
  # show those stamps are the old hash (and so remade under pipeline 2).
  @spec legacy_spec_hash(Dimension.t(), String.t() | nil) :: String.t()
  def legacy_spec_hash(%Dimension{} = d, format) do
    aspect = if d.maintain_aspect_ratio, do: "t", else: "f"

    "v1|w=#{d.width}|h=#{d.height}|q=#{d.quality}|f=#{format}|a=#{aspect}"
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end

  defp transact(fun) do
    repo().transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
