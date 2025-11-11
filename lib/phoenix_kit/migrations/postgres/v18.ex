defmodule PhoenixKit.Migrations.Postgres.V18 do
  @moduledoc """
  PhoenixKit V18 Migration: User Custom Fields

  Adds JSONB `custom_fields` column to phoenix_kit_users table for storing
  arbitrary custom data per user (phone numbers, addresses, preferences, metadata, etc.)

  ## Changes

  ### Users Table (phoenix_kit_users)
  - Adds `custom_fields` JSONB column (nullable, default: %{})
  - Stores flexible key-value data without schema changes
  - Leverages PostgreSQL's native JSONB type for performance

  ## Features

  - **Flexible Schema**: Add any custom user data without migrations
  - **PostgreSQL JSONB**: Native JSON storage with indexing support
  - **Default Empty Map**: New users start with `%{}`
  - **Queryable**: Use PostgreSQL JSONB operators for filtering

  ## Usage Examples

  ```elixir
  # Store custom fields
  Auth.register_user(%{
    email: "user@example.com",
    custom_fields: %{
      "phone" => "555-1234",
      "department" => "Engineering"
    }
  })

  # Update fields
  Auth.update_user_custom_fields(user, %{"linkedin" => "https://..."})

  # Access directly
  user.custom_fields["phone"]
  ```
  """
  use Ecto.Migration

  @doc """
  Run the V18 migration to add custom_fields column to users table.
  """
  def up(%{prefix: prefix} = _opts) do
    alter table(:phoenix_kit_users, prefix: prefix) do
      add :custom_fields, :map, null: true, default: %{}
    end

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_users", prefix)}.custom_fields IS
    'JSONB storage for custom user fields (phone, address, preferences, metadata, etc.)'
    """

    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '18'"
  end

  @doc """
  Rollback the V18 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    alter table(:phoenix_kit_users, prefix: prefix) do
      remove :custom_fields
    end

    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '17'"
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
