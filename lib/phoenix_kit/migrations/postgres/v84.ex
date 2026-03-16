defmodule PhoenixKit.Migrations.Postgres.V84 do
  @moduledoc """
  V84: Rename mailing tables to newsletters.

  The mailing module was renamed to newsletters. V79 was updated to create
  `phoenix_kit_newsletters_*` tables, but databases that already ran the old V79
  (which created `phoenix_kit_mailing_*` tables) were not migrated.

  This migration idempotently renames any remaining `mailing_*` tables to
  `newsletters_*`. Safe to run multiple times — uses IF EXISTS guards.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    rename_if_needed(schema, p, "phoenix_kit_mailing_lists", "phoenix_kit_newsletters_lists")

    rename_if_needed(
      schema,
      p,
      "phoenix_kit_mailing_list_members",
      "phoenix_kit_newsletters_list_members"
    )

    rename_if_needed(
      schema,
      p,
      "phoenix_kit_mailing_broadcasts",
      "phoenix_kit_newsletters_broadcasts"
    )

    rename_if_needed(
      schema,
      p,
      "phoenix_kit_mailing_deliveries",
      "phoenix_kit_newsletters_deliveries"
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '84'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    rename_if_needed(
      schema,
      p,
      "phoenix_kit_newsletters_deliveries",
      "phoenix_kit_mailing_deliveries"
    )

    rename_if_needed(
      schema,
      p,
      "phoenix_kit_newsletters_broadcasts",
      "phoenix_kit_mailing_broadcasts"
    )

    rename_if_needed(
      schema,
      p,
      "phoenix_kit_newsletters_list_members",
      "phoenix_kit_mailing_list_members"
    )

    rename_if_needed(schema, p, "phoenix_kit_newsletters_lists", "phoenix_kit_mailing_lists")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '83'")
  end

  defp rename_if_needed(schema, p, from_table, to_table) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = '#{from_table}'
      ) AND NOT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = '#{to_table}'
      ) THEN
        ALTER TABLE #{p}#{from_table} RENAME TO #{to_table};
      END IF;
    END $$;
    """)
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
