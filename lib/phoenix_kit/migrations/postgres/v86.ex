defmodule PhoenixKit.Migrations.Postgres.V86 do
  @moduledoc """
  V86: Add Document Creator tables.

  Creates the three tables needed by the PhoenixKitDocumentCreator module:
  - `phoenix_kit_doc_headers_footers` — reusable header/footer designs
  - `phoenix_kit_doc_templates` — document templates with GrapesJS editor content
  - `phoenix_kit_doc_documents` — documents created from templates with baked header/footer content
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # ── Headers & Footers ──────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_doc_headers_footers,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:type, :string, null: false, default: "header", size: 20)
      add(:html, :text, default: "")
      add(:css, :text, default: "")
      add(:native, :map)
      add(:height, :string, default: "25mm", size: 20)
      add(:data, :map, default: %{})
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_doc_headers_footers, [:type], prefix: prefix))

    # ── Templates ──────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_doc_templates,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)
      add(:slug, :string, size: 255)
      add(:description, :text)
      add(:status, :string, default: "published", size: 20)

      add(:content_html, :text, default: "")
      add(:content_css, :text, default: "")
      add(:content_native, :map)

      add(:variables, :map, default: fragment("'[]'::jsonb"))

      add(
        :header_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(
        :footer_uuid,
        references(:phoenix_kit_doc_headers_footers,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:config, :map, default: %{paper_size: "a4", orientation: "portrait"})
      add(:data, :map, default: %{})
      add(:thumbnail, :text)
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(unique_index(:phoenix_kit_doc_templates, [:slug], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_doc_templates, [:status], prefix: prefix))

    # ── Documents ──────────────────────────────────────────────────
    create_if_not_exists table(:phoenix_kit_doc_documents,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:name, :string, null: false, size: 255)

      add(
        :template_uuid,
        references(:phoenix_kit_doc_templates,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(:content_html, :text, default: "")
      add(:content_css, :text, default: "")
      add(:content_native, :map)

      add(:variable_values, :map, default: %{})

      # Baked header/footer content (no FK — self-contained)
      add(:header_html, :text, default: "")
      add(:header_css, :text, default: "")
      add(:header_height, :string, default: "25mm", size: 20)
      add(:footer_html, :text, default: "")
      add(:footer_css, :text, default: "")
      add(:footer_height, :string, default: "20mm", size: 20)

      add(:config, :map, default: %{paper_size: "a4", orientation: "portrait"})
      add(:data, :map, default: %{})
      add(:thumbnail, :text)
      add(:created_by_uuid, :uuid)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:phoenix_kit_doc_documents, [:template_uuid], prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '86'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(table(:phoenix_kit_doc_documents, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_doc_templates, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_doc_headers_footers, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '85'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
