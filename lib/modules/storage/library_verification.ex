defmodule PhoenixKit.Modules.Storage.LibraryVerification do
  @moduledoc """
  Read-only verification of original objects and, optionally, previews. A check
  never updates location health, rewrites bytes or queues repairs. Problems carry
  identifiers and fixed codes only; no provider responses or credentials enter logs.
  """
  alias PhoenixKit.Modules.Storage.{Bucket, FileReport, Manager, Profiles}

  @doc "Checks one file. The optional probe functions are also used by fixture tests."
  def check(file, mode, include_previews, opts \\ []) do
    profile = Profiles.for_library(file.library_uuid)
    rows = FileReport.renditions(file)
    rows = if include_previews, do: rows, else: Enum.filter(rows, &(&1.kind == :original))

    pending =
      if file.status == "processing",
        do: [%{"file_uuid" => file.uuid, "problem" => "processing"}],
        else: []

    pending ++
      Enum.flat_map(rows, fn row ->
        base = %{"file_uuid" => file.uuid, "rendition" => row.name}
        state = state_problems(row, base)
        copies = Enum.flat_map(row.copies, &check_copy(file, row, &1, mode, base, opts))
        placement = placement_problems(profile, row, base)
        state ++ copies ++ placement
      end)
  end

  defp state_problems(%{state: :ok}, _base), do: []

  defp state_problems(%{state: state}, base),
    do: [Map.put(base, "problem", Atom.to_string(state))]

  defp check_copy(file, row, copy, mode, base, opts) do
    if heartbeat = opts[:heartbeat], do: heartbeat.()
    base = Map.put(base, "bucket_uuid", copy.bucket.uuid)

    problem =
      cond do
        not copy.bucket.enabled -> "bucket_disabled"
        copy.status != "active" -> "copy_pending"
        mode == "presence" -> presence(copy, opts)
        true -> checksum(file, row, copy, opts)
      end

    if problem, do: [Map.put(base, "problem", problem)], else: []
  end

  defp presence(copy, opts) do
    probe = Keyword.get(opts, :presence, &Manager.holds?/2)
    if probe.(copy.bucket, copy.path), do: nil, else: "missing_or_inaccessible"
  end

  defp checksum(file, row, copy, opts) do
    recorded = FileReport.recorded_checksum(file, row.instance)
    probe = Keyword.get(opts, :checksum, &Manager.checksum_in/2)

    cond do
      recorded in [nil, ""] ->
        "unrecorded_checksum"

      not Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, recorded) ->
        "unsupported_checksum"

      true ->
        compare_checksum(
          probe.(copy.bucket, copy.path),
          String.downcase(recorded),
          row.instance.size
        )
    end
  end

  defp compare_checksum({:ok, %{checksum: checksum, size: size}}, checksum, size), do: nil
  defp compare_checksum({:ok, %{checksum: checksum}}, checksum, _size), do: "size_mismatch"
  defp compare_checksum({:ok, _}, _checksum, _size), do: "checksum_mismatch"
  defp compare_checksum({:error, :not_found}, _checksum, _size), do: "missing_or_inaccessible"
  defp compare_checksum({:error, _}, _checksum, _size), do: "read_failed"

  defp placement_problems(nil, _row, base), do: [Map.put(base, "problem", "profile_missing")]
  defp placement_problems(_profile, %{instance: nil}, _base), do: []

  defp placement_problems(profile, row, base) do
    # A pooled profile need not use every candidate bucket. Check its required
    # copy counts by storage kind instead of inventing a particular destination.
    allowed =
      for target <- profile.buckets,
          target.status in ["active", "read_only"],
          match?(%{enabled: true}, target.bucket),
          into: %{},
          do: {target.bucket_uuid, target}

    active =
      Enum.filter(row.copies, &(&1.status == "active" and Map.has_key?(allowed, &1.bucket.uuid)))

    counts =
      active |> Enum.uniq_by(& &1.bucket.uuid) |> Enum.frequencies_by(&Bucket.group(&1.bucket))

    missing =
      for group <- [:local, :cloud],
          Profiles.copies(profile, group) > Map.get(counts, group, 0),
          do:
            Map.merge(base, %{
              "problem" => "insufficient_copies",
              "storage_kind" => Atom.to_string(group)
            })

    serving? = Enum.any?(active, &(allowed[&1.bucket.uuid].role in ["primary", "replica"]))
    if serving?, do: missing, else: missing ++ [Map.put(base, "problem", "no_serving_copy")]
  end
end
