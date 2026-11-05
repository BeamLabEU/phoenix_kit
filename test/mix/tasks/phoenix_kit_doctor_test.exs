defmodule Mix.Tasks.PhoenixKit.DoctorTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Doctor, as: DoctorTask

  # `run/1` isn't a unit-test seam (starts the app, needs a real DB) — same
  # reasoning as `Mix.Tasks.PhoenixKit.StatusTest` and
  # `Mix.Tasks.PhoenixKit.RepairTest`: exercise the pure decision the task
  # makes. Here that decision is what `--exit-code` reports to a deploy script.

  describe "daisyui_outdated_message/4" do
    # `String.capitalize/1` lowercases everything after the first letter, which
    # turned the product's name into "Vendored daisyui" and "Daisyui dependency".
    test "keeps the product's name as it is written, for either copy and severity" do
      for severity <- [:broken, :behind], source <- [:vendored, :dep] do
        message = DoctorTask.daisyui_outdated_message(severity, "5.0.0", "5.6.0", source)

        assert message =~ "daisyUI"
        refute message =~ "Daisyui"
        refute message =~ "daisyui is"
      end
    end

    test "names the copy the host actually has" do
      assert DoctorTask.daisyui_outdated_message(:behind, "5.0.0", "5.6.0", :dep) =~
               "daisyUI dependency (deps/daisyui) is 5.0.0"

      assert DoctorTask.daisyui_outdated_message(:behind, "5.0.0", "5.6.0", :vendored) =~
               "vendored daisyUI is 5.0.0"
    end
  end

  describe "exit_code/1 — only a FAIL gates the run" do
    test "all passing → 0" do
      assert DoctorTask.exit_code([
               {"Repo Detection", {:pass, "PhoenixKit.Repo"}},
               {"DB Connectivity", {:pass, "PostgreSQL 16.2"}}
             ]) == 0
    end

    test "no checks at all → 0" do
      assert DoctorTask.exit_code([]) == 0
    end

    test "any failure → 1" do
      assert DoctorTask.exit_code([
               {"Repo Detection", {:pass, "PhoenixKit.Repo"}},
               {"Module Schema Versions", {:fail, "Behind: Boards V01 (code expects V02)"}},
               {"Update Mode", {:pass, "update_mode=false"}}
             ]) == 1
    end

    test "warnings alone never fail the run" do
      # Deliberate, and the reason the flag is usable at all: several warnings
      # fire on healthy installs — a pool capped by update_mode, an
      # application.ex the child-order check could not locate. Gating on them
      # would make --exit-code permanently red, which is how a task ends up
      # back at "reports a problem and exits 0".
      assert DoctorTask.exit_code([
               {"Pool Configuration", {:warn, "pool_size=2 is very low."}},
               {"Child Start Order", {:warn, "Couldn't locate your application.ex"}},
               {"Update Mode", {:warn, "update_mode=true"}}
             ]) == 0
    end

    test "a failure mixed among warnings still fails" do
      assert DoctorTask.exit_code([
               {"Pool Configuration", {:warn, "pool_size=2 is very low."}},
               {"Schema Drift", {:fail, "3 columns missing"}},
               {"Update Mode", {:warn, "update_mode=true"}}
             ]) == 1
    end

    test "an exception inside a check is a FAIL and gates too" do
      # `run_check/2` rescues into {:fail, "Exception: ..."}, so a crashed check
      # must not be able to pass a deploy.
      assert DoctorTask.exit_code([
               {"Orphaned FK References", {:fail, "Exception: connection not available"}}
             ]) == 1
    end
  end

  defmodule ScheduledWorker do
    use Oban.Worker, queue: :scheduled_jobs

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule DefaultQueueWorker do
    # No `queue:` — Oban.Job's own "default" applies.
    use Oban.Worker

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  describe "module_schema_versions_result/1 — an ahead-of-code module must not read as a clean bill of health" do
    test "no modules → pass" do
      assert DoctorTask.module_schema_versions_result([]) ==
               {:pass, "No installed module owns migrations."}
    end

    test "every module current → pass" do
      modules = [module_entry("Boards", 1, 1, :up_to_date)]

      assert DoctorTask.module_schema_versions_result(modules) ==
               {:pass, "1 module(s), all at the version their code expects."}
    end

    test "a pending module → fail" do
      modules = [module_entry("Inbox", 1, 2, :needs_update)]

      assert {:fail, message} = DoctorTask.module_schema_versions_result(modules)
      assert message =~ "Behind: Inbox V1 (code expects V2)"
    end

    # This is the regression: an ahead-of-code module is neither pending nor
    # failed, and previously fell through to the same `:pass` a healthy
    # install gets — the same "reports healthy" defect this whole fix exists
    # to remove, just one layer up.
    test "an ahead-of-code module alone → warn, never pass" do
      modules = [module_entry("Inbox", 3, 2, :ahead_of_code)]

      assert {:warn, message} = DoctorTask.module_schema_versions_result(modules)
      assert message =~ "Ahead of code: Inbox V3 (code expects V2)"
    end

    test "an unreadable module alone → warn" do
      modules = [error_module_entry("Broken")]

      assert {:warn, message} = DoctorTask.module_schema_versions_result(modules)
      assert message =~ "Version unreadable for Broken"
    end

    # Pending, unreadable, and ahead-of-code are not alternatives — one run
    # can hold all three, and `:fail` (the actionable one) must not swallow
    # the other two silently.
    test "pending, unreadable, and ahead-of-code together → fail names all three" do
      modules = [
        module_entry("Behind", 1, 2, :needs_update),
        error_module_entry("Broken"),
        module_entry("Rollback", 3, 2, :ahead_of_code)
      ]

      assert {:fail, message} = DoctorTask.module_schema_versions_result(modules)
      assert message =~ "Behind: Behind V1 (code expects V2)"
      assert message =~ "version unreadable for Broken"
      assert message =~ "ahead of code: Rollback V3 (code expects V2)"
    end
  end

  describe "check_cron_queues/1 — a crontab entry with no queue to run it" do
    test "warns when a crontab worker's queue is not configured" do
      # PhoenixKit's own 2025-12-28 → 1.7.63 bug, reproduced: the entry fires
      # every minute, the queue it declares is absent, so each tick inserts a
      # job that stays :available forever.
      config = [
        queues: [default: 10],
        plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
      ]

      assert {:warn, message} = DoctorTask.check_cron_queues(config)
      assert message =~ "ScheduledWorker"
      assert message =~ "scheduled_jobs"
    end

    test "passes once the queue is configured" do
      config = [
        queues: [default: 10, scheduled_jobs: 1],
        plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
      ]

      assert {:pass, _} = DoctorTask.check_cron_queues(config)
    end

    test "a worker declaring no queue is checked against 'default', not skipped" do
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [emails: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", DefaultQueueWorker}]}]
               )

      assert message =~ "default"

      assert {:pass, _} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", DefaultQueueWorker}]}]
               )
    end

    test "an entry's own queue opt overrides the worker's, as Oban resolves it" do
      # Cron merges the entry's opts over `worker.__opts__()`, so a worker
      # declaring an unconfigured queue is fine when the entry redirects it —
      # and reporting it would be a false positive.
      assert {:pass, _} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [
                   {Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker, queue: :default}]}
                 ]
               )
    end

    test "queues: false is a node that runs no jobs, not a misconfiguration" do
      # Web-only and test nodes turn queues off wholesale; every entry would
      # look orphaned. Warning there is a false positive by construction.
      assert {:pass, message} =
               DoctorTask.check_cron_queues(
                 queues: false,
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
               )

      assert message =~ "runs no queues"
    end

    test "plugins: false means there is no cron to check" do
      assert {:pass, message} =
               DoctorTask.check_cron_queues(queues: [default: 10], plugins: false)

      assert message =~ "plugins: false"
    end

    test "a module that is not an Oban worker is skipped rather than reported" do
      # A crontab can name something doctor's VM cannot load. Guessing would
      # report a healthy host as broken over a module we merely failed to
      # resolve.
      assert {:pass, _} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", NoSuchWorker.Nowhere}]}]
               )
    end

    test "no Cron plugin, no crontab, and no Oban config at all are all clean" do
      assert {:pass, _} = DoctorTask.check_cron_queues(queues: [default: 10], plugins: [])
      assert {:pass, _} = DoctorTask.check_cron_queues(nil)

      assert {:pass, _} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: []}]
               )
    end

    test "a top-level crontab: key is checked, not just the Cron plugin" do
      # Oban still accepts `crontab:` directly on the Oban config and promotes
      # it into a Cron plugin itself (Oban.Config.crontab_to_plugin/1). Reading
      # only `plugins:` reported a clean bill of health on exactly the config
      # this check exists to catch.
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 crontab: [{"* * * * *", ScheduledWorker}]
               )

      assert message =~ "ScheduledWorker"
    end

    test "entries from a second Cron plugin are not lost" do
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [
                   {Oban.Plugins.Cron, crontab: []},
                   {Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}
                 ]
               )

      assert message =~ "ScheduledWorker"
    end

    test "an empty queues list reads the same as queues: false" do
      # Oban's own docs: "Using an empty list or `false` prevents any queues
      # from starting on init." Treating them differently warned on one
      # spelling of a deliberate web-only node and passed the other.
      assert {:pass, message} =
               DoctorTask.check_cron_queues(
                 queues: [],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
               )

      assert message =~ "runs no queues"
    end

    test "testing mode is not a misconfiguration" do
      # `testing: :inline | :manual` makes Oban overwrite queues and plugins
      # with [] itself, so no cron fires and nothing can accumulate.
      for mode <- [:inline, :manual] do
        assert {:pass, message} =
                 DoctorTask.check_cron_queues(
                   testing: mode,
                   queues: [default: 10],
                   plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
                 )

        assert message =~ "testing mode"
      end

      # :disabled is the real default and must still be checked.
      assert {:warn, _} =
               DoctorTask.check_cron_queues(
                 testing: :disabled,
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
               )
    end

    test "the warning says what configuring the queue will release" do
      # Draining is not free: the first sweep publishes every overdue
      # scheduled post and sends every overdue broadcast. A host that reads
      # only "add the queue" gets that as a surprise.
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [default: 10],
                 plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", ScheduledWorker}]}]
               )

      assert message =~ "backlog"
      assert message =~ "cancel_all_jobs"
    end

    test "every offending worker is named, not just the first" do
      assert {:warn, message} =
               DoctorTask.check_cron_queues(
                 queues: [emails: 10],
                 plugins: [
                   {Oban.Plugins.Cron,
                    crontab: [
                      {"* * * * *", ScheduledWorker},
                      {"0 3 * * *", DefaultQueueWorker}
                    ]}
                 ]
               )

      assert message =~ "ScheduledWorker"
      assert message =~ "DefaultQueueWorker"
    end
  end

  describe "integration_key_result/2 — the verdict is total over the signal space" do
    alias PhoenixKit.Integrations.Encryption
    alias PhoenixKit.Test.KeyVerdictInvariants, as: Invariants

    @location "/srv/keys/app.key"

    # The SYNTHETIC space: every combination of signal values, reachable or not.
    # What it proves is totality — the verdict renders anything it is handed
    # without contradicting itself — and that is all it can prove. It enumerates
    # our idea of the states, so a defect in the idea is invisible to it, which
    # is exactly what happened: 60 green combinations while a real configuration
    # rendered advice naming a variable the operator does not have.
    #
    # The invariants themselves live in `PhoenixKit.Test.KeyVerdictInvariants`
    # because the REAL space in `PhoenixKit.Integrations.EncryptionTest` has to
    # check the same ones, and two copies drift.
    test "no rendering contradicts the signals it was built from, anywhere in the space" do
      space = Invariants.synthetic_space()

      # If this number moves, a signal gained a value and every assertion below
      # silently covers less than it claims.
      assert length(space) == 90

      for signals <- space, do: Invariants.assert_consistent(signals, inspect(signals))
    end

    test "a fingerprint never appears without the tier that produced it" do
      for signals <- Invariants.synthetic_space(), signals.fingerprint != :none do
        report = Encryption.key_report(signals)
        {_status, detail} = DoctorTask.integration_key_result(report, true)

        case report.fingerprint do
          {:ok, value, _tier} -> assert detail =~ ~r/Fingerprint #{value} \(.+\)/
          :none -> refute detail =~ "Fingerprint"
        end
      end
    end

    # The two absences the design keeps apart, because the advice is opposite.
    test "an empty store is told to fill it; an absent one is told to set one up" do
      empty =
        %{
          enabled?: true,
          tier: :none,
          rejected_key: false,
          store: {:no_secret_yet, @location},
          fingerprint: :none
        }

      absent = %{empty | store: :absent}

      {_s1, filled} = DoctorTask.integration_key_result(Encryption.key_report(empty), false)
      {_s2, missing} = DoctorTask.integration_key_result(Encryption.key_report(absent), false)

      assert filled =~ "holds no secret yet"
      assert filled =~ "rotation cannot help"
      assert filled =~ @location
      assert missing =~ "Configure integrations_encryption_key"
      refute missing =~ @location
    end

    # The state the clause ORDER got wrong: a valid key in config while the
    # store is broken. Encryption is working; only the spare copy is not.
    # Reproduced against the real resolution before it was fixed, where it
    # reported the legacy tier.
    test "a configured key with a broken store is not reported as a fallback" do
      signals = %{
        enabled?: true,
        tier: :dedicated,
        rejected_key: false,
        store: {:unreadable, @location},
        fingerprint: {:ok, "abc123def456"}
      }

      report = Encryption.key_report(signals)
      {status, detail} = DoctorTask.integration_key_result(report, true)

      assert report.diagnosis == {:dedicated, :store_unreadable}
      assert status == :warn
      refute detail =~ "fell back"
      refute detail =~ "FALLBACK"
      assert detail =~ "dedicated encryption key is in use"
      assert detail =~ "(dedicated key)"
      assert detail =~ @location
    end
  end

  describe "git_hooks_verdict/1 — 'not installed' and 'could not check' are different answers" do
    @ok %{
      repo: {:ok, "/repo/.git"},
      hooks_path: {:ok, ".githooks"},
      pre_commit_executable: :yes,
      tracked?: true,
      shadow: :none
    }

    test "enabled, tracked, no leftover → pass" do
      assert {:pass, _} = DoctorTask.git_hooks_verdict(@ok)
    end

    test "core.hooksPath unset → warns, and says exactly how to fix it" do
      {status, detail} = DoctorTask.git_hooks_verdict(%{@ok | hooks_path: :unset})
      assert status == :warn
      assert detail =~ "NOT running"
      assert detail =~ "git config core.hooksPath .githooks"
    end

    # `.githooks` is not privileged: any directory with an executable
    # `pre-commit` in it passes, exactly like `.githooks` does above.
    test "pointing somewhere else, with an executable pre-commit there → pass" do
      verdict =
        DoctorTask.git_hooks_verdict(%{
          @ok
          | hooks_path: {:ok, "/root/.laisk-hooks"},
            pre_commit_executable: :yes
        })

      assert {:pass, _} = verdict
    end

    test "pointing somewhere else, with NO executable pre-commit there → warns and names where" do
      {status, detail} =
        DoctorTask.git_hooks_verdict(%{
          @ok
          | hooks_path: {:ok, "hooks"},
            pre_commit_executable: :no
        })

      assert status == :warn
      assert detail =~ ~s("hooks")
      assert detail =~ "no executable pre-commit"
    end

    test "pointing somewhere else, but could not tell if pre-commit is there → warns, refuses to guess" do
      {status, detail} =
        DoctorTask.git_hooks_verdict(%{
          @ok
          | hooks_path: {:ok, "/some/dir"},
            pre_commit_executable: :unknown
        })

      assert status == :warn
      assert detail =~ ~s("/some/dir")
      assert detail =~ "NOT the same"
      refute detail =~ "Fix:"
    end

    test "tracked hook missing from the checkout → warns about that, not about config" do
      {status, detail} = DoctorTask.git_hooks_verdict(%{@ok | tracked?: false})
      assert status == :warn
      assert detail =~ ".githooks/pre-commit is missing"
    end

    test "leftover hook in the common dir → warns it is dead code" do
      {status, detail} =
        DoctorTask.git_hooks_verdict(%{@ok | shadow: {:ok, "/repo/.git/hooks/pre-commit"}})

      assert status == :warn
      assert detail =~ "/repo/.git/hooks/pre-commit"
      assert detail =~ "Delete it"
    end

    # The whole reason this check exists in this shape. A check that answers
    # "not installed" when it merely failed to look is confidently wrong, and
    # sends the reader to fix something that is not broken.
    test "not a git repo → says it could not check, and refuses to call it 'not installed'" do
      {status, detail} = DoctorTask.git_hooks_verdict(%{@ok | repo: :unknown})
      assert status == :warn
      assert detail =~ "Could not check"
      assert detail =~ "NOT the same"
      refute detail =~ "git config core.hooksPath .githooks"
    end

    test "core.hooksPath unreadable → same refusal to guess" do
      {status, detail} = DoctorTask.git_hooks_verdict(%{@ok | hooks_path: :unknown})
      assert status == :warn
      assert detail =~ "unknown whether the hook runs"
      refute detail =~ "Fix:"
    end

    test "an unreadable config and an unset one do not produce the same message" do
      {_, could_not_check} = DoctorTask.git_hooks_verdict(%{@ok | hooks_path: :unknown})
      {_, definitely_off} = DoctorTask.git_hooks_verdict(%{@ok | hooks_path: :unset})

      refute could_not_check == definitely_off
    end

    test "enabled but the leftover check itself failed → says so rather than passing" do
      {status, detail} = DoctorTask.git_hooks_verdict(%{@ok | shadow: :unknown})
      assert status == :warn
      assert detail =~ "could not check for a stale copy"
    end
  end

  # The filesystem-facing half of the Git Hooks check: does the directory
  # `core.hooksPath` names actually have an executable `pre-commit` in it?
  # Absolute paths only — a relative one is resolved against `File.cwd!()`,
  # and changing cwd to prove that would not be safe under `async: true`
  # (cwd is a process-wide OS attribute, not scoped to the test process).
  describe "pre_commit_executable?/1 — the property git_hooks_verdict/1 relies on" do
    test "an executable file named pre-commit → :yes" do
      dir = tmp_dir!()
      write_executable!(dir, "pre-commit", "#!/bin/sh\nexit 0\n")

      assert DoctorTask.pre_commit_executable?(dir) == :yes
    end

    test "a pre-commit file that exists but is NOT executable → :no" do
      dir = tmp_dir!()
      path = Path.join(dir, "pre-commit")
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o644)

      assert DoctorTask.pre_commit_executable?(dir) == :no
    end

    test "no pre-commit file at all → :no, not :unknown" do
      dir = tmp_dir!()
      assert DoctorTask.pre_commit_executable?(dir) == :no
    end

    test "the whole directory does not exist → :no" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "pk_doctor_hooks_missing_#{System.unique_integer([:positive])}"
        )

      refute File.exists?(dir)

      assert DoctorTask.pre_commit_executable?(dir) == :no
    end

    test "pre-commit exists but is a directory, not a file → :no" do
      dir = tmp_dir!()
      File.mkdir_p!(Path.join(dir, "pre-commit"))

      assert DoctorTask.pre_commit_executable?(dir) == :no
    end
  end

  describe "classify_fk_check/5 — a probe failure must never read as clean" do
    test "a failed orphan-count probe lands in the probe_failed bucket, not the clean path" do
      acc = {[], [], []}

      assert {[], [], [{"t", "c", "r", :orphan_count, "boom", nil}]} =
               DoctorTask.classify_fk_check(
                 "t",
                 "c",
                 "r",
                 {:probe_failed, "boom"},
                 :validated,
                 acc
               )
    end

    test "a failed validation-state probe lands in the probe_failed bucket too" do
      acc = {[], [], []}

      assert {[], [], [{"t", "c", "r", :validation_state, "no access", 0}]} =
               DoctorTask.classify_fk_check(
                 "t",
                 "c",
                 "r",
                 {:ok, 0},
                 {:probe_failed, "no access"},
                 acc
               )
    end

    test "a failed validation-state probe preserves the measured orphan count" do
      # The orphan-count probe already succeeded here — 5 real orphaned rows
      # were measured — and it is only the SEPARATE validation-state probe
      # that failed. Before this fix, the measured count was discarded and
      # the caller could only ever print "could not check", losing the exact
      # number the whole section exists to report.
      acc = {[], [], []}

      assert {[], [], [{"t", "c", "r", :validation_state, "no access", 5}]} =
               DoctorTask.classify_fk_check(
                 "t",
                 "c",
                 "r",
                 {:ok, 5},
                 {:probe_failed, "no access"},
                 acc
               )
    end

    test "a probe failure wins even when the orphan count would otherwise be clean" do
      # Both reads must succeed for the old empty-accumulator ("nothing to
      # report") path to apply — one failing is enough to route to
      # probe_failed regardless of what the other read said.
      acc = {[], [], []}

      assert {[], [], [_]} =
               DoctorTask.classify_fk_check(
                 "t",
                 "c",
                 "r",
                 {:probe_failed, "timeout"},
                 :absent,
                 acc
               )
    end

    test "known-good inputs still classify the same as before this fix" do
      assert {[{"t", "c", "r", 3, :validate}], [], []} =
               DoctorTask.classify_fk_check(
                 "t",
                 "c",
                 "r",
                 {:ok, 3},
                 {:not_valid, "fk_x"},
                 {[], [], []}
               )

      assert {[], [{"t", "c", "r"}], []} =
               DoctorTask.classify_fk_check(
                 "t",
                 "c",
                 "r",
                 {:ok, 0},
                 {:not_valid, "fk_x"},
                 {[], [], []}
               )

      assert {[], [], []} =
               DoctorTask.classify_fk_check("t", "c", "r", {:ok, 0}, :validated, {[], [], []})
    end
  end

  describe "classify_fk_check/5 — a VALID constraint with real orphans must not be discarded" do
    test "count > 0 with :validated lands in orphaned as :existing_orphan, not the clean catch-all" do
      # Before this clause, `{:ok, count > 0}` paired with `:validated` fell
      # through to the generic catch-all (`{orph, nv, pf} -> acc`, no change)
      # — the exact shape a destructive orphan on an already-VALID constraint
      # takes, since `probe_fk/4` only ever produces `:validated` or
      # `{:not_valid, _}`, never `:absent`. Confirmed live against a real
      # orphan planted via disabled triggers in
      # `phoenix_kit_doctor_orphaned_fk_test.exs`.
      assert {[{"t", "c", "r", 3, :existing_orphan}], [], []} =
               DoctorTask.classify_fk_check("t", "c", "r", {:ok, 3}, :validated, {[], [], []})
    end

    test "an existing_orphan does not clobber unrelated entries already in the accumulator" do
      acc =
        {[{"other", "col", "ref2", 1, :create}], [{"t2", "c2", "r2"}],
         [{"t3", "c3", "r3", :orphan_count, "x", nil}]}

      # Decomposed rather than matched as one inline tuple: that pattern sat
      # exactly on the formatter's line-break threshold, and Elixir 1.18 and
      # 1.19 break it differently, so `mix format --check-formatted` failed
      # on whichever version had not last written the file (mix.exs allows
      # `~> 1.18`, so both are in scope). These lines are short enough that
      # no version has a choice to make.
      assert {orphaned, not_validated, probe_failed} =
               DoctorTask.classify_fk_check("t", "c", "r", {:ok, 5}, :validated, acc)

      assert orphaned == [
               {"t", "c", "r", 5, :existing_orphan},
               {"other", "col", "ref2", 1, :create}
             ]

      assert not_validated == [{"t2", "c2", "r2"}]
      assert probe_failed == [{"t3", "c3", "r3", :orphan_count, "x", nil}]
    end
  end

  describe "report_orphaned_fk_refs/4 — a probe failure is its own tier, not the same red as real orphans" do
    test "probe_failed alone (no orphans, no known-unvalidated) is :warn, not :fail — a third tier" do
      # Before this fix this was :fail — the same red as confirmed broken
      # data, even though nothing is actually broken. Coverage being
      # incomplete is "investigate why", not "fix corrupted data"; only real
      # orphans (below) still earn the red.
      probe_failed = [
        {"phoenix_kit_users_tokens", "user_uuid", "phoenix_kit_users", :orphan_count, "boom", nil}
      ]

      assert {:warn, message} = DoctorTask.report_orphaned_fk_refs([], [], probe_failed, 4)
      assert message =~ "Could not check 1 of 4"
      assert message =~ "not the same as clean"
      assert message =~ "boom"
    end

    test "a validation-state probe failure reports the measured orphan count, not just 'could not check'" do
      probe_failed = [
        {"phoenix_kit_users_tokens", "user_uuid", "phoenix_kit_users", :validation_state,
         "no access", 5}
      ]

      assert {:warn, message} = DoctorTask.report_orphaned_fk_refs([], [], probe_failed, 1)
      assert message =~ "5 orphaned row"
      assert message =~ "no access"
    end

    test "no findings at all is still :pass, and now names the coverage" do
      assert {:pass, message} = DoctorTask.report_orphaned_fk_refs([], [], [], 231)
      assert message =~ "checked 231 of 231"
    end

    test "orphans alone still :fail — real data damage always wins the color" do
      orphaned = [{"phoenix_kit_users_tokens", "user_uuid", "phoenix_kit_users", 2, :validate}]

      assert {:fail, message} = DoctorTask.report_orphaned_fk_refs(orphaned, [], [], 4)
      assert message =~ "2 orphaned row"
    end

    test "orphans found AND a separate probe failure — still :fail, but the coverage gap is still surfaced" do
      orphaned = [{"phoenix_kit_users_tokens", "user_uuid", "phoenix_kit_users", 2, :validate}]

      probe_failed = [
        {"other_table", "other_col", "other_ref", :orphan_count, "boom", nil}
      ]

      assert {:fail, message} = DoctorTask.report_orphaned_fk_refs(orphaned, [], probe_failed, 5)
      assert message =~ "2 orphaned row"
      assert message =~ "boom"
      assert message =~ "checked 4 of 5"
    end

    test "not_validated alone (nothing blocking) is still :warn, and names the coverage" do
      not_validated = [{"phoenix_kit_users_tokens", "user_uuid", "phoenix_kit_users"}]

      assert {:warn, message} = DoctorTask.report_orphaned_fk_refs([], not_validated, [], 1)
      assert message =~ "checked 1 of 1"
    end
  end

  describe "fk_probe_failure_reason/1 — a timed-out probe says so, not a raw Postgres error" do
    test "a query_canceled Postgrex error becomes a time-limit message" do
      reason = %Postgrex.Error{postgres: %{code: :query_canceled, message: "canceling statement"}}

      assert DoctorTask.fk_probe_failure_reason(reason) =~ "time limit exceeded"
      assert DoctorTask.fk_probe_failure_reason(reason) =~ "not checked, not clean"
    end

    test "a pool-closed DBConnection.ConnectionError becomes a time-limit message too" do
      # Verified live (not assumed): `repo.query/3` with a `:timeout` — the
      # exact call `probe_fk/4` makes, through the DBConnection
      # pool/ownership layer — does not reliably surface as
      # `%Postgrex.Error{postgres: %{code: :query_canceled}}}`. Depending on
      # whether Postgres acknowledges the cancel before DBConnection's own
      # grace period expires, the SAME timeout can instead surface as
      # DBConnection tearing down the connection itself. Before this fix,
      # this shape fell through to the generic `reason` clause and printed a
      # raw "tcp recv: closed" pool message instead of "time limit exceeded".
      reason = %DBConnection.ConnectionError{reason: :closed, message: "tcp recv: closed"}

      assert DoctorTask.fk_probe_failure_reason(reason) =~ "time limit exceeded"
      assert DoctorTask.fk_probe_failure_reason(reason) =~ "not checked, not clean"
    end

    test "a DBConnection.ConnectionError for a different reason passes through unchanged" do
      # Only `:closed` is treated as a timeout — `:queue_timeout` (the pool
      # itself has no free connection to hand out) is a different failure and
      # must not be relabeled as "time limit exceeded".
      reason = %DBConnection.ConnectionError{reason: :queue_timeout, message: "queue timeout"}

      assert DoctorTask.fk_probe_failure_reason(reason) == reason
    end

    test "any other error reason passes through unchanged" do
      assert DoctorTask.fk_probe_failure_reason(:some_other_error) == :some_other_error
    end
  end

  # -------------------------------------------------------------------
  # helpers
  # -------------------------------------------------------------------

  defp tmp_dir! do
    dir =
      Path.join(System.tmp_dir!(), "pk_doctor_hooks_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write_executable!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
  end

  # Shape mirrors `PhoenixKit.Migrations.Modules.list/1` entries — same
  # helper shape used by `PhoenixKit.Migrations.ModulesTest`.
  defp module_entry(name, installed, target, status) do
    %{
      name: name,
      module: SomeModule,
      migration_module: SomeModule.Migrations,
      installed: installed,
      target: target,
      status: status,
      error: nil
    }
  end

  defp error_module_entry(name) do
    %{
      name: name,
      module: SomeModule,
      migration_module: SomeModule.Migrations,
      installed: 0,
      target: nil,
      status: :error,
      error: "relation does not exist"
    }
  end
end
