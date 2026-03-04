defmodule PhoenixKit.Migrations.Postgres.V76 do
  @moduledoc """
  V76: Rename Tickets module settings keys and permission module_key to customer_service.

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

    execute("UPDATE #{table} SET key = 'customer_service_enabled' WHERE key = 'tickets_enabled'")

    execute(
      "UPDATE #{table} SET key = 'customer_service_per_page' WHERE key = 'tickets_per_page'"
    )

    execute(
      "UPDATE #{table} SET key = 'customer_service_comments_enabled' WHERE key = 'tickets_comments_enabled'"
    )

    execute(
      "UPDATE #{table} SET key = 'customer_service_internal_notes_enabled' WHERE key = 'tickets_internal_notes_enabled'"
    )

    execute(
      "UPDATE #{table} SET key = 'customer_service_attachments_enabled' WHERE key = 'tickets_attachments_enabled'"
    )

    execute(
      "UPDATE #{table} SET key = 'customer_service_allow_reopen' WHERE key = 'tickets_allow_reopen'"
    )

    execute(
      "UPDATE #{table} SET key = 'auto_granted_perm:customer_service' WHERE key = 'auto_granted_perm:tickets'"
    )

    execute(
      "UPDATE #{perms_table} SET module_key = 'customer_service' WHERE module_key = 'tickets'"
    )

    execute("COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '76'")
  end

  def down(%{prefix: prefix} = _opts) do
    table = "#{prefix_str(prefix)}phoenix_kit_settings"
    perms_table = "#{prefix_str(prefix)}phoenix_kit_role_permissions"

    execute(
      "UPDATE #{perms_table} SET module_key = 'tickets' WHERE module_key = 'customer_service'"
    )

    execute(
      "UPDATE #{table} SET key = 'auto_granted_perm:tickets' WHERE key = 'auto_granted_perm:customer_service'"
    )

    execute(
      "UPDATE #{table} SET key = 'tickets_allow_reopen' WHERE key = 'customer_service_allow_reopen'"
    )

    execute(
      "UPDATE #{table} SET key = 'tickets_attachments_enabled' WHERE key = 'customer_service_attachments_enabled'"
    )

    execute(
      "UPDATE #{table} SET key = 'tickets_internal_notes_enabled' WHERE key = 'customer_service_internal_notes_enabled'"
    )

    execute(
      "UPDATE #{table} SET key = 'tickets_comments_enabled' WHERE key = 'customer_service_comments_enabled'"
    )

    execute(
      "UPDATE #{table} SET key = 'tickets_per_page' WHERE key = 'customer_service_per_page'"
    )

    execute("UPDATE #{table} SET key = 'tickets_enabled' WHERE key = 'customer_service_enabled'")

    execute("COMMENT ON TABLE #{prefix_str(prefix)}phoenix_kit IS '75'")
  end

  defp prefix_str(nil), do: ""
  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
