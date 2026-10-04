defmodule PhoenixKit.Migrations.Postgres.V208 do
  @moduledoc """
  V208: the bucket log (`dev_docs/plans/2026-10-03-bucket-page.md`, section 6).

  `phoenix_kit_bucket_log` records what went wrong with a **site** storage bucket
  (a write, read or delete that failed) and what its connection probes said,
  with the time each took, so the bucket's own page can show a failing bucket
  and its latency over time. Until now such failures reached only `Logger`.

    * `kind` — `probe`, `write`, `read` or `delete`;
    * `ok` — whether it succeeded (a probe can; the rest are only recorded when
      they fail, so the table stays small on a healthy bucket);
    * `latency_ms` — how long a probe took;
    * `message` — what the provider said, truncated by the writer, never a key;
    * `count`, `inserted_at`, `last_at` — **the same failure seen again within a
      minute is one row** whose `count` grows and `last_at` moves, so a bucket
      that is down does not write a row per request.

  There is **no foreign key** on `bucket_uuid`, the choice V206 and V207 made: a
  row must not block deleting a bucket (`Storage.delete_bucket/2` removes the
  bucket's rows itself), and a log write must never fail because a bucket was
  deleted meanwhile. A user's own bucket (V206) is never logged.

  The log is operational, not an audit: it is pruned daily to
  `bucket_log_retention_days` (default 30). Nothing is copied, moved or
  rewritten; the table starts empty.

  ## Locks

  `CREATE TABLE` and `CREATE INDEX` on a table nothing references. Re-runnable.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers
  alias PhoenixKit.Migrations.Postgres.V203

  @kinds ~w(probe write read delete)

  @doc "The kinds of entry the log holds."
  def kinds, do: @kinds

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V208 back: the log is only history, so the table simply goes."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)
    kinds = Enum.map_join(@kinds, ", ", &"'#{&1}'")

    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_bucket_log (
        uuid uuid DEFAULT #{Helpers.uuid_v7_call(prefix)} NOT NULL,
        bucket_uuid uuid NOT NULL,
        kind character varying(20) NOT NULL,
        ok boolean NOT NULL,
        latency_ms integer,
        message text,
        count integer DEFAULT 1 NOT NULL,
        inserted_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        last_at timestamp(0) without time zone DEFAULT now() NOT NULL,
        CONSTRAINT phoenix_kit_bucket_log_pkey PRIMARY KEY (uuid),
        CONSTRAINT phoenix_kit_bucket_log_kind_check CHECK (kind IN (#{kinds})),
        CONSTRAINT phoenix_kit_bucket_log_count_check CHECK (count >= 1)
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_bucket_log_bucket_index
      ON #{p}phoenix_kit_bucket_log (bucket_uuid, last_at DESC)
      """,
      """
      CREATE INDEX IF NOT EXISTS phoenix_kit_bucket_log_last_at_index
      ON #{p}phoenix_kit_bucket_log (last_at)
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '208'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "DROP TABLE IF EXISTS #{p}phoenix_kit_bucket_log",
      "COMMENT ON TABLE #{p}phoenix_kit IS '207'"
    ]
  end
end
