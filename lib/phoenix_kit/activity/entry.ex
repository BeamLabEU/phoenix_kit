defmodule PhoenixKit.Activity.Entry do
  @moduledoc """
  Schema for activity feed entries.

  Records business-level actions across the platform: posts created, comments liked,
  users followed, passwords changed, etc.

  ## Fields

  - `action` — Dotted action string: "post.created", "comment.liked", "user.registered"
  - `actor_uuid` — Who performed the action (FK to users)
  - `resource_type` — What kind of thing was acted on: "post", "comment", "user"
  - `resource_uuid` — UUID of the resource
  - `target_uuid` — Optional: who was affected (e.g., follow target, message recipient)
  - `metadata` — Flexible JSONB context (title, old_value, new_value, etc.)
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          action: String.t(),
          actor_uuid: UUIDv7.t() | nil,
          resource_type: String.t() | nil,
          resource_uuid: Ecto.UUID.t() | nil,
          target_uuid: UUIDv7.t() | nil,
          metadata: map(),
          permanent: boolean(),
          actor: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t() | nil,
          target: PhoenixKit.Users.Auth.User.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "phoenix_kit_activities" do
    field(:action, :string)
    field(:module, :string)
    field(:mode, :string)
    field(:resource_type, :string)
    field(:resource_uuid, Ecto.UUID)
    field(:metadata, :map, default: %{})
    field(:actor_label, :string, virtual: true)
    # Never pruned. A settings change is the first kind of entry kept this
    # way; any module may keep one (`PhoenixKit.Activity.log/1` with
    # `permanent: true`).
    field(:permanent, :boolean, default: false)

    belongs_to(:actor, PhoenixKit.Users.Auth.User,
      foreign_key: :actor_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:target, PhoenixKit.Users.Auth.User,
      foreign_key: :target_uuid,
      references: :uuid,
      type: UUIDv7
    )

    # Microseconds: "what was X at that instant" walks a resource's entries
    # by time, and two changes inside one second must not read as
    # simultaneous.
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Changeset for creating an activity entry."
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :action,
      :module,
      :mode,
      :actor_uuid,
      :resource_type,
      :resource_uuid,
      :target_uuid,
      :metadata
    ])
    |> validate_required([:action])
    |> validate_length(:action, min: 1, max: 100)
    |> validate_length(:module, max: 50)
    |> validate_length(:mode, max: 20)
    |> validate_length(:resource_type, max: 50)
    |> foreign_key_constraint(:actor_uuid)
    |> foreign_key_constraint(:target_uuid)
  end
end
