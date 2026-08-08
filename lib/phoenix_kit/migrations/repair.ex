defmodule PhoenixKit.Migrations.Repair do
  @moduledoc """
  Runtime, additive-only verify-and-repair for the PhoenixKit migration
  chain (spec §6, D6). Two public entry points:

    * `verify/1` — read-only. Never executes a create, never writes the
      version comment, never calls `Oban.Migration.up/1`.
    * `repair/1` — `dry_run: false` (the default) actually applies missing
      objects and comment-policy writes; `dry_run: true` runs the identical
      pipeline but only *plans* (see `PhoenixKit.Migrations.Repair.Executor.create_action/2`).

  Both return `{:ok, PhoenixKit.Migrations.Repair.Report.t()}` on a completed
  run, or `{:error, reason}` for a condition the pipeline refuses to proceed
  past (manifest not generated, below-floor, comment ahead of code, a
  pooled connection without `--unsafe-pooled`, or a detected concurrent
  migration). `reason` is always either `:not_generated` or a `{tag, ...}`
  tuple; `error_message/1` renders any of them to the same text
  `mix phoenix_kit.repair`/`mix phoenix_kit.doctor` print.

  ## Options

    * `:prefix` — schema prefix, already resolved (default `"public"`).
      Callers resolving it from config/`--prefix`
      (`PhoenixKit.Install.PrefixConfig.resolve_prefix/1`) do so before
      calling here — this module does not read application config itself,
      the same way `PhoenixKit.Migrations.Postgres.up/1` does not.
    * `:repo` — defaults to `PhoenixKit.RepoHelper.repo/0`.
    * `:adopt` — R4 (§6.4). Only consulted when the raw comment is `nil`.
    * `:heal_comment` — R2's stale-low heal. Only consulted for an
      in-range comment whose marker cross-check found `{:stale_low, _}`.
    * `:unsafe_pooled` — skip the advisory lock and FK `VALIDATE` (§6.3).
      Required (else `{:error, {:pooled_connection, message}}`) whenever
      `PhoenixKit.Migrations.Repair.Environment.pooled?/2` says yes AND this
      run would actually write (`repair/1` with `dry_run: false`, the
      default). Never consulted for a read-only pass — `verify/1`, or
      `repair/1` with `dry_run: true` — which takes neither the lock nor
      the FK `VALIDATE` path regardless of the pooled verdict, so a pooled
      connection can never block one. This is what lets
      `mix phoenix_kit.doctor`'s manifest-repair check call `verify/1`
      plainly, with no flag, and still get real information on a
      PgBouncer-fronted deployment (a real, documented topology for this
      codebase's own runtime).
    * `:dry_run` — `repair/1` only; `verify/1` always runs as if this were
      `true` regardless of what is passed.

  ## Repair vs. a concurrently running migration

  `Postgres.up/1` and `.down/1` take the same advisory lock key this module
  takes (`PhoenixKit.Migrations.Repair.Environment.with_lock/2`) — spec §6.1 —
  but the exclusion that buys is **one-directional**: a chain run started while
  a repair holds the lock waits for it, whereas a repair started while a chain
  run is mid-DDL is not blocked, because the generated wrappers disable their
  DDL transaction and the migration side's transaction-scoped lock is therefore
  released after its own statement (see `Postgres.acquire_chain_lock!/0` for the
  full reasoning). For that direction — and on a pooled connection, where
  advisory locking cannot be trusted at all — the before/after raw-comment
  re-read (`PhoenixKit.Migrations.Repair.CommentPolicy.concurrent_migration?/2`,
  S18) remains the mechanism, and it *detects* rather than prevents.
  """

  alias PhoenixKit.Migrations.ExpectedSchema.Resolver
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.Repair.CommentPolicy
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Environment
  alias PhoenixKit.Migrations.Repair.Executor
  alias PhoenixKit.Migrations.Repair.ObanRunner
  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Migrations.Repair.Report
  alias PhoenixKit.Migrations.Repair.Scope
  alias PhoenixKit.RepoHelper

  # Spec §6.3's preflight: "asserts server_version within a declared
  # supported range". Deliberately never a hard abort (`add_server_version_finding/2`
  # only ever adds an `:info`-severity finding) — an operator running repair
  # against a genuinely newer/older major is exactly the case this tool
  # should still attempt to help with, just with a flagged caveat on any
  # structural divergence it reports (§9's risk row: PG-major deparse
  # differences → false divergences; the finding is the mitigation, not a
  # gate).
  @supported_pg_majors 13..18

  @typedoc "Every `{:error, _}` shape this module returns; see moduledoc."
  @type error_reason ::
          :not_generated
          | {:not_installed, prefix :: String.t()}
          | {:below_floor, comment :: pos_integer(), floor :: pos_integer()}
          | {:above_current, comment :: pos_integer(), current :: pos_integer()}
          | {:pooled_connection, String.t()}
          | {:concurrent_migration, before :: term(), after_ :: term()}

  @doc "Read-only. See moduledoc."
  @spec verify(keyword()) :: {:ok, Report.t()} | {:error, error_reason()}
  def verify(opts \\ []) do
    opts |> Keyword.put(:dry_run, true) |> run()
  end

  @doc "Applies missing objects and comment-policy writes unless `dry_run: true`. See moduledoc."
  @spec repair(keyword()) :: {:ok, Report.t()} | {:error, error_reason()}
  def repair(opts \\ []) do
    opts |> Keyword.put_new(:dry_run, false) |> run()
  end

  @doc "Renders any `error_reason()` this module returns to operator-facing text — the wording `mix phoenix_kit.repair`/`mix phoenix_kit.doctor` both print verbatim."
  @spec error_message(error_reason()) :: String.t()
  def error_message(:not_generated), do: Resolver.not_generated_message()

  def error_message({:not_installed, prefix}) do
    "PhoenixKit is not installed at prefix #{inspect(prefix)} — run mix phoenix_kit.install first."
  end

  def error_message({:below_floor, comment, floor}) do
    "DB is at version #{comment}, below this release's floor (#{floor}). Repair is a " <>
      "completeness tool, not a migration bridge — install the last 1.x bridge release, " <>
      "run mix phoenix_kit.update to reach the floor, then upgrade to this release."
  end

  def error_message({:above_current, comment, current}) do
    "DB claims version #{comment} but this code supports up to #{current} — upgrade " <>
      "phoenix_kit first."
  end

  def error_message({:pooled_connection, message}), do: message

  def error_message({:concurrent_migration, _before, _after}) do
    "A migration changed the version comment while repair was running (concurrent " <>
      "migration detected). Re-run once it finishes."
  end

  # ---------------------------------------------------------------------------
  # Pipeline
  # ---------------------------------------------------------------------------

  defp run(opts) do
    case Resolver.resolve() do
      {:error, :not_generated} -> {:error, :not_generated}
      {:ok, manifest} -> run_with_manifest(manifest, opts)
    end
  end

  defp run_with_manifest(manifest, opts) do
    prefix = Keyword.get(opts, :prefix, "public")
    Helpers.validate_prefix!(prefix)
    repo = Keyword.get(opts, :repo) || RepoHelper.repo()

    ctx = %{
      manifest: manifest,
      repo: repo,
      prefix: prefix,
      floor: Postgres.initial_version(),
      current: Postgres.current_version(),
      dry_run: Keyword.get(opts, :dry_run, true),
      adopt?: Keyword.get(opts, :adopt, false),
      heal_comment?: Keyword.get(opts, :heal_comment, false),
      unsafe_pooled?: Keyword.get(opts, :unsafe_pooled, false)
    }

    if ctx.dry_run do
      # A read-only pass never writes, never needs the advisory lock for
      # correctness (there is nothing else it could safely serialize
      # against — see `Environment`'s moduledoc: the lock only ever
      # protects concurrent WRITERS from each other), and never calls FK
      # `VALIDATE` (`missing_finding/3`'s `dry_run: true` clause returns a
      # `:missing`/`:repairable` finding directly and never reaches
      # `Executor.create/4` at all). The pooled-connection gate below exists
      # to protect exactly those two things, so it does not apply here —
      # skip straight to the lock-free pipeline regardless of the pooled
      # verdict (and skip probing for it at all, saving `Environment.pooled?/2`'s
      # own two extra round trips on every dry run).
      locked_pipeline(ctx, skip_validate: true)
    else
      pooled = Environment.pooled?(repo, repo.config())

      cond do
        pooled and not ctx.unsafe_pooled? ->
          {:error, {:pooled_connection, pooled_message()}}

        pooled ->
          locked_pipeline(ctx, skip_validate: true)

        true ->
          Environment.with_lock(repo, fn -> locked_pipeline(ctx, skip_validate: false) end)
      end
    end
  end

  defp pooled_message do
    "Detected a pooled connection (PgBouncer transaction-mode or similar). Repair needs " <>
      "the advisory lock and FK VALIDATE to run against a direct connection; pass " <>
      "--unsafe-pooled to proceed anyway (skips both — see mix phoenix_kit.repair --help)."
  end

  defp locked_pipeline(ctx, skip_validate: skip_validate?) do
    comment1 = Probe.raw_comment(ctx.repo, ctx.prefix)

    case CommentPolicy.classify(comment1, ctx.floor, ctx.current) do
      :not_installed ->
        {:error, {:not_installed, ctx.prefix}}

      {:below_floor, comment} ->
        {:error, {:below_floor, comment, ctx.floor}}

      {:above_current, comment} ->
        {:error, {:above_current, comment, ctx.current}}

      :adopt_required ->
        run_adopt_branch(ctx, comment1, skip_validate?)

      {:in_range, comment} ->
        run_in_range_branch(ctx, comment1, comment, skip_validate?)
    end
  end

  # ── :adopt_required (R4) ────────────────────────────────────────────

  defp run_adopt_branch(ctx, comment1, skip_validate?) do
    report =
      ctx.prefix
      |> Report.new(ctx.dry_run, %{comment: comment1, floor: ctx.floor, current: ctx.current})
      |> add_server_version_finding(ctx)

    if ctx.adopt? do
      run_adopt(ctx, comment1, report, skip_validate?)
    else
      finding = finding(:adopt_required, :error, nil, nil, adopt_required_message())
      {:ok, Report.add_finding(report, finding)}
    end
  end

  defp adopt_required_message do
    "PhoenixKit tables exist but the version comment is missing (half-installed, " <>
      "adopted, or PgBouncer dropped it). Repair refuses to guess — pass --adopt to " <>
      "converge the floor-level slice and stamp the floor version if it comes back " <>
      "clean, then run mix phoenix_kit.update for the remaining deltas."
  end

  defp run_adopt(ctx, comment1, report, skip_validate?) do
    objects = ctx.manifest.objects(ctx.prefix)
    invariants = ctx.manifest.data_invariants(ctx.prefix)
    snapshot = Probe.snapshot(ctx.repo, ctx.prefix)

    report =
      apply_scope(ctx, objects, invariants, snapshot, ctx.floor, report, skip_validate?)

    report = delegate_oban(ctx, report)

    with :ok <- check_no_concurrent_migration(ctx, comment1) do
      # From `report` itself, not the `apply_scope/7` return above —
      # `delegate_oban/2` may have just appended an `:oban_delegation_failed`
      # finding, and the clean gate must see it (an Oban failure should
      # block the stamp exactly like any other error-severity finding).
      clean? = CommentPolicy.floor_verify_clean?(Report.findings(report))

      report =
        case CommentPolicy.adopt_outcome(clean?, ctx.floor) do
          {:stamp, floor} ->
            apply_comment_action(ctx, report, {:adopted, floor}, {:would_adopt, floor})

          :no_stamp ->
            report
        end

      {:ok, report}
    end
  end

  # ── {:in_range, comment} (R2/R5) ────────────────────────────────────

  defp run_in_range_branch(ctx, comment1, comment, skip_validate?) do
    report =
      ctx.prefix
      |> Report.new(ctx.dry_run, %{comment: comment1, floor: ctx.floor, current: ctx.current})
      |> add_server_version_finding(ctx)

    objects = ctx.manifest.objects(ctx.prefix)
    invariants = ctx.manifest.data_invariants(ctx.prefix)
    snapshot = Probe.snapshot(ctx.repo, ctx.prefix)

    report =
      apply_scope(ctx, objects, invariants, snapshot, comment, report, skip_validate?)

    report = delegate_oban(ctx, report)

    with :ok <- check_no_concurrent_migration(ctx, comment1) do
      report =
        report
        |> add_pending_findings(objects, comment)
        |> add_cross_check_finding_and_action(ctx, objects, snapshot, comment)

      {:ok, report}
    end
  end

  # Spec §6.1's pipeline step: after applying the object slice, before the
  # concurrency re-read. Oban objects are delegated, never manifested/
  # compared (S16) — this call is the whole of that delegation, exactly
  # `Postgres.V135`'s own `Oban.Migration.up(prefix:, create_schema: false)`
  # (originally V27's idiom, folded into the V135 baseline by the squash)
  # (`create_schema: false` is load-bearing there too: Oban defaults it to
  # `true` for non-public prefixes otherwise, which fails for a
  # low-privilege role — CLAUDE.md). Unlike V135, this call has no real
  # migration wrapping it — `ObanRunner.up/2` bootstraps just enough of an
  # `Ecto.Migration.Runner` for `Oban.Migration.up/1` to run at all (see its
  # moduledoc for why a bare call raises "could not find migration runner
  # process"). Never runs in dry-run mode (`verify/1`, or `repair/1` with
  # `dry_run: true`) — this is Oban's own migration code, which this module
  # cannot "preview" any more safely than it can preview any other library's
  # migrator; skipping it entirely is the only way `verify/1`'s "never
  # writes" guarantee stays true by construction. A failure is caught and
  # reported (`:oban_delegation_failed`, error severity) rather than left to
  # crash the whole repair run — Oban's own migration failing is a real
  # problem worth surfacing, but a repair tool crashing outright on it would
  # be worse than reporting it alongside everything else.
  defp delegate_oban(%{dry_run: true}, report), do: report

  defp delegate_oban(ctx, report) do
    ObanRunner.up(ctx.repo, ctx.prefix)
    report
  rescue
    e ->
      message = "Oban.Migration.up failed: #{Exception.message(e)}"
      Report.add_finding(report, finding(:oban_delegation_failed, :error, nil, nil, message))
  end

  # Cached per run: the preflight already queried it, and a per-object query
  # would be one round trip per compared object.
  defp pg_major_supported?(ctx) do
    case Map.get(ctx, :pg_major, :unset) do
      :unset -> Probe.server_version_major(ctx.repo) in @supported_pg_majors
      :unknown -> true
      major -> major in @supported_pg_majors
    end
  end

  defp add_server_version_finding(report, ctx) do
    case Probe.server_version_major(ctx.repo) do
      :unknown ->
        report

      major when major in @supported_pg_majors ->
        report

      major ->
        message =
          "connected server is PostgreSQL #{major}.x; this release is verified against " <>
            "majors #{@supported_pg_majors.first}-#{@supported_pg_majors.last} — structural " <>
            "comparisons may false-positive on cross-major pg_get_*def rendering differences"

        Report.add_finding(report, finding(:unsupported_pg_version, :info, nil, nil, message))
    end
  end

  defp check_no_concurrent_migration(ctx, comment1) do
    comment2 = Probe.raw_comment(ctx.repo, ctx.prefix)

    if CommentPolicy.concurrent_migration?(comment1, comment2) do
      {:error, {:concurrent_migration, comment1, comment2}}
    else
      :ok
    end
  end

  # ── Applying the in-scope slice: missing → create/would_repair, present → diff ──
  #
  # Returns the updated `report` alone — every caller that needs to gate a
  # decision on "is everything clean so far" (`run_adopt/4`'s clean gate)
  # reads `Report.findings/1` off the returned report itself, never a
  # separately-threaded list; a list captured mid-pipeline would go stale
  # the moment a later step (`delegate_oban/2`, `add_extra_column_findings/3`)
  # appends one more finding to the report but not to that list.

  defp apply_scope(ctx, objects, invariants, snapshot, bound, report, skip_validate?) do
    {in_scope, _pending} = Scope.partition(objects, bound)

    # Resolve every in-scope object to the shape `bound` selects FIRST, then
    # sort the resolved set via `Scope.execution_order/1` — spec §6.1's
    # literal class-ordering requirement ("apply/verify slice class-ordered:
    # extensions < functions < sequences < tables < columns < indexes <
    # constraints < seeds"). Iterating `in_scope` in the manifest's own
    # emission order (`{since, class, id}` — since-first, per the real P1
    # generator's `Emitter.build_objects/1`) is a materially different,
    # weaker ordering guarantee: it happens to be a safe topological order
    # for a well-formed chain today, but that safety is an unenforced
    # coincidence of real migration history, not a defended invariant — and
    # `execution_order/1` exists precisely so this module never has to rely
    # on that coincidence.
    ordered =
      in_scope
      |> Enum.map(&Scope.resolve(&1, bound))
      |> Enum.reject(&is_nil/1)
      |> Scope.execution_order()

    report =
      Enum.reduce(ordered, report, fn resolved, report ->
        apply_resolved(ctx, resolved, snapshot, skip_validate?, report)
      end)

    report
    |> then(&apply_invariants(ctx, invariants, bound, &1))
    |> add_extra_column_findings(objects, snapshot)
  end

  defp apply_resolved(ctx, resolved, snapshot, skip_validate?, report) do
    case object_finding(ctx, resolved, snapshot, skip_validate?) do
      nil -> report
      finding -> Report.add_finding(report, finding)
    end
  end

  defp object_finding(
         ctx,
         %{object: %{class: :seed} = object} = resolved,
         _snapshot,
         _skip_validate?
       ) do
    cond do
      Probe.seed_present?(ctx.repo, object.check) ->
        nil

      best_effort_seed_module_absent?(object) ->
        nil

      object.presence == :legacy_optional ->
        finding(
          :legacy_optional_absent,
          :info,
          object.id,
          object.since,
          "#{object.id}: legacy-optional, absent (expected either way)"
        )

      true ->
        missing_finding(ctx, resolved)
    end
  end

  defp object_finding(ctx, %{object: object, shape: shape} = resolved, snapshot, skip_validate?) do
    case Probe.lookup(snapshot, object.check) do
      nil ->
        presence_missing_finding(ctx, object, resolved, skip_validate?)

      observed ->
        presence_present_finding(
          ctx,
          resolved,
          shape,
          observed,
          pg_major_supported?(ctx),
          skip_validate?
        )
    end
  end

  # A `{:helper, mfa}` seed (the v15/v31 best-effort email-template
  # lineage) whose companion module genuinely is not part of this install
  # — a Mix task stripped from a release, or the optional emails module
  # never added — is the documented expected common case (`Object`'s
  # moduledoc, "Helper creates": "this is the expected common case, not a
  # failure mode"), not drift. `Executor.create/4` already treats it as a
  # silent no-op (`run_helper/3`'s `:seed` clause returns
  # `:best_effort_skipped` for a missing module exactly like a module that
  # raised), but until this fix that outcome was only ever visible to
  # `repair/1` — `verify/1`'s dry-run clause of `missing_finding/3` never
  # calls `Executor.create/4` at all, so it reported `:missing`/
  # `:repairable` (a permanent error the two paths disagreed on) for
  # something a real repair run would immediately shrug off. Predicting
  # the "module absent" half in dry-run needs no `apply/3` call (unlike
  # "module present but raised", which genuinely can't be known without
  # running it) — so this goes one step further than just matching apply's
  # `:info` finding: a correctly-configured, fully-caught-up install can
  # now show a genuinely empty report instead of a permanent info line.
  defp best_effort_seed_module_absent?(%{create: {:helper, {mod, _fun, _args}}}),
    do: not Code.ensure_loaded?(mod)

  defp best_effort_seed_module_absent?(_object), do: false

  defp presence_missing_finding(
         _ctx,
         %{presence: :legacy_optional} = object,
         _resolved,
         _skip_validate?
       ) do
    finding(
      :legacy_optional_absent,
      :info,
      object.id,
      object.since,
      "#{object.id}: legacy-optional, absent (expected either way)"
    )
  end

  defp presence_missing_finding(ctx, _object, resolved, skip_validate?) do
    missing_finding(ctx, resolved, skip_validate?)
  end

  defp missing_finding(ctx, resolved, skip_validate? \\ false)

  defp missing_finding(%{dry_run: true}, %{object: object}, _skip_validate?) do
    finding(:missing, :repairable, object.id, object.since, "#{object.id}: missing, would repair")
  end

  defp missing_finding(ctx, resolved, skip_validate?) do
    outcome = Executor.create(ctx.repo, resolved, ctx.prefix, skip_validate?)
    outcome_finding(resolved.object, outcome)
  end

  defp outcome_finding(object, :created) do
    finding(:repaired, :repairable, object.id, object.since, "#{object.id}: created")
  end

  defp outcome_finding(object, :already_present) do
    finding(
      :already_present,
      :info,
      object.id,
      object.since,
      "#{object.id}: already present (race-tolerant)"
    )
  end

  defp outcome_finding(object, :best_effort_skipped) do
    finding(
      :best_effort_skipped,
      :info,
      object.id,
      object.since,
      "#{object.id}: optional seeder absent or failed (best-effort, not held against the install)"
    )
  end

  defp outcome_finding(object, {:create_failed, message}) do
    finding(
      :create_failed,
      :error,
      object.id,
      object.since,
      "#{object.id}: create failed — #{message}"
    )
  end

  defp outcome_finding(object, {:fk_validation_failed, message}) do
    finding(
      :fk_validation_failed,
      :error,
      object.id,
      object.since,
      "#{object.id}: added NOT VALID; VALIDATE failed — #{message}"
    )
  end

  defp presence_present_finding(
         _ctx,
         %{object: %{presence: :legacy_optional} = object},
         _shape,
         _observed,
         _pg_ok,
         _skip_validate?
       ) do
    finding(
      :legacy_optional_present,
      :info,
      object.id,
      object.since,
      "#{object.id}: legacy-optional, present (expected either way)"
    )
  end

  defp presence_present_finding(
         ctx,
         resolved,
         shape,
         observed,
         pg_major_supported?,
         skip_validate?
       ) do
    object = resolved.object
    result = Differ.compare(object.class, shape, observed)

    case result do
      :match ->
        nil

      {:mismatch, reasons} ->
        # A mismatch whose every reason rests on pg_get_*def RENDERING (index
        # predicates, CHECK/exclusion definitions — the two fields with no
        # structural decomposition) is not trustworthy on a Postgres major this
        # release was not verified against: the same expression can simply be
        # re-rendered. Report it as info there instead of asserting drift, so a
        # cross-major operator is not handed a wall of false errors — and keep
        # it :error on a verified major, where a rendering difference IS drift.
        downgrade? = not pg_major_supported? and Differ.deparse_text_only?(result)
        marker = Differ.deparse_text_marker()
        text = reasons |> Enum.map_join("; ", &String.replace_prefix(&1, marker, ""))

        cond do
          downgrade? ->
            finding(
              :deparse_rendering_differs,
              :info,
              object.id,
              object.since,
              "#{object.id}: " <>
                text <>
                " (rendering-only difference, unverified PostgreSQL major — not treated as drift)"
            )

          # Function bodies are PhoenixKit-owned, revision-blind, idempotent
          # creates — `ShapeSql`'s moduledoc already documents `:function`
          # creates as safe to reissue ("ensure_uuid_v7_function/2, or a
          # CREATE OR REPLACE FUNCTION ... there is no 'old shape' a later
          # delta depends on the absence of"). Unlike every other class, a
          # function shape mismatch is therefore additive-safe to self-heal
          # by reissuing the object's own `create` (a schema-qualified
          # `CREATE OR REPLACE`, never a `DROP`) — the mechanism this needed
          # (`Helpers.do_ensure_uuid_v7_function/3` replacing an existing,
          # differently-bodied function) was missing until this fix, so a
          # pre-qualification-fix `uuid_generate_v7()` body stayed drifted
          # forever with no repair path. A signature change Postgres
          # genuinely can't apply in place (e.g. a changed return type)
          # surfaces as `:create_failed`/`:error` instead of silently
          # "succeeding" — additive-only is preserved by construction, not
          # by this module refraining from trying.
          object.class == :function ->
            function_mismatch_finding(ctx, resolved, skip_validate?, text)

          true ->
            finding(:wrong_shape, :error, object.id, object.since, "#{object.id}: " <> text)
        end
    end
  end

  defp function_mismatch_finding(%{dry_run: true}, resolved, _skip_validate?, text) do
    object = resolved.object

    finding(
      :wrong_shape,
      :repairable,
      object.id,
      object.since,
      "#{object.id}: " <> text <> " — would reissue CREATE OR REPLACE"
    )
  end

  defp function_mismatch_finding(ctx, resolved, skip_validate?, text) do
    object = resolved.object

    case Executor.create(ctx.repo, resolved, ctx.prefix, skip_validate?) do
      :created ->
        finding(
          :repaired,
          :repairable,
          object.id,
          object.since,
          "#{object.id}: " <> text <> " — reissued CREATE OR REPLACE"
        )

      {:create_failed, message} ->
        finding(
          :create_failed,
          :error,
          object.id,
          object.since,
          "#{object.id}: reissuing definition failed — #{message}"
        )

      other ->
        outcome_finding(object, other)
    end
  end

  # ── Data invariants (report-only, never "fixed") ───────────────────

  defp apply_invariants(ctx, invariants, bound, report) do
    in_scope = Scope.in_scope_invariants(invariants, bound)

    Enum.reduce(in_scope, report, fn invariant, report ->
      case invariant_finding(ctx, invariant) do
        nil -> report
        finding -> Report.add_finding(report, finding)
      end
    end)
  end

  defp invariant_finding(ctx, invariant) do
    case ctx.repo.query(invariant.assert, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        nil

      _ ->
        finding(
          :invariant_failed,
          :error,
          nil,
          invariant.since,
          "invariant failed: #{invariant.desc}"
        )
    end
  end

  # ── Pending objects (since > comment) ───────────────────────────────

  defp add_pending_findings(report, objects, bound) do
    {_in_scope, pending} = Scope.partition(objects, bound)

    Enum.reduce(pending, report, fn object, report ->
      finding =
        finding(
          :pending,
          :info,
          object.id,
          object.since,
          "#{object.id}: pending (since #{object.since} > comment #{bound}); run mix phoenix_kit.update"
        )

      Report.add_finding(report, finding)
    end)
  end

  # ── Extra objects (info-only; scoped to columns of manifest-known tables — see moduledoc) ──

  defp add_extra_column_findings(report, objects, snapshot) do
    known_tables =
      objects
      |> Enum.filter(&(&1.class == :table))
      |> MapSet.new(fn %{check: {:catalog, %{name: name}}} -> name end)

    known_columns =
      objects
      |> Enum.filter(&(&1.class == :column))
      |> MapSet.new(fn %{check: {:catalog, %{table: table, column: column}}} ->
        {table, column}
      end)

    snapshot.columns
    |> Enum.filter(fn {{table, _column}, _shape} -> MapSet.member?(known_tables, table) end)
    |> Enum.reject(fn {key, _shape} -> MapSet.member?(known_columns, key) end)
    |> Enum.reduce(report, fn {{table, column}, _shape}, report ->
      id = "column:#{table}.#{column}"
      finding = finding(:extra_object, :info, id, nil, "#{id}: extra column, not in the manifest")
      Report.add_finding(report, finding)
    end)
  end

  # ── R2/R5 cross-check + --heal-comment ──────────────────────────────

  defp add_cross_check_finding_and_action(report, ctx, objects, snapshot, comment) do
    presence =
      objects
      |> Probe.presence_by_since(snapshot)
      |> pad_vacuous_versions(ctx.floor, comment)

    highest = CommentPolicy.highest_fully_present_version(presence)

    case CommentPolicy.marker_cross_check(comment, highest) do
      :consistent ->
        report

      {:ahead_of_schema, lower} ->
        msg = ahead_of_schema_message(ctx.dry_run, comment, lower)
        Report.add_finding(report, finding(:comment_ahead_of_schema, :info, nil, nil, msg))

      {:stale_low, target} ->
        report
        |> Report.add_finding(
          finding(:stale_low_comment, :info, nil, nil, stale_low_message(comment, target))
        )
        |> maybe_heal(ctx, target)
    end
  end

  # `Probe.presence_by_since/2` only emits a bucket for a `since` value some
  # manifest object actually carries. A version that introduces NO manifest
  # objects at all (e.g. V163 — `grep 'since: 163,' expected_schema.ex` is
  # empty) then has no bucket whatsoever, so
  # `CommentPolicy.highest_fully_present_version/1`'s take_while silently
  # caps out at the highest OBJECT-BEARING since below it — every install
  # sitting exactly at such a version (a fresh install at `current`, the
  # common case) was reported as "comment ahead of schema" even though
  # nothing is actually missing (there was nothing TO be missing). Pad
  # every since in `floor..comment` that has no real bucket with `true`
  # (vacuously present — nothing to check there). Real buckets are never
  # touched (below `floor` included — genuine drift there must still halt
  # `take_while`), and the padding is bounded by `comment`, not
  # `ctx.current`: a healthy install sitting at an OLDER in-range comment
  # must not have versions it hasn't reached yet vacuously counted as
  # "present" merely because a later delta happens to add no objects.
  defp pad_vacuous_versions(presence, floor, comment) do
    known = Map.new(presence)
    padding = for since <- floor..comment, not Map.has_key?(known, since), do: {since, true}

    presence ++ padding
  end

  defp ahead_of_schema_message(true, comment, lower) do
    "comment claims V#{comment} but the highest fully-present version is V#{lower} " <>
      "(objects since #{lower + 1}..#{comment} are missing or diverged — see the findings " <>
      "above; run mix phoenix_kit.repair to address them)"
  end

  defp ahead_of_schema_message(false, comment, lower) do
    "comment claims V#{comment} but the highest fully-present version is V#{lower} " <>
      "(objects since #{lower + 1}..#{comment} were missing and have been addressed above)"
  end

  defp stale_low_message(comment, target) do
    "comment claims V#{comment} but every marker up to V#{target} is structurally present " <>
      "— schema is ahead of the comment. Pass --heal-comment to stamp V#{target} (warning: " <>
      "mix phoenix_kit.update from a stale-low comment re-runs deltas whose data ops are " <>
      "not all no-ops)."
  end

  defp maybe_heal(report, ctx, target) do
    case CommentPolicy.should_heal_comment?({:stale_low, target}, ctx.heal_comment?) do
      {:heal, target} ->
        apply_comment_action(ctx, report, {:healed, target}, {:would_heal, target})

      :no_heal ->
        report
    end
  end

  defp apply_comment_action(ctx, report, real_action, dry_run_action) do
    if ctx.dry_run do
      Report.put_comment_action(report, dry_run_action)
    else
      {_action, version} = real_action
      write_comment(ctx, version)
      Report.put_comment_action(report, real_action)
    end
  end

  defp write_comment(ctx, version) do
    ctx.repo.query!(~s(COMMENT ON TABLE #{ctx.prefix}.phoenix_kit IS '#{version}'), [],
      log: false
    )
  end

  defp finding(kind, severity, object_id, since, message) do
    %{kind: kind, severity: severity, object_id: object_id, since: since, message: message}
  end
end
