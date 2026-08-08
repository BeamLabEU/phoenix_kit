#!/usr/bin/env elixir
# verify.exs — scenario harness for the migration squash
# (spec: dev_docs/plans/2026-07-14-squash-migrations-spec.md, sections 8.2 + 8.3).
#
# Offline smoke gate (compiles everything, runs helper self-checks, no DB):
#
#     MIX_ENV=test mix run --no-start dev_docs/squash/verify.exs --check
#
# Scenario runs (need an operator scratch DB, spec section 8.1):
#
#     PGHOST=172.18.0.13 PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=... \
#     PK_SQUASH_FLOOR=121 \
#     MIX_ENV=test mix run dev_docs/squash/verify.exs --mode b --scenario s1_self,s2_self
#
# Full env contract + scenario table: dev_docs/squash/README.md.

Code.require_file(Path.join(__DIR__, "repo_helper.ex"))
Code.require_file(Path.join(__DIR__, "dump_helper.ex"))
Code.require_file(Path.join(__DIR__, "migration_runner.ex"))
Code.require_file(Path.join(__DIR__, "s5_fixtures.ex"))

# S5(iv) uses ExUnit.CaptureIO to pin the clamped-down desync warning (spec
# 5.2) — that needs ExUnit's own supervision tree (ExUnit.CaptureServer)
# running, which `mix run` does not start on its own (only `mix test` does).
# `autorun: false`: this script defines no ExUnit.Case modules, so there is
# nothing to auto-run either way — explicit for clarity.
ExUnit.start(autorun: false)

