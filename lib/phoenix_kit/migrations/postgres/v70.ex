defmodule PhoenixKit.Migrations.Postgres.V70 do
  @moduledoc """
  V70: Re-backfill UUID FK columns silently skipped in V56/V63.

  ## Background

  V56 introduced UUID FK companion columns (via UUIDFKColumns) with a backfill
  that populated each FK column from the corresponding source table's `uuid`
  column.  Two bugs in V56/V63 could cause the backfill to be skipped silently:

  1. **Type mismatch** — On databases where `phoenix_kit_email_logs.uuid` was
     created as `character varying` instead of the native PostgreSQL `uuid` type
     (because a manual migration pre-empted V40's proper ADD COLUMN), the
     backfill UPDATE fails with `ERROR 42804 datatype_mismatch`.

  2. **Broken rescue** — V56's `backfill_uuid_fk` had a `rescue _ -> :ok` clause
     intended to swallow the error.  However, a failed PostgreSQL statement puts
     the connection's transaction in an aborted state (ERROR 25P02), so all
     subsequent execute/1 calls fail even though Elixir caught the exception.
     The first error (type mismatch) is reported; the migration rolls back; the
     DB stays at v55.  Alternatively, if the migration somehow succeeded, the
     backfill was still skipped and `email_log_uuid` rows were filled with
     random UUIDs by `UUIDFKColumns.add_constraints/1`'s NULL-fill fallback.

  V63 had the same issue for `matched_email_log_uuid` without even a rescue.

  ## What This Migration Does

  1. Converts `phoenix_kit_email_logs.uuid` to native `uuid` type if still
     `character varying` (root-cause fix).

  2. Re-backfills `email_log_uuid` in `phoenix_kit_email_events`:
     - Rows whose `email_log_uuid` does NOT reference a real email log uuid
       (random UUID written by the NULL-fill fallback) are reset to NULL first.
     - Then the proper JOIN-based backfill is re-run.

  3. Re-backfills `matched_email_log_uuid` in `phoenix_kit_email_orphaned_events`
     (same pattern as above).

  All operations are idempotent — safe on every install, including fresh ones
  where the columns were backfilled correctly from the start.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = opts) do
    escaped_prefix = Map.get(opts, :escaped_prefix, prefix)

    flush()

    # Step 1: Ensure phoenix_kit_email_logs.uuid is native uuid type.
    fix_email_logs_uuid_type(prefix, escaped_prefix)

    # Flush so the type change is visible in the same transaction.
    flush()

    # Step 2: Re-backfill email_log_uuid in email_events.
    rebackfill_email_log_uuid(prefix, escaped_prefix)

    # Step 3: Re-backfill matched_email_log_uuid in email_orphaned_events.
    rebackfill_matched_email_log_uuid(prefix, escaped_prefix)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '70'")
  end

  def down(%{prefix: prefix} = _opts) do
    # No structural changes to reverse — backfill data is correct data.
    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '69'")
  end

  # ---------------------------------------------------------------------------
  # Step 1: Fix email_logs.uuid column type
  # ---------------------------------------------------------------------------

  defp fix_email_logs_uuid_type(prefix, escaped_prefix) do
    table = "phoenix_kit_email_logs"

    if table_exists?(table, escaped_prefix) do
      uuid_type_query = """
      SELECT data_type
      FROM information_schema.columns
      WHERE table_name = '#{table}'
        AND column_name = 'uuid'
        AND table_schema = '#{escaped_prefix}'
      """

      case repo().query(uuid_type_query, [], log: false) do
        {:ok, %{rows: [[dt]]}} when dt in ["character varying", "text", "character"] ->
          table_name = prefix_table(table, prefix)

          execute("""
          ALTER TABLE #{table_name}
          ALTER COLUMN uuid TYPE uuid USING uuid::uuid
          """)

        _ ->
          :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2: Re-backfill email_log_uuid in email_events
  # ---------------------------------------------------------------------------

  defp rebackfill_email_log_uuid(prefix, escaped_prefix) do
    events_table = "phoenix_kit_email_events"
    logs_table = "phoenix_kit_email_logs"

    if table_exists?(events_table, escaped_prefix) and
         table_exists?(logs_table, escaped_prefix) and
         column_exists?(events_table, "email_log_uuid", escaped_prefix) and
         column_exists?(logs_table, "uuid", escaped_prefix) do
      events = prefix_table(events_table, prefix)
      logs = prefix_table(logs_table, prefix)

      # Reset rows whose email_log_uuid does not reference any real email log.
      # These were filled with random UUIDs by the V56 NULL-fill fallback and
      # need to be re-backfilled from the correct JOIN.
      execute("""
      UPDATE #{events} e
      SET email_log_uuid = NULL
      WHERE e.email_log_id IS NOT NULL
        AND e.email_log_uuid IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM #{logs} l WHERE l.uuid = e.email_log_uuid
        )
      """)

      # Re-run the proper JOIN-based backfill (idempotent: WHERE IS NULL).
      execute("""
      DO $$
      DECLARE
        batch_count INTEGER;
      BEGIN
        LOOP
          UPDATE #{events} t
          SET email_log_uuid = s.uuid
          FROM #{logs} s
          WHERE s.id = t.email_log_id
            AND t.email_log_uuid IS NULL
            AND t.email_log_id IS NOT NULL
            AND t.ctid IN (
              SELECT t2.ctid FROM #{events} t2
              WHERE t2.email_log_uuid IS NULL
                AND t2.email_log_id IS NOT NULL
              LIMIT 10000
            );

          GET DIAGNOSTICS batch_count = ROW_COUNT;
          EXIT WHEN batch_count = 0;
          PERFORM pg_sleep(0.01);
        END LOOP;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE WARNING 'PhoenixKit V70: email_log_uuid re-backfill skipped — %', SQLERRM;
      END $$;
      """)
    end
  end

  # ---------------------------------------------------------------------------
  # Step 3: Re-backfill matched_email_log_uuid in email_orphaned_events
  # ---------------------------------------------------------------------------

  defp rebackfill_matched_email_log_uuid(prefix, escaped_prefix) do
    orphaned_table = "phoenix_kit_email_orphaned_events"
    logs_table = "phoenix_kit_email_logs"

    if table_exists?(orphaned_table, escaped_prefix) and
         table_exists?(logs_table, escaped_prefix) and
         column_exists?(orphaned_table, "matched_email_log_uuid", escaped_prefix) and
         column_exists?(logs_table, "uuid", escaped_prefix) do
      orphaned = prefix_table(orphaned_table, prefix)
      logs = prefix_table(logs_table, prefix)

      # Reset orphaned rows whose matched_email_log_uuid references nothing real.
      execute("""
      UPDATE #{orphaned} e
      SET matched_email_log_uuid = NULL
      WHERE e.matched_email_log_id IS NOT NULL
        AND e.matched_email_log_uuid IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM #{logs} l WHERE l.uuid = e.matched_email_log_uuid
        )
      """)

      execute("""
      DO $$
      BEGIN
        UPDATE #{orphaned} e
        SET matched_email_log_uuid = l.uuid
        FROM #{logs} l
        WHERE e.matched_email_log_id = l.id
          AND e.matched_email_log_uuid IS NULL
          AND e.matched_email_log_id IS NOT NULL;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE WARNING 'PhoenixKit V70: matched_email_log_uuid re-backfill skipped — %', SQLERRM;
      END $$;
      """)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp table_exists?(table_str, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.tables
             WHERE table_name = '#{table_str}'
               AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp column_exists?(table_str, column_str, escaped_prefix) do
    case repo().query(
           """
           SELECT EXISTS (
             SELECT FROM information_schema.columns
             WHERE table_name = '#{table_str}'
               AND column_name = '#{column_str}'
               AND table_schema = '#{escaped_prefix}'
           )
           """,
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
