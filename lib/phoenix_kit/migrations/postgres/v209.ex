defmodule PhoenixKit.Migrations.Postgres.V209 do
  @moduledoc """
  V209: a storage profile's copies are counted per kind of bucket, local and
  cloud.

  A profile used to say "N copies of each file" and let placement pick any N
  buckets. It now says how many copies go to **local** buckets and how many to
  **cloud** buckets, so a profile can keep two copies on the server's own disks
  and one in the cloud, which survives the server:

    * `copies_local` (0..5) — copies on `local` buckets;
    * `copies_cloud` (0..5) — copies on cloud buckets (S3, B2, R2, Tigris).

  `copies_originals` stays and **is now the total**: the CHECK below keeps it
  equal to `copies_local + copies_cloud`, so everything that reads the old
  column (`min_copies_on_write` is bounded by it, an older core on the same
  database) still sees how many copies a file has. `copies_variants` is not
  used any more; the application keeps it equal to the total.

  ## Backfill

  Existing profiles are split the way their buckets are, local first: the cloud
  share is as many of the profile's copies as the local buckets cannot take, up
  to the cloud buckets it has (active, enabled); the rest is local. A profile
  with no bucket yet keeps all its copies local. The total never changes, and
  `revision` is not touched, so no file is placed again by this migration.

  The backfill runs only when the columns are added, so a re-run never
  overwrites a split an admin chose.

  ## Locks

  `ALTER TABLE` on the (tiny) profiles table, one `UPDATE` of its rows.
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.V203

  @check "phoenix_kit_storage_profiles_local_cloud_check"

  @doc false
  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc "Rolls V209 back: the columns go, the total (`copies_originals`) stays."
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      # The columns and the backfill together: only a run that adds the columns
      # splits the counts, so a re-run leaves an admin's choice alone.
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = '#{prefix}'
            AND table_name = 'phoenix_kit_storage_profiles'
            AND column_name = 'copies_local'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_storage_profiles
            ADD COLUMN copies_local integer DEFAULT 1 NOT NULL,
            ADD COLUMN copies_cloud integer DEFAULT 0 NOT NULL;

          UPDATE #{p}phoenix_kit_storage_profiles pr
          SET copies_cloud = split.cloud,
              copies_local = pr.copies_originals - split.cloud
          FROM (
            SELECT p2.uuid,
                   LEAST(
                     COUNT(b.uuid) FILTER (WHERE b.provider <> 'local'),
                     GREATEST(
                       p2.copies_originals - COUNT(b.uuid) FILTER (WHERE b.provider = 'local'),
                       0
                     )
                   ) AS cloud
            FROM #{p}phoenix_kit_storage_profiles p2
            LEFT JOIN #{p}phoenix_kit_storage_profile_buckets pb
              ON pb.profile_uuid = p2.uuid AND pb.status = 'active'
            LEFT JOIN #{p}phoenix_kit_buckets b
              ON b.uuid = pb.bucket_uuid AND b.enabled
            GROUP BY p2.uuid, p2.copies_originals
          ) split
          WHERE split.uuid = pr.uuid;
        END IF;
      END
      $$
      """,
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = '#{@check}'
            AND t.relname = 'phoenix_kit_storage_profiles'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_storage_profiles ADD CONSTRAINT #{@check}
            CHECK (copies_local BETWEEN 0 AND 5 AND copies_cloud BETWEEN 0 AND 5
                   AND copies_local + copies_cloud = copies_originals);
        END IF;
      END
      $$
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '209'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = V203.prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_storage_profiles DROP CONSTRAINT IF EXISTS #{@check}",
      "ALTER TABLE #{p}phoenix_kit_storage_profiles DROP COLUMN IF EXISTS copies_cloud",
      "ALTER TABLE #{p}phoenix_kit_storage_profiles DROP COLUMN IF EXISTS copies_local",
      "COMMENT ON TABLE #{p}phoenix_kit IS '208'"
    ]
  end
end