defmodule PhoenixKit.Squash.Verify do
  @moduledoc """
  Scenario harness implementing the spec's S1-S13/S15-S20 matrix (S14 is the
  DB-free gate suite — `mix precommit` / `mix phoenix_kit.release_check` — and
  deliberately not a verify.exs scenario).

  Every scenario emits one machine-readable line:

      RESULT <id> PASS | FAIL | ERROR | SKIP:<reason-slug>

  Scenarios whose prerequisites have not landed yet (P2 repair engine /
  manifest, P3 squashed registry / `BelowFloorError`, saved reference dumps)
  are present as SKIP stubs and light up as the phases land — the harness is
  runnable at every stage. Exit code: 0 when nothing FAILed/ERRORed
  (SKIPs are fine), 1 otherwise, 2 for configuration/usage errors.

  S21 is a later addition, not part of the original spec's numbered S1-S20
  matrix: it proves `PhoenixKit.Migrations.Postgres.V164` (the repair for
  the historical V56/V57 flush-order defect, see that module's own
  moduledoc) actually repairs a damaged database, restores idempotently,
  and grants an orphan-blocked FK the documented NOT VALID grace — none of
  which had any automated coverage before it.

  S22 is likewise a later addition. S1 proves fresh-install equivalence for
  a SINGLE multi-version invocation; S3 proves an upgrade from the floor
  lands on the same schema. Neither ever runs a delta in its OWN separate
  `Ecto.Migrator` invocation the way a real consumer app applies pending
  migrations one file at a time — which is exactly the shape the historical
  V56/V57 defect took (misbehaving only when several versions ran inside
  ONE migrator invocation). A version added later that reintroduces that
  class would stay green under every other scenario here; S22 proves
  per-version stepping is equivalent to a single combined invocation.

  ## Modes

  * `--mode b` (default) — throwaway named schemas inside `PGDATABASE`;
    `public` is never touched. Safe against any scratch DB.
  * `--mode a` — sequential clean-DB runs in `public`; side-by-side
    comparisons are achieved by dump-then-reset-then-rerun, where reset is
    `DROP SCHEMA public CASCADE; CREATE SCHEMA public` (spec section 8.1
    option (b) recipe). Destructive by design, therefore gated:
    `PK_SQUASH_ALLOW_RESET` must equal the `PGDATABASE` name.

  ## Cleanup guarantee

  Scratch schemas a scenario creates are registered BEFORE creation and
  dropped in an `after` block — exceptions cannot leak them (the June 2026
  draft leaked schemas on every scenario crash). `--verbose` opts out of
  cleanup (retains schemas and dumps for inspection); the persistent
  below-floor handoff schema of `s4_seed` is exempt by design.
  """

  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Postgres.V164
  alias PhoenixKit.Migrations.Repair
  alias PhoenixKit.Migrations.Repair.Environment, as: RepairEnvironment
  alias PhoenixKit.Migrations.Repair.Report
  alias PhoenixKit.Migrations.UUIDFKColumns
  alias PhoenixKit.Squash.DumpHelper
  alias PhoenixKit.Squash.MigrationRunner
  alias PhoenixKit.Squash.RepoHelper
  alias PhoenixKit.Squash.S5Fixtures

  @script_dir __DIR__

  # Committed :legacy_optional whitelist (spec sections 3.7 + 8.2 S1): objects
  # whose presence is bimodal between single-run and incrementally-upgraded
  # old-chain installs. Override with PK_SQUASH_WHITELIST (comma-separated;
  # set empty for strict mode). Any diff NOT covered by this list is a failure.
  #
  # - preferred_locale (+ its index): V28 adds them; V30's immediate-query
  #   guard misses V28's queued add on single-run installs, so fresh
  #   single-run chains RETAIN both while upgraded installs do not.
  # - V13's partial unique index on email_logs.aws_message_id: duplicated by
  #   V22's `_uidx`; the baseline keeps exactly one (V22's name), so V13's
  #   name is presence-optional.
  # - The last three entries are bimodal by INSTALL PATH, not by run shape,
  #   and are the reason `--mode a` exists (found by it, 2026-08-08). Two
  #   pre-squash migrations are prefix-unsafe: V68's `DROP INDEX IF EXISTS
  #   idx_publishing_posts_group_slug` is not schema-qualified, so in `public`
  #   it replaced the index with the intended partial one while in a named
  #   schema it silently found nothing and the following `CREATE ... IF NOT
  #   EXISTS` silently did nothing either; the same class of accident left the
  #   unique index on subscription_types.slug named `..._types_slug_uidx` on
  #   the public path and `..._plans_slug_uidx` on the named path. The baseline
  #   was generated from a NAMED-schema replay, so it carries the named-path
  #   shapes; V164 normalizes every install onto the public/intended shapes
  #   (a no-op on real public installs).
  #
  #   These three are belt-and-braces, NOT load-bearing: measured on
  #   2026-08-08, with a bridge checkout that carries V164, both modes compare
  #   exactly on these objects and the only tolerated diff in `--mode a` was
  #   `preferred_locale` (+ its index). They exist for the case where the
  #   reference was built on a bridge checkout WITHOUT V164 — a real `1.7.235`
  #   tag, say — where the old chain's named-schema output legitimately keeps
  #   the unnormalized shapes. If you rebuild the references on a V164-carrying
  #   bridge and want the strictest possible oracle, drop these three (or run
  #   with `PK_SQUASH_WHITELIST` narrowed) and they should still compare equal.
  @legacy_optional_default [
    "phoenix_kit_users.preferred_locale",
    "phoenix_kit_users_preferred_locale_index",
    "phoenix_kit_email_logs_aws_message_id_index",
    "idx_publishing_posts_group_slug",
    "phoenix_kit_subscription_plans_slug_uidx",
    "phoenix_kit_subscription_types_slug_uidx"
  ]

  @ref_header_prefix "-- pk-squash-ref"

  # Longest object name the chain builds by embedding the schema prefix
  # (`phoenix_kit_files_user_file_checksum_index`, V26). Everything derived
  # from it is a NAMEDATALEN budget — see scratch_name/2.
  @longest_embedded_object_name 42
  @max_schema_bytes 63 - 1 - @longest_embedded_object_name
  @max_base_bytes @max_schema_bytes - 12

  @usage """
  Usage: MIX_ENV=test mix run dev_docs/squash/verify.exs [options]

    --check              offline gate: compile, helper self-checks, config
                         validation, scenario runnability listing; no DB access
    --mode a|b           a = sequential clean-DB (public + CASCADE resets,
                         gated by PK_SQUASH_ALLOW_RESET=<PGDATABASE>)
                         b = throwaway named schemas (default)
    --scenario id1,id2   run only the listed scenario ids (--check lists them)
    --verbose            retain scratch schemas and all dumps (PK_SQUASH_OUT_DIR)
  """

  # ---------------------------------------------------------------------------
  # Entry points
  # ---------------------------------------------------------------------------

  def main(argv) do
    {opts, positional, invalid} =
      OptionParser.parse(argv,
        strict: [check: :boolean, mode: :string, scenario: :string, verbose: :boolean]
      )

    cond do
      invalid != [] -> halt_usage("unknown option(s): #{inspect(invalid)}")
      positional != [] -> halt_usage("unexpected argument(s): #{inspect(positional)}")
      Keyword.get(opts, :check, false) -> check(opts)
      true -> run(opts)
    end
  end

  @doc """
  Offline smoke gate: compiles this script plus the three helper modules,
  runs their DB-free self-checks, validates the configuration surface
  (mode/schema/whitelist/floor/scenario filter), lists every scenario with
  its current runnability, prints a one-line OK, and returns without any
  DB access.
  """
  def check(opts) do
    IO.puts("verify.exs --check (offline; no DB access)\n")

    RepoHelper.run_self_checks()
    IO.puts("  RepoHelper.run_self_checks: OK")
    DumpHelper.run_self_checks()
    IO.puts("  DumpHelper.run_self_checks: OK")
    MigrationRunner.check()
    IO.puts("  MigrationRunner.check: OK")

    ctx = build_ctx(opts, :check)
    selected = select_scenarios!(opts[:scenario])

    IO.puts(
      "  configuration: mode=#{ctx.mode} base=#{ctx.base} " <>
        "floor=#{MigrationRunner.floor()} current=#{MigrationRunner.current_version()} " <>
        "whitelist=#{length(ctx.whitelist)} selected=#{length(selected)}"
    )

    IO.puts("""

    Scenario runnability (S14 = DB-free gates: mix precommit / release_check,
    not a verify.exs scenario):
    """)

    Enum.each(scenarios(), fn s ->
      status =
        case unmet_requirement(ctx, s) do
          :ok -> "RUNNABLE"
          {:skip, slug, _human} -> "SKIP:#{slug}"
        end

      IO.puts(
        "  #{String.pad_trailing(s.id, 12)}#{String.pad_trailing(s.spec, 5)}" <>
          "#{String.pad_trailing(status, 36)}#{s.title}"
      )
    end)

    IO.puts(
      "\nOK verify.exs --check: modules compiled, helper self-checks passed, " <>
        "configuration valid; no DB was touched."
    )
  end

  def run(opts) do
    ctx = build_ctx(opts, :run)
    selected = select_scenarios!(opts[:scenario])

    IO.puts("""
    =======================================================
    PhoenixKit migration squash — scenario harness
    mode=#{ctx.mode} base=#{ctx.base} floor=#{MigrationRunner.floor()} \
    current=#{MigrationRunner.current_version()}
    scenarios: #{Enum.map_join(selected, ", ", & &1.id)}
    =======================================================
    """)

    ctx = attach_repo(ctx, selected)

    results = Enum.map(selected, fn s -> {s.id, run_scenario(ctx, s)} end)

    IO.puts("\n=======================================================")
    IO.puts("SUMMARY")
    IO.puts("=======================================================")

    Enum.each(results, fn {id, status} ->
      IO.puts("  #{String.pad_trailing(id, 12)} #{status_line(status)}")
    end)

    failed? =
      Enum.any?(results, fn {_id, status} ->
        match?({:fail, _}, status) or match?({:error, _}, status)
      end)

    IO.puts("")

    if failed? do
      IO.puts("One or more scenarios FAILED.")
      System.halt(1)
    else
      IO.puts("No failures (PASS/SKIP only).")
      System.halt(0)
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario registry
  # ---------------------------------------------------------------------------

  # Requirements are checked before the body runs; the first unmet one becomes
  # the SKIP reason. Precursor scenarios (_self/_pre suffixes) prove the
  # oracles against the CURRENT compiled chain and need only a scratch DB.
  defp scenarios do
    [
      %{
        id: "s1_self",
        spec: "S1",
        title:
          "fresh-install self-oracle: current chain twice, normalized dumps byte-equal " <>
            "(strict; writes the S1 reference on pre-squash checkouts)",
        requires: [:db],
        run: &s1_self/1
      },
      %{
        id: "s1",
        spec: "S1",
        title: "fresh-install equivalence: NEW chain vs saved OLD-chain reference (whitelisted)",
        requires: [:squashed_registry, :ref_s1, :db],
        run: &s1_full/1
      },
      %{
        id: "s2_self",
        spec: "S2",
        title:
          "seed-data self-oracle: two fresh installs, normalized seed dumps identical " <>
            "(writes the S2 reference on pre-squash checkouts)",
        requires: [:db],
        run: &s2_self/1
      },
      %{
        id: "s2",
        spec: "S2",
        title: "seed-data equivalence: NEW chain vs saved OLD-chain seed reference",
        requires: [:squashed_registry, :ref_s2, :db],
        run: &s2_full/1
      },
      %{
        id: "s3",
        spec: "S3",
        title: "existing-install upgrade from floor and floor+k: deltas only, comment=current",
        requires: [:squashed_registry, :db],
        run: &s3_upgrade/1
      },
      %{
        id: "s4_seed",
        spec: "S4",
        title:
          "seed the persistent below-floor handoff schema at floor-1 " <>
            "(bridge checkout; hands off to s4 on the squash checkout)",
        requires: [:pre_squash_registry, :floor_override, :mode_b, :db],
        run: &s4_seed/1
      },
      %{
        id: "s4",
        spec: "S4",
        title:
          "below-floor guard: up(), down() AND ensure_current/2 raise the specific BelowFloorError",
        requires: [:squashed_registry, :below_floor_error, :mode_b, :db],
        run: &s4_guard/1
      },
      %{
        id: "s5",
        spec: "S5",
        title: "consumer wrapper replay (Andi 41-file set / synthetic pins / interleaved)",
        requires: [:squashed_registry, :repair_engine, :generated_manifest, :db],
        run: &s5_all/1
      },
      %{
        id: "s6",
        spec: "S6",
        title: "baseline down to 0 + re-up; shared extensions survive; identical re-create",
        requires: [:squashed_registry, :db],
        run: &s6_down/1
      },
      %{
        id: "s7",
        spec: "S7",
        title: "repair tamper matrix: drop each object class, repair restores, extras untouched",
        requires: [:repair_engine, :generated_manifest, :db],
        run: &s7_tamper_matrix/1
      },
      %{
        id: "s8_pre",
        spec: "S8",
        title: "double up() idempotence: second run is a no-op, dumps byte-identical",
        requires: [:db],
        run: &s8_pre/1
      },
      %{
        id: "s8",
        spec: "S8",
        title: "repair idempotence: healthy DB twice, empty plan, byte-identical dumps",
        requires: [:repair_engine, :generated_manifest, :db],
        run: &s8_repair_idempotence/1
      },
      %{
        id: "s9",
        spec: "S9",
        title:
          "divergence reporting: report-only, exit 2, no deparse false-positives " <>
            "(second-PG-major cell needs the operator container)",
        requires: [:repair_engine, :generated_manifest, :db],
        run: &s9_divergence/1
      },
      %{
        id: "s10",
        spec: "S10",
        title: "data preservation: seeded + user rows + tuned settings survive repair",
        requires: [:repair_engine, :generated_manifest, :db],
        run: &s10_data_preservation/1
      },
      %{
        id: "s11_pre",
        spec: "S11",
        title:
          "prefixed dual-install cross-leak: parity of coexisting installs via the dump " <>
            "differ (mode A adds the public-vs-named cell)",
        requires: [:db],
        run: &s11_pre/1
      },
      %{
        id: "s11",
        spec: "S11",
        title: "prefixed install parity on the NEW chain (repair-in-prefix cell lands with P2)",
        requires: [:squashed_registry, :db],
        run: &s11_full/1
      },
      %{
        id: "s12",
        spec: "S12",
        title: "pooled-connection detection / --unsafe-pooled degraded mode (needs Q6 endpoint)",
        requires: [:repair_engine, :generated_manifest, :db],
        run: &s12_pooled_detection/1
      },
      %{
        id: "s13",
        spec: "S13",
        title: "--adopt: healthy converges + stamps; half-installed / invariant-failing do not",
        requires: [:repair_engine, :generated_manifest, :db],
        run: &s13_adopt/1
      },
      %{
        id: "s15",
        spec: "S15",
        title: "stamp semantics: single-step fresh stamps '{floor}', multi-step '{current}'",
        requires: [:squashed_registry, :db],
        run: &s15_stamps/1
      },
      %{
        id: "s16",
        spec: "S16",
        title: "Oban delegation: repair/verify skip oban objects; no oban entries in Report",
        requires: [:repair_engine, :db],
        run: &s16_stub/1
      },
      %{
        id: "s17",
        spec: "S17",
        title: "repair since/revision scoping: comment-era shapes clean, pending reported",
        requires: [:repair_engine, :generated_manifest, :db],
        run: &s17_revision_scoping/1
      },
      %{
        id: "s18",
        spec: "S18",
        title: "concurrency: chain up() mid-repair triggers the concurrent-migration abort",
        requires: [:repair_engine, :db],
        run: &s18_stub/1
      },
      %{
        id: "s19",
        spec: "S19",
        title: "data-dependent drift: V137-class index over duplicates yields :create_failed",
        requires: [:repair_engine, :generated_manifest, :db],
        run: &s19_create_failed/1
      },
      %{
        id: "s20",
        spec: "S20",
        title: "comment > current: repair hard-errors, doctor warns, up() no-op documented",
        requires: [:repair_engine, :generated_manifest, :db],
        run: &s20_comment_above_current/1
      },
      %{
        id: "s21",
        spec: "S21",
        title:
          "V164 repair: restores FKs/NOT NULL/comments-FK ON DELETE after the V56/V57 " <>
            "flush-order defect, is idempotent, and grants an orphan-blocked FK NOT VALID",
        requires: [:squashed_registry, :db],
        run: &s21_v164_repair/1
      },
      %{
        id: "s22",
        spec: "S22",
        title:
          "per-version stepping equivalence: each delta applied in its own migrator " <>
            "invocation matches a single combined invocation (schema and seed data)",
        requires: [:squashed_registry, :db],
        run: &s22_stepwise_equivalence/1
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Requirements
  # ---------------------------------------------------------------------------

  defp unmet_requirement(ctx, scenario) do
    Enum.find_value(scenario.requires, :ok, fn req ->
      case check_requirement(ctx, req) do
        :ok -> nil
        {:skip, _slug, _human} = skip -> skip
      end
    end)
  end

  defp check_requirement(ctx, :db) do
    if ctx.repo do
      :ok
    else
      {:skip, "needs-scratch-db",
       "PGHOST/PGUSER/PGPASSWORD/PGDATABASE not set — operator scratch DB pending (spec 8.1)"}
    end
  end

  defp check_requirement(_ctx, :squashed_registry) do
    if Postgres.initial_version() > 1 do
      :ok
    else
      {:skip, "needs-p3-squashed-registry",
       "compiled @initial_version is 1 (pre-squash checkout); lands with the P3 squash PR"}
    end
  end

  defp check_requirement(_ctx, :pre_squash_registry) do
    if Postgres.initial_version() == 1 do
      :ok
    else
      {:skip, "needs-pre-squash-checkout",
       "below-floor installs can only be built by the bridge (pre-squash) chain"}
    end
  end

  defp check_requirement(_ctx, :floor_override) do
    if MigrationRunner.floor() >= 2 do
      :ok
    else
      {:skip, "needs-pk-squash-floor",
       "set PK_SQUASH_FLOOR (>= 2) so floor-1 is a real version on the pre-squash checkout"}
    end
  end

  defp check_requirement(ctx, :mode_b) do
    if ctx.mode == :b do
      :ok
    else
      {:skip, "needs-mode-b",
       "the persistent below-floor handoff schema cannot coexist with mode A public " <>
         "resets (DROP SCHEMA public CASCADE also drops extension-dependent objects)"}
    end
  end

  defp check_requirement(_ctx, :below_floor_error) do
    if Code.ensure_loaded?(PhoenixKit.Migrations.BelowFloorError) do
      :ok
    else
      {:skip, "needs-p3-below-floor-error",
       "PhoenixKit.Migrations.BelowFloorError is not defined (P3 deliverable)"}
    end
  end

  defp check_requirement(_ctx, :repair_engine) do
    if Code.ensure_loaded?(PhoenixKit.Migrations.Repair) do
      :ok
    else
      {:skip, "needs-p2-repair-engine",
       "PhoenixKit.Migrations.Repair is not defined (P2 deliverable)"}
    end
  end

  defp check_requirement(_ctx, :manifest) do
    if Code.ensure_loaded?(PhoenixKit.Migrations.ExpectedSchema) do
      :ok
    else
      {:skip, "needs-p2-manifest",
       "PhoenixKit.Migrations.ExpectedSchema is not defined (P2 deliverable)"}
    end
  end

  # Division of labor (unlike :manifest above, which checks for the
  # P3-compiled real module): the repair-engine scenarios below are the
  # OPERATOR-facing matrix against the REAL generated manifest — the file
  # `generate_baseline.exs`'s full [DB] run writes to `output/`, built from
  # this checkout's actual v01..v161 chain — not `PhoenixKit.Test.FixtureExpectedSchema`,
  # which `test/integration/repair_test.exs` already covers the engine
  # MECHANISM against. Checks file presence only; loading it is each
  # scenario's own first step (`ensure_generated_manifest_loaded!/0`) so
  # `--check`'s runnability listing never touches the filesystem beyond
  # `File.exists?/1`.
  defp check_requirement(_ctx, :generated_manifest) do
    if File.exists?(generated_manifest_path()) do
      :ok
    else
      {:skip, "needs-generated-manifest",
       "no generated manifest at #{generated_manifest_path()}; run the full generator " <>
         "first (MIX_ENV=test PK_SQUASH_FLOOR=<floor> PGPOOL=<n> mix run " <>
         "dev_docs/squash/generate_baseline.exs), which writes output/expected_schema.ex"}
    end
  end

  defp check_requirement(ctx, :ref_s1) do
    if File.exists?(s1_ref_path(ctx)) do
      :ok
    else
      {:skip, "missing-reference-s1",
       "no S1 reference at #{s1_ref_path(ctx)}; run --scenario s1_self on the bridge checkout"}
    end
  end

  defp check_requirement(ctx, :ref_s2) do
    if File.exists?(s2_ref_path(ctx)) do
      :ok
    else
      {:skip, "missing-reference-s2",
       "no S2 reference at #{s2_ref_path(ctx)}; run --scenario s2_self on the bridge checkout"}
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario runner (cleanup-guaranteed)
  # ---------------------------------------------------------------------------

  defp run_scenario(ctx, scenario) do
    IO.puts("\n--- #{scenario.id} (#{scenario.spec}) #{scenario.title} ---")

    status =
      case unmet_requirement(ctx, scenario) do
        {:skip, slug, human} ->
          IO.puts("  SKIPPED: #{human}")
          {:skip, slug}

        :ok ->
          {:ok, cleanup} = Agent.start_link(fn -> [] end)
          ctx = %{ctx | cleanup: cleanup}

          try do
            case scenario.run.(ctx) do
              :pass ->
                :pass

              {:fail, msg} ->
                IO.puts("  FAIL: #{msg}")
                {:fail, msg}

              {:skip, slug, human} ->
                IO.puts("  SKIPPED: #{human}")
                {:skip, slug}
            end
          rescue
            e ->
              IO.puts("  EXCEPTION:")
              print_exception_safely(e, __STACKTRACE__)
              {:error, e}
          catch
            kind, value ->
              IO.puts("  NON-RAISE EXIT: #{inspect(kind)} #{inspect(value)}")
              {:error, {kind, value}}
          after
            drop_registered_schemas(ctx)
            Agent.stop(cleanup)
          end
      end

    IO.puts("RESULT #{scenario.id} #{status_line(status)}")
    status
  end

  # A raised exception's message can carry raw bytes this environment's
  # `:standard_io` encoding cannot write (verified empirically: a
  # `Postgrex.Error` whose `:postgres.detail` held an invalid-for-the-
  # database-encoding byte sequence made `Exception.format/3`'s OWN output
  # unprintable, so `IO.puts/1` raised a SECOND, unrelated `ArgumentError`
  # from `:io.put_chars` — silently replacing the real failure with a
  # confusing crash and aborting the ENTIRE scenario run, not just this one
  # scenario). Falls back to a bounded `inspect/2` (which never raises on
  # binary content the way raw stdout writes can) so a printing failure
  # degrades to a still-useful, sanitized dump instead of taking down every
  # scenario queued after this one.
  defp print_exception_safely(e, stacktrace) do
    IO.puts(Exception.format(:error, e, stacktrace))
  rescue
    _ ->
      IO.puts(
        "  (exception message could not be printed — contains bytes invalid for this " <>
          "environment's I/O encoding; falling back to a sanitized dump)"
      )

      safe_inspect_line(e)
  end

  defp safe_inspect_line(e) do
    IO.puts(inspect(e, limit: :infinity, printable_limit: :infinity))
  rescue
    _ -> IO.puts("  (exception could not be rendered at all: #{inspect(e.__struct__)})")
  end

  defp status_line(:pass), do: "PASS"
  defp status_line({:fail, _}), do: "FAIL"
  defp status_line({:skip, slug}), do: "SKIP:#{slug}"
  defp status_line({:error, _}), do: "ERROR"

  # ---------------------------------------------------------------------------
  # S1/S2 precursors and full scenarios
  # ---------------------------------------------------------------------------

  defp s1_self(ctx) do
    to = MigrationRunner.current_version()

    a = fresh_target(ctx, "s1_ref")
    IO.puts("  installing chain v#{to} into #{a} (run 1)...")
    MigrationRunner.run_old_chain(ctx.repo, a)
    dump_a = DumpHelper.dump!(a)
    retain(ctx, "s1_self_a.sql", dump_a, :verbose)
    maybe_save_s1_reference(ctx, a, dump_a)

    b = fresh_target(ctx, "s1_alt")
    IO.puts("  installing chain v#{to} into #{b} (run 2)...")
    MigrationRunner.run_old_chain(ctx.repo, b)
    dump_b = DumpHelper.dump!(b)
    retain(ctx, "s1_self_b.sql", dump_b, :verbose)

    # Two identical single-run installs: strict comparison, no whitelist —
    # the bimodal artifacts are present on BOTH sides here.
    compare_dumps(ctx, "s1_self", dump_a, a, dump_b, b, [])
  end

  defp s1_full(ctx) do
    {meta, ref_dump} = load_ref!(s1_ref_path(ctx))
    ref_schema = Map.fetch!(meta, "schema")

    cond do
      Map.get(meta, "chain_version") != to_string(MigrationRunner.current_version()) ->
        {:skip, "reference-stale",
         "S1 reference was built at chain v#{meta["chain_version"]}, compiled chain is " <>
           "v#{MigrationRunner.current_version()}; regenerate via --scenario s1_self on " <>
           "the bridge checkout at the matching chain head"}

      ref_schema == "public" != (ctx.mode == :a) ->
        {:skip, "reference-mode-mismatch",
         "S1 reference came from schema #{ref_schema}; compare in the matching mode " <>
           "(public references in --mode a, named-schema references in --mode b) — " <>
           "cross-kind comparison false-diffs on shared-object references such as " <>
           "public.gen_random_bytes inside uuid_generate_v7's body"}

      true ->
        t = fresh_target(ctx, "s1_new")
        IO.puts("  installing NEW chain into #{t}...")
        MigrationRunner.run_new_chain_fresh(ctx.repo, t)
        raw = DumpHelper.dump!(t)
        retain(ctx, "s1_new.sql", raw, :verbose)
        compare_dumps(ctx, "s1", ref_dump, ref_schema, raw, t, ctx.whitelist)
    end
  end

  defp s2_self(ctx) do
    a = fresh_target(ctx, "s2_ref")
    IO.puts("  installing into #{a} (run 1)...")
    MigrationRunner.run_old_chain(ctx.repo, a)
    seeds_a = DumpHelper.dump_seed_data!(a)
    retain(ctx, "s2_self_a.txt", seeds_a, :verbose)
    warn_if_templates_absent(seeds_a)
    maybe_save_s2_reference(ctx, seeds_a)

    b = fresh_target(ctx, "s2_alt")
    IO.puts("  installing into #{b} (run 2)...")
    MigrationRunner.run_old_chain(ctx.repo, b)
    seeds_b = DumpHelper.dump_seed_data!(b)
    retain(ctx, "s2_self_b.txt", seeds_b, :verbose)

    compare_seed_texts(ctx, "s2_self", seeds_a, "run1", seeds_b, "run2")
  end

  defp s2_full(ctx) do
    {meta, ref_body} = load_ref!(s2_ref_path(ctx))

    if Map.get(meta, "chain_version") != to_string(MigrationRunner.current_version()) do
      {:skip, "reference-stale",
       "S2 reference was built at chain v#{meta["chain_version"]}, compiled chain is " <>
         "v#{MigrationRunner.current_version()}; regenerate via --scenario s2_self"}
    else
      t = fresh_target(ctx, "s2_new")
      IO.puts("  installing NEW chain into #{t}...")
      MigrationRunner.run_new_chain_fresh(ctx.repo, t)
      seeds = DumpHelper.dump_seed_data!(t)
      retain(ctx, "s2_new.txt", seeds, :verbose)
      warn_if_templates_absent(seeds)
      compare_seed_texts(ctx, "s2", ref_body, "reference", seeds, t)
    end
  end

  # ---------------------------------------------------------------------------
  # S3 — existing-install upgrade (post-squash)
  # ---------------------------------------------------------------------------

  defp s3_upgrade(ctx) do
    floor = MigrationRunner.floor()
    current = MigrationRunner.current_version()

    ref = fresh_target(ctx, "s3_ref_")
    IO.puts("  building single-run reference install in #{ref}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, ref)
    ref_dump = DumpHelper.dump!(ref)
    ref_seeds = DumpHelper.dump_seed_data!(ref)

    ks = Enum.uniq([0, min(3, current - floor)])

    results =
      Enum.map(ks, fn k ->
        from_version = floor + k
        t = fresh_target(ctx, "s3_f#{from_version}")
        IO.puts("  installing #{t} to v#{from_version}, then upgrading via up()...")
        MigrationRunner.run_new_chain_fresh(ctx.repo, t, to_version: from_version)
        MigrationRunner.run_new_chain_existing(ctx.repo, t, from_version)
        v = MigrationRunner.migrated_version(ctx.repo, t)

        if v != current do
          {:fail, "upgrade from v#{from_version} landed at comment #{v}, expected #{current}"}
        else
          d = DumpHelper.dump!(t)
          seeds = DumpHelper.dump_seed_data!(t)

          first_failure([
            compare_dumps(ctx, "s3_from_#{from_version}", ref_dump, ref, d, t, ctx.whitelist),
            compare_seed_texts(ctx, "s3_from_#{from_version}", ref_seeds, "reference", seeds, t)
          ])
        end
      end)

    first_failure(results)
  end

  # ---------------------------------------------------------------------------
  # S4 — below-floor guard (bridge-seeded handoff schema + specific matcher)
  # ---------------------------------------------------------------------------

  defp s4_seed(ctx) do
    floor = MigrationRunner.floor()
    seed_version = floor - 1
    target = below_floor_schema(ctx)

    IO.puts("  (re)seeding persistent handoff schema #{target} at v#{seed_version}...")
    drop_schema!(ctx, target)
    MigrationRunner.run_old_chain(ctx.repo, target, to_version: seed_version)
    v = MigrationRunner.migrated_version(ctx.repo, target)

    if v == seed_version do
      IO.puts(
        "  handoff ready: #{target} is at v#{v} (below floor #{floor}) and is " <>
          "deliberately NOT dropped. Check out the squash branch and run " <>
          "--scenario s4 against the same database."
      )

      :pass
    else
      {:fail, "handoff schema landed at v#{v}, expected #{seed_version}"}
    end
  end

  defp s4_guard(ctx) do
    floor = MigrationRunner.floor()
    target = below_floor_schema(ctx)
    v = MigrationRunner.migrated_version(ctx.repo, target)

    cond do
      v == 0 ->
        {:skip, "handoff-schema-absent",
         "schema #{target} holds no install; run --scenario s4_seed on the bridge " <>
           "(pre-squash) checkout against the same database first"}

      v >= floor ->
        {:fail, "handoff schema #{target} is at v#{v}, not below floor #{floor}; reseed it"}

      true ->
        matcher = below_floor_matcher(v)

        r_up =
          MigrationRunner.assert_below_floor_error(ctx.repo, target, v,
            matcher: matcher,
            entry_point: :up
          )

        r_down =
          MigrationRunner.assert_below_floor_error(ctx.repo, target, v,
            matcher: matcher,
            entry_point: :down
          )

        r_ensure =
          MigrationRunner.assert_below_floor_error(ctx.repo, target, v,
            matcher: ensure_current_matcher(v),
            entry_point: :ensure_current
          )

        case {r_up, r_down, r_ensure} do
          {:ok, :ok, :ok} ->
            IO.puts(
              "  up(), down() and ensure_current/2 all raised BelowFloorError with the " <>
                "expected fields (ensure_current additionally carries the test-DB hint)"
            )

            :pass

          {up, down, ensure} ->
            {:fail,
             "below-floor guard mismatch: up=#{inspect(up)} down=#{inspect(down)} " <>
               "ensure_current=#{inspect(ensure)}"}
        end
    end
  end

  # Asserted field-by-field: db_version + floor; bridge_version is pinned only
  # indirectly via the bridge-named message (its expected VALUE is unknowable
  # until the bridge is tagged — add a field assert in s4_guard then). If P3
  # ships different field names this matcher fails loudly as
  # {:wrong_error, exception} — adjust it, never loosen it to any-raise-passes.
  # Same fields, plus the two things only the ensure_current/2 path can prove:
  # its `rescue` really re-tagged the context (Ecto.Migrator carried the
  # exception out of its spawned Task un-wrapped), and the re-tag is what makes
  # `message/1` append the `mix test.reset` hint instead of bridge-install
  # advice that is wrong for a CI database.
  defp ensure_current_matcher(db_version) do
    base = below_floor_matcher(db_version)

    fn e ->
      base.(e) and Map.get(e, :context) == :ensure_current and
        Exception.message(e) =~ "mix test.reset"
    end
  end

  defp below_floor_matcher(db_version) do
    error_mod = PhoenixKit.Migrations.BelowFloorError
    floor = MigrationRunner.floor()

    fn e ->
      is_struct(e, error_mod) and Map.get(e, :db_version) == db_version and
        Map.get(e, :floor) == floor and Exception.message(e) =~ ~r/bridge/i
    end
  end

  # ---------------------------------------------------------------------------
  # S5 — consumer wrapper replay (spec 8.2 S5 i-iv / 5.3; fixtures in
  # s5_fixtures.ex, mined from /www/app/priv/repo/migrations — never edited)
  # ---------------------------------------------------------------------------

  defp s5_all(ctx) do
    first_failure([
      s5_wrapper_replay(ctx),
      s5_synthetic_pins(ctx),
      s5_interleaved_failure(ctx),
      s5_rollback_roundtrip(ctx)
    ])
  end

  # (i) Realistic accumulated wrapper set: Andi's real 54-file shape (1
  # unpinned installer + 48 pinned update wrappers + 5 interleaved
  # consumer-authored migrations touching PK-owned tables), replayed in
  # their real chronological order against the NEW squashed chain. Oracle:
  # lands at the current comment, and `Repair.verify/1` reports the PK
  # schema itself fully conformant (exit 0) — Andi's own extra objects
  # (markup_percentage, prefix, primary_supplier_uuid, the sample warehouse
  # table) are not PK-manifest objects, so they don't count against this;
  # a raw byte-dump comparison against a pristine install would need to
  # whitelist each of them individually for no added assurance.
  defp s5_wrapper_replay(ctx) do
    ensure_generated_manifest_loaded!()
    t = fresh_target(ctx, "s5_wrap")
    current = MigrationRunner.current_version()

    IO.puts(
      "  [s5i] replaying installer + #{length(S5Fixtures.wrapper_versions())} update " <>
        "wrapper(s), with interleaved consumer migrations at their real positions, " <>
        "against #{t}..."
    )

    replay_wrapper_and_consumer_steps(ctx, t, installer: true, to_max: current)

    v = MigrationRunner.migrated_version(ctx.repo, t)

    if v != current do
      {:fail, "s5(i): after the realistic replay, comment is #{v}, expected #{current}"}
    else
      {:ok, report} = Repair.verify(prefix: t, repo: ctx.repo)

      if Report.exit_code(report) == 0 do
        IO.puts("  [s5i] PASS: #{t} landed at v#{v}; repair verify reports the PK schema clean")
        :pass
      else
        {:fail,
         "s5(i): after the realistic replay, repair verify is NOT clean: " <>
           "#{inspect(Report.summary(report))} — #{findings_detail(report)}"}
      end
    end
  end

  # (ii) Synthetic pinned chain [27, 50, 120, current] on a fresh schema —
  # the D13 clamp acceptance case (spec 5.2/5.3): the first pin clamps a
  # fresh install straight to the baseline, every below-comment pin after
  # it is a no-op, and the final current-pinned wrapper carries the deltas
  # the rest of the way. Step-by-step comment assertions PLUS a full dump
  # comparison against a pristine single-shot install (no consumer extras
  # here, so byte equality modulo the standard S1 whitelist is the right,
  # stronger oracle).
  defp s5_synthetic_pins(ctx) do
    floor = MigrationRunner.floor()
    current = MigrationRunner.current_version()
    t = fresh_target(ctx, "s5_pins")
    pins = [27, 50, 120, current]

    IO.puts("  [s5ii] replaying synthetic pinned chain #{inspect(pins)} against #{t}...")

    {_final, mismatches} =
      Enum.reduce(pins, {0, []}, fn pin, {prev, mismatches} ->
        MigrationRunner.run_pinned_wrapper(ctx.repo, t, pin, create_schema: prev == 0)
        actual = MigrationRunner.migrated_version(ctx.repo, t)
        expected = expected_after_pin(prev, pin, floor)

        mismatches =
          if actual == expected do
            mismatches
          else
            [
              "up(version: #{pin}) after prior comment #{prev}: expected #{expected}, got #{actual}"
              | mismatches
            ]
          end

        {actual, mismatches}
      end)

    if mismatches != [] do
      {:fail, "s5(ii): #{Enum.join(Enum.reverse(mismatches), "; ")}"}
    else
      ref = fresh_target(ctx, "s5_pins_ref")
      IO.puts("  [s5ii] building single-shot reference install in #{ref}...")
      MigrationRunner.run_new_chain_fresh(ctx.repo, ref)
      ref_dump = DumpHelper.dump!(ref)
      dump = DumpHelper.dump!(t)
      compare_dumps(ctx, "s5_synthetic_pins", ref_dump, ref, dump, t, ctx.whitelist)
    end
  end

  # Pure mirror of Postgres.plan_up/3's routing (D13 clamp / no-op / delta),
  # for asserting the synthetic pinned chain's comment after EACH step, not
  # just the final one.
  defp expected_after_pin(0, pin, floor), do: max(pin, floor)
  defp expected_after_pin(prev, pin, _floor) when prev < pin, do: pin
  defp expected_after_pin(prev, _pin, _floor), do: prev

  # (iii) Interleaved consumer migration touching a below-floor-shaped
  # object -> documented, actionable failure (spec 5.3's named breakage
  # class). Same position and same object as the REAL guarded
  # phoenix_kit_catalogue_v013_base_price.exs (s5_wrapper_replay/1 proves
  # THAT one survives) — this is its unguarded sibling
  # (S5Fixtures.unguarded_price_rename/1), a synthetic negative fixture, not
  # a real Andi file. Oracle: raises, and the message actually names the
  # missing column (actionable), not an opaque crash.
  defp s5_interleaved_failure(ctx) do
    t = fresh_target(ctx, "s5_fail")

    IO.puts(
      "  [s5iii] building #{t} to the same position the real guarded rename runs at, " <>
        "then replaying its UNGUARDED sibling..."
    )

    MigrationRunner.run_pinned_wrapper(ctx.repo, t, 87, create_schema: true)
    MigrationRunner.run_pinned_wrapper(ctx.repo, t, 88, create_schema: false)

    v = MigrationRunner.migrated_version(ctx.repo, t)

    result =
      try do
        MigrationRunner.run_consumer_migration!(ctx.repo, t, S5Fixtures.unguarded_price_rename(t))
        {:unexpected_success, nil}
      rescue
        e -> {:raised, e}
      catch
        kind, value -> {:caught, kind, value}
      end

    case result do
      {:raised, e} ->
        message = Exception.message(e)

        if message =~ ~r/price/i and message =~ ~r/does not exist|column/i do
          IO.puts(
            "  [s5iii] PASS: unguarded rename raised an actionable error at comment " <>
              "v#{v}: #{String.slice(message, 0, 200)}"
          )

          :pass
        else
          {:fail,
           "s5(iii): unguarded rename raised #{inspect(e.__struct__)}, but the message " <>
             "doesn't name the missing column (not actionable): #{message}"}
        end

      {:unexpected_success, _} ->
        {:fail,
         "s5(iii): unguarded rename against comment v#{v} did NOT raise — the below-floor " <>
           "breakage class spec 5.3 names is no longer reproducible here; re-check that " <>
           "example is still valid"}

      {:caught, kind, value} ->
        {:fail,
         "s5(iii): unguarded rename exited via #{inspect(kind)}/#{inspect(value)}, not a " <>
           "normal raise"}
    end
  end

  # (iv) Rollback -> migrate round trip, including one interleaved consumer
  # migration's own down, landing back at a state repair finds fully clean
  # (no spurious re-creates) — plus the below-floor clamped-down desync
  # invariant (spec 5.2) that doctor's detection is built on: the PK
  # comment stays pinned at the floor while Ecto's own bookkeeping in the
  # scratch schema records the wrapper as rolled back, and a warning names
  # the disagreement.
  #
  # Rollback TARGET is the wrapper step immediately before the ONE
  # interleaved consumer migration under test (138, one before the
  # warehouse-tables fixture at 139) — NOT the floor. Rolling all the way
  # to the floor would also re-traverse wrapper steps 136..139, which host
  # A DIFFERENT interleaved fixture (add_primary_supplier_uuid, at 138)
  # whose OWN down was never called — Ecto tracks each migration file's
  # applied state independently, so a real `mix ecto.rollback` targeting
  # only the PK wrapper's version would never re-run that file either, and
  # replaying it a second time (an unguarded ADD COLUMN, faithful to the
  # real file) collides with itself. Rolling back exactly one step keeps
  # the round trip to precisely "one interleaved consumer down" as
  # documented, and confirmed live: rolling to the floor instead reproduces
  # a duplicate_column error here — the double-run is fixture-harness
  # infidelity to Ecto's per-file bookkeeping, not a squash defect.
  @s5_rollback_step_before 138
  @s5_rollback_step_after 139

  defp s5_rollback_roundtrip(ctx) do
    ensure_generated_manifest_loaded!()
    current = MigrationRunner.current_version()
    t = fresh_target(ctx, "s5_rt")

    IO.puts(
      "  [s5iv] building #{t} up through v#{@s5_rollback_step_after} (installer + wrappers, " <>
        "plus the interleaved warehouse-tables consumer migration)..."
    )

    replay_wrapper_and_consumer_steps(ctx, t, installer: true, to_max: @s5_rollback_step_after)

    [warehouse_fixture] = S5Fixtures.consumer_migrations_after(@s5_rollback_step_after)

    IO.puts(
      "  [s5iv] rolling #{t} back down to v#{@s5_rollback_step_before}: the interleaved " <>
        "consumer migration's own down first (drops the sample warehouse table), then the " <>
        "one PK wrapper step..."
    )

    MigrationRunner.run_consumer_migration!(ctx.repo, t, warehouse_fixture.down.(t))
    MigrationRunner.run_pinned_wrapper_down(ctx.repo, t, @s5_rollback_step_before)
    v_after_down = MigrationRunner.migrated_version(ctx.repo, t)

    IO.puts(
      "  [s5iv] migrating #{t} back up to v#{current} (replays v#{@s5_rollback_step_after}, " <>
        "including the interleaved consumer migration's up again, then the remaining " <>
        "untouched wrapper steps through v#{current})..."
    )

    replay_wrapper_and_consumer_steps(ctx, t,
      installer: false,
      to_min: @s5_rollback_step_before,
      to_max: current
    )

    v_final = MigrationRunner.migrated_version(ctx.repo, t)

    cond do
      v_after_down != @s5_rollback_step_before ->
        {:fail,
         "s5(iv): after rolling down one step, comment reads #{v_after_down}, expected " <>
           "#{@s5_rollback_step_before}"}

      v_final != current ->
        {:fail, "s5(iv): after migrating back up, comment reads #{v_final}, expected #{current}"}

      true ->
        ref = fresh_target(ctx, "s5_rt_ref")
        IO.puts("  [s5iv] building single-shot reference install in #{ref}...")
        MigrationRunner.run_new_chain_fresh(ctx.repo, ref)
        {:ok, ref_report} = Repair.verify(prefix: ref, repo: ctx.repo)
        {:ok, rt_report} = Repair.verify(prefix: t, repo: ctx.repo)

        cond do
          Report.exit_code(ref_report) != 0 ->
            {:fail,
             "s5(iv): fresh reference install is not itself clean per repair verify " <>
               "(unrelated to the round trip): #{inspect(Report.summary(ref_report))}"}

          Report.exit_code(rt_report) != 0 ->
            {:fail,
             "s5(iv): after the round trip, repair verify found something to fix (a " <>
               "spurious missing column/object): #{inspect(Report.summary(rt_report))} — " <>
               "#{findings_detail(rt_report)}"}

          true ->
            IO.puts("  [s5iv] round trip landed back at v#{v_final}; repair verify reports clean")

            s5_below_floor_down_desync_check(ctx)
        end
    end
  end

  # spec 5.2's down/1 routing: `target == 0` is a FULL TEARDOWN (removes
  # everything, including the floor's own down) — NOT the clamp case. The
  # clamp is specifically `0 < target < @initial_version`, so this targets
  # `1` (any value in `1..floor-1` clamps identically).
  @s5_below_floor_down_target 1

  defp s5_below_floor_down_desync_check(ctx) do
    floor = MigrationRunner.floor()
    t = fresh_target(ctx, "s5_desync")

    IO.puts(
      "  [s5iv] building #{t} to v#{floor}, then attempting a clamped " <>
        "down(version: #{@s5_below_floor_down_target}) to pin the documented desync " <>
        "warning (spec 5.2)..."
    )

    MigrationRunner.run_pinned_wrapper(ctx.repo, t, floor, create_schema: true)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        MigrationRunner.run_pinned_wrapper_down(ctx.repo, t, @s5_below_floor_down_target)
      end)

    v_after = MigrationRunner.migrated_version(ctx.repo, t)

    cond do
      v_after != floor ->
        {:fail,
         "s5(iv): clamped down(version: #{@s5_below_floor_down_target}) moved the PK " <>
           "comment to #{v_after}; expected it to stay pinned at floor v#{floor} (the " <>
           "documented clamped-down invariant)"}

      not (output =~ ~r/clamp/i and output =~ ~r/floor/i) ->
        {:fail,
         "s5(iv): clamped down(version: #{@s5_below_floor_down_target}) did not emit the " <>
           "expected desync warning on stderr; got: #{inspect(output)}"}

      true ->
        IO.puts(
          "  [s5iv] PASS: clamped down warned and the comment correctly stayed pinned at v#{floor}"
        )

        :pass
    end
  end

  # `add_phoenix_kit_tables.exs` literally calls `PhoenixKit.Migrations.up([])`
  # — no version pin, which `with_defaults/2` resolves to WHATEVER
  # `@current_version` the INSTALLED package compiles to. Historically that
  # was ~84 (the very next wrapper's `from`), not today's 163 — replaying it
  # against TODAY's compiled code with an explicit `version: current()` pin
  # would jump the schema straight to 163 in one shot, making every
  # subsequent wrapper AND interleaved consumer fixture race against an
  # already-fully-migrated schema (a real column collision was observed
  # here: V146 and the real `add_primary_supplier_uuid_...` consumer file
  # both add `phoenix_kit_cat_items.primary_supplier_uuid`, and only the
  # SEQUENCE — consumer file first, V146 later finds it already there via
  # its own `IF NOT EXISTS` — makes both succeed). Pinning below the floor
  # instead reproduces what actually happened: `run_pinned_wrapper/4`'s D13
  # clamp lands ANY below-floor target at exactly the floor either way, so
  # `84` (real, documented evidence — the next wrapper's `from`) and
  # `current()` are NOT interchangeable here despite both being legal
  # `up/1` calls.
  @installer_historical_version 84

  # Replays the installer (if requested) then every wrapper step whose `to`
  # falls in `(to_min, to_max]`, splicing in that step's interleaved
  # consumer fixtures (S5Fixtures.consumer_migrations_after/1) right after
  # it — shared by s5_wrapper_replay/1 (the full sequence) and
  # s5_rollback_roundtrip/1 (which replays it in two slices, before and
  # after a rollback).
  defp replay_wrapper_and_consumer_steps(ctx, prefix, opts) do
    include_installer? = Keyword.get(opts, :installer, false)
    to_min = Keyword.get(opts, :to_min, 0)
    to_max = Keyword.get(opts, :to_max, MigrationRunner.current_version())

    if include_installer? do
      MigrationRunner.run_pinned_wrapper(
        ctx.repo,
        prefix,
        @installer_historical_version,
        create_schema: true
      )
    end

    S5Fixtures.wrapper_versions()
    |> Enum.filter(fn {_from, to} -> to > to_min and to <= to_max end)
    |> Enum.each(fn {_from, to} ->
      MigrationRunner.run_pinned_wrapper(ctx.repo, prefix, to, create_schema: false)

      Enum.each(S5Fixtures.consumer_migrations_after(to), fn fx ->
        MigrationRunner.run_consumer_migration!(ctx.repo, prefix, fx.up.(prefix),
          down: fx.down.(prefix),
          disable_ddl_transaction: fx.disable_ddl_transaction
        )
      end)
    end)

    catch_up_to_head(ctx, prefix, to_max)
  end

  # The mined fixture set ends at whatever head the host app had when it was
  # captured (163). A consumer who bumps the dep runs `mix phoenix_kit.update`
  # once more, and that generates exactly ONE further wrapper pinned to the new
  # head — so model it instead of leaving the install short. Without this, s5(i)
  # starts failing the day a delta is added rather than when something breaks
  # (it did, when V164 grew the normalization). Fires only when a gap remains,
  # so the s5(iv) round-trip (to_max well below the set's end) is unaffected.
  defp catch_up_to_head(ctx, prefix, to_max) do
    last_pinned = S5Fixtures.wrapper_versions() |> Enum.map(&elem(&1, 1)) |> Enum.max()

    if to_max > last_pinned do
      MigrationRunner.run_pinned_wrapper(ctx.repo, prefix, to_max, create_schema: false)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # S6 — full down + re-up (post-squash)
  # ---------------------------------------------------------------------------

  defp s6_down(ctx) do
    t = fresh_target(ctx, "s6")
    IO.puts("  installing NEW chain into #{t}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, t)
    d1 = DumpHelper.dump!(t)
    exts_before = installed_extensions(ctx)

    IO.puts("  rolling down to version 0...")
    MigrationRunner.run_old_chain_down(ctx.repo, t, to_version: 0)

    v = MigrationRunner.migrated_version(ctx.repo, t)
    leftover = pk_table_count(ctx, t)
    lost = exts_before -- installed_extensions(ctx)

    cond do
      v != 0 ->
        {:fail, "after down() migrated_version is #{v}, expected 0"}

      leftover > 0 ->
        {:fail, "#{leftover} phoenix_kit/oban tables left in #{t} after full down()"}

      lost != [] ->
        {:fail, "down() dropped shared extensions: #{Enum.join(lost, ", ")}"}

      true ->
        IO.puts("  teardown clean; re-installing...")
        MigrationRunner.run_new_chain_fresh(ctx.repo, t)
        d2 = DumpHelper.dump!(t)
        compare_dumps(ctx, "s6_reup", d1, t, d2, t, [])
    end
  end

  # ---------------------------------------------------------------------------
  # S8 precursor — double up() idempotence
  # ---------------------------------------------------------------------------

  defp s8_pre(ctx) do
    t = fresh_target(ctx, "s8pre")
    IO.puts("  installing into #{t}...")
    MigrationRunner.run_old_chain(ctx.repo, t)
    v1 = MigrationRunner.migrated_version(ctx.repo, t)
    d1 = DumpHelper.dump!(t)

    IO.puts("  running up() a second time (must be a silent no-op)...")
    MigrationRunner.run_old_chain(ctx.repo, t)
    v2 = MigrationRunner.migrated_version(ctx.repo, t)
    d2 = DumpHelper.dump!(t)

    if v1 != v2 do
      {:fail, "version moved #{v1} -> #{v2} on a double up()"}
    else
      compare_dumps(ctx, "s8_pre", d1, t, d2, t, [])
    end
  end

  # ---------------------------------------------------------------------------
  # S11 — prefixed dual-install cross-leak
  # ---------------------------------------------------------------------------
  #
  # Parity is asserted between two NAMED schemas (symmetric normalization —
  # comparing a public dump against a named-schema dump false-diffs on
  # shared-object references like public.gen_random_bytes). Mode A adds the
  # stronger cell: a public install coexists while the named installs run, so
  # unanchored existence checks would see public's objects and skip creating
  # the named ones (caught by parity), and any leak INTO public is caught by
  # the before/after snapshot.

  defp s11_pre(ctx), do: s11_body(ctx, "s11_pre", &MigrationRunner.run_old_chain/2)

  defp s11_full(ctx) do
    IO.puts("  note: the repair-in-prefix cell (S11 x S7) lands with the P2 repair engine")
    s11_body(ctx, "s11", fn repo, prefix -> MigrationRunner.run_new_chain_fresh(repo, prefix) end)
  end

  defp s11_body(ctx, id, install) do
    pub_before =
      case ctx.mode do
        :a ->
          reset_public!(ctx)
          IO.puts("  installing into public (mode A public-vs-named cell)...")
          install.(ctx.repo, "public")
          DumpHelper.dump!("public")

        :b ->
          IO.puts(
            "  mode B: public untouched; dual named-schema cell only " <>
              "(--mode a on a resettable scratch DB adds the public-vs-named cell)"
          )

          nil
      end

    n1 = named_target(ctx, "#{id}_a")
    IO.puts("  installing into #{n1}...")
    install.(ctx.repo, n1)
    d1 = DumpHelper.dump!(n1)

    n2 = named_target(ctx, "#{id}_b")
    IO.puts("  installing into #{n2} (while #{n1} exists)...")
    install.(ctx.repo, n2)
    d2 = DumpHelper.dump!(n2)
    d1_after = DumpHelper.dump!(n1)

    checks = [
      compare_dumps(ctx, "#{id}_parity", d1, n1, d2, n2, []),
      compare_dumps(ctx, "#{id}_first_intact", d1, n1, d1_after, n1, [])
    ]

    checks =
      if pub_before do
        pub_after = DumpHelper.dump!("public")

        checks ++
          [
            compare_dumps(
              ctx,
              "#{id}_public_intact",
              pub_before,
              "public",
              pub_after,
              "public",
              []
            )
          ]
      else
        checks
      end

    first_failure(checks)
  end

  # ---------------------------------------------------------------------------
  # S15 — stamp semantics (post-squash)
  # ---------------------------------------------------------------------------

  defp s15_stamps(ctx) do
    floor = MigrationRunner.floor()
    current = MigrationRunner.current_version()

    t1 = fresh_target(ctx, "s15_single")
    IO.puts("  single-step fresh install: up(version: #{floor}) into #{t1}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, t1, to_version: floor)
    v1 = MigrationRunner.migrated_version(ctx.repo, t1)

    r1 =
      if v1 == floor do
        IO.puts("  single-step run stamped '#{v1}'")
        :pass
      else
        {:fail, "single-step fresh install stamped '#{v1}', expected '#{floor}'"}
      end

    t2 = fresh_target(ctx, "s15_multi")
    IO.puts("  multi-step fresh install into #{t2}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, t2)
    v2 = MigrationRunner.migrated_version(ctx.repo, t2)

    r2 =
      if v2 == current do
        IO.puts("  multi-step run stamped '#{v2}'")
        :pass
      else
        {:fail, "multi-step fresh install stamped '#{v2}', expected '#{current}'"}
      end

    first_failure([r1, r2])
  end

  # ---------------------------------------------------------------------------
  # P2 repair-engine scenarios — operator-facing matrix against the REAL
  # generated manifest (see :generated_manifest's check_requirement comment).
  # `test/integration/repair_test.exs` already proves the engine MECHANISM
  # against `PhoenixKit.Test.FixtureExpectedSchema`; these scenarios reuse the
  # exact same public `PhoenixKit.Migrations.Repair` API at real chain scale
  # instead of re-deriving it.
  # ---------------------------------------------------------------------------

  defp s16_stub(_ctx), do: pending_p2("Oban delegation - no oban entries in Report (S16)")

  defp pending_p2(note) do
    {:skip, "pending-p2-body",
     "repair-engine artifacts are loaded, but this scenario body is a P2 deliverable: " <> note}
  end

  defp generated_manifest_path, do: Path.join(@script_dir, "output/expected_schema.ex")

  defp ensure_generated_manifest_loaded! do
    unless Code.ensure_loaded?(PhoenixKit.Migrations.ExpectedSchema) do
      Code.require_file(generated_manifest_path())
    end

    :ok
  end

  # Builds a scratch schema on the REAL v01..current chain via the ordinary
  # `PhoenixKit.Migrations.up/1` entry point (`MigrationRunner.run_old_chain/3`
  # — NOT `run_new_chain_fresh/3`, which refuses pre-squash; these scenarios
  # are deliberately floor-agnostic, matching how `:squashed_registry` is
  # absent from every one of their `requires:` lists).
  defp install_repair_target(ctx, slot, opts \\ []) do
    t = fresh_target(ctx, slot)
    MigrationRunner.run_old_chain(ctx.repo, t, opts)
    t
  end

  # `apply/3` (not `PhoenixKit.Migrations.ExpectedSchema.objects(prefix)`
  # directly) — same reasoning as `Fixture.check_manifest_compiles!/1`'s own
  # comment on this pattern: a static remote call to a module that does not
  # exist at COMPILE time (this script's own compile, before
  # `ensure_generated_manifest_loaded!/0` ever runs) is a spurious warning
  # every time, not a real problem — this sidesteps it structurally instead.
  defp manifest_objects(prefix),
    do: apply(PhoenixKit.Migrations.ExpectedSchema, :objects, [prefix])

  defp manifest_table_names(prefix) do
    prefix
    |> manifest_objects()
    |> Enum.filter(&(&1.class == :table))
    |> Enum.map(fn %{check: {:catalog, %{name: name}}} -> name end)
  end

  # ── S7 — tamper matrix ──────────────────────────────────────────────────

  defp s7_tamper_matrix(ctx) do
    ensure_generated_manifest_loaded!()
    t = install_repair_target(ctx, "s7")
    objects = manifest_objects(t)
    before_dump = DumpHelper.dump!(t)

    # :sequence deliberately excluded: every real sequence in this chain
    # backs a column DEFAULT (`nextval(...)`), so a bare `DROP SEQUENCE`
    # fails with `dependent_objects_still_exist` (2BP01) — verified
    # empirically against `phoenix_kit_warehouse_goods_issues_number_seq`.
    # `DROP ... CASCADE` would "succeed" but also silently drop the
    # column's DEFAULT clause, which repair's additive-only contract
    # cannot restore on an EXISTING column (`Executor.create_action/2`
    # only ever adds a column that doesn't exist at all) — collateral,
    # unrepairable damage this scenario must not introduce. Matches
    # `test/integration/repair_test.exs`'s own S7 scope (column +
    # constraint only, no sequence).
    picks = %{
      column: pick_safe_column(objects),
      index: Enum.find(objects, &(&1.class == :index)),
      constraint: pick_fk_constraint(objects)
    }

    missing = for {class, nil} <- picks, do: class

    if missing != [] do
      {:fail,
       "s7: manifest has no droppable object of class(es) #{inspect(missing)} to tamper with"}
    else
      Enum.each(picks, fn {_class, object} -> drop_manifest_object!(ctx, t, object) end)
      run_s7_repair_cycle(ctx, t, picks, before_dump)
    end
  end

  defp run_s7_repair_cycle(ctx, t, picks, before_dump) do
    tampered_ids = picks |> Map.values() |> MapSet.new(& &1.id)

    {:ok, verify_report} = Repair.verify(prefix: t, repo: ctx.repo)
    found_missing = ids_with_kind(verify_report, :missing)

    if not MapSet.subset?(tampered_ids, found_missing) do
      {:fail,
       "s7: verify did not report every tampered object missing — expected " <>
         "#{inspect(MapSet.to_list(tampered_ids))}, found :missing for " <>
         "#{inspect(MapSet.to_list(found_missing))}"}
    else
      {:ok, repair_report} = Repair.repair(prefix: t, repo: ctx.repo)
      repaired = ids_with_kind(repair_report, :repaired)

      if not MapSet.subset?(tampered_ids, repaired) do
        {:fail,
         "s7: repair did not restore every tampered object — expected " <>
           "#{inspect(MapSet.to_list(tampered_ids))}, repaired " <>
           "#{inspect(MapSet.to_list(repaired))}"}
      else
        after_dump = DumpHelper.dump!(t)
        compare_dumps(ctx, "s7_tamper_matrix", before_dump, t, after_dump, t, [])
      end
    end
  end

  defp ids_with_kind(report, kind) do
    report |> Report.findings() |> Enum.filter(&(&1.kind == kind)) |> MapSet.new(& &1.object_id)
  end

  # A column that is safe to DROP/re-ADD without collateral damage: nullable
  # (sidesteps any NOT NULL/backfill nuance), not part of any PRIMARY KEY,
  # AND already the LAST physical column (`pos`) in its table. That last
  # condition is load-bearing, not cosmetic: `ALTER TABLE ADD COLUMN`
  # always appends — `Differ.compare/3`'s own moduledoc documents `pos` as
  # "accidental, never a divergence worth reporting" and the repair engine
  # correctly never flags it, but this scenario's OWN dump-based "restored,
  # byte-identical" check has no such exception (`pg_dump`'s CREATE TABLE
  # column listing reflects physical order) — verified empirically: picking
  # a non-last nullable column produced a real, spurious dump diff (column
  # reordered, nothing structurally different). Choosing a column that's
  # already last sidesteps the false positive instead of weakening the
  # dump comparison's strictness for the index/constraint picks too.
  defp pick_safe_column(objects) do
    pk_columns = pk_columns_by_table(objects)
    max_pos_by_table = max_column_pos_by_table(objects)

    Enum.find(objects, fn
      %{class: :column, check: {:catalog, %{table: table, column: column}}} = object ->
        {_v, shape} = List.last(object.revisions)

        not shape.not_null and
          not MapSet.member?(Map.get(pk_columns, table, MapSet.new()), column) and
          shape.pos == Map.get(max_pos_by_table, table)

      _ ->
        false
    end)
  end

  defp pk_columns_by_table(objects) do
    objects
    |> Enum.filter(&(&1.class == :constraint))
    |> Enum.reduce(%{}, fn object, acc ->
      {_v, shape} = List.last(object.revisions)

      case {object.check, shape} do
        {{:catalog, %{table: table}}, %{type: "p", columns: columns}} ->
          Map.update(acc, table, MapSet.new(columns), &MapSet.union(&1, MapSet.new(columns)))

        _ ->
          acc
      end
    end)
  end

  defp max_column_pos_by_table(objects) do
    objects
    |> Enum.filter(&(&1.class == :column))
    |> Enum.reduce(%{}, fn %{check: {:catalog, %{table: table}}} = object, acc ->
      {_v, shape} = List.last(object.revisions)
      Map.update(acc, table, shape.pos, &max(&1, shape.pos))
    end)
  end

  # A foreign-key constraint — the NOT VALID + VALIDATE path (spec §6.3),
  # never a PK/UNIQUE (dropping either risks cascading into dependents this
  # scenario does not model).
  defp pick_fk_constraint(objects) do
    Enum.find(objects, fn
      %{class: :constraint} = object ->
        {_v, shape} = List.last(object.revisions)
        shape.type == "f"

      _ ->
        false
    end)
  end

  defp drop_manifest_object!(ctx, prefix, %{
         class: :column,
         check: {:catalog, %{table: table, column: column}}
       }) do
    RepoHelper.query!(ctx.repo, ~s[ALTER TABLE "#{prefix}"."#{table}" DROP COLUMN "#{column}"])
  end

  defp drop_manifest_object!(ctx, prefix, %{class: :index, check: {:catalog, %{name: name}}}) do
    RepoHelper.query!(ctx.repo, ~s[DROP INDEX IF EXISTS "#{prefix}"."#{name}"])
  end

  defp drop_manifest_object!(ctx, prefix, %{
         class: :constraint,
         check: {:catalog, %{table: table, name: name}}
       }) do
    RepoHelper.query!(ctx.repo, ~s[ALTER TABLE "#{prefix}"."#{table}" DROP CONSTRAINT "#{name}"])
  end

  defp drop_manifest_object!(ctx, prefix, %{class: :sequence, check: {:catalog, %{name: name}}}) do
    RepoHelper.query!(ctx.repo, ~s[DROP SEQUENCE IF EXISTS "#{prefix}"."#{name}"])
  end

  # ── S8 — repair idempotence ──────────────────────────────────────────────

  defp s8_repair_idempotence(ctx) do
    ensure_generated_manifest_loaded!()
    t = install_repair_target(ctx, "s8")

    {:ok, r1} = Repair.repair(prefix: t, repo: ctx.repo)
    d1 = DumpHelper.dump!(t)

    {:ok, r2} = Repair.repair(prefix: t, repo: ctx.repo)
    d2 = DumpHelper.dump!(t)

    cond do
      Report.exit_code(r1) != 0 ->
        {:fail,
         "s8: first repair pass on a freshly-installed chain was not clean: " <>
           "#{inspect(Report.summary(r1))} — #{findings_detail(r1)}"}

      Report.summary(r1) != Report.summary(r2) ->
        {:fail,
         "s8: second repair pass was not an empty plan relative to the first (not " <>
           "idempotent): #{inspect(Report.summary(r1))} -> #{inspect(Report.summary(r2))}"}

      true ->
        compare_dumps(ctx, "s8_repair_idempotence", d1, t, d2, t, [])
    end
  end

  # Renders the diagnostic-relevant findings (default: error/repairable —
  # info findings are expected noise even on a healthy DB) as
  # "kind:object_id:message" triples, for FAIL messages an operator can act
  # on directly instead of just a severity/kind count.
  defp findings_detail(report, severities \\ [:error, :repairable]) do
    report
    |> Report.findings()
    |> Enum.filter(&(&1.severity in severities))
    |> Enum.map_join(" | ", fn f -> "#{f.kind}:#{f.object_id}:#{f.message}" end)
  end

  # ── S9 — divergence reporting ────────────────────────────────────────────

  defp s9_divergence(ctx) do
    ensure_generated_manifest_loaded!()
    t = install_repair_target(ctx, "s9")
    objects = manifest_objects(t)

    case pick_varchar_column(objects) do
      nil ->
        {:fail, "s9: manifest has no character-varying column to retype"}

      %{check: {:catalog, %{table: table, column: column}}} = object ->
        RepoHelper.query!(
          ctx.repo,
          ~s[ALTER TABLE "#{t}"."#{table}" ALTER COLUMN "#{column}" TYPE text]
        )

        {:ok, report} = Repair.verify(prefix: t, repo: ctx.repo)

        finding =
          Enum.find(
            Report.findings(report),
            &(&1.object_id == object.id and &1.kind == :wrong_shape)
          )

        cond do
          Report.exit_code(report) != 2 ->
            {:fail,
             "s9: exit_code was #{Report.exit_code(report)}, expected 2 " <>
               "(summary: #{inspect(Report.summary(report))})"}

          is_nil(finding) ->
            {:fail, "s9: no :wrong_shape finding for #{object.id}"}

          finding.severity != :error ->
            {:fail, "s9: #{object.id} finding severity was #{finding.severity}, expected :error"}

          true ->
            assert_column_type_unchanged(ctx, t, table, column, "text")
        end
    end
  end

  defp pick_varchar_column(objects) do
    Enum.find(objects, fn
      %{class: :column} = object ->
        {_v, shape} = List.last(object.revisions)
        String.starts_with?(shape.type, "character varying")

      _ ->
        false
    end)
  end

  # verify/1 is read-only — confirms the divergence introduced above is still
  # there afterward (repair never "fixes" a report-only mismatch by
  # overwriting it).
  defp assert_column_type_unchanged(ctx, prefix, table, column, expected_type) do
    %{rows: [[type]]} =
      RepoHelper.query!(
        ctx.repo,
        "SELECT format_type(atttypid, atttypmod) FROM pg_attribute a " <>
          "JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = '#{table}' AND a.attname = '#{column}' AND n.nspname = '#{prefix}'"
      )

    if type == expected_type do
      :pass
    else
      {:fail, "s9: verify/1 mutated #{table}.#{column} — now #{type}, expected #{expected_type}"}
    end
  end

  # ── S10 — data preservation ──────────────────────────────────────────────

  defp s10_data_preservation(ctx) do
    ensure_generated_manifest_loaded!()
    t = install_repair_target(ctx, "s10")

    RepoHelper.query!(
      ctx.repo,
      ~s[UPDATE "#{t}".phoenix_kit_settings SET value = 'tuned-by-s10-verify' WHERE key = 'time_zone']
    )

    # NOT `phoenix_kit_users` — the harness's own `refuse_live_schema!/2`
    # cleanup guard treats ANY populated `phoenix_kit_users` as a sign of a
    # live install and refuses `DROP SCHEMA`, which then crashes the whole
    # run from inside `run_scenario/2`'s `after` block (verified
    # empirically: it does not degrade to a single scenario FAIL). A simple
    # standalone seed table proves the same "arbitrary extra row survives"
    # property without tripping that guard.
    row_uuid = insert_minimal_row!(ctx, t, "phoenix_kit_currencies")
    tables = manifest_table_names(t)
    before_counts = table_row_counts(ctx, t, tables)
    before_tuned = setting_value(ctx, t, "time_zone")

    {:ok, report} = Repair.repair(prefix: t, repo: ctx.repo)

    after_counts = table_row_counts(ctx, t, tables)
    after_tuned = setting_value(ctx, t, "time_zone")
    row_survived? = row_exists?(ctx, t, "phoenix_kit_currencies", "uuid", row_uuid)

    cond do
      Report.exit_code(report) == 2 ->
        {:fail,
         "s10: repair reported error-severity findings on an otherwise-healthy install: " <>
           "#{inspect(Report.summary(report))} — #{findings_detail(report)}"}

      before_counts != after_counts ->
        {:fail,
         "s10: table row counts changed under repair — before " <>
           "#{inspect(before_counts)}, after #{inspect(after_counts)}"}

      before_tuned != after_tuned ->
        {:fail,
         "s10: operator-tuned setting was overwritten — before #{inspect(before_tuned)}, " <>
           "after #{inspect(after_tuned)}"}

      not row_survived? ->
        {:fail, "s10: the inserted extra row disappeared under repair"}

      true ->
        :pass
    end
  end

  defp table_row_counts(ctx, prefix, tables) do
    Map.new(tables, fn table ->
      %{rows: [[count]]} =
        RepoHelper.query!(ctx.repo, ~s[SELECT count(*) FROM "#{prefix}"."#{table}"])

      {table, count}
    end)
  end

  defp setting_value(ctx, prefix, key) do
    %{rows: rows} =
      RepoHelper.query!(
        ctx.repo,
        ~s[SELECT value FROM "#{prefix}".phoenix_kit_settings WHERE key = '#{key}']
      )

    case rows do
      [[v]] -> v
      [] -> nil
    end
  end

  defp row_exists?(ctx, prefix, table, pk_column, value) do
    %{rows: [[exists]]} =
      RepoHelper.query!(
        ctx.repo,
        ~s[SELECT EXISTS (SELECT 1 FROM "#{prefix}"."#{table}" WHERE "#{pk_column}" = '#{value}')]
      )

    exists
  end

  # Generic "insert a row that satisfies every NOT NULL-without-default
  # column" — introspects the live schema rather than hand-modeling any one
  # table, so it works against whichever real table a scenario needs a
  # throwaway row in. `extra` overrides/adds specific columns (e.g. to force
  # a duplicate value into an otherwise-nullable column, S19).
  defp insert_minimal_row!(ctx, prefix, table, extra \\ %{}) do
    base =
      ctx
      |> not_null_columns_without_default(prefix, table)
      |> Map.new(fn {col, type, udt_name, max_len} ->
        {col, default_literal(type, udt_name, max_len)}
      end)

    assignments = Map.merge(base, extra)
    {cols, vals} = Enum.unzip(assignments)
    col_list = Enum.map_join(cols, ", ", &~s["#{&1}"])
    val_list = Enum.join(vals, ", ")
    sql = ~s[INSERT INTO "#{prefix}"."#{table}" (#{col_list}) VALUES (#{val_list}) RETURNING uuid]

    try do
      %{rows: [[uuid]]} = RepoHelper.query!(ctx.repo, sql)
      # Postgrex returns a `:uuid` column as the raw 16-byte binary, NOT
      # the hyphenated hex string — a plain `RETURNING uuid` query (not
      # routed through an Ecto schema/type, which would normally load it)
      # hands that binary straight back. Interpolating it later (e.g.
      # `row_exists?/4`'s `"...WHERE uuid = '#{value}'"`) embeds raw,
      # non-UTF8 bytes directly into SQL TEXT — verified empirically: this
      # produced a genuinely bytes-for-bytes reproducible Postgres
      # `character_not_in_repertoire` error (`0x9f` was one of the 16 raw
      # bytes). `Ecto.UUID.load/1` is the standard raw-binary -> canonical-
      # string conversion (the inverse of `dump/1`, used for exactly this
      # "driver handed back a raw column value" situation).
      case Ecto.UUID.load(uuid) do
        {:ok, uuid_string} -> uuid_string
        :error -> raise "insert_minimal_row!/4: could not load UUID from #{inspect(uuid)}"
      end
    rescue
      # Re-raise with `Exception.message/1` explicitly extracted into a
      # plain string — a raw `Postgrex.Error` struct's `:postgres.detail`
      # can carry bytes `run_scenario/2`'s own `Exception.format/3` +
      # `IO.puts/1` cannot always write to `:standard_io` in this
      # environment's locale (verified empirically: that combination
      # raised its OWN unrelated `ArgumentError` from `:io.put_chars`,
      # masking the real error entirely). A plain string always prints.
      e ->
        reraise "insert_minimal_row!/4 failed for #{prefix}.#{table}: " <>
                  "#{Exception.message(e)} (assignments: #{inspect(assignments)})",
                __STACKTRACE__
    end
  end

  defp not_null_columns_without_default(ctx, prefix, table) do
    %{rows: rows} =
      RepoHelper.query!(ctx.repo, """
      SELECT column_name, data_type, udt_name, character_maximum_length
      FROM information_schema.columns
      WHERE table_schema = '#{prefix}' AND table_name = '#{table}'
        AND is_nullable = 'NO' AND column_default IS NULL
      ORDER BY ordinal_position
      """)

    Enum.map(rows, fn [col, type, udt_name, max_len] -> {col, type, udt_name, max_len} end)
  end

  defp default_literal(type, _udt_name, max_len)
       when type in ["character varying", "character", "text"] do
    raw = "x" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    limit = if is_integer(max_len), do: max(max_len, 1), else: byte_size(raw)
    "'" <> String.slice(raw, 0, limit) <> "'"
  end

  # `information_schema.columns.data_type` reports an extension-defined
  # domain/type (e.g. citext, per V04's case-insensitive email columns) as
  # the generic `"USER-DEFINED"` — the real type name is only in `udt_name`.
  # citext accepts the same literal syntax as text; anything else genuinely
  # unhandled still raises via the catch-all below (never guesses silently).
  defp default_literal("USER-DEFINED", "citext", max_len),
    do: default_literal("text", "citext", max_len)

  defp default_literal("uuid", _udt_name, _max_len), do: "gen_random_uuid()"
  defp default_literal("boolean", _udt_name, _max_len), do: "false"

  defp default_literal(type, _udt_name, _max_len)
       when type in ["integer", "bigint", "smallint", "numeric"],
       do: "0"

  defp default_literal("jsonb", _udt_name, _max_len), do: "'{}'::jsonb"
  defp default_literal("json", _udt_name, _max_len), do: "'{}'::json"

  defp default_literal(type, _udt_name, _max_len)
       when type in ["timestamp without time zone", "timestamp with time zone"],
       do: "now()"

  defp default_literal(type, udt_name, _max_len) do
    raise "s10/s19 fixture helper: no literal-value rule for information_schema type " <>
            "#{inspect(type)}/#{inspect(udt_name)} — add one (insert_minimal_row!/4's " <>
            "default_literal/3 clauses)"
  end

  # ── S12 — pooled-connection detection ────────────────────────────────────

  # Dry-run detection only (spec's own scoping: "zero writes through the
  # pooled path") — proves (a) `Environment.pooled?/2` correctly flags the
  # real pgbouncer endpoint, (b) `Repair.verify/1` (always read-only) works
  # fine through it, (c) `Repair.repair/1` WITHOUT `--unsafe-pooled` refuses
  # outright rather than attempting the advisory lock/FK VALIDATE against a
  # connection that cannot safely hold either. Never exercises the
  # `unsafe_pooled: true` write path for real — that degraded-mode write cell
  # needs the operator's own pgbouncer config change (spec §10 Q6), same
  # scope line the scenario title already draws.
  defp s12_pooled_detection(ctx) do
    ensure_generated_manifest_loaded!()

    case start_pooled_repo() do
      {:error, reason} ->
        {:skip, "needs-pooled-endpoint",
         "could not reach the pooled endpoint (host=pgbouncer port=6432): #{inspect(reason)}"}

      {:ok, pooled_name} ->
        # Build the target BEFORE any dynamic-repo switch — Ecto's
        # `put_dynamic_repo/1` is a per-CALLING-PROCESS setting, and this
        # scenario's process is the one `MigrationRunner.run_old_chain/3`
        # (and everything it calls) actually runs in, so building the
        # schema after the switch would silently run the whole chain
        # THROUGH the pooled connection — verified empirically: PgBouncer
        # dropped the DDL exactly as CLAUDE.md warns, `schema_migrations`
        # bookkeeping recorded success, and the very next version to query
        # a table crashed with `undefined_table`.
        t = install_repair_target(ctx, "s12")
        run_s12_body(ctx, t, pooled_name)
    end
  end

  defp run_s12_body(ctx, t, pooled_name) do
    repo_mod = RepoHelper.repo_module()
    previous_dynamic = repo_mod.get_dynamic_repo()
    previous_env = Application.get_env(:phoenix_kit, repo_mod)

    repo_mod.put_dynamic_repo(pooled_name)

    # `Repair.repair/1`'s own pooled-connection gate reads `repo.config()`
    # (`Environment.pooled?(repo, repo.config())`) — Ecto's generated
    # `config/0` is NOT dynamic-repo-aware (it always reads back the base
    # module's `Application.get_env`, unlike query functions, which DO
    # follow `put_dynamic_repo/1`) — verified empirically: without this,
    # the config-based half of the pooled heuristic silently saw the
    # DIRECT connection's config no matter which dynamic instance queries
    # were actually routed to. Mirrors `RepoHelper.start/0`'s own
    # established pattern of driving this repo via `Application.put_env`
    # (same key), just scoped to this scenario's duration and restored
    # after — a real host app has only one static config here, so this
    # override makes the test environment match that real topology
    # instead of the dynamic-repo trick's own artifact.
    Application.put_env(:phoenix_kit, repo_mod, pooled_repo_config() ++ [pool_size: 2])

    try do
      case repo_mod.query("SELECT 1", [], log: false) do
        {:error, reason} ->
          {:skip, "needs-pooled-endpoint", "pooled endpoint unreachable: #{inspect(reason)}"}

        {:ok, _} ->
          s12_checks(ctx, t, repo_mod)
      end
    after
      repo_mod.put_dynamic_repo(previous_dynamic)
      restore_app_env(:phoenix_kit, repo_mod, previous_env)
    end
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp s12_checks(ctx, t, repo_mod) do
    detected? = RepairEnvironment.pooled?(repo_mod, pooled_repo_config())
    before_dump = DumpHelper.dump!(t)

    verify_result = Repair.verify(prefix: t, repo: repo_mod)
    repair_result = Repair.repair(prefix: t, repo: repo_mod)
    after_dump = DumpHelper.dump!(t)

    cond do
      not detected? ->
        {:fail, "s12: Environment.pooled?/2 did not classify the pgbouncer endpoint as pooled"}

      not match?({:ok, %Report{}}, verify_result) ->
        {:fail,
         "s12: verify/1 (dry-run) through the pooled connection returned #{inspect(verify_result)}"}

      not match?({:error, {:pooled_connection, _message}}, repair_result) ->
        {:fail,
         "s12: repair/1 without --unsafe-pooled through the pooled connection returned " <>
           "#{inspect(repair_result)}, expected {:error, {:pooled_connection, _}}"}

      true ->
        # `compare_dumps/6` (not a raw `!=`) — a raw `pg_dump` invocation
        # carries its own generation-timestamp header, which differs
        # between any two calls regardless of whether the schema changed
        # at all; `compare_dumps/6`'s normalization is what every other
        # scenario relies on to tell "genuinely differs" from "pg_dump's
        # own header noise" apart (verified empirically: a naive `!=`
        # here false-failed on header noise alone, with the schema
        # provably untouched).
        compare_dumps(ctx, "s12_pooled_dry_run_no_writes", before_dump, t, after_dump, t, [])
    end
  end

  defp pooled_repo_config do
    base = RepoHelper.connection_env()

    [
      hostname: "pgbouncer",
      port: 6432,
      username: base.username,
      password: base.password,
      database: base.database,
      ssl: base.ssl
    ]
  end

  defp start_pooled_repo do
    config =
      pooled_repo_config()
      |> Keyword.merge(
        name: pooled_repo_name(),
        pool_size: 2,
        pool: DBConnection.ConnectionPool,
        log: false
      )

    case RepoHelper.repo_module().start_link(config) do
      {:ok, _pid} -> {:ok, pooled_repo_name()}
      {:error, {:already_started, _pid}} -> {:ok, pooled_repo_name()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pooled_repo_name, do: PhoenixKit.Squash.Verify.PooledRepo

  # ── S13 — --adopt ─────────────────────────────────────────────────────

  defp s13_adopt(ctx) do
    ensure_generated_manifest_loaded!()

    first_failure([
      s13_healthy_converges(ctx),
      s13_invariant_failing_no_stamp(ctx)
    ])
  end

  defp s13_healthy_converges(ctx) do
    # Spec's own wording: "comment stripped from a HEALTHY FLOOR-STATE DB".
    # `Repair`'s `--adopt` unconditionally applies the `since <= floor`
    # slice (`ctx.floor = Postgres.initial_version()`, hardcoded, not
    # `MigrationRunner.floor()`/`PK_SQUASH_FLOOR`) and gates the stamp on
    # THAT slice verifying clean — comparing it against a DB migrated all
    # the way to `current` (161) is comparing the wrong thing: V01-era
    # columns get retyped/repointed by dozens of LATER deltas (UUID PKs at
    # V56/V74, `timestamptz` conversions, etc.), so a full install
    # necessarily "diverges" from the V1 shape on unrelated grounds having
    # nothing to do with `--adopt`'s actual floor-convergence behavior —
    # verified empirically (15 extra findings, none of them the citext gap
    # this scenario is actually about). Building only to the floor matches
    # the DB shape `--adopt` is designed for.
    t = install_repair_target(ctx, "s13_healthy", to_version: Postgres.initial_version())
    RepoHelper.query!(ctx.repo, ~s[COMMENT ON TABLE "#{t}".phoenix_kit IS NULL])

    {:ok, pre_report} = Repair.verify(prefix: t, repo: ctx.repo)

    if not Enum.any?(Report.findings(pre_report), &(&1.kind == :adopt_required)) do
      {:fail, "s13: comment-stripped install did not report :adopt_required"}
    else
      floor = Postgres.initial_version()
      {:ok, adopted} = Repair.repair(prefix: t, repo: ctx.repo, adopt: true)

      # `phoenix_kit_users.email` (V01, citext) sits in every real
      # install's `since <= floor` slice — until `Catalog.snapshot/2`
      # forced `search_path = ''` (matching `Probe.snapshot/2`'s own
      # convention), that column's type mismatch (`"citext"` vs
      # `"public.citext"`) blocked `--adopt` from EVER stamping a real
      # install. Left strict throughout that period rather than loosened,
      # per spec 8.3's own precedent for below-floor assertions (match the
      # specific expected outcome, never any-result-passes) — now genuinely
      # passing on its own merits.
      if adopted.comment_action == {:adopted, floor} do
        :pass
      else
        {:fail,
         "s13: --adopt on a healthy DB set comment_action " <>
           "#{inspect(adopted.comment_action)}, expected {:adopted, #{floor}} — " <>
           findings_detail(adopted)}
      end
    end
  end

  # Spec §6.4 R4's data-invariant gate: "post-V114 no composite integration:*
  # settings keys" is one of the manifest's real, generator-emitted
  # invariants — violate it directly, confirming --adopt reports the failure
  # and refuses to stamp (the concrete example the spec names for the
  # "object-clean but data-invariant-failing" no-stamp branch).
  #
  # DORMANT-TODAY, checked rather than assumed: `Repair`'s `--adopt` only
  # ever evaluates invariants `Scope.in_scope_invariants/2` selects for
  # `since <= ctx.floor` (`Postgres.initial_version/0`, hardcoded — same
  # value `s13_healthy_converges/1` uses). The REAL manifest's lowest
  # invariant `since` is 77 (verified against the generated output) — at
  # floor 1, NO invariant is ever in scope, so `--adopt`'s invariant gate
  # cannot fire at all regardless of what data this scenario inserts. Same
  # class of floor-dependent dormancy as `plan_up/3`/`plan_down/3`'s
  # below-floor branches. Checked dynamically (not hardcoded as "always
  # skip") so this starts running for real the moment the floor rises
  # far enough for an invariant to be in scope.
  defp s13_invariant_failing_no_stamp(ctx) do
    floor = Postgres.initial_version()
    invariants = apply(PhoenixKit.Migrations.ExpectedSchema, :data_invariants, ["public"])

    if not Enum.any?(invariants, &(&1.since <= floor)) do
      {:skip, "needs-in-scope-invariant",
       "no manifest data invariant has since <= the real floor (#{floor}) — --adopt's " <>
         "invariant gate is dormant at this floor. Mechanism unit-tested directly by " <>
         "PhoenixKit.Migrations.Repair.CommentPolicyTest; exercised end-to-end by " <>
         "test/integration/repair_test.exs against its synthetic manifest (whose since " <>
         "values are chosen to be in-scope at floor 1 specifically for this reason)"}
    else
      # Not reachable today (see above) — intentionally minimal: revisit
      # the install target once a real invariant is actually in scope, so
      # it can install to whatever version that invariant's referenced
      # objects need rather than guessing now.
      t = install_repair_target(ctx, "s13_invariant", to_version: floor)

      RepoHelper.query!(
        ctx.repo,
        ~s[INSERT INTO "#{t}".phoenix_kit_settings (key, value) ] <>
          ~s[VALUES ('integration:s13_verify:token', 'x') ON CONFLICT (key) DO NOTHING]
      )

      RepoHelper.query!(ctx.repo, ~s[COMMENT ON TABLE "#{t}".phoenix_kit IS NULL])

      {:ok, report} = Repair.repair(prefix: t, repo: ctx.repo, adopt: true)

      cond do
        report.comment_action != :none ->
          {:fail,
           "s13: --adopt stamped #{inspect(report.comment_action)} despite a failing " <>
             "data invariant"}

        not Enum.any?(Report.findings(report), &(&1.kind == :invariant_failed)) ->
          {:fail, "s13: no :invariant_failed finding for the composite integration key"}

        true ->
          :pass
      end
    end
  end

  # ── S17 — revision scoping ────────────────────────────────────────────

  # `phoenix_kit_role_permissions.module_key` (spec's own named example):
  # `character varying(50)` since V53, widened to `character varying(120)`
  # at V142 — a real multi-revision object.
  defp s17_revision_scoping(ctx) do
    ensure_generated_manifest_loaded!()
    t = install_repair_target(ctx, "s17", to_version: 100)

    {:ok, report_old} = Repair.verify(prefix: t, repo: ctx.repo)
    id = "column:phoenix_kit_role_permissions.module_key"

    cond do
      Enum.any?(Report.findings(report_old), &(&1.object_id == id)) ->
        {:fail,
         "s17: #{id} verifies with a finding at comment v100 (between its V53/V142 " <>
           "revisions) — the old-shape revision was not selected"}

      true ->
        MigrationRunner.run_old_chain(ctx.repo, t)
        {:ok, report_new} = Repair.verify(prefix: t, repo: ctx.repo)

        if Enum.any?(Report.findings(report_new), &(&1.object_id == id)) do
          {:fail, "s17: #{id} verifies with a finding at the current comment (post-V142 retype)"}
        else
          :pass
        end
    end
  end

  # ── S18 — concurrency (documented manual, see moduledoc) ───────────────

  # `test/integration/repair_test.exs`'s own S18 note applies verbatim here:
  # a deterministic race needs two genuinely concurrent connections
  # coordinated around the advisory lock — more infrastructure than this
  # single-process harness provides. `PhoenixKit.Migrations.Repair.CommentPolicyTest`'s
  # `concurrent_migration?/2` unit tests cover the DECISION; this scenario
  # stays a documented, deliberate skip rather than a flaky or fake pass.
  defp s18_stub(_ctx) do
    {:skip, "needs-manual-trigger",
     "S18 needs two genuinely concurrent connections racing the before/after raw-comment " <>
       "read around Repair.Environment's advisory lock — not deterministically triggerable " <>
       "from a single-process harness. Unit-covered by " <>
       "PhoenixKit.Migrations.Repair.CommentPolicyTest's concurrent_migration?/2 " <>
       "(dev_docs/squash/README.md documents the manual two-terminal trigger)."}
  end

  # ── S19 — data-dependent create-failure grace ───────────────────────────

  # V137-class hazard: a partial UNIQUE index over a column that already has
  # duplicate non-NULL values. `phoenix_kit_email_logs_aws_message_id_uidx`
  # (V22) is the real, in-manifest instance (V137's own fix target) — BOTH
  # it and its same-column, same-predicate twin `..._index` (V13, never
  # dropped by any later version) are genuinely `presence: :required` on
  # the real chain and must both be dropped first: leaving either one in
  # place blocks the duplicate INSERTs below from ever landing (verified
  # empirically — the surviving twin's own uniqueness fires at insert time).
  defp s19_create_failed(ctx) do
    ensure_generated_manifest_loaded!()
    t = install_repair_target(ctx, "s19")
    objects = manifest_objects(t)

    index_id = "index:phoenix_kit_email_logs_aws_message_id_uidx"
    twin_id = "index:phoenix_kit_email_logs_aws_message_id_index"
    index_object = Enum.find(objects, &(&1.id == index_id))
    twin_object = Enum.find(objects, &(&1.id == twin_id))

    if is_nil(index_object) or is_nil(twin_object) do
      {:fail,
       "s19: #{index_id} and/or #{twin_id} is not in the generated manifest — pick " <>
         "different real unique-index targets for this scenario"}
    else
      drop_manifest_object!(ctx, t, index_object)
      drop_manifest_object!(ctx, t, twin_object)

      dup = "'s19-duplicate-aws-message-id'"
      insert_minimal_row!(ctx, t, "phoenix_kit_email_logs", %{"aws_message_id" => dup})
      insert_minimal_row!(ctx, t, "phoenix_kit_email_logs", %{"aws_message_id" => dup})

      {:ok, report} = Repair.repair(prefix: t, repo: ctx.repo)
      finding = Enum.find(Report.findings(report), &(&1.object_id == index_id))

      run_s19_assertions(ctx, t, index_id, finding)
    end
  end

  defp run_s19_assertions(ctx, t, index_id, finding) do
    cond do
      is_nil(finding) ->
        {:fail, "s19: no finding for #{index_id} after the tamper"}

      finding.kind != :create_failed ->
        {:fail, "s19: #{index_id} finding was #{inspect(finding.kind)}, expected :create_failed"}

      finding.severity != :error ->
        {:fail, "s19: :create_failed finding must be error-severity, got #{finding.severity}"}

      not (finding.message =~ ~r/duplicate/i) ->
        {:fail,
         "s19: :create_failed message has no duplicate-group diagnostic: #{finding.message}"}

      true ->
        %{rows: [[invalid_index_exists]]} =
          RepoHelper.query!(
            ctx.repo,
            "SELECT to_regclass('#{t}.phoenix_kit_email_logs_aws_message_id_uidx') IS NOT NULL"
          )

        if invalid_index_exists do
          {:fail, "s19: an INVALID index was left behind after the failed create"}
        else
          :pass
        end
    end
  end

  # ── S20 — comment > current ──────────────────────────────────────────

  defp s20_comment_above_current(ctx) do
    ensure_generated_manifest_loaded!()
    t = install_repair_target(ctx, "s20")

    current = Postgres.current_version()
    bogus = current + 838

    RepoHelper.query!(ctx.repo, ~s[COMMENT ON TABLE "#{t}".phoenix_kit IS '#{bogus}'])

    verify_result = Repair.verify(prefix: t, repo: ctx.repo)

    # `Postgres.up/1` cannot be called bare here — it uses `Ecto.Migration`
    # DSL functions (`repo()` et al) that need an ACTIVE
    # `Ecto.Migration.Runner` process (normally supplied by
    # `Ecto.Migrator.up/4`); a direct call crashes `:noproc` (verified
    # empirically). `run_old_chain/3` provides that same real context
    # `PhoenixKit.Migrations.up/1` always runs under in production, so this
    # exercises the actual `initial >= target -> :ok` no-op branch rather
    # than the underlying `Postgres.up/1` in isolation.
    up_outcome = MigrationRunner.run_old_chain(ctx.repo, t)
    version_after_up = MigrationRunner.migrated_version(ctx.repo, t)

    cond do
      verify_result != {:error, {:above_current, bogus, current}} ->
        {:fail,
         "s20: Repair.verify/1 on a comment-above-current DB returned #{inspect(verify_result)}, " <>
           "expected {:error, {:above_current, #{bogus}, #{current}}}"}

      up_outcome not in [:ok, :already_up] ->
        {:fail, "s20: up() on a comment-above-current DB returned #{inspect(up_outcome)}"}

      version_after_up != bogus ->
        {:fail,
         "s20: Postgres.up/1 changed the comment (#{bogus} -> #{version_after_up}) instead of " <>
           "silently no-op'ing on a comment ahead of @current_version (repair/doctor are the " <>
           "documented detection surface for this state, per spec 6.4 R6)"}

      true ->
        :pass
    end
  end

  # ---------------------------------------------------------------------------
  # S21 — V164 repair for the V56/V57 flush-order defect (added later; not
  # part of the original spec's S1-S20 matrix — see the moduledoc note).
  # ---------------------------------------------------------------------------
  #
  # V164 (lib/phoenix_kit/migrations/postgres/v164.ex) repairs three things
  # on an install that crossed the historical V56/V57 flush-order bug:
  #   1. NOT NULL on UUIDFKColumns.not_null_uuid_fks/0, minus its own
  #      @relaxed_after_v57 exclusion list.
  #   2. every FK in UUIDFKColumns.fk_constraints/0 that is missing
  #      (NOT VALID then VALIDATE, left NOT VALID with a warning if
  #      validation fails against live orphan rows).
  #   3. phoenix_kit_comments.fk_comments_user_uuid's ON DELETE action
  #      (V72's guessed CASCADE -> the originally-declared SET NULL).
  #
  # The real V56/V57 bug was a per-{table,column} information_schema guard
  # reading stale (unflushed) state — it hit the WHOLE not_null_uuid_fks/0
  # and fk_constraints/0 lists uniformly, not just the slice V164 later
  # chooses to repair. So the defect simulation below drops NOT NULL on
  # EVERY not_null_uuid_fks/0 column (no exclusion) and every fk_constraints/0
  # FK — that is what actually reproduces "an install that crossed V56/V57 in
  # one migrator invocation". @relaxed_after_v57's two columns are then
  # expected to STILL be nullable afterward specifically because V164 never
  # touches them (by design), not because the healthy baseline happens to
  # leave them nullable on its own — it does not, for one of the two:
  # phoenix_kit_ticket_status_history.changed_by_uuid is baked as `NOT NULL`
  # in the squashed V135 baseline (verified against that file's CREATE
  # TABLE) despite being on @relaxed_after_v57 — V164's own moduledoc
  # documents this as a genuine contradiction inside V56/V57's own two
  # declarations (its FK is ON DELETE SET NULL, which NOT NULL makes
  # unsatisfiable), not a later relaxation like phoenix_kit_files.user_uuid.
  # Asserting "still nullable" against the untouched baseline state would
  # therefore silently test nothing for that column; damaging it first and
  # confirming V164 leaves it alone is the real assertion.

  defp s21_v164_repair(ctx) do
    first_failure([
      s21_repair_and_idempotence(ctx),
      s21_orphan_grace(ctx)
    ])
  end

  # ── S21(A)+(B) — repair, then idempotence on the same schema ──────────

  defp s21_repair_and_idempotence(ctx) do
    t = fresh_target(ctx, "s21")
    IO.puts("  [s21] building a fresh, healthy install (current chain) into #{t}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, t)

    IO.puts(
      "  [s21] simulating the V56/V57 flush-order defect in #{t}: dropping every " <>
        "fk_constraints/0 FK, DROP NOT NULL on every not_null_uuid_fks/0 column, and " <>
        "recreating the comments FK with ON DELETE CASCADE..."
    )

    s21_simulate_flush_defect!(ctx, t)

    repair_to = MigrationRunner.current_version()
    repair_from = repair_to - 1

    IO.puts(
      "  [s21] restamping #{t} to v#{repair_from} and running the chain to " <>
        "v#{repair_to} (the repair delta)..."
    )

    restamp_comment!(ctx, t, repair_from)
    MigrationRunner.run_new_chain_existing(ctx.repo, t, repair_from, to_version: repair_to)

    case s21_assert_repaired(ctx, t) do
      :pass ->
        IO.puts("  [s21] PASS: V164 restored every FK / NOT NULL / comments-FK direction")
        s21_idempotence(ctx, t)

      fail ->
        fail
    end
  end

  defp s21_idempotence(ctx, t) do
    repair_to = MigrationRunner.current_version()
    repair_from = repair_to - 1

    IO.puts(
      "  [s21] re-running the repair a second time (restamp to v#{repair_from}, " <>
        "run to v#{repair_to})..."
    )

    before_dump = DumpHelper.dump!(t)
    repair_to = MigrationRunner.current_version()
    restamp_comment!(ctx, t, repair_to - 1)
    MigrationRunner.run_new_chain_existing(ctx.repo, t, repair_to - 1, to_version: repair_to)
    after_dump = DumpHelper.dump!(t)

    case compare_dumps(ctx, "s21_idempotent", before_dump, t, after_dump, t, []) do
      :pass ->
        case s21_assert_repaired(ctx, t) do
          :pass ->
            IO.puts("  [s21] PASS: second repair pass is a byte-identical no-op")
            :pass

          fail ->
            fail
        end

      fail ->
        fail
    end
  end

  defp s21_simulate_flush_defect!(ctx, t) do
    for {table, uuid_fk, _ref_table, _ref_col, _on_delete} <- UUIDFKColumns.fk_constraints() do
      table_str = Atom.to_string(table)
      constraint = UUIDFKColumns.fk_constraint_name(table_str, uuid_fk)

      RepoHelper.query!(
        ctx.repo,
        ~s[ALTER TABLE IF EXISTS "#{t}"."#{table_str}" DROP CONSTRAINT IF EXISTS "#{constraint}"]
      )
    end

    for {table, column} <- UUIDFKColumns.not_null_uuid_fks() do
      table_str = Atom.to_string(table)

      RepoHelper.query!(
        ctx.repo,
        ~s[ALTER TABLE IF EXISTS "#{t}"."#{table_str}" ALTER COLUMN "#{column}" DROP NOT NULL]
      )
    end

    RepoHelper.query!(
      ctx.repo,
      ~s[ALTER TABLE "#{t}".phoenix_kit_comments ] <>
        ~s[ADD CONSTRAINT fk_comments_user_uuid FOREIGN KEY (user_uuid) ] <>
        ~s[REFERENCES "#{t}".phoenix_kit_users(uuid) ON DELETE CASCADE]
    )

    :ok
  end

  defp s21_assert_repaired(ctx, t) do
    relaxed = V164.relaxed_after_v57()

    problems =
      s21_check_fk_constraints(ctx, t) ++
        s21_check_not_null(ctx, t, UUIDFKColumns.not_null_uuid_fks() -- relaxed, false) ++
        s21_check_not_null(ctx, t, relaxed, true) ++
        List.wrap(s21_check_comments_fk(ctx, t))

    if problems == [] do
      :pass
    else
      {:fail, "s21: #{Enum.join(problems, "; ")}"}
    end
  end

  defp s21_check_fk_constraints(ctx, t) do
    UUIDFKColumns.fk_constraints()
    |> Enum.flat_map(fn {table, uuid_fk, ref_table, ref_col, _on_delete} ->
      table_str = Atom.to_string(table)

      if s21_column_exists?(ctx, t, table_str, uuid_fk) and
           s21_column_exists?(ctx, t, ref_table, ref_col) do
        constraint = UUIDFKColumns.fk_constraint_name(table_str, uuid_fk)

        case s21_fk_constraint_state(ctx, t, table_str, constraint) do
          {true, true} ->
            []

          {true, false} ->
            ["#{constraint} exists but is NOT VALID (convalidated=false)"]

          {false, _} ->
            # V164 matches FKs by SHAPE, not by name: where an equivalent FK
            # already enforces this exact pair under another name (Ecto's
            # `<table>_<column>_fkey`, which the baseline creates for
            # phoenix_kit_ai_requests.prompt_uuid), it adopts that one instead of
            # adding a duplicate whose declared ON DELETE would never take
            # effect. So "the fk_-prefixed name is absent" is only a failure when
            # NOTHING enforces the pair. Asserting the name alone would demand
            # the very duplicate the repair now refuses to create.
            s21_unenforced_pair(ctx, t, table_str, uuid_fk, ref_table, ref_col, constraint)
        end
      else
        []
      end
    end)
  end

  # `pairs` is either (not_null_uuid_fks/0 -- @relaxed_after_v57), expected
  # NOT NULL again (expect_nullable? = false), or @relaxed_after_v57 itself,
  # expected to stay nullable (expect_nullable? = true) — V164 never touches
  # the latter.
  defp s21_check_not_null(ctx, t, pairs, expect_nullable?) do
    Enum.flat_map(pairs, fn {table, column} ->
      table_str = Atom.to_string(table)

      case s21_column_nullable(ctx, t, table_str, column) do
        nil ->
          ["#{table_str}.#{column}: column not found (unexpected on a fresh install)"]

        ^expect_nullable? ->
          []

        _other when expect_nullable? ->
          ["#{table_str}.#{column} is NOT NULL, expected to stay nullable (@relaxed_after_v57)"]

        _other ->
          ["#{table_str}.#{column} is nullable, expected NOT NULL after V164's repair"]
      end
    end)
  end

  defp s21_check_comments_fk(ctx, t) do
    case s21_fk_on_delete(ctx, t, "phoenix_kit_comments", "fk_comments_user_uuid") do
      "n" -> nil
      other -> "fk_comments_user_uuid confdeltype=#{inspect(other)}, expected \"n\" (SET NULL)"
    end
  end

  defp s21_column_exists?(ctx, prefix, table, column) do
    %{rows: [[exists]]} =
      RepoHelper.query!(
        ctx.repo,
        "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = $1 " <>
          "AND table_name = $2 AND column_name = $3)",
        [prefix, table, column]
      )

    exists
  end

  defp s21_column_nullable(ctx, prefix, table, column) do
    %{rows: rows} =
      RepoHelper.query!(
        ctx.repo,
        "SELECT is_nullable FROM information_schema.columns WHERE table_schema = $1 " <>
          "AND table_name = $2 AND column_name = $3",
        [prefix, table, column]
      )

    case rows do
      [["YES"]] -> true
      [["NO"]] -> false
      [] -> nil
    end
  end

  # [] when some other constraint enforces (table.column -> ref_table.ref_col);
  # a failure message naming the pair when nothing does.
  defp s21_unenforced_pair(ctx, prefix, table, column, ref_table, ref_col, constraint) do
    %{rows: rows} =
      RepoHelper.query!(
        ctx.repo,
        """
        SELECT c.conname, c.convalidated
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_class ft ON ft.oid = c.confrelid
        WHERE c.contype = 'f'
          AND n.nspname = $1 AND t.relname = $2 AND ft.relname = $3
          AND array_length(c.conkey, 1) = 1 AND array_length(c.confkey, 1) = 1
          AND (SELECT a.attname FROM pg_attribute a
               WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[1]) = $4
          AND (SELECT a.attname FROM pg_attribute a
               WHERE a.attrelid = c.confrelid AND a.attnum = c.confkey[1]) = $5
        """,
        [prefix, table, ref_table, column, ref_col]
      )

    case rows do
      [] ->
        [
          "nothing enforces #{table}.#{column} -> #{ref_table}.#{ref_col} " <>
            "(#{constraint} absent and no equivalently-shaped FK under any other name)"
        ]

      [[adopted, true] | _] ->
        IO.puts("    [s21] #{table}.#{column}: adopted pre-existing #{adopted} (validated)")
        []

      [[adopted, false] | _] ->
        ["#{adopted} enforces #{table}.#{column} but is NOT VALID"]
    end
  end

  defp s21_fk_constraint_state(ctx, prefix, table, constraint) do
    %{rows: rows} =
      RepoHelper.query!(
        ctx.repo,
        "SELECT convalidated FROM pg_constraint c " <>
          "JOIN pg_class t ON t.oid = c.conrelid " <>
          "JOIN pg_namespace n ON n.oid = t.relnamespace " <>
          "WHERE c.conname = $1 AND t.relname = $2 AND n.nspname = $3",
        [constraint, table, prefix]
      )

    case rows do
      [[validated]] -> {true, validated}
      [] -> {false, nil}
    end
  end

  defp s21_fk_on_delete(ctx, prefix, table, constraint) do
    %{rows: rows} =
      RepoHelper.query!(
        ctx.repo,
        "SELECT confdeltype FROM pg_constraint c " <>
          "JOIN pg_class t ON t.oid = c.conrelid " <>
          "JOIN pg_namespace n ON n.oid = t.relnamespace " <>
          "WHERE c.conname = $1 AND t.relname = $2 AND n.nspname = $3",
        [constraint, table, prefix]
      )

    case rows do
      [[deltype]] -> deltype
      [] -> nil
    end
  end

  defp restamp_comment!(ctx, prefix, version) do
    RepoHelper.query!(ctx.repo, ~s[COMMENT ON TABLE "#{prefix}".phoenix_kit IS '#{version}'])
    :ok
  end

  # ── S21(C) — orphan grace: constraint added NOT VALID, no data loss ────
  #
  # phoenix_kit_billing_profiles.user_uuid (SET NULL) is the cheapest real
  # fk_constraints/0 target to insert an orphan row against: its only
  # NOT NULL-without-default columns are inserted_at/updated_at (both
  # handled generically by insert_minimal_row!/4's "now()" clause), it
  # carries no CHECK constraint, and — unlike phoenix_kit_role_permissions
  # (a NOT NULL, still-enforced FK to phoenix_kit_user_roles) or
  # phoenix_kit_tickets (a status column) — it has no OTHER column that
  # would need a real parent row or a specific literal to insert around.
  # Verified against lib/phoenix_kit/migrations/postgres/v135.ex's own
  # CREATE TABLE + constraint list for this table.

  @s21_orphan_table "phoenix_kit_billing_profiles"
  @s21_orphan_fk_column "user_uuid"
  @s21_orphan_uuid "00000000-0000-0000-0000-000000000000"

  defp s21_orphan_grace(ctx) do
    t = fresh_target(ctx, "s21_orph")

    IO.puts(
      "  [s21C] building a fresh, healthy install into #{t}, dropping " <>
        "fk_billing_profiles_user_uuid, and inserting a #{@s21_orphan_table} row whose " <>
        "#{@s21_orphan_fk_column} points at a non-existent user before restamping to " <>
        "and running V164..."
    )

    MigrationRunner.run_new_chain_fresh(ctx.repo, t)

    constraint = UUIDFKColumns.fk_constraint_name(@s21_orphan_table, @s21_orphan_fk_column)

    RepoHelper.query!(
      ctx.repo,
      ~s[ALTER TABLE "#{t}"."#{@s21_orphan_table}" DROP CONSTRAINT "#{constraint}"]
    )

    row_uuid =
      insert_minimal_row!(ctx, t, @s21_orphan_table, %{
        @s21_orphan_fk_column => "'#{@s21_orphan_uuid}'"
      })

    repair_to = MigrationRunner.current_version()
    restamp_comment!(ctx, t, repair_to - 1)
    MigrationRunner.run_new_chain_existing(ctx.repo, t, repair_to - 1, to_version: repair_to)

    {exists, validated} = s21_fk_constraint_state(ctx, t, @s21_orphan_table, constraint)
    row_survived? = row_exists?(ctx, t, @s21_orphan_table, "uuid", row_uuid)

    %{rows: [[current_fk_value]]} =
      RepoHelper.query!(
        ctx.repo,
        ~s[SELECT "#{@s21_orphan_fk_column}"::text FROM "#{t}"."#{@s21_orphan_table}" ] <>
          ~s[WHERE "uuid" = '#{row_uuid}']
      )

    cond do
      not exists ->
        {:fail, "s21(C): #{constraint} was not recreated by V164 despite the orphan row"}

      validated ->
        {:fail, "s21(C): #{constraint} validated despite the orphan row — expected NOT VALID"}

      not row_survived? ->
        {:fail, "s21(C): the orphan #{@s21_orphan_table} row was deleted by V164's repair"}

      current_fk_value != @s21_orphan_uuid ->
        {:fail,
         "s21(C): the orphan row's #{@s21_orphan_fk_column} was modified by V164's repair " <>
           "(now #{inspect(current_fk_value)}, expected #{@s21_orphan_uuid} unchanged)"}

      true ->
        IO.puts(
          "  [s21C] PASS: #{constraint} exists but NOT VALID (convalidated=false); orphan " <>
            "row untouched"
        )

        :pass
    end
  end

  # ---------------------------------------------------------------------------
  # S22 — per-version stepping equivalence (added later; not part of the
  # original spec's S1-S20 matrix — see the moduledoc note).
  # ---------------------------------------------------------------------------
  #
  # s1 proves fresh-install equivalence for ONE multi-version invocation; s3
  # proves an upgrade from the floor (and floor+3) lands on the same schema.
  # Neither ever migrates a delta in its OWN separate `Ecto.Migrator`
  # invocation the way a real consumer app applies pending migrations one
  # file at a time — which is exactly the shape of the historical V56/V57
  # defect: `execute/1` merely queues DDL, so an immediate `repo().query`
  # guard later in the SAME invocation could see only flushed state and miss
  # an earlier version's still-queued change. A version added later that
  # reintroduces that class would stay green under s1/s3/every other
  # scenario here, since none of them ever isolates a delta into its own
  # invocation. s22 closes that gap directly: build side A with the whole
  # chain in ONE `up/1` call, build side B by stepping the baseline and then
  # every delta through `MigrationRunner.run_chain_stepwise/5` (already used
  # by `generate_baseline.exs` for its own per-version snapshots — no new
  # migrator plumbing needed here), asserting the version comment after
  # every single step, then diff A against B with the same dump + seed-data
  # oracle every other scenario uses.

  defp s22_stepwise_equivalence(ctx) do
    floor = MigrationRunner.floor()
    current = MigrationRunner.current_version()

    a = fresh_target(ctx, "s22_one")
    IO.puts("  [s22] single invocation: v#{floor}..v#{current} in one up() call into #{a}...")
    MigrationRunner.run_new_chain_fresh(ctx.repo, a)

    b = fresh_target(ctx, "s22_step")

    IO.puts(
      "  [s22] stepwise: baseline v#{floor}, then each delta v#{floor + 1}..v#{current} as " <>
        "its own separate migrator invocation, into #{b}, asserting the version comment " <>
        "after every step..."
    )

    mismatches = s22_run_stepwise_and_assert(ctx, b, floor, current)

    if mismatches != [] do
      {:fail, "s22: #{Enum.join(mismatches, "; ")}"}
    else
      delta_count = current - floor

      IO.puts(
        "  [s22] all #{delta_count + 1} steps landed (baseline v#{floor} + #{delta_count} " <>
          "delta(s) v#{floor + 1}..v#{current}), each asserted individually"
      )

      dump_a = DumpHelper.dump!(a)
      dump_b = DumpHelper.dump!(b)
      seeds_a = DumpHelper.dump_seed_data!(a)
      seeds_b = DumpHelper.dump_seed_data!(b)

      first_failure([
        compare_dumps(ctx, "s22", dump_a, a, dump_b, b, ctx.whitelist),
        compare_seed_texts(ctx, "s22", seeds_a, a, seeds_b, b)
      ])
    end
  end

  # Drives `MigrationRunner.run_chain_stepwise/5` over `floor..current` on
  # `prefix`, asserting after EACH step that the version comment reads the
  # version just applied. Returns a list of human-readable mismatch strings
  # (empty when every step matched). An Agent accumulates results because
  # the stepwise callback runs synchronously, one step at a time, in THIS
  # process — `run_chain_stepwise/5`'s own `Enum.each/2` calls it right
  # after each `Ecto.Migrator.up/4` call returns, no Task boundary at this
  # level — the same pattern `generate_baseline.exs`'s `run_stepwise/4` uses
  # for its per-version catalog snapshots.
  defp s22_run_stepwise_and_assert(ctx, prefix, floor, current) do
    {:ok, results} = Agent.start_link(fn -> [] end)

    try do
      MigrationRunner.run_chain_stepwise(ctx.repo, prefix, floor..current, fn version ->
        actual = MigrationRunner.migrated_version(ctx.repo, prefix)
        Agent.update(results, &[{version, actual} | &1])
      end)

      results
      |> Agent.get(&Enum.reverse/1)
      |> Enum.filter(fn {expected, actual} -> actual != expected end)
      |> Enum.map(fn {expected, actual} ->
        "after stepping to v#{expected} the comment in #{prefix} reads #{actual}"
      end)
    after
      Agent.stop(results)
    end
  end

  # ---------------------------------------------------------------------------
  # Targets, cleanup, mode plumbing
  # ---------------------------------------------------------------------------

  # A fresh, empty migration target. Mode B: a named scratch schema (registered
  # for cleanup BEFORE creation, so exceptions cannot leak it). Mode A: public,
  # reset via the gated DROP SCHEMA public CASCADE recipe — sequential
  # comparisons must therefore capture their dumps BEFORE requesting the next
  # target.
  defp fresh_target(%{mode: :a} = ctx, _slot) do
    reset_public!(ctx)
    "public"
  end

  defp fresh_target(%{mode: :b} = ctx, slot), do: named_target(ctx, slot)

  # A named scratch schema in BOTH modes — for scenarios that need coexisting
  # installs (s11) regardless of mode.
  defp named_target(ctx, slot) do
    name = scratch_name(ctx, slot)
    register_schema(ctx, name)
    drop_schema!(ctx, name)
    name
  end

  # The V26/V56 conventions embed the SCHEMA NAME INTO object names
  # (`<prefix>_phoenix_kit_..._index`), so a scratch schema name is not free:
  # schema + "_" + the longest emitted object name must stay within Postgres's
  # 63-byte NAMEDATALEN or the identifier is silently TRUNCATED. Two
  # consequences this guard exists to prevent, both observed for real:
  #   * comparing two installs whose schema names differ in LENGTH truncates
  #     one side only, and the dump differ reports a phantom rename
  #     (`..._checksum_index` vs `..._checksum_inde`) — that is why every
  #     comparison pair below uses equal-length slots;
  #   * a long-enough name truncates BOTH sides, so the harness silently stops
  #     testing the real object names the manifest expects.
  # @longest_embedded_object_name is measured from the manifest; the budget is
  # 63 - 1 - that.
  defp scratch_name(ctx, slot) do
    name = "#{ctx.base}_#{slot}"
    validate_identifier!(name)

    if byte_size(name) > @max_schema_bytes do
      raise "scratch schema #{inspect(name)} is #{byte_size(name)} bytes; the " <>
              "V26/V56 prefix-embedded object names allow at most " <>
              "#{@max_schema_bytes} (63 - 1 - #{@longest_embedded_object_name} for the " <>
              "longest embedded name) before Postgres truncates identifiers — " <>
              "shorten PK_SQUASH_SCHEMA or the slot"
    end

    name
  end

  defp below_floor_schema(ctx), do: scratch_name(ctx, "below_floor")

  defp register_schema(ctx, name) do
    Agent.update(ctx.cleanup, &[name | &1])
  end

  defp drop_registered_schemas(%{cleanup: nil}), do: :ok
  defp drop_registered_schemas(%{repo: nil}), do: :ok

  defp drop_registered_schemas(ctx) do
    schemas = ctx.cleanup |> Agent.get(& &1) |> Enum.uniq()

    cond do
      schemas == [] ->
        :ok

      ctx.verbose ->
        IO.puts("  retaining scratch schemas (--verbose): #{Enum.join(schemas, ", ")}")

      true ->
        Enum.each(schemas, fn name ->
          try do
            drop_schema!(ctx, name)
          rescue
            e ->
              IO.puts("  WARN: cleanup of schema #{name} failed: #{Exception.message(e)}")
          end
        end)
    end
  end

  defp drop_schema!(_ctx, "public") do
    raise "refusing DROP SCHEMA on public — mode A resets go through reset_public!/1"
  end

  defp drop_schema!(ctx, name) do
    refuse_live_schema!(ctx, name)
    validate_identifier!(name)
    RepoHelper.query!(ctx.repo, ~s[DROP SCHEMA IF EXISTS "#{name}" CASCADE])
    :ok
  end

  # Spec section 8.1 option (b) reset recipe. Reached only behind the
  # PK_SQUASH_ALLOW_RESET gate (enforced before any scenario runs).
  # Tripwire ON TOP of the gate: a database whose public schema carries a
  # populated phoenix_kit_users table is a LIVE INSTALL, not a scratch DB —
  # refuse even with the gate set (no override; point PG* at a scratch DB).
  defp reset_public!(ctx) do
    refuse_live_install!(ctx)
    IO.puts("  resetting public (DROP SCHEMA public CASCADE)...")
    RepoHelper.query!(ctx.repo, "DROP SCHEMA public CASCADE")
    RepoHelper.query!(ctx.repo, "CREATE SCHEMA public")
    :ok
  end

  # Named-schema twin of refuse_live_install!: scratch schemas this harness
  # creates never contain user rows (migrations alone never insert users), so
  # a populated phoenix_kit_users in a schema we are about to drop means the
  # configured name collides with a LIVE prefixed install — refuse, no
  # override (pick a different base name).
  defp refuse_live_schema!(ctx, schema) do
    %{rows: [[reg]]} =
      RepoHelper.query!(ctx.repo, "SELECT to_regclass('#{schema}.phoenix_kit_users')::text")

    users =
      if reg do
        %{rows: [[n]]} =
          RepoHelper.query!(ctx.repo, "SELECT count(*) FROM \"#{schema}\".phoenix_kit_users")

        n
      else
        0
      end

    if users > 0 do
      raise """
      refusing DROP SCHEMA #{schema}: it contains #{users} row(s) in
      #{schema}.phoenix_kit_users — that is a LIVE prefixed PhoenixKit install,
      not a harness scratch schema. Change the scratch base name; there is
      deliberately no override.
      """
    end

    :ok
  end

  defp refuse_live_install!(ctx) do
    %{rows: [[reg]]} =
      RepoHelper.query!(ctx.repo, "SELECT to_regclass('public.phoenix_kit_users')::text")

    users =
      if reg do
        %{rows: [[n]]} =
          RepoHelper.query!(ctx.repo, "SELECT count(*) FROM public.phoenix_kit_users")

        n
      else
        0
      end

    if users > 0 do
      raise """
      refusing DROP SCHEMA public: this database has #{users} row(s) in
      public.phoenix_kit_users — it looks like a LIVE PhoenixKit install, not a
      scratch DB. There is deliberately no override; point PG* env at the
      operator-provided scratch database (spec section 8.1).
      """
    end

    :ok
  end

  defp attach_repo(ctx, selected) do
    needs_db? = Enum.any?(selected, &(:db in &1.requires))

    cond do
      not needs_db? ->
        ctx

      not db_env_present?() ->
        IO.puts(
          "NOTE: PG* env not set — every [DB] scenario will SKIP " <>
            "(operator scratch DB pending, spec 8.1)."
        )

        ctx

      true ->
        repo = RepoHelper.start!()
        enforce_mode_a_gate!(ctx)
        %{ctx | repo: repo}
    end
  end

  defp enforce_mode_a_gate!(%{mode: :a}) do
    database = RepoHelper.connection_env().database

    case System.get_env("PK_SQUASH_ALLOW_RESET") do
      ^database ->
        IO.puts(
          "MODE A: this run will repeatedly DROP SCHEMA public CASCADE in " <>
            "database #{database} (confirmed via PK_SQUASH_ALLOW_RESET)."
        )

        :ok

      other ->
        halt_usage("""
        Mode A resets the public schema of #{database} with DROP SCHEMA public CASCADE
        (spec 8.1 option (b) recipe). That destroys EVERYTHING in that schema,
        including extensions and their dependent objects.

        To confirm #{database} is a disposable scratch DB, set:

            PK_SQUASH_ALLOW_RESET=#{database}

        (currently: #{inspect(other)})
        """)
    end
  end

  defp enforce_mode_a_gate!(_ctx), do: :ok

  defp db_env_present? do
    RepoHelper.connection_env()
    true
  rescue
    _ -> false
  end

  # ---------------------------------------------------------------------------
  # Comparison + retention helpers
  # ---------------------------------------------------------------------------

  defp compare_dumps(ctx, id, dump_a, schema_a, dump_b, schema_b, whitelist) do
    case DumpHelper.compare(dump_a, schema_a, dump_b, schema_b, legacy_optional: whitelist) do
      :equal ->
        IO.puts("  [#{id}] dumps identical after normalization")
        :pass

      {:equal_modulo_whitelist, %{only_a: only_a, only_b: only_b}} ->
        IO.puts("  [#{id}] dumps identical modulo the :legacy_optional whitelist:")
        Enum.each(only_a, &IO.puts("    only in #{schema_a}: #{&1}"))
        Enum.each(only_b, &IO.puts("    only in #{schema_b}: #{&1}"))
        :pass

      {:diff, text} ->
        retain(ctx, "#{id}_a.sql", dump_a, :always)
        retain(ctx, "#{id}_b.sql", dump_b, :always)
        retain(ctx, "#{id}.diff", text, :always)
        IO.puts("  [#{id}] dumps differ (unlisted divergence = FAILURE):")
        print_capped(text)
        {:fail, "[#{id}] normalized dumps differ (retained under #{ctx.out_dir})"}
    end
  end

  defp compare_seed_texts(ctx, id, text_a, label_a, text_b, label_b) do
    case DumpHelper.unified_diff(text_a, text_b, label_a, label_b) do
      :equal ->
        IO.puts("  [#{id}] seed dumps identical after normalization")
        :pass

      {:diff, diff} ->
        retain(ctx, "#{id}_seeds_a.txt", text_a, :always)
        retain(ctx, "#{id}_seeds_b.txt", text_b, :always)
        retain(ctx, "#{id}_seeds.diff", diff, :always)
        IO.puts("  [#{id}] seed dumps differ:")
        print_capped(diff)
        {:fail, "[#{id}] seed dumps differ (retained under #{ctx.out_dir})"}
    end
  end

  # S2 tolerance (spec 8.2): template rows must match when the seeder ran;
  # absence is acceptable only for release-mode installs. Under `mix run` the
  # seeder should have run — an empty section is suspicious, so warn loudly.
  defp warn_if_templates_absent(seed_text) do
    lines = String.split(seed_text, "\n")

    case Enum.split_while(lines, &(&1 != "-- table: phoenix_kit_email_templates")) do
      {_, []} ->
        if Enum.any?(lines, &String.starts_with?(&1, "-- table: phoenix_kit_email_templates")) do
          IO.puts("  WARN: phoenix_kit_email_templates table MISSING from the install")
        else
          IO.puts("  WARN: email-templates section absent from the seed dump")
        end

      {_, [_marker | rest]} ->
        rows =
          rest
          |> Enum.take_while(&(not String.starts_with?(&1, "-- table:")))
          |> Enum.reject(&(&1 == ""))

        # First row is the CSV header.
        if length(rows) <= 1 do
          IO.puts(
            "  WARN: system email templates absent (seeder skipped?) — acceptable " <>
              "only for release-mode installs (S2 tolerance)"
          )
        end
    end

    :ok
  end

  defp retain(ctx, name, content, when_) do
    if when_ == :always or ctx.verbose do
      File.mkdir_p!(ctx.out_dir)
      path = Path.join(ctx.out_dir, name)
      File.write!(path, content)
      IO.puts("  retained #{path}")
    end

    :ok
  end

  defp print_capped(text, max_lines \\ 200) do
    lines = String.split(text, "\n")
    Enum.each(Enum.take(lines, max_lines), &IO.puts/1)
    extra = length(lines) - max_lines
    if extra > 0, do: IO.puts("  ... (#{extra} more lines; see retained files)")
    :ok
  end

  defp first_failure(results), do: Enum.find(results, &(&1 != :pass)) || :pass

  # ---------------------------------------------------------------------------
  # Reference dumps (cross-checkout S1/S2 handoff)
  # ---------------------------------------------------------------------------

  defp s1_ref_path(ctx), do: Path.join(ctx.ref_dir, "s1_old_chain.sql")
  defp s2_ref_path(ctx), do: Path.join(ctx.ref_dir, "s2_old_chain_seeds.txt")

  defp maybe_save_s1_reference(ctx, schema, raw_dump) do
    if Postgres.initial_version() == 1 do
      save_ref(
        ctx,
        s1_ref_path(ctx),
        [kind: "s1", schema: schema, chain_version: MigrationRunner.current_version()],
        raw_dump
      )
    else
      IO.puts("  (squashed registry: not overwriting the OLD-chain S1 reference)")
    end
  end

  defp maybe_save_s2_reference(ctx, seed_text) do
    if Postgres.initial_version() == 1 do
      save_ref(
        ctx,
        s2_ref_path(ctx),
        [kind: "s2", chain_version: MigrationRunner.current_version()],
        seed_text
      )
    else
      IO.puts("  (squashed registry: not overwriting the OLD-chain S2 reference)")
    end
  end

  defp save_ref(ctx, path, kvs, body) do
    File.mkdir_p!(ctx.ref_dir)
    header = @ref_header_prefix <> " " <> Enum.map_join(kvs, " ", fn {k, v} -> "#{k}=#{v}" end)
    File.write!(path, header <> "\n" <> body)
    IO.puts("  wrote reference #{path}")
    :ok
  end

  defp load_ref!(path) do
    content = File.read!(path)

    case String.split(content, "\n", parts: 2) do
      [@ref_header_prefix <> rest, body] ->
        meta = ~r/(\w+)=(\S+)/ |> Regex.scan(rest) |> Map.new(fn [_, k, v] -> {k, v} end)
        {meta, body}

      _ ->
        raise "malformed reference file #{path}: first line must start with " <>
                "'#{@ref_header_prefix}' (references are tool-written; regenerate, " <>
                "never hand-edit)"
    end
  end

  # ---------------------------------------------------------------------------
  # Catalog probes
  # ---------------------------------------------------------------------------

  defp installed_extensions(ctx) do
    %{rows: rows} =
      RepoHelper.query!(ctx.repo, "SELECT extname FROM pg_extension ORDER BY extname")

    List.flatten(rows)
  end

  defp pk_table_count(ctx, schema) do
    %{rows: [[count]]} =
      RepoHelper.query!(
        ctx.repo,
        "SELECT count(*)::int FROM information_schema.tables " <>
          "WHERE table_schema = $1 " <>
          "AND (table_name LIKE 'phoenix_kit%' OR table_name LIKE 'oban%')",
        [schema]
      )

    count
  end

  # ---------------------------------------------------------------------------
  # Configuration
  # ---------------------------------------------------------------------------

  defp build_ctx(opts, phase) do
    mode =
      case Keyword.get(opts, :mode, "b") do
        "a" -> :a
        "b" -> :b
        other -> halt_usage("--mode must be 'a' or 'b', got #{inspect(other)}")
      end

    base = System.get_env("PK_SQUASH_SCHEMA", "pk_sqv")
    validate_identifier!(base)

    if byte_size(base) > @max_base_bytes do
      halt_usage(
        "PK_SQUASH_SCHEMA #{inspect(base)} too long (#{byte_size(base)} bytes); " <>
          "scratch suffixes must fit PostgreSQL's 63-byte identifier limit"
      )
    end

    %{
      phase: phase,
      mode: mode,
      verbose: Keyword.get(opts, :verbose, false),
      base: base,
      whitelist: whitelist_from_env(),
      ref_dir: System.get_env("PK_SQUASH_REF_DIR", Path.join(@script_dir, "reference")),
      out_dir: System.get_env("PK_SQUASH_OUT_DIR", Path.join(@script_dir, "out")),
      # :check phase never connects; :env marks "env present" for runnability
      # listing only. :run phase replaces this via attach_repo/2.
      repo: if(phase == :check and db_env_present?(), do: :env, else: nil),
      cleanup: nil
    }
  end

  defp whitelist_from_env do
    case System.get_env("PK_SQUASH_WHITELIST") do
      nil -> @legacy_optional_default
      "" -> []
      raw -> raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
  end

  defp select_scenarios!(nil), do: scenarios()

  defp select_scenarios!(filter) do
    ids =
      filter
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    known = MapSet.new(scenarios(), & &1.id)
    unknown = Enum.reject(ids, &MapSet.member?(known, &1))

    if unknown != [] do
      halt_usage(
        "unknown scenario id(s): #{Enum.join(unknown, ", ")}\n" <>
          "known ids: #{Enum.map_join(scenarios(), ", ", & &1.id)}"
      )
    end

    set = MapSet.new(ids)
    Enum.filter(scenarios(), &MapSet.member?(set, &1.id))
  end

  # Schema names are interpolated into DDL; enforce the same charset the
  # migration entry points enforce (Helpers.validate_prefix!/1).
  defp validate_identifier!(name) do
    unless is_binary(name) and Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name) do
      halt_usage("invalid schema identifier #{inspect(name)}: must match [a-z_][a-z0-9_]*")
    end

    :ok
  end

  defp halt_usage(message) do
    IO.puts("ERROR: #{message}\n")
    IO.puts(@usage)
    System.halt(2)
  end
end

PhoenixKit.Squash.Verify.main(System.argv())
