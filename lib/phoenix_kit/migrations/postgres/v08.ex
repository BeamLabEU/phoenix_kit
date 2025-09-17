defmodule PhoenixKit.Migrations.Postgres.V08 do
  @moduledoc """
  PhoenixKit V08 Migration: Username Support

  This migration adds username functionality to the user system, allowing users
  to have unique usernames in addition to their email addresses.

  ## Changes

  ### Username System
  - Adds username field to phoenix_kit_users table
  - Creates unique constraint on username field
  - Migrates existing users to have default usernames based on email
  - Provides username validation and generation logic

  ### New Features
  - **Username Field**: Optional unique username for each user
  - **Email-based Generation**: Automatically generates usernames from email addresses
  - **Uniqueness Handling**: Handles duplicate usernames with incremental suffixes
  - **Backwards Compatibility**: Existing functionality remains unchanged

  ## PostgreSQL Support
  - Supports PostgreSQL prefix for schema isolation
  - Optimized indexes for username lookups
  - Safe migration of existing user data
  """
  use Ecto.Migration

  alias Ecto.Adapters.SQL
  alias PhoenixKit.RepoHelper

  @doc """
  Run the V08 migration to add username support.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add username field to users table using Ecto's alter (should work within transaction)
    alter table(:phoenix_kit_users, prefix: prefix) do
      add :username, :string, null: true
    end

    # Force the DDL to be executed before proceeding with data changes
    flush()

    # Migrate existing users to have usernames based on email
    migrate_existing_users_to_have_usernames(prefix)

    # Create unique index on username (for non-null values only) - after data is populated
    create_if_not_exists unique_index(:phoenix_kit_users, [:username],
                           prefix: prefix,
                           name: :phoenix_kit_users_username_uidx,
                           where: "username IS NOT NULL"
                         )

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '8'"
  end

  # Migrate existing users to have default usernames generated from their email addresses.
  defp migrate_existing_users_to_have_usernames(prefix) do
    # Get all users (since username column was just added, all will be NULL)
    users_query = """
    SELECT id, email 
    FROM #{prefix_table_name("phoenix_kit_users", prefix)} 
    ORDER BY id ASC
    """

    {:ok, result} = SQL.query(RepoHelper.repo(), users_query, [])
    users = Enum.map(result.rows, fn [id, email] -> {id, email} end)

    # Generate and assign usernames with a simple counter for duplicates
    {_final_used_set, _} =
      Enum.reduce(users, {MapSet.new(), 0}, fn {user_id, email}, {used_usernames, _count} ->
        base_username = generate_base_username_from_email(email)
        username = ensure_unique_username_simple(base_username, used_usernames)

        # Update the database
        update_query = """
        UPDATE #{prefix_table_name("phoenix_kit_users", prefix)} 
        SET username = $1 
        WHERE id = $2
        """

        SQL.query!(PhoenixKit.RepoHelper.repo(), update_query, [username, user_id])

        # Return updated used_usernames set for next iteration
        {MapSet.put(used_usernames, username), 0}
      end)
  end

  # Generate base username from an email address without uniqueness checking.
  defp generate_base_username_from_email(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.downcase()
    # Remove dots and make valid username format
    |> String.replace(".", "_")
    # Ensure it starts with a letter and contains only valid chars
    |> clean_username()
  end

  # Clean username to ensure it meets validation rules.
  defp clean_username(username) do
    # Remove any invalid characters and ensure it starts with a letter
    cleaned =
      username
      |> String.replace(~r/[^a-zA-Z0-9_]/, "")
      # Max length
      |> String.slice(0, 30)

    # Ensure it starts with a letter
    case String.match?(cleaned, ~r/^[a-zA-Z]/) do
      true -> cleaned
      # Leave room for "user_" prefix
      false -> "user_" <> String.slice(cleaned, 0, 25)
    end
    |> ensure_minimum_length()
  end

  # Ensure username meets minimum length requirement.
  defp ensure_minimum_length(username) when byte_size(username) >= 3, do: username
  defp ensure_minimum_length(username), do: username <> "_1"

  # Simple uniqueness check using in-memory set (for migration only).
  defp ensure_unique_username_simple(base_username, used_usernames, attempt \\ 0) do
    candidate =
      case attempt do
        0 -> base_username
        n -> "#{base_username}_#{n}"
      end

    if MapSet.member?(used_usernames, candidate) do
      ensure_unique_username_simple(base_username, used_usernames, attempt + 1)
    else
      candidate
    end
  end

  # Helper function to build table name with prefix
  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"

  def down(%{prefix: prefix} = _opts) do
    # Drop the unique index on username
    drop_if_exists index(:phoenix_kit_users, [:username],
                     prefix: prefix,
                     name: :phoenix_kit_users_username_uidx
                   )

    # Remove username field from users table
    alter table(:phoenix_kit_users, prefix: prefix) do
      remove :username
    end

    # Set version comment back to V07
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '7'"
  end
end
