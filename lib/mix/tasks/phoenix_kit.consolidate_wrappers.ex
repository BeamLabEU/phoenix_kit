defmodule Mix.Tasks.PhoenixKit.ConsolidateWrappers do
  @moduledoc """
  Collapses a consumer app's accumulated PhoenixKit wrapper migrations into
  ONE migration file.

  "Wrapper migrations" are the files `mix phoenix_kit.install` (the
  installer's `..._add_phoenix_kit_tables.exs`) and `mix phoenix_kit.update` /
  `mix phoenix_kit.gen.migration` (`..._phoenix_kit_(force_)?update_vNN_to_vMM.exs`)
  write into the host app's `priv/repo/migrations/` — each one nothing but a
  version-pinned call to `PhoenixKit.Migrations.up/1` / `.down/1`. A long-lived
  app accumulates dozens of these; this task is the documented remedy from
  `dev_docs/plans/2026-07-14-squash-migrations-spec.md` §5.3/§9.

  ## Why this exists

  Once PhoenixKit's own history is squashed past a floor version (a later
  release), a *consumer-authored* migration that was interleaved between two
  wrapper files and depends on a below-floor intermediate shape of a
  PhoenixKit-owned object breaks on a fresh install — it now replays against
  the collapsed baseline shape instead of the exact intermediate shape that
  existed at that point in the original chain (spec §5.3's documented
  breakage class; the flagship consumer's real
  `..._phoenix_kit_catalogue_v013_base_price.exs` survives only because it
  happens to carry its own `IF EXISTS` guard). Collapsing the wrapper chain
  into one file removes the "in-between" position such a migration could ever
  have been interleaved at, making the whole breakage class moot for any repo
  that runs this task.

  ## What counts as a wrapper (content, not filename)

  A migration file counts if — and only if — it textually contains BOTH a
  `PhoenixKit.Migrations.up(...)` call and a `PhoenixKit.Migrations.down(...)`
  call. This is deliberately a *content* signature, not a filename pattern:

    * `mix phoenix_kit.update` zero-pads the version in its filename
      (`..._v05_to_v27...`); `mix phoenix_kit.gen.migration` does not
      (`..._v5_to_v27...`) — both are recognized, because neither filename
      shape is inspected at all.
    * The installer's own filename convention has drifted historically
      (`add_phoenix_kit_tables` today; `create_phoenix_kit_tables` is what
      `phoenix_kit.gen.migration`'s pre-existing version-scan bug still
      assumes) — both forms, and any other name, are recognized the same way.
    * A consumer-authored migration that merely *mentions* "phoenix_kit" in
      its name or comments — the real
      `..._phoenix_kit_catalogue_v013_base_price.exs`, which hand-writes
      `ALTER TABLE` against a PhoenixKit-owned column — does **not** call the
      wrapper API, so it is correctly never a collapse candidate and always
      counts as foreign for the interleaving check below. That is the whole
      point: this is exactly the file class a floor-raising squash can later
      break, and exactly the file class this task must never touch or
      silently reorder past without the operator's explicit say-so.

  Classification is pure text/regex scanning — the scanner never evaluates or
  parses the files it reads as code, so a syntactically broken foreign
  migration elsewhere in the directory cannot crash it. A file that contains
  one of the two calls but not its counterpart, or whose `up`/`down` calls
  disagree with each other on `prefix:`, is reported as unparseable and
  always blocks the run (never bypassable with `--force`, unlike the
  interleaving refusal below) — this task never guesses at a wrapper's
  intended shape.

  ## The interleaving refusal

  If any non-wrapper (foreign) file's timestamp falls between the earliest
  and latest in-scope wrapper file's timestamp, this task refuses by default:
  collapsing the wrapper chain into one file at the *earliest* wrapper's
  timestamp changes that foreign migration's execution order relative to
  what is now a single PhoenixKit step, and only the operator can judge
  whether that reordering is safe for that specific migration. Pass `--force`
  to proceed anyway. The foreign file(s) are left completely untouched on
  disk either way — only their *relative position* against the (now
  collapsed) PhoenixKit chain changes. Shape-guard any consumer migration
  that touches PhoenixKit-owned objects (`IF EXISTS` / column-existence
  checks) before doing this, the same way you would before a future
  PhoenixKit floor-raising squash.

  Wrapper files that belong to a **different** schema prefix (multi-prefix
  installs) are never treated as foreign for this purpose — they are simply
  out of scope for the current run. Pass `--prefix` to pick which chain to
  collapse when more than one is found (the run refuses, listing every
  prefix found, until you do).

  ## The crux invariant: Ecto version bookkeeping

  Ecto's `schema_migrations` table records *applied* migrations by the
  integer version parsed from each file's leading digits — it has no notion
  of a file's contents, only what timestamp it is filed under. This task's
  new file reuses the **first replaced wrapper's exact timestamp**, and that
  one decision is what makes collapsing safe on already-migrated databases:

    * **Already-migrated database** (any environment where the original
      wrapper chain already ran to completion): `schema_migrations` already
      has a row for the first wrapper's version number. After this task
      deletes the old files and writes the new one under that *same* version
      number, `mix ecto.migrate` sees that version as already applied and
      skips the new file too — it is never re-executed. The other replaced
      wrappers' version rows become harmless orphans: permanent journal
      entries pointing at filenames that no longer exist, which Ecto has
      never required to still be present in order to consider a version
      "applied".
    * **Fresh database** (never migrated through any of the replaced files):
      `mix ecto.migrate` finds exactly one PhoenixKit-related file in the
      collapsed range and runs its `up/0`, which calls
      `PhoenixKit.Migrations.up/1` directly at the *last* wrapper's target
      version (or unpinned — jumping straight to whatever the installed
      PhoenixKit's `current_version/0` is — if the collapsed chain itself
      ended unpinned, i.e. consisted only of the installer). PhoenixKit's own
      fresh-install path (`initial_version == 0`) always installs directly to
      the target version in one pass regardless of how many intermediate
      pins the original chain had, so collapsing loses no fidelity for a
      fresh install.
    * **Rollback** (`mix ecto.rollback` against the new file) calls
      `PhoenixKit.Migrations.down/1` pinned to the *first* replaced wrapper's
      own starting version — exactly what rolling the entire original chain
      back would have produced. This is an intentional, permanent loss of
      granularity: after this task runs, you can no longer roll back to a
      version that used to sit strictly between the first and last replaced
      wrapper. Losing exactly that granularity is what "collapsing history"
      means — do not run this task against a chain you still expect to
      partially roll back within.

  **Precondition this task cannot check for you** (it never opens a database
  connection, by design — see "DB-free by design" below): every environment
  must be either fully migrated through the *last* replaced wrapper, or not
  migrated through *any* of them, before you `--apply` and ship the result. A
  database that is only partially through the old chain — has applied
  wrapper #1 but not wrapper #2 — starts, after collapsing, from a file whose
  version is *already* marked applied (wrapper #1's own version number), so
  `mix ecto.migrate` will skip the new file too and that database will never
  advance to the collapsed target version. Confirm every environment's
  applied-migration state (your app's `mix ecto.migrate` status, or
  `mix phoenix_kit.update --status` for the PhoenixKit side specifically)
  before applying — the same discipline `mix phoenix_kit.update`'s own
  upgrade guide asks for when bumping a version pin.

  ## DB-free by design

  This task only ever reads and writes files under the migrations directory.
  It never opens a database connection and never inspects `schema_migrations`
  — the precondition above is the operator's to confirm, on every
  environment, before `--apply`.

  ## Usage

      mix phoenix_kit.consolidate_wrappers                # dry run (default)
      mix phoenix_kit.consolidate_wrappers --apply         # write the change
      mix phoenix_kit.consolidate_wrappers --apply --force # bypass the interleaving refusal
      mix phoenix_kit.consolidate_wrappers --prefix auth   # pick one chain among several
      mix phoenix_kit.consolidate_wrappers --migrations-dir path/to/migrations

  ## Options

    * `--dry-run` — print the plan without touching anything (the default;
      accepted explicitly for scripting clarity — identical to passing
      nothing)
    * `--apply` — write the new file and delete the ones it replaces
    * `--force` — proceed even though a foreign migration is interleaved
      between the first and last in-scope PhoenixKit wrapper (see "The
      interleaving refusal"); never bypasses an *unparseable*-wrapper refusal
    * `--prefix SCHEMA` — only consider wrapper files for this schema prefix;
      required when wrappers for more than one prefix are found
    * `--migrations-dir DIR` — defaults to `priv/repo/migrations`
  """

  use Mix.Task

  alias PhoenixKit.Migrations.Postgres.Helpers

  @shortdoc "Collapses accumulated PhoenixKit wrapper migrations into one file"

  @switches [
    apply: :boolean,
    dry_run: :boolean,
    force: :boolean,
    prefix: :string,
    migrations_dir: :string,
    help: :boolean
  ]

  @consolidated_module "PhoenixKitConsolidated"
  @consolidated_slug "phoenix_kit_consolidated"

  @up_call_re ~r/PhoenixKit\.Migrations\.up\(/
  @down_call_re ~r/PhoenixKit\.Migrations\.down\(/

  @impl Mix.Task
  def run(argv) do
    opts = parse_args(argv)

    if opts.help do
      Mix.shell().info(help_text())
    else
      execute(opts)
    end
  end

  # ---------------------------------------------------------------------
  # Argument parsing
  # ---------------------------------------------------------------------

  @doc false
  def parse_args(argv) do
    {parsed, _rest, _invalid} = OptionParser.parse(argv, switches: @switches, aliases: [h: :help])

    %{
      apply?: Keyword.get(parsed, :apply, false),
      force?: Keyword.get(parsed, :force, false),
      prefix: Keyword.get(parsed, :prefix),
      migrations_dir: Keyword.get(parsed, :migrations_dir, default_migrations_dir()),
      help: Keyword.get(parsed, :help, false)
    }
  end

  defp default_migrations_dir, do: Path.join(["priv", "repo", "migrations"])

  # ---------------------------------------------------------------------
  # Orchestration
  # ---------------------------------------------------------------------

  @doc false
  def execute(opts) do
    case discover(opts.migrations_dir) do
      {:error, :enoent} ->
        Mix.shell().info(
          "No migrations directory found at #{opts.migrations_dir} — nothing to do."
        )

      {:ok, entries} ->
        dispatch_plan(entries, opts)
    end
  end

  defp dispatch_plan(entries, opts) do
    plan_opts = %{prefix: opts.prefix, force: opts.force?}

    case build_plan(entries, plan_opts) do
      {:noop, reason} -> report_noop(reason, opts)
      {:error, reason} -> report_error_and_raise(reason)
      {:ok, plan} -> handle_plan(plan, opts)
    end
  end

  defp handle_plan(plan, %{apply?: true} = opts) do
    print_plan(plan, opts)
    apply!(plan)

    Mix.shell().info(
      "\n✅ Wrote #{plan.filename}; deleted #{length(plan.files_to_delete)} wrapper file(s)."
    )
  end

  defp handle_plan(plan, opts) do
    print_plan(plan, opts)
    Mix.shell().info("\n(dry run — pass --apply to write these changes)")
  end

  defp print_plan(plan, opts) do
    shell = Mix.shell()
    mode = if opts.apply?, do: "APPLY", else: "DRY RUN"

    shell.info("""

    PhoenixKit wrapper consolidation plan (#{mode})
      Prefix:        #{plan.prefix}
      Rolls back to: V#{plan.down_target} (down)
      Installs to:   #{up_target_label(plan.up_target)} (up)
      New file:      #{plan.filename}
    """)

    shell.info("  Replacing #{length(plan.files_to_delete)} file(s):")
    Enum.each(plan.files_to_delete, &shell.info("    - #{Path.basename(&1)}"))

    print_forced_interleaved(plan, shell)
  end

  defp print_forced_interleaved(%{forced_interleaved: []}, _shell), do: :ok

  defp print_forced_interleaved(%{forced_interleaved: interleaved}, shell) do
    shell.info("""

      ⚠️  --force bypassed #{length(interleaved)} interleaved non-PhoenixKit
         migration(s) — their execution order relative to the collapsed
         range has changed. Left untouched on disk:
    """)

    Enum.each(interleaved, &shell.info("    - #{Path.basename(&1.path)}"))
  end

  defp report_noop(:none_found, opts) do
    Mix.shell().info(
      "No PhoenixKit wrapper migrations found in #{opts.migrations_dir} — nothing to consolidate."
    )
  end

  defp report_noop(:single_wrapper, opts) do
    Mix.shell().info(
      "Only one PhoenixKit wrapper migration found in #{opts.migrations_dir} " <>
        "— already minimal, nothing to consolidate."
    )
  end

  defp report_error_and_raise({:unparseable, entries}) do
    listing = Enum.map_join(entries, "\n", &unparseable_line/1)

    Mix.raise("""
    Found file(s) that reference PhoenixKit.Migrations.up/down but could not
    be parsed as a recognized wrapper shape — refusing to guess:

    #{listing}

    Fix or remove these by hand, then re-run. This refusal is never
    bypassable with --force.
    """)
  end

  defp report_error_and_raise({:mixed_prefixes, groups}) do
    listing =
      Enum.map_join(groups, "\n", fn {prefix, entries} ->
        files = Enum.map_join(entries, ", ", &Path.basename(&1.path))
        "  - #{prefix}: #{files}"
      end)

    Mix.raise("""
    PhoenixKit wrapper migrations for more than one schema prefix were found:

    #{listing}

    Pass --prefix to consolidate one chain at a time.
    """)
  end

  defp report_error_and_raise({:interleaved, entries}) do
    listing = Enum.map_join(entries, "\n", &"  - #{Path.basename(&1.path)}")

    Mix.raise("""
    Refusing to consolidate: the following migration(s) are NOT PhoenixKit
    wrappers but sit between the first and last in-scope PhoenixKit wrapper
    by timestamp. Collapsing across them would reorder your migration
    history relative to theirs:

    #{listing}

    Shape-guard those migrations (or confirm the reorder is safe) and re-run
    with --force to proceed anyway.
    """)
  end

  defp unparseable_line(%{path: path, tag: {:unparseable, reason}}),
    do: "  - #{Path.basename(path)}: #{reason}"

  defp up_target_label(:unpinned), do: "the latest installed PhoenixKit version"
  defp up_target_label(version), do: "V#{version}"

  # ---------------------------------------------------------------------
  # Discovery — list migration-shaped files and read their content
  # ---------------------------------------------------------------------

  @doc false
  def discover(migrations_dir) do
    if File.dir?(migrations_dir) do
      entries =
        migrations_dir
        |> File.ls!()
        |> Enum.filter(&migration_filename?/1)
        |> Enum.map(&build_entry(migrations_dir, &1))
        |> Enum.sort_by(& &1.timestamp)

      {:ok, entries}
    else
      {:error, :enoent}
    end
  end

  defp migration_filename?(filename) do
    String.ends_with?(filename, ".exs") and Regex.match?(~r/^\d+_/, filename)
  end

  defp build_entry(dir, filename) do
    path = Path.join(dir, filename)
    [_, ts] = Regex.run(~r/^(\d+)_/, filename)

    %{
      path: path,
      filename: filename,
      timestamp: String.to_integer(ts),
      timestamp_str: ts,
      content: File.read!(path)
    }
  end

  # ---------------------------------------------------------------------
  # Classification — pure text scanning, never Code.eval'd
  # ---------------------------------------------------------------------

  # Classifies one migration file's content as `:foreign` (not a PhoenixKit
  # wrapper), `{:wrapper, shape}` (calls both `PhoenixKit.Migrations.up/1` and
  # `.down/1`, cleanly parsed), or `{:unparseable, reason}` (references the
  # wrapper API but not in a shape this task can safely interpret). See the
  # moduledoc's "What counts as a wrapper" section. Pure — never touches disk,
  # never evaluates `content` as code.
  @doc false
  def classify(content) do
    classify_by_args(
      extract_call_args(content, @up_call_re),
      extract_call_args(content, @down_call_re)
    )
  end

  defp classify_by_args(:unbalanced, _down_args),
    do: {:unparseable, "PhoenixKit.Migrations.up(...) call has unbalanced parentheses"}

  defp classify_by_args(_up_args, :unbalanced),
    do: {:unparseable, "PhoenixKit.Migrations.down(...) call has unbalanced parentheses"}

  defp classify_by_args(nil, nil), do: :foreign

  defp classify_by_args(nil, _down_args),
    do: {:unparseable, "calls PhoenixKit.Migrations.down/1 without a matching .up/1 call"}

  defp classify_by_args(_up_args, nil),
    do: {:unparseable, "calls PhoenixKit.Migrations.up/1 without a matching .down/1 call"}

  defp classify_by_args(up_args, down_args), do: classify_wrapper(up_args, down_args)

  defp classify_wrapper(up_args, down_args) do
    with {:ok, prefix} <- resolve_prefix(up_args, down_args) do
      {:wrapper,
       %{
         prefix: prefix,
         up_version: extract_version(up_args) || :unpinned,
         down_version: extract_version(down_args) || 0,
         create_schema: resolve_create_schema(up_args, down_args)
       }}
    end
  end

  defp resolve_prefix(up_args, down_args) do
    up_prefix = extract_prefix(up_args)
    down_prefix = extract_prefix(down_args)

    if up_prefix && down_prefix && up_prefix != down_prefix do
      {:unparseable, "up/down calls disagree on prefix (#{up_prefix} vs #{down_prefix})"}
    else
      validated_prefix(up_prefix || down_prefix || "public")
    end
  end

  defp validated_prefix(prefix) do
    Helpers.validate_prefix!(prefix)
    {:ok, prefix}
  rescue
    e in ArgumentError -> {:unparseable, Exception.message(e)}
  end

  # `false` is a real, deliberate value here — prefer the up-call's explicit
  # setting (even when it is literally `false`) over the down-call's, and
  # only fall back to a hardcoded `false` default when NEITHER call states
  # it (the installer's public-prefix form omits it entirely, since it is a
  # no-op for the public schema either way).
  defp resolve_create_schema(up_args, down_args) do
    case extract_create_schema(up_args) do
      nil -> extract_create_schema(down_args) || false
      value -> value
    end
  end

  defp extract_version(args) do
    case Regex.run(~r/version:\s*(\d+)/, args) do
      [_, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  defp extract_prefix(args) do
    case Regex.run(~r/prefix:\s*"([^"]*)"/, args) do
      [_, prefix] -> prefix
      nil -> nil
    end
  end

  defp extract_create_schema(args) do
    case Regex.run(~r/create_schema:\s*(true|false)/, args) do
      [_, "true"] -> true
      [_, "false"] -> false
      nil -> nil
    end
  end

  # Locates `call_regex` (one of `@up_call_re`/`@down_call_re`) and returns
  # the raw text of its argument list — everything between the call's own
  # "(" and its matching ")" — or `nil` when the call is absent, or
  # `:unbalanced` when it is present but never closes before EOF.
  defp extract_call_args(content, call_regex) do
    case Regex.run(call_regex, content, return: :index) do
      [{start, len}] ->
        args_start = start + len
        tail = :binary.part(content, args_start, byte_size(content) - args_start)

        case scan_balanced(tail, 1, false, 0) do
          nil -> :unbalanced
          byte_count -> :binary.part(tail, 0, byte_count)
        end

      nil ->
        nil
    end
  end

  # Balanced-paren scan starting just AFTER a call's opening "(" (depth 1),
  # aware of double-quoted string literals (a hypothetical ")" inside a
  # quoted value can never terminate early) and backslash-escaped characters
  # within them. Returns the byte length of the args text up to (excluding)
  # the matching close paren, or nil if the input runs out unbalanced.
  #
  # Byte-oriented throughout (never String.*/codepoint-based), which makes it
  # correct even if unrelated content elsewhere in the file contains
  # multi-byte UTF-8: every continuation/leading byte of a multi-byte UTF-8
  # sequence has its high bit set, so it can never be misread as the ASCII
  # '(', ')', '"', or the escape backslash this scan matches on.
  defp scan_balanced(<<?\\, _escaped, rest::binary>>, depth, true, count),
    do: scan_balanced(rest, depth, true, count + 2)

  defp scan_balanced(<<?", rest::binary>>, depth, in_string, count),
    do: scan_balanced(rest, depth, not in_string, count + 1)

  defp scan_balanced(<<?(, rest::binary>>, depth, false, count),
    do: scan_balanced(rest, depth + 1, false, count + 1)

  defp scan_balanced(<<?), _rest::binary>>, 1, false, count), do: count

  defp scan_balanced(<<?), rest::binary>>, depth, false, count),
    do: scan_balanced(rest, depth - 1, false, count + 1)

  defp scan_balanced(<<_byte, rest::binary>>, depth, in_string, count),
    do: scan_balanced(rest, depth, in_string, count + 1)

  defp scan_balanced(<<>>, _depth, _in_string, _count), do: nil

  # ---------------------------------------------------------------------
  # Planning — decide what, if anything, to collapse
  # ---------------------------------------------------------------------

  # Builds the consolidation plan from `discover/1`'s entries.
  #
  # `opts` is a map with optional `:prefix` (restrict to one schema's chain)
  # and `:force` (proceed despite an interleaved foreign migration).
  #
  # Returns:
  #
  #   * `{:ok, plan}` — safe to print/apply.
  #   * `{:noop, :none_found | :single_wrapper}` — nothing to do.
  #   * `{:error, {:unparseable, entries}}` — always fatal, never bypassable.
  #   * `{:error, {:mixed_prefixes, %{prefix => entries}}}` — pass `--prefix`.
  #   * `{:error, {:interleaved, entries}}` — pass `--force` to bypass.
  @doc false
  def build_plan(entries, opts \\ %{}) do
    tagged = Enum.map(entries, &Map.put(&1, :tag, classify(&1.content)))
    unparseable = Enum.filter(tagged, &match?({:unparseable, _reason}, &1.tag))

    if unparseable != [] do
      {:error, {:unparseable, unparseable}}
    else
      resolve_scope(tagged, Map.get(opts, :prefix), Map.get(opts, :force, false))
    end
  end

  defp resolve_scope(tagged, prefix_filter, force?) do
    wrappers = Enum.filter(tagged, &in_scope?(&1.tag, prefix_filter))

    case wrappers do
      [] -> {:noop, :none_found}
      [_one] -> {:noop, :single_wrapper}
      many -> resolve_prefix_group(many, tagged, prefix_filter, force?)
    end
  end

  defp in_scope?({:wrapper, %{prefix: _prefix}}, nil), do: true
  defp in_scope?({:wrapper, %{prefix: prefix}}, filter), do: prefix == filter
  defp in_scope?(_tag, _filter), do: false

  defp resolve_prefix_group(wrappers, tagged, prefix_filter, force?) do
    distinct = wrappers |> Enum.map(&elem(&1.tag, 1).prefix) |> Enum.uniq()

    if is_nil(prefix_filter) and length(distinct) > 1 do
      {:error, {:mixed_prefixes, group_by_prefix(wrappers)}}
    else
      finalize_plan(wrappers, tagged, force?)
    end
  end

  defp group_by_prefix(wrappers), do: Enum.group_by(wrappers, &elem(&1.tag, 1).prefix)

  defp finalize_plan(wrappers, tagged, force?) do
    sorted = Enum.sort_by(wrappers, & &1.timestamp)
    first = List.first(sorted)
    last = List.last(sorted)
    {:wrapper, first_shape} = first.tag
    {:wrapper, last_shape} = last.tag

    interleaved = interleaved_foreign(tagged, first.timestamp, last.timestamp)

    if interleaved != [] and not force? do
      {:error, {:interleaved, interleaved}}
    else
      {:ok, assemble_plan(sorted, first, first_shape, last_shape, interleaved)}
    end
  end

  defp interleaved_foreign(tagged, first_ts, last_ts) do
    tagged
    |> Enum.filter(&(&1.tag == :foreign and &1.timestamp >= first_ts and &1.timestamp <= last_ts))
    |> Enum.sort_by(& &1.timestamp)
  end

  defp assemble_plan(sorted, first, first_shape, last_shape, interleaved) do
    filename = "#{first.timestamp_str}_#{@consolidated_slug}.exs"
    dir = Path.dirname(first.path)
    path = Path.join(dir, filename)

    %{
      prefix: first_shape.prefix,
      create_schema: first_shape.create_schema,
      up_target: last_shape.up_version,
      down_target: first_shape.down_version,
      timestamp_str: first.timestamp_str,
      dir: dir,
      filename: filename,
      path: path,
      # Excludes `path` itself — on a RE-consolidation, `first` is already a
      # previously-consolidated file whose filename equals this run's
      # computed target (same slug, same earliest timestamp), so
      # `path == first.path` and `first.path` would otherwise be a member
      # of `sorted`'s own paths. `apply!/1` writes `path` before deleting
      # anything in `files_to_delete` specifically to avoid ever deleting a
      # file it just wrote — but that guarantee only holds if the file it
      # just wrote is never ALSO listed for deletion. Without this reject, a
      # re-consolidation run deletes the very file it just (re)wrote,
      # leaving the directory with zero PhoenixKit migration files.
      files_to_delete: sorted |> Enum.map(& &1.path) |> Enum.reject(&(&1 == path)),
      forced_interleaved: interleaved
    }
  end

  # ---------------------------------------------------------------------
  # Rendering — the replacement migration's source
  # ---------------------------------------------------------------------

  # Renders the consolidated migration file's full source, `mix format`-clean.
  # Pure — takes a plan (as built by `build_plan/2`), returns a string.
  #
  # Every moduledoc line below is built as ONE interpolated value (never a
  # multi-line interpolation) so its placement in the outer heredoc's fixed
  # indentation is unambiguous — `Code.format_string!/1` normalizes a
  # heredoc's own literal-line indentation, but it operates on SOURCE text
  # and has no visibility into what a runtime interpolation's VALUE
  # contains, so a multi-line interpolated value would land at whatever
  # indentation it already had, not the surrounding template's.
  @doc false
  def render_content(plan) do
    raw = """
    defmodule #{app_module_name()}.Repo.Migrations.#{@consolidated_module} do
      @moduledoc \"\"\"
      #{intro_line(plan)}

      * #{bullet_already_applied(plan)}
      * #{bullet_fresh(plan)}
      * #{bullet_rollback(plan)}

      See `mix help phoenix_kit.consolidate_wrappers` for the full invariant this relies on.
      \"\"\"
      use Ecto.Migration

      @disable_ddl_transaction true

      def up do
        #{render_up_call(plan)}
      end

      def down do
        #{render_down_call(plan)}
      end
    end
    """

    raw |> Code.format_string!() |> IO.iodata_to_binary() |> Kernel.<>("\n")
  end

  defp intro_line(plan) do
    "Collapses #{length(plan.files_to_delete)} PhoenixKit wrapper migration(s) that " <>
      "previously ran between V#{plan.down_target} and #{up_target_label(plan.up_target)} " <>
      "into this one file, generated by `mix phoenix_kit.consolidate_wrappers`."
  end

  defp bullet_already_applied(plan) do
    "A database that had already applied the original chain sees this exact " <>
      "migration version (\##{plan.timestamp_str}) as already applied and skips it " <>
      "— the replaced versions become harmless orphan rows in `schema_migrations`."
  end

  defp bullet_fresh(plan) do
    "A fresh database runs this file's `up/0` directly to #{up_target_label(plan.up_target)}."
  end

  defp bullet_rollback(plan) do
    "`mix ecto.rollback` against this file now rolls all the way back to " <>
      "V#{plan.down_target} (the first replaced wrapper's starting point) — the " <>
      "intermediate history this file replaces can no longer be rolled back to individually."
  end

  defp render_up_call(plan), do: "PhoenixKit.Migrations.up(#{inspect(up_opts(plan))})"

  defp render_down_call(plan) do
    "PhoenixKit.Migrations.down(#{inspect(prefix: plan.prefix, version: plan.down_target)})"
  end

  defp up_opts(%{up_target: :unpinned} = plan),
    do: [prefix: plan.prefix, create_schema: plan.create_schema]

  defp up_opts(%{up_target: version} = plan),
    do: [prefix: plan.prefix, create_schema: plan.create_schema, version: version]

  defp app_module_name do
    Mix.Project.config()[:app]
    |> to_string()
    |> Macro.camelize()
  end

  # ---------------------------------------------------------------------
  # Apply — write the new file, then delete the ones it replaces
  # ---------------------------------------------------------------------

  # Writes the plan's new migration file, then deletes the files it replaces.
  #
  # Order matters for crash-safety: the new file is written FIRST. If the
  # process dies between the write and the deletes, the migrations directory
  # is left with both the new file and (some of) the old ones under it — a
  # DUPLICATE migration version, which Ecto refuses to run at all until a
  # human deletes the leftover duplicate. That is a loud, immediately-visible
  # failure. The alternative order (delete old files first) risks the
  # opposite: a crash after deleting every old wrapper but before writing the
  # new one would leave a directory with NO PhoenixKit migration in that
  # range at all — a silent gap that `mix ecto.migrate` would not complain
  # about, and that is worse.
  #
  # `render_content/1`'s call to `Code.format_string!/1` is this function's
  # parse gate: a malformed render raises here, before anything on disk is
  # touched.
  @doc false
  def apply!(plan) do
    content = render_content(plan)

    File.write!(plan.path, content)
    Enum.each(plan.files_to_delete, &File.rm!/1)

    :ok
  end

  # ---------------------------------------------------------------------
  # Help
  # ---------------------------------------------------------------------

  defp help_text do
    """

    mix phoenix_kit.consolidate_wrappers - Collapse PhoenixKit wrapper migrations

    USAGE
      mix phoenix_kit.consolidate_wrappers [OPTIONS]

    DESCRIPTION
      Scans priv/repo/migrations (or --migrations-dir) for PhoenixKit wrapper
      migrations — files that call PhoenixKit.Migrations.up/1 and .down/1 —
      and replaces the whole chain with ONE file. Default is a dry run; pass
      --apply to write the change. See `mix help phoenix_kit.consolidate_wrappers`
      for the full design rationale, including the Ecto version-bookkeeping
      invariant this relies on and the precondition this task cannot check
      for you.

    OPTIONS
      --dry-run                Print the plan only (default)
      --apply                  Write the new file and delete the replaced ones
      --force                  Proceed despite an interleaved foreign migration
      --prefix SCHEMA           Restrict to one schema's wrapper chain
      --migrations-dir DIR      Defaults to priv/repo/migrations
      -h, --help                Show this help message
    """
  end
end
