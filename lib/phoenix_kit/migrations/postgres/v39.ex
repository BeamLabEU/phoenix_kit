defmodule PhoenixKit.Migrations.Postgres.V39 do
  @moduledoc """
  PhoenixKit V39 Migration: Admin Notes System

  Adds a notes system for administrators to record internal notes about users.
  These notes are only visible to admins and serve as admin-to-admin communication.

  ## Changes

  ### Admin Notes Table (phoenix_kit_admin_notes)
  - Internal notes that admins can write about users
  - Tracks which admin wrote each note
  - Full edit history with updated_at timestamps
  - Any admin can view/edit/delete any note

  ## Features

  - Simple text-based notes
  - Author tracking for accountability
  - Efficient indexes for user and author lookups
  - Timestamps for audit trail
  """
  use Ecto.Migration

  @doc """
  Run the V39 migration to add admin notes system.
  """
  def up(%{prefix: prefix} = _opts) do
    create_admin_notes_table(prefix)

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '39'")
  end

  @doc """
  Rollback the V39 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    drop_if_exists(table(:phoenix_kit_admin_notes, prefix: prefix))

    execute("COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '38'")
  end

  defp create_admin_notes_table(prefix) do
    create_if_not_exists table(:phoenix_kit_admin_notes, prefix: prefix) do
      # User being noted about
      add(
        :user_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      # Admin who wrote the note
      add(
        :author_id,
        references(:phoenix_kit_users, on_delete: :delete_all, prefix: prefix, type: :bigint),
        null: false
      )

      # Note content
      add(:content, :text, null: false)

      timestamps(type: :naive_datetime)
    end

    # Index for fetching notes about a user (most common query)
    create_if_not_exists(index(:phoenix_kit_admin_notes, [:user_id], prefix: prefix))

    # Index for fetching notes by an author
    create_if_not_exists(index(:phoenix_kit_admin_notes, [:author_id], prefix: prefix))

    # Index for ordering by creation time
    create_if_not_exists(index(:phoenix_kit_admin_notes, [:inserted_at], prefix: prefix))

    execute("""
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_admin_notes", prefix)} IS
    'Internal admin notes about users (admin-to-admin communication)'
    """)
  end

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
