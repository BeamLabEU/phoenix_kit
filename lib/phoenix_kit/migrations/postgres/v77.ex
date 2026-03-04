defmodule PhoenixKit.Migrations.Postgres.V77 do
  @moduledoc """
  V77: Rename Tickets module settings keys and permission module_key to customer_service.

  The `tickets` module has been renamed to `customer_service`. This migration
  renames all associated settings keys and role permission module_key values
  to match the new module identity.

  ## Changes

  - Rename 6 settings keys from `tickets_*` → `customer_service_*`
  - Rename auto-granted permission key from `auto_granted_perm:tickets` → `auto_granted_perm:customer_service`
  - Rename role permission module_key from `tickets` → `customer_service`

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    table = "#{prefix_str(prefix)}phoenix_kit_settings"
    perms_table = "#{prefix_str(prefix)}phoenix_kit_role_permissions"

    rename_setting(table, "tickets_enabled", "customer_service_enabled")
    rename_setting(table, "tickets_per_page", "customer_service_per_page")
    rename_setting(table, "tickets_comments_enabled", "customer_service_comments_enabled")

    rename_setting(
      table,
      "tickets_internal_notes_enabled",
      "customer_service_internal_notes_enabled"
    )

    rename_setting(table, "tickets_attachments_enabled", "customer_service_attachments_enabled")
    rename_setting(table, "tickets_allow_reopen", "customer_service_allow_reopen")
    rename_setting(table, "auto_granted_perm:tickets", "auto_granted_perm:customer_service")

    rename_role_permission(perms_table, "tickets", "customer_service")

    execute("COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '77'")
  end

  # Renames a settings key. If the target already exists, deletes the source to avoid
  # unique constraint violations (handles the case where new keys were pre-seeded).
  defp rename_setting(table, from_key, to_key) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{table} WHERE key = '#{to_key}') THEN
        DELETE FROM #{table} WHERE key = '#{from_key}';
      ELSE
        UPDATE #{table} SET key = '#{to_key}' WHERE key = '#{from_key}';
      END IF;
    END $$;
    """)
  end

  # Renames role permission module_key. If target already exists for the same role,
  # deletes the source row to avoid unique constraint violations.
  defp rename_role_permission(table, from_key, to_key) do
    execute("""
    DO $$
    DECLARE
      r RECORD;
    BEGIN
      FOR r IN SELECT uuid, role_uuid FROM #{table} WHERE module_key = '#{from_key}' LOOP
        IF EXISTS (
          SELECT 1 FROM #{table}
          WHERE module_key = '#{to_key}' AND role_uuid = r.role_uuid
        ) THEN
          DELETE FROM #{table} WHERE uuid = r.uuid;
        ELSE
          UPDATE #{table} SET module_key = '#{to_key}' WHERE uuid = r.uuid;
        END IF;
      END LOOP;
    END $$;
    """)
  end

  def down(%{prefix: prefix} = _opts) do
    table = "#{prefix_str(prefix)}phoenix_kit_settings"
    perms_table = "#{prefix_str(prefix)}phoenix_kit_role_permissions"

    rename_role_permission(perms_table, "customer_service", "tickets")
    rename_setting(table, "auto_granted_perm:customer_service", "auto_granted_perm:tickets")
    rename_setting(table, "customer_service_allow_reopen", "tickets_allow_reopen")
    rename_setting(table, "customer_service_attachments_enabled", "tickets_attachments_enabled")

    rename_setting(
      table,
      "customer_service_internal_notes_enabled",
      "tickets_internal_notes_enabled"
    )

    rename_setting(table, "customer_service_comments_enabled", "tickets_comments_enabled")
    rename_setting(table, "customer_service_per_page", "tickets_per_page")
    rename_setting(table, "customer_service_enabled", "tickets_enabled")

    execute("COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '76'")
  end

  defp prefix_str(nil), do: ""
  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
