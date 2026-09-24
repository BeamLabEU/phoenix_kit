defmodule PhoenixKit.Migrations.Postgres.V203 do
  @moduledoc """
  V203: a library's URL name.

  `slug` on `phoenix_kit_storage_libraries` — the name a library is reached
  by (`/admin/media/library/<slug>`), unique per owner, NULL for the default
  library, which is the bare `/admin/media`. Libraries created before the
  column existed are given one from their name.

  ## Why this is its own version

  It shipped inside V202 at first, added by an `ALTER … ADD COLUMN IF NOT
  EXISTS` so that "a database that ran an earlier build of this version gets
  the same column". That reasoning does not reach the databases it was
  written for: the chain records the version it has RUN, so an install
  already at 202 is never offered 202 again, whatever 202 has grown since.
  The amendment reached fresh installs only, and everyone else got a schema
  module selecting a column their table did not have — a 500 on every media
  page, with `mix phoenix_kit.status` reporting the chain up to date.

  Moving it to a version of its own is what makes it arrive. Fresh installs
  are unaffected: they run 202 then 203 and end up in the same place.

  Re-runnable.
  """

  use Ecto.Migration

  @nil_uuid "00000000-0000-0000-0000-000000000000"

  def up(opts) do
    opts |> Map.get(:prefix, "public") |> up_statements() |> Enum.each(&execute/1)
  end

  @doc """
  Rolls V203 back: drops the unique index and the column. Which URL a
  library answered to is lost.
  """
  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, for the migration test. Index names stay
  # bare on CREATE and are qualified only on DROP.
  def up_statements(prefix) do
    p = prefix_str(prefix)

    [
      "ALTER TABLE #{p}phoenix_kit_storage_libraries ADD COLUMN IF NOT EXISTS slug character varying(64)",
      # Slugs for libraries created before the column existed. Same shape as
      # `Library.slugify/1` for ASCII names: lower-cased, hyphenated, cut at
      # 58. Taken one at a time so a disambiguating `-2` cannot collide with
      # a name that already slugifies to that (`Foo` / `Foo!` / `Foo-2`), and
      # two long names that only differ past the cut still get different
      # slugs. One pass that ranked the full string and then truncated could
      # write the same slug twice and abort the update.
      """
      DO $$
      DECLARE
        rec record;
        base text;
        candidate text;
        n int;
        owner uuid;
      BEGIN
        FOR rec IN
          SELECT uuid, owner_uuid, name
          FROM #{p}phoenix_kit_storage_libraries
          WHERE slug IS NULL AND NOT is_default
          ORDER BY uuid
        LOOP
          base := COALESCE(
            NULLIF(
              trim(both '-' from left(
                trim(both '-' from lower(regexp_replace(rec.name, '[^a-zA-Z0-9]+', '-', 'g'))),
                58
              )),
              ''
            ),
            'library'
          );
          owner := COALESCE(rec.owner_uuid, '#{@nil_uuid}'::uuid);
          n := 1;

          LOOP
            IF n = 1 THEN
              candidate := base;
            ELSE
              candidate := base || '-' || n::text;
            END IF;

            EXIT WHEN NOT EXISTS (
              SELECT 1
              FROM #{p}phoenix_kit_storage_libraries l
              WHERE l.slug = candidate
                AND COALESCE(l.owner_uuid, '#{@nil_uuid}'::uuid) = owner
            );

            n := n + 1;

            IF n > 500 THEN
              RAISE EXCEPTION 'could not assign a unique slug to library %', rec.uuid;
            END IF;
          END LOOP;

          UPDATE #{p}phoenix_kit_storage_libraries
          SET slug = candidate
          WHERE uuid = rec.uuid;
        END LOOP;
      END
      $$
      """,
      """
      CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_storage_libraries_owner_slug_index
      ON #{p}phoenix_kit_storage_libraries
        (COALESCE(owner_uuid, '#{@nil_uuid}'::uuid), slug)
      WHERE slug IS NOT NULL
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '203'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    p = prefix_str(prefix)

    [
      "DROP INDEX IF EXISTS #{p}phoenix_kit_storage_libraries_owner_slug_index",
      "ALTER TABLE #{p}phoenix_kit_storage_libraries DROP COLUMN IF EXISTS slug",
      "COMMENT ON TABLE #{p}phoenix_kit IS '202'"
    ]
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
