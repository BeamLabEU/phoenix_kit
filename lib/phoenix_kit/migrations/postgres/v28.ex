defmodule PhoenixKit.Migrations.Postgres.V28 do
  @moduledoc """
  Migration V28: Add preferred_locale field to users table for dialect preferences.

  This migration adds support for user-specific language dialect preferences,
  allowing authenticated users to choose their preferred variant (e.g., en-GB vs en-US)
  while URLs continue to show simplified base language codes (/en/ instead of /en-US/).

  ## Changes
  - Adds `preferred_locale` column to `phoenix_kit_users` table (nullable string, size 10)
  - Creates index on `preferred_locale` for potential locale-based queries
  - Supports full dialect codes (en-US, es-MX, zh-Hans-CN, etc.)

  ## Requirements
  - PostgreSQL database
  - PhoenixKit V27 or higher

  ## Purpose
  Enable simplified URL structure with dialect preferences:
  - URLs show base codes: `/en/`, `/es/`, `/fr/`
  - Users can save preferred dialects: "en-GB", "es-MX", "pt-BR"
  - Guest users get default dialect mapping (en → en-US)
  - Translation system uses full dialect codes internally

  ## Usage
  Once migrated, users can update their locale preference:

      PhoenixKit.Users.Auth.update_user_locale(user, "en-GB")

  When visiting `/en/dashboard`, the system will:
  1. Detect base code "en" from URL
  2. Resolve to user's preferred_locale ("en-GB")
  3. Use "en-GB" for translations while URL stays `/en/`

  ## Validation
  - Format validation: matches ~r/^[a-z]{2}(-[A-Z]{2})?$/
  - Existence validation: must be in predefined language list
  - NULL allowed: defaults to system dialect mapping

  ## Size Rationale
  - Size 10 supports extended codes like "zh-Hans-CN" (10 chars)
  - Covers all standard language-REGION codes (5 chars: "en-US")
  - Allows future BCP 47 extensions if needed

  ## Notes
  - Idempotent: Safe to run multiple times
  - No default value: NULL indicates "use system default"
  - Index improves potential analytics queries
  - Backward compatible: existing users have NULL (use defaults)
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    alter table(:phoenix_kit_users, prefix: prefix) do
      add :preferred_locale, :string, size: 10
    end

    # Create index for potential locale-based queries
    create index(:phoenix_kit_users, [:preferred_locale], prefix: prefix)

    # Update version comment on phoenix_kit table for version tracking
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '28'"
  end

  def down(%{prefix: prefix} = _opts) do
    # Remove index
    drop index(:phoenix_kit_users, [:preferred_locale], prefix: prefix)

    # Remove column
    alter table(:phoenix_kit_users, prefix: prefix) do
      remove :preferred_locale
    end

    # Update version comment on phoenix_kit table to previous version
    execute "COMMENT ON TABLE #{prefix_table_name("phoenix_kit", prefix)} IS '27'"
  end

  # Helper functions

  defp prefix_table_name(table_name, nil), do: table_name
  defp prefix_table_name(table_name, prefix), do: "#{prefix}.#{table_name}"
end
