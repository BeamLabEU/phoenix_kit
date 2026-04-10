defmodule PhoenixKit.Modules.Storage.FolderLink do
  @moduledoc """
  Schema for folder links (shortcuts).

  Allows a file to appear in multiple folders without moving it.
  The file's home folder is tracked via `folder_uuid` on the file itself;
  this junction table provides additional folder appearances.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_media_folder_links" do
    belongs_to :folder, PhoenixKit.Modules.Storage.Folder,
      foreign_key: :folder_uuid,
      references: :uuid

    belongs_to :file, PhoenixKit.Modules.Storage.File,
      foreign_key: :file_uuid,
      references: :uuid

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:folder_uuid, :file_uuid])
    |> validate_required([:folder_uuid, :file_uuid])
    |> foreign_key_constraint(:folder_uuid)
    |> foreign_key_constraint(:file_uuid)
    |> unique_constraint([:folder_uuid, :file_uuid])
  end
end
