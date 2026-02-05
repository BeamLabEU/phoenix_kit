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
          id: integer() | nil,
          user_id: integer(),
          author_id: integer(),
          content: String.t(),
          inserted_at: NaiveDateTime.t(),
          updated_at: NaiveDateTime.t()
        }

  schema "phoenix_kit_admin_notes" do
    field :uuid, Ecto.UUID, read_after_writes: true
    belongs_to :user, PhoenixKit.Users.Auth.User
    belongs_to :author, PhoenixKit.Users.Auth.User

    field :content, :string

    timestamps()
  end

  @doc """
  Creates a changeset for a new admin note.
  """
  def changeset(admin_note, attrs) do
    admin_note
    |> cast(attrs, [:user_id, :author_id, :content])
    |> validate_required([:user_id, :author_id, :content])
    |> validate_length(:content, min: 1, max: 10_000)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:author_id)
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
