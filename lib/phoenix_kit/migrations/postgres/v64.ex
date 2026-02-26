defmodule PhoenixKit.Migrations.Postgres.V64 do
  @moduledoc """
  V64: Fix user token check constraint for UUID-only inserts.

  The V16 migration added a check constraint `user_id_required_for_non_registration_tokens`
  that requires `user_id IS NOT NULL` for non-registration tokens. After the UUID cleanup,
  the schema only sets `user_uuid` (not `user_id`), so session token inserts fail.

  This migration replaces the constraint to check `user_uuid` instead of `user_id`.
  """

  use Ecto.Migration

  @old_constraint "user_id_required_for_non_registration_tokens"
  @new_constraint "user_uuid_required_for_non_registration_tokens"

  def up(%{prefix: prefix} = _opts) do
    table_name = prefix_table("phoenix_kit_users_tokens", prefix)

    # Drop the old user_id-based constraint
    execute("""
    ALTER TABLE #{table_name}
    DROP CONSTRAINT IF EXISTS #{@old_constraint}
    """)

    # Add new constraint checking user_uuid instead
    execute("""
    ALTER TABLE #{table_name}
    ADD CONSTRAINT #{@new_constraint}
    CHECK (
      CASE
        WHEN context = 'magic_link_registration' THEN true
        ELSE user_uuid IS NOT NULL
      END
    )
    """)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '64'")
  end

  def down(%{prefix: prefix} = _opts) do
    table_name = prefix_table("phoenix_kit_users_tokens", prefix)

    # Drop the new uuid-based constraint
    execute("""
    ALTER TABLE #{table_name}
    DROP CONSTRAINT IF EXISTS #{@new_constraint}
    """)

    # Restore the old user_id-based constraint
    execute("""
    ALTER TABLE #{table_name}
    ADD CONSTRAINT #{@old_constraint}
    CHECK (
      CASE
        WHEN context = 'magic_link_registration' THEN true
        ELSE user_id IS NOT NULL
      END
    )
    """)

    execute("COMMENT ON TABLE #{prefix_table("phoenix_kit", prefix)} IS '63'")
  end

  defp prefix_table(table_name, nil), do: table_name
  defp prefix_table(table_name, "public"), do: "public.#{table_name}"
  defp prefix_table(table_name, prefix), do: "#{prefix}.#{table_name}"
end
