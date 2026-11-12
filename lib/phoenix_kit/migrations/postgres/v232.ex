defmodule PhoenixKit.Migrations.Postgres.V232 do
  @moduledoc """
  V232: stacks of files.

  A stack is two or more photos of one library that a person wants seen as one thing:
  the pages of a document, a burst. `PhoenixKit.Modules.Storage.Stacks` keeps them.

  **`phoenix_kit_file_stacks`** (new): what a stack says about itself.

    * `library_uuid`: the library its files are in (cascades with the library).
    * `title` (`varchar(200)`) and `description` (`text`), both optional.
    * `created_by_uuid`: who made it (`SET NULL` when the account goes).
    * `inserted_at`, `updated_at`.

  It has no date and no cover: the date is its files' own capture dates, and the cover
  is the first of its files a reader may see, worked out when it is listed.

  **`phoenix_kit_files`**, two nullable columns:

    * `stack_uuid`: the stack the file is in. `ON DELETE SET NULL`: deleting a stack
      leaves its files as they were, unstacked.
    * `stack_position` (`integer`): its place in the stack, lowest first.

  And `phoenix_kit_files_stack_index` on `(stack_uuid, stack_position)` for the files that
  are in one.

  ## Locks

  A new table; two `ADD COLUMN`s with no default (catalog-only, bounded by
  `lock_timeout`; the foreign key is added `NOT VALID` and then validated, over a column
  that is all `NULL`); a partial
  index over no rows yet. No backfill. Re-runnable.

  ## Down

  Drops the columns and the table: every stack is gone, its files stay as single files.
  """
  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    Helpers.validate_prefix!(prefix)
    Helpers.ensure_uuid_v7_function(prefix)
    Enum.each(up_statements(prefix), &execute/1)
  end

  def down(opts) do
    opts |> Map.get(:prefix, "public") |> down_statements() |> Enum.each(&execute/1)
  end

  @doc false
  def up_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."
    id = Helpers.uuid_v7_call(prefix)

    [
      "SET lock_timeout = '5000ms'",
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_file_stacks (
        uuid uuid PRIMARY KEY DEFAULT #{id},
        library_uuid uuid NOT NULL REFERENCES #{p}phoenix_kit_storage_libraries(uuid) ON DELETE CASCADE,
        title character varying(200),
        description text,
        created_by_uuid uuid REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE SET NULL,
        inserted_at timestamp(0) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(0) without time zone NOT NULL DEFAULT now()
      )
      """,
      "CREATE INDEX IF NOT EXISTS phoenix_kit_file_stacks_library_uuid_index ON #{p}phoenix_kit_file_stacks (library_uuid)",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS stack_uuid uuid",
      "ALTER TABLE #{p}phoenix_kit_files ADD COLUMN IF NOT EXISTS stack_position integer",
      """
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class t ON t.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE c.conname = 'phoenix_kit_files_stack_uuid_fkey'
            AND t.relname = 'phoenix_kit_files'
            AND n.nspname = '#{prefix}'
        ) THEN
          ALTER TABLE #{p}phoenix_kit_files
            ADD CONSTRAINT phoenix_kit_files_stack_uuid_fkey
            FOREIGN KEY (stack_uuid) REFERENCES #{p}phoenix_kit_file_stacks(uuid) ON DELETE SET NULL
            NOT VALID;
        END IF;
      END
      $$
      """,
      "ALTER TABLE #{p}phoenix_kit_files VALIDATE CONSTRAINT phoenix_kit_files_stack_uuid_fkey",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_files_stack_index ON #{p}phoenix_kit_files (stack_uuid, stack_position) WHERE stack_uuid IS NOT NULL",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '232'"
    ]
  end

  @doc false
  def down_statements(prefix) do
    Helpers.validate_prefix!(prefix)
    p = prefix <> "."

    [
      "SET lock_timeout = '5000ms'",
      "DROP INDEX IF EXISTS #{p}phoenix_kit_files_stack_index",
      "ALTER TABLE #{p}phoenix_kit_files DROP CONSTRAINT IF EXISTS phoenix_kit_files_stack_uuid_fkey",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS stack_position",
      "ALTER TABLE #{p}phoenix_kit_files DROP COLUMN IF EXISTS stack_uuid",
      "DROP TABLE IF EXISTS #{p}phoenix_kit_file_stacks",
      "RESET lock_timeout",
      "COMMENT ON TABLE #{p}phoenix_kit IS '231'"
    ]
  end
end
