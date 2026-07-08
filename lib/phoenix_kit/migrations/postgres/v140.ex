defmodule PhoenixKit.Migrations.Postgres.V140 do
  @moduledoc """
  V140: Widen role-permission keys for fine-grained sub-permissions.

  Sub-permissions are stored in `phoenix_kit_role_permissions.module_key` as
  composed dotted keys (`"calendar.view_others"`). Base and sub parts are
  each capped at 50 chars, so a composed key can reach 101 — the original
  V53 `VARCHAR(50)` is too narrow. Widen to `VARCHAR(120)`.

  All statements are idempotent, safe to re-run.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("""
    ALTER TABLE #{p}phoenix_kit_role_permissions
    ALTER COLUMN module_key TYPE VARCHAR(120)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '140'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Dotted sub-permission rows may exceed 50 chars; drop them before
    # narrowing so the type change cannot fail mid-rollback. Sub-permission
    # grants are additive and re-grantable, so removing them is safe.
    execute("""
    DELETE FROM #{p}phoenix_kit_role_permissions
    WHERE LENGTH(module_key) > 50
    """)

    execute("""
    ALTER TABLE #{p}phoenix_kit_role_permissions
    ALTER COLUMN module_key TYPE VARCHAR(50)
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '139'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
