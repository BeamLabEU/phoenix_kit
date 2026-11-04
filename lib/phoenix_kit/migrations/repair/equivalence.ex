defmodule PhoenixKit.Migrations.Repair.Equivalence do
  @moduledoc """
  An index or key constraint that exists under another name.

  A manifest names its indexes and key constraints, and
  `PhoenixKit.Migrations.Repair.Probe.lookup/2` finds them by that name. A host
  whose object was created under an earlier name (a renamed module, or a rename
  that an old migration ran on some hosts and not on others) therefore reads as
  "missing", and a repair would build a second, identical object next to the
  one that is already there.

  `assign/3` looks for that twin for every declared object that is absent by
  name: an index, or a primary key, unique or foreign key constraint, on the same
  table, that the manifest does not name itself and whose structure is the one
  the manifest declares. "The same structure" is `Differ.compare/3` returning
  `:match`, nothing looser:

    * an index: uniqueness, access method, key columns, operator classes and
      predicate, and the column part of its definition (everything after
      `USING`), which carries what the key list does not: sort direction,
      `NULLS FIRST/LAST`, `COLLATE`, `INCLUDE` and `WITH (...)`;
    * a primary key or unique constraint: its type and columns;
    * a foreign key: its columns, the referenced table and columns, and the
      `ON DELETE` / `ON UPDATE` actions.

  A similar object is not a twin: a partial index with another predicate, a
  non-unique index where a unique one is declared, another column list, another
  referential action. Those stay `:missing`. CHECK and exclusion constraints are
  not looked for (their text, not a column list, is their identity).

  Rules that keep a real loss from being hidden:

    * An object the manifest names is never a twin. Its presence is judged by its
      own name, so two declared objects with one structure cannot stand in for
      each other. The names of every manifest count, core's and the modules'.
    * One object is the twin of at most one declared object, in the order the
      objects are applied. A host with a single unique index under a third name
      cannot answer for two declared ones.
    * An index that backs a primary key or unique constraint is not a candidate
      for an index, and a plain unique index is not a candidate for a unique
      constraint.
    * An index left invalid (`pg_index.indisvalid` false: what a failed
      `CREATE INDEX CONCURRENTLY` leaves behind) is not a candidate. The planner
      never uses it, so it answers for nothing, and the declared index still has
      to be built.

  Found by name, the name is the identity and the structure is only checked for
  drift; for a twin the structure is the only identity, so the index definition
  is compared too. The two texts are compared with the index name and the schema
  qualifier of the table (and of anything else in the text) left out, the
  `__SCHEMA__` token standing for that qualifier on a declaration that still
  carries it. A definition that cannot be read that way is not a twin.

  What is not compared: the validity, deferrability, `MATCH` type and
  `NULLS NOT DISTINCT` of a key constraint.

  A partial index whose predicate Postgres prints differently from the manifest
  (a major outside the verified range can) is not a twin: `Differ` cannot tell a
  re-printed predicate from a different one, and guessing wrong would hide a real
  loss. On such a host it stays `:missing`, as it did before this module.
  """

  alias PhoenixKit.Migrations.ExpectedSchema.Object
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Migrations.Repair.Scope

  @typedoc "What `claimed_names/1` returns: every index and constraint name a manifest declares."
  @type claimed :: MapSet.t()

  @typedoc "The kind and the name of the twin found."
  @type twin :: {:index | :constraint, String.t()}

  @key_constraint_types ["p", "u", "f"]

  @schema_token Object.schema_token()

  @doc """
  Every index and constraint name `objects` declare, as `{:index, name}` and
  `{:constraint, table, name}`. Index names are unique per schema, constraint
  names per table.
  """
  @spec claimed_names([Object.t()]) :: claimed()
  def claimed_names(objects) do
    for %{check: {:catalog, %{kind: kind} = spec}} <- objects,
        kind in [:index, :constraint],
        into: MapSet.new() do
      key(kind, spec, spec.name)
    end
  end

  defp key(:index, _spec, name), do: {:index, name}
  defp key(:constraint, %{table: table}, name), do: {:constraint, table, name}

  @doc """
  The twin of every declared object in `resolved` (`Scope.resolve/2` results, in
  the order they are applied) that is absent by name and has one, as a map from
  the object's id to the twin. `claimed` is `claimed_names/1`. A legacy-optional
  object never takes a twin.
  """
  @spec assign(Probe.snapshot(), [Scope.resolved()], claimed()) :: %{String.t() => twin()}
  def assign(snapshot, resolved, claimed) do
    {twins, _taken} = assign_taken(snapshot, resolved, claimed)
    twins
  end

  @doc """
  `assign/3`, and with the twins it handed out the names now taken: `claimed`
  plus one entry per twin. Pass that set as `claimed` of the next pass over the
  same snapshot (a module manifest after core's) so one object is never the twin
  of two declared objects.
  """
  @spec assign_taken(Probe.snapshot(), [Scope.resolved()], claimed()) ::
          {%{String.t() => twin()}, claimed()}
  def assign_taken(snapshot, resolved, claimed) do
    Enum.reduce(resolved, {%{}, claimed}, fn %{object: object, shape: shape}, {twins, taken} ->
      # A legacy-optional object is reported absent whatever is there, so it
      # takes no twin away from a required one.
      with false <- Map.get(object, :presence) == :legacy_optional,
           nil <- Probe.lookup(snapshot, object.check),
           {kind, name} = twin <- find(snapshot, object, shape, taken) do
        {_, spec} = object.check
        {Map.put(twins, object.id, twin), MapSet.put(taken, key(kind, spec, name))}
      else
        _ -> {twins, taken}
      end
    end)
  end

  @doc """
  The first object in `snapshot`, by name, that is a twin of `object` and is not
  in `excluded` (the claimed names, plus the twins already handed out), or `nil`.
  `expected` is the shape the run's scope selects for the object.
  """
  @spec find(Probe.snapshot(), Object.t(), map(), claimed()) :: twin() | nil
  def find(snapshot, object, expected, excluded)

  def find(
        snapshot,
        %{class: :index, check: {:catalog, %{table: table, name: name}}},
        expected,
        excluded
      ) do
    snapshot.indexes
    |> Enum.filter(fn {candidate, observed} ->
      candidate != name and observed.table == table and Map.get(observed, :valid, true) and
        not MapSet.member?(excluded, {:index, candidate})
    end)
    |> Enum.sort_by(fn {candidate, _observed} -> candidate end)
    |> Enum.find_value(fn {candidate, observed} ->
      if same_index?(expected, observed, table), do: {:index, candidate}
    end)
  end

  def find(
        snapshot,
        %{class: :constraint, check: {:catalog, %{table: table, name: name}}},
        %{type: type} = expected,
        excluded
      )
      when type in @key_constraint_types do
    snapshot.constraints
    |> Enum.filter(fn {{candidate_table, candidate}, observed} ->
      candidate_table == table and candidate != name and observed.type == type and
        not MapSet.member?(excluded, {:constraint, table, candidate})
    end)
    |> Enum.sort_by(fn {{_table, candidate}, _observed} -> candidate end)
    |> Enum.find_value(fn {{_table, candidate}, observed} ->
      if Differ.compare(:constraint, expected, observed) == :match, do: {:constraint, candidate}
    end)
  end

  def find(_snapshot, _object, _expected, _excluded), do: nil

  defp same_index?(expected, observed, table) do
    Differ.compare(:index, expected, observed) == :match and
      same_columns_part?(Map.get(expected, :definition), Map.get(observed, :definition), table)
  end

  # Everything after `USING` in `pg_get_indexdef`: method, columns with their
  # ordering and collation, INCLUDE, WITH, predicate. Reads `ON [ONLY] <schema>.<table>
  # USING <rest>`; the schema qualifier is whatever stands between `ON` and the
  # table, and the same qualifier is replaced by the token wherever else it
  # appears, so the two sides meet.
  defp same_columns_part?(expected, observed, table) do
    with {:ok, expected_part} <- columns_part(expected, table),
         {:ok, observed_part} <- columns_part(observed, table) do
      expected_part == observed_part
    else
      _ -> false
    end
  end

  defp columns_part(definition, table) when is_binary(definition) do
    pattern = ~r/ ON (?:ONLY )?(.+)\.#{Regex.escape(table)} USING (.*)\z/s

    case Regex.run(pattern, definition) do
      [_, qualifier, rest] -> {:ok, String.replace(rest, qualifier <> ".", @schema_token <> ".")}
      _ -> :error
    end
  end

  defp columns_part(_definition, _table), do: :error

  @doc """
  `snapshot` with every object of `objects` that is in scope at `bound`, absent
  by name and present under another, also listed under its own name.

  The version-marker cross-check asks "is everything introduced at version N
  there?" and a twin answers yes; without this a host with one renamed index
  would read as "comment ahead of schema" forever. It assigns twins with
  `assign/3`, in the same order `Repair` applies the objects.
  """
  @spec with_twins_as_present(Probe.snapshot(), [Object.t()], claimed(), pos_integer()) ::
          Probe.snapshot()
  def with_twins_as_present(snapshot, objects, claimed, bound) do
    {in_scope, _pending} = Scope.partition(objects, bound)

    resolved =
      in_scope
      |> Enum.map(&Scope.resolve(&1, bound))
      |> Enum.reject(&is_nil/1)
      |> Scope.execution_order()

    twins = assign(snapshot, resolved, claimed)

    Enum.reduce(resolved, snapshot, fn %{object: object}, acc ->
      case Map.fetch(twins, object.id) do
        {:ok, {kind, twin}} -> put_twin(acc, snapshot, kind, object, twin)
        :error -> acc
      end
    end)
  end

  defp put_twin(acc, snapshot, :index, %{check: {:catalog, %{name: name}}}, twin) do
    %{acc | indexes: Map.put(acc.indexes, name, Map.fetch!(snapshot.indexes, twin))}
  end

  defp put_twin(
         acc,
         snapshot,
         :constraint,
         %{check: {:catalog, %{table: table, name: name}}},
         twin
       ) do
    observed = Map.fetch!(snapshot.constraints, {table, twin})
    %{acc | constraints: Map.put(acc.constraints, {table, name}, observed)}
  end
end
