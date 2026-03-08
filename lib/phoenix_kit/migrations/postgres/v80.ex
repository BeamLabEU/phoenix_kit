defmodule PhoenixKit.Migrations.Postgres.V80 do
  @moduledoc """
  V80: Emails Module i18n — JSON language fields

  Converts 5 text fields in phoenix_kit_email_templates to JSONB for multilingual support.
  Existing data is preserved by wrapping current values under the "en" key.

  Adds `locale` field to phoenix_kit_email_logs for tracking which language was sent.
  """

  use Ecto.Migration

  def up(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    # Convert template content fields to JSONB
    # Existing string values are preserved as {"en": "original_value"}
    execute("""
    ALTER TABLE #{p}phoenix_kit_email_templates
      ALTER COLUMN subject TYPE jsonb
        USING jsonb_build_object('en', subject),
      ALTER COLUMN html_body TYPE jsonb
        USING jsonb_build_object('en', html_body),
      ALTER COLUMN text_body TYPE jsonb
        USING jsonb_build_object('en', text_body),
      ALTER COLUMN display_name TYPE jsonb
        USING jsonb_build_object('en', display_name),
      ALTER COLUMN description TYPE jsonb
        USING CASE
          WHEN description IS NULL THEN NULL
          ELSE jsonb_build_object('en', description)
        END
    """)

    # Add locale tracking to email logs
    execute("""
    ALTER TABLE #{p}phoenix_kit_email_logs
      ADD COLUMN IF NOT EXISTS locale VARCHAR(10) NOT NULL DEFAULT 'en'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_email_logs_locale
      ON #{p}phoenix_kit_email_logs (locale)
    """)
  end

  def down(%{prefix: prefix} = _opts) do
    p = prefix_str(prefix)

    # Revert JSONB back to text — extract the "en" value
    execute("""
    ALTER TABLE #{p}phoenix_kit_email_templates
      ALTER COLUMN subject TYPE varchar(300)
        USING (subject->>'en'),
      ALTER COLUMN html_body TYPE text
        USING (html_body->>'en'),
      ALTER COLUMN text_body TYPE text
        USING (text_body->>'en'),
      ALTER COLUMN display_name TYPE varchar(200)
        USING (display_name->>'en'),
      ALTER COLUMN description TYPE text
        USING (description->>'en')
    """)

    execute("DROP INDEX IF EXISTS #{p}idx_email_logs_locale")

    execute("""
    ALTER TABLE #{p}phoenix_kit_email_logs
      DROP COLUMN IF EXISTS locale
    """)
  end

  defp prefix_str(nil), do: ""
  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
