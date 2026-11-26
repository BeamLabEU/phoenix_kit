# generate_module_manifest.exs — the ExpectedSchema manifest of ONE module's tables.
#
# Plan: dev_docs/plans/2026-10-25-module-table-ownership.md, step 7b.
#
# A module ships a generated module implementing
# `PhoenixKit.Migrations.ExpectedSchema.Behaviour` and returns it from
# `PhoenixKit.Module.expected_schema/0`; `mix phoenix_kit.repair` / `doctor` then
# check the module's tables as they do core's. This script writes that file.
#
# What it does, in a scratch schema:
#
#   1. builds core's chain, drops the module's tables, and runs the module's own
#      chain alone (`PhoenixKit.TestSupport.ModuleChainCheck.build_alone/4`) —
#      the state a host has once core no longer creates the module's tables;
#   2. takes the catalog snapshot the core generator uses (`Catalog.snapshot/2`)
#      and keeps the module's tables with their columns, indexes, constraints
#      and sequences;
#   3. renders them through the core generator's own emitter, one revision per
#      object at version 1: a module manifest describes the chain head only, and
#      repair checks it only while the database is at that head.
#
# Unlike generate_baseline.exs this needs no pre-squash checkout and no pg_dump:
# catalog queries only.
#
# Run from core, MIX_ENV=test, with the usual PG* env (a direct connection):
#
#   MIX_ENV=test mix run dev_docs/squash/generate_module_manifest.exs \
#     --migrations PhoenixKitCustomerSupport.Migrations \
#     --source ../phoenix_kit_customer_support/lib/phoenix_kit_customer_support/migrations.ex \
#     --module PhoenixKitCustomerSupport.ExpectedSchema \
#     --app phoenix_kit_customer_support \
#     --output ../phoenix_kit_customer_support/lib/phoenix_kit_customer_support/expected_schema.ex
#
# `--exclude constraint:TABLE.NAME` (repeatable) leaves out an object the chain only
# adds where another package's table exists (a guarded foreign key).
#
# `--source` is repeatable (a file, or a directory searched for *.ex): everything
# the migrations module needs to compile on its own. Offline gate:
#
#   MIX_ENV=test mix run --no-start dev_docs/squash/generate_module_manifest.exs --check

System.put_env("PK_GEN_LIBRARY", "1")
Code.require_file(Path.join(__DIR__, "generate_baseline.exs"))

