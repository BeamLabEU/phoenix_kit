defmodule PhoenixKit.Migrations.Postgres.V25 do
  @moduledoc """
  PhoenixKit V25 Migration: Aspect Ratio Control for Dimensions

  This migration adds support for aspect ratio preservation in dimension configuration.
  Allows users to choose between maintaining aspect ratio (width only) or fixed dimensions.

  ## Changes

  ### Storage Dimensions Table (phoenix_kit_storage_dimensions)
  - Adds `maintain_aspect_ratio` boolean column (default: true)
  - When true: Only width is used, height is calculated to preserve aspect ratio
  - When false: Both width and height are used as fixed dimensions (for thumbnails/crops)

  ## Features

  - **Aspect Ratio Mode**: Responsive sizing with width-only specification
  - **Fixed Dimension Mode**: Exact pixel dimensions for square crops/thumbnails
  - **Per-Dimension Control**: Each variant can independently choose its mode
  - **Default to Aspect Ratio**: All dimensions default to maintaining aspect ratio
  """
  use Ecto.Migration

  @doc """
  Run the V25 migration to add aspect ratio control.
  """
  def up(%{prefix: prefix} = _opts) do
    # Add maintain_aspect_ratio column to dimensions table
    alter table(:phoenix_kit_storage_dimensions, prefix: prefix) do
      add :maintain_aspect_ratio, :boolean, default: true, null: false
    end

    # Set version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '25'"
  end

  @doc """
  Rollback the V25 migration.
  """
  def down(%{prefix: prefix} = _opts) do
    # Remove maintain_aspect_ratio column from dimensions table
    alter table(:phoenix_kit_storage_dimensions, prefix: prefix) do
      remove :maintain_aspect_ratio
    end

    # Update version comment on phoenix_kit table to previous version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '24'"
  end

  # Helper functions

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
