defmodule PhoenixKit.Migrations.Postgres.V94 do
  @moduledoc """
  V94: Create media folders and folder links tables.

  Adds organizational folder hierarchy for media files.
  Folders are metadata-only — storage buckets are unaware of them.
  Files have one home folder; folder_links provide shortcuts to other folders.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Folders table
    create_if_not_exists table(:phoenix_kit_media_folders,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false, size: 255)
      add(:color, :string, size: 20)

      add(
        :parent_uuid,
        references(:phoenix_kit_media_folders,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )

      add(
        :user_uuid,
        references(:phoenix_kit_users,
          column: :uuid,
          type: :uuid,
          on_delete: :nothing,
          prefix: prefix
        )
      )

      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
      add(:updated_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(index(:phoenix_kit_media_folders, [:parent_uuid], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_media_folders, [:user_uuid], prefix: prefix))

    # Unique folder name per parent (COALESCE handles NULL parent for root-level uniqueness)
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{p}phoenix_kit_media_folders_name_parent_idx
    ON #{p}phoenix_kit_media_folders (name, COALESCE(parent_uuid, '00000000-0000-0000-0000-000000000000'))
    """)

    # Folder links (shortcuts)
    create_if_not_exists table(:phoenix_kit_media_folder_links,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(
        :folder_uuid,
        references(:phoenix_kit_media_folders,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :file_uuid,
        references(:phoenix_kit_files,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(index(:phoenix_kit_media_folder_links, [:folder_uuid], prefix: prefix))
    create_if_not_exists(index(:phoenix_kit_media_folder_links, [:file_uuid], prefix: prefix))

    create_if_not_exists(
      unique_index(:phoenix_kit_media_folder_links, [:folder_uuid, :file_uuid], prefix: prefix)
    )

    # Add folder_uuid to files
    alter table(:phoenix_kit_files, prefix: prefix) do
      add_if_not_exists(
        :folder_uuid,
        references(:phoenix_kit_media_folders,
          column: :uuid,
          type: :uuid,
          on_delete: :nilify_all,
          prefix: prefix
        )
      )
    end

    create_if_not_exists(index(:phoenix_kit_files, [:folder_uuid], prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '94'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(index(:phoenix_kit_files, [:folder_uuid], prefix: prefix))

    alter table(:phoenix_kit_files, prefix: prefix) do
      remove_if_exists(:folder_uuid, :uuid)
    end

    drop_if_exists(table(:phoenix_kit_media_folder_links, prefix: prefix))
    drop_if_exists(table(:phoenix_kit_media_folders, prefix: prefix))

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '90'")
  end

  defp prefix_str("public"), do: ""
  defp prefix_str(prefix), do: "#{prefix}."
end