defmodule PhoenixKit.Squash.GenerateModule do
  @moduledoc false

  alias PhoenixKit.Migrations.ModuleOwnedTables
  alias PhoenixKit.Squash.Generate.Catalog
  alias PhoenixKit.Squash.Generate.Differ
  alias PhoenixKit.Squash.Generate.Emitter
  alias PhoenixKit.Squash.RepoHelper
  alias PhoenixKit.TestSupport.ModuleChainCheck

  @usage """
  generate_module_manifest.exs --migrations Mod --source PATH... --module Mod --app APP --output FILE
  generate_module_manifest.exs --check
  """

  def main(argv) do
    {opts, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          check: :boolean,
          migrations: :string,
          source: [:string, :keep],
          module: :string,
          app: :string,
          output: :string,
          schema: :string,
          exclude: [:string, :keep]
        ]
      )

    cond do
      rest != [] or invalid != [] -> raise ArgumentError, "bad arguments\n\n" <> @usage
      opts[:check] -> check()
      true -> generate(config!(opts))
    end
  end

  defp config!(opts) do
    for key <- [:migrations, :module, :app, :output], is_nil(opts[key]) do
      raise ArgumentError, "missing --#{key}\n\n" <> @usage
    end

    sources = Keyword.get_values(opts, :source)
    if sources == [], do: raise(ArgumentError, "missing --source\n\n" <> @usage)

    %{
      migrations: Module.concat([opts[:migrations]]),
      module: opts[:module],
      app: String.to_atom(opts[:app]),
      output: opts[:output],
      sources: sources,
      exclude: Keyword.get_values(opts, :exclude),
      schema:
        opts[:schema] || "pk_modgen_" <> Integer.to_string(System.unique_integer([:positive]))
    }
  end

  def generate(config) do
    compile_sources!(config.sources)
    repo = RepoHelper.start!()

    try do
      {:ok, tables} = build!(repo, config)
      snapshot = repo |> Catalog.snapshot(config.schema) |> keep_tables(tables, config.exclude)
      source = render(snapshot, config)

      File.write!(config.output, source)
      IO.puts("wrote #{config.output} (#{map_size(snapshot.tables)} tables)")
    after
      repo.query!(~s(DROP SCHEMA IF EXISTS "#{config.schema}" CASCADE), [], log: false)
    end
  end

  defp build!(repo, config) do
    # The migrations module is not part of a loaded OTP app here, so its tables
    # come from core's ownership map, like `ModuleChainCheck.check/3` for a module.
    tables = ModuleOwnedTables.tables_for(config.app)

    case ModuleChainCheck.build_alone(repo, config.migrations, config.schema, tables: tables) do
      {:ok, tables} -> {:ok, tables}
      {:error, message} -> raise message
    end
  end

  defp compile_sources!(sources) do
    sources
    |> Enum.flat_map(fn path ->
      if File.dir?(path), do: Path.wildcard(Path.join(path, "**/*.ex")), else: [path]
    end)
    |> Enum.sort()
    |> Kernel.ParallelCompiler.compile(return_diagnostics: true)
    |> case do
      {:ok, _modules, _warnings} -> :ok
      {:error, errors, _warnings} -> raise "cannot compile --source: #{inspect(errors)}"
    end
  end

  # The snapshot covers the whole scratch schema, core's tables included.
  def keep_tables(snapshot, tables, exclude \\ []) do
    tables = MapSet.new(tables)
    present = snapshot.tables |> Map.keys() |> Enum.filter(&MapSet.member?(tables, &1))
    own? = &(&1 in present)

    %{
      tables: Map.take(snapshot.tables, present),
      columns: Map.filter(snapshot.columns, fn {{table, _}, _} -> own?.(table) end),
      indexes: Map.filter(snapshot.indexes, fn {_, shape} -> own?.(shape.table) end),
      constraints:
        Map.filter(snapshot.constraints, fn {{table, name}, _} ->
          own?.(table) and "constraint:#{table}.#{name}" not in exclude
        end),
      sequences:
        Map.filter(snapshot.sequences, fn {name, _} ->
          Enum.any?(present, &String.starts_with?(name, &1 <> "_"))
        end),
      functions: %{},
      extensions: %{},
      seeds: %{}
    }
  end

  def render(snapshot, config) do
    history = Differ.history([{1, snapshot}])
    %{objects: objects} = Differ.catalog(history, snapshot)

    # `inspect/1` alone cuts lists at 50 items and strings at 4096 bytes, so
    # an object added past the 50th (the catalogue's V7) left the hash as it
    # was. Unlimited, the text covers every object; for a manifest that was
    # never cut it is the same text as before, so its hash does not move.
    hash =
      :crypto.hash(
        :sha256,
        inspect(Emitter.build_objects(objects, owner: config.app),
          limit: :infinity,
          printable_limit: :infinity
        )
      )
      |> Base.encode16(case: :lower)

    meta = %{initial: 1, current: 1, file_count: 0, chain_hash: hash}

    Emitter.render_manifest(objects, meta,
      module: config.module,
      owner: config.app,
      invariants: [],
      header: header(config)
    )
  end

  defp header(config) do
    """
      # Generated by core's dev_docs/squash/generate_module_manifest.exs — DO NOT EDIT,
      # regenerate. It describes the tables #{inspect(config.migrations)} builds, as the
      # chain leaves them at its current version, and is what `mix phoenix_kit.repair`
      # and `mix phoenix_kit.doctor` check them against
      # (`PhoenixKit.Module.expected_schema/0`).
      #
      # One revision per object: repair checks this manifest only while the database is
      # at the chain's current version, never against an older shape. `chain_hash/0` is a
      # fingerprint of the objects below, not of the migration files.
      #
      # Regenerate after any change to the chain:
      #
      #   cd <phoenix_kit> && MIX_ENV=test mix run dev_docs/squash/generate_module_manifest.exs \\
      #     --migrations #{inspect(config.migrations)} --source <migrations source> \\
      #     --module #{config.module} --app #{config.app} --output <this file>
    """
  end

  def check do
    snapshot = %{
      tables: %{"t_a" => %{}, "core_x" => %{}},
      columns: %{
        {"t_a", "uuid"} => %{type: "uuid", not_null: true, default: nil, pos: 1},
        {"core_x", "id"} => %{type: "integer", not_null: true, default: nil, pos: 1}
      },
      indexes: %{},
      constraints: %{},
      sequences: %{},
      functions: %{},
      extensions: %{},
      seeds: %{}
    }

    kept = keep_tables(snapshot, ["t_a"])
    true = Map.keys(kept.tables) == ["t_a"] and map_size(kept.columns) == 1

    with_fk =
      put_in(snapshot.constraints, %{{"t_a", "t_a_fkey"} => %{}, {"t_a", "t_a_pkey"} => %{}})

    true = Map.keys(keep_tables(with_fk, ["t_a"]).constraints) |> length() == 2

    true =
      Map.keys(keep_tables(with_fk, ["t_a"], ["constraint:t_a.t_a_fkey"]).constraints) ==
        [{"t_a", "t_a_pkey"}]

    config = %{migrations: Some.Migrations, module: "Some.ExpectedSchema", app: :some_app}
    source = render(kept, config)
    Code.string_to_quoted!(source)
    true = source =~ "defmodule Some.ExpectedSchema"
    true = source =~ "owner: :some_app"
    true = source == render(kept, config)

    IO.puts("OK generate_module_manifest.exs --check")
  end
end

PhoenixKit.Squash.GenerateModule.main(System.argv())
