defmodule PhoenixKit.Migrations.Postgres.Helpers do
  @moduledoc """
  Shared SQL helpers for the versioned Postgres migration chain.

  Centralizes the prefix-sensitive patterns that individual version
  modules used to hand-roll (and get subtly wrong in independent ways):

    * `qualify_table/2` — schema-qualified table reference for raw SQL
      in NEW migration code (existing versions keep their local helpers;
      migrating them is opportunistic). Index **names** must stay bare on
      `CREATE INDEX` (Postgres rejects `CREATE INDEX schema.name`); only
      `DROP INDEX schema.name` accepts a qualified name.
    * `validate_prefix!/1` — rejects prefixes that can't be interpolated
      into SQL safely. Called at the `up/down` entry points and by the
      prefix-resolving tooling (`PrefixConfig.resolve_prefix/1`,
      `Install.Common`).
    * `ensure_extension!/1` — privilege-aware replacement for a bare
      `CREATE EXTENSION IF NOT EXISTS`. Postgres checks the CREATE
      privilege *before* the IF-NOT-EXISTS short-circuit, so the bare
      statement fails for low-privilege roles even when the extension is
      already installed. This helper checks `pg_extension` first and
      only attempts creation when the extension is genuinely missing.
    * `ensure_uuid_v7_function/1` — creates `uuid_generate_v7()` inside
      the install's schema (never wherever `search_path` happens to
      point, which pollutes `public` and fails outright on PG15+ where
      `public` isn't world-writable). Unlike `ensure_extension!/1`, this
      one does NOT pre-check existence — it always queues `CREATE OR
      REPLACE FUNCTION`, unconditionally. That is deliberate, not a missed
      optimization: an `unless already exists` guard here (the original
      shape) meant a function created before some later fix to this same
      body (e.g. the pgcrypto schema-qualification change) stayed on the
      OLD body forever — `CREATE OR REPLACE` never got a chance to run
      because the guard always saw "exists" and skipped it, and there was
      no other path back to a correct body short of a manual `DROP`.
      `CREATE OR REPLACE FUNCTION` on an unchanged signature is additive
      and idempotent (no dependent objects break, nothing is dropped), so
      the guard bought nothing but a stuck body — removing it is what lets
      `PhoenixKit.Migrations.Repair` self-heal a drifted body via this
      same helper instead of reporting a permanent, un-fixable finding.

  Functions without a `repo` argument run in `Ecto.Migration` context
  (immediate existence checks via `repo().query/3`, DDL queued via
  `execute/1`). The `repo`-taking variants are for runtime callers outside
  a migration context, e.g. `mix phoenix_kit.repair`.
  """

  @prefix_format ~r/^[a-z_][a-z0-9_]*$/

  # The V26/V56 conventions embed the schema PREFIX directly into a handful
  # of index names (`"#{prefix}_" <> base_name`, materialized by
  # `PhoenixKit.Migrations.ExpectedSchema.Object.materialize/2`'s
  # `__PK_NAME_EXEMPT__`/`__PK_NAME_ALWAYS__` markers) rather than only
  # schema-qualifying a table reference. Postgres silently TRUNCATES any
  # identifier over its 63-byte NAMEDATALEN instead of rejecting it, so a
  # long enough prefix collides two different prefixes' embedded names into
  # the same truncated string, or drifts from what the manifest expects to
  # see forever — verified live: `PhoenixKit.Migrations.Repair`'s repair
  # engine never converges past a 21-byte prefix (3 permanent `:repairable`
  # findings, S8 idempotence violated). `@longest_embedded_object_name` is
  # measured from `expected_schema.ex`'s longest `__PK_NAME_*__` base
  # (currently "phoenix_kit_user_role_assignments_uuid_idx" /
  # "phoenix_kit_shop_shipping_methods_uuid_idx" /
  # "phoenix_kit_files_user_file_checksum_index", all 42 bytes) — mirrors
  # `dev_docs/squash/verify.exs`'s own `@longest_embedded_object_name`/
  # `@max_schema_bytes` budget for the identical reason. A DB-free test
  # (`test/phoenix_kit/migrations/postgres_helpers_test.exs`) scans the
  # manifest source for a longer embedded name and fails loudly if one ever
  # ships, so this constant cannot silently drift out of sync.
  @longest_embedded_object_name 42
  @max_prefix_bytes 63 - 1 - @longest_embedded_object_name

  @required_extensions %{
    "citext" => "case-insensitive email storage (V01)",
    "pgcrypto" => "UUIDv7 generation via gen_random_bytes (V26/V40)",
    "pg_trgm" => "trigram search on PDF page content (V111)"
  }

  # gen_random_bytes/1 comes from pgcrypto and is qualified with pgcrypto's
  # actual installation schema at creation time — a plpgsql body resolves
  # identifiers via the CALLER's search_path at execution, so an unqualified
  # call would fail for roles whose search_path excludes pgcrypto's schema
  # (defeating the point of a schema-qualified uuid_generate_v7()).
  defp uuid_v7_function_body(pgcrypto_schema) do
    """
    RETURNS uuid AS $$
    DECLARE
      unix_ts_ms bytea;
      uuid_bytes bytea;
    BEGIN
      -- Get current timestamp in milliseconds
      unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);

      -- Build UUIDv7: 6 bytes timestamp + 2 bytes random (with version) + 8 bytes random (with variant)
      uuid_bytes := unix_ts_ms || #{pgcrypto_schema}.gen_random_bytes(10);

      -- Set version 7 (0111xxxx in byte 7)
      uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);

      -- Set variant (10xxxxxx in byte 9)
      uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);

      RETURN encode(uuid_bytes, 'hex')::uuid;
    END
    $$ LANGUAGE plpgsql VOLATILE;
    """
  end

  @doc """
  Schema-qualified table reference for raw SQL interpolation.

  `nil` and `"public"` both qualify explicitly as `public.` — an
  explicit schema never depends on the connection's `search_path`.
  """
  @spec qualify_table(String.t() | atom(), String.t() | nil) :: String.t()
  def qualify_table(table, nil), do: "public.#{table}"
  def qualify_table(table, prefix), do: "#{prefix}.#{table}"

  @doc """
  Whether the prefix denotes the default `public` schema (`nil` counts).
  """
  @spec public_prefix?(String.t() | nil) :: boolean()
  def public_prefix?(prefix), do: prefix in [nil, "public"]

  @doc """
  Schema-qualified `uuid_generate_v7()` call for SQL interpolation.
  """
  @spec uuid_v7_call(String.t() | nil) :: String.t()
  def uuid_v7_call(prefix), do: "#{schema(prefix)}.uuid_generate_v7()"

  @doc """
  Schema-qualified pgcrypto function reference for SQL interpolation in
  migration context, e.g. `"\#{Helpers.pgcrypto_call("digest")}(...)"`.

  Resolves pgcrypto's actual installation schema (same lookup used by
  `ensure_uuid_v7_function/1`) so the call works regardless of the
  connecting role's `search_path` — required whenever pgcrypto was
  installed outside the default search path (e.g. alongside a custom
  prefix schema in a hardened multi-schema install). Call after
  `ensure_extension!("pgcrypto")` so the extension is already visible.
  """
  @spec pgcrypto_call(String.t()) :: String.t()
  def pgcrypto_call(function_name),
    do: "#{pgcrypto_schema(Ecto.Migration.repo())}.#{function_name}"

  @doc """
  Validates a schema prefix before it is interpolated into SQL.

  The migration chain interpolates the prefix into hundreds of
  statements, mostly unquoted, so only conventional lower-case
  identifiers are supported: `#{inspect(@prefix_format.source)}`.
  Raises `ArgumentError` for anything else (including uppercase or
  dashed names, which only ever half-worked) — including a prefix over
  `#{@max_prefix_bytes}` bytes, which fits every conventional prefix a real
  install uses but rejects the ones that would silently truncate a
  prefix-embedded object name (see `@longest_embedded_object_name` above)
  past Postgres's 63-byte NAMEDATALEN.
  """
  @spec validate_prefix!(term()) :: :ok
  def validate_prefix!(prefix) when is_binary(prefix) do
    cond do
      not Regex.match?(@prefix_format, prefix) ->
        raise ArgumentError, """
        invalid PhoenixKit schema prefix: #{inspect(prefix)}

        The prefix is interpolated into SQL identifiers, so it must match
        #{inspect(@prefix_format.source)} (lower-case letters, digits and
        underscores, not starting with a digit) — e.g. "auth" or "my_app".
        """

      byte_size(prefix) > @max_prefix_bytes ->
        raise ArgumentError, """
        invalid PhoenixKit schema prefix: #{inspect(prefix)} (#{byte_size(prefix)} bytes)

        The V26/V56 conventions embed the prefix directly into a handful of
        index names — the longest is #{@longest_embedded_object_name} bytes
        (e.g. "phoenix_kit_user_role_assignments_uuid_idx") — and Postgres
        silently TRUNCATES any identifier over its 63-byte NAMEDATALEN
        rather than rejecting it, which the migration chain and
        `PhoenixKit.Migrations.Repair` cannot detect after the fact. The
        prefix must therefore be at most #{@max_prefix_bytes} bytes
        (63 - 1 - #{@longest_embedded_object_name}).
        """

      true ->
        :ok
    end
  end

  def validate_prefix!(prefix) do
    raise ArgumentError,
          "invalid PhoenixKit schema prefix: expected a string, got #{inspect(prefix)}"
  end

  @doc """
  Ensures a Postgres extension is available, in migration context.

  * already installed → no-op (skips the `CREATE EXTENSION` privilege
    check entirely, so pre-provisioned low-privilege setups pass)
  * missing + role can create → queues `CREATE EXTENSION IF NOT EXISTS`
  * missing + role cannot create → raises an operator-facing error
    listing the extensions to pre-create as a privileged role
  """
  @spec ensure_extension!(String.t()) :: :ok
  def ensure_extension!(name) do
    # Creation runs IMMEDIATELY (repo().query!) rather than queued via
    # execute/1 — so a later ensure_uuid_v7_function/1 in the same version
    # sees the extension in pg_extension and resolves pgcrypto's real
    # schema instead of falling back to public. Also guarantees the
    # citext type exists before any queued CREATE TABLE that uses it.
    repo = Ecto.Migration.repo()
    do_ensure_extension!(repo, name, fn sql -> repo.query!(sql, [], log: false) end)
  end

  @doc """
  Runtime variant of `ensure_extension!/1` for callers outside migration
  context (statements run immediately on `repo`).
  """
  @spec ensure_extension!(Ecto.Repo.t(), String.t()) :: :ok
  def ensure_extension!(repo, name) do
    do_ensure_extension!(repo, name, fn sql -> repo.query!(sql, [], log: false) end)
  end

  @doc """
  Ensures `uuid_generate_v7()` exists in the install's schema, in
  migration context.

  Unconditionally queues a schema-qualified `CREATE OR REPLACE FUNCTION` —
  no existence pre-check, on purpose (see moduledoc "`ensure_uuid_v7_function/1`").
  The schema must exist when this runs; V01 owns schema creation, so
  callers on the upgrade path (installed version > 0) are always safe.
  """
  @spec ensure_uuid_v7_function(String.t() | nil) :: :ok
  def ensure_uuid_v7_function(prefix) do
    do_ensure_uuid_v7_function(Ecto.Migration.repo(), prefix, &Ecto.Migration.execute/1)
  end

  @doc """
  Runtime variant of `ensure_uuid_v7_function/1` (statements run
  immediately on `repo`; raises on database errors via `repo.query!/3`).
  """
  @spec ensure_uuid_v7_function(Ecto.Repo.t(), String.t() | nil) :: :ok
  def ensure_uuid_v7_function(repo, prefix) do
    do_ensure_uuid_v7_function(repo, prefix, fn sql -> repo.query!(sql, [], log: false) end)
  end

  defp do_ensure_uuid_v7_function(repo, prefix, executor) do
    executor.("""
    CREATE OR REPLACE FUNCTION #{schema(prefix)}.uuid_generate_v7()
    #{uuid_v7_function_body(pgcrypto_schema(repo))}
    """)

    :ok
  rescue
    error ->
      # `CREATE OR REPLACE FUNCTION` requires OWNERSHIP of an existing
      # function. On a hardened install (the 2026-07-12 field report: schema
      # pre-created by a DBA, app role without CREATE) the function may already
      # exist owned by someone else — replacing it then fails with
      # insufficient_privilege. The previous `unless exists?` guard skipped
      # silently in that case; keeping the unconditional replace WITHOUT this
      # clause would turn a cosmetic body difference into an aborted migration,
      # which is strictly worse. So: if the function is already there, leave it
      # and say so; if it is genuinely absent, the failure is real and must
      # surface.
      if insufficient_privilege?(error) and uuid_v7_function_present?(repo, prefix) do
        IO.warn(
          "PhoenixKit: #{schema(prefix)}.uuid_generate_v7() exists but is owned by another " <>
            "role, so its body could not be refreshed (#{Exception.message(error)}). Leaving it " <>
            "in place. If it predates the pgcrypto-schema qualification, ask the owner to run " <>
            "the CREATE OR REPLACE from PhoenixKit.Migrations.Postgres.Helpers."
        )

        :ok
      else
        reraise error, __STACKTRACE__
      end
  end

  defp insufficient_privilege?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:insufficient_privilege, :duplicate_function]

  defp insufficient_privilege?(_), do: false

  defp uuid_v7_function_present?(repo, prefix) do
    case repo.query(
           """
           SELECT EXISTS (
             SELECT 1 FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE p.proname = 'uuid_generate_v7' AND n.nspname = $1
           )
           """,
           [schema(prefix)],
           log: false
         ) do
      {:ok, %{rows: [[present]]}} -> present
      _ -> false
    end
  rescue
    _ -> false
  end

  # Where pgcrypto actually lives. When the extension isn't visible yet
  # (its CREATE EXTENSION may be queued but not flushed on a fresh
  # chain), fall back to public — the default installation target. The
  # plpgsql body is only resolved at first call, by which point the
  # extension exists.
  defp pgcrypto_schema(repo) do
    query = """
    SELECT n.nspname FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'pgcrypto'
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[schema]]}} when is_binary(schema) -> schema
      _ -> "public"
    end
  end

  defp do_ensure_extension!(repo, name, executor) do
    # The name is interpolated into DDL — keep it to known extensions.
    unless Map.has_key?(@required_extensions, name) do
      raise ArgumentError, "unknown Postgres extension for PhoenixKit: #{inspect(name)}"
    end

    cond do
      extension_exists?(repo, name) ->
        :ok

      can_create_extension?(repo) ->
        executor.("CREATE EXTENSION IF NOT EXISTS #{name}")
        :ok

      true ->
        raise """
        PhoenixKit requires the Postgres extension '#{name}', which is not
        installed, and the current database role cannot create it.

        Pre-create the required extensions as a privileged role:

        #{Enum.map_join(@required_extensions, "\n", fn {ext, why} -> "    CREATE EXTENSION IF NOT EXISTS #{ext};  -- #{why}" end)}

        then re-run the migration.
        """
    end
  end

  defp extension_exists?(repo, name) do
    case repo.query("SELECT 1 FROM pg_extension WHERE extname = $1", [name], log: false) do
      {:ok, %{num_rows: rows}} -> rows > 0
      _ -> false
    end
  end

  # Trusted extensions (citext/pgcrypto/pg_trgm on PG13+) need CREATE on
  # the current database; superusers can always create. When in doubt
  # (query failure), report "can create" so the original CREATE EXTENSION
  # path — and its native error message — is preserved.
  defp can_create_extension?(repo) do
    query = """
    SELECT rolsuper OR has_database_privilege(current_database(), 'CREATE')
    FROM pg_roles WHERE rolname = current_user
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[allowed]]}} -> allowed == true
      _ -> true
    end
  end

  defp schema(prefix), do: if(public_prefix?(prefix), do: "public", else: prefix)
end
