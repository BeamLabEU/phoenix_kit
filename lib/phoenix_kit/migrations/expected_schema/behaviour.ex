defmodule PhoenixKit.Migrations.ExpectedSchema.Behaviour do
  @moduledoc """
  The manifest contract every `PhoenixKit.Migrations.ExpectedSchema`
  implementation satisfies — this is the entry point for the whole
  verify-and-repair design (spec §5.1/§6.1).

  ## Why this module exists (and why it is not called `ExpectedSchema`)

  `PhoenixKit.Migrations.ExpectedSchema` is the name of the **tool-generated**
  manifest (`dev_docs/squash/generate_baseline.exs`'s `Emitter.render_manifest/2`,
  frozen from P1) — a real migrated scratch database, one incremental
  per-version catalog diff at a time (spec §5.1/§8.3). It does not exist in
  this repository yet; it lands with the squash PR (P3), `@moduledoc false`
  (a manifest spanning the whole `V01..@current_version` chain is too large
  to be a useful hexdocs page, and it is regenerated — never hand-edited — so
  there is nothing there worth documenting in place).

  This module — and its siblings
  `PhoenixKit.Migrations.ExpectedSchema.Object` and
  `PhoenixKit.Migrations.ExpectedSchema.DataInvariant` — is the **public docs
  surface** for that contract, deliberately namespaced *underneath*
  `ExpectedSchema` rather than reusing that exact name: once the real
  generated module lands at `lib/phoenix_kit/migrations/expected_schema.ex`,
  it is a single generated file that replaces its own previous contents
  wholesale on every regeneration ("never hand-merged" per spec §8.3) — a
  docs/behaviour module living at that same name and path would be silently
  destroyed the first time the squash PR's generation step runs. Living at
  `expected_schema/behaviour.ex` instead means both files coexist forever:
  the generated module supplies the data, this one documents the shape.

  ## The three callbacks

  Every implementation — the real generated manifest, and any test fixture
  such as `PhoenixKit.Test.FixtureExpectedSchema` — exports exactly these
  three functions. `objects/1` and `data_invariants/1` take a
  `prefix` because both return SQL text/specs anchored to a specific Postgres
  schema (spec §5.1's `"__SCHEMA__"` substitution); `chain_hash/0` does not,
  because it hashes the `v*.ex` migration file set itself, which has no
  notion of a runtime prefix.

  A hand-written implementation should:

    1. `use Ecto.Migration`-style raw SQL/data as a *private* "raw" list,
       written with `PhoenixKit.Migrations.ExpectedSchema.Object.schema_token/0`
       (`"__SCHEMA__"`) standing in for the prefix and the atom `:prefix`
       standing in for a helper-call argument that needs it (see
       `Object`'s "Helper creates" section);
    2. normalize the incoming `prefix` once, via
       `Object.normalize_prefix/1`;
    3. materialize every raw object/invariant against that prefix via
       `Object.materialize/2` / `DataInvariant.materialize/2`.

  `PhoenixKit.Test.FixtureExpectedSchema` follows exactly this shape and is a
  runnable reference alongside these docs.

      @behaviour PhoenixKit.Migrations.ExpectedSchema.Behaviour

      @impl PhoenixKit.Migrations.ExpectedSchema.Behaviour
      def objects(prefix) do
        prefix = Object.normalize_prefix(prefix)
        Enum.map(raw_objects(), &Object.materialize(&1, prefix))
      end

      @impl PhoenixKit.Migrations.ExpectedSchema.Behaviour
      def data_invariants(prefix \\ "public") do
        prefix = Object.normalize_prefix(prefix)
        Enum.map(raw_data_invariants(), &DataInvariant.materialize(&1, prefix))
      end

      @impl PhoenixKit.Migrations.ExpectedSchema.Behaviour
      def chain_hash, do: @chain_hash

  ## Finding the concrete module

  Nothing in P2 calls `PhoenixKit.Migrations.ExpectedSchema` (or any other
  implementation) by name directly — go through
  `PhoenixKit.Migrations.ExpectedSchema.Resolver.resolve/0`. It degrades
  gracefully (`{:error, :not_generated}`) for the whole of P2, since the real
  module does not exist until P3's scratch-DB generation step runs, and lets
  tests substitute a fixture via
  `Application.put_env(:phoenix_kit, :expected_schema_module, ...)`.

  ## The real generated module does not declare `@behaviour` here

  The Emitter's template (`Emitter.render_manifest/2`) emits `def objects/1`,
  `def data_invariants/1`, `def chain_hash/0` directly with no
  `@behaviour PhoenixKit.Migrations.ExpectedSchema.Behaviour` line — P1 is
  frozen, so that will still be true once the real module lands in P3. The
  compiler's callback-completeness warning therefore never fires for it.
  `Resolver` compensates by checking conformance structurally at runtime
  (exported-function membership) rather than relying on `@behaviour`
  declaration — see `PhoenixKit.Migrations.ExpectedSchema.Object`'s
  moduledoc, deviation 4, for the full reasoning. Hand-written
  implementations should still declare `@behaviour` (as shown above and in
  the fixture) for the free compile-time check on top of that.
  """

  alias PhoenixKit.Migrations.ExpectedSchema.DataInvariant
  alias PhoenixKit.Migrations.ExpectedSchema.Object

  @doc """
  Every tracked schema object, materialized for `prefix`.

  `prefix` is `nil` (normalizes to `"public"`) or a validated schema name
  (`PhoenixKit.Migrations.Postgres.Helpers.validate_prefix!/1` — raises
  `ArgumentError` for anything unsafe to interpolate into SQL, same as every
  migration entry point).

  Deterministic: two calls with the same `prefix` return `==` lists (the
  generator sorts by `{since, class, id}` at emission time; a hand-written
  implementation should preserve that or any other fixed order — callers must
  not depend on a *particular* order, only on it being stable across calls).
  """
  @callback objects(prefix :: String.t() | nil) :: [Object.t()]

  @doc """
  Every data invariant (spec §5.1's upgrade-only-transform assertions),
  materialized for `prefix`. See `PhoenixKit.Migrations.ExpectedSchema.DataInvariant`.

  Same `prefix` contract as `objects/1`. Declared at arity 1 (not the spec
  §5.1 pseudocode's arity 0) because `:assert` SQL is schema-anchored the same
  way `objects/1`'s SQL is — see `Object`'s moduledoc, deviation 5.
  """
  @callback data_invariants(prefix :: String.t() | nil) :: [DataInvariant.t()]

  @doc """
  SHA-256 (lower-hex) over the sorted `v*.ex` migration file set at the time
  this module was generated — the staleness detector (spec §5.1/§8.3):
  `mix phoenix_kit.release_check` and a plain DB-free unit test both assert
  this still matches a fresh hash of the on-disk chain, catching "a migration
  was added but the manifest was not regenerated" before it reaches a
  release. Takes no `prefix` — the migration file set has no per-install
  variation.
  """
  @callback chain_hash() :: String.t()
end
