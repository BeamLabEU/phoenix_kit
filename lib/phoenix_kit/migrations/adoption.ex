defmodule PhoenixKit.Migrations.Adoption do
  @moduledoc """
  Public, documented API for module-owned migration chains that adopt a
  core-baseline table (`dev_docs/guides/2026-09-05-module-table-extraction-guide.md`)
  to verify its shape before claiming ownership — not just its presence.

  ## The bug this exists to let module authors close

  A module chain adopts a core table with `CREATE TABLE IF NOT EXISTS` /
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, then stamps ownership with
  `COMMENT ON TABLE ... IS '<marker_prefix><N>'`. `IF NOT EXISTS` checks
  *existence*, never *shape*: a column narrowed by hand outside migrations
  (say, a money column quietly changed from `numeric(15,2)` to
  `numeric(10,2)` by an operator working straight against the database)
  survives adoption completely silently — exit 0, marker written, the
  narrower type never noticed. This module closes that gap by giving a
  module's adoption step a way to assert "the table I am about to claim
  actually has the shape I expect" before it writes the marker.

  This module is a thin, **stability-committed** facade over
  `PhoenixKit.Migrations.Repair.Differ` and `PhoenixKit.Migrations.Repair.Probe`
  (core's existing structural-diff engine for `mix phoenix_kit.repair`) —
  unlike those two, which carry no external-API stability claim, this
  module's public functions are safe for a module package to depend on
  across core releases.

  ## `verify_shape/3` — the vocabulary

  `checks` is a flat list of per-object shape declarations, in the exact
  same `class`/`check`/`expected`-shape vocabulary
  `PhoenixKit.Migrations.ExpectedSchema` already uses internally for its
  own manifest entries (see `PhoenixKit.Migrations.ExpectedSchema.Object`'s
  moduledoc, "Per-class shape keys") — so a module author copies a
  familiar shape, not a novel one. A `:column` check, matching a real
  manifest entry's fields exactly:

      %{
        class: :column,
        check: {:catalog, %{kind: :column, table: "phoenix_kit_subscription_types", column: "price"}},
        expected: %{type: "numeric(15,2)", not_null: true, default: nil}
      }

  An `:index` check (a real, current core manifest entry —
  `phoenix_kit_users_username_uidx`, a partial unique index):

      %{
        class: :index,
        check: {:catalog, %{kind: :index, name: "phoenix_kit_users_username_uidx"}},
        expected: %{unique: true, method: "btree", keys: ["username"], opclasses: ["citext_ops"], predicate: "(username IS NOT NULL)"}
      }

  A `:constraint` check (primary key):

      %{
        class: :constraint,
        check: {:catalog, %{kind: :constraint, table: "phoenix_kit_orders", name: "phoenix_kit_orders_pkey"}},
        expected: %{type: "p", columns: ["uuid"]}
      }

  Only the fields `PhoenixKit.Migrations.Repair.Differ.compare/3` actually
  reads for that `class` need to be present in `expected` — see its
  moduledoc for the exact field list per class (columns: `type`,
  `not_null`, `default`; indexes: `unique`, `method`, `keys`, `opclasses`,
  `predicate`; constraints: dispatched on `expected.type`, see `Differ`).
  `verify_shape/3` validates this itself before ever calling `Differ` — see
  "Never raises, even on a malformed `checks` entry" below.

  ### Building a real `expected` map — don't hand-copy manifest source text

  `expected` values must be the CANONICAL text the querying server itself
  renders (`format_type`/`pg_get_expr`/`pg_get_indexdef` output) — never a
  SQL-source spelling. `character varying(120)`, never `varchar(120)`; a
  timestamp default is either `now()` or `CURRENT_TIMESTAMP` depending on
  how it was declared, and those are two different strings that do **not**
  compare equal to each other. Any default expression that references a
  schema-qualified function or type must be qualified for the REAL prefix
  you are checking against, not the literal, unsubstituted
  `"__SCHEMA__"` placeholder token core's own manifest source carries
  internally — copying a manifest entry's raw fields by hand (e.g. by
  `grep`-ing `expected_schema.ex` and pasting what you find) reproduces
  that placeholder and manufactures a false drift on the very first check
  (`default: "__SCHEMA__.uuid_generate_v7()"` will never equal what a real
  connection reads back).

  The right way to build a real `expected` map from an actual, current core
  object is through the manifest's own public accessors, never by reading
  `expected_schema.ex`'s source directly:

      manifest = PhoenixKit.Migrations.ExpectedSchema.objects(prefix)
      object = Enum.find(manifest, &(&1.id == "column:phoenix_kit_subscription_types.price"))
      expected = PhoenixKit.Migrations.ExpectedSchema.Object.newest_shape(object)

  `ExpectedSchema.objects/1` already substitutes `"__SCHEMA__"` for the
  real, validated `prefix` you pass it — across every field, including
  every `:revisions` entry (the same per-object substitution
  `PhoenixKit.Migrations.ExpectedSchema.Object.materialize/2` performs;
  `objects/1` applies its own equivalent internally, so there is no need to
  call `materialize/2` again on what it returns). `Object.newest_shape/1`
  is the right shape to declare in `checks` for a table you are adopting
  NOW — but ONLY for an object your own module has never itself touched.
  Skip any object whose `presence` is `:legacy_optional` — spec §3.7's
  bimodal drift, where either state is normal on an old install, is not a
  shape a module's own fresh adoption should assert as required.

  ### `Object.newest_shape/1` is core's OWN idea of the shape — not
  necessarily what your module actually declares today

  If your module's own migration chain has already changed an object
  beyond what it inherited from core, `expected` for THAT object must come
  from YOUR module's own DDL/declared shape, not from core's manifest —
  core's `Object.newest_shape/1` still describes core's baseline, which may
  no longer be what's actually on the table. This is not hypothetical:
  `phoenix_kit_billing`'s own V5 migration does
  `ALTER TABLE ... ALTER COLUMN user_uuid DROP NOT NULL` on both
  `phoenix_kit_invoices` and `phoenix_kit_transactions` — a deliberate,
  intentional widening — while core's manifest still declares `user_uuid`
  `NOT NULL` for both (core has not yet gone through the Phase 1 process,
  `@module_owned_ids` + dropping the objects from the manifest, for this
  specific change — see the extraction guide). A module using
  `Object.newest_shape/1`
  unmodified for `user_uuid` on either table would get a false drift on
  every single adoption run, forever, until core catches up. `shape_at/2`
  exists for the rarer case of deliberately pinning to an older, still-valid
  revision of an object your module has NOT modified; neither function is
  the right tool for an object your OWN module has changed — declare that
  `expected` by hand, from what your own DDL actually creates.

  `verify_shape/3` takes one `Probe.snapshot/2` of the target server, then
  runs every check against it and collects **every** drifted object in one
  pass — it never stops at the first mismatch, so a caller sees the full
  diff at once. An object the caller expects but that is entirely absent
  (dropped by a stray manual `DROP INDEX`, say) is reported as drift too,
  with its own `"missing: ..."` reason — this is deliberately not the same
  question `mix phoenix_kit.repair` answers (whether to *create* it); it is
  purely "does reality match what I declared".

  ### Never raises, even on a malformed `checks` entry

  `verify_shape/3` validates every `checks` entry completely before it
  ever reaches `Probe.lookup/2` or `Differ.compare/3` — neither of those
  was built to reject a bad input gracefully. All of the following are
  reported as drift, with an `"invalid check: ..."` reason, instead of
  crashing or silently passing:

    * the entry isn't a map, or is missing `:class`/`:check`/`:expected`
      (would otherwise be a `FunctionClauseError` at the call site);
    * `class` isn't a recognized class atom (`FunctionClauseError` from
      `Differ.compare/3`);
    * `check`'s own `kind` doesn't match the declared `class` — e.g.
      `class: :index` on a check that actually names a `:column`
      (`KeyError` from `Differ.compare/3` reading an index-shaped field
      off a column-shaped observed map), or, more dangerously,
      `class: :table` on a check that names a `:column`: `Differ.compare(
      :table, _, _)` always returns `:match` regardless of content, so
      THIS specific mismatch doesn't crash at all — it silently reports a
      genuinely narrowed column as clean. Cross-checking `class` against
      `check`'s `kind` closes that hole, not just the crashing ones;
    * `expected` isn't a map at all (`BadMapError` from `Map.has_key?/2`);
    * `expected` is a map but is missing a field that `class` needs
      (`KeyError` from `Differ.compare/3`'s own field reads).

  Because this module is **stability-committed** for external callers
  (see above), a caller mistake in its own `checks` list must surface as a
  clear signal inside the normal `{:drift, diffs}` result, not a cryptic
  internal crash from a module the caller does not own — and never a
  silent `:ok` either, which is the more dangerous failure mode of the
  two. This promise is specific to `verify_shape/3`; `marker_conflict/5`
  makes no equivalent "never raises" claim (its documented `{:error, _}`
  return covers real query/existence failures, not caller input errors).

  ### `~deparse~`-marked reasons are full-severity drift here, unlike in `mix phoenix_kit.repair`

  `Differ`'s `:index` predicate and `:constraint` (`"c"`/`"x"`) definition
  comparisons fall back to raw `pg_get_expr`/`pg_get_constraintdef`
  rendering (see `Differ`'s own moduledoc) — two Postgres majors can
  re-render an identical expression differently, so a reason resting only
  on that text (`Differ.deparse_text_only?/1`) is not always real drift.
  `mix phoenix_kit.repair` downgrades such a reason to informational on an
  unverified major (its own server-version preflight,
  `PhoenixKit.Migrations.Repair`'s `@supported_pg_majors`). `verify_shape/3`
  deliberately does **not** mirror that: it has no report/severity-tier
  system of its own to hang an `:info` vs `:error` distinction on, and
  introducing one would be new machinery this module does not otherwise
  need. Adoption is also a rare, deliberate, operator-supervised migration
  step — not a routine health check — so treating a possible cross-major
  rendering artifact as full drift (rather than silently accepting it) is
  the safer default here: worst case, a module author sees a reason to
  double-check by hand; `format_drift/1` still renders it plainly (stripped
  of the internal marker prefix). If this proves too strict for a real
  cross-major deployment, a module author's option today is to adjust its
  own `expected` declaration for that specific object.

  ## The recommended pattern: verify, then decline-and-raise on drift — or,
  under an explicit operator opt-in, warn and adopt anyway

  `verify_shape/3` never raises on anything in its `checks` argument (see
  "Never raises" above — that promise is `verify_shape/3`'s specifically;
  `marker_conflict/5` DOES raise on a malformed CALL — an empty
  `own_marker_prefix`, or a `prefix` `Helpers.validate_prefix!/1` rejects —
  those are programmer errors in how the function was called, not data the
  function is meant to report on the way `checks`/drift is). Neither
  function ever *writes* to the database — `verify_shape/3` does run a
  real, read-only `Probe.snapshot/2` of the target server (which briefly
  sets `search_path = ''` on the connection for the duration of the
  snapshot; see `Probe`'s own moduledoc for why), but neither function ever
  executes DDL or writes a comment. **This module is deliberately
  mode-agnostic** — it reports; the calling module chain decides how to
  react. The following is the decided, shared contract for that reaction,
  common to this module and `phoenix_kit_legal`'s own adoption step (its
  issue #23) — not something `Adoption` enforces itself.

  Run the additive `CREATE TABLE IF NOT EXISTS` / `ADD COLUMN IF NOT
  EXISTS` statements first (as today), `flush()` them so they have
  actually landed, then verify shape, then react to the result:

    * **By default** — decline the marker and **raise**, with the diff
      rendered into the message via `format_drift/1`. Never silently skip,
      never auto-repair.
    * **Under an explicit, per-host operator opt-in** (a config toggle the
      module chain itself reads — e.g. `Application.get_env(:my_module,
      :adoption_shape_check, :raise) == :warn`; the exact key is the
      module's own choice, this module does not define or read one) —
      render the SAME diff via `format_drift/1` into an
      `Logger.error/1` call instead of a raise, **write the ownership
      marker anyway**, and let the migration succeed and the chain's
      version advance. The migration must NOT fail in `:warn` mode:
      `mix phoenix_kit.update` regenerates a module's migration file on
      every run it is invoked for, and a migration that never completes
      would be regenerated and re-attempted forever. `:warn` accepts the
      drift, it does not hide it — but the `:error`-level log line at the
      moment of adoption is the durable record of that, not a promise that
      a LATER `mix phoenix_kit.repair`/`doctor` run will independently
      rediscover the same drift: `Differ` itself excludes the
      `not_null: true, default: nil` shape from comparison entirely (the
      same exemption this module separately compensates for — see below —
      repair has no such compensation, so it would never have seen that
      specific drift either), and any object a module has since gone
      through Phase 1 for (`@module_owned_ids`, the object dropped from
      core's manifest) simply stops being asserted by core
      at all, at which point repair/doctor cannot see it as a mismatch by
      design, not by omission.

  This is an explicit, reviewed, per-host operator decision — never a
  default, never something a module flips on for itself. It exists for the
  same reason `marker_conflict/5`'s `overwritable:` option exists: some
  hosts have a legitimate, already-understood reason their shape does not
  match, and the alternative to a deliberate override is adoption never
  completing on that host at all.

  This same pattern (default raise, `:warn` opt-in) is mirrored, in short
  form, in `dev_docs/guides/2026-09-05-module-table-extraction-guide.md`.

  A real module chain's coordinator implements `up(opts \\\\ [])` (the
  decentralized-migrations contract `mix phoenix_kit.update` discovers via
  `migration_module/0`) and is itself invoked from *inside* a real,
  generated `Ecto.Migration` callback — so `execute/1` and `repo()` (both
  from `Ecto.Migration`, available because the coordinator does
  `use Ecto.Migration`) are the real DDL/repo-access mechanism, not
  `repo.query!/2`. `execute/1` only *queues* a command on the migration
  runner (`Ecto.Migration.Runner`) — it does not run it immediately — so a
  `flush()` between the queued `CREATE TABLE` and the read `verify_shape/3`
  performs is required, or the verify would see the table as entirely
  *missing* rather than checking its shape at all:

      defmodule MyModule.Migrations do
        use Ecto.Migration
        require Logger
        alias PhoenixKit.Migrations.Adoption

        @marker_prefix "mym_schema:"

        def up(opts \\\\ []) do
          prefix = Keyword.get(opts, :prefix, "public")
          repo = repo()
          p = "\#{prefix}."

          execute(\"\"\"
          CREATE TABLE IF NOT EXISTS \#{p}phoenix_kit_subscription_types (
            "uuid" uuid PRIMARY KEY DEFAULT \#{p}uuid_generate_v7(),
            "price" numeric(15,2) NOT NULL
          )
          \"\"\")

          # `execute/1` above only QUEUES the CREATE on the migration runner —
          # `flush()` forces it to actually land before the read below, or
          # verify_shape/3 would see the table as missing, not as drift.
          flush()

          checks = [
            %{
              class: :column,
              check:
                {:catalog,
                 %{kind: :column, table: "phoenix_kit_subscription_types", column: "price"}},
              expected: %{type: "numeric(15,2)", not_null: true, default: nil}
            }
          ]

          case Adoption.verify_shape(repo, prefix, checks) do
            :ok -> :ok
            {:drift, diffs} -> handle_drift(diffs)
          end

          case Adoption.marker_conflict(
                 repo,
                 prefix,
                 "phoenix_kit_subscription_types",
                 @marker_prefix
               ) do
            :ok ->
              execute(
                "COMMENT ON TABLE \#{p}phoenix_kit_subscription_types IS '\#{@marker_prefix}1'"
              )

            {:conflict, existing} ->
              raise "MyModule cannot adopt phoenix_kit_subscription_types: " <>
                      "it already carries an unrelated marker (\#{inspect(existing)})"

            {:error, reason} ->
              raise "MyModule could not read phoenix_kit_subscription_types' " <>
                      "current comment to check for a marker conflict: \#{inspect(reason)}"
          end
        end

        # Default: decline and raise, with an executable diff. Under an
        # explicit, reviewed, per-host operator opt-in
        # (`config :my_module, :adoption_shape_check, :warn` — the exact
        # key is MyModule's own choice, `Adoption` neither defines nor
        # reads one), log the SAME diff at :error and return normally
        # instead — `up/1` then proceeds to write the marker anyway and
        # the migration succeeds, so the chain's version advances rather
        # than regenerating and re-attempting this same migration forever.
        # The drift stays visible in the log either way; `:warn` accepts
        # it, it does not hide it.
        defp handle_drift(diffs) do
          diff_text = Adoption.format_drift(diffs)

          case Application.get_env(:my_module, :adoption_shape_check, :raise) do
            :warn ->
              Logger.error(\"\"\"
              MyModule: phoenix_kit_subscription_types has drifted from the shape \\
              MyModule expects, but :adoption_shape_check is set to :warn — adopting \\
              anyway and writing the ownership marker.

              \#{diff_text}
              \"\"\")

            _ ->
              raise \"\"\"
              MyModule cannot adopt phoenix_kit_subscription_types: its shape on \\
              this database does not match what MyModule expects.

              \#{diff_text}

              This is not something `mix phoenix_kit.repair` can fix for you: \\
              repair is additive-only (it can add a missing column or index, \\
              never alter an existing one's type, nullability, or definition) \\
              and has no notion of module ownership. Inspect the diff above, \\
              check the actual data before deciding (a narrowed column may \\
              already hold truncated values), then either run the corrective \\
              DDL by hand to bring the table back to this shape, update \\
              MyModule's own `expected` declaration if the drift is \\
              intentional, or set `:adoption_shape_check` to `:warn` for \\
              this host if you have reviewed the diff above and accept it. \\
              Re-run this migration once you have done one of those.
              \"\"\"
          end
        end
      end

  ### Why decline-and-raise, not auto-fix

  Auto-fixing DDL during unattended adoption (at app boot, with no operator
  watching) carries the same silent-mutation risk this module exists to
  close, just inverted — a column silently widened back is a smaller but
  structurally identical mistake to a column silently narrowed: the host's
  schema changes without anyone being told. `mix phoenix_kit.repair`
  remains the one tool that ever issues DDL automatically — but only for
  CORE's own tables, adding a genuinely missing column or index it created
  in the first place. For a module-adopted table specifically, as the
  worked example's raise message above notes, repair cannot help at all
  (it is additive-only, and has no notion of module ownership) — a real
  fix here is always a manual one. Keeping adoption's own shape check
  detection-only mirrors the same principle for the one case where no
  tool, repair included, can safely auto-correct: detection is safe to run
  unattended, DDL mutation is not. An unhandled `raise` during a migration
  halts the chain (the version marker is never advanced), so the host does
  not boot into a half-adopted state and the operator sees exactly what
  disagreed.

  "Auto-fix" and "operator override" are different things, and only the
  first is ruled out here. `:warn` (above) is a documented, deliberate
  *override* — an operator explicitly saying "I have reviewed this drift
  and accept it, adopt anyway" — not automatic repair: nothing DDL-wise
  changes about the table itself, only whether the marker gets written
  over the drift instead of adoption halting. The mode switch lives in the
  calling module, not here, by design (see above).

  ## `marker_conflict/5`

  Reads the current `COMMENT ON TABLE` for an arbitrary, caller-given
  table (not core's own `phoenix_kit` meta table — this is a new,
  parameterized query, schema-anchored the same way
  `PhoenixKit.Migrations.Repair.Probe.raw_comment/2` anchors its read of
  core's own marker). `:ok` when the comment is absent, `nil`, already
  starts with the caller's own `own_marker_prefix` (an ordinary version
  bump by the SAME module), or is a known core pre-squash legacy
  descriptive comment (see below); `{:conflict, existing_comment}` for
  anything else — another module's marker, or an operator's own
  hand-written documentation comment on the table — so the caller can
  decline to overwrite it rather than silently stomping it.
  `{:error, reason}` when the query itself failed — this is deliberately
  distinct from `:ok`; a caller that cannot tell whether a conflict exists
  must not proceed as if there is none.

  `own_marker_prefix` must be non-empty (an empty string would make every
  comment match `String.starts_with?(comment, "")` and this function would
  always report `:ok`, defeating the whole check) and must include the
  same trailing separator the caller's own marker-write statement uses
  (the existing convention across `phoenix_kit_billing`/`phoenix_kit_legal`
  is a trailing colon, e.g. `"pkb_schema:"`) — a prefix without it risks a
  false match against an unrelated but similarly-named module
  (`"pkb_schema"` would also match a hypothetical `"pkb_schema_v2:1"`).

  ### Core's own pre-squash legacy comments

  Before the squash at V135, core itself wrote plain descriptive (not
  marker-shaped) `COMMENT ON TABLE` statements on baseline tables — not
  only the handful billing/legal happen to adopt today, but essentially
  every table core created before the squash, ~48 in total (storage,
  posts/social, billing, AI, support tickets, user relationships, db sync,
  shop, consent — see `@core_legacy_table_comments` for the exact table
  list and text, confirmed by reading every descriptive `COMMENT ON TABLE`
  in the pre-squash source directly, not a partial sample). On any host
  installed before the squash, that text is still there for whichever of
  those tables it created — not `nil`, not the adopting module's own
  marker prefix. `marker_conflict/5` treats an exact match against one of
  these known strings, for its own table, as automatically overwritable
  (the same outcome as "no comment"), so a correctly-written adoption step
  does not fail on any pre-squash host adopting any core-baseline table —
  not just the ones known modules adopt today, but future ones too (the
  next module in the extraction series adopting, say, `phoenix_kit_posts`
  or `phoenix_kit_tickets`, hits the same class of host and is already
  covered).

  `overwritable:` is for a comment `marker_conflict/5` does NOT already
  recognize as safe — core's own pre-squash comments are covered
  automatically by the list above and never need this option. Typical use:
  an operator's own hand-written note on the table, independently reviewed
  and confirmed safe to overwrite for this specific adoption:

      Adoption.marker_conflict(repo, prefix, table, @marker_prefix,
        overwritable: ["an operator's own note, reviewed and confirmed safe"]
      )

  This does not widen what counts as safe by default — only the two
  sources above (core's own known list, and whatever the CALLER
  explicitly supplies) are ever treated as overwritable; anything else
  still declines with `{:conflict, existing_comment}`.
  """

  alias PhoenixKit.Migrations.ExpectedSchema.Object
  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.Repair.Differ
  alias PhoenixKit.Migrations.Repair.Probe

  @typedoc """
  One object's declared expectation: `class` picks the
  `PhoenixKit.Migrations.Repair.Differ.compare/3` clause, `check` locates
  the observed object in a `Probe.snapshot/2` result (same shape
  `PhoenixKit.Migrations.ExpectedSchema.Object.check/0` uses), `expected`
  is the per-class shape map `Differ.compare/3` reads fields out of — see
  the moduledoc for concrete examples per class.
  """
  @type shape_check :: %{
          class: Object.class(),
          check: Object.check(),
          expected: map()
        }

  @typedoc "One drifted object: the check that found it, and every disagreeing field's reason."
  @type drift :: %{check: Object.check(), reasons: [String.t()]}

  # Every `Object.class()` value `Differ.compare/3` has a real clause for —
  # see `expected_shape_error/2` below, the guard against the
  # `FunctionClauseError` an unrecognized atom would otherwise raise there.
  @known_classes [:table, :extension, :seed, :column, :sequence, :function, :index, :constraint]

  @doc """
  Verifies every declared `checks` entry against the real, current shape
  of `prefix` on `repo` — one `Probe.snapshot/2` round trip, then a
  `Differ.compare/3` per check. Returns `:ok` when every object matches;
  `{:drift, diffs}` (never stopping at the first mismatch) otherwise, one
  `t:drift/0` entry per object that disagreed, was entirely missing, or
  whose own `checks` entry was itself malformed (see the moduledoc's
  "Never raises" section).

  Never raises and never executes DDL — purely a read. See the
  moduledoc's "recommended pattern" for how a caller is expected to react
  to `{:drift, diffs}`.
  """
  @spec verify_shape(Ecto.Repo.t(), String.t(), [shape_check()]) ::
          :ok | {:drift, [drift()]}
  def verify_shape(repo, prefix, checks) when is_list(checks) do
    Helpers.validate_prefix!(prefix)
    # Probe.snapshot/2 keeps its `search_path = ''` inside its own
    # transaction (a savepoint here) and puts the caller's value back, so a
    # migration connection's deliberately-set search_path survives it.
    snapshot = Probe.snapshot(repo, prefix)

    drifted =
      checks
      |> Enum.map(&compare_check(&1, snapshot))
      |> Enum.reject(&is_nil/1)

    if drifted == [], do: :ok, else: {:drift, drifted}
  end

  @doc """
  Renders a `verify_shape/3` `{:drift, diffs}` result's `diffs` list into
  one consistent, human-readable, actionable message — so every module's
  adoption-failure raise looks the same instead of each hand-rolling its
  own `inspect/1`. See the moduledoc's worked example.

  This is the SAME rendering a caller uses for both reactions in the
  decided `:warn`-override contract (see the moduledoc's "recommended
  pattern" section): the message inside a default-mode `raise`, and the
  message inside an `:warn`-mode `Logger.error/1` call when an operator
  has explicitly opted a host into adopting over drift instead of halting.
  `format_drift/1` itself has no opinion about which of those a caller
  chooses — it only renders the diff.

  A `~deparse~`-marked reason (see the moduledoc's "`~deparse~`-marked
  reasons" section) has its internal marker prefix stripped for display —
  the raw, marked reason is still exactly what `verify_shape/3` itself
  returns in `diffs`; only this rendering strips it.
  """
  @spec format_drift([drift()]) :: String.t()
  def format_drift(diffs) when is_list(diffs) do
    marker = Differ.deparse_text_marker()

    Enum.map_join(diffs, "\n", fn %{check: check, reasons: reasons} ->
      text = Enum.map_join(reasons, "; ", &String.replace_prefix(&1, marker, ""))
      "  #{inspect(check)}: #{text}"
    end)
  end

  # `Differ.compare/3` assumes both shapes are already non-nil (its own
  # moduledoc: "never looks at :missing ... that is a presence question the
  # caller answers before ever calling here") — `Probe.lookup/2` returning
  # `nil` (the object is not on the target server at all) is therefore
  # handled here, as its own drift reason, and never reaches `compare/3`.
  #
  # Every field of a `checks` entry is validated by `validate_checks_entry/1`
  # BEFORE either `Probe.lookup/2` or `Differ.compare/3` ever sees it — both
  # raise on inputs they were never designed to reject gracefully (a
  # `FunctionClauseError` from `Probe.lookup/2` on a malformed `check`; a
  # `KeyError`/`BadMapError` from `Differ.compare/3` on an `expected` that
  # doesn't match `class`, or isn't a map at all). Critically,
  # `validate_checks_entry/1` cross-checks `class` against `check`'s OWN
  # `kind` (`check_matches_class?/2`) — without that, a caller-side mistake
  # (`class: :table` on a check that actually names a `:column`) doesn't
  # just risk a crash, it risks a SILENT FALSE `:ok`:
  # `Differ.compare(:table, _, _)` always returns `:match` regardless of
  # what's observed, so a genuinely narrowed column checked under the wrong
  # `class` would verify clean instead of drifted.
  defp compare_check(entry, snapshot) do
    case validate_checks_entry(entry) do
      {:ok, class, check, expected} ->
        case Probe.lookup(snapshot, check) do
          nil ->
            %{check: check, reasons: ["missing: no #{class} matching #{inspect(check)} found"]}

          observed ->
            compare_present(class, check, expected, observed)
        end

      {:error, reason} ->
        %{check: safe_check_for_report(entry), reasons: [reason]}
    end
  end

  # A best-effort "check" value for a REJECTED entry's drift report — must
  # never itself raise, however malformed `entry` is (that would defeat the
  # entire point of validating it in the first place). Not necessarily a
  # real `t:Object.check/0`; only used for display in the reasons list.
  defp safe_check_for_report(%{check: check}), do: check
  defp safe_check_for_report(entry), do: entry

  defp compare_present(class, check, expected, observed) do
    reasons =
      case Differ.compare(class, expected, observed) do
        :match -> []
        {:mismatch, reasons} -> reasons
      end ++ not_null_gap_reason(class, expected, observed)

    if reasons == [], do: nil, else: %{check: check, reasons: reasons}
  end

  # `Differ.compare/3`'s `:column` clause deliberately skips comparing
  # `not_null` whenever `expected` is exactly `%{not_null: true, default:
  # nil}` — that exemption exists for `mix phoenix_kit.repair`'s own sake
  # (its additive-only column create can never add `NOT NULL` with no
  # default to a possibly-populated table, so comparing that shape there
  # would manufacture a permanent, uncleanable finding). `Adoption` has no
  # such constraint — a module's own `CREATE TABLE`/`ADD COLUMN` can set
  # `NOT NULL` freely on a table it is creating — so this compensates for
  # that exemption explicitly here rather than silently inheriting a gap
  # that exists for a different caller's different reason. Without this, a
  # `numeric(15,2) NOT NULL, default nil` column (core's own moduledoc
  # example shape) silently verified clean even after a bare
  # `ALTER TABLE ... ALTER COLUMN ... DROP NOT NULL`.
  defp not_null_gap_reason(:column, %{not_null: true, default: nil}, observed) do
    if Map.get(observed, :not_null) == true do
      []
    else
      ["not_null: expected true, got #{inspect(Map.get(observed, :not_null))}"]
    end
  end

  defp not_null_gap_reason(_class, _expected, _observed), do: []

  # See the moduledoc's "Never raises" section. Validates a `checks` entry
  # completely before it ever reaches `Probe.lookup/2` or `Differ.compare/3`:
  # the entry's own shape (a map carrying all three keys — anything else,
  # including a non-map, falls to the catch-all clause below), that `class`
  # isn't `:seed` (see the note above `check_matches_class?/2`), `class`
  # against `@known_classes`, `class` against what `check` itself claims to
  # be INCLUDING the catalog spec's own required keys for that `kind`
  # (`check_matches_class?/2` — the guard against the silent-`:ok` class of
  # mistake described on `compare_check/2`, and against a `FunctionClauseError`
  # from `Probe.lookup/2` on a `kind`-correct but incomplete spec, e.g.
  # `{:catalog, %{kind: :column}}` missing `:table`/`:column`), and finally
  # `expected`'s own shape for that `class`.
  defp validate_checks_entry(%{class: :seed}) do
    {:error,
     "invalid check: :seed is not supported by verify_shape/3 — seed presence requires " <>
       "executing the check SQL live (see Probe.seed_present?/2), never a snapshot lookup, " <>
       "so it can never be answered from the one Probe.snapshot/2 this function takes " <>
       "(every :seed check would otherwise report \"missing\" unconditionally, true or not)"}
  end

  defp validate_checks_entry(%{class: class, check: check, expected: expected}) do
    cond do
      class not in @known_classes ->
        {:error, "invalid check: unrecognized class #{inspect(class)}"}

      not check_matches_class?(class, check) ->
        {:error, "invalid check: class #{inspect(class)} does not match check #{inspect(check)}"}

      class not in [:table, :extension, :seed] and not is_map(expected) ->
        {:error,
         "invalid check: expected must be a map for class #{inspect(class)}, got #{inspect(expected)}"}

      true ->
        case expected_shape_error(class, expected) do
          nil -> {:ok, class, check, expected}
          error -> {:error, error}
        end
    end
  end

  defp validate_checks_entry(entry) do
    {:error,
     "invalid check: expected a map with :class, :check, and :expected keys, got #{inspect(entry)}"}
  end

  # The catalog-spec keys `Probe.lookup/2`'s own clauses actually
  # pattern-match on, per `kind` — confirmed against `probe.ex` directly,
  # not `Object.catalog_spec/0`'s documented (but not identically enforced)
  # contract: `:index` genuinely only needs `:name` there (indexes are
  # looked up by name alone, not table-scoped), everything else matches
  # `Object.catalog_spec/0`'s own required-key table.
  @required_catalog_keys %{
    table: [:name],
    extension: [:name],
    sequence: [:name],
    column: [:table, :column],
    index: [:name],
    constraint: [:table, :name],
    function: [:name, :args]
  }

  # `Object.check/0` is `{:catalog, %{kind: ..., ...}}` for every class but
  # `:seed` (rejected before this is ever called — see
  # `validate_checks_entry/1`'s dedicated `:seed` clause). A malformed
  # `check` — wrong shape, wrong `kind`, a `kind`-correct catalog spec
  # missing a key that `kind` needs (`Probe.lookup/2` would otherwise raise
  # `FunctionClauseError` on it directly), or not a tuple at all — never
  # matches the real clause below and falls through to `false`; this never
  # raises, whatever `check` actually is.
  defp check_matches_class?(class, {:catalog, %{kind: kind} = spec}) do
    kind == class and
      Enum.all?(Map.get(@required_catalog_keys, kind, []), &Map.has_key?(spec, &1))
  end

  defp check_matches_class?(_class, _check), do: false

  defp expected_shape_error(class, _expected) when class in [:table, :extension, :seed],
    do: nil

  defp expected_shape_error(:column, expected),
    do: missing_keys_error(expected, [:type, :not_null, :default])

  defp expected_shape_error(:sequence, expected),
    do: missing_keys_error(expected, [:data_type, :increment, :min, :max, :cache, :cycle, :start])

  defp expected_shape_error(:function, expected),
    do: missing_keys_error(expected, [:returns, :language, :body_md5])

  defp expected_shape_error(:index, expected),
    do: missing_keys_error(expected, [:unique, :method, :keys, :opclasses, :predicate])

  defp expected_shape_error(:constraint, expected) do
    case missing_keys_error(expected, [:type]) do
      nil -> constraint_type_error(expected)
      error -> error
    end
  end

  defp constraint_type_error(%{type: "f"} = expected),
    do:
      missing_keys_error(expected, [
        :columns,
        :foreign_table,
        :foreign_columns,
        :on_delete,
        :on_update
      ])

  defp constraint_type_error(%{type: type} = expected) when type in ["p", "u"],
    do: missing_keys_error(expected, [:columns])

  defp constraint_type_error(%{type: type} = expected) when type in ["c", "x"],
    do: missing_keys_error(expected, [:definition])

  defp constraint_type_error(%{type: type}),
    do: "invalid check: unrecognized constraint type #{inspect(type)} in expected"

  defp missing_keys_error(expected, keys) do
    case Enum.filter(keys, &(not Map.has_key?(expected, &1))) do
      [] -> nil
      missing -> "invalid check: expected map missing #{inspect(missing)} for this class"
    end
  end

  # Every value here was confirmed by reading the pre-squash source
  # (`af86e3afb^:lib/phoenix_kit/migrations/postgres/v*.ex`) directly — a
  # full sweep of every descriptive (non-numeric-marker) `COMMENT ON TABLE`
  # statement across the pre-squash chain, not just the tables billing/legal
  # happen to adopt today. Two tables are deliberately absent even though
  # core once commented on them: `phoenix_kit_db_sync_connections` and
  # `phoenix_kit_db_sync_transfers` were renamed by V44's `ALTER TABLE ...
  # RENAME TO` (`phoenix_kit_sync_connections`/`phoenix_kit_sync_transfers`,
  # both included below) — the old names never exist as live tables on any
  # host that has run V44, so an entry for them could never match anything.
  # A table with no entry here at all (i.e. it never had a pre-squash
  # descriptive comment) falls through to the normal conflict check.
  @core_legacy_table_comments %{
    "phoenix_kit_admin_notes" =>
      "Internal admin notes about users (admin-to-admin communication)",
    "phoenix_kit_ai_accounts" => "AI provider accounts for text processing (OpenRouter, etc.)",
    "phoenix_kit_ai_endpoints" =>
      "AI endpoints - unified configuration combining credentials, model, and parameters",
    "phoenix_kit_ai_prompts" => "Reusable AI prompt templates with variable substitution support",
    "phoenix_kit_ai_requests" => "AI API request history for usage tracking and statistics",
    "phoenix_kit_billing_profiles" =>
      "User billing information for individuals and companies (EU Standard)",
    "phoenix_kit_buckets" =>
      "Storage provider configurations (local, AWS S3, Backblaze B2, Cloudflare R2)",
    "phoenix_kit_comment_dislikes" => "User dislikes on comments (unique per user/comment pair)",
    "phoenix_kit_comment_likes" => "User likes on comments (unique per user/comment pair)",
    "phoenix_kit_consent_logs" => "User consent tracking for GDPR/CCPA compliance cookie banners",
    "phoenix_kit_currencies" => "Supported currencies for billing with exchange rates",
    "phoenix_kit_file_instances" =>
      "File variants (thumbnails, resizes, video qualities) - one original + generated variants",
    "phoenix_kit_file_locations" =>
      "Physical storage locations for multi-location redundancy - maps instances to buckets",
    "phoenix_kit_files" =>
      "Original file uploads with metadata (images, videos, documents, archives)",
    "phoenix_kit_invoices" => "Invoices generated from orders with receipt functionality",
    "phoenix_kit_orders" => "Orders with line items, amounts, and billing information",
    "phoenix_kit_payment_options" =>
      "Available payment methods for checkout (COD, bank transfer, online payments)",
    "phoenix_kit_post_comments" =>
      "Nested threaded comments with unlimited depth (self-referencing)",
    "phoenix_kit_post_dislikes" => "User dislikes on posts (unique per user/post pair)",
    "phoenix_kit_post_group_assignments" =>
      "Post-Group many-to-many junction with position ordering",
    "phoenix_kit_post_groups" =>
      "User-created collections to organize posts (Pinterest-style boards)",
    "phoenix_kit_post_likes" => "User likes on posts (unique per user/post pair)",
    "phoenix_kit_post_media" =>
      "Post media attachments junction (ordered image galleries with captions)",
    "phoenix_kit_post_mentions" => "User mentions/contributors (tagged users related to post)",
    "phoenix_kit_post_tag_assignments" => "Post-Tag many-to-many junction",
    "phoenix_kit_post_tags" => "Hashtag system for post categorization (auto-slugified)",
    "phoenix_kit_post_views" => "Analytics tracking for post views (session-based deduplication)",
    "phoenix_kit_posts" =>
      "Social posts with media, type-specific layouts, and scheduled publishing",
    "phoenix_kit_scheduled_jobs" =>
      "Universal scheduled jobs system for posts, emails, notifications, etc.",
    "phoenix_kit_shop_cart_items" => "Cart items with price snapshots for consistency",
    "phoenix_kit_shop_carts" => "Shopping carts for users and guests with status tracking",
    "phoenix_kit_shop_categories" => "Product categories with hierarchical nesting support",
    "phoenix_kit_shop_products" => "E-commerce products (physical and digital)",
    "phoenix_kit_shop_shipping_methods" =>
      "Shipping methods with weight, price, and geographic constraints",
    "phoenix_kit_storage_dimensions" =>
      "Admin-configurable dimension presets for automatic variant generation",
    "phoenix_kit_sync_connections" =>
      "Permanent connections between PhoenixKit instances for data sync",
    "phoenix_kit_sync_transfers" =>
      "Track all data transfers (uploads and downloads) with approval workflow",
    "phoenix_kit_ticket_attachments" =>
      "File attachments for tickets or comments (with position ordering)",
    "phoenix_kit_ticket_comments" =>
      "Ticket comments with internal notes support (is_internal flag for staff-only)",
    "phoenix_kit_ticket_status_history" =>
      "Audit trail for ticket status transitions (who, when, from/to, reason)",
    "phoenix_kit_tickets" =>
      "Support tickets with status workflow (open/in_progress/resolved/closed)",
    "phoenix_kit_transactions" =>
      "Payment transactions for invoices (amount > 0 = payment, amount < 0 = refund)",
    "phoenix_kit_user_blocks" => "User blocking (prevents all interaction between users)",
    "phoenix_kit_user_blocks_history" => "Activity log of block/unblock events",
    "phoenix_kit_user_connections" =>
      "Two-way mutual connections (requires acceptance from both parties)",
    "phoenix_kit_user_connections_history" =>
      "Activity log of connection request/accept/reject/remove events",
    "phoenix_kit_user_follows" =>
      "One-way follow relationships (follower follows followed, no consent required)",
    "phoenix_kit_user_follows_history" => "Activity log of follow/unfollow events"
  }

  @doc """
  Reads the current `COMMENT ON TABLE` on `table` (schema-anchored to
  `prefix`) and decides whether the caller may write its own marker there.

  `:ok` when the table has no comment, its comment already starts with
  `own_marker_prefix`, or the comment exactly matches a known-overwritable
  string (core's own pre-squash legacy comments, or `opts[:overwritable]` —
  see the moduledoc); `{:conflict, existing_comment}` otherwise;
  `{:error, reason}` when the comment could not be reliably read at all.
  Never writes anything — the caller decides what to do with a conflict
  (the recommended pattern, per the moduledoc, is to decline and raise).

  ## Options

    * `:overwritable` — a list of exact comment strings, in addition to
      core's own known pre-squash legacy comments, that the caller has
      independently confirmed are safe to overwrite. Defaults to `[]`.
  """
  @spec marker_conflict(Ecto.Repo.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:conflict, String.t()} | {:error, term()}
  def marker_conflict(repo, prefix, table, own_marker_prefix, opts \\ [])
      when is_binary(table) and table != "" and is_binary(own_marker_prefix) and
             own_marker_prefix != "" and is_list(opts) do
    Helpers.validate_prefix!(prefix)

    case raw_table_comment(repo, prefix, table) do
      :absent -> :ok
      nil -> :ok
      {:error, reason} -> {:error, {:comment_check_failed, reason}}
      comment -> classify_comment(comment, table, own_marker_prefix, opts)
    end
  end

  defp classify_comment(comment, table, own_marker_prefix, opts) do
    cond do
      String.starts_with?(comment, own_marker_prefix) ->
        :ok

      Map.get(@core_legacy_table_comments, table) == comment ->
        :ok

      comment in Keyword.get(opts, :overwritable, []) ->
        :ok

      true ->
        {:conflict, comment}
    end
  end

  # Existence AND comment resolved by ONE query, entirely through
  # `pg_catalog.pg_class`/`pg_namespace` — deliberately never
  # `information_schema.tables`. `information_schema` views apply
  # `has_table_privilege`-style filtering per the SQL standard: a
  # lower-privileged migration connection can see ZERO rows there for a
  # table that genuinely exists (and genuinely carries a conflicting
  # marker) — live-reproduced with `SET LOCAL ROLE` dropping to a
  # lower-privileged role against a table carrying another module's
  # marker, which fell through to `:absent` → `:ok` under the old
  # two-query design. `pg_class`/`pg_namespace` are ordinary system
  # catalogs: readable for existence/metadata purposes by any connected
  # role, independent of table-level privilege, so this can't
  # under-report the same way.
  #
  # Zero rows means the table genuinely does not exist (`:absent`) — no
  # separate existence pre-check needed, this query already distinguishes
  # "no matching row" from "one row, comment is `nil`" (exists, no
  # comment) from "one row, comment is a string". Any OTHER query outcome
  # (a real failure) is `{:error, _}`, never collapsed into `:absent`.
  defp raw_table_comment(repo, prefix, table) do
    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_catalog.pg_class
    JOIN pg_catalog.pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = $1
    AND pg_namespace.nspname = $2
    AND pg_class.relkind IN ('r', 'p')
    """

    case repo.query(query, [table, prefix], log: false) do
      {:ok, %{rows: []}} -> :absent
      {:ok, %{rows: [[comment]]}} -> comment
      # `repo.query/3`'s own failure return is already `{:error, reason}` —
      # pass `reason` through unwrapped rather than re-wrapping the whole
      # tuple (which `marker_conflict/5`'s own `{:error, reason} ->
      # {:error, {:comment_check_failed, reason}}` would otherwise nest a
      # second time, leaving a caller matching on `{:error, reason}` with
      # `reason` itself shaped `{:error, actual_reason}` instead of just
      # `actual_reason`).
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end
end
