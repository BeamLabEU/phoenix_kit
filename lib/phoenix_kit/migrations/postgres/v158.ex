defmodule PhoenixKit.Migrations.Postgres.V158 do
  @moduledoc """
  V158: broadcast attachments (accumulator).

  Per the one-open-migration rule this file is the accumulator for the
  restructuring work until it ships in a release; later sections append
  here rather than opening V159.

  ## Section: `phoenix_kit_newsletters_broadcasts.attachments`

  A JSONB array of Storage file uuids (`phoenix_kit_files.uuid`) to be
  attached to every email of the broadcast. Deliberately a bare uuid
  list, not an FK'd join table:

  - The soft-reference pattern matches this table's existing
    `crm_list_uuid`/`source_params` precedent — newsletters rows never
    hold FKs into other modules' tables, so a file deleted from Media
    later degrades to "skipped at send time" (the worker resolves each
    uuid via Storage and skips misses) rather than blocking the delete
    with a RESTRICT nobody can see the reason for.
  - Order matters to the sender (attachments appear in the email in list
    order), which a join table would need an extra column to preserve;
    a JSONB array carries it for free.

  The application-side writer (broadcast editor + `Broadcast` changeset,
  newsletters package) validates entries are uuids and caps the count;
  the column itself only guarantees "a JSON array" via the CHECK — the
  DB-level backstop that a stray writer can't store an object/scalar
  here and crash every reader.

  All operations idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts
      ADD COLUMN IF NOT EXISTS attachments JSONB NOT NULL DEFAULT '[]'
    """)

    execute(
      "ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts DROP CONSTRAINT IF EXISTS phoenix_kit_newsletters_broadcasts_attachments_is_array"
    )

    execute("""
    ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts
      ADD CONSTRAINT phoenix_kit_newsletters_broadcasts_attachments_is_array
      CHECK (jsonb_typeof(attachments) = 'array')
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '158'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute(
      "ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts DROP CONSTRAINT IF EXISTS phoenix_kit_newsletters_broadcasts_attachments_is_array"
    )

    execute(
      "ALTER TABLE #{p}phoenix_kit_newsletters_broadcasts DROP COLUMN IF EXISTS attachments"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '157'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
