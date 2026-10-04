defmodule Mix.Tasks.PhoenixKit.Doctor do
  @moduledoc """
  Diagnoses PhoenixKit installation, migration, and runtime issues.

  Runs a comprehensive suite of checks covering database connectivity, pool
  configuration, PgBouncer detection, migration state, lock conflicts, and
  application configuration. Prints a clear pass/fail report with actionable
  remediation steps.

  ## Usage

      $ mix phoenix_kit.doctor
      $ mix phoenix_kit.doctor --prefix=auth
      $ mix phoenix_kit.doctor --exit-code

  ## Options

    * `--prefix` - Database schema prefix. When omitted, resolves from
      `config :phoenix_kit, :prefix`, then `"public"` — the same resolution
      `mix phoenix_kit.update` / `--status` use, so a prefixed install is
      diagnosed against the schema it actually lives in.
    * `--exit-code` - Exit non-zero when any check FAILED. Without it this task
      prints "N failures" and still exits 0, so a deploy script that runs it
      cannot act on the result — the same silent success `mix phoenix_kit.status
      --exit-code` exists to remove. Warnings never fail the run; they are
      advisory by construction and several fire on healthy installs. Off by
      default so deploys that run this purely for its report keep passing.

  ## Checks Performed

    1. **Repo Detection** — Can we find and start the Ecto repo?
    2. **DB Connectivity** — Can we execute a simple query?
    3. **Pool Configuration** — Pool size, checkout timeout, queue settings
    4. **PgBouncer Detection** — Is PgBouncer between app and PostgreSQL?
    5. **Migration State** — PhoenixKit version (COMMENT), schema_migrations alignment
    6. **Module Schema Versions** — Modules owning their own chain, vs what their code expects
    7. **Schema Drift** — Columns a migration should have added but the DB lacks
    8. **Pending Migrations** — Migration files not yet recorded in schema_migrations
    9. **UUID Column Types** — Detects varchar uuid columns that crash Ecto on startup
   10. **UUID Primary Keys** — Detects primary keys that are not the expected uuid type
   11. **NULL UUIDs in FK Sources** — Detects NULL uuids that cause infinite backfill loops
   12. **Orphaned FK References** — Detects orphaned rows behind an existing FK
       constraint, whether it is already VALID (a trigger-bypassed write, a
       bulk load, direct catalog surgery) or still NOT VALID (would block its
       own VALIDATE), and existing constraints still sitting NOT VALID with
       nothing currently blocking them — V176 validates those in place; this
       just tells you before it does. Two boundaries on what "checked" means
       here: discovery reads `pg_constraint`, so a relationship with no FK
       constraint declared at all is outside this check's scope and is not
       examined; and discovery matches both the owning table and the
       referenced table to the schema being checked (`--prefix`), so a FK
       whose referenced table lives in a different schema is outside scope
       too, even though the owning table itself was checked
   13. **Schema-Declared Relations Without a DB FK** — Every `belongs_to`
       PhoenixKit's own Ecto schemas declare, cross-referenced against
       `pg_constraint` for a matching foreign key. Reports the COUNT found
       with no DB-level FK — informational, not a failure: some are
       intentional (a federated/soft reference cannot carry a FK across an
       optional module boundary, see V179/V180). This is the complement to
       check 12's own stated gap above: check 12 only ever sees a
       relationship that already HAS a declared FK constraint; this one
       finds relationships Ecto declares that never got one. Derived
       entirely from what the schema itself declares (`owner_key` on the
       `belongs_to`), never guessed from a column name — so it also cannot
       see a soft reference that isn't declared as a `belongs_to` at all
       (e.g. a plain field, or a polymorphic `*_uuid`/`*_type` pair).
   14. **Lock Conflicts** — Any blocked or long-running queries?
   15. **Orphaned Connections** — Idle-in-transaction or stuck connections
   16. **Oban Configuration** — Queues and plugins that consume pool connections
   17. **Oban Cron Queues** — Does every crontab worker have its queue configured?
   18. **PhoenixKit Supervisor** — What's running (update_mode vs full)?
   19. **Child Start Order** — Does the Repo start before PhoenixKit/Oban in application.ex?
   20. **Update Mode** — Is update_mode active?
   21. **daisyUI Version** — Is the host's vendored daisyUI recent enough?
   22. **User Dashboard (deprecated)** — Is the host still on the retired dashboard?
   23. **Sitemap Discoverability** — Is the sitemap actually reachable?
   24. **Crawler Visibility** — noindex on a production-looking host, or a
       staging-looking host left indexable
   25. **Demo Auth Pages** — Are the demo auth routes still exposed?
   26. **Manifest Repair (dry-run)** — `PhoenixKit.Migrations.Repair.verify/1`
       runs read-only against the generated
       `PhoenixKit.Migrations.ExpectedSchema` manifest as an additional,
       non-fatal check (never `:fail`). Passes and says so if the manifest
       has been removed or overridden away in this checkout.
   27. **Git Hooks** — does `core.hooksPath` point at a directory that has an
       executable `pre-commit` in it? Any directory qualifies — `.githooks`
       is only the convention this checkout happens to track. Only runs
       inside a checkout of phoenix_kit itself (that convention is a
       phoenix_kit-repo thing, not something installed into a consuming host
       app) — silently skipped otherwise.
  """

  use Mix.Task

  alias PhoenixKit.Install.ChildOrder
  alias PhoenixKit.Install.PrefixConfig
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Migrations.ExpectedSchema.Resolver
  alias PhoenixKit.Migrations.Modules, as: MigrationModules
  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Repair
  alias PhoenixKit.Migrations.Repair.Environment
  alias PhoenixKit.Migrations.Repair.Report
  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Crawlers.Bots
  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Modules.Sitemap.RouteResolver
  alias PhoenixKit.Modules.Storage.Dimension
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Utils.Routes

  @shortdoc "Diagnoses PhoenixKit installation, migration, and runtime issues"

  @switches [prefix: :string, exit_code: :boolean, fingerprint: :boolean]
  @aliases [p: :prefix]

  # The longest timeout/1 any worker PhoenixKit ships declares
  # (Storage.Jobs.Reconcile). A Lifeline rescue_after at or below this is
  # unsafe by construction — see check_lifeline_plugin/2.
  @lifeline_min_rescue_after :timer.minutes(30)

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    # Start app with minimal footprint (same approach as phoenix_kit.update)
    Mix.Task.run("app.config")

    # Resolve the prefix AFTER app.config loads config, so a configured
    # non-public prefix is honored — same resolution the updater/status use
    # (--prefix flag → config :phoenix_kit, :prefix → "public"). Reading
    # opts[:prefix] || "public" here queries the version marker at public and
    # reports a prefixed install as "not installed".
    prefix = PrefixConfig.resolve_prefix(opts)

    # Snapshot the host's Oban config BEFORE cap_repo_pool_size/1 zeroes its
    # queues/plugins (it does that to conserve connections in update_mode) —
    # otherwise the Oban Configuration check reports "0 queues, 0 plugins".
    oban_config = Application.get_env(Mix.Project.config()[:app], Oban)

    host_update_mode = Application.get_env(:phoenix_kit, :update_mode, false)

    cap_repo_pool_size(2)
    Application.put_env(:phoenix_kit, :update_mode, true)
    start_app_or_explain!()

    header("PhoenixKit Doctor")

    results =
      [
        run_check("Repo Detection", fn -> check_repo_detection() end),
        run_check("DB Connectivity", fn -> check_db_connectivity() end),
        run_check("Pool Configuration", fn -> check_pool_config() end),
        run_check("PgBouncer Detection", fn -> check_pgbouncer(oban_config) end),
        run_check("Migration State", fn -> check_migration_state(prefix) end),
        run_check("Module Schema Versions", fn -> check_module_schema_versions(prefix) end),
        run_check("Schema Drift", fn -> check_schema_drift(prefix) end),
        run_check("Pending Migrations", fn -> check_pending_migrations() end),
        run_check("UUID Column Types", fn -> check_uuid_column_types(prefix) end),
        run_check("UUID Primary Keys", fn -> check_uuid_primary_keys(prefix) end),
        run_check("NULL UUIDs in FK Sources", fn -> check_null_uuids(prefix) end),
        run_check("Orphaned FK References", fn -> check_orphaned_fk_refs(prefix) end),
        run_check("Schema-Declared Relations Without a DB FK", fn ->
          check_schema_declared_relations_without_fk(prefix)
        end),
        run_check("Lock Conflicts", fn -> check_lock_conflicts() end),
        run_check("Orphaned Connections", fn -> check_orphaned_connections() end),
        run_check("Oban Configuration", fn -> check_oban_config(oban_config) end),
        run_check("Declared Oban Queues", fn -> check_declared_queues(oban_config) end),
        run_check("Oban Cron Queues", fn -> check_cron_queues(oban_config) end),
        run_check("PhoenixKit Supervisor", fn -> check_supervisor_state() end),
        run_check("Child Start Order", fn -> check_child_order() end),
        run_check("Update Mode", fn -> update_mode_verdict(host_update_mode) end),
        run_check("daisyUI Version", fn -> check_daisyui() end),
        run_check("User Dashboard (deprecated)", fn -> check_user_dashboard_deprecation() end),
        run_check("Sitemap Discoverability", fn -> check_sitemap_serving(prefix) end),
        run_check("Crawler Visibility", fn -> check_crawler_visibility(prefix) end),
        run_check("Demo Auth Pages", fn -> check_demo_routes() end),
        run_check("Variant Set Standard Sizes", fn -> check_variant_sets(prefix) end),
        run_check("Image Sizes From an Older Pipeline", fn -> check_variant_pipeline(prefix) end),
        run_check("Manifest Repair (dry-run)", fn -> check_manifest_repair(prefix) end),
        run_check("Integration Key", fn -> check_integration_key(opts[:fingerprint] || false) end)
      ] ++ git_hooks_check()

    IO.puts("")
    summary(results)
    maybe_halt(results, opts[:exit_code] || false)
  end

  @doc """
  The process exit status `--exit-code` should produce: `1` when any check
  failed, `0` otherwise.

  Public because `run/1` is not a unit-test seam (it starts the app and needs a
  real database) — this is the pure decision behind the flag, in the same shape
  as `Mix.Tasks.PhoenixKit.Status.exit_code/2` and
  `Mix.Tasks.PhoenixKit.Repair.exit_code/1`.

  Only `:fail` gates. A `:warn` is advisory by construction — several fire on
  perfectly healthy installs (a capped pool under `update_mode`, an unreadable
  `application.ex`) — and gating on them would make the flag unusable, which is
  how a task ends up back at "reports a problem and exits 0".
  """
  @spec exit_code([{String.t(), {:pass | :warn | :fail, String.t()}}]) :: 0 | 1
  def exit_code(results) do
    if Enum.any?(results, fn {_name, {status, _detail}} -> status == :fail end), do: 1, else: 0
  end

  @doc """
  The "Git Hooks" verdict, as a pure function of what could actually be observed.

  Public for the same reason `exit_code/1` is: `run/1` is not a unit-test seam,
  so the decision is tested on its own.

  The point of the three-way inputs is that this check must be able to say *"I
  could not tell"* instead of guessing. A check that reports "hook not
  installed" when it merely failed to look is worse than no check: it is
  confidently wrong, and it sends the reader to fix something that is not
  broken.

  That distinction is not free, and the obvious implementation gets it wrong:
  `git config --get core.hooksPath` exits **1 both when the key is unset and
  when the current directory is not a git repository at all** (verified, not
  assumed). So repository-ness is probed separately, and only inside a
  repository is exit 1 read as the fact "not configured".

  A second trap, independent of the first: `:hooks_path` holding anything
  other than the literal string `.githooks` does not mean the hook is broken.
  `core.hooksPath` names a directory, and a user is free to point it anywhere
  — any directory with an executable `pre-commit` in it works exactly the way
  `.githooks` does; `.githooks` is only the name this checkout's own
  convention happens to use. Treating one specific value as the only correct
  answer reports a perfectly working setup as broken, and its "fix" tells the
  reader to point at a location that has nothing to do with why. So this
  checks the property that actually matters — an executable `pre-commit` at
  wherever `core.hooksPath` points — never string equality with `.githooks`.

    * `:repo` — `{:ok, common_dir}` when git answered, `:unknown` otherwise
      (not a repository, git missing, anything else).
    * `:hooks_path` — `{:ok, value}` | `:unset` (a fact) | `:unknown` (a gap).
    * `:pre_commit_executable` — whether the directory `:hooks_path` names has
      an executable `pre-commit` in it: `:yes` | `:no` | `:unknown` (only
      meaningful when `:hooks_path` is `{:ok, _}`; see `pre_commit_executable?/1`).
    * `:tracked?` — whether `.githooks/pre-commit` exists in this checkout.
    * `:shadow` — `{:ok, path}` for a leftover hook in the **common** hooks dir
      (worktrees do not have their own), `:none`, or `:unknown`.
  """
  @spec git_hooks_verdict(map()) :: {:pass | :warn, String.t()}
  def git_hooks_verdict(%{repo: :unknown}) do
    {:warn,
     "Could not check — this is not a git repository, or git is unavailable.\n" <>
       "       This is NOT the same as \"the hook is not installed\": nothing was verified."}
  end

  def git_hooks_verdict(%{tracked?: false}) do
    {:warn,
     ".githooks/pre-commit is missing from this checkout, so there is nothing to enable.\n" <>
       "       Expected the tracked hook at .githooks/pre-commit."}
  end

  def git_hooks_verdict(%{hooks_path: :unknown}) do
    {:warn,
     "Could not read core.hooksPath, so it is unknown whether the hook runs.\n" <>
       "       This is NOT the same as \"the hook is not installed\": nothing was verified."}
  end

  def git_hooks_verdict(%{hooks_path: :unset}) do
    {:warn,
     "The tracked hook is NOT running: core.hooksPath is not set.\n" <>
       "       Fix: git config core.hooksPath .githooks"}
  end

  def git_hooks_verdict(%{hooks_path: {:ok, path}, pre_commit_executable: :no}) do
    {:warn,
     "The tracked hook is NOT running: core.hooksPath points at #{inspect(path)}, " <>
       "which has no executable pre-commit in it.\n" <>
       "       Fix: point core.hooksPath at a directory that has one " <>
       "(for example .githooks, if this checkout tracks it)."}
  end

  def git_hooks_verdict(%{hooks_path: {:ok, path}, pre_commit_executable: :unknown}) do
    {:warn,
     "Could not check whether #{inspect(path)} has an executable pre-commit.\n" <>
       "       This is NOT the same as \"the hook is not installed\": nothing was verified."}
  end

  def git_hooks_verdict(%{shadow: {:ok, path}}) do
    {:warn,
     "Enabled, but #{path} still exists. core.hooksPath wins, so that copy is\n" <>
       "       dead code that will mislead the next reader. Delete it."}
  end

  def git_hooks_verdict(%{shadow: :unknown}) do
    {:warn, "Enabled via core.hooksPath, but could not check for a stale copy in the hooks dir."}
  end

  def git_hooks_verdict(%{}), do: {:pass, "tracked hook enabled via core.hooksPath"}

  @doc """
  Whether `dir` has an executable `pre-commit` in it.

  The property `git_hooks_verdict/1` actually cares about, regardless of what
  the configured directory is named or where it lives — `core.hooksPath`
  works identically for any directory that has this file, `.githooks` is not
  special to git itself.

  Public for the same reason `exit_code/1` is: a test seam over a filesystem
  fact, so `git_hooks_verdict/1` above can stay a pure function of an
  already-decided map instead of doing its own I/O.

  A relative `dir` is resolved the same way git resolves a relative
  `core.hooksPath`: against the top of the working tree (see githooks(5)),
  which is also where this task itself runs.
  """
  @spec pre_commit_executable?(String.t()) :: :yes | :no | :unknown
  def pre_commit_executable?(dir) do
    file = dir |> Path.expand(File.cwd!()) |> Path.join("pre-commit")

    case File.stat(file) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0, do: :yes, else: :no

      # A directory (or anything else) named "pre-commit" is not a hook git
      # can run, whatever its permission bits say.
      {:ok, _not_a_regular_file} ->
        :no

      {:error, :enoent} ->
        :no

      # Anything else (denied, a broken mount, ...) is a gap in what we know,
      # never evidence that the hook is missing.
      {:error, _reason} ->
        :unknown
    end
  end

  # Printing "N failures" and exiting 0 makes this task unusable as a deploy
  # gate — and it now owns a check (Module Schema Versions) whose whole point is
  # to catch an install nothing else reports on. Opt-in for the same reason
  # `mix phoenix_kit.status --exit-code` is: an existing pipeline that runs
  # doctor for its report must not start failing on an upgrade.
  #
  # `exit({:shutdown, code})` rather than `Mix.raise/1`, matching
  # `mix phoenix_kit.repair`: the failures are already printed above in full,
  # and re-raising would bury them under a second copy.
  defp maybe_halt(_results, false), do: :ok

  defp maybe_halt(results, true) do
    case exit_code(results) do
      0 -> :ok
      1 -> exit({:shutdown, 1})
    end
  end

  # ── Check implementations (return {:pass|:warn|:fail, detail}) ──────

  defp check_integration_key(show_fingerprint?) do
    integration_key_result(Encryption.key_report(), show_fingerprint?)
  end

  @doc """
  The "Integration Key" verdict, rendered from one complete report.

  Takes the report and a display choice, and **nothing else**. That is the whole
  point of the signature: this check previously received the advice, a
  fingerprint note and a storage location as separate arguments, each computed
  without reference to the others, and three consecutive rounds of fixes each
  produced a message that contradicted itself — a fingerprint note beside "no
  key resolved at all", a storage location for a key stored nowhere, a claim of
  a weaker key where none existed.

  There is no longer an argument through which those pieces could disagree: the
  fingerprint and the tier that produced it are one term inside the report, and
  they are absent together when there is no key.

  Public as a test seam, for the same reason `exit_code/1` is: the defects lived
  in this rendering, where tests over the diagnosis could not reach them.
  """
  @spec integration_key_result(Encryption.key_report(), boolean()) ::
          {:pass | :warn | :fail, String.t()}
  def integration_key_result(report, show_fingerprint?) do
    detail =
      [report.summary, report.consequence, report.action]
      |> Enum.reject(&(&1 == ""))
      |> Enum.concat(fingerprint_lines(report, show_fingerprint?))
      |> Enum.concat(key_store_lines(report))
      |> Enum.join(".\n       ")

    {severity_status(report.severity), detail}
  end

  # An unintended plaintext store is a FAIL, not a warning: `--exit-code` exists
  # to stop a deploy, and credentials written in the clear without anyone
  # choosing that is what it should stop for. Encryption switched off on purpose
  # stays a warning — the operator already knows.
  defp severity_status(:ok), do: :pass
  defp severity_status(:warn), do: :warn
  defp severity_status(:fail), do: :fail

  # No key means no line at all, in EITHER flag state. The flag chooses between
  # two ways of describing a fingerprint that exists; it cannot conjure one.
  defp fingerprint_lines(%{fingerprint: :none}, _show), do: []

  defp fingerprint_lines(%{fingerprint: {:ok, _value, _tier}}, false),
    do: ["Fingerprint hidden — pass --fingerprint to show"]

  defp fingerprint_lines(%{fingerprint: {:ok, value, tier}}, true),
    do: ["Fingerprint #{value} (#{tier})"]

  # Absent when nothing is configured, rather than printed as "no key store
  # configured" underneath a message about a key that is stored nowhere.
  #
  # The state is printed with it. A bare path reads as "your key is saved here",
  # and for two of the three states it is not: the store may hold nothing yet,
  # or hold something nobody can read. That line sat under a `{:dedicated, :ok}`
  # verdict looking like confirmation of a backup that did not exist.
  defp key_store_lines(%{key_store: nil}), do: []
  defp key_store_lines(%{key_store: {:holding, location}}), do: ["Key store: #{location}"]

  defp key_store_lines(%{key_store: {:no_secret_yet, location}}),
    do: ["Key store: #{location} (configured, holds no secret yet)"]

  defp key_store_lines(%{key_store: {:unreadable, location}}),
    do: ["Key store: #{location} (configured, could not be read)"]

  defp key_store_lines(%{key_store: {:shadowed, location}}),
    do: [
      "Key store: #{location} (configured, holds a DIFFERENT secret — not a copy of the key in use)"
    ]

  # `.githooks/pre-commit` is a phoenix_kit-core-repo convention (see
  # AGENTS.md) — nothing installs or copies it into a consuming host app, so
  # the check is meaningless (and permanently unfixable) run from one. Scope
  # it to a checkout of phoenix_kit itself, the same way `oban_config` above
  # already distinguishes "the host's app" from `:phoenix_kit`.
  defp git_hooks_check do
    if Mix.Project.config()[:app] == :phoenix_kit do
      [run_check("Git Hooks", fn -> check_git_hooks() end)]
    else
      []
    end
  end

  defp check_git_hooks do
    git_hooks_verdict(gather_git_hooks_state())
  end

  defp gather_git_hooks_state do
    tracked? = File.exists?(".githooks/pre-commit")

    case git_cmd(["rev-parse", "--git-common-dir"]) do
      {:ok, common} ->
        hooks_path = hooks_path_config()

        %{
          repo: {:ok, common},
          hooks_path: hooks_path,
          pre_commit_executable: hooks_path_executable(hooks_path),
          tracked?: tracked?,
          shadow: shadow_hook(common)
        }

      :error ->
        %{
          repo: :unknown,
          hooks_path: :unknown,
          pre_commit_executable: :unknown,
          tracked?: tracked?,
          shadow: :unknown
        }
    end
  end

  defp hooks_path_executable({:ok, path}), do: pre_commit_executable?(path)
  defp hooks_path_executable(_not_ok), do: :unknown

  defp hooks_path_config do
    case System.cmd("git", ["config", "--get", "core.hooksPath"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      # Only meaningful because the caller already established we are inside a
      # repository — outside one, git answers 1 to this as well.
      {_, 1} -> :unset
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  # Worktrees share the common git dir, so the stale copy lives there, not in a
  # per-worktree ".git/hooks" — hardcoding that path reports a clean tree in
  # every worktree of a repo that still has one.
  defp shadow_hook(common_dir) do
    path = Path.join(common_dir, "hooks/pre-commit")
    if File.exists?(path), do: {:ok, path}, else: :none
  end

  defp git_cmd(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    # git absent from PATH raises ErlangError :enoent. That is a gap in our
    # knowledge, never evidence about the hook.
    _ -> :error
  end

  defp check_repo_detection do
    app = Mix.Project.config()[:app]
    repos = Application.get_env(app, :ecto_repos, [])

    if repos == [] do
      {:fail, "No :ecto_repos configured for :#{app}"}
    else
      repo = hd(repos)

      info =
        Enum.join(
          [
            "app: :#{app}",
            "repo: #{inspect(repo)}",
            "adapter: #{inspect(repo.__adapter__())}"
          ],
          ", "
        )

      {:pass, info}
    end
  end

  defp check_db_connectivity do
    repo = get_repo!()

    case repo.query("SELECT 1 AS ok", [], timeout: 5_000) do
      {:ok, %{rows: [[1]]}} ->
        {:pass, "Connected"}

      {:error, %{message: msg}} ->
        {:fail, "Query failed: #{msg}"}

      {:error, reason} ->
        {:fail, "Query failed: #{inspect(reason)}"}
    end
  end

  defp check_pool_config do
    app = Mix.Project.config()[:app]
    repo = get_repo!()
    config = Application.get_env(app, repo, [])

    pool_size = config[:pool_size] || 10
    queue_target = config[:queue_target] || 50
    queue_interval = config[:queue_interval] || 1000

    info =
      Enum.join(
        [
          "pool_size: #{pool_size}",
          "queue_target: #{queue_target}ms",
          "queue_interval: #{queue_interval}ms"
        ],
        ", "
      )

    cond do
      pool_size > 20 ->
        {:warn, "pool_size=#{pool_size} is high — may saturate PgBouncer. #{info}"}

      pool_size < 2 ->
        {:warn, "pool_size=#{pool_size} is very low. #{info}"}

      true ->
        {:pass, info}
    end
  end

  # Whether a transaction-pooling proxy sits between the app and Postgres.
  #
  # The hostname/port guess alone was wrong both ways: a pooler reached as
  # `postgres:5432` read as direct, and any URL without an explicit port read
  # as a pooler. The authoritative signal is behavioral (two statements on one
  # checkout landing on different backends), and the codebase already owns it.
  defp check_pgbouncer(oban_config) do
    repo = get_repo!()
    config = repo.config()

    port =
      cond do
        config[:port] -> config[:port]
        config[:url] -> extract_port_from_url(config[:url]) || 5432
        true -> 5432
      end

    hostname = config[:hostname] || extract_host_from_url(config[:url]) || "localhost"

    pgbouncer_verdict(
      Environment.classify_config(config),
      Environment.probe(repo),
      oban_notifier(oban_config),
      "port=#{port}, host=#{hostname}"
    )
  end

  defp oban_notifier(config) when is_list(config), do: Keyword.get(config, :notifier)
  defp oban_notifier(_), do: nil

  @doc false
  # Pure: what to report, given the config hint, the probe, and the Oban
  # notifier the host configured (nil = Oban's default, the Postgres one).
  def pgbouncer_verdict(config_verdict, probe, notifier, where) do
    case probe do
      :transaction_pooled ->
        {:warn,
         "Transaction pooling detected (#{where}): two statements on one connection " <>
           "reached different Postgres backends. DDL migrations need " <>
           "@disable_ddl_transaction true." <> notifier_hint(notifier)}

      # The probe can prove pooling, never rule it out: on an idle pool
      # PgBouncer hands the same server connection back (LIFO), so both
      # statements can land on one backend under transaction pooling too.
      # A config that looks pooled keeps the advice.
      :not_detected when config_verdict == :maybe_pooled ->
        {:warn,
         "Unconfirmed pooler hint: the config looks like a pooler (#{where}), but no transaction pooling was " <>
           "detected — a direct connection on a non-standard port, session pooling, or " <>
           "a transaction pooler that reused one backend for the probe (an idle " <>
           "PgBouncer does). If it is PgBouncer in transaction mode, DDL migrations need " <>
           "@disable_ddl_transaction true." <> notifier_hint(notifier)}

      :not_detected ->
        {:pass,
         "No transaction pooling detected (#{where}); an idle transaction pooler can " <>
           "reuse the same backend, so this does not prove a direct connection."}

      {:inconclusive, reason} ->
        {:warn,
         "Inconclusive probe: Could not tell whether a transaction pooler is in the way (#{where}): #{reason}. " <>
           "If you run PgBouncer in transaction mode, DDL migrations need " <>
           "@disable_ddl_transaction true." <> notifier_hint(notifier)}
    end
  end

  # Oban's default notifier relies on LISTEN/NOTIFY, which transaction pooling
  # breaks without an error: jobs still run (local staging keeps going), but
  # queue start/pause/scale signals and cross-node wake-ups are lost.
  defp notifier_hint(notifier) when notifier in [nil, Oban.Notifiers.Postgres] do
    " If transaction pooling is in use, Oban's configured Postgres notifier loses LISTEN/NOTIFY behind a " <>
      "transaction pooler — silently: jobs still run, but queue pause/scale/start " <>
      "signals are dropped. Use `notifier: Oban.Notifiers.PG` if your nodes are " <>
      "Erlang-clustered, or give Oban a Repo that connects past the pooler."
  end

  defp notifier_hint(_other), do: ""

  defp check_migration_state(prefix) do
    repo = get_repo!()
    escaped_prefix = String.replace(prefix, "'", "\\'")

    # Source 1: COMMENT ON TABLE (set by each V*.up migration)
    comment_version = get_comment_version(repo, escaped_prefix)

    # Source 2: migrated_version_runtime (what phoenix_kit.status uses)
    runtime_version =
      try do
        opts = %{prefix: prefix, escaped_prefix: escaped_prefix}
        Postgres.migrated_version_runtime(opts)
      rescue
        _ -> :error
      end

    # Source 3: Code's latest version
    latest_version = Postgres.current_version()

    lines = [
      "COMMENT ON TABLE: V#{comment_version}",
      "migrated_version_runtime: #{if runtime_version == :error, do: "ERROR", else: "V#{runtime_version}"}",
      "Code latest: V#{latest_version}"
    ]

    info = Enum.join(lines, "\n       ")

    # Detect discrepancies
    discrepancy =
      runtime_version != :error and runtime_version != comment_version

    cond do
      discrepancy ->
        {:warn,
         "DISCREPANCY between version sources!\n       #{info}\n       " <>
           "The COMMENT was updated by a migration that didn't commit to schema_migrations " <>
           "(killed process or missing @disable_ddl_transaction true)."}

      comment_version == 0 ->
        {:warn, "PhoenixKit not installed.\n       #{info}"}

      comment_version < latest_version ->
        {:warn, "Needs migration.\n       #{info}"}

      comment_version == latest_version ->
        {:pass, info}

      true ->
        {:warn, "DB version > code version.\n       #{info}"}
    end
  end

  # Columns a given migration version adds. If the version marker claims that
  # version (or higher) but the column is missing at the prefix, the install
  # drifted — the marker is ahead of the actual schema (e.g. a version renumber
  # that crossed an upgrade, or an earlier prefix-confused migration run). A
  # query that selects the column then crashes at runtime, and re-running the
  # migrator is a no-op because the marker already covers that version.
  @expected_columns [
    {150, "phoenix_kit_users_tokens", "browser"},
    {150, "phoenix_kit_users_tokens", "os"}
  ]

  # Core's marker says nothing about a module that owns its own chain, so every
  # check above can pass while a module's tables sit versions behind the code
  # querying them. That gap presents as an undefined-column 500 on the module's
  # admin page — no migration error, and `doctor` previously gave the install a
  # clean bill of health, which is the worst possible moment to be reassuring.
  defp check_module_schema_versions(prefix) do
    module_schema_versions_result(MigrationModules.list(prefix: prefix))
  end

  # Exposed (not `defp`) and `@doc false`, same reason as the other pure
  # decision functions in this module: it takes an already-fetched module
  # list, so a test can pin every classification this check makes without a
  # database.
  @doc false
  def module_schema_versions_result(modules) do
    failed = MigrationModules.failed(modules)
    pending = MigrationModules.pending(modules)
    ahead = MigrationModules.ahead_of_code(modules)

    cond do
      modules == [] ->
        {:pass, "No installed module owns migrations."}

      pending != [] ->
        {:fail,
         "Behind: #{describe_module_versions(pending)}#{unreadable_suffix(failed)}#{ahead_suffix(ahead)}. " <>
           "Run mix phoenix_kit.update --yes (mix ecto.migrate alone does not write these)."}

      failed != [] ->
        {:warn,
         "Version unreadable for #{Enum.map_join(failed, ", ", & &1.name)} — " <>
           "their tables may be behind and nothing can tell. See mix phoenix_kit.status --verbose."}

      # Not pending — `mix phoenix_kit.update` has nothing to run — but a
      # database newer than the code now running is a rollback or a
      # backwards-pinned dependency, not a clean bill of health.
      ahead != [] ->
        {:warn,
         "Ahead of code: #{describe_module_versions(ahead)}. " <>
           "Database schema is newer than the running code — rollback or a backwards-pinned dependency?"}

      true ->
        {:pass, "#{length(modules)} module(s), all at the version their code expects."}
    end
  end

  defp describe_module_versions(entries) do
    Enum.map_join(entries, ", ", fn entry ->
      "#{entry.name} V#{entry.installed} (code expects V#{entry.target})"
    end)
  end

  # Behind and unreadable are not alternatives — one run can hold both, and the
  # `cond` above reaches the `failed` branch only when nothing is pending. Left
  # to it, an install with one module behind and another whose coordinator
  # raised reported only the first, and the unreadable module vanished from the
  # report entirely. It is the one an operator cannot discover any other way,
  # which is why `StatusReport.next_action/3` and the status tree both surface
  # it first; the severity stays `:fail` because a behind module is actionable.
  defp unreadable_suffix([]), do: ""

  defp unreadable_suffix(failed),
    do: "; version unreadable for #{Enum.map_join(failed, ", ", & &1.name)}"

  # Same reasoning as `unreadable_suffix/1`: a pending module and an
  # ahead-of-code module are not alternatives, and `:fail` must not swallow
  # the ahead one silently just because it isn't what made this run fail.
  defp ahead_suffix([]), do: ""

  defp ahead_suffix(ahead),
    do: "; ahead of code: #{describe_module_versions(ahead)}"

  defp check_schema_drift(prefix) do
    repo = get_repo!()
    escaped_prefix = String.replace(prefix, "'", "\\'")
    marker = get_comment_version(repo, escaped_prefix)

    if marker == 0 do
      {:pass, "PhoenixKit not installed at prefix #{inspect(prefix)} — nothing to check."}
    else
      missing =
        @expected_columns
        |> Enum.filter(fn {min_version, _t, _c} -> marker >= min_version end)
        |> Enum.reject(fn {_v, table, column} ->
          column_exists?(repo, escaped_prefix, table, column)
        end)

      report_schema_drift(missing, marker, prefix)
    end
  end

  defp report_schema_drift([], marker, _prefix),
    do: {:pass, "Columns expected at V#{marker} are present."}

  defp report_schema_drift(missing, marker, prefix) do
    names = Enum.map_join(missing, ", ", fn {v, t, c} -> "#{t}.#{c} (V#{v})" end)
    lowest = missing |> Enum.map(fn {v, _t, _c} -> v end) |> Enum.min()
    p = if prefix == "public", do: "public.", else: "#{prefix}."

    {:fail,
     "Marker says V#{marker} but these columns are missing: #{names}. The install drifted " <>
       "(marker ahead of schema). Roll the marker back one version and re-run the migrator — " <>
       "the column adds are idempotent (add_if_not_exists), so this is safe:\n" <>
       "       COMMENT ON TABLE #{p}phoenix_kit IS '#{lowest - 1}';\n" <>
       "       mix phoenix_kit.update#{prefix_flag(prefix)}"}
  end

  defp column_exists?(repo, escaped_prefix, table, column) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_schema = '#{escaped_prefix}'
      AND table_name = '#{table}'
      AND column_name = '#{column}'
    )
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_flag("public"), do: ""
  defp prefix_flag(prefix), do: " --prefix=#{prefix}"

  defp check_pending_migrations do
    repo = get_repo!()
    migrations_path = Path.join(["priv", "repo", "migrations"])

    migration_files =
      if File.dir?(migrations_path) do
        migrations_path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.map(fn f ->
          case Integer.parse(f) do
            {version, _rest} -> {version, f}
            :error -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()
      else
        []
      end

    recorded =
      case repo.query("SELECT version FROM schema_migrations ORDER BY version", []) do
        {:ok, %{rows: rows}} -> Enum.map(rows, fn [v] -> v end) |> MapSet.new()
        _ -> MapSet.new()
      end

    pending =
      Enum.reject(migration_files, fn {version, _name} -> MapSet.member?(recorded, version) end)

    phoenix_kit_pending =
      Enum.filter(pending, fn {_v, name} -> String.contains?(name, "phoenix_kit") end)

    # Also check for duplicate PhoenixKit migration files (same version range)
    pk_files =
      Enum.filter(migration_files, fn {_v, name} -> String.contains?(name, "phoenix_kit") end)

    duplicates = find_duplicate_migration_ranges(pk_files)

    detail_parts = []

    detail_parts =
      if pending != [] do
        pk_names = Enum.map_join(phoenix_kit_pending, "\n       ", fn {_v, n} -> n end)

        detail_parts ++
          [
            "#{length(pending)} pending (#{length(phoenix_kit_pending)} PhoenixKit):\n       #{pk_names}"
          ]
      else
        detail_parts ++ ["All #{length(migration_files)} files recorded in schema_migrations"]
      end

    detail_parts =
      if duplicates != "" do
        detail_parts ++ ["DUPLICATE ranges detected:\n       #{duplicates}"]
      else
        detail_parts
      end

    detail = Enum.join(detail_parts, "\n       ")

    cond do
      duplicates != "" ->
        {:warn, detail}

      pending == [] ->
        {:pass, detail}

      true ->
        {:warn, detail}
    end
  end

  defp find_duplicate_migration_ranges(pk_files) do
    # Extract version ranges from filenames like "phoenix_kit_update_v49_to_v71.exs"
    ranges =
      Enum.map(pk_files, fn {_v, name} ->
        case Regex.run(~r/phoenix_kit_\w+_v(\d+)_to_v(\d+)/, name) do
          [_, from, to] -> {String.to_integer(from), String.to_integer(to), name}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Find overlapping ranges
    overlaps =
      for {from1, to1, name1} <- ranges,
          {from2, to2, name2} <- ranges,
          name1 < name2,
          max(from1, from2) < min(to1, to2),
          do: "#{name1} overlaps #{name2}"

    Enum.join(overlaps, "\n       ")
  end

  # A missing primary key is what the varchar column actually COST, and the type
  # check could not see it: a table can have a perfectly typed uuid column and
  # still have no key. Reported by a host whose phoenix_kit_email_events had
  # both problems and whose doctor run named only the first.
  defp check_uuid_primary_keys(prefix) do
    repo = get_repo!()

    query = """
    SELECT t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema = $1
      AND t.table_name LIKE 'phoenix\\_kit\\_%'
      AND t.table_type = 'BASE TABLE'
      AND EXISTS (
        SELECT 1 FROM information_schema.columns c
        WHERE c.table_name = t.table_name
          AND c.table_schema = t.table_schema
          AND c.column_name = 'uuid'
      )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_constraint pc
        JOIN pg_class pcl ON pcl.oid = pc.conrelid
        JOIN pg_namespace pn ON pn.oid = pcl.relnamespace
        WHERE pcl.relname = t.table_name
          AND pn.nspname = t.table_schema
          AND pc.contype = 'p'
      )
    ORDER BY t.table_name
    """

    case repo.query(query, [prefix], log: false) do
      {:ok, %{rows: []}} ->
        {:pass, "Every phoenix_kit table with a uuid column has a primary key"}

      {:ok, %{rows: rows}} ->
        tables = Enum.map_join(rows, "\n       ", fn [t] -> t end)

        {:fail,
         "#{length(rows)} table(s) have a uuid column but NO primary key:\n       #{tables}\n       " <>
           "Fix: mix phoenix_kit.repair_uuid  (or upgrade — V163 repairs this automatically)"}

      _ ->
        {:warn, "Could not check (phoenix_kit tables may not exist yet)"}
    end
  end

  # Pre-migration: check for varchar/text uuid columns that should be native uuid type.
  # A varchar uuid column on phoenix_kit_settings crashes the Ecto schema loader on startup,
  # blocking migrations from even running.
  defp check_uuid_column_types(prefix) do
    repo = get_repo!()
    escaped_prefix = String.replace(prefix, "'", "\\'")

    query = """
    SELECT table_name, data_type
    FROM information_schema.columns
    WHERE table_name LIKE 'phoenix_kit_%'
      AND column_name = 'uuid'
      AND table_schema = '#{escaped_prefix}'
      AND data_type IN ('character varying', 'text', 'character')
    ORDER BY table_name
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: []}} ->
        {:pass, "All uuid columns are native uuid type"}

      {:ok, %{rows: rows}} ->
        tables =
          Enum.map_join(rows, "\n       ", fn [table, dtype] ->
            "#{table} (#{dtype})"
          end)

        # The remedy is a task, not a single ALTER. The ALTER alone restores the
        # TYPE and leaves the column nullable, without a UUIDv7 default and
        # without a primary key — anyone following it literally ends up in a
        # state that still fails this doctor. Reported by a host who did.
        {:fail,
         "#{length(rows)} table(s) have a varchar uuid column:\n       #{tables}\n       " <>
           "These break any Ecto schema that maps to them, and cannot carry a uuid primary key.\n       " <>
           "Fix: mix phoenix_kit.repair_uuid  (or upgrade — V163 repairs this automatically)"}

      _ ->
        {:warn, "Could not check (phoenix_kit tables may not exist yet)"}
    end
  end

  # Pre-migration: check for NULL uuid values in tables that are FK sources.
  # NULL source UUIDs cause the V56 batched backfill loop to run forever.
  defp check_null_uuids(prefix) do
    repo = get_repo!()
    escaped_prefix = String.replace(prefix, "'", "\\'")

    # Key FK source tables whose uuid column must not be NULL.
    #
    # `phoenix_kit_cat_items`/`phoenix_kit_cat_categories` (catalogue module)
    # are deliberately absent: their uuid column has carried `DEFAULT
    # uuid_generate_v7() NOT NULL` since their V135 baseline creation, so
    # they never went through the V56 backfill this check exists to catch
    # and cannot hold a NULL uuid.
    source_tables = [
      "phoenix_kit_users",
      "phoenix_kit_user_roles",
      "phoenix_kit_entities",
      "phoenix_kit_email_logs",
      "phoenix_kit_shop_carts",
      "phoenix_kit_shop_products",
      "phoenix_kit_shop_categories",
      "phoenix_kit_shop_shipping_methods",
      "phoenix_kit_payment_options",
      "phoenix_kit_billing_profiles",
      "phoenix_kit_orders",
      "phoenix_kit_invoices",
      "phoenix_kit_payment_methods",
      "phoenix_kit_subscriptions",
      "phoenix_kit_subscription_types",
      "phoenix_kit_subscription_plans",
      "phoenix_kit_referral_codes",
      "phoenix_kit_ai_endpoints",
      "phoenix_kit_ai_prompts",
      "phoenix_kit_sync_connections"
    ]

    problems =
      Enum.reduce(source_tables, [], fn table, acc ->
        exists_query = """
        SELECT EXISTS (
          SELECT FROM information_schema.columns
          WHERE table_name = '#{table}'
            AND column_name = 'uuid'
            AND table_schema = '#{escaped_prefix}'
        )
        """

        case repo.query(exists_query, [], log: false) do
          {:ok, %{rows: [[true]]}} ->
            table_name = prefix_table_name(table, prefix)

            count_query = "SELECT count(*)::integer FROM #{table_name} WHERE uuid IS NULL"

            case repo.query(count_query, [], log: false) do
              {:ok, %{rows: [[count]]}} when count > 0 ->
                [{table, count} | acc]

              _ ->
                acc
            end

          _ ->
            acc
        end
      end)

    if problems == [] do
      {:pass, "No NULL uuids in FK source tables"}
    else
      detail =
        Enum.map_join(Enum.reverse(problems), "\n       ", fn {table, count} ->
          "#{table}: #{count} rows with NULL uuid"
        end)

      {:fail,
       "NULL uuids found (will cause infinite loop in V56 backfill):\n       #{detail}\n       " <>
         "Fix: UPDATE <table> SET uuid = gen_random_uuid() WHERE uuid IS NULL"}
    end
  end

  # This used to check 4 hardcoded (table, fk_col, ref_table, ref_col)
  # pairs out of 70 canonical relationships (231 total FK constraints on a
  # calibration install) and printed PASS — which reads as "everything is
  # fine" but meant only "the four pairs we happened to list are fine".
  # Two real orphans on a live site sat outside the four and were
  # invisible to this check the whole time.
  #
  # Fixed by discovering every FK constraint straight from `pg_constraint`
  # instead of a list in code: self-maintaining (a constraint added by a
  # future migration is covered without touching this file) and exhaustive
  # by construction rather than by upkeep. Coverage is now part of the
  # result text itself, and zero coverage — empty schema, wrong --prefix,
  # a catalog query that itself failed — can never read as PASS, no matter
  # which of those reasons caused it ("clean" and "never looked" used to
  # print byte-identical text).
  #
  # Exposed (not `defp`) and `@doc false`, same reason as the other pure
  # decision functions in this module: `get_repo!/0` resolves the same
  # `PhoenixKit.Test.Repo` under `mix test` that it resolves under a real
  # `mix phoenix_kit.doctor` run, so this is a real end-to-end seam for the
  # whole discover -> probe -> classify -> report pipeline against a live
  # connection, not just its pieces in isolation.
  @doc false
  def check_orphaned_fk_refs(prefix) do
    repo = get_repo!()
    escaped_prefix = String.replace(prefix, "'", "\\'")

    case discover_fk_constraints(repo, escaped_prefix) do
      {:error, reason} ->
        {:warn,
         "could not enumerate foreign key constraints in schema #{inspect(prefix)} " <>
           "(#{inspect(reason)}) — coverage is zero, which is not the same as clean. " <>
           "Fix catalog access (pg_constraint/pg_class) and re-run."}

      {:ok, {[], []}} ->
        {:warn,
         "no foreign key constraints found in schema #{inspect(prefix)} — coverage is " <>
           "zero: either nothing is installed here, or --prefix names the wrong schema. " <>
           "This is not the same as clean."}

      {:ok, {constraints, []}} ->
        {orphaned, not_validated, probe_failed} =
          Enum.reduce(constraints, {[], [], []}, fn fk, acc -> probe_fk(repo, fk, prefix, acc) end)

        report_orphaned_fk_refs(
          Enum.reverse(orphaned),
          Enum.reverse(not_validated),
          Enum.reverse(probe_failed),
          length(constraints)
        )
    end
  end

  # Discover every FK, preserving conkey/confkey order for composite pairs.
  # Both tables must be in the checked schema; cross-schema FKs remain outside
  # this check's documented scope.
  @doc false
  def discover_fk_constraints(repo, escaped_prefix) do
    query = """
    SELECT
      t.relname AS table_name,
      ft.relname AS ref_table,
      c.conname,
      c.convalidated,
      c.confmatchtype,
      ARRAY(SELECT a.attname FROM unnest(c.conkey) WITH ORDINALITY AS k(num, ord)
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.num
            ORDER BY k.ord) AS fk_cols,
      ARRAY(SELECT a.attname FROM unnest(c.confkey) WITH ORDINALITY AS k(num, ord)
            JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.num
            ORDER BY k.ord) AS ref_cols
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    JOIN pg_class ft ON ft.oid = c.confrelid
    JOIN pg_namespace fn ON fn.oid = ft.relnamespace
    WHERE c.contype = 'f'
      AND n.nspname = '#{escaped_prefix}'
      AND fn.nspname = '#{escaped_prefix}'
    ORDER BY t.relname, c.conname
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: rows}} ->
        constraints =
          Enum.map(rows, fn [table, ref_table, conname, valid?, match_type, fk_cols, ref_cols] ->
            %{
              table: table,
              fk_col: Enum.join(fk_cols, ", "),
              fk_cols: fk_cols,
              ref_table: ref_table,
              ref_col: Enum.join(ref_cols, ", "),
              ref_cols: ref_cols,
              match_type: match_type,
              conname: conname,
              convalidated: valid?
            }
          end)

        {:ok, {constraints, []}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Per-constraint time budget: a check that never finishes must never read
  # as clean, but it also must not be allowed to hang the whole doctor run
  # waiting on one giant table. A server-side cancellation on expiry surfaces
  # as `{:error, %Postgrex.Error{postgres: %{code: :query_canceled}}}` — but
  # verified live against `PhoenixKit.Test.Repo.query/3` (the exact call
  # `probe_fk/4` makes, through the DBConnection pool/ownership layer, not a
  # raw `Postgrex.query/3` against a bare connection), the timeout more often
  # surfaces ONE layer up instead: DBConnection itself drops the request from
  # its queue and closes the checked-out connection, returning
  # `{:error, %DBConnection.ConnectionError{reason: :closed}}` with no
  # `Postgrex.Error` involved at all. Both shapes are handled the same way —
  # a timeout is just one more reason a probe can fail, never a silent scope
  # reduction. A `--full` flag is deliberately not offered, for this exact
  # reason: breadth (every constraint) is never negotiable, only depth (how
  # long we wait per constraint) is.
  @fk_probe_timeout_ms 5_000

  defp probe_fk(repo, fk, prefix, {orph, nv, pf}) do
    %{table: table, fk_col: fk_col, ref_table: ref_table, convalidated: valid?} = fk
    orphan_query = fk_orphan_query(fk, prefix)

    count_result =
      case repo.query(orphan_query, [], log: false, timeout: @fk_probe_timeout_ms) do
        {:ok, %{rows: [[c]]}} ->
          {:ok, c}

        {:error, %Postgrex.Error{postgres: %{code: :query_canceled}} = reason} ->
          {:probe_failed, timeout_probe_failure(reason, repo, table, hd(fk.fk_cols), prefix)}

        {:error, %DBConnection.ConnectionError{reason: :closed} = reason} ->
          {:probe_failed, timeout_probe_failure(reason, repo, table, hd(fk.fk_cols), prefix)}

        {:error, reason} ->
          {:probe_failed, fk_probe_failure_reason(reason)}

        other ->
          {:probe_failed, other}
      end

    validation = if valid?, do: :validated, else: {:not_valid, fk.conname}

    classify_fk_check(table, fk_col, ref_table, count_result, validation, {orph, nv, pf})
  end

  defp fk_orphan_query(fk, prefix) do
    # MATCH SIMPLE exempts a row with ANY null key; MATCH FULL exempts only
    # an ALL-null key. A partially-null FULL key is a violation too.
    null_join = if fk.match_type == "f", do: " OR ", else: " AND "

    non_null = Enum.map_join(fk.fk_cols, null_join, &"t.#{quote_fk_identifier(&1)} IS NOT NULL")

    matching =
      Enum.zip(fk.fk_cols, fk.ref_cols)
      |> Enum.map_join(" AND ", fn {col, ref} ->
        "r.#{quote_fk_identifier(ref)} = t.#{quote_fk_identifier(col)}"
      end)

    table = "#{quote_fk_identifier(prefix)}.#{quote_fk_identifier(fk.table)}"
    ref = "#{quote_fk_identifier(prefix)}.#{quote_fk_identifier(fk.ref_table)}"

    "SELECT count(*)::integer FROM #{table} t WHERE (#{non_null}) " <>
      "AND NOT EXISTS (SELECT 1 FROM #{ref} r WHERE #{matching})"
  end

  defp quote_fk_identifier(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""

  defp timeout_probe_failure(reason, repo, table, fk_col, prefix) do
    fk_probe_failure_reason(reason) <> fk_probe_cost_context(repo, table, fk_col, prefix)
  end

  # A query cancelled by the timeout above, a connection closed out from
  # under it by the pool, and every other Postgrex/DBConnection error all
  # reach this function — it only exists to make the two timeout shapes say
  # "time limit exceeded" instead of a raw Postgres cancellation code or a
  # "tcp recv: closed" pool message, so the doctor's report uses
  # operator-facing language ("not checked, not clean") rather than
  # leaking a database/pool error that means the same thing.
  #
  # Exposed (not `defp`) and `@doc false`, same reason as the other pure
  # decision functions in this module: directly testable without a repo.
  @doc false
  def fk_probe_failure_reason(%Postgrex.Error{postgres: %{code: :query_canceled}}) do
    "time limit exceeded (#{@fk_probe_timeout_ms}ms) — not checked, not clean"
  end

  def fk_probe_failure_reason(%DBConnection.ConnectionError{reason: :closed}) do
    "time limit exceeded (#{@fk_probe_timeout_ms}ms) — not checked, not clean"
  end

  def fk_probe_failure_reason(reason), do: reason

  # Cost of an expensive check must be measured and
  # printed, not guessed at ("table likely large") or silently dropped.
  # `n_live_tup` is planner statistics (a `pg_stat_user_tables` read), not a
  # table scan, so this stays cheap even on the table whose real scan just
  # timed out. Index presence is checked as "leads some index"
  # (`indkey[0]` — `int2vector` subscripts are 0-based, unlike the
  # `conkey`/`confkey` smallint[] arrays used in `discover_fk_constraints/2`)
  # — a composite index where the FK column isn't first doesn't help this
  # query's plan, so it doesn't count as indexed here either.
  #
  # Exposed (not `defp`) and `@doc false`, same reason as
  # `discover_fk_constraints/2` and `fk_validation_state/5`: takes `repo`
  # explicitly, so it's a real unit-test seam against a live connection
  # without starting the whole app.
  @doc false
  def fk_probe_cost_context(repo, table, fk_col, prefix) do
    query = """
    SELECT
      (SELECT n_live_tup FROM pg_stat_user_tables
       WHERE schemaname = $1 AND relname = $2) AS row_estimate,
      EXISTS (
        SELECT 1 FROM pg_index i
        JOIN pg_class t ON t.oid = i.indrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = i.indkey[0]
        WHERE n.nspname = $1 AND t.relname = $2 AND a.attname = $3
      ) AS fk_col_indexed
    """

    case repo.query(query, [prefix, table, fk_col], log: false) do
      {:ok, %{rows: [[row_estimate, indexed?]]}} ->
        rows_text = if row_estimate, do: "~#{row_estimate} rows", else: "row count unknown"
        idx_text = if indexed?, do: "indexed", else: "NOT indexed"
        " (#{table}.#{fk_col}: #{rows_text}, #{idx_text})"

      {:error, _reason} ->
        ""
    end
  end

  # Either probe failing must never read as "clean" — a failed probe is a
  # missing answer, not a passing one. Checked before either success shape,
  # so a probe failure on ANY of orphan-count or validation-state routes
  # straight to `probe_failed`, never falls through to the branches below
  # that assume both reads succeeded.
  #
  # Exposed (not `defp`) and `@doc false`, same reason as `V176.validate_one/7`:
  # a pure decision function, directly testable without touching a real repo.
  @doc false
  def classify_fk_check(table, fk_col, ref, {:probe_failed, reason}, _validation, {orph, nv, pf}) do
    {orph, nv, [{table, fk_col, ref, :orphan_count, reason, nil} | pf]}
  end

  # The orphan-count probe already succeeded by the time this clause can
  # match (a failed one is caught by the clause above regardless of
  # `validation`) — `count` is a real measurement, not a placeholder, and is
  # carried into the probe_failed tuple so report_orphaned_fk_refs/3 can
  # print it instead of losing it behind "could not check".
  def classify_fk_check(
        table,
        fk_col,
        ref,
        {:ok, count},
        {:probe_failed, reason},
        {orph, nv, pf}
      ) do
    {orph, nv, [{table, fk_col, ref, :validation_state, reason, count} | pf]}
  end

  # Existing NOT VALID constraint blocking VALIDATE, not creation.
  def classify_fk_check(table, fk_col, ref, {:ok, count}, {:not_valid, _conname}, {orph, nv, pf})
      when count > 0 do
    {[{table, fk_col, ref, count, :validate} | orph], nv, pf}
  end

  # No constraint at all — the original "blocks creation" case.
  def classify_fk_check(table, fk_col, ref, {:ok, count}, :absent, {orph, nv, pf})
      when count > 0 do
    {[{table, fk_col, ref, count, :create} | orph], nv, pf}
  end

  # A VALID, enforced constraint — Postgres itself should make this state
  # unreachable through ordinary SQL, but "should" is not "does": a bulk load
  # with triggers off, a restore from an inconsistent backup, or direct
  # catalog surgery can all leave orphaned rows behind a constraint that
  # still reads as fully validated. Before this clause, `count > 0` here fell
  # through to the generic catch-all below and was silently discarded — the
  # single most common `validation` shape (most real FKs are validated, not
  # `NOT VALID`) was exactly the one this function couldn't report on.
  def classify_fk_check(table, fk_col, ref, {:ok, count}, :validated, {orph, nv, pf})
      when count > 0 do
    {[{table, fk_col, ref, count, :existing_orphan} | orph], nv, pf}
  end

  # Constraint present, NOT VALID, but nothing currently blocking it — a
  # nudge, not a failure: V176 validates this on its own.
  def classify_fk_check(table, fk_col, ref, {:ok, _count}, {:not_valid, _conname}, {orph, nv, pf}) do
    {orph, [{table, fk_col, ref} | nv], pf}
  end

  # Narrowed to `{:ok, 0}` deliberately: this is the ONLY combination that
  # means "clean". Widening it back to `{:ok, _count}` is exactly the bug
  # already fixed for `:validated` — a future `validation` shape reaching
  # here with `count > 0` must raise `FunctionClauseError`, not silently
  # discard real orphans the way the old wildcard catch-all did.
  def classify_fk_check(_table, _fk_col, _ref, {:ok, 0}, _validated_or_absent_and_clean, acc) do
    acc
  end

  # A third urgency tier, alongside `:warn` and `:fail`. Before this fix, a
  # probe failure with zero actual orphans still returned :fail — the same
  # red as real broken data, even though nothing is actually broken. Real
  # orphans (last clause below) still win :fail outright, checked or not; a
  # probe failure on its own is "investigate coverage", not "fix broken
  # data", and gets its own color for it.
  @doc false
  def report_orphaned_fk_refs([], [], [], total) do
    {:pass,
     "No orphaned FK references found (checked #{total} of #{total} foreign key constraints)"}
  end

  def report_orphaned_fk_refs([], not_validated, [], total) do
    detail =
      Enum.map_join(not_validated, "\n       ", fn {table, fk_col, ref} ->
        "#{table}.#{fk_col} → #{ref}"
      end)

    {:warn,
     "Foreign key(s) exist but were never validated (no orphaned rows blocking it right " <>
       "now), checked #{total} of #{total}:\n       #{detail}\n       V176 validates these " <>
       "automatically on the next migration run; or ALTER TABLE <table> VALIDATE CONSTRAINT " <>
       "<name> by hand."}
  end

  def report_orphaned_fk_refs([], not_validated, probe_failed, total) when probe_failed != [] do
    covered = total - length(probe_failed)

    nv_note =
      case not_validated do
        [] ->
          ""

        list ->
          "\n       Also unvalidated with nothing currently blocking it: " <>
            Enum.map_join(list, ", ", fn {t, c, r} -> "#{t}.#{c} → #{r}" end)
      end

    {:warn,
     "Could not check #{length(probe_failed)} of #{total} foreign key constraints — " <>
       "coverage is incomplete, which is not the same as clean:\n       " <>
       Enum.join(fk_probe_lines(probe_failed), "\n       ") <>
       nv_note <>
       "\n       No orphaned rows among the #{covered} successfully checked." <>
       retry_suggestion(
         probe_failed,
         " Fix DB connectivity/permissions (or the time limit, " <>
           "for a slow table) and re-run for full coverage."
       )}
  end

  # Falls through here whenever `orphaned != []` — real broken data, so this
  # is :fail regardless of what else is going on. A probe failure elsewhere
  # in the same run is still worth surfacing (it means coverage is
  # incomplete on TOP of the confirmed damage), so its detail is still
  # appended rather than swallowed by the more urgent finding.
  def report_orphaned_fk_refs(orphaned, not_validated, probe_failed, total) do
    detail = Enum.join(fk_orphan_lines(orphaned) ++ fk_probe_lines(probe_failed), "\n       ")

    coverage_note =
      if probe_failed == [] do
        " (checked #{total} of #{total})"
      else
        " (checked #{total - length(probe_failed)} of #{total} — #{length(probe_failed)} more not checked)"
      end

    nv_note =
      case not_validated do
        [] ->
          ""

        list ->
          "\n       Also unvalidated with nothing currently blocking it: " <>
            Enum.map_join(list, ", ", fn {t, c, r} -> "#{t}.#{c} → #{r}" end)
      end

    {:fail,
     "Orphaned FK refs / unverifiable FK state found#{coverage_note}:\n       " <>
       "#{detail}#{nv_note}\n       V164/V176 never delete rows to force a constraint " <>
       "through — clean orphaned rows up by hand and re-run the migration chain." <>
       retry_suggestion(
         probe_failed,
         " For a probe failure, fix DB connectivity or " <>
           "permissions on pg_constraint and re-run doctor."
       )}
  end

  defp retry_suggestion([], _text), do: ""
  defp retry_suggestion(_probe_failed, text), do: text

  defp fk_orphan_lines(orphaned) do
    Enum.map(orphaned, fn
      {table, fk_col, ref, count, :validate} ->
        "#{table}.#{fk_col} → #{ref}: #{count} orphaned row(s) — constraint already exists " <>
          "NOT VALID, this blocks VALIDATE"

      {table, fk_col, ref, count, :create} ->
        "#{table}.#{fk_col} → #{ref}: #{count} orphaned row(s) — no constraint yet, this " <>
          "blocks its creation"

      {table, fk_col, ref, count, :existing_orphan} ->
        "#{table}.#{fk_col} → #{ref}: #{count} orphaned row(s) — constraint IS validated but " <>
          "orphans exist anyway (likely written via a trigger-bypass path: bulk load, " <>
          "replica catch-up, direct catalog edit) — investigate how, then clean up by hand"
    end)
  end

  defp fk_probe_lines(probe_failed) do
    Enum.map(probe_failed, fn
      {table, fk_col, ref, :validation_state, reason, count} ->
        "#{table}.#{fk_col} → #{ref}: #{count} orphaned row(s) measured, but could not check " <>
          "whether the constraint is validated (validation_state probe failed: " <>
          "#{inspect(reason)}) — a failed probe is not a pass, treat as unverified"

      {table, fk_col, ref, kind, reason, nil} ->
        "#{table}.#{fk_col} → #{ref}: could not check (#{kind} probe failed: #{inspect(reason)}) " <>
          "— a failed probe is not a pass, treat as unverified"
    end)
  end

  # `convalidated` for the constraint enforcing this exact (column ->
  # ref_table.uuid) shape, matched by shape via conkey/confkey — not by
  # name, so a constraint adopted under a differently-named twin (V164's own
  # documented case) is still found. Returns `:absent` if no such FK exists
  # at all — a state discover_fk_constraints/2 has no way to report, since
  # bulk discovery only ever enumerates constraints that exist. Carries the
  # identical same-schema restriction as discover_fk_constraints/2 (see its
  # comment): `ref_table` is assumed to live in `escaped_prefix` too.
  #
  # Not called from the doctor's own run: probe_fk/4 reads `convalidated`
  # straight off each constraint discover_fk_constraints/2 already found, one
  # round trip cheaper per check than looking each one up again by shape.
  # Kept anyway, deliberately: it is the one existing primitive that can
  # answer "does this specific expected relationship have a declared FK at
  # all", independent of naming — exactly what closing check 12's current
  # gap (a relationship with no FK constraint declared at all goes
  # unexamined, see its moduledoc entry) would need, given a source of
  # expected (table, fk_col, ref_table) candidates. No such source exists
  # yet, so this stays unwired until one does.
  #
  # Exposed (not `defp`) and `@doc false` so the test suite can force a real
  # probe failure (a malformed identifier producing a genuine Postgres
  # syntax error) and assert it does NOT collapse into `:absent` — that
  # collapse is exactly what let `mix phoenix_kit.doctor` print PASS for a
  # check it never actually ran.
  @doc false
  def fk_validation_state(repo, table, fk_col, ref_table, escaped_prefix) do
    query = """
    SELECT c.conname, c.convalidated
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    JOIN pg_class ft ON ft.oid = c.confrelid
    JOIN pg_namespace fn ON fn.oid = ft.relnamespace
    WHERE c.contype = 'f'
      AND n.nspname = '#{escaped_prefix}'
      AND t.relname = '#{table}'
      AND ft.relname = '#{ref_table}'
      AND fn.nspname = '#{escaped_prefix}'
      AND array_length(c.conkey, 1) = 1
      AND (SELECT a.attname FROM pg_attribute a
           WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[1]) = '#{fk_col}'
    LIMIT 1
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[_conname, true]]}} -> :validated
      {:ok, %{rows: [[conname, false]]}} -> {:not_valid, conname}
      {:ok, %{rows: []}} -> :absent
      # A query error (timeout, missing pg_constraint privilege, connection
      # drop) is NOT the same fact as "no such constraint" — collapsing both
      # into :absent is how a diagnostic ends up printing PASS for a state it
      # never actually looked at. Distinguished so the caller can fail (or at
      # least warn) instead of silently reading this as clean.
      {:error, reason} -> {:probe_failed, reason}
      other -> {:probe_failed, other}
    end
  end

  # Check 12 above only ever examines a relationship that already HAS a
  # declared FK constraint — its own moduledoc entry names this boundary
  # ("a relationship with no FK constraint declared at all is outside this
  # check's scope"). `belongs_to` is a source of exactly the (table,
  # owner_key, ref_table) triple a check like that would need — every one
  # PhoenixKit's own Ecto schemas declare names its target unambiguously
  # via `owner_key`/`related`, without guessing from a column name. This
  # check resolves that triple itself and cross-references it against
  # `pg_constraint` directly (a bulk, two-query scan — see
  # `discover_schema_declared_relations_without_fk/2` — not a per-candidate
  # call to `fk_validation_state/5`, which answers a related but different
  # question, a constraint's VALIDATE state, that this check does not use).
  #
  # It found two real gaps on a live install: phoenix_kit_activities's
  # actor_uuid and target_uuid, both declared in PhoenixKit.Activity.Entry
  # with no matching foreign key in the database. Reported as advisory
  # (warn, not fail) — this can be intentional, a federated reference
  # (V179/V180) cannot carry a FK across an optional module boundary.
  #
  # A polymorphic pair (a *_uuid column with a sibling *_type
  # discriminator) structurally cannot appear in this check's findings:
  # Ecto has no way to declare belongs_to against a type that varies per
  # row, so there is nothing to filter for, unlike a name-based scan.
  #
  # Exposed (not `defp`) and `@doc false`, same reason as the other pure
  # decision functions in this module: a real end-to-end seam against a
  # live repo, directly testable without going through `run/1`.
  @doc false
  def check_schema_declared_relations_without_fk(prefix) do
    repo = get_repo!()

    case discover_schema_declared_relations_without_fk(repo, prefix) do
      {:error, reason} ->
        {:warn,
         "could not enumerate belongs_to relations or foreign keys in schema " <>
           "#{inspect(prefix)} (#{inspect(reason)}) — coverage is zero, which is not the " <>
           "same as clean. Fix catalog access (pg_constraint/information_schema) and re-run."}

      {:ok, {0, _missing}} ->
        {:warn,
         "no belongs_to-declared relation found to check in schema #{inspect(prefix)} — " <>
           "coverage is zero: either PhoenixKit's own schemas' tables aren't installed here " <>
           "yet, or --prefix names the wrong schema. This is not the same as clean."}

      {:ok, {total, []}} ->
        {:pass,
         "Every belongs_to PhoenixKit's schemas declare has a matching DB foreign key " <>
           "(checked #{total} of #{total})"}

      {:ok, {total, missing}} ->
        detail =
          Enum.map_join(missing, "\n       ", fn {table, column} -> "#{table}.#{column}" end)

        {:warn,
         "#{length(missing)} of #{total} relation(s) declared via `belongs_to` in " <>
           "PhoenixKit's own Ecto schemas have no matching database foreign key:\n       " <>
           "#{detail}\n       This is advisory, not a failure — some are intentional (a " <>
           "federated/soft reference cannot carry a FK across an optional module boundary, " <>
           "see V179/V180). Derived from declared `belongs_to` associations only, cross-" <>
           "referenced against pg_constraint — not exhaustive: a soft reference held as a " <>
           "plain field (no `belongs_to` at all, e.g. a polymorphic pair) is invisible to " <>
           "this scan too."}
    end
  end

  # Returns `{:ok, {total_candidates, missing}}`, `missing` a `[{table,
  # column}]` for every `belongs_to` owner_key that exists as a real column
  # in this schema but has no `pg_constraint` FK matching its declared
  # target table — or `{:error, reason}` if either catalog query itself
  # fails. `total_candidates` is every belongs_to owner_key that DOES exist
  # as a real column here (checked against `information_schema.columns`,
  # not just `pg_constraint` membership, so a schema module for a
  # not-yet-installed module — table absent entirely — is correctly
  # excluded rather than miscounted as "declared, no FK"), surfaced so a
  # caller can tell "checked N, all clean" apart from "checked nothing" —
  # an empty `existing_columns` (wrong --prefix, nothing installed yet)
  # would otherwise filter every candidate out and report the same `[]`
  # `missing` as a genuinely clean install, printing PASS for a schema
  # this check never actually looked at.
  #
  # The FK side is matched on the full (table, column, ref_table) triple,
  # not just (table, column): a column carrying a single-column FK to the
  # WRONG table (or a table caught up in a multi-column constraint via
  # `array_length(c.conkey, 1) = 1` below) must still show up as missing
  # its DECLARED relation, not be waved through because some other FK
  # happens to touch the same column.
  @doc false
  def discover_schema_declared_relations_without_fk(repo, prefix) do
    escaped_prefix = String.replace(prefix, "'", "\\'")

    with {:ok, %{rows: fk_rows}} <-
           repo.query(
             """
             SELECT t.relname, a.attname, ft.relname
             FROM pg_constraint c
             JOIN pg_class t ON t.oid = c.conrelid
             JOIN pg_namespace n ON n.oid = t.relnamespace
             JOIN pg_class ft ON ft.oid = c.confrelid
             JOIN pg_namespace fn ON fn.oid = ft.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
             WHERE c.contype = 'f'
               AND n.nspname = '#{escaped_prefix}'
               AND fn.nspname = '#{escaped_prefix}'
               AND array_length(c.conkey, 1) = 1
             """,
             [],
             log: false
           ),
         {:ok, %{rows: col_rows}} <-
           repo.query(
             "SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = '#{escaped_prefix}'",
             [],
             log: false
           ) do
      declared_fk_relations =
        MapSet.new(fk_rows, fn [table, col, ref_table] -> {table, col, ref_table} end)

      existing_columns = MapSet.new(col_rows, fn [table, col] -> {table, col} end)

      {:ok, modules} = :application.get_key(:phoenix_kit, :modules)

      candidates =
        modules
        # `function_exported?/3` checks only what's already loaded in THIS
        # process — for a schema module nothing has called yet, it reads
        # false even though `Code.ensure_loaded?/1` would trigger the load
        # and it would work fine one line later. Without the ensure_loaded?
        # first, this filtered out nearly every schema.
        |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :__schema__, 1)))
        |> Enum.flat_map(&belongs_to_owner_columns/1)
        |> Enum.uniq()
        |> Enum.filter(fn {table, col, _ref_table} ->
          MapSet.member?(existing_columns, {table, col})
        end)
        |> Enum.sort()

      missing =
        candidates
        |> Enum.reject(&MapSet.member?(declared_fk_relations, &1))
        |> Enum.map(fn {table, col, _ref_table} -> {table, col} end)

      {:ok, {length(candidates), missing}}
    end
  end

  defp belongs_to_owner_columns(schema) do
    table = schema.__schema__(:source)

    schema.__schema__(:associations)
    |> Enum.map(&schema.__schema__(:association, &1))
    |> Enum.filter(&match?(%Ecto.Association.BelongsTo{}, &1))
    |> Enum.map(fn assoc ->
      {table, Atom.to_string(assoc.owner_key), assoc.related.__schema__(:source)}
    end)
  end

  defp check_lock_conflicts do
    repo = get_repo!()

    query = """
    SELECT count(*) FROM pg_stat_activity
    WHERE datname = current_database()
      AND pid != pg_backend_pid()
      AND wait_event_type = 'Lock'
    """

    case repo.query(query, []) do
      {:ok, %{rows: [[0]]}} ->
        {:pass, "No lock conflicts"}

      {:ok, %{rows: [[count]]}} ->
        detail_query = """
        SELECT pid, age(now(), query_start)::text, left(query, 80)
        FROM pg_stat_activity
        WHERE datname = current_database()
          AND pid != pg_backend_pid()
          AND wait_event_type = 'Lock'
        ORDER BY query_start LIMIT 5
        """

        details =
          case repo.query(detail_query, []) do
            {:ok, %{rows: rows}} ->
              Enum.map_join(rows, "\n       ", fn [pid, dur, q] ->
                "PID #{pid} (#{dur}): #{q}"
              end)

            _ ->
              "Could not fetch details"
          end

        {:fail, "#{count} queries waiting on locks:\n       #{details}"}

      _ ->
        {:warn, "Could not check (may not have pg_stat_activity access)"}
    end
  end

  defp check_orphaned_connections do
    repo = get_repo!()

    query = """
    SELECT state, count(*)::integer, max(age(now(), state_change))::text
    FROM pg_stat_activity
    WHERE datname = current_database()
      AND pid != pg_backend_pid()
    GROUP BY state ORDER BY state
    """

    case repo.query(query, []) do
      {:ok, %{rows: rows}} ->
        info =
          Enum.map_join(rows, ", ", fn [state, count, oldest] ->
            "#{state || "null"}: #{count} (oldest: #{oldest})"
          end)

        idle_in_tx =
          Enum.find(rows, fn [state, _, _] ->
            state in ["idle in transaction", "idle in transaction (aborted)"]
          end)

        if idle_in_tx do
          [_state, count, oldest] = idle_in_tx

          {:fail,
           "#{count} idle-in-transaction (oldest: #{oldest}). " <>
             "These block DDL. Kill: SELECT pg_terminate_backend(pid) ... All: #{info}"}
        else
          {:pass, info}
        end

      _ ->
        {:warn, "Could not query pg_stat_activity"}
    end
  end

  # Reports the Oban config snapshotted in run/1 BEFORE cap_repo_pool_size/1
  # zeroed its queues/plugins — reading it live here would always show 0/0.
  # Queues PhoenixKit and the installed modules declare (`oban_queues/0`)
  # that this node's Oban config does not run. Jobs sent to such a queue wait
  # forever without an error, which is why this is worth a line of its own.
  defp check_declared_queues(oban_config) do
    {declared, conflicts} = PhoenixKit.ObanQueues.resolve()
    declared_queues_verdict(oban_config, PhoenixKit.ObanQueues.required(declared), conflicts)
  end

  @doc false
  # Pure: the verdict for the declared-queues check.
  def declared_queues_verdict(oban_config, declared, conflicts) do
    conflict_text =
      Enum.map_join(conflicts, " ", &(PhoenixKit.ObanQueues.describe_conflict(&1) <> "."))

    cond do
      not is_list(oban_config) ->
        {:pass, "Oban not configured statically; declared queues not checked."}

      # Oban then runs nothing, like `queues: false` — but nobody chose it,
      # and the updater has no list to add to.
      not Keyword.has_key?(oban_config, :queues) ->
        {:warn,
         "Your Oban config has no queues: list, so this node runs no queues and these " <>
           "jobs never run: " <>
           Enum.map_join(declared, ", ", &"#{&1.name}: #{&1.limit}") <>
           ". Add a queues: list with them, or set `queues: false` on a node that " <>
           "should run no jobs." <>
           if(conflict_text == "", do: "", else: " " <> conflict_text)}

      Keyword.get(oban_config, :queues) in [false, []] ->
        {:pass,
         "This node runs no queues (queues: false or []). Declared queues must run on your " <>
           "worker nodes: " <> Enum.map_join(declared, ", ", &"#{&1.name}")}

      (missing = PhoenixKit.ObanQueues.missing(oban_config, declared)) != [] ->
        {:warn,
         "Not configured, so their jobs never run: " <>
           Enum.map_join(missing, ", ", fn spec ->
             "#{spec.name}: #{spec.limit} (#{PhoenixKit.ObanQueues.owner_label(spec.owner)})"
           end) <>
           ". Run `mix phoenix_kit.update`, or add them to your Oban queues." <>
           if(conflict_text == "", do: "", else: " " <> conflict_text)}

      conflicts != [] ->
        {:warn, conflict_text}

      true ->
        {:pass, "All #{length(declared)} declared queues are configured."}
    end
  end

  defp check_oban_config(nil), do: {:pass, "Oban not configured"}

  defp check_oban_config(config) when is_list(config) do
    # `queues: false` / `plugins: false` is Oban's documented way to disable
    # either wholesale (standard in test config, and used by hosts that run
    # jobs on a separate node) — normalize so this check reports instead of
    # raising into run_check/2's rescue as a bogus FAIL.
    raw_plugins = Keyword.get(config, :plugins, [])
    queues = config |> Keyword.get(:queues, []) |> normalize_oban_list()
    plugins = normalize_oban_list(raw_plugins)

    base =
      "#{length(queues)} queues, #{length(plugins)} plugins. Each active queue uses 1 pool connection."

    # Plugins off on purpose (web-only node, test config). Nagging about
    # Lifeline here is a false positive, and the remedy it recommends would
    # rewrite config.exs for a node that must not run plugins at all.
    if raw_plugins == false do
      {:pass, base <> " Oban plugins are disabled on this node (plugins: false)."}
    else
      check_lifeline_plugin(plugins, base)
    end
  end

  defp check_oban_config(_other), do: {:pass, "Oban configured (non-keyword config)"}

  defp normalize_oban_list(value) when is_list(value), do: value
  defp normalize_oban_list(_value), do: []

  # Lifeline's presence is necessary but not sufficient: it rescues purely by
  # elapsed time with no liveness check, so a rescue_after at or below the
  # longest job the host can run re-executes that job concurrently with the
  # still-live original. Oban's own docs advertise :timer.minutes(5) as the
  # "more aggressive period" example, so a too-low value is an easy thing for a
  # host to copy in — validate the value, not just the entry.
  defp check_lifeline_plugin(plugins, base) do
    case lifeline_entry(plugins) do
      nil ->
        {:warn,
         base <>
           " Oban.Plugins.Lifeline is not configured — a job orphaned in :executing by a hard " <>
           "crash (kill -9, OOM, node failure) is never rescued back to :available. Run " <>
           "mix phoenix_kit.update to add {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}."}

      {:ok, rescue_after}
      when is_integer(rescue_after) and rescue_after <= @lifeline_min_rescue_after ->
        {:warn,
         base <>
           " Oban.Plugins.Lifeline is configured with rescue_after: #{div(rescue_after, 60_000)} " <>
           "minutes, at or below the longest job PhoenixKit ships " <>
           "(Storage.Jobs.Reconcile, #{div(@lifeline_min_rescue_after, 60_000)} minutes). " <>
           "Lifeline rescues purely by elapsed time and never checks whether the executing node " <>
           "is alive, so a job still running at that mark is rescued and executes a second time " <>
           "concurrently. Raise it above your longest-running job (60 minutes is Oban's default)."}

      _ ->
        {:pass, base}
    end
  end

  # `{:ok, rescue_after}` where rescue_after is nil when unset — an unset value
  # means Oban's own 60-minute default, which is safe.
  defp lifeline_entry(plugins) do
    Enum.find_value(plugins, fn
      Oban.Plugins.Lifeline -> {:ok, nil}
      {Oban.Plugins.Lifeline, opts} when is_list(opts) -> {:ok, Keyword.get(opts, :rescue_after)}
      {Oban.Plugins.Lifeline, _opts} -> {:ok, nil}
      _ -> nil
    end)
  end

  # A cron entry inserts a job whether or not anything is configured to run it,
  # and Oban only fetches for queues this node lists in `queues:`. So a crontab
  # worker whose queue is missing produces one job per tick that stays
  # :available forever — Pruner deletes terminal states only, so nothing ever
  # clears them.
  #
  # PhoenixKit shipped exactly this between 2025-12-28 and 1.7.63: the
  # ProcessScheduledJobsWorker entry went into the generated config without its
  # :scheduled_jobs queue. Hosts installed in that window are still affected,
  # because the installer's *upgrade* path only ever added the entry — one such
  # host was found with 21,337 orphaned rows and climbing at ~1,440/day.
  #
  # Checking the whole crontab rather than that one worker is the point: the
  # next instance of this mistake is then a warning on the next doctor run
  # instead of something a host has to discover by reading its own oban_jobs
  # table.
  @doc """
  Reports crontab entries whose queue this node does not run.

  Public so it can be unit-tested directly against config keyword lists, for
  the same reason as `exit_code/1`: it is the pure decision inside a task whose
  `run/1` needs a live app and a database.
  """
  @spec check_cron_queues(keyword() | nil | term()) :: {:pass | :warn, String.t()}
  def check_cron_queues(nil), do: {:pass, "Oban not configured"}

  def check_cron_queues(config) when is_list(config) do
    raw_queues = Keyword.get(config, :queues, [])
    raw_plugins = Keyword.get(config, :plugins, [])
    queues = normalize_oban_list(raw_queues)

    cond do
      # `testing: :inline | :manual` makes Oban itself overwrite both plugins
      # and queues with [] (Oban.Config.normalize_opts/1), so no cron ever
      # fires and nothing can accumulate. Reading the host's declared values
      # and warning would describe a config Oban is not going to use.
      Keyword.get(config, :testing, :disabled) in [:inline, :manual] ->
        {:pass, "Oban is in testing mode — it runs no queues and no plugins."}

      # `plugins: false` is Oban's documented way to turn plugins off
      # wholesale: no Cron, so no entries to check.
      raw_plugins == false ->
        {:pass, "Oban plugins are disabled on this node (plugins: false)."}

      # Oban documents an empty list and `false` as the same thing — "prevents
      # any queues from starting on init". A web-only node says one or the
      # other, and there every entry would look orphaned, so the honest answer
      # is "not applicable" rather than a warning per crontab line.
      raw_queues == false or queues == [] ->
        {:pass, "Oban runs no queues on this node — jobs are executed elsewhere."}

      true ->
        config
        |> crontab_entries()
        |> check_entry_queues(queues)
    end
  end

  def check_cron_queues(_other), do: {:pass, "Oban configured (non-keyword config)"}

  # `flat_map` rather than "find the Cron plugin", and the top-level key as
  # well as the plugin: Oban still accepts `crontab:` directly on the Oban
  # config and promotes it into a Cron plugin itself
  # (`Oban.Config.crontab_to_plugin/1`). A host using that form has entries the
  # plugins list never mentions, and stopping at the first Cron plugin would
  # have missed them entirely — reporting a clean bill of health on precisely
  # the config this check exists to catch.
  defp crontab_entries(config) do
    plugin_entries =
      config
      |> Keyword.get(:plugins, [])
      |> normalize_oban_list()
      |> Enum.flat_map(fn
        {Oban.Plugins.Cron, opts} when is_list(opts) -> Keyword.get(opts, :crontab, [])
        _ -> []
      end)

    plugin_entries ++ Keyword.get(config, :crontab, [])
  end

  defp check_entry_queues([], _queues),
    do: {:pass, "No Oban.Plugins.Cron crontab entries to check."}

  defp check_entry_queues(entries, queues) do
    configured = MapSet.new(Keyword.keys(queues), &to_string/1)

    orphans =
      for entry <- entries,
          {:ok, worker, queue} <- [entry_queue(entry)],
          not MapSet.member?(configured, queue),
          uniq: true,
          do: {worker, queue}

    case orphans do
      [] ->
        {:pass, "#{length(entries)} crontab entries, every queue configured."}

      orphans ->
        detail =
          Enum.map_join(orphans, ", ", fn {worker, queue} ->
            "#{inspect(worker)} → #{queue}"
          end)

        {:warn,
         "#{length(entries)} crontab entries. These fire into queues this node does not run, so " <>
           "each tick inserts a job nothing will execute and Pruner never clears it (terminal " <>
           "states only): #{detail}. Add the queue to `queues:` in config.exs, or drop the " <>
           "crontab entry — `mix phoenix_kit.update` adds the ones PhoenixKit ships. Check what " <>
           "has already collected first (`SELECT count(*) FROM oban_jobs WHERE state = " <>
           "'available'`): configuring the queue releases the whole backlog at once, and for " <>
           "ProcessScheduledJobsWorker that first sweep publishes every overdue scheduled post " <>
           "and sends every overdue broadcast. `Oban.cancel_all_jobs/1` over the queue clears " <>
           "them without running them."}
    end
  end

  # Mirrors Oban.Plugins.Cron.build_changeset/4: the entry's own opts win over
  # the worker's, and a worker declaring no queue falls back to Oban.Job's
  # "default". (Cron uses Worker.merge_opts/2, whose only special case is
  # :unique — for :queue it is a plain Keyword.merge.)
  #
  # Queues compare as strings because Oban accepts either form — `queue: :foo`
  # in a worker and `foo: 10` in `queues:` are the same queue — and it avoids
  # minting atoms from config while checking it.
  defp entry_queue({expr, worker}), do: entry_queue({expr, worker, []})

  defp entry_queue({_expr, worker, opts}) when is_atom(worker) and is_list(opts) do
    # A crontab may name a worker from a dependency that is not loaded in the
    # doctor's VM. Skipping is right: we cannot read its queue, and guessing
    # would report a host as broken for a module we simply failed to load.
    if Code.ensure_loaded?(worker) and function_exported?(worker, :__opts__, 0) do
      queue =
        worker.__opts__()
        |> Keyword.merge(opts)
        |> Keyword.get(:queue, :default)

      {:ok, worker, to_string(queue)}
    else
      :skip
    end
  end

  defp entry_queue(_other), do: :skip

  defp check_supervisor_state do
    case Process.whereis(PhoenixKit.Supervisor) do
      nil ->
        {:warn, "PhoenixKit.Supervisor not running"}

      pid ->
        children = Supervisor.which_children(pid)
        names = Enum.map(children, fn {id, _, _, _} -> id end)
        {:pass, "#{length(children)} children: #{inspect(names)}"}
    end
  end

  # Reads the host application.ex and verifies the Repo starts BEFORE
  # PhoenixKit.Supervisor and Oban — a child listed before the Repo crashes the
  # app at boot (PhoenixKit reads Settings from the DB; Oban needs the pool).
  # The runtime supervisor check above can't catch this (by the time doctor
  # runs, everything has already started), so we read the source order.
  defp check_child_order do
    repo = get_repo!()

    case host_application_source() do
      {:ok, path, source} ->
        where = Path.relative_to_cwd(path)

        case ChildOrder.check(source, repo) do
          {:ok, detail} ->
            {:pass, "#{detail} (#{where})"}

          {:misordered, mods} ->
            names = Enum.map_join(mods, ", ", &inspect/1)

            {:fail,
             "#{names} start BEFORE #{inspect(repo)} in #{where}. PhoenixKit.Supervisor " <>
               "reads Settings from the database and Oban needs the connection pool, so both " <>
               "must be listed AFTER your Repo. Move #{inspect(repo)} above them in the " <>
               "children list to fix the boot crash."}

          :no_repo_in_children ->
            {:warn,
             "Couldn't find #{inspect(repo)} in the children list of #{where} — verify " <>
               "PhoenixKit.Supervisor and Oban are started after your Repo."}

          :no_children ->
            {:warn, "Couldn't locate a children list in #{where} to verify start order."}
        end

      :error ->
        {:warn, "Couldn't locate your application.ex to verify child start order."}
    end
  end

  @doc false
  def update_mode_verdict(true) do
    {:warn,
     "update_mode=true was configured before doctor started; normal application services are disabled"}
  end

  def update_mode_verdict(_) do
    {:pass,
     "Host update_mode=false; doctor temporarily enables update mode to minimize DB connections"}
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp get_repo! do
    app = Mix.Project.config()[:app]

    case Application.get_env(app, :ecto_repos, []) do
      [repo | _] -> repo
      [] -> raise "No :ecto_repos configured for :#{app}"
    end
  end

  # Locate the host's application.ex — first via the compiled application
  # module's source path, then the conventional lib/<app>/application.ex.
  defp host_application_source do
    app = Mix.Project.config()[:app]

    candidates =
      [
        case Application.spec(app, :mod) do
          {mod, _args} -> module_source(mod)
          _ -> nil
        end,
        Path.join(["lib", "#{app}", "application.ex"])
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find_value(candidates, :error, fn path ->
      case File.read(path) do
        {:ok, source} -> {:ok, path, source}
        _ -> nil
      end
    end)
  end

  defp module_source(mod) do
    with {:module, _} <- Code.ensure_loaded(mod),
         source when not is_nil(source) <- mod.module_info(:compile)[:source] do
      to_string(source)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp cap_repo_pool_size(pool_size) do
    app = Mix.Project.config()[:app]
    repos = Application.get_env(app, :ecto_repos, [])

    Enum.each(repos, fn repo ->
      current = Application.get_env(app, repo, [])
      updated = Keyword.put(current, :pool_size, pool_size)
      Application.put_env(app, repo, updated)
    end)

    # Disable Oban queues to save connections
    case Application.get_env(app, Oban) do
      nil ->
        :ok

      config ->
        updated = config |> Keyword.put(:queues, []) |> Keyword.put(:plugins, [])
        Application.put_env(app, Oban, updated)
    end
  rescue
    _ -> :ok
  end

  defp get_comment_version(repo, escaped_prefix) do
    table_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = 'phoenix_kit' AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo.query(table_query, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = 'phoenix_kit'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        case repo.query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp prefix_table_name(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  defp extract_port_from_url(nil), do: nil

  defp extract_port_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{port: port} when is_integer(port) -> port
      _ -> nil
    end
  end

  defp extract_port_from_url(_), do: nil

  defp extract_host_from_url(nil), do: nil

  defp extract_host_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp extract_host_from_url(_), do: nil

  # The host owns assets/vendor/daisyui.js (scaffolded by phx.new, upgraded
  # manually). PhoenixKit's modals rely on daisyUI >= the minimum for correct
  # modal scrollbar-gutter handling — this check is where a host finds out
  # it's behind (install/update print the same warning).
  defp check_daisyui do
    alias PhoenixKit.Install.DaisyUI

    minimum = DaisyUI.minimum_version()

    case DaisyUI.check() do
      :ok ->
        {:pass, "daisyUI #{DaisyUI.installed_version(DaisyUI.host_path())} (>= #{minimum})"}

      {:outdated, version} ->
        {:warn, daisyui_outdated_message(DaisyUI.severity(version), version, minimum)}

      :unversioned ->
        {:warn,
         "assets/vendor/daisyui.js carries no version marker — cannot verify it against " <>
           "PhoenixKit's designed-for minimum (#{minimum})."}

      :missing ->
        {:warn,
         "No assets/vendor/daisyui.js — custom daisyUI setup? PhoenixKit is designed " <>
           "against daisyUI #{minimum}+; make sure your setup matches."}
    end
  end

  # Below daisyUI 5.1 modals genuinely mishandle the scrollbar gutter; at or
  # above it the host is merely short of the version core is verified against
  # (mix phx.new vendors 5.5.19 today, so a clean install lands here). Same
  # split as PhoenixKit.Install.DaisyUI.outdated_warning/1.
  defp daisyui_outdated_message(:broken, version, minimum) do
    alias PhoenixKit.Install.DaisyUI

    "Vendored daisyUI is #{version}; PhoenixKit is designed against #{minimum}+. " <>
      "Below #{DaisyUI.gutter_fix_version()} modals mishandle the scrollbar gutter. " <>
      "Update assets/vendor/daisyui.js + daisyui-theme.js from " <>
      "https://github.com/saadeghi/daisyui/releases and rebuild assets."
  end

  defp daisyui_outdated_message(:behind, version, minimum) do
    "Vendored daisyUI is #{version}; PhoenixKit is verified against #{minimum}+. " <>
      "Modals render correctly on your copy — advisory only. Update " <>
      "assets/vendor/daisyui.js + daisyui-theme.js from " <>
      "https://github.com/saadeghi/daisyui/releases when convenient."
  end

  # The user dashboard (/dashboard) is deprecated. It still works unchanged, so
  # this is advisory: WARN while it's enabled (a heads-up that it's going away
  # in favor of the unified /admin panel), PASS once a host has disabled it.
  # install/update print the same advisory (see PhoenixKit.Install.Deprecations).
  defp check_user_dashboard_deprecation do
    if PhoenixKit.Config.user_dashboard_enabled?() do
      {:warn,
       "The user dashboard (/dashboard) is deprecated. It still works and needs no " <>
         "action now, but will be removed in a future release — its functionality is " <>
         "moving into the unified admin panel (/admin), which shows sections per the " <>
         "viewer's permissions."}
    else
      {:pass, "User dashboard disabled — nothing to migrate."}
    end
  end

  # Three demo LiveViews (/test-current-user, /test-redirect-if-auth,
  # /test-ensure-auth) were written into every host by early versions of the
  # installer. They were never documented, never refreshed by
  # `mix phoenix_kit.update`, and `phoenix_kit_hello_world` does the job they
  # were for — properly, and as a versioned package. The generator is gone, but
  # deleting it does nothing for the hosts that already have them, which is what
  # this check is for. One of the three publicly reports whether you are logged
  # in, so this is worth saying out loud rather than leaving to archaeology.
  @demo_routes ["/test-current-user", "/test-redirect-if-auth", "/test-ensure-auth"]

  defp check_demo_routes do
    case RouteResolver.get_router() do
      nil ->
        {:pass, "No router resolved — nothing to check."}

      router ->
        paths = MapSet.new(router.__routes__(), & &1.path)

        case Enum.filter(@demo_routes, &MapSet.member?(paths, &1)) do
          [] ->
            {:pass, "No demo auth pages routed."}

          found ->
            {:warn,
             "This app still routes PhoenixKit's old demo auth pages: #{Enum.join(found, ", ")}. " <>
               "They were scaffolded by an early installer, are undocumented and unmaintained, " <>
               "and one of them reports publicly whether the visitor is logged in. Remove the " <>
               "demo scope from your router and delete the matching " <>
               "*Web.PhoenixKitLive.Test*Live modules. For a worked example of a PhoenixKit " <>
               "module, use phoenix_kit_hello_world instead."}
        end
    end
  rescue
    _ -> {:pass, "Could not introspect routes — skipping."}
  end

  # The two crawler-visibility footguns, in both directions: a production host
  # carrying the global noindex directive (the silent SEO killer — the switch
  # was for staging and someone shipped it), and a staging-looking host that is
  # indexable (Google will happily index a dev box; both directions have
  # happened here). Heuristic on the hostname, so it PASSes with a note when
  # the host cannot be determined rather than guessing.
  #
  # Settings are read via direct SQL, NOT PhoenixKit.Settings: the doctor runs
  # in update_mode, which short-circuits every Settings read to its default —
  # through that API this check would report "disabled" on every install.
  defp check_crawler_visibility(prefix) do
    cond do
      crawler_setting?(prefix, "crawlers_module_enabled", false) == false ->
        {:pass, "Crawlers module disabled — no directives active."}

      crawler_setting?(prefix, "crawlers_no_index", false) ->
        case host_flavor(prefix) do
          {:staging, host} ->
            {:pass, "Global noindex is ON for #{host}, which looks like staging — as intended."}

          {:production, host} ->
            {:warn,
             "The global noindex directive is ON and #{host} does not look like a staging " <>
               "host. If this is production, every page is telling search engines to drop " <>
               "it. Turn it off in Settings → Crawlers."}

          :unknown ->
            {:pass,
             "Global noindex is ON (host undetermined — if this deployment is " <>
               "production, turn it off in Settings → Crawlers)."}
        end

      true ->
        case host_flavor(prefix) do
          {:staging, host} ->
            {:warn,
             "#{host} looks like a staging/dev deployment and is INDEXABLE — search " <>
               "engines will index it. Consider the noindex toggle in Settings → Crawlers."}

          _ ->
            blocked =
              Enum.reject(
                Bots.group_keys(),
                &crawler_setting?(prefix, Crawlers.group_setting_key(&1), true)
              )

            summary =
              case blocked do
                [] -> "all bot groups allowed"
                keys -> "blocked bot groups: #{Enum.join(keys, ", ")}"
              end

            {:pass, "Site indexable, noindex off; #{summary}."}
        end
    end
  rescue
    _ -> {:pass, "Crawler settings unreadable (no database?) — skipping."}
  catch
    :exit, _ -> {:pass, "Crawler settings unreadable (no database?) — skipping."}
  end

  # A boolean settings row, read straight from the table (see moduledoc of the
  # check above for why). Missing row → the given default.
  defp crawler_setting?(prefix, key, default) do
    repo = get_repo!()
    p = if prefix == "public", do: "public.", else: "#{prefix}."

    case repo.query!("SELECT value FROM #{p}phoenix_kit_settings WHERE key = $1", [key]) do
      %{rows: [[value] | _]} -> value == "true"
      _ -> default
    end
  end

  # Every variant set must have the standard sizes (V205): a size's name is
  # in every file URL, and core and modules ask for these by name. V205 does
  # not invent a size an install deleted or renamed before; serving stands
  # in for it (the nearest smaller size, else a placeholder) until an admin
  # adds it back.
  defp check_variant_sets(prefix) do
    repo = get_repo!()
    p = if prefix == "public", do: "public.", else: "#{prefix}."
    slots = Dimension.standard_slots()

    %{rows: [[present?]]} =
      repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'phoenix_kit_variant_sets')",
        [prefix]
      )

    if present? do
      %{rows: rows} =
        repo.query!(
          """
          SELECT s.name,
                 ARRAY(SELECT unnest($1::text[])
                       EXCEPT SELECT d.name FROM #{p}phoenix_kit_storage_dimensions d
                              WHERE d.variant_set_uuid = s.uuid)
          FROM #{p}phoenix_kit_variant_sets s
          ORDER BY s.is_default DESC, s.name
          """,
          [slots]
        )

      case Enum.reject(rows, fn [_name, missing] -> missing == [] end) do
        [] ->
          {:pass, "Every variant set has the standard sizes (#{Enum.join(slots, ", ")})."}

        incomplete ->
          detail =
            Enum.map_join(incomplete, "; ", fn [name, missing] ->
              "#{name}: #{missing |> Enum.sort() |> Enum.join(", ")}"
            end)

          {:warn,
           "Variant sets missing standard sizes — #{detail}. Until they are added back " <>
             "(Settings → Media), those sizes are served as the nearest smaller size or " <>
             "a placeholder."}
      end
    else
      {:pass, "No variant sets yet (before V205)."}
    end
  end

  # Sizes made before the current rendering rules (`VariantSets` @pipeline)
  # keep working but look as they did — a see-through PNG's JPEG size on
  # black, an upscaled small original. Remaking them is deliberately manual:
  # `remake_all/0` touches every size of every file, which a host with a
  # large library schedules itself. The count stops at @pipeline_scan_cap so
  # the check stays cheap on millions of rows.
  @pipeline_scan_cap 10_000

  defp check_variant_pipeline(prefix) do
    repo = get_repo!()
    p = if prefix == "public", do: "public.", else: "#{prefix}."

    %{rows: [[present?]]} =
      repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'phoenix_kit_file_instances' AND column_name = 'spec_hash')",
        [prefix]
      )

    if present? do
      %{rows: dimensions} =
        repo.query!(
          "SELECT width, height, quality, format, maintain_aspect_ratio, alternative_formats FROM #{p}phoenix_kit_storage_dimensions"
        )

      legacy = legacy_hashes(dimensions)

      %{rows: [[count]]} =
        repo.query!(
          "SELECT count(*) FROM (SELECT 1 FROM #{p}phoenix_kit_file_instances WHERE spec_hash = ANY($1) LIMIT $2) s",
          [legacy, @pipeline_scan_cap]
        )

      pipeline_verdict(count)
    else
      {:pass, "No sized variants yet (before V205)."}
    end
  end

  @doc false
  # The pipeline-1 spec hashes of every size (and alternative format) the
  # dimension rows `[width, height, quality, format, keep_aspect, alts]` make.
  @spec legacy_hashes([list()]) :: [String.t()]
  def legacy_hashes(dimensions) do
    for [w, h, q, format, keep_aspect, alternatives] <- dimensions,
        f <- Enum.uniq([format | alternatives || []]) do
      VariantSets.legacy_spec_hash(
        %Dimension{width: w, height: h, quality: q, maintain_aspect_ratio: keep_aspect},
        f
      )
    end
    |> Enum.uniq()
  end

  @doc false
  # The verdict for `count` sizes still carrying a pipeline-1 spec hash.
  @spec pipeline_verdict(non_neg_integer()) :: {:pass | :warn, String.t()}
  def pipeline_verdict(0), do: {:pass, "Every image size was made by the current pipeline."}

  def pipeline_verdict(count) do
    shown = if count >= @pipeline_scan_cap, do: "#{@pipeline_scan_cap}+", else: "#{count}"

    {:warn,
     "#{shown} image sizes were made by an older version of the image pipeline " <>
       "(before see-through images got PNG sizes and sizes stopped upscaling). They " <>
       "still work and are left as they are. To remake them, run " <>
       "PhoenixKit.Modules.Storage.VariantSets.remake_all() from a remote console: " <>
       "it queues EVERY size of EVERY file for the background reconciler, so on a " <>
       "large library pick a quiet time."}
  end

  # :staging / :production by hostname shape, :unknown when no URL is
  # configured. Label-based matching, not substring — "device.com" must not
  # read as a dev box, while "max-dev2.example" must. The site_url setting is
  # read via SQL (update_mode, as above) with the endpoint config as fallback.
  defp host_flavor(prefix) do
    url = configured_site_url(prefix) || endpoint_url()

    with url when is_binary(url) and url != "" <- url,
         %URI{host: host} when is_binary(host) and host != "" <- URI.parse(url) do
      # DNS names are case-insensitive; the label list is lowercase.
      host = String.downcase(host)
      if staging_host?(host), do: {:staging, host}, else: {:production, host}
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp configured_site_url(prefix) do
    repo = get_repo!()
    p = if prefix == "public", do: "public.", else: "#{prefix}."

    case repo.query!("SELECT value FROM #{p}phoenix_kit_settings WHERE key = 'site_url'", []) do
      %{rows: [[value] | _]} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp endpoint_url do
    Routes.base_url()
  rescue
    _ -> nil
  end

  @staging_labels ~w(localhost local staging stage dev develop development test testing demo preview sandbox)

  defp staging_host?(host) do
    cond do
      host in ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"] -> true
      String.ends_with?(host, ".local") -> true
      String.contains?(host, "ngrok") or String.ends_with?(host, "lvh.me") -> true
      ip_address?(host) -> true
      true -> host |> String.split([".", "-"]) |> Enum.any?(&staging_label?/1)
    end
  end

  defp staging_label?(label) do
    # Strip a trailing ordinal so "dev2" and "staging3" match while "device"
    # (whose stem is not in the list) does not.
    base = String.replace(label, ~r/\d+$/, "")
    base != "" and base in @staging_labels
  end

  defp ip_address?(host) do
    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  # Which layer answers GET /sitemap.xml, and whether robots.txt points at it.
  #
  # Three layers can claim that path and nothing tells a host which one won:
  # Plug.Static runs before the router, host routes declared before
  # `phoenix_kit_routes()` bind first, and PhoenixKit is last. A host that
  # reported "the sitemap 404s" had simply never been told any of that.
  defp check_sitemap_serving(prefix) do
    serving =
      case {static_sitemap_file(), sitemap_route_owner()} do
        {path, _} when is_binary(path) ->
          {:warn,
           "#{path} exists, and Plug.Static runs before the router — that file is served, " <>
             "not PhoenixKit's generated sitemap. Delete it to use the generated one."}

        {nil, nil} ->
          {:warn,
           "No route answers GET /sitemap.xml. PhoenixKit declares one, so either " <>
             "phoenix_kit_routes() is missing from your router or a host route matched " <>
             "first and was removed."}

        {nil, owner} ->
          {:pass,
           "GET /sitemap.xml is served by #{inspect(owner)}." <>
             robots_hint(router_routes(), "priv/static/robots.txt")}
      end

    findings =
      duplicate_root_route_findings(router_routes()) ++
        List.wrap(
          sitemap_base_url_finding(
            # Not `Settings.get_setting/2`: update_mode (set in run/1)
            # short-circuits it to the default, so every install read as
            # "site_url is not set".
            configured_site_url(prefix) || "",
            Sitemap.endpoint_base_url()
          )
        )

    merge_findings(serving, findings)
  end

  defp merge_findings(result, []), do: result

  defp merge_findings({_status, message}, findings) do
    {:warn, Enum.join([message | findings], " ")}
  end

  defp router_routes do
    case RouteResolver.get_router() do
      nil -> []
      router -> router.__routes__()
    end
  rescue
    _ -> []
  end

  # The root-level paths PhoenixKit's router macro declares (outside its URL
  # prefix). 1.7 told hosts to declare the sitemap routes themselves; the kit
  # took that over, so an upgraded host can declare the same path twice.
  @kit_root_paths ~w(/llms.txt /sitemap.xml /sitemap.html /sitemaps/:filename /sitemap.xsl)

  @doc false
  # Pure: one finding per kit root path declared more than once. Phoenix
  # matches routes in the order they were declared, so the first declaration
  # answers and every later one is dead code — which of the two is the host's
  # depends on where the host put `phoenix_kit_routes()`, so both are named.
  def duplicate_root_route_findings(routes) do
    routes
    |> Enum.filter(&(&1.verb == :get and &1.path in @kit_root_paths))
    |> Enum.group_by(& &1.path)
    |> Enum.filter(fn {_path, declared} -> length(declared) > 1 end)
    |> Enum.sort_by(fn {path, _} -> path end)
    |> Enum.map(fn {path, [winner | dead]} ->
      "GET #{path} is declared #{length(dead) + 1} times: #{inspect(winner.plug)} " <>
        "answers it (declared first), and the declaration by " <>
        "#{Enum.map_join(dead, ", ", &inspect(&1.plug))} never runs. " <>
        "Delete the one you no longer want — usually a pre-2.0 copy of PhoenixKit's route."
    end)
  end

  @doc false
  # Pure: whether the sitemap is falling back from `site_url`, and to what.
  def sitemap_base_url_finding(site_url, endpoint_url) do
    cond do
      is_binary(site_url) and site_url != "" ->
        nil

      endpoint_url != "" ->
        "site_url is not set, so sitemap links use the endpoint URL (#{endpoint_url}). " <>
          "Set site_url if that is not your public address (behind a proxy, say); a " <>
          "sitemap generated before this change keeps its old links until it is regenerated." <>
          loopback_note(endpoint_url)

      true ->
        "site_url is not set and the endpoint has no public absolute URL (a placeholder " <>
          "host like example.com never counts; localhost counts only on a development " <>
          "server), so the sitemap answers 503. Set site_url in the admin settings."
    end
  end

  # The doctor usually runs on a development box, where a local endpoint URL
  # is accepted; say what the same config does in production.
  defp loopback_note(endpoint_url) do
    host = URI.parse(endpoint_url).host || ""

    if Sitemap.local_host?(host) do
      " #{host} counts only on a development server — in production the sitemap " <>
        "answers 503 until site_url (or the endpoint's url) is set."
    else
      ""
    end
  end

  defp static_sitemap_file do
    Enum.find(["priv/static/sitemap.xml", "priv/static/sitemap.xml.gz"], &File.exists?/1)
  end

  # Same router the sitemap source itself introspects, so what this reports is
  # what actually generates.
  defp sitemap_route_owner do
    case RouteResolver.get_router() do
      nil ->
        nil

      router ->
        case Enum.find(router.__routes__(), &(&1.verb == :get and &1.path == "/sitemap.xml")) do
          %{plug: plug} -> plug
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  # robots.txt is host policy — PhoenixKit deliberately does not generate one.
  # Without a Sitemap: line, crawlers only find the sitemap by guessing. A
  # host may serve it from a route (a controller writing it per domain); then
  # there is no file to read, and saying "no robots.txt" would be wrong.
  @doc false
  @spec robots_hint([map()], Path.t()) :: String.t()
  def robots_hint(routes, path) do
    routed = Enum.find(routes, &(&1.verb == :get and &1.path == "/robots.txt"))

    cond do
      routed && not File.exists?(path) ->
        " robots.txt is served by #{inspect(routed.plug)} — make sure it carries a `Sitemap:` line."

      not File.exists?(path) ->
        " No priv/static/robots.txt — consider adding one with a `Sitemap:` line."

      File.read!(path) =~ ~r/^\s*sitemap:/im ->
        ""

      true ->
        " priv/static/robots.txt has no `Sitemap:` line — add " <>
          "`Sitemap: https://yourdomain/sitemap.xml` so crawlers find it."
    end
  rescue
    _ -> ""
  end

  # Additional, non-fatal check (task ask, spec §6.1's third manifest
  # consumer): when the generated manifest exists, run
  # `PhoenixKit.Migrations.Repair.verify/1` (read-only) against it and fold
  # the result into doctor's report. Deliberately capped at `:warn` — this
  # check exists to surface repair-relevant information during a routine
  # diagnostic pass, not to make `mix phoenix_kit.doctor` fail a deploy gate
  # over something `mix phoenix_kit.repair` itself reports in full. Wrapped
  # in its own rescue (on top of `run_check/2`'s) so a bug in this brand-new
  # code path can never turn into a `:fail` here either.
  defp check_manifest_repair(prefix) do
    case Resolver.resolve() do
      {:error, :not_generated} ->
        {:pass, Resolver.not_generated_message()}

      {:ok, _module} ->
        manifest_repair_result(prefix)
    end
  rescue
    e -> {:warn, "Manifest repair check raised: #{Exception.message(e)}"}
  end

  defp manifest_repair_result(prefix) do
    case Repair.verify(prefix: prefix) do
      {:ok, report} ->
        summary = Report.summary(report)

        if Report.exit_code(report) == 0 do
          {:pass, "clean — #{summary.total} finding(s), all info-level"}
        else
          {:warn,
           "#{summary.total} finding(s): #{inspect(summary.by_severity)} — run mix phoenix_kit.repair for details"}
        end

      {:error, reason} ->
        {:warn, Repair.error_message(reason)}
    end
  end

  # ── Display ─────────────────────────────────────────────────────────

  # The doctor needs the host application running, and a column-adding release
  # is exactly when that fails: the freshly compiled schema modules select a
  # column the database has not got, so a host child that queries at init
  # (a registry warming a cache, a GenServer loading settings) takes the whole
  # boot down. Raw, the crash reads as an application bug. It is a pending
  # migration, and there is a way to run it without the app — say so, then
  # re-raise so the exit status and the original stacktrace are unchanged.
  defp start_app_or_explain! do
    Mix.Task.run("app.start")
  rescue
    error ->
      error |> Exception.message() |> explain_if_undefined_column()
      reraise error, __STACKTRACE__
  catch
    # A boot failure can exit rather than raise, depending on where in the
    # host's tree it happened — the hint is worth the same either way.
    :exit, reason ->
      reason |> inspect(limit: :infinity) |> explain_if_undefined_column()
      exit(reason)
  end

  # Postgres 42703 is undefined_column. The failure reaches us wrapped in
  # whatever the host's supervision tree raised on the way up (`Mix.Error`
  # around an `{:EXIT, ...}` around a `Postgrex.Error`), so match the rendered
  # text rather than trying to pattern-match a nesting we do not control.
  defp explain_if_undefined_column(text) do
    if String.contains?(text, "42703") do
      Mix.shell().error("""

      ❌ The application could not start: a query named a column the database
         has not got. The schema modules in this release are ahead of the
         database — a migration is pending, not a bug in the app.

         Migrate without starting the application, then run the doctor again:

             mix phoenix_kit.update --no-start
             mix phoenix_kit.doctor
      """)
    end

    :ok
  end

  defp header(title) do
    IO.puts("\n#{IO.ANSI.bright()}#{IO.ANSI.cyan()}#{title}#{IO.ANSI.reset()}")
    IO.puts(String.duplicate("─", 60))
  end

  defp run_check(name, fun) do
    result =
      try do
        fun.()
      rescue
        e -> {:fail, "Exception: #{Exception.message(e)}"}
      end

    display_check(name, result)
    {name, result}
  end

  defp display_check(name, {:pass, detail}) do
    IO.puts("  #{IO.ANSI.green()}PASS#{IO.ANSI.reset()} #{name}")
    if detail, do: IO.puts("       #{IO.ANSI.faint()}#{detail}#{IO.ANSI.reset()}")
  end

  defp display_check(name, {:warn, detail}) do
    IO.puts("  #{IO.ANSI.yellow()}WARN#{IO.ANSI.reset()} #{name}")
    if detail, do: IO.puts("       #{IO.ANSI.yellow()}#{detail}#{IO.ANSI.reset()}")
  end

  defp display_check(name, {:fail, detail}) do
    IO.puts("  #{IO.ANSI.red()}FAIL#{IO.ANSI.reset()} #{name}")
    if detail, do: IO.puts("       #{IO.ANSI.red()}#{detail}#{IO.ANSI.reset()}")
  end

  defp summary(results) do
    pass = Enum.count(results, fn {_, {status, _}} -> status == :pass end)
    warn = Enum.count(results, fn {_, {status, _}} -> status == :warn end)
    fail = Enum.count(results, fn {_, {status, _}} -> status == :fail end)
    total = length(results)

    IO.puts(
      "#{IO.ANSI.bright()}Summary#{IO.ANSI.reset()}: #{pass}/#{total} passed, #{warn} warnings, #{fail} failures"
    )

    if fail > 0 do
      IO.puts(
        "#{IO.ANSI.red()}Fix the FAIL items above before running migrations.#{IO.ANSI.reset()}"
      )
    end
  end
end
