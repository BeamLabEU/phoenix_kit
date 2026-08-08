defmodule PhoenixKit.Migrations do
  @moduledoc false

  defdelegate up(opts \\ []), to: PhoenixKit.Migration
  defdelegate down(opts \\ []), to: PhoenixKit.Migration
end

defmodule PhoenixKit.Migration do
  @moduledoc """
  Migrations create and modify the database tables PhoenixKit needs to function.

  ## Usage

  To use migrations in your application you'll need to generate an `Ecto.Migration` that wraps
  calls to `PhoenixKit.Migration`:

  ```bash
  mix ecto.gen.migration add_phoenix_kit
  ```

  Open the generated migration in your editor and call the `up` and `down` functions on
  `PhoenixKit.Migration`:

  ```elixir
  defmodule MyApp.Repo.Migrations.AddPhoenixKit do
    use Ecto.Migration

    def up, do: PhoenixKit.Migrations.up()

    def down, do: PhoenixKit.Migrations.down()
  end
  ```

  This will run all of PhoenixKit's versioned migrations for your database.

  Now, run the migration to create the table:

  ```bash
  mix ecto.migrate
  ```

  Migrations between versions are idempotent. As new versions are released, you may need to run
  additional migrations. To do this, generate a new migration:

  ```bash
  mix ecto.gen.migration upgrade_phoenix_kit_to_v2
  ```

  Open the generated migration in your editor and call the `up` and `down` functions on
  `PhoenixKit.Migration`, passing a version number:

  ```elixir
  defmodule MyApp.Repo.Migrations.UpgradePhoenixKitToV2 do
    use Ecto.Migration

    def up, do: PhoenixKit.Migrations.up(version: 2)

    def down, do: PhoenixKit.Migrations.down(version: 2)
  end
  ```

  ## Isolation with Prefixes

  PhoenixKit supports namespacing through PostgreSQL schemas, also called "prefixes" in Ecto. With
  prefixes your auth tables can reside outside of your primary schema (usually public) and you can
  have multiple separate auth systems.

  To use a prefix you first have to specify it within your migration:

  ```elixir
  defmodule MyApp.Repo.Migrations.AddPrefixedPhoenixKitTables do
    use Ecto.Migration

    def up, do: PhoenixKit.Migrations.up(prefix: "auth")

    def down, do: PhoenixKit.Migrations.down(prefix: "auth")
  end
  ```

  The migration will create the "auth" schema and all tables within
  that schema. With the database migrated you'll then specify the prefix in your configuration:

  ```elixir
  config :phoenix_kit,
    prefix: "auth",
    ...
  ```

  That config entry is written automatically by
  `mix phoenix_kit.install --prefix "auth"` and does two things:

    * **Runtime queries target the schema.** Every PhoenixKit Ecto schema
      compiles the prefix in (via `PhoenixKit.SchemaPrefix`), so reads and
      writes hit `auth.phoenix_kit_*` directly — no `search_path` setup on
      the database role is needed for core. This is compile-time
      configuration: set it in `config/config.exs` (not `runtime.exs`);
      changing it recompiles the phoenix_kit dependency on the next
      `mix compile`. A build compiled before the config change refuses
      to boot with a clear compile-env mismatch error (it never silently
      queries `public`) — any `mix phx.server`, `ecto.migrate`, or
      release build after the install triggers the recompile.

      Caveat: PhoenixKit *feature modules* (`phoenix_kit_catalogue`,
      `phoenix_kit_projects`, …) define their own Ecto schemas, which
      only honor the prefix once that module also adopts
      `PhoenixKit.SchemaPrefix`. Until the modules you use have it, a
      prefixed install running feature modules still needs the schema on
      the role's `search_path`:

      ```sql
      ALTER ROLE my_app_role SET search_path = auth, public;
      ```
    * **Tooling finds the install.** `mix phoenix_kit.update` / `status` /
      `gen.migration` resolve the prefix from config when `--prefix`
      isn't passed.

  Oban needs the prefix too — its tables are created inside the same
  schema, so the host's Oban config must carry it (the installer adds
  this for new prefixed installs):

  ```elixir
  config :my_app, Oban,
    prefix: "auth",
    repo: MyApp.Repo,
    ...
  ```

  In some cases, for example if your "auth" schema already exists and your database user in
  production doesn't have permissions to create a new schema, trying to create the schema from the
  migration will result in an error. In such situations, it may be useful to inhibit the creation
  of the "auth" schema:

  ```elixir
  defmodule MyApp.Repo.Migrations.AddPrefixedPhoenixKitTables do
    use Ecto.Migration

    def up, do: PhoenixKit.Migrations.up(prefix: "auth", create_schema: false)

    def down, do: PhoenixKit.Migrations.down(prefix: "auth")
  end
  ```

  The prefix must be a conventional lower-case identifier (`[a-z_][a-z0-9_]*`) —
  it is interpolated into SQL, and anything else is rejected at the `up`/`down`
  entry points.

  One requirement for *upgrading* an existing prefixed install: the migrating
  role needs `CREATE` on the install's schema, because newer versions ensure a
  schema-local `uuid_generate_v7()` there (older releases created it wherever
  `search_path` pointed, typically `public`). If the schema is DBA-owned and
  the role only has `USAGE`, have the DBA grant `CREATE` for the migration or
  pre-create the function in the schema.

  ## Required Postgres extensions

  The migration chain needs three extensions: `citext` (case-insensitive
  emails), `pgcrypto` (UUIDv7 generation), and `pg_trgm` (trigram search).
  When they are already installed the chain never issues `CREATE EXTENSION`
  (so no database-level CREATE privilege is needed). When one is missing, the
  migrating role must be allowed to create it — on locked-down databases have
  a DBA pre-provision them instead:

  ```sql
  CREATE EXTENSION IF NOT EXISTS citext;
  CREATE EXTENSION IF NOT EXISTS pgcrypto;
  CREATE EXTENSION IF NOT EXISTS pg_trgm;
  ```

  ## Migrating Without Ecto

  If your application uses something other than Ecto for migrations, be it an external system or
  another ORM, it may be helpful to create plain SQL migrations for PhoenixKit database schema changes.

  The simplest mechanism for obtaining the SQL changes is to create the migration locally and run
  `mix ecto.migrate --log-migrations-sql`. That will log all of the generated SQL, which you can
  then paste into your migration system of choice.
  """

  use Ecto.Migration

  @doc """
  Migrates storage up to the latest version.
  """
  @callback up(Keyword.t()) :: :ok

  @doc """
  Migrates storage down to the previous version.
  """
  @callback down(Keyword.t()) :: :ok

  @doc """
  Identifies the last migrated version.
  """
  @callback migrated_version(Keyword.t()) :: non_neg_integer()

  @doc """
  Run the `up` changes for all migrations between the initial version and the current version.

  ## Example

  Run all migrations up to the current version:

      PhoenixKit.Migration.up()

  Run migrations up to a specified version:

      PhoenixKit.Migration.up(version: 2)

  Run migrations in an alternate prefix:

      PhoenixKit.Migration.up(prefix: "auth")

  Run migrations in an alternate prefix but don't try to create the schema:

      PhoenixKit.Migration.up(prefix: "auth", create_schema: false)
  """
  def up(opts \\ []) when is_list(opts) do
    migrator().up(opts)
  end

  @doc """
  Run the `down` changes for all migrations between the current version and the initial version.

  ## Example

  Run all migrations from current version down to the first:

      PhoenixKit.Migration.down()

  Run migrations down to and including a specified version:

      PhoenixKit.Migration.down(version: 1)

  Run migrations in an alternate prefix:

      PhoenixKit.Migration.down(prefix: "auth")
  """
  def down(opts \\ []) when is_list(opts) do
    migrator().down(opts)
  end

  @doc """
  Check the latest version the database is migrated to.

  ## Example

      PhoenixKit.Migration.migrated_version()
  """
  def migrated_version(opts \\ []) when is_list(opts) do
    migrator().migrated_version(opts)
  end

  @doc """
  Idempotently brings `repo` up to the latest PhoenixKit migration version.

  Designed for test helpers and re-runnable boot paths where the
  database is long-lived but the calling process restarts on every
  invocation.

  ## Why this exists

  The natural-looking pattern

      Ecto.Migrator.run(repo, [{0, PhoenixKit.Migration}], :up, all: true)

  is broken for re-runnable contexts: `Ecto.Migrator` records "version
  0 applied" in `schema_migrations` after the first call and filters
  `{0, PhoenixKit.Migration}` out of pending on every subsequent call.
  `PhoenixKit.Migration.up/1` is never re-invoked, so newly-shipped
  Vxxx migrations don't get applied even though PhoenixKit's own marker
  (the comment on the `phoenix_kit` table) is itself idempotent.

  `ensure_current/2` works around that by passing a fresh wall-clock
  version (`:os.system_time(:microsecond)`) to `Ecto.Migrator.up/4` on
  every call. Ecto sees a "new" migration each time and invokes the
  inner runner; PhoenixKit's marker then short-circuits if there's
  nothing new to apply. The `schema_migrations` table accumulates one
  row per call — cosmetic noise acceptable for the test-DB use case.
  Microsecond precision keeps the collision and clock-skew windows
  small enough that an NTP correction would have to rewind the clock
  by µs at exactly the wrong moment to hide a newly-shipped migration.

  For one-shot production migrations, prefer the documented
  `mix ecto.migrate` path with a hand-rolled migration that calls
  `PhoenixKit.Migration.up/1` directly.

  ## Options

  Forwarded verbatim to `Ecto.Migrator.up/4` and through to
  `PhoenixKit.Migration.up/1`. Common values:

    * `:log` — Ecto-level migration log (`:info` default; `false` to
      silence)
    * `:prefix` — runs PhoenixKit's tables under a non-default schema

  ## Return contract

  Returns `:ok` on success. Failures (advisory-lock contention,
  migration crashes, connection errors) propagate as raises from
  `Ecto.Migrator.up/4`; `ensure_current/2` does not wrap them in
  `{:error, _}`.

  ## Example

      # In test/test_helper.exs
      PhoenixKit.Migration.ensure_current(MyApp.Test.Repo, log: false)
  """
  @spec ensure_current(Ecto.Repo.t(), keyword()) :: :ok
  def ensure_current(repo, opts \\ []) do
    # Microsecond precision (rather than millisecond) shrinks the
    # collision and clock-skew windows by 1000x. Two concurrent calls
    # within the same microsecond would still collide, but in practice
    # `ensure_current/2` runs once per `mix test` invocation. Bigint-
    # safe (Postgres `bigint` covers ~9 quintillion microseconds, ~292
    # years).
    Ecto.Migrator.up(
      repo,
      :os.system_time(:microsecond),
      PhoenixKit.Migration.Runner,
      opts
    )

    :ok
  rescue
    # Below-floor DB (spec §5.2): re-raise with the test/CI-database hint
    # `PhoenixKit.Migrations.BelowFloorError.message/1` only appends for
    # `context: :ensure_current` — "install the bridge" is the wrong advice
    # for this call site's actual common case, a persistent below-floor CI
    # database (GLM M6). Ecto.Migrator's own mechanics above are untouched;
    # this only decorates whatever `PhoenixKit.Migration.up/1` (reached
    # through `PhoenixKit.Migration.Runner.up/0`) already raised.
    e in PhoenixKit.Migrations.BelowFloorError ->
      reraise %{e | context: :ensure_current}, __STACKTRACE__
  end

  defp migrator do
    case repo().__adapter__() do
      Ecto.Adapters.Postgres ->
        PhoenixKit.Migrations.Postgres

      # There is no SQLite or MyXQL migrator: the versioned chain is
      # PostgreSQL-only (citext, pgcrypto, pg_trgm, uuid_generate_v7, JSONB,
      # partial and expression indexes). The clauses that used to name
      # PhoenixKit.Migrations.SQLite / .MyXQL pointed at modules that have
      # never existed and would have raised UndefinedFunctionError the moment
      # anything reached them. A host on another adapter must supply its own
      # migrator explicitly.
      adapter ->
        case Keyword.fetch(repo().config(), :phoenix_kit_migrator) do
          {:ok, migrator} ->
            migrator

          :error ->
            raise ArgumentError, """
            PhoenixKit migrations require PostgreSQL, but #{inspect(repo())} uses             #{inspect(adapter)}.

            The versioned chain depends on PostgreSQL-only features (citext,             pgcrypto, pg_trgm, JSONB, partial and expression indexes), so there             is no built-in migrator for other adapters. If you have your own,             configure it:

                config :my_app, #{inspect(repo())}, phoenix_kit_migrator: MyApp.Migrator
            """
        end
    end
  end
