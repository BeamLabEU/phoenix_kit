defmodule PhoenixKit.Modules.Storage.FileRepair do
  @moduledoc """
  Puts one file's storage right: what `FileReport.verify/1` finds wrong, and
  what the reconciler would make.

  It does, in order:

    1. **Reads every copy back** (`FileReport.verify/1`).
    2. **Copies a good copy over a bad one** — a copy that is gone from its
       bucket or whose bytes differ from the checksum recorded for it — from
       another bucket that holds a good one (`Manager.copy_object/3`).
    3. **Makes again what no good copy is left of**, when it is a size made
       from the original (`VariantGenerator.generate_variant/5`, which also
       replaces a damaged object under the same key). An original with no good
       copy anywhere cannot be made again: that is reported, not hidden — and
       because every size is made from the original, nothing is made from an
       original that is damaged.
    4. **Records a copy it finds** in an enabled bucket for an object with no
       location row (`Locations.record/2`).
    5. **Reconciles** (`Reconciler.reconcile_file/1`): sizes the variant set
       wants and the file lacks, sizes made from another spec, and copies where
       the storage profile wants them.
    6. **Reads everything back again**, so the result says what is right now.

  Steps 2 to 4 run twice: a size made again may leave a bucket of the file's
  profile without it, and the second pass copies it there.

  Returns `{:ok, %{actions: [action], verification: [result]}}`, where an action
  is `%{name:, kind:, bucket:, from:}` and `kind` is one of `:restored`,
  `:regenerated`, `:recorded`, `:unrecoverable`, `:unreadable`, `:skipped`,
  `:failed` or `:reconciled`. `{:error, :edit_in_progress}` while an image edit
  is rendering: the bytes are about to change.
  """

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileReport
  alias PhoenixKit.Modules.Storage.Locations
  alias PhoenixKit.Modules.Storage.Manager
  alias PhoenixKit.Modules.Storage.Reconciler
  alias PhoenixKit.Modules.Storage.VariantGenerator

  @passes 2

  @type action :: %{
          name: String.t(),
          kind: atom(),
          bucket: String.t() | nil,
          from: String.t() | nil
        }

  @spec repair(StorageFile.t(), keyword()) ::
          {:ok, %{actions: [action()], verification: [map()]}} | {:error, :edit_in_progress}
  def repair(file, opts \\ [])
  def repair(%StorageFile{edit_state: "pending"}, _opts), do: {:error, :edit_in_progress}

  def repair(%StorageFile{} = file, opts) do
    {actions, original_ok?} =
      Enum.reduce_while(1..@passes, {[], true}, fn pass, {done, _ok?} ->
        current = reload(file)
        # The first reading is what finds the damage; it is the one recorded.
        audit = if pass == 1, do: Keyword.put(opts, :found_by, "repair")
        {taken, original_ok?} = repair_objects(current, FileReport.verify(current, audit: audit))

        # A pass that did nothing leaves nothing for the next one.
        if taken == [],
          do: {:halt, {done, original_ok?}},
          else: {:cont, {done ++ taken, original_ok?}}
      end)

    current = reload(file)

    # Sizes and placements are the reconciler's. Not while the original is
    # damaged beyond repair: it would make sizes from bad bytes.
    reconcile =
      if original_ok?,
        do: [action("original", :reconciled, outcome: Reconciler.reconcile_file(current))],
        else: []

    actions = Enum.uniq_by(actions, &{&1.name, &1.kind, &1.bucket}) ++ reconcile
    verification = FileReport.verify(reload(file))

    # The trail: what was done to this file, and how much was still wrong.
    Audit.log_repair(current, actions, Enum.count(verification, &(&1.result != :ok)), opts)

    {:ok, %{actions: actions, verification: verification}}
  end

  # ── objects ───────────────────────────────────────────────────

  # One pass over the instances, the original first. `{actions, original_ok?}`.
  defp repair_objects(file, results) do
    instances = Storage.list_file_instances(file.uuid)
    by_name = Enum.group_by(results, & &1.name)
    expected = VariantGenerator.expected_variants(file)

    {ordered_originals, others} = Enum.split_with(instances, &(&1.variant_name == "original"))

    Enum.reduce(ordered_originals ++ others, {[], true}, fn instance, {done, original_ok?} ->
      rows = Map.get(by_name, instance.variant_name, [])
      {taken, healthy?} = repair_instance(file, instance, rows, expected, original_ok?)
      {done ++ taken, if(instance.variant_name == "original", do: healthy?, else: original_ok?)}
    end)
  end

  # `healthy?` is whether the instance has a good copy when this is done.
  defp repair_instance(file, instance, rows, expected, original_ok?) do
    %{good: good, bad: bad, unreadable: unreadable} = sort_copies(rows)
    name = instance.variant_name
    left = for b <- unreadable, do: action(name, :unreadable, bucket: b.name, bucket_uuid: b.uuid)

    # Every copy the records name is bad, but another bucket may hold a good one
    # nothing recorded (an object copied by hand, a location row never written).
    good = if good == [] and bad != [], do: good_elsewhere(file, instance, rows), else: good

    cond do
      # Nothing recorded: perhaps the object is there and only the row is missing.
      good == [] and bad == [] and unreadable == [] ->
        found_or_remake(file, instance, expected, original_ok?)

      bad == [] ->
        {left, good != []}

      good != [] ->
        {Enum.map(bad, &restore(instance, &1, hd(good))) ++ left, true}

      true ->
        remake(file, instance, expected, original_ok?, left)
    end
  end

  # The copies a verification found, by what they turned out to be.
  defp sort_copies(rows) do
    held = Enum.filter(rows, & &1.bucket)

    %{
      good: for(%{result: r, bucket: b} <- held, r == :ok or match?({:unrecorded, _}, r), do: b),
      bad: for(%{result: r, bucket: b} <- held, damaged?(r), do: b),
      unreadable: for(%{result: {:error, _}, bucket: b} <- held, do: b)
    }
  end

  defp found_or_remake(file, instance, expected, original_ok?) do
    case find_unrecorded(instance) do
      [] ->
        remake(file, instance, expected, original_ok?, [])

      found ->
        {Enum.map(
           found,
           &action(instance.variant_name, :recorded, bucket: &1.name, bucket_uuid: &1.uuid)
         ), true}
    end
  end

  # Enabled buckets the records do not name for this object that hold it with the
  # checksum it was stored with; each is recorded as a location.
  defp good_elsewhere(file, instance, rows) do
    recorded = FileReport.recorded_checksum(file, instance)
    named = for %{bucket: %{uuid: uuid}} <- rows, do: to_string(uuid)

    for bucket <- Storage.list_enabled_buckets(),
        to_string(bucket.uuid) not in named,
        recorded != nil,
        Manager.holds?(bucket, instance.file_name),
        match?({:ok, %{checksum: ^recorded}}, Manager.checksum_in(bucket, instance.file_name)) do
      Locations.record(instance.file_name, bucket.uuid)
      bucket
    end
  end

  defp damaged?(:not_found), do: true
  defp damaged?({:mismatch, _recorded, _actual}), do: true
  defp damaged?(_), do: false

  defp restore(instance, bad, good) do
    case Manager.copy_object(good, bad, instance.file_name) do
      :ok ->
        action(instance.variant_name, :restored,
          bucket: bad.name,
          bucket_uuid: bad.uuid,
          from: good.name,
          from_uuid: good.uuid
        )

      {:error, _reason} ->
        action(instance.variant_name, :failed,
          bucket: bad.name,
          bucket_uuid: bad.uuid,
          from: good.name,
          from_uuid: good.uuid
        )
    end
  end

  # No good copy. A size is made again from the original; the original, and
  # anything not made from a size (a burned copy), cannot be.
  defp remake(file, instance, expected, original_ok?, extra) do
    name = instance.variant_name

    case {name, Enum.find(expected, fn {_d, n, _f} -> n == name end)} do
      {"original", _} ->
        {[action(name, :unrecoverable) | extra], false}

      {_, nil} ->
        {[action(name, :unrecoverable) | extra], false}

      {_, _} when not original_ok? ->
        {[action(name, :skipped) | extra], false}

      {_, {dimension, name, format}} ->
        case VariantGenerator.generate_variant(file, dimension, name, format) do
          {:ok, _} -> {[action(name, :regenerated) | extra], true}
          _ -> {[action(name, :failed) | extra], false}
        end
    end
  end

  # Enabled buckets that hold the object although no location row says so; the
  # row is recorded for each.
  defp find_unrecorded(instance) do
    found =
      Enum.filter(Storage.list_enabled_buckets(), &Manager.holds?(&1, instance.file_name))

    Enum.each(found, &Locations.record(instance.file_name, &1.uuid))
    found
  end

  defp action(name, kind, opts \\ []) do
    %{
      name: name,
      kind: kind,
      bucket: opts[:bucket],
      bucket_uuid: opts[:bucket_uuid],
      from: opts[:from],
      from_uuid: opts[:from_uuid],
      outcome: opts[:outcome]
    }
  end

  defp reload(file), do: Storage.get_file(file.uuid) || file
end
