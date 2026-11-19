defmodule PhoenixKit.API.OAuth.Grant do
  @moduledoc """
  One consent: a person let a client act as them, with the scopes of `scopes`, until
  `expires_at` (table `phoenix_kit_api_oauth_grants`).

    * `key_uuid` - the **hidden API key** the grant owns (one each, `oauth_grant_uuid` on the
      key points back). The key carries the actor, the rate limit, the confirmations and the
      activity of the grant; it is never shown or handled as a key
      (`PhoenixKit.API.Keys.create_oauth_key/3`).
    * `resource` - the one resource the tokens of this grant are for.
    * `activated_at` - set when the authorization code was exchanged; a consent nobody
      finished stays `nil`.
    * `revoked_at`, `last_used_at`, `created_ip`.

  The effective rights of a request are the grant's scopes narrowed to what its owner may do
  right now (`PhoenixKit.API.OAuth.Tokens.verify/2`). This module is the schema only; making
  and ending grants is `PhoenixKit.API.OAuth.Grants`.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.API.OAuth.Client
  alias PhoenixKit.Users.Auth.User

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_api_oauth_grants" do
    field :key_uuid, UUIDv7
    field :resource, :string
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :activated_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :created_ip, :string

    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7
    belongs_to :client, Client, foreign_key: :client_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime)
  end
end
