defmodule PhoenixKit.Migrations.Postgres.V85 do
  @moduledoc """
  V85: Add system_prompt field to AI prompts table.

  Adds an optional system_prompt column to `phoenix_kit_ai_prompts` for
  storing system-level instructions separately from the user prompt content.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = '#{schema}' AND table_name = 'phoenix_kit_ai_prompts'
      ) AND NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_ai_prompts'
          AND column_name = 'system_prompt'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_ai_prompts ADD COLUMN system_prompt TEXT;
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '85'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_ai_prompts'
          AND column_name = 'system_prompt'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_ai_prompts DROP COLUMN system_prompt;
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '84'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
