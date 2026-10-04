defmodule PhoenixKit.ObanSchema do
  @moduledoc """
  Keeps a host's Oban schema in step with the Oban library it runs.

  ## Why

  PhoenixKit creates Oban's tables once, by delegating to
  `Oban.Migration.up/1` from its V135 baseline — which installs whatever
  version the Oban of that day shipped. Oban's schema is versioned separately
  (the version is the `COMMENT` on `oban_jobs`), and core's open `{:oban, "~> 2.20"}`
  pin lets a host move to a newer Oban without anything migrating its schema.

  That is not harmless. Schema version 14 added a `suspended` value to the
  `oban_job_state` enum (it ships with Oban 2.21), and from Oban 2.24 the
  unique-insert check looks for jobs in that state by default. Against a version-13 schema every unique insert fails
  with `invalid input value for enum oban_job_state: "suspended"`. Cron inserts
  a minute's jobs in one transaction, so one unique cron worker rolls back
  every job scheduled for that minute.

  ## How it fits together

    * `mix phoenix_kit.update` checks the schema (`check/2`) and, when it is
      behind the library, writes a host migration (`write_migration/5`) that
      runs `Oban.Migration.up/1` to the library's version — applied together
      with the rest of the update's migrations.
    * `mix phoenix_kit.doctor` and `mix phoenix_kit.status` report the version.
    * The application logs one warning at boot when the running Oban's schema
      is behind (`warn_if_behind/1`), for hosts that never run the updater.

  Postgres only: Oban's MySQL and SQLite engines are outside what core
  installs, and `check/2` says so rather than guessing.

  ## Which schema, on which repo

  Two places are checked (`targets/3`): PhoenixKit's prefix on the host repo
  (where the baseline created the tables, and the repo `mix ecto.migrate`
  runs), and the prefix the host's Oban config runs at, on the repo that
  config names (`repo:`). When Oban runs on a repo other than the one the
  updater writes migrations for, no file is written for it — a migration
  there would run against the wrong database — and the updater prints the
  migration to add to that repo instead.
  """

  require Logger

  @typedoc """
  What `check/2` found at one prefix.

    * `{:current, version}` — the schema matches the library; `version` is
      `:infinity` when the comment is `∞`, which Oban itself reads as "never
      migrate this schema" (`Oban.Migrations.Postgres.migrated_version/1`)
    * `{:behind, migrated, expected}` — the library expects a newer schema
    * `{:ahead, migrated, expected}` — the schema is newer than the library
      (a newer Oban migrated it, then the dependency moved back)
    * `:no_table` — no `oban_jobs` at this prefix (a fresh install: core's
      baseline installs the library's version itself)
    * `{:unversioned, comment}` — `oban_jobs` exists but its comment is not a
      version number; nothing can be generated safely from it
    * `{:unsupported_adapter, adapter}` — the repo is not Postgres
    * `{:error, reason}` — the database could not be asked
  """
  @type status ::
          {:current, pos_integer() | :infinity}
          | {:behind, non_neg_integer(), pos_integer()}
          | {:ahead, pos_integer(), pos_integer()}
          | :no_table
          | {:unversioned, String.t() | nil}
          | {:unsupported_adapter, module()}
          | {:error, term()}

  @doc """
  Reads the Oban schema version at `prefix` on `repo` and compares it with
  the version the loaded Oban library expects.

  Never raises: an unreachable database is `{:error, reason}`.
  """
  @spec check(module(), String.t()) :: status()
  def check(repo, prefix) when is_atom(repo) and is_binary(prefix) do
    case repo.__adapter__() do
      Ecto.Adapters.Postgres ->
        classify(read_comment(repo, prefix), library_version(repo))

      adapter ->
        {:unsupported_adapter, adapter}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # `Oban.Migration.current_version/1` is public from Oban 2.22 only, while core's
  # pin is `~> 2.20`; the Postgres engine's own `current_version/0` exists from
  # 2.21. Older than that, there is no version to compare with — `check/2`
  # reports it as `{:error, _}` rather than guessing.
  defp library_version(repo) do
    Code.ensure_loaded(Oban.Migration)
    Code.ensure_loaded(Oban.Migrations.Postgres)

    cond do
      function_exported?(Oban.Migration, :current_version, 1) ->
        Oban.Migration.current_version(repo: repo)

      function_exported?(Oban.Migrations.Postgres, :current_version, 0) ->
        Oban.Migrations.Postgres.current_version()

      true ->
        raise "this Oban does not report the schema version it expects"
    end
  end

  # Same catalog lookup as Oban's own `migrated_version/1`, except that a
  # missing table and a table without a readable comment stay apart — Oban
  # folds both into 0, and "migrate from 0" over existing tables is exactly
  # the kind of guess this module must not make.
  defp read_comment(repo, prefix) do
    query = """
    SELECT pg_catalog.obj_description(c.oid, 'pg_class')
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'oban_jobs' AND n.nspname = $1 AND c.relkind IN ('r', 'p')
    """

    case repo.query!(query, [prefix], log: false) do
      %{rows: []} -> :no_table
      %{rows: [[comment] | _]} -> {:comment, comment}
    end
  end

  @doc false
  # Pure: the status for a catalog answer and the library's version.
  @spec classify(:no_table | {:comment, String.t() | nil}, pos_integer()) :: status()
  def classify(:no_table, _expected), do: :no_table

  def classify({:comment, comment}, expected) when is_binary(comment) do
    case String.trim(comment) do
      "∞" -> {:current, :infinity}
      trimmed -> classify_number(trimmed, comment, expected)
    end
  end

  def classify({:comment, nil}, _expected), do: {:unversioned, nil}

  defp classify_number(trimmed, comment, expected) do
    case Integer.parse(trimmed) do
      {migrated, ""} when migrated > 0 and migrated == expected -> {:current, migrated}
      {migrated, ""} when migrated > 0 and migrated < expected -> {:behind, migrated, expected}
      {migrated, ""} when migrated > 0 -> {:ahead, migrated, expected}
      _ -> {:unversioned, comment}
    end
  end

  @typedoc "A schema to check: the repo it lives on, and its prefix."
  @type target :: {module(), String.t()}

  @doc """
  The schemas worth checking: PhoenixKit's prefix on the host repo (where its
  baseline created Oban's tables), and the prefix the host's Oban config runs
  at — on the repo that config names, defaulting to the host repo — when that
  is a different schema. Oban defaults to `"public"` when its config names no
  prefix. A config that is not a keyword list (built at runtime) adds nothing.

      iex> PhoenixKit.ObanSchema.targets(MyApp.Repo, "auth", repo: MyApp.Repo, prefix: "auth")
      [{MyApp.Repo, "auth"}]

      iex> PhoenixKit.ObanSchema.targets(MyApp.Repo, "auth", repo: MyApp.Repo)
      [{MyApp.Repo, "auth"}, {MyApp.Repo, "public"}]

      iex> PhoenixKit.ObanSchema.targets(MyApp.Repo, "public", repo: MyApp.JobsRepo)
      [{MyApp.Repo, "public"}, {MyApp.JobsRepo, "public"}]

      iex> PhoenixKit.ObanSchema.targets(MyApp.Repo, "public", repo: {MyApp.JobsRepo, []})
      [{MyApp.Repo, "public"}, {MyApp.JobsRepo, "public"}]

      iex> PhoenixKit.ObanSchema.targets(MyApp.Repo, "public", nil)
      [{MyApp.Repo, "public"}]
  """
  @spec targets(module(), String.t(), term()) :: [target()]
  def targets(host_repo, phoenix_kit_prefix, oban_config) do
    Enum.uniq([{host_repo, phoenix_kit_prefix} | oban_target(host_repo, oban_config)])
  end

  defp oban_target(host_repo, oban_config) do
    if Keyword.keyword?(oban_config || :none) do
      repo =
        case Keyword.get(oban_config, :repo) do
          repo when is_atom(repo) and not is_nil(repo) -> repo
          # Oban 2.24 also takes `{repo, opts}` (per-repo options)
          {repo, opts} when is_atom(repo) and not is_nil(repo) and is_list(opts) -> repo
          _ -> host_repo
        end

      case Keyword.get(oban_config, :prefix, "public") do
        prefix when is_binary(prefix) -> [{repo, prefix}]
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Checks every target. Returns `{label, status}` pairs for the tasks' output:
  the label is the prefix, with the repo in front when it is not `host_repo`.
  """
  @spec check_all(module(), [target()]) :: [{String.t(), status()}]
  def check_all(host_repo, targets) do
    Enum.map(targets, fn {repo, prefix} = target ->
      {label(target, host_repo), check(repo, prefix)}
    end)
  end

  @doc false
  @spec label(target(), module()) :: String.t()
  def label({host_repo, prefix}, host_repo), do: prefix
  def label({repo, prefix}, _host_repo), do: "#{inspect(repo)} #{prefix}"

  @doc """
  The filename suffix of the migration that brings `prefix` from `from` to
  `to` — the part after the timestamp, which is what makes a second run find
  the first run's file instead of writing another.

      iex> PhoenixKit.ObanSchema.migration_suffix("public", 13, 14)
      "phoenix_kit_update_oban_v13_to_v14.exs"

      iex> PhoenixKit.ObanSchema.migration_suffix("auth", 13, 14)
      "phoenix_kit_update_oban_auth_v13_to_v14.exs"
  """
  @spec migration_suffix(String.t(), non_neg_integer(), pos_integer()) :: String.t()
  def migration_suffix(prefix, from, to) do
    "phoenix_kit_update_oban#{prefix_part(prefix, "_")}_v#{pad(from)}_to_v#{pad(to)}.exs"
  end

  @doc """
  The source of the host migration bringing `prefix` from `from` to `to`.

  `namespace` is the module namespace of the repo's migrations
  (`"MyApp.Repo.Migrations"`). The prefix must pass `generatable_prefix?/1`
  (it goes into the module name) — anything else raises `ArgumentError`. `create_schema:
  false` because the schema already holds `oban_jobs` — and a low-privilege
  role cannot `CREATE SCHEMA`, even `IF NOT EXISTS`. `down` passes `from + 1`:
  `Oban.Migration.down/1` reverts every version down to and including the one
  it is given.
  """
  @spec migration_source(String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          String.t()
  def migration_source(namespace, prefix, from, to) do
    ensure_generatable!(prefix)

    """
    defmodule #{namespace}.#{module_name(prefix, from, to)} do
      @moduledoc false
      use Ecto.Migration

      # Oban's schema follows the Oban library, not PhoenixKit's migration
      # chain. Written by mix phoenix_kit.update: the schema at "#{prefix}" was
      # at Oban version #{from}, the installed Oban expects #{to}.

      def up do
        Oban.Migration.up(version: #{to}, prefix: "#{prefix}", create_schema: false)
      end

      def down do
        Oban.Migration.down(version: #{from + 1}, prefix: "#{prefix}")
      end
    end
    """
  end

  @doc """
  Writes the migration into `dir` unless a file for the same step is already
  there (an earlier run wrote it and it was never applied — a second copy
  would carry a duplicate module name, which Ecto refuses outright).

  `timestamp` is the migration version to put in front of a new file. The
  prefix must pass `generatable_prefix?/1`, as for `migration_source/4`.
  """
  @spec write_migration(
          Path.t(),
          String.t(),
          String.t(),
          {non_neg_integer(), pos_integer()},
          String.t()
        ) :: {:created, Path.t()} | {:exists, Path.t()}
  def write_migration(dir, namespace, prefix, {from, to}, timestamp) do
    ensure_generatable!(prefix)
    suffix = migration_suffix(prefix, from, to)

    case Path.wildcard(Path.join(dir, "*_" <> suffix)) do
      [existing | _] ->
        {:exists, existing}

      [] ->
        File.mkdir_p!(dir)
        path = Path.join(dir, "#{timestamp}_#{suffix}")
        File.write!(path, migration_source(namespace, prefix, from, to))
        {:created, path}
    end
  end

  @typedoc """
  One checked target, as `stage/4` returns it. `file` is what happened to the
  migration: written, found from an earlier run, refused (a schema name that
  cannot go into a filename, or a schema on another repo than the one the
  migrations are written for), failed to write, or `nil` when nothing was due.
  """
  @type staged :: %{
          repo: module(),
          prefix: String.t(),
          status: status(),
          file:
            {:created, Path.t()}
            | {:exists, Path.t()}
            | :not_generatable
            | :other_repo
            | {:error, String.t()}
            | nil
        }

  @doc """
  Checks every target and writes the step-up migration into `dir` — the
  migrations directory of `host_repo` — for each one on `host_repo` that is
  behind. That is what `mix phoenix_kit.update` does before it migrates,
  independent of whether PhoenixKit's own chain had anything to do.

  A behind schema on another repo gets no file (`:other_repo`): it would be
  applied to `host_repo`'s database. `timestamp` is called with the entry's
  index for each file written. A failed write is returned, not raised, so one
  schema cannot take the rest of the update down with it.
  """
  @spec stage(module(), [target()], Path.t(), (non_neg_integer() -> String.t())) :: [staged()]
  def stage(host_repo, targets, dir, timestamp) do
    namespace = migrations_namespace(host_repo)

    targets
    |> Enum.with_index()
    |> Enum.map(fn {{repo, prefix}, index} ->
      status = check(repo, prefix)

      file =
        if repo == host_repo,
          do: stage_file(status, prefix, dir, namespace, timestamp, index),
          else: other_repo_file(status)

      %{repo: repo, prefix: prefix, status: status, file: file}
    end)
  end

  defp stage_file({:behind, from, to}, prefix, dir, namespace, timestamp, index) do
    if generatable_prefix?(prefix) do
      write_migration(dir, namespace, prefix, {from, to}, timestamp.(index))
    else
      :not_generatable
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp stage_file(_status, _prefix, _dir, _namespace, _timestamp, _index), do: nil

  defp other_repo_file({:behind, _from, _to}), do: :other_repo
  defp other_repo_file(_status), do: nil

  @doc """
  The module namespace for a repo's migrations, as `mix ecto.gen.migration`
  names them.

      iex> PhoenixKit.ObanSchema.migrations_namespace(MyApp.Repo)
      "MyApp.Repo.Migrations"
  """
  @spec migrations_namespace(module()) :: String.t()
  def migrations_namespace(repo), do: inspect(repo) <> ".Migrations"

  @doc """
  Whether `prefix` can be written into a migration's filename and module
  name. Oban accepts any schema name; a generated file only takes plain ones
  (`\\A`/`\\z`, not `^`/`$`: a trailing newline must not pass).
  """
  @spec generatable_prefix?(String.t()) :: boolean()
  def generatable_prefix?(prefix) when is_binary(prefix),
    do: Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, prefix)

  def generatable_prefix?(_prefix), do: false

  defp ensure_generatable!(prefix) do
    unless generatable_prefix?(prefix) do
      raise ArgumentError,
            "cannot write an Oban migration for schema #{inspect(prefix)}: " <>
              "only lower-case letters, digits and underscores go into its file and module name"
    end
  end

  @doc """
  One line describing a status, for the tasks' output.

      iex> PhoenixKit.ObanSchema.describe({:behind, 13, 14})
      "schema v13, Oban expects v14"
  """
  @spec describe(status()) :: String.t()
  def describe({:current, :infinity}),
    do: "v∞ — marked as never needing migration, which Oban honours"

  def describe({:current, version}), do: "v#{version}, matches Oban"

  def describe({:behind, migrated, expected}),
    do: "schema v#{migrated}, Oban expects v#{expected}"

  def describe({:ahead, migrated, expected}),
    do: "schema v#{migrated} is newer than this Oban (v#{expected})"

  def describe(:no_table), do: "no oban_jobs table"

  def describe({:unversioned, comment}),
    do: "oban_jobs has no readable version comment (#{inspect(comment)})"

  def describe({:unsupported_adapter, adapter}),
    do: "#{inspect(adapter)} is not Postgres; not checked"

  def describe({:error, reason}), do: "could not read: #{format_reason(reason)}"

  @doc """
  Logs one warning when the schema the running Oban instance uses is behind
  the library. Called once per boot, after the host has had time to start
  Oban; reads the repo and prefix from Oban itself, so it checks what is
  actually in use. Best-effort: silent without Oban, in testing mode, or when
  the database cannot answer, and never raises.
  """
  @spec warn_if_behind(keyword()) :: :ok
  def warn_if_behind(opts \\ []) do
    oban_name = Keyword.get(opts, :oban, Oban)

    with true <- Code.ensure_loaded?(Oban),
         pid when is_pid(pid) <- Oban.whereis(oban_name),
         %{testing: :disabled, repo: repo, prefix: prefix} when is_binary(prefix) <-
           Oban.config(oban_name),
         {:behind, _migrated, _expected} = status <- check(repo, prefix) do
      Logger.warning(boot_warning(prefix, status))
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  @spec boot_warning(String.t(), status()) :: String.t()
  def boot_warning(prefix, {:behind, _migrated, _expected} = status) do
    "[PhoenixKit] Oban #{describe(status)} at prefix #{inspect(prefix)} — unique job " <>
      "inserts (cron included) fail until it is migrated. Run `mix phoenix_kit.update`."
  end

  # The prefix goes in verbatim: `Macro.camelize/1` folds distinct schema
  # names together ("a_1b" and "a1b" both become "A1b"), and two migrations
  # with one module name cannot both load. An alias segment may carry
  # underscores and digits after its capital.
  defp module_name("public", from, to), do: "PhoenixKitUpdateObanV#{pad(from)}ToV#{pad(to)}"

  defp module_name(prefix, from, to),
    do: "PhoenixKitUpdateOban_#{prefix}_V#{pad(from)}ToV#{pad(to)}"

  defp prefix_part("public", _sep), do: ""
  defp prefix_part(prefix, sep), do: sep <> prefix

  defp pad(version) when version < 10, do: "0#{version}"
  defp pad(version), do: to_string(version)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