end

defmodule PhoenixKit.Migration.Runner do
  @moduledoc false
  # Static `Ecto.Migration` wrapper consumed by
  # `PhoenixKit.Migration.ensure_current/2`. Lives at module scope (not
  # an anonymous one defined per call) so `Ecto.Migrator.up/4` can
  # resolve `up/0` and `down/0` against a known module name.
  #
  # `prefix/0` is imported by `use Ecto.Migration` and reads the
  # current migration's prefix from the runner's process state. When
  # `ensure_current/2` is called with `prefix: "auth"`, Ecto.Migrator
  # propagates that into the runner context; without forwarding it
  # back into `PhoenixKit.Migration.up/1` here, the inner migrator
  # would default to `"public"` and silently apply the migrations to
  # the wrong schema.

  use Ecto.Migration

  def up, do: PhoenixKit.Migration.up(runner_opts(prefix()))
  def down, do: PhoenixKit.Migration.down(runner_opts(prefix()))

  # Pure transform of the runner-context prefix into opts threaded to
  # `PhoenixKit.Migration.up/1` / `down/1`. Split out of `up/0` and
  # `down/0` so it can be regression-tested without standing up a real
  # `Ecto.Migration.Runner` process — see
  # `test/phoenix_kit/migration_test.exs`.
  #
  # `prefix/0` returns nil when no `:prefix` opt was passed to
  # `Ecto.Migrator.up/4`. Forwarding `prefix: nil` to PhoenixKit's
  # migrator would override the `"public"` default in `with_defaults/2`
  # and crash inside `String.replace/4`. Only thread `:prefix` when it's
  # actually set.
  @doc false
  def runner_opts(nil), do: []
  def runner_opts(prefix), do: [prefix: prefix]
end
