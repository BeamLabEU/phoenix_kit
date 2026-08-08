defmodule PhoenixKit.Migrations.Repair.Executor do
  @moduledoc """
  Turns one `PhoenixKit.Migrations.Repair.Scope.resolved()` into the SQL to
  run, and (in real repair mode) runs it — additive-only, statement-at-a-time,
  autocommit, spec §6.2/§6.3.

  ## Two halves, deliberately split

  `create_action/2` is **pure** — no `repo` argument, cannot touch a
  database — and is the whole "what SQL would this be" answer:
  `PhoenixKit.Migrations.Repair.verify/1` (and a dry-run `.repair/1`) call
  only this half, so `--dry-run` genuinely cannot write anything by
  construction, not by discipline. `test/phoenix_kit/migrations/repair/executor_test.exs`
  asserts exact statement text against it — the "SQL-generation assertions
  without executing" the plan calls for. `create/3` is the executing half;
  it has no unit test (no database in this suite).

  ## Additive-only rules this module enforces (spec §6.2)

  Never `DROP`, `ALTER TYPE`, `SET`/`DROP NOT NULL` on a pre-existing column,
  `UPDATE`/`DELETE` user data, rename, or touch anything outside
  `phoenix_kit*` — none of those verbs appear anywhere below. The one
  `UPDATE` this module ever issues (`backfill/4`) only ever targets `WHERE
  "<col>" IS NULL` on a column this same call **just added** in the
  immediately preceding statement (spec D7) — never a pre-existing column,
  never rows that already have a value.

  ## FK `NOT VALID` + `VALIDATE` (spec §6.3)

  For every foreign key (`shape.type == "f"`), `create_action/2` always adds
  ` NOT VALID` to the `ADD CONSTRAINT` — regardless of whether the manifest's
  own precomputed `object.create` would have (it never does; V113 is the
  in-chain precedent for the two-step). `create/3` follows a successful
  `ADD` with a separate `VALIDATE CONSTRAINT` statement; a validation
  failure leaves the constraint `NOT VALID` (per spec — never dropped, never
  retried) and reports an orphan-row count via
  `PhoenixKit.Migrations.Repair.Probe.orphan_count/6`.
  """

  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Migrations.Repair.Scope
  alias PhoenixKit.Migrations.Repair.ShapeSql

  @typedoc "What happened (or, from `create_action/2` alone, would be attempted)."
  @type outcome ::
          :created
          | :already_present
          | :best_effort_skipped
          | {:create_failed, String.t()}
          | {:fk_validation_failed, String.t()}

  @duplicate_codes [:duplicate_object, :duplicate_column, :duplicate_table, :duplicate_function]

  @doc """
  The create action for one resolved object — `nil` (nothing to create;
  `:legacy_optional`), a SQL string, or `{:helper, {mod, fun, args}}`. Pure.

  Dispatches on class exactly as `PhoenixKit.Migrations.Repair.ShapeSql`'s
  moduledoc describes: `:column`/`:index`/`:constraint` are always rebuilt
  from `resolved.shape` (never `resolved.object.create`, which is the
  newest-revision precomputed field and NOT VALID-less for every FK); every
  other class uses the object's own precomputed `create` (revision-blind by
  design, matching the generator).

      iex> resolved = %{
      ...>   object: %{class: :column, check: {:catalog, %{kind: :column, table: "widgets", column: "name"}}},
      ...>   shape: %{type: "text", not_null: false, default: nil}
      ...> }
      iex> Executor.create_action(resolved, "public")
      ~s(ALTER TABLE public.widgets ADD COLUMN IF NOT EXISTS "name" text)
  """
  @spec create_action(Scope.resolved(), prefix :: String.t()) ::
          nil | String.t() | {:helper, {module(), atom(), [term()]}}
  def create_action(%{object: %{presence: :legacy_optional}}, _prefix), do: nil

  def create_action(%{object: %{class: :column} = object, shape: shape}, prefix) do
    {table, column} = catalog_table_column(object)
    ShapeSql.column_create(prefix, table, column, shape)
  end

  def create_action(%{object: %{class: :index}, shape: shape}, _prefix) do
    ShapeSql.index_create(shape)
  end

  def create_action(%{object: %{class: :constraint} = object, shape: shape}, prefix) do
    {table, name} = catalog_table_name(object)

    ShapeSql.constraint_create(prefix, table, name, shape,
      not_valid: Map.get(shape, :type) == "f"
    )
  end

  def create_action(%{object: object}, _prefix), do: object.create

  @doc """
  Runs `create_action/2` for real: executes a SQL string immediately
  (`repo.query!/3`, autocommit), invokes a `{:helper, mfa}`, or reports
  `:already_present` for `nil`. Column creates backfill their own default on
  success (spec D7); FK constraint creates follow with `VALIDATE CONSTRAINT`
  on success — unless `skip_validate?` is `true` (§6.3's `--unsafe-pooled`:
  the constraint is added `NOT VALID` and left there, deliberately, without
  ever attempting the VALIDATE statement against a connection that cannot
  safely hold the advisory lock either).
  """
  @spec create(Ecto.Repo.t(), Scope.resolved(), prefix :: String.t(), skip_validate? :: boolean()) ::
          outcome()
  def create(repo, resolved, prefix, skip_validate? \\ false) do
    case create_action(resolved, prefix) do
      nil -> :already_present
      {:helper, mfa} -> run_helper(repo, mfa, resolved.object.class)
      sql when is_binary(sql) -> run_sql_create(repo, resolved, sql, prefix, skip_validate?)
    end
  end

  defp run_sql_create(
         repo,
         %{object: %{class: :constraint} = object, shape: %{type: "f"} = shape},
         sql,
         prefix,
         skip_validate?
       ) do
    case execute_statement(repo, sql) do
      :created -> if skip_validate?, do: :created, else: validate_fk(repo, object, shape, prefix)
      other -> other
    end
  end

  defp run_sql_create(
         repo,
         %{object: %{class: :index}, shape: %{unique: true} = shape},
         sql,
         prefix,
         _skip_validate?
       ) do
    case execute_statement(repo, sql) do
      {:create_failed, msg} -> {:create_failed, msg <> duplicate_diagnostic(repo, shape, prefix)}
      other -> other
    end
  end

  defp run_sql_create(
         repo,
         %{object: %{class: :column} = object, shape: shape},
         sql,
         prefix,
         _skip_validate?
       ) do
    case execute_statement(repo, sql) do
      :created -> backfill(repo, object, shape, prefix)
      other -> other
    end
  end

  defp run_sql_create(repo, _resolved, sql, _prefix, _skip_validate?),
    do: execute_statement(repo, sql)

  defp validate_fk(repo, object, shape, prefix) do
    {table, name} = catalog_table_name(object)

    case execute_statement(repo, ShapeSql.validate_constraint(prefix, table, name)) do
      :created ->
        :created

      :already_present ->
        :created

      {:create_failed, msg} ->
        {:fk_validation_failed, msg <> orphan_diagnostic(repo, table, shape, prefix)}
    end
  end

  defp orphan_diagnostic(
         repo,
         table,
         %{
           columns: [fk_column | _],
           foreign_table: foreign_table,
           foreign_columns: [foreign_column | _]
         },
         prefix
       )
       when is_binary(fk_column) and is_binary(foreign_table) and is_binary(foreign_column) do
    case Probe.orphan_count(repo, prefix, table, fk_column, foreign_table, foreign_column) do
      :unknown -> " (orphan count unavailable)"
      count -> " (#{count} orphaned row(s) referencing #{foreign_table})"
    end
  end

  defp orphan_diagnostic(_repo, _table, _shape, _prefix), do: " (orphan count unavailable)"

  defp backfill(_repo, %{backfill: nil}, _shape, _prefix), do: :created

  defp backfill(repo, %{backfill: :default} = object, shape, prefix) do
    {table, column} = catalog_table_column(object)

    sql =
      ~s(UPDATE #{prefix}.#{table} SET "#{column}" = #{shape.default} WHERE "#{column}" IS NULL)

    case execute_statement(repo, sql) do
      :created -> :created
      :already_present -> :created
      {:create_failed, msg} -> {:create_failed, "column added but backfill failed: " <> msg}
    end
  end

  defp duplicate_diagnostic(repo, %{table: table, keys: [key | _]}, prefix) do
    # Same identifier-format guard `PhoenixKit.Migrations.Repair.Probe.orphan_count/6`
    # applies before interpolating its own manifest-derived names — both draw
    # from equally trusted, generator-controlled data today, but this keeps
    # the two call sites consistent rather than one silently losing the
    # defense the other keeps. Raising here is caught by this function's own
    # `rescue` below, same as any other diagnostic-building failure —
    # collapsing to "" (an omitted diagnostic suffix) rather than crashing
    # the repair pipeline over a best-effort diagnostic string.
    for ident <- [prefix, table, key] do
      unless is_binary(ident) and Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, ident) do
        raise ArgumentError, "unsafe SQL identifier in duplicate_diagnostic: #{inspect(ident)}"
      end
    end

    query = """
    SELECT count(*)::integer FROM (
      SELECT "#{key}" FROM #{prefix}.#{table} GROUP BY "#{key}" HAVING count(*) > 1
    ) dupes
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[count]]}} when count > 0 -> " (#{count} duplicate group(s) on #{key})"
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp duplicate_diagnostic(_repo, _shape, _prefix), do: ""

  defp execute_statement(repo, sql) do
    repo.query!(sql, [], log: false)
    :created
  rescue
    e in Postgrex.Error -> classify_error(e)
  end

  defp classify_error(%Postgrex.Error{postgres: %{code: code}}) when code in @duplicate_codes do
    :already_present
  end

  defp classify_error(%Postgrex.Error{} = e), do: {:create_failed, Exception.message(e)}

  # class == :seed → best-effort, swallow-all (v15/v31 lineage): an absent
  # OR failing optional module is a silent no-op, never a `:create_failed`.
  defp run_helper(_repo, {mod, fun, args}, :seed) do
    case Code.ensure_loaded(mod) do
      {:module, _} ->
        try do
          apply(mod, fun, args)
          :created
        rescue
          _ -> :best_effort_skipped
        catch
          _, _ -> :best_effort_skipped
        end

      {:error, _} ->
        :best_effort_skipped
    end
  end

  # Every other helper class (extension/function) is NOT best-effort — a
  # real failure (a privilege error, say) must surface loudly. `Helpers`
  # ships BOTH a migration-context arity (implicitly calls
  # `Ecto.Migration.repo()`, which only resolves inside an active
  # migration — unusable here) and a runtime-context arity taking `repo`
  # explicitly (`ensure_extension!/2`, `ensure_uuid_v7_function/2` — the
  # same variants the retired `UUIDRepair` used before the squash made its
  # sub-V40 gate unreachable). The manifest's
  # `{:helper, mfa}` shape carries the migration-context arity's `args`
  # (e.g. `[name]`, not `[repo, name]` — it has no way to know which variant
  # a given runtime caller needs), so this dispatch tries `arity + 1` first
  # (repo prepended — resolves to the runtime variant when one exists) and
  # falls back to the literal `args` otherwise (a hypothetical helper with
  # no runtime variant at all).
  defp run_helper(repo, {mod, fun, args}, _class) do
    arity = length(args)

    cond do
      function_exported?(mod, fun, arity + 1) -> apply(mod, fun, [repo | args])
      function_exported?(mod, fun, arity) -> apply(mod, fun, args)
      true -> raise "helper #{inspect(mod)}.#{fun} not exported at arity #{arity} or #{arity + 1}"
    end

    :created
  rescue
    # A race between repair and a concurrently-running migration creating the
    # same extension/function (`postgres.ex` does not yet share repair's
    # advisory lock — this module's own moduledoc) can surface as a
    # duplicate-object-class Postgrex error from inside the helper, exactly
    # like a raw-SQL create's race does — reuse `classify_error/1` so it
    # reclassifies to `:already_present` here too, instead of the generic
    # catch-all misreporting a harmless race as an error-severity
    # `:create_failed`. Any OTHER exception (e.g. the `raise` above, for an
    # unexported helper) still falls through to the generic clause.
    e in Postgrex.Error -> classify_error(e)
    e -> {:create_failed, Exception.message(e)}
  catch
    kind, reason -> {:create_failed, Exception.format(kind, reason)}
  end

  # See `PhoenixKit.Migrations.Repair.Scope.resolve/2` — `object.check`'s
  # catalog spec carries `table`/`column`/`name` structurally for exactly
  # this purpose; never parse `object.id` (documented as an internal
  # convention on `Object`, not a stable format to split apart).
  defp catalog_table_column(%{check: {:catalog, %{table: table, column: column}}}),
    do: {table, column}

  defp catalog_table_name(%{check: {:catalog, %{table: table, name: name}}}),
    do: {table, name}
end
