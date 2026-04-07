defmodule PhoenixKit.Modules.Storage.Folder do
  @moduledoc """
  Schema for media folders.

  Provides hierarchical organization for media files. Folders are purely
  metadata — storage buckets are unaware of folder structure.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_media_folders" do
    field :name, :string

    belongs_to :parent, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid

    has_many :children, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid

    has_many :files, PhoenixKit.Modules.Storage.File,
      foreign_key: :folder_uuid,
      references: :uuid

    has_many :folder_links, PhoenixKit.Modules.Storage.FolderLink,
      foreign_key: :folder_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:name, :parent_uuid, :user_uuid])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> foreign_key_constraint(:parent_uuid)
    |> foreign_key_constraint(:user_uuid)
    |> unique_constraint([:name, :parent_uuid],
      name: :phoenix_kit_media_folders_name_parent_idx
    )
  end
end
