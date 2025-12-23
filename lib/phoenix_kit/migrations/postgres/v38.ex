defmodule PhoenixKit.Migrations.Postgres.V38 do
  @moduledoc """
  PhoenixKit V38 Migration: AI Prompts System

  This migration adds reusable prompt templates with variable substitution to the AI module.

  ## Changes

  ### Prompts Table (phoenix_kit_ai_prompts)
  - Reusable text templates for AI interactions
  - Variable substitution with {{VariableName}} syntax
  - Auto-extracted variables stored for validation
  - Usage tracking (count and last used timestamp)
  - Sorting and organization support

  ## Key Features

  - **Variable Substitution**: Use {{VarName}} placeholders in prompts
  - **Auto-extraction**: Variables are automatically parsed from content
  - **Usage Tracking**: Track how often prompts are used
  - **Flexible Templates**: Can be used as system prompts, user prompts, or any text
  """
  use Ecto.Migration

  @doc """
  Run the V38 migration to add AI Prompts.
  """
  def up(%{prefix: prefix} = _opts) do
    # ===========================================
    # 1. PROMPTS TABLE
    # ===========================================
    create_if_not_exists table(:phoenix_kit_ai_prompts, prefix: prefix) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :content, :text, null: false

      # Auto-extracted variables from content
      add :variables, {:array, :string}, null: false, default: []

      # Status and organization
      add :enabled, :boolean, null: false, default: true
      add :sort_order, :integer, null: false, default: 0

      # Usage tracking
      add :usage_count, :integer, null: false, default: 0
      add :last_used_at, :utc_datetime_usec

      # Flexible metadata storage
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Unique indexes for name and slug
    create_if_not_exists unique_index(:phoenix_kit_ai_prompts, [:name],
                           name: :phoenix_kit_ai_prompts_name_uidx,
                           prefix: prefix
                         )

    create_if_not_exists unique_index(:phoenix_kit_ai_prompts, [:slug],
                           name: :phoenix_kit_ai_prompts_slug_uidx,
                           prefix: prefix
                         )

    # Status and sorting indexes
    create_if_not_exists index(:phoenix_kit_ai_prompts, [:enabled],
                           name: :phoenix_kit_ai_prompts_enabled_idx,
                           prefix: prefix
                         )

    create_if_not_exists index(:phoenix_kit_ai_prompts, [:sort_order],
                           name: :phoenix_kit_ai_prompts_sort_order_idx,
                           prefix: prefix
                         )

    # Usage tracking index for sorting by usage
    create_if_not_exists index(:phoenix_kit_ai_prompts, [:usage_count],
                           name: :phoenix_kit_ai_prompts_usage_count_idx,
                           prefix: prefix
                         )

    # ===========================================
    # 2. TABLE COMMENTS
    # ===========================================
    execute """
    COMMENT ON TABLE #{prefix_table_name("phoenix_kit_ai_prompts", prefix)} IS
    'Reusable AI prompt templates with variable substitution support'
    """

    execute """
    COMMENT ON COLUMN #{prefix_table_name("phoenix_kit_ai_prompts", prefix)}.variables IS
    'Auto-extracted variable names from content (e.g., ["Language", "Text"] from {{Language}} and {{Text}})'
    """

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '38'"
  end

  @doc """
  Rollback the V38 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Drop indexes
    drop_if_exists index(:phoenix_kit_ai_prompts, [:usage_count],
                     name: :phoenix_kit_ai_prompts_usage_count_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_prompts, [:sort_order],
                     name: :phoenix_kit_ai_prompts_sort_order_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_prompts, [:enabled],
                     name: :phoenix_kit_ai_prompts_enabled_idx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_prompts, [:slug],
                     name: :phoenix_kit_ai_prompts_slug_uidx,
                     prefix: prefix
                   )

    drop_if_exists index(:phoenix_kit_ai_prompts, [:name],
                     name: :phoenix_kit_ai_prompts_name_uidx,
                     prefix: prefix
                   )

    # Drop table
    drop_if_exists table(:phoenix_kit_ai_prompts, prefix: prefix)

    # Update version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '37'"
  end

  # Helper functions

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, "public"), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
