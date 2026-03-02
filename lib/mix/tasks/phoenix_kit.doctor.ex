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

  ## Options

    * `--prefix` - Database schema prefix (default: "public")

  ## Checks Performed

    1. **Repo Detection** — Can we find and start the Ecto repo?
    2. **DB Connectivity** — Can we execute a simple query?
    3. **Pool Configuration** — Pool size, checkout timeout, queue settings
    4. **PgBouncer Detection** — Is PgBouncer between app and PostgreSQL?
    5. **Migration State** — PhoenixKit version (COMMENT), schema_migrations alignment
    6. **Pending Migrations** — Migration files not yet recorded in schema_migrations
    7. **UUID Column Types** — Detects varchar uuid columns that crash Ecto on startup
    8. **NULL UUIDs in FK Sources** — Detects NULL uuids that cause infinite backfill loops
    9. **Orphaned FK References** — Detects orphaned rows that block FK constraint creation
   10. **Lock Conflicts** — Any blocked or long-running queries?
   11. **Orphaned Connections** — Idle-in-transaction or stuck connections
   12. **Oban Configuration** — Queues and plugins that consume pool connections
   13. **Supervisor Children** — What's running (update_mode vs full)?
   14. **Update Mode** — Is update_mode active?
  """

  use Mix.Task

  @shortdoc "Diagnoses PhoenixKit installation, migration, and runtime issues"

  @switches [prefix: :string]
  @aliases [p: :prefix]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    prefix = opts[:prefix] || "public"

    # Start app with minimal footprint (same approach as phoenix_kit.update)
    Mix.Task.run("app.config")
    cap_repo_pool_size(2)
    Application.put_env(:phoenix_kit, :update_mode, true)
    Mix.Task.run("app.start")

    header("PhoenixKit Doctor")

    results = [
      run_check("Repo Detection", fn -> check_repo_detection() end),
      run_check("DB Connectivity", fn -> check_db_connectivity() end),
      run_check("Pool Configuration", fn -> check_pool_config() end),
      run_check("PgBouncer Detection", fn -> check_pgbouncer() end),
      run_check("Migration State", fn -> check_migration_state(prefix) end),
      run_check("Pending Migrations", fn -> check_pending_migrations() end),
      run_check("UUID Column Types", fn -> check_uuid_column_types(prefix) end),
      run_check("NULL UUIDs in FK Sources", fn -> check_null_uuids(prefix) end),
      run_check("Orphaned FK References", fn -> check_orphaned_fk_refs(prefix) end),
      run_check("Lock Conflicts", fn -> check_lock_conflicts() end),
      run_check("Orphaned Connections", fn -> check_orphaned_connections() end),
      run_check("Oban Configuration", fn -> check_oban_config() end),
      run_check("PhoenixKit Supervisor", fn -> check_supervisor_state() end),
      run_check("Update Mode", fn -> check_update_mode() end)
    ]

    IO.puts("")
    summary(results)
  end

  # ── Check implementations (return {:pass|:warn|:fail, detail}) ──────

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

  defp check_pgbouncer do
    app = Mix.Project.config()[:app]
    repo = get_repo!()
    config = Application.get_env(app, repo, [])

    port =
      cond do
        config[:port] -> config[:port]
        config[:url] -> extract_port_from_url(config[:url])
        true -> 5432
      end

    hostname = config[:hostname] || extract_host_from_url(config[:url]) || "localhost"

    if port != 5432 or String.contains?(to_string(hostname), "pgbouncer") do
      {:warn,
       "Likely PgBouncer (port=#{port}, host=#{hostname}). " <>
         "DDL migrations should use @disable_ddl_transaction true"}
    else
      {:pass, "Direct PostgreSQL (port=#{port}, host=#{hostname})"}
    end
  end

  defp check_migration_state(prefix) do
    repo = get_repo!()
    escaped_prefix = String.replace(prefix, "'", "\\'")

    # Source 1: COMMENT ON TABLE (set by each V*.up migration)
    comment_version = get_comment_version(repo, escaped_prefix)

    # Source 2: migrated_version_runtime (what phoenix_kit.status uses)
    runtime_version =
      try do
        opts = %{prefix: prefix, escaped_prefix: escaped_prefix}
        PhoenixKit.Migrations.Postgres.migrated_version_runtime(opts)
      rescue
        _ -> :error
      end

    # Source 3: Code's latest version
    latest_version = PhoenixKit.Migrations.Postgres.current_version()

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
      if length(pending) > 0 do
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

      length(pending) == 0 ->
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

        {:fail,
         "#{length(rows)} table(s) have varchar uuid columns (will crash Ecto on load):\n       #{tables}\n       " <>
           "Fix: ALTER TABLE <table> ALTER COLUMN uuid TYPE uuid USING uuid::uuid"}

      _ ->
        {:warn, "Could not check (phoenix_kit tables may not exist yet)"}
    end
  end

  # Pre-migration: check for NULL uuid values in tables that are FK sources.
  # NULL source UUIDs cause the V56 batched backfill loop to run forever.
  defp check_null_uuids(prefix) do
    repo = get_repo!()
    escaped_prefix = String.replace(prefix, "'", "\\'")

    # Key FK source tables whose uuid column must not be NULL
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

  # Pre-migration: check for orphaned FK references (rows pointing to deleted parents).
  # Orphaned refs cause V56's add_constraints to fail when adding FK constraints.
  defp check_orphaned_fk_refs(prefix) do
    repo = get_repo!()
    escaped_prefix = String.replace(prefix, "'", "\\'")

    # Check the most common orphaned FK pattern: user_uuid → users.uuid
    fk_checks = [
      {"phoenix_kit_users_tokens", "user_uuid", "phoenix_kit_users", "uuid"},
      {"phoenix_kit_user_role_assignments", "user_uuid", "phoenix_kit_users", "uuid"},
      {"phoenix_kit_admin_notes", "user_uuid", "phoenix_kit_users", "uuid"},
      {"phoenix_kit_email_events", "email_log_uuid", "phoenix_kit_email_logs", "uuid"}
    ]

    problems =
      Enum.reduce(fk_checks, [], fn {table, fk_col, ref_table, ref_col}, acc ->
        # Check both tables and columns exist
        table_name = prefix_table_name(table, prefix)
        ref_name = prefix_table_name(ref_table, prefix)

        check_query = """
        SELECT EXISTS (
          SELECT FROM information_schema.columns
          WHERE table_name = '#{table}' AND column_name = '#{fk_col}' AND table_schema = '#{escaped_prefix}'
        ) AND EXISTS (
          SELECT FROM information_schema.columns
          WHERE table_name = '#{ref_table}' AND column_name = '#{ref_col}' AND table_schema = '#{escaped_prefix}'
        )
        """

        case repo.query(check_query, [], log: false) do
          {:ok, %{rows: [[true]]}} ->
            orphan_query = """
            SELECT count(*)::integer FROM #{table_name} t
            WHERE t.#{fk_col} IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM #{ref_name} r WHERE r.#{ref_col} = t.#{fk_col})
            """

            case repo.query(orphan_query, [], log: false) do
              {:ok, %{rows: [[count]]}} when count > 0 ->
                [{table, fk_col, ref_table, count} | acc]

              _ ->
                acc
            end

          _ ->
            acc
        end
      end)

    if problems == [] do
      {:pass, "No orphaned FK references found"}
    else
      detail =
        Enum.map_join(Enum.reverse(problems), "\n       ", fn {table, fk_col, ref, count} ->
          "#{table}.#{fk_col} → #{ref}: #{count} orphaned rows"
        end)

      {:fail,
       "Orphaned FK refs found (will block FK constraint creation):\n       #{detail}\n       " <>
         "Fix: DELETE FROM <table> t WHERE NOT EXISTS (SELECT 1 FROM <ref> r WHERE r.uuid = t.<fk_col>)"}
    end
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

  defp check_oban_config do
    app = Mix.Project.config()[:app]

    case Application.get_env(app, Oban) do
      nil ->
        {:pass, "Oban not configured"}

      config ->
        queues = Keyword.get(config, :queues, [])
        plugins = Keyword.get(config, :plugins, [])

        {:pass,
         "#{length(queues)} queues, #{length(plugins)} plugins. Each active queue uses 1 pool connection."}
    end
  end

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

  defp check_update_mode do
    update_mode = Application.get_env(:phoenix_kit, :update_mode, false)

    if update_mode do
      {:warn, "update_mode=true (doctor runs in update_mode to minimize DB connections)"}
    else
      {:pass, "update_mode=false (normal operation)"}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp get_repo! do
    app = Mix.Project.config()[:app]

    case Application.get_env(app, :ecto_repos, []) do
      [repo | _] -> repo
      [] -> raise "No :ecto_repos configured for :#{app}"
    end
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

  # ── Display ─────────────────────────────────────────────────────────

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
