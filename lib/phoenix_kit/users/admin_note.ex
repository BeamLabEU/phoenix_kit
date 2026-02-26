defmodule PhoenixKit.Users.AdminNote do
  @moduledoc """
  Schema for admin notes about users.

  Admin notes allow administrators to record internal notes about users that are
  only visible to other administrators. This enables admin-to-admin communication
  about user accounts.

  ## Fields

  - `user_id` - The user being noted about
  - `author_id` - The admin who wrote the note
  - `content` - The note content
  - `inserted_at` - When the note was created
  - `updated_at` - When the note was last updated

  ## Permissions

  - Only admins can view, create, edit, and delete notes
  - Any admin can edit or delete any note
  - Notes show author information for accountability
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          user_uuid: UUIDv7.t() | nil,
          author_uuid: UUIDv7.t() | nil,
          content: String.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_admin_notes" do
    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      type: UUIDv7

    belongs_to :author, PhoenixKit.Users.Auth.User,
      foreign_key: :author_uuid,
      references: :uuid,
      type: UUIDv7

    field :content, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a new admin note.
  """
  def changeset(admin_note, attrs) do
    admin_note
    |> cast(attrs, [:user_uuid, :author_uuid, :content])
    |> validate_required([:user_uuid, :author_uuid, :content])
    |> validate_length(:content, min: 1, max: 10_000)
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:author_uuid)
  end

  @doc """
  Creates a changeset for updating an existing admin note.
  Only the content can be updated.
  """
  def update_changeset(admin_note, attrs) do
    admin_note
    |> cast(attrs, [:content])
    |> validate_required([:content])
    |> validate_length(:content, min: 1, max: 10_000)
  end
end
