defmodule PhoenixKit.Modules.Storage.LibraryMember do
  @moduledoc """
  Someone other than its owner who may use a user library (V203), and as
  what:

    * `manager` — everything the owner does to the library's files, and
      managing its viewers and contributors; not appointing, changing or
      removing other managers, trashing the library, nor handing it on.
      Only the owner manages Manager roles; a manager may still leave
    * `contributor` — upload, and change the files they uploaded; folder
      names and looks are shared. The media browser (`own_files_only`)
      refuses a contributor's change to anyone else's file, a folder write
      (trash, delete, move) whose subtree holds one, and emptying the trash
      or clearing orphans
    * `viewer` — see the files

  The owner is the library's `owner_uuid`, never a member row. A member row
  goes with its library and with its user.

  Go through `PhoenixKit.Modules.Storage.Libraries` rather than this schema.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type UUIDv7

  @roles ~w(manager contributor viewer)

  @type t :: %__MODULE__{
          library_uuid: UUIDv7.t() | nil,
          user_uuid: UUIDv7.t() | nil,
          role: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_storage_library_members" do
    belongs_to :library, PhoenixKit.Modules.Storage.Library,
      foreign_key: :library_uuid,
      references: :uuid,
      primary_key: true

    belongs_to :user, PhoenixKit.Users.Auth.User,
      foreign_key: :user_uuid,
      references: :uuid,
      primary_key: true

    field :role, :string, default: "viewer"

    timestamps(type: :utc_datetime)
  end

  @doc "The roles a member can have, most to least."
  @spec roles() :: [String.t()]
  def roles, do: @roles

  @doc false
  def changeset(member, attrs) do
    member
    |> cast(attrs, [:library_uuid, :user_uuid, :role])
    |> validate_required([:library_uuid, :user_uuid, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:library_uuid, :user_uuid],
      name: :phoenix_kit_storage_library_members_pkey,
      message: "is already a member"
    )
    |> foreign_key_constraint(:user_uuid,
      name: :phoenix_kit_storage_library_members_user_uuid_fkey
    )
  end

  @doc false
  def role_changeset(member, attrs) do
    member
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
  end
end
