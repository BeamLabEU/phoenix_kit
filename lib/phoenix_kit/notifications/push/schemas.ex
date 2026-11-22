defmodule PhoenixKit.Notifications.Push.Installation do
  @moduledoc """
  A browser or device that turned push on (V235). One browser has ONE push
  subscription, shared by every account signed in there; the accounts opted
  in on it are its `bindings`. `endpoint` is a capability URL (whoever holds
  it can push to that device): never logged, looked up by `endpoint_hash`.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @timestamps_opts [type: :naive_datetime]

  @type t :: %__MODULE__{}

  schema "phoenix_kit_push_installations" do
    field :endpoint, :string
    field :endpoint_hash, :binary
    field :p256dh, :string
    field :auth, :string
    field :label, :string
    field :browser_id, :string
    field :vapid_key_id, :string
    field :last_success_at, :naive_datetime

    has_many :bindings, PhoenixKit.Notifications.Push.Binding,
      foreign_key: :installation_uuid,
      references: :uuid

    timestamps()
  end
end

defmodule PhoenixKit.Notifications.Push.Binding do
  @moduledoc "An account opted in to push on an installation (V235)."
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_push_bindings" do
    belongs_to :installation, PhoenixKit.Notifications.Push.Installation,
      foreign_key: :installation_uuid,
      references: :uuid,
      type: UUIDv7

    field :user_uuid, UUIDv7
    field :inserted_at, :naive_datetime, read_after_writes: true
  end
end

defmodule PhoenixKit.Notifications.Push.Pending do
  @moduledoc """
  A notification waiting for its user's next push (V235): the grouping reads
  and deletes these, so a burst becomes one push ("3 notifications pending").
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_push_pending" do
    field :user_uuid, UUIDv7
    field :notification_uuid, UUIDv7
    field :type_key, :string
    field :title, :string
    field :line, :string
    field :link, :string
    field :inserted_at, :naive_datetime, read_after_writes: true
  end
end
