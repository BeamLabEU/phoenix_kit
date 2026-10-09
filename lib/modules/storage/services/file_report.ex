defmodule PhoenixKit.Modules.Storage.FileReport do
  @moduledoc """
  What is stored for one file, and whether it is all there: the data behind a
  file's storage page.

  `renditions/1` lists the original and every size the file's variant set
  wants (`VariantGenerator.expected_variants/1`), then whatever else the file
  carries (a burned-annotation copy), each with its state and the buckets
  that hold it. The states follow the reconciler's own reading
  (`Reconciler.reconcile_file/1` makes what is `:missing` or `:stale`):

    * `:ok` — stored, made from the size's current spec
    * `:missing` — the set wants it and the file has no instance of it
    * `:stale` — made from another spec than the size has now
    * `:processing` / `:failed` — its instance row says so
    * `:no_copy` — an instance whose object no bucket is recorded to hold

  `verify/1` reads every copy back from its own bucket and compares the
  SHA-256 with the one recorded when the object was stored. Slow on a large
  file or a cloud bucket: call it from a task, not a render.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.FileLocation
  alias PhoenixKit.Modules.Storage.Manager
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Modules.Storage.VariantSets

  @typedoc "One bucket's copy of an object."
  @type copy :: %{
          bucket: PhoenixKit.Modules.Storage.Bucket.t(),
          status: String.t(),
          path: String.t(),
          last_verified_at: DateTime.t() | nil
        }

  @type state :: :ok | :missing | :stale | :processing | :failed | :no_copy

  @type row :: %{
          name: String.t(),
          kind: :original | :size | :alternative | :annotated | :other,
          state: state(),
          instance: FileInstance.t() | nil,
          dimension: struct() | nil,
          format: String.t() | nil,
          copies: [copy()]
        }

  @doc """
  The rows of `file`: the original, the sizes its set wants, then the rest.
  """
  @spec renditions(StorageFile.t()) :: [row()]
  def renditions(%StorageFile{} = file) do
    instances = Storage.list_file_instances(file.uuid)
    copies = copies_by_instance(instances)
    by_name = Map.new(instances, &{&1.variant_name, &1})

    expected =
      Enum.map(VariantGenerator.expected_variants(file), fn {dimension, name, format} ->
        instance = by_name[name]
        kind = if name == dimension.name, do: :size, else: :alternative

        row(name, kind, instance, copies, dimension: dimension, format: format)
        |> Map.put(:state, expected_state(instance, dimension, format, copies))
      end)

    expected_names = MapSet.new(["original" | Enum.map(expected, & &1.name)])

    original =
      row("original", :original, by_name["original"], copies, format: nil)
      |> then(&Map.put(&1, :state, found_state(&1)))

    extras =
      instances
      |> Enum.reject(&MapSet.member?(expected_names, &1.variant_name))
      |> Enum.sort_by(& &1.variant_name)
      |> Enum.map(fn instance ->
        kind =
          if String.starts_with?(instance.variant_name, "burned"), do: :annotated, else: :other

        row = row(instance.variant_name, kind, instance, copies, format: nil)
        Map.put(row, :state, found_state(row))
      end)

    [original | expected] ++ extras
  end

  @doc """
  Whether the file has anything to put right: a rendition missing, made from
  an older spec, or an object no bucket holds.
  """
  @spec problems(StorageFile.t() | [row()]) :: [row()]
  def problems(%StorageFile{} = file), do: file |> renditions() |> problems()

  def problems(rows) when is_list(rows),
    do: Enum.filter(rows, &(&1.state in [:missing, :stale, :failed, :no_copy]))

  @doc """
  Reads every copy of every instance back from its own bucket and compares it
  with the checksum recorded for it.

  One result per copy: `%{name, bucket, path, result}` where `result` is
  `:ok`, `{:mismatch, recorded, actual}`, `:not_found`, `{:unrecorded, actual}`
  (no checksum was recorded to compare with) or `{:error, reason}`. An
  instance with no copy at all gives one result with `bucket: nil` and
  `:no_copy`.
  """
  @spec verify(StorageFile.t()) :: [map()]
  def verify(%StorageFile{} = file) do
    instances = Storage.list_file_instances(file.uuid)
    copies = copies_by_instance(instances)

    Enum.flat_map(instances, fn instance ->
      recorded = recorded_checksum(file, instance)

      case Map.get(copies, instance.uuid, []) do
        [] ->
          [
            %{
              name: instance.variant_name,
              bucket: nil,
              path: instance.file_name,
              result: :no_copy
            }
          ]

        found ->
          for copy <- found, copy.status == "active" do
            %{
              name: instance.variant_name,
              bucket: copy.bucket,
              path: copy.path,
              result: check(copy, recorded)
            }
          end
      end
    end)
  end

  @doc "Whether every result of `verify/1` is `:ok`."
  @spec all_ok?([map()]) :: boolean()
  def all_ok?(results), do: results != [] and Enum.all?(results, &(&1.result == :ok))

  # The checksum an instance was stored with. The original's falls back to the
  # file's own, for rows written before instances carried one.
  defp recorded_checksum(file, %{variant_name: "original", checksum: sum}) when sum in [nil, ""],
    do: file.file_checksum

  defp recorded_checksum(_file, %{checksum: sum}) when sum in [nil, ""], do: nil
  defp recorded_checksum(_file, %{checksum: sum}), do: sum

  defp check(copy, recorded) do
    case Manager.checksum_in(copy.bucket, copy.path) do
      {:ok, %{checksum: ^recorded}} -> :ok
      {:ok, %{checksum: actual}} when is_nil(recorded) -> {:unrecorded, actual}
      {:ok, %{checksum: actual}} -> {:mismatch, recorded, actual}
      {:error, :not_found} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp row(name, kind, instance, copies, opts) do
    %{
      name: name,
      kind: kind,
      state: :ok,
      instance: instance,
      dimension: opts[:dimension],
      format: opts[:format],
      copies: (instance && Map.get(copies, instance.uuid, [])) || []
    }
  end

  defp expected_state(nil, _dimension, _format, _copies), do: :missing

  defp expected_state(%FileInstance{spec_hash: hash} = instance, dimension, format, copies) do
    cond do
      instance.processing_status == "failed" -> :failed
      instance.processing_status != "completed" -> :processing
      Map.get(copies, instance.uuid, []) == [] -> :no_copy
      hash != nil and hash != VariantSets.spec_hash(dimension, format) -> :stale
      true -> :ok
    end
  end

  # Rows that are not measured against a size: only whether they are stored.
  defp found_state(%{instance: nil}), do: :missing
  defp found_state(%{instance: %{processing_status: "failed"}}), do: :failed

  defp found_state(%{instance: %{processing_status: status}}) when status != "completed",
    do: :processing

  defp found_state(%{copies: []}), do: :no_copy
  defp found_state(_row), do: :ok

  defp copies_by_instance([]), do: %{}

  defp copies_by_instance(instances) do
    uuids = Enum.map(instances, & &1.uuid)

    from(l in FileLocation,
      join: b in assoc(l, :bucket),
      where: l.file_instance_uuid in ^uuids and l.status != "deleted",
      order_by: [desc: l.priority, asc: b.name],
      select: {l.file_instance_uuid, b, l.status, l.path, l.last_verified_at}
    )
    |> PhoenixKit.Config.get_repo().all()
    |> Enum.group_by(&elem(&1, 0), fn {_uuid, bucket, status, path, verified} ->
      %{bucket: bucket, status: status, path: path, last_verified_at: verified}
    end)
  end
end
