# Igniter-only helper: every caller is a `mix phoenix_kit.*` igniter task,
# which is itself guarded the same way. Igniter is an OPTIONAL dependency
# (see mix.exs), so a host that scopes it to `only: [:dev, :test]` compiles
# :prod without it — unguarded, this module emitted a wall of
# "Igniter.X is undefined" warnings on every production build.
if Code.ensure_loaded?(Igniter) do
  defmodule PhoenixKit.Install.ObanConfig do
    @moduledoc """
    Handles Oban configuration for PhoenixKit installation.

    This module provides functionality to:
    - Configure Oban for background job processing
    - Set up required queues (default, file_processing)
    - Add Oban.Plugins.Pruner for job cleanup
    - Add Oban to application supervisor tree
    - Ensure configuration exists during updates
    """
    use PhoenixKit.Install.IgniterCompat

    # Mix functions only available at compile-time during installation
    @dialyzer {:nowarn_function, update_existing_oban_config: 3}
    @dialyzer {:nowarn_function, ensure_queue: 4}
    @dialyzer {:nowarn_function, ensure_declared_queues: 3}
    @dialyzer {:nowarn_function, insert_queue: 4}
    @dialyzer {:nowarn_function, ensure_scheduled_jobs_queue: 2}
    @dialyzer {:nowarn_function, ensure_cron_plugin: 2}
    @dialyzer {:nowarn_function, ensure_digest_cron_entries: 2}
    @dialyzer {:nowarn_function, add_digest_entries_to_crontab: 3}
    @dialyzer {:nowarn_function, ensure_worker_cron_entries: 2}
    @dialyzer {:nowarn_function, add_worker_entries_to_crontab: 3}
    @dialyzer {:nowarn_function, ensure_pruner_max_age: 2}
    @dialyzer {:nowarn_function, ensure_lifeline_plugin: 2}
    @dialyzer {:nowarn_function, maybe_raise_lifeline_rescue_after: 1}
    @dialyzer {:nowarn_function, add_cron_plugin_to_plugins: 2}
    @dialyzer {:nowarn_function, queue_manual_notice: 3}
    @dialyzer {:nowarn_function, lifeline_manual_notice: 1}
    @dialyzer {:nowarn_function, scheduled_posts_job_manual_notice: 0}
    @dialyzer {:nowarn_function, worker_entries_manual_notice: 2}
    @dialyzer {:nowarn_function, digest_entries_manual_notice: 2}
    @dialyzer {:nowarn_function, cron_plugin_manual_notice: 1}
    @dialyzer {:nowarn_function, pruner_manual_notice: 0}
    @dialyzer {:nowarn_function, apply_pruner_max_age: 2}

    alias Igniter.Libs.Phoenix
    alias Igniter.Project.Application
    alias PhoenixKit.Install.ConfigVerify
    alias PhoenixKit.Install.IgniterHelpers

    # Lifeline rescues purely by elapsed time, with no check that the node
    # executing the job is still alive, so rescue_after must stay above the
    # longest job a host can legitimately run or that job is rescued mid-flight
    # and executes a second time concurrently. 60 minutes is Oban's own default;
    # 30 is the longest timeout/1 PhoenixKit itself ships
    # (Storage.Jobs.Reconcile), and is therefore the floor below which an
    # existing entry gets raised rather than left alone.
    @lifeline_rescue_after_minutes 60
    @lifeline_min_rescue_after_minutes 30

    @doc """
    Adds or verifies Oban configuration.

    This function ensures that Oban is properly configured for PhoenixKit's
    background job processing, including:
    1. Repo configuration (auto-detected from PhoenixKit config)
    2. Required queues for file processing
    3. Pruner plugin for automatic job cleanup

    ## Parameters
    - `igniter` - The igniter context

    ## Returns
    Updated igniter with Oban configuration and notices.
    """
    def add_oban_configuration(igniter, prefix \\ nil) do
      igniter
      |> add_oban_config(prefix)
      |> maybe_warn_missing_oban_prefix(prefix)
      |> add_oban_configuration_notice()
    end

    @doc """
    Whether the given config content has a `config :app, Oban` block that
    lacks a `prefix:` key.

    Scoped to the Oban block on purpose: a whole-file scan is defeated by
    the `config :phoenix_kit, prefix: "..."` entry (which matches a naive
    `prefix:` grep) and false-positives on unrelated config. Any `prefix:`
    inside the block counts — including computed values like
    `System.get_env(...)`. Returns false when the content has no Oban
    block at all (nothing to judge).
    """
    @spec oban_block_missing_prefix?(String.t()) :: boolean()
    def oban_block_missing_prefix?(content) when is_binary(content) do
      case Regex.scan(
             ~r/config\s+:\w+,\s+Oban\b(.*?)(?=\n(?:config\s|import_config\s)|\z)/s,
             strip_comment_lines(content)
           ) do
        [] -> false
        blocks -> Enum.all?(blocks, fn [_, body] -> not String.contains?(body, "prefix:") end)
      end
    end

    # Drops comment-only lines before block scanning — otherwise a
    # commented-out example Oban block can false-positive a "missing
    # prefix" warning for a file with no active block, or a commented block
    # that happens to mention `prefix:` can mask a genuinely unprefixed
    # active block (false negative, defeating the check).
    defp strip_comment_lines(content) do
      content
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
      |> Enum.join("\n")
    end

    # Existing Oban configs on a prefixed install must carry prefix: — the
    # migrations put oban_jobs into the named schema, and without the option
    # Oban looks for public.oban_jobs. add_oban_config only injects prefix:
    # into freshly generated blocks, so warn about pre-existing ones. Reads
    # from disk (the igniter buffer isn't flushed yet), which is exactly
    # right: a freshly generated block isn't on disk and produces no
    # false warning.
    defp maybe_warn_missing_oban_prefix(igniter, prefix) when prefix in [nil, "public"],
      do: igniter

    defp maybe_warn_missing_oban_prefix(igniter, prefix) do
      contents =
        ["config/config.exs", "config/runtime.exs"]
        |> Enum.filter(&File.exists?/1)
        |> Enum.map(&File.read!/1)

      has_block? = fn content ->
        Regex.match?(~r/config\s+:\w+,\s+Oban\b/, strip_comment_lines(content))
      end

      any_block = Enum.any?(contents, has_block?)

      any_block_with_prefix =
        Enum.any?(contents, fn content ->
          has_block?.(content) and not oban_block_missing_prefix?(content)
        end)

      if any_block and not any_block_with_prefix do
        Igniter.add_warning(igniter, """
        Your existing Oban config appears to lack this install's schema prefix.
        PhoenixKit's Oban tables live in the "#{prefix}" schema — add:

          config :your_app, Oban,
            prefix: "#{prefix}",
            ...
        """)
      else
        igniter
      end
    rescue
      _ -> igniter
    end

    @doc """
    Checks if Oban configuration exists in config.exs.

    ## Parameters
    - `igniter` - The igniter context for detecting parent app name

    ## Returns
    Boolean indicating if configuration exists.
    """
    def oban_config_exists?(igniter) do
      config_path = "config/config.exs"
      app_name = IgniterHelpers.get_parent_app_name(igniter)

      if File.exists?(config_path) do
        content = File.read!(config_path)
        lines = String.split(content, "\n")

        # Check for active (non-commented) Oban configuration with parent app namespace
        has_oban_config =
          Enum.any?(lines, fn line ->
            trimmed = String.trim(line)
            # Not a comment and contains config :app_name, Oban
            !String.starts_with?(trimmed, "#") and
              String.contains?(line, "config :#{app_name}, Oban")
          end)

        has_queues =
          Enum.any?(lines, fn line ->
            trimmed = String.trim(line)
            # Not a comment and contains queues:
            !String.starts_with?(trimmed, "#") and String.contains?(line, "queues:")
          end)

        has_oban_config and has_queues
      else
        false
      end
    rescue
      _ -> false
    end

    # Clean up broken Oban config syntax from previous failed updates
    # NOTE: Previously this function attempted to fix syntax issues with greedy
    # regexes, but they could corrupt valid commented config. The regexes have
    # been removed as they caused more harm than good. If syntax issues occur
    # from failed updates, they should be fixed manually or with more targeted
    # approaches.
    defp cleanup_oban_config_syntax do
      :ok
    end

    # Add Oban configuration to config.exs
    defp add_oban_config(igniter, prefix) do
      # First, clean up any broken syntax from previous failed updates
      cleanup_oban_config_syntax()

      # Get parent app name and repo
      app_name = IgniterHelpers.get_parent_app_name(igniter)
      repo_module = get_repo_module(igniter)

      # Prefixed installs put oban_jobs into the named schema (V27), so Oban
      # must be pointed at it — without this it looks for public.oban_jobs.
      prefix_line =
        if prefix in [nil, "public"] do
          ""
        else
          "\n  prefix: \"#{prefix}\","
        end

      oban_config = """

      # Configure Oban for PhoenixKit background jobs.
      # Queues come from PhoenixKit and the installed modules (their
      # `oban_queues/0` declarations); `mix phoenix_kit.update` adds any a
      # later module declares, and never changes a limit you set here.
      # Limits are per node.
      config :#{app_name}, Oban,
        repo: #{repo_module},#{prefix_line}
        queues: [
      #{generated_queue_lines()}
        ],
        plugins: [
          # Pruner: delete completed/discarded jobs after 30 days
          {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
          # Lifeline: rescue jobs orphaned in :executing by a hard crash
          # (BEAM kill -9, OOM, node failure) back to :available so they
          # run again — without it, an orphaned job sits stuck forever.
          # rescue_after MUST stay above your longest-running job: Lifeline
          # rescues purely by elapsed time, with no check that the node is
          # still alive, so a job that legitimately runs longer is rescued
          # mid-flight and executes a second time concurrently. 60 minutes
          # is Oban's own default and 2x PhoenixKit's longest worker
          # timeout (Storage.Jobs.Reconcile, 30 min).
          #{lifeline_entry()},
          {Oban.Plugins.Cron,
           crontab: [
             {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker},
             {"0 3 * * *", PhoenixKit.Modules.Storage.Workers.PruneTrashJob},
             {"0 4 * * *", PhoenixKit.Notifications.PruneWorker},
             {"30 4 * * *", PhoenixKit.Users.Referrals.PruneWorker},
             {"45 4 * * *", PhoenixKit.Users.LoginAttemptsPruneWorker},
             {"*/5 * * * *", PhoenixKit.Jobs.SweepWorker},
             {"15 4 * * *", PhoenixKit.Jobs.PruneWorker},
             {"20 4 * * *", PhoenixKit.Modules.Storage.Workers.BucketLogPruneWorker},
             {"0 * * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "hourly"}},
             {"0 */12 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "12h"}},
             {"0 6 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "daily"}},
             {"0 6 * * 1", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "weekly"}}
           ]}
        ]
      """

      try do
        Igniter.update_file(igniter, "config/config.exs", fn source ->
          content = Rewrite.Source.get(source, :content)

          # Check if Oban config already exists (with more robust detection)
          if oban_config_already_exists?(content, app_name) do
            # Update existing config to add posts queue and cron plugin
            update_existing_oban_config(source, content, app_name)
          else
            # Find insertion point before import_config statements
            insertion_point = find_import_config_location(content)

            updated_content =
              case insertion_point do
                {:before_import, before_content, after_content} ->
                  # Insert before import_config
                  before_content <> oban_config <> "\n" <> after_content

                :append_to_end ->
                  # No import_config found, append to end
                  content <> oban_config
              end

            Rewrite.Source.update(source, :content, updated_content)
          end
        end)
      rescue
        e ->
          IO.warn("Failed to add Oban configuration: #{inspect(e)}")
          add_manual_config_notice(igniter, repo_module)
      end
    end

    # Update existing Oban configuration to add posts/sitemap queues and cron plugin
    defp update_existing_oban_config(source, content, app_name) do
      Mix.shell().info("🔍 Updating existing Oban configuration for :#{app_name}...")

      # Every queue PhoenixKit or an installed module declares
      # (`PhoenixKit.ObanQueues`) is added when missing — an idle queue costs
      # nothing, and the reverse is the failure this exists to prevent: Oban
      # only fetches for queues the node lists, so a job enqueued into a
      # missing queue sits `available` forever (Pruner deletes terminal states
      # only) while the feature looks fine. A limit already present is never
      # changed.
      updated_content =
        content
        |> ensure_declared_queues(app_name)
        |> ensure_cron_plugin(app_name)
        |> ensure_digest_cron_entries(app_name)
        |> ensure_worker_cron_entries(app_name)
        |> ensure_pruner_max_age(app_name)
        |> ensure_lifeline_plugin(app_name)

      if updated_content == content do
        Mix.shell().info(
          "✅ Oban configuration already up-to-date (queues, cron plugin, pruner max_age, and Lifeline present)"
        )
      else
        Mix.shell().info(
          "✅ Updated Oban configuration (queues, cron plugin, pruner retention, Lifeline)"
        )
      end

      Rewrite.Source.update(source, :content, updated_content)
    end

    @doc """
    Adds every declared queue (`PhoenixKit.ObanQueues.declared/1`) that a host's
    existing Oban block is missing.

    A block that runs no queues — `queues: false` or `queues: []`, a web-only
    node — is left exactly as it is, with one line saying so, rather than a
    "please add manually" error per queue. Conflicting declarations are
    reported, and the first one wins (PhoenixKit's own, then modules in a
    stable order).

    Public so it can be unit-tested against content strings; `declared` is
    injectable for the same reason.
    """
    @spec ensure_declared_queues(String.t(), atom() | String.t(), [map()] | nil) :: String.t()
    def ensure_declared_queues(content, app_name, declared \\ nil) do
      {declared, conflicts} =
        case declared do
          nil -> PhoenixKit.ObanQueues.resolve()
          list -> {list, []}
        end

      Enum.each(conflicts, fn conflict ->
        Mix.shell().error("  ⚠️  " <> PhoenixKit.ObanQueues.describe_conflict(conflict))
      end)

      if queues_disabled?(content, app_name) do
        Mix.shell().info(
          "  ℹ️  This node's Oban config runs no queues (queues: false or []); leaving it as is"
        )

        content
      else
        Enum.reduce(declared, content, fn spec, acc ->
          ensure_queue(acc, app_name, Atom.to_string(spec.name), spec.limit)
        end)
      end
    end

    @doc false
    # `queues: false`, `queues: []` — Oban's two spellings of "this node runs
    # no queues". Scoped to this app's Oban block, like `insert_queue/4`.
    def queues_disabled?(content, app_name) do
      case app_oban_block(content, app_name) do
        nil -> false
        # No start-of-line anchor: `config :app, Oban, repo: R, queues: false`
        # on one line is the same web-only node.
        block -> Regex.match?(~r/(?<![A-Za-z0-9_])queues:\s*(?:false\b|\[\s*\])/, block)
      end
    end

    @doc false
    # The queue lines of a freshly generated Oban block, one per declared
    # queue, with who asked for it. The comma goes BEFORE the comment — after
    # it, it would be part of the comment and the list would not parse.
    def generated_queue_lines(declared \\ PhoenixKit.ObanQueues.declared()) do
      last = length(declared) - 1

      declared
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {spec, index} ->
        comma = if index == last, do: "", else: ","
        "    #{spec.name}: #{spec.limit}#{comma}" <> queue_comment(spec)
      end)
    end

    defp queue_comment(%{owner: owner, kind: kind}) do
      who = PhoenixKit.ObanQueues.owner_label(owner)
      what = if kind, do: ", #{kind}", else: ""
      "   # #{who}#{what}"
    end

    # The one queue a host can be missing through no fault of its own.
    #
    # The ProcessScheduledJobsWorker crontab entry entered the generated config
    # on 2025-12-28 without the queue it runs in; the fresh-install block gained
    # `scheduled_jobs: 1` on 2026-03-05, released in 1.7.63. Every host that
    # installed in between got a per-minute cron entry firing into a queue
    # nothing runs, and no upgrade repaired it, because this is the upgrade path
    # and it had no helper for that queue — the other six queues did. One such
    # host was found 15 days in with 21,337 jobs stuck in :available, growing at
    # ~1,440/day, because Pruner only deletes terminal states.
    #
    @doc """
    Ensures the `scheduled_jobs` queue exists in a host's existing Oban config.

    Public for the same reason as `ensure_worker_cron_entries/2`: so it can be
    unit-tested directly against content strings.
    """
    @spec ensure_scheduled_jobs_queue(String.t(), atom() | String.t()) :: String.t()
    def ensure_scheduled_jobs_queue(content, app_name) do
      ensure_queue(content, app_name, "scheduled_jobs", 1)
    end

    @doc """
    Ensures `queue: limit` exists in a host's existing Oban `queues:` list.

    The shared implementation behind every `ensure_*_queue/2`. It was written
    for `scheduled_jobs` and generalised afterwards, because the six sibling
    helpers that predated it had each hand-rolled the same string surgery and
    reproduced the same six defects — and theirs are worse than the missing
    queue this repairs: a bad insert *corrupts* the host's `config.exs`.

    Public so it can be unit-tested directly against content strings.
    """
    @spec ensure_queue(String.t(), atom() | String.t(), String.t(), pos_integer()) :: String.t()
    def ensure_queue(content, app_name, queue, limit) do
      if queue_configured?(content, app_name, queue) do
        Mix.shell().info("  ℹ️  #{queue} queue already configured")
        content
      else
        Mix.shell().info("  ➕ Adding #{queue} queue to Oban configuration...")
        insert_queue(content, app_name, queue, limit)
      end
    end

    # Comment lines go before the check, for the same reason
    # `oban_block_missing_prefix?/1` strips them and with a sharper edge here:
    # the failure path below prints "Please manually add: <queue>: <limit>",
    # so the exact line a host pastes in as a reminder-to-self is what would
    # otherwise convince the next run the queue is already there — leaving it
    # broken forever, quietly.
    #
    # ANY value counts, not only a bare integer or `[`: the limit is the host's
    # to write, and hosts write `default: String.to_integer(System.get_env(…))`,
    # a module attribute, a variable. Reading those as "absent" appended a
    # second entry, and a duplicate key is not a compile error: it survives
    # into `Oban.Config.normalize_queues/1`, and `Oban.Midwife` asserts
    # `{:ok, _}` on start_queue, so the second start returns
    # `{:error, {:already_started, _}}` and the host does not boot. That
    # mattered less while the list held only PhoenixKit's own queue names; it
    # now includes `default`, the one queue nearly every host already tunes.
    #
    # The lookbehind is what stops `notifications:` from being satisfied by a
    # host's own `push_notifications: 5` — an unanchored pattern reads any key
    # *ending* in the queue's name as the queue itself and skips the insert,
    # which is the missing-queue failure all over again. It replaces a
    # start-of-line anchor, which missed the second entry of
    # `default: 10, mailers: 20` written on one line.
    #
    # Scoped to THIS app's Oban block: in a config holding several apps' Oban
    # blocks (an umbrella, a host that also runs a second instance), another
    # block listing the same queue used to make the updater skip it here — the
    # missing-queue failure again, for a queue that is plainly absent from this
    # app.
    defp queue_configured?(content, app_name, queue) do
      Regex.match?(
        ~r/(?<![A-Za-z0-9_])#{Regex.escape(queue)}:\s*\S/,
        app_oban_block(content, app_name) || strip_comment_lines(content)
      )
    end

    # The body of `config :app_name, Oban, ...` up to the next top-level
    # `config`/`import_config`, comment lines removed; nil when there is none.
    defp app_oban_block(content, app_name) do
      case Regex.run(
             ~r/^config\s+:#{app_name},\s+Oban\b((?:(?!\n(?:config\s|import_config\s)).)*)/ms,
             strip_comment_lines(content)
           ) do
        [_, block] -> block
        nil -> nil
      end
    end

    # Two ways string surgery on a queues list goes wrong, both already paid for
    # elsewhere in this file:
    #
    #   * stopping at a nested list's bracket rather than the queues list's own
    #     — `default: [limit: 10]` is legal, and inserting there produces an
    #     option Oban rejects at boot. `ensure_lifeline_plugin/2` documents the
    #     fix: anchor the closing `]` to the keyword's own indentation with a
    #     backreference, which nested entries are always indented past.
    #
    #   * running out of this app's Oban block entirely. An Oban block with no
    #     `queues:` at all let a lazy `.*?` walk into the next `config` entry
    #     and add the queue to an unrelated application. The block is bounded
    #     here by the next top-level `config`/`import_config`, the same boundary
    #     `oban_block_missing_prefix?/1` uses.
    #
    # An empty `queues: []` deliberately finds no match and takes the manual
    # path: Oban documents an empty list as equivalent to `false` — "prevents
    # any queues from starting on init" — so a node that says it runs no queues
    # should not silently be given one.
    defp insert_queue(content, app_name, queue, limit) do
      case Regex.run(
             ~r/(^config\s+:#{app_name},\s+Oban\b(?:(?!\n(?:config\s|import_config\s)).)*?\n([ \t]+)queues:\s*\[\n)(.*?)(\n\2\])/ms,
             content,
             capture: :all
           ) do
        [full_match, queues_open, indent, queues_content, queues_close] ->
          Mix.shell().info("  ✓ Found queues block, adding #{queue} queue")

          entry = "#{queue}: #{limit}"

          updated_queues =
            queues_open <> add_queue_entry(queues_content, indent <> "  ", entry) <> queues_close

          candidate = String.replace(content, full_match, updated_queues, global: false)
          queue_atom = String.to_atom(queue)

          case ConfigVerify.verify_or_rollback(
                 content,
                 candidate,
                 &keyword_list_has_key?(&1, :queues, queue_atom, limit)
               ) do
            {:ok, result} ->
              result

            {:rolled_back, original, _reason} ->
              queue_manual_notice(app_name, queue, limit)
              original
          end

        nil ->
          queue_manual_notice(app_name, queue, limit)
          content
      end
    end

    defp queue_manual_notice(app_name, queue, limit) do
      Mix.shell().error(
        "  ⚠️  Could not safely add #{queue} to the queues block for :#{app_name} " <>
          "(not found, or the insertion would have produced invalid or misplaced config)"
      )

      Mix.shell().error("     Please manually add: #{queue}: #{limit}")
    end

    # True if `ast` has a `root_key: [...]` list containing `{key, value}` or
    # `{key, [limit: value]}` — the two shapes Oban accepts for a queue entry,
    # and the shared check behind confirming a splice into any flat
    # `key: value`-style keyword list (queues here) actually landed.
    defp keyword_list_has_key?(ast, root_key, key, value) do
      ConfigVerify.keyword_list_satisfies?(ast, root_key, fn list ->
        Enum.any?(list, fn
          {^key, ^value} ->
            true

          {^key, kw} when is_list(kw) ->
            ConfigVerify.keyword_get(kw, :limit) == {:ok, value}

          _ ->
            false
        end)
      end)
    end

    # The entry goes after the last line carrying code, not at the end of the
    # block. A queues list can end in comment lines, and appending the
    # separating comma there puts it inside the comment — which leaves the
    # previous entry and the new one with nothing between them, and a
    # config.exs that no longer parses.
    defp add_queue_entry(queues_content, entry_indent, entry_text) do
      entry = entry_indent <> entry_text
      lines = String.split(queues_content, "\n")

      case last_code_line_index(lines) do
        nil when queues_content == "" ->
          entry

        nil ->
          queues_content <> "\n" <> entry

        index ->
          lines
          |> List.update_at(index, fn line ->
            if String.ends_with?(String.trim(line), ","), do: line, else: line <> ","
          end)
          |> List.insert_at(index + 1, entry)
          |> Enum.join("\n")
      end
    end

    defp last_code_line_index(lines) do
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {line, index} ->
        trimmed = String.trim(line)

        if trimmed != "" and not String.starts_with?(trimmed, "#"), do: index
      end)
    end

    # Ensure Pruner has max_age configured for 30-day retention
    # I103: exposed (not `defp`) and `@doc false`, same reason as
    # `ensure_lifeline_plugin/2` above — a real unit-test seam for the
    # verify-and-rollback behavior against plain content strings, without an
    # Igniter/Rewrite context (this is only otherwise reachable through the
    # full `update_existing_oban_config/3` pipeline).
    @doc false
    def ensure_pruner_max_age(content, _app_name) do
      # Check if max_age is already configured
      if Regex.match?(~r/Oban\.Plugins\.Pruner.*max_age:/s, content) do
        Mix.shell().info("  ℹ️  Pruner max_age already configured")
        content
      else
        # Check for bare Oban.Plugins.Pruner (without tuple)
        if Regex.match?(~r/Oban\.Plugins\.Pruner\s*[,\]]/, content) do
          Mix.shell().info("  ➕ Adding max_age to Oban.Plugins.Pruner...")

          # Replace bare Pruner with tuple form including max_age
          candidate =
            Regex.replace(
              ~r/Oban\.Plugins\.Pruner(\s*)(,|\])/,
              content,
              "{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30}\\1\\2  # Keep jobs for 30 days"
            )

          apply_pruner_max_age(content, candidate)
        else
          # Check for tuple form without max_age: {Oban.Plugins.Pruner}
          if Regex.match?(~r/\{Oban\.Plugins\.Pruner\}/, content) do
            Mix.shell().info("  ➕ Adding max_age to {Oban.Plugins.Pruner}...")

            candidate =
              String.replace(
                content,
                "{Oban.Plugins.Pruner}",
                "{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30}  # Keep jobs for 30 days"
              )

            apply_pruner_max_age(content, candidate)
          else
            Mix.shell().info("  ℹ️  Pruner configuration not found or already has options")
            content
          end
        end
      end
    end

    defp apply_pruner_max_age(content, candidate) do
      case ConfigVerify.verify_or_rollback(content, candidate, &pruner_has_max_age?/1) do
        {:ok, result} ->
          result

        {:rolled_back, original, _reason} ->
          pruner_manual_notice()
          original
      end
    end

    defp pruner_manual_notice do
      Mix.shell().error(
        "  ⚠️  Could not safely add max_age to Oban.Plugins.Pruner " <>
          "(the insertion would have produced invalid or misplaced config) - please add it manually:"
      )

      Mix.shell().error("     {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30}")
    end

    defp pruner_has_max_age?(ast) do
      ConfigVerify.ast_contains?(ast, fn node ->
        case ConfigVerify.tuple_elements(node) do
          nil ->
            false

          elements ->
            Enum.any?(elements, &ConfigVerify.alias_matches?(&1, Oban.Plugins.Pruner)) and
              Enum.any?(elements, fn
                kw when is_list(kw) -> match?({:ok, _}, ConfigVerify.keyword_get(kw, :max_age))
                _ -> false
              end)
        end
      end)
    end

    @doc """
    Ensure the Lifeline plugin exists in an existing `config :app, Oban`
    block's `plugins:` list, adding it if missing.

    Rescues a job orphaned in `:executing` by a hard crash (BEAM `kill -9`,
    OOM, node failure) back to `:available` so it runs again — without it,
    an orphaned job sits stuck in `:executing` forever. That's more than a
    stalled retry: for a unique worker whose unique `states:` includes
    `:executing` (a self-scheduling chain deduping against its own
    in-flight run is a common pattern — see `phoenix_kit_emails`' pollers),
    an orphan permanently blocks every future insert for that worker too,
    not just the one crashed job.

    `rescue_after` is Oban's default of 60 minutes rather than anything
    more aggressive, and it must stay above the host's longest-running
    job. Lifeline rescues purely by elapsed time — it never checks whether
    the node is still alive — so a job that legitimately runs past
    `rescue_after` is flipped back to `:available` (or `:discarded`, if its
    attempts are exhausted) while the original process is still working,
    and re-executes concurrently. PhoenixKit's longest declared worker
    timeout is 30 minutes (`Storage.Jobs.Reconcile`); workers with no
    `timeout/1` callback have no bound at all, which is the case the margin
    is really protecting.

    Public (not `defp`, unlike the sibling `ensure_*_queue/2` helpers)
    specifically so this can be unit-tested directly against plain content
    strings, the same way `oban_block_missing_prefix?/1` is — no live
    Igniter/Mix context needed.
    """
    @spec ensure_lifeline_plugin(String.t(), atom() | String.t()) :: String.t()
    def ensure_lifeline_plugin(content, app_name) do
      if Regex.match?(~r/Oban\.Plugins\.Lifeline/, content) do
        maybe_raise_lifeline_rescue_after(content)
      else
        Mix.shell().info("  ➕ Adding Oban.Plugins.Lifeline to Oban configuration...")

        # The closing `]` is matched at the SAME indentation as the
        # `plugins:` keyword itself (backreference `\\2`). A lazy `.*?` up
        # to the first `]` would instead stop inside a nested list — the
        # generated config's own Cron plugin carries `crontab: [...]`, and
        # inserting there corrupts the file (review finding on this very
        # function). Nested lists are always indented deeper, so anchoring
        # the close to the keyword's indentation skips them.
        #
        # I103: the whole pattern is anchored to THIS app's own
        # `config :app_name, Oban` block first (same prefix `insert_queue/4`
        # already uses for `queues:`), bounded at the next top-level
        # `config`/`import_config`. Without it, a host with any OTHER
        # `plugins: [...]` list earlier in config.exs — a completely
        # unrelated `config :some_lib, plugins: [...]` — matched first: this
        # inserted Lifeline into the WRONG application's list and reported
        # success, while `:app_name`'s own Oban config stayed untouched.
        case Regex.run(
               ~r/(^config\s+:#{app_name},\s+Oban\b(?:(?!\n(?:config\s|import_config\s)).)*?\n([ \t]+)plugins:\s*\[\n)(.*?)(\n\2\])/ms,
               content,
               capture: :all
             ) do
          [full_match, plugins_open, indent, plugins_content, plugins_close] ->
            Mix.shell().info("  ✓ Found plugins block, adding Lifeline plugin")

            trimmed_content = String.trim(plugins_content)
            has_trailing_comma = String.ends_with?(trimmed_content, ",")

            # Entry indentation inferred from the block's own: keyword
            # indent + 2, matching how the generated template nests entries.
            entry_indent = indent <> "  "

            lifeline_plugin =
              if has_trailing_comma do
                "\n" <> entry_indent <> lifeline_entry()
              else
                ",\n" <> entry_indent <> lifeline_entry()
              end

            updated_plugins = plugins_open <> plugins_content <> lifeline_plugin <> plugins_close
            candidate = String.replace(content, full_match, updated_plugins, global: false)

            case ConfigVerify.verify_or_rollback(
                   content,
                   candidate,
                   &plugins_contains_module?(&1, app_name, Oban.Plugins.Lifeline)
                 ) do
              {:ok, result} ->
                result

              {:rolled_back, original, _reason} ->
                lifeline_manual_notice(app_name)
                original
            end

          nil ->
            lifeline_manual_notice(app_name)
            content
        end
      end
    end

    defp lifeline_manual_notice(app_name) do
      Mix.shell().error(
        "  ⚠️  Could not safely add Lifeline to the plugins block for :#{app_name} " <>
          "(not found, or the insertion would have produced invalid or misplaced config)"
      )

      Mix.shell().error("     Please manually add: #{lifeline_entry()}")
    end

    # True if `ast` has a `plugins: [...]` list containing a tuple naming
    # `module`, INSIDE `app_name`'s own `config :app_name, Oban` block —
    # shared by every splice below that adds a plugin tuple to an Oban
    # `plugins:` list. Scoped to `app_name` for the same reason the splices
    # themselves are: an unscoped `keyword_list_satisfies?/3` is satisfied by
    # ANY `plugins:` list in the file, including a different application's,
    # and would report success on an insertion that landed in the wrong
    # place — or never landed at all.
    defp plugins_contains_module?(ast, app_name, module) do
      ConfigVerify.app_config_satisfies?(ast, app_name, Oban, :plugins, fn list ->
        Enum.any?(list, &ConfigVerify.tuple_names_module?(&1, module))
      end)
    end

    # Single source for the entry every emit site writes, so the value and the
    # invariant behind it can't drift apart across the template, the backfill and
    # the manual-fallback message.
    defp lifeline_entry do
      "{Oban.Plugins.Lifeline, rescue_after: :timer.minutes(#{@lifeline_rescue_after_minutes})}"
    end

    # A Lifeline entry that is already present may still carry an unsafe
    # rescue_after — hosts that hand-wrote one, or copied Oban's own docs example
    # (`rescue_after: :timer.minutes(5)`), sit exactly in the window where a
    # long-running job is rescued mid-flight and executes twice. Presence alone is
    # not the thing worth checking, so raise a too-low literal instead of no-oping.
    #
    # Only the `:timer.minutes(N)` literal form is rewritten — the shape both
    # PhoenixKit and Oban's docs emit. Any other expression (raw milliseconds, a
    # module attribute, a runtime lookup) is left alone with a notice, because
    # rewriting it blind is how an installer corrupts a host's config.
    defp maybe_raise_lifeline_rescue_after(content) do
      pattern =
        ~r/\{Oban\.Plugins\.Lifeline,\s*rescue_after:\s*:timer\.minutes\((\d+)\)\}/

      case Regex.run(pattern, content, capture: :all) do
        [full_match, minutes] ->
          if String.to_integer(minutes) <= @lifeline_min_rescue_after_minutes do
            Mix.shell().info(
              "  ⬆️  Raising Lifeline rescue_after #{minutes} → #{@lifeline_rescue_after_minutes} minutes " <>
                "(at or below PhoenixKit's longest worker timeout, jobs would be rescued mid-flight)"
            )

            candidate = String.replace(content, full_match, lifeline_entry(), global: false)

            case ConfigVerify.verify_or_rollback(
                   content,
                   candidate,
                   &lifeline_rescue_after_raised?/1
                 ) do
              {:ok, result} ->
                result

              {:rolled_back, original, _reason} ->
                Mix.shell().error(
                  "  ⚠️  Could not safely raise Lifeline rescue_after " <>
                    "(the replacement would have produced invalid or misplaced config) - please set it manually:"
                )

                Mix.shell().error("     #{lifeline_entry()}")
                original
            end
          else
            Mix.shell().info("  ℹ️  Lifeline plugin already configured")
            content
          end

        nil ->
          Mix.shell().info("  ℹ️  Lifeline plugin already configured")
          content
      end
    end

    defp lifeline_rescue_after_raised?(ast) do
      ConfigVerify.ast_contains?(ast, fn node ->
        case ConfigVerify.tuple_elements(node) do
          nil -> false
          elements -> lifeline_tuple_raised?(elements)
        end
      end)
    end

    defp lifeline_tuple_raised?(elements) do
      Enum.any?(elements, &ConfigVerify.alias_matches?(&1, Oban.Plugins.Lifeline)) and
        Enum.any?(elements, &rescue_after_raised?/1)
    end

    # `:timer.minutes(N)` calls the ERLANG `:timer` module — a lowercase
    # atom, not an Elixir alias — so its AST head is a bare `:timer` atom,
    # never `{:__aliases__, _, [:timer]}` (that shape is for a capitalized
    # Elixir module reference).
    defp rescue_after_raised?(kw) when is_list(kw) do
      case ConfigVerify.keyword_get(kw, :rescue_after) do
        {:ok, {{:., _, [:timer, :minutes]}, _, [minutes]}} ->
          minutes == @lifeline_rescue_after_minutes

        _ ->
          false
      end
    end

    defp rescue_after_raised?(_), do: false

    # Any module path ending in the old worker's name. The replacement used to
    # be the literal "PhoenixKit.Posts.Workers.PublishScheduledPostsJob", a
    # module that exists in no repo — the real one is
    # `PhoenixKitPosts.Workers.PublishScheduledPostsJob`. So the Case 1 guard
    # matched, `String.replace/3` found nothing, and the branch returned the
    # content untouched while printing "🔄 Replacing…". Being `cond`'s first
    # clause, it also shadowed Cases 2-4, so the core worker was never added
    # either: an upgrading host kept the old posts worker, gained nothing, and
    # was told the opposite. That is why hosts are found running both cron
    # entries, which is what makes the posts sweep race itself on a single node.
    @old_posts_worker ~r/[A-Za-z0-9_.]*\bPublishScheduledPostsJob\b/
    @new_worker "PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker"

    @doc """
    Ensures the crontab schedules `ProcessScheduledJobsWorker`.

    Public for the same reason as `ensure_worker_cron_entries/2`: so it can be
    unit-tested directly against content strings.
    """
    @spec ensure_cron_plugin(String.t(), atom() | String.t()) :: String.t()
    def ensure_cron_plugin(content, app_name) do
      cond do
        # Case 1: the old worker is scheduled and the core worker is not.
        # Rename it in place — the core worker's catch-up already calls
        # PhoenixKitPosts.process_scheduled_posts/0, so it subsumes the entry.
        #
        # I103: deliberately NOT wrapped in `ConfigVerify.verify_or_rollback/3`,
        # unlike every other splice in this module — a plain identifier-to-
        # identifier text substitution cannot land on the wrong bracket or
        # misplace anything structurally, so there is no failure mode for a
        # parse-then-verify step to catch. `global: false` is left off (the
        # default, global replace) on purpose too: if the old module path
        # somehow appears more than once, renaming every occurrence
        # consistently is correct, not a hazard to guard against.
        Regex.match?(@old_posts_worker, content) and
            not String.contains?(content, "ProcessScheduledJobsWorker") ->
          Mix.shell().info(
            "  🔄 Replacing PublishScheduledPostsJob with ProcessScheduledJobsWorker..."
          )

          Regex.replace(@old_posts_worker, content, @new_worker)

        # Case 1b: both are scheduled. Rewriting the old entry would leave two
        # identical crontab lines, so say what is there and change nothing —
        # the two are independently cronned callers of the same sweep, and
        # which one to drop is the host's decision, not ours.
        Regex.match?(@old_posts_worker, content) ->
          Mix.shell().error(
            "  ⚠️  Both PublishScheduledPostsJob and ProcessScheduledJobsWorker are in the crontab"
          )

          Mix.shell().error(
            "     They run the same posts sweep from different queues, so scheduled posts can be"
          )

          Mix.shell().error(
            "     published twice. Remove the PublishScheduledPostsJob entry — the core worker"
          )

          Mix.shell().error("     already covers it via catchup_scheduled_posts/0.")

          content

        # Case 2: Cron plugin exists with new worker - already configured
        String.contains?(content, "Oban.Plugins.Cron") and
            String.contains?(content, "ProcessScheduledJobsWorker") ->
          Mix.shell().info("  ℹ️  Cron plugin and ProcessScheduledJobsWorker already configured")
          content

        # Case 3: Cron plugin exists but no scheduled jobs worker - add new worker
        String.contains?(content, "Oban.Plugins.Cron") ->
          Mix.shell().info(
            "  ➕ Adding ProcessScheduledJobsWorker to existing cron configuration..."
          )

          add_scheduled_posts_job_to_crontab(content, app_name)

        # Case 4: No cron plugin at all - add entire plugin with new worker
        true ->
          Mix.shell().info("  ➕ Adding Oban.Plugins.Cron with ProcessScheduledJobsWorker...")
          add_cron_plugin_to_plugins(content, app_name)
      end
    end

    # Add ProcessScheduledJobsWorker to existing crontab
    #
    # I103: this is the one crontab-splice function that used a lazy `.*?`
    # instead of the anchored, same-indentation-close pattern the sibling
    # functions below use (`add_worker_entries_to_crontab/3`,
    # `add_digest_entries_to_crontab/3`) — the only one of the six
    # block-splice helpers in this file with no anchor at all. Reproduced
    # live: an entirely ordinary comment inside the crontab block containing
    # a `]` (e.g. "# historically took a priority list, e.g. [1, 2] - removed")
    # makes the lazy match stop at the comment's own bracket and corrupts the
    # file into invalid Elixir. A DIFFERENT shape — an existing entry whose
    # own `args:` value is itself a list (`args: %{tags: ["a", "b"]}`) —
    # corrupts just as badly but produces something that still PARSES: the
    # new entry lands nested inside that list instead of as a crontab
    # sibling. `ConfigVerify.verify_or_rollback/3` catches both: the first
    # via `Code.string_to_quoted/1` failing outright, the second because the
    # semantic check below only accepts a result where the new tuple shows
    # up as a direct member of the `crontab:` list itself, not buried deeper
    # in some other value that also happened to close with a `]`.
    #
    # I103: the pattern is additionally anchored to THIS app's own
    # `config :app_name, Oban` block, bounded at the next top-level
    # `config`/`import_config` — same prefix `insert_queue/4` uses for
    # `queues:`. Without it, the (still lazy) `crontab:` search could match a
    # different application's `crontab:` list first if one appeared earlier
    # in config.exs.
    defp add_scheduled_posts_job_to_crontab(content, app_name) do
      # Pattern: crontab: [...] within Cron plugin, inside app_name's own block
      case Regex.run(
             ~r/(^config\s+:#{app_name},\s+Oban\b(?:(?!\n(?:config\s|import_config\s)).)*?crontab:\s*\[)(.*?)(\])/ms,
             content,
             capture: :all
           ) do
        [full_match, before_crontab, crontab_content, after_crontab] ->
          # `crontab_content` keeps its OWN trailing whitespace/newline up to
          # (not including) the closing `]` — appending straight onto that
          # puts a bare `,` alone on its own line, detached by a newline from
          # the element before it, which Elixir's parser rejects outright
          # ("syntax error before: ','"). `String.trim_trailing/1` here
          # matches what the anchored sibling splices below already do
          # correctly (`add_worker_entries_to_crontab/3`,
          # `add_digest_entries_to_crontab/3`): drop the trailing whitespace
          # first, so the new comma lands directly after the last real token.
          trimmed_entries = String.trim_trailing(crontab_content)
          has_entries = String.trim(crontab_content) != ""
          has_trailing_comma = String.ends_with?(trimmed_entries, ",")

          new_job_entry =
            cond do
              not has_entries ->
                "\n           {\"* * * * *\", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}\n         "

              has_trailing_comma ->
                "\n           {\"* * * * *\", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}\n"

              true ->
                ",\n           {\"* * * * *\", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}\n"
            end

          updated_crontab = before_crontab <> trimmed_entries <> new_job_entry <> after_crontab
          candidate = String.replace(content, full_match, updated_crontab, global: false)

          case ConfigVerify.verify_or_rollback(
                 content,
                 candidate,
                 &crontab_contains_module?(
                   &1,
                   app_name,
                   PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker
                 )
               ) do
            {:ok, result} ->
              result

            {:rolled_back, original, _reason} ->
              scheduled_posts_job_manual_notice()
              original
          end

        _ ->
          scheduled_posts_job_manual_notice()
          content
      end
    end

    # True if `ast` has a `crontab: [...]` list containing a tuple naming
    # `module`, INSIDE `app_name`'s own `config :app_name, Oban` block — used
    # both to confirm a splice landed where it was meant to (a direct list
    # member, not nested inside some other entry's own value) and, unchanged,
    # to check the SAME thing for the sibling crontab-splice functions below.
    # Scoped to `app_name` for the same reason `plugins_contains_module?/3`
    # is: an unscoped check is satisfied by ANY `crontab:` list in the file.
    defp crontab_contains_module?(ast, app_name, module) do
      ConfigVerify.app_config_satisfies?(ast, app_name, Oban, :crontab, fn list ->
        Enum.any?(list, &ConfigVerify.tuple_names_module?(&1, module))
      end)
    end

    defp scheduled_posts_job_manual_notice do
      Mix.shell().error(
        "  ⚠️  Could not safely add ProcessScheduledJobsWorker to the existing crontab " <>
          "(the insertion would have produced invalid or misplaced config) - please add it manually:"
      )

      Mix.shell().error(
        "     {\"* * * * *\", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}"
      )
    end

    # The notification digest sweeps — one cron entry per cadence, matching the
    # generated template. `DigestWorker` is ONLY ever enqueued by these entries,
    # so a host missing them has silently-dead digest cadences: the creation path
    # already suppresses the per-event inbox row for a non-immediate cadence
    # (`Notifications.inapp_immediate?/2`), and with no cron there is no summary
    # to replace it — the user's notifications just vanish.
    @digest_cron_entries [
      {"0 * * * *", "hourly"},
      {"0 */12 * * *", "12h"},
      {"0 6 * * *", "daily"},
      {"0 6 * * 1", "weekly"}
    ]

    @doc """
    Ensures every notification digest cadence has a crontab entry.

    Runs AFTER `ensure_cron_plugin/2` (which guarantees a `crontab:` block
    exists) and is needed because that function short-circuits as soon as
    `ProcessScheduledJobsWorker` is present — so a host installed before the
    digest workers existed would keep a crontab without them forever, and
    `mix phoenix_kit.update` would never notice. Each cadence is checked
    independently, so a partially-updated crontab converges.

    Public (not `defp`, unlike the sibling `ensure_*_queue/2` helpers)
    specifically so this can be unit-tested directly against plain content
    strings, the same way `ensure_lifeline_plugin/2` is.
    """
    @spec ensure_digest_cron_entries(String.t(), atom() | String.t()) :: String.t()
    def ensure_digest_cron_entries(content, app_name) do
      missing =
        Enum.reject(@digest_cron_entries, fn {_cron, cadence} -> digest?(content, cadence) end)

      if missing == [] do
        Mix.shell().info("  ℹ️  notification digest cron entries already configured")
        content
      else
        Mix.shell().info("  ➕ Adding notification digest cron entries...")
        add_digest_entries_to_crontab(content, missing, app_name)
      end
    end

    defp digest?(content, cadence) do
      Regex.match?(~r/DigestWorker[^\n]*cadence:\s*"#{Regex.escape(cadence)}"/, content)
    end

    # Plain `{cron, Worker}` crontab entries that shipped after the first
    # installs. Same reasoning as the digest entries: `ensure_cron_plugin/2`
    # short-circuits once `ProcessScheduledJobsWorker` is present, so without an
    # explicit backfill a host that installed earlier never gains them.
    @worker_cron_entries [
      {"30 4 * * *", "PhoenixKit.Users.Referrals.PruneWorker"},
      # Shipped in 2.31.0. Without the backfill an existing host never
      # prunes failed sign-in buckets and the table grows for the life
      # of the install.
      {"45 4 * * *", "PhoenixKit.Users.LoginAttemptsPruneWorker"},
      # Job runs (2.48.0). Without the sweeper an existing host never rescues a run
      # whose batch died, and without the prune the table grows for the life of
      # the install.
      {"*/5 * * * *", "PhoenixKit.Jobs.SweepWorker"},
      {"15 4 * * *", "PhoenixKit.Jobs.PruneWorker"},
      # The bucket log (V208). Without the prune the table grows for the life
      # of the install.
      {"20 4 * * *", "PhoenixKit.Modules.Storage.Workers.BucketLogPruneWorker"}
    ]

    @doc """
    Ensures the plain worker cron entries shipped since a host's install exist.

    Public for the same reason as `ensure_digest_cron_entries/2`: so it can be
    unit-tested directly against content strings.
    """
    @spec ensure_worker_cron_entries(String.t(), atom() | String.t()) :: String.t()
    def ensure_worker_cron_entries(content, app_name) do
      missing =
        Enum.reject(@worker_cron_entries, fn {_cron, mod} -> String.contains?(content, mod) end)

      if missing == [] do
        content
      else
        Mix.shell().info("  ➕ Adding PhoenixKit worker cron entries...")
        add_worker_entries_to_crontab(content, missing, app_name)
      end
    end

    # I103: anchored to THIS app's own `config :app_name, Oban` block (same
    # prefix `insert_queue/4` uses for `queues:`), and the leading separator
    # before the new entries now checks `has_trailing_comma` instead of
    # always prepending `,\n` — the same hardening `add_scheduled_posts_job_to_crontab/2`
    # already has. A crontab whose last entry legitimately already ends in a
    # comma (a perfectly ordinary shape, e.g. `mix format`'s own output for a
    # multi-entry list) got a DOUBLE comma before this fix: `Code.string_to_quoted/1`
    # then fails, `verify_or_rollback/3` rolls back, and the operator is told
    # their own config is the problem when the insertion logic was.
    defp add_worker_entries_to_crontab(content, missing, app_name) do
      case Regex.run(
             ~r/(^config\s+:#{app_name},\s+Oban\b(?:(?!\n(?:config\s|import_config\s)).)*?\n([ \t]+)crontab:\s*\[\n)(.*?)(\n\2\])/ms,
             content,
             capture: :all
           ) do
        [full_match, crontab_open, indent, crontab_content, crontab_close] ->
          entry_indent = indent <> "  "
          trimmed_content = String.trim_trailing(crontab_content)
          has_trailing_comma = String.ends_with?(trimmed_content, ",")

          entries =
            Enum.map_join(missing, ",\n", fn {cron, mod} ->
              "#{entry_indent}{\"#{cron}\", #{mod}}"
            end)

          new_entries = if has_trailing_comma, do: "\n" <> entries, else: ",\n" <> entries

          updated = crontab_open <> trimmed_content <> new_entries <> crontab_close

          candidate = String.replace(content, full_match, updated, global: false)

          case ConfigVerify.verify_or_rollback(
                 content,
                 candidate,
                 &crontab_has_all_modules?(&1, app_name, missing)
               ) do
            {:ok, result} ->
              result

            {:rolled_back, original, _reason} ->
              worker_entries_manual_notice(app_name, missing)
              original
          end

        nil ->
          worker_entries_manual_notice(app_name, missing)
          content
      end
    end

    defp worker_entries_manual_notice(app_name, missing) do
      Mix.shell().error(
        "  ⚠️  Could not safely add worker cron entries for :#{app_name} " <>
          "(crontab block not found, or the insertion would have produced invalid or misplaced config)"
      )

      Enum.each(missing, fn {cron, mod} ->
        Mix.shell().error("     Please manually add: {\"#{cron}\", #{mod}}")
      end)
    end

    # True if `ast` has a `crontab: [...]` list containing, for EVERY
    # `{_cron, mod_string}` pair in `missing`, a tuple naming that module —
    # scoped to `app_name`'s own Oban block for the same reason
    # `crontab_contains_module?/3` is.
    defp crontab_has_all_modules?(ast, app_name, missing) do
      ConfigVerify.app_config_satisfies?(ast, app_name, Oban, :crontab, fn list ->
        Enum.all?(missing, fn {_cron, mod} ->
          module = Module.concat(String.split(mod, "."))
          Enum.any?(list, &ConfigVerify.tuple_names_module?(&1, module))
        end)
      end)
    end

    # Append the missing entries to the existing crontab list. The closing `]` is
    # anchored to the `crontab:` keyword's own indentation (backreference `\\2`)
    # for the same reason as `add_cron_plugin_to_plugins/2`: a lazy `.*?` to the
    # first `]` can stop inside an entry's own nested list.
    #
    # I103: anchored to THIS app's own `config :app_name, Oban` block (same
    # prefix as `add_worker_entries_to_crontab/3`), and the leading separator
    # before the new entries checks `has_trailing_comma` instead of always
    # prepending `,\n` — see `add_worker_entries_to_crontab/3` for why an
    # unconditional leading comma corrupts a crontab that legitimately
    # already ends in one.
    defp add_digest_entries_to_crontab(content, missing, app_name) do
      case Regex.run(
             ~r/(^config\s+:#{app_name},\s+Oban\b(?:(?!\n(?:config\s|import_config\s)).)*?\n([ \t]+)crontab:\s*\[\n)(.*?)(\n\2\])/ms,
             content,
             capture: :all
           ) do
        [full_match, crontab_open, indent, crontab_content, crontab_close] ->
          entry_indent = indent <> "  "
          trimmed_content = String.trim_trailing(crontab_content)
          has_trailing_comma = String.ends_with?(trimmed_content, ",")

          entries =
            Enum.map_join(missing, ",\n", fn {cron, cadence} ->
              "#{entry_indent}{\"#{cron}\", PhoenixKit.Notifications.DigestWorker, " <>
                "args: %{cadence: \"#{cadence}\"}}"
            end)

          new_entries = if has_trailing_comma, do: "\n" <> entries, else: ",\n" <> entries

          updated = crontab_open <> trimmed_content <> new_entries <> crontab_close

          candidate = String.replace(content, full_match, updated, global: false)

          case ConfigVerify.verify_or_rollback(
                 content,
                 candidate,
                 &crontab_has_all_digest_cadences?(&1, app_name, missing)
               ) do
            {:ok, result} ->
              result

            {:rolled_back, original, _reason} ->
              digest_entries_manual_notice(app_name, missing)
              original
          end

        nil ->
          digest_entries_manual_notice(app_name, missing)
          content
      end
    end

    defp digest_entries_manual_notice(app_name, missing) do
      Mix.shell().error(
        "  ⚠️  Could not safely add digest cron entries for :#{app_name} " <>
          "(crontab block not found, or the insertion would have produced invalid or misplaced config)"
      )

      Enum.each(missing, fn {cron, cadence} ->
        Mix.shell().error(
          "     Please manually add: {\"#{cron}\", PhoenixKit.Notifications.DigestWorker, " <>
            "args: %{cadence: \"#{cadence}\"}}"
        )
      end)
    end

    # True if `ast` has a `crontab: [...]` list containing, for EVERY
    # `{_cron, cadence}` in `missing`, a DigestWorker tuple whose `args:`
    # map carries that exact cadence — not just "a DigestWorker tuple
    # exists somewhere", which would pass even if only one of several
    # missing cadences actually landed.
    defp crontab_has_all_digest_cadences?(ast, app_name, missing) do
      ConfigVerify.app_config_satisfies?(ast, app_name, Oban, :crontab, fn list ->
        Enum.all?(missing, fn {_cron, cadence} ->
          Enum.any?(list, &digest_tuple_has_cadence?(&1, cadence))
        end)
      end)
    end

    defp digest_tuple_has_cadence?(node, cadence) do
      case ConfigVerify.tuple_elements(node) do
        nil ->
          false

        elements ->
          Enum.any?(
            elements,
            &ConfigVerify.alias_matches?(&1, PhoenixKit.Notifications.DigestWorker)
          ) and
            Enum.any?(elements, fn
              kw when is_list(kw) ->
                with {:ok, {:%{}, _meta, map_kv}} <- ConfigVerify.keyword_get(kw, :args),
                     {:ok, ^cadence} <- ConfigVerify.keyword_get(map_kv, :cadence) do
                  true
                else
                  _ -> false
                end

              _ ->
                false
            end)
      end
    end

    # Add Cron plugin to plugins list
    defp add_cron_plugin_to_plugins(content, app_name) do
      # Find the ACTIVE plugins block - must not be commented out
      # Pattern: line starts with spaces (not #), then plugins: [
      #
      # The closing `]` is anchored to the `plugins:` keyword's own
      # indentation (backreference `\\2`), for the same reason as
      # `ensure_lifeline_plugin/2`: a lazy `.*?` to the first indented `]`
      # stops inside a nested list instead (a host plugin carrying its own
      # list — `{Oban.Plugins.Reindexer, indexes: [...]}`, Oban Web's
      # stats plugin — puts one right there), and inserting there corrupts
      # the file. Nested lists are always indented deeper, so anchoring to
      # the keyword's indentation skips them.
      #
      # I103: also anchored to THIS app's own `config :app_name, Oban` block
      # — see `ensure_lifeline_plugin/2` for why an unanchored `plugins:`
      # search can match a different application's list first.
      case Regex.run(
             ~r/(^config\s+:#{app_name},\s+Oban\b(?:(?!\n(?:config\s|import_config\s)).)*?\n([ \t]+)plugins:\s*\[\n)(.*?)(\n\2\])/ms,
             content,
             capture: :all
           ) do
        [full_match, plugins_open, indent, plugins_content, plugins_close] ->
          Mix.shell().info("  ✓ Found plugins block, adding Cron plugin")

          # Check if content ends with comma
          trimmed_content = String.trim(plugins_content)
          has_trailing_comma = String.ends_with?(trimmed_content, ",")

          # Entry indentation inferred from the block's own: keyword indent
          # + 2, matching how the generated template nests entries.
          entry_indent = indent <> "  "

          cron_entry =
            entry_indent <>
              "{Oban.Plugins.Cron,\n" <>
              entry_indent <>
              " crontab: [\n" <>
              entry_indent <>
              "   {\"* * * * *\", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}\n" <>
              entry_indent <> " ]}"

          # Add cron plugin with proper formatting (matching existing indentation)
          cron_plugin =
            if has_trailing_comma do
              "\n" <> cron_entry
            else
              ",\n" <> cron_entry
            end

          updated_plugins = plugins_open <> plugins_content <> cron_plugin <> plugins_close
          candidate = String.replace(content, full_match, updated_plugins, global: false)

          case ConfigVerify.verify_or_rollback(
                 content,
                 candidate,
                 &crontab_contains_module?(
                   &1,
                   app_name,
                   PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker
                 )
               ) do
            {:ok, result} ->
              result

            {:rolled_back, original, _reason} ->
              cron_plugin_manual_notice(app_name)
              original
          end

        nil ->
          cron_plugin_manual_notice(app_name)
          content
      end
    end

    defp cron_plugin_manual_notice(app_name) do
      Mix.shell().error(
        "  ⚠️  Could not safely add Oban.Plugins.Cron to the plugins block for :#{app_name} " <>
          "(not found, or the insertion would have produced invalid or misplaced config)"
      )

      Mix.shell().error("     Please manually add Oban.Plugins.Cron configuration")
    end

    # Get repo module from PhoenixKit config or detect from app
    defp get_repo_module(igniter) do
      config_path = "config/config.exs"
      app_name = IgniterHelpers.get_parent_app_name(igniter)

      if File.exists?(config_path) do
        content = File.read!(config_path)

        # First try: Look for existing PhoenixKit repo config
        case Regex.run(~r/config :phoenix_kit,\s+repo:\s+([A-Za-z0-9_.]+)/, content) do
          [_, repo] ->
            repo

          _ ->
            # Second try: Look for ecto_repos in app config
            app_module = Macro.camelize(to_string(app_name))

            case Regex.run(~r/config :#{app_name}.*?ecto_repos:\s*\[([A-Za-z0-9_.]+)\]/s, content) do
              [_, repo] -> repo
              _ -> "#{app_module}.Repo"
            end
        end
      else
        app_module = Macro.camelize(to_string(app_name))
        "#{app_module}.Repo"
      end
    rescue
      _ ->
        app_name = IgniterHelpers.get_parent_app_name(igniter)
        app_module = Macro.camelize(to_string(app_name))
        "#{app_module}.Repo"
    end

    # Check if Oban config already exists in the file
    defp oban_config_already_exists?(content, app_name) do
      lines = String.split(content, "\n")

      Enum.any?(lines, fn line ->
        trimmed = String.trim(line)

        # Not a comment and contains config for Oban
        # Also check for variations with spaces
        !String.starts_with?(trimmed, "#") and
          (String.contains?(line, "config :#{app_name}, Oban") or
             Regex.match?(~r/config\s+:#{app_name},\s+Oban/, line))
      end)
    end

    # Find the location to insert config before import_config statements
    defp find_import_config_location(content) do
      lines = String.split(content, "\n")

      # Look for import_config pattern
      import_index =
        Enum.find_index(lines, fn line ->
          trimmed = String.trim(line)
          String.starts_with?(trimmed, "import_config") or String.contains?(line, "import_config")
        end)

      case import_index do
        nil ->
          # No import_config found, append to end
          :append_to_end

        index ->
          # Find the start of the import_config block
          start_index = find_import_block_start(lines, index)

          # Split content at the start of import block
          before_lines = Enum.take(lines, start_index)
          after_lines = Enum.drop(lines, start_index)

          before_content = Enum.join(before_lines, "\n")
          after_content = Enum.join(after_lines, "\n")

          {:before_import, before_content, after_content}
      end
    end

    # Find the start of the import_config block (including preceding comments)
    defp find_import_block_start(lines, import_index) do
      lines
      |> Enum.take(import_index)
      |> Enum.reverse()
      |> Enum.reduce_while(import_index, fn line, current_index ->
        trimmed = String.trim(line)

        cond do
          # Comment line related to import
          String.starts_with?(trimmed, "#") and
              (String.contains?(line, "import") or String.contains?(line, "Import") or
                 String.contains?(line, "bottom") or String.contains?(line, "BOTTOM") or
                 String.contains?(line, "environment")) ->
            {:cont, current_index - 1}

          # Blank line
          trimmed == "" ->
            {:cont, current_index - 1}

          # config_env or similar
          String.contains?(line, "config_env()") or String.contains?(line, "env_config") ->
            {:cont, current_index - 1}

          # Stop at any other code
          true ->
            {:halt, current_index}
        end
      end)
    end

    # Add notice about Oban configuration
    defp add_oban_configuration_notice(igniter) do
      if oban_config_exists?(igniter) do
        Igniter.add_notice(
          igniter,
          """
          ⚙️  Oban configured for background jobs (file processing, sitemap, newsletters)
             If queues were added/updated, restart your server to apply changes.
          """
          |> String.trim()
        )
      else
        Igniter.add_notice(
          igniter,
          """
          ⚙️  Oban configuration added to config.exs
             (restart a running server to apply)
          """
          |> String.trim()
        )
      end
    end

    @doc """
    Adds Oban to the parent application's supervision tree.

    This function ensures that Oban starts automatically when the application starts,
    with correct positioning in the supervisor tree:
    - AFTER PhoenixKit.Supervisor (PhoenixKit services available)
    - BEFORE Endpoint (Oban ready before HTTP requests)

    ## Important

    Oban MUST start AFTER PhoenixKit.Supervisor because PhoenixKit.Supervisor
    depends on Repo, and Oban also depends on Repo. The correct order is:
    1. Repo (database connection)
    2. PhoenixKit.Supervisor (uses Repo for Settings)
    3. Oban (uses Repo for job persistence)

    ## Parameters
    - `igniter` - The igniter context

    ## Returns
    Updated igniter with Oban added to application supervisor.
    """
    def add_oban_supervisor(igniter) do
      app_name = IgniterHelpers.get_parent_app_name(igniter)
      {igniter, endpoint} = Phoenix.select_endpoint(igniter)

      # Build AST for: Application.get_env(:app_name, Oban)
      # Using Sourceror to parse the code string into AST
      get_env_code = "Application.get_env(:#{app_name}, Oban)"
      get_env_ast = Sourceror.parse_string!(get_env_code)

      # Use Igniter API to add Oban with explicit positioning
      # Pass {Module, {:code, ast}} format so Igniter doesn't escape the AST
      # This ensures correct order: Repo → PhoenixKit → Oban → Endpoint
      igniter
      |> Application.add_new_child(
        {Oban, {:code, get_env_ast}},
        after: [PhoenixKit.Supervisor],
        before: [endpoint]
      )
    end

    @doc """
    Checks if Oban supervisor is configured in application.ex.

    ## Parameters
    - `igniter` - The igniter context for detecting parent app name

    ## Returns
    Boolean indicating if Oban supervisor exists in application.ex.
    """
    def oban_supervisor_exists?(igniter) do
      app_name = IgniterHelpers.get_parent_app_name(igniter)
      app_file = "lib/#{app_name}/application.ex"

      if File.exists?(app_file) do
        content = File.read!(app_file)

        # Check for Oban in children list
        String.contains?(content, "{Oban,") or
          String.contains?(content, "Application.get_env(:#{app_name}, Oban)")
      else
        false
      end
    rescue
      _ -> false
    end

    # Add notice when manual configuration is required
    defp add_manual_config_notice(igniter, repo_module) do
      app_name = IgniterHelpers.get_parent_app_name(igniter)

      notice = """
      ⚠️  Manual Configuration Required: Oban

      PhoenixKit couldn't automatically configure Oban for background jobs.

      Please add the following to config/config.exs:

        config :#{app_name}, Oban,
          repo: #{repo_module},
          queues: [
            default: 10,
            file_processing: 20,
            posts: 10,
            scheduled_jobs: 1,
            sitemap: 5,
            newsletters_delivery: 10,
            notifications: 10
          ],
          plugins: [
            # Pruner: delete completed/discarded jobs after 30 days
            {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
            # Lifeline: rescue jobs orphaned in :executing by a hard crash
            # (rescue_after must exceed your longest-running job)
            #{lifeline_entry()},
            {Oban.Plugins.Cron,
             crontab: [
               {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker},
               {"0 3 * * *", PhoenixKit.Modules.Storage.Workers.PruneTrashJob},
               {"0 4 * * *", PhoenixKit.Notifications.PruneWorker},
               {"30 4 * * *", PhoenixKit.Users.Referrals.PruneWorker},
               {"45 4 * * *", PhoenixKit.Users.LoginAttemptsPruneWorker},
               {"0 * * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "hourly"}},
               {"0 */12 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "12h"}},
               {"0 6 * * *", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "daily"}},
               {"0 6 * * 1", PhoenixKit.Notifications.DigestWorker, args: %{cadence: "weekly"}}
             ]}
          ]

      And add the following to lib/#{app_name}/application.ex in the children list:

        {Oban, Application.get_env(:#{app_name}, Oban)}

      IMPORTANT: Restart your server after making these changes.

      Without this configuration, the storage system cannot process uploaded files,
      scheduled posts will not be published automatically, and sitemap generation
      will not work asynchronously.
      """

      Igniter.add_notice(igniter, notice)
    end
  end
end
