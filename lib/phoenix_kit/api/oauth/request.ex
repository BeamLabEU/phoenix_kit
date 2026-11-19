defmodule PhoenixKit.API.OAuth.Request do
  @moduledoc """
  One validated authorization request waiting for the person's consent (table
  `phoenix_kit_api_oauth_requests`).

  It is found by `request_token_hash`, the SHA-256 of a random token that sits in the
  consent URL; the token itself is never stored. It lives ten minutes and is used once
  (`consumed_at`). `client_snapshot` pins what the client's document said when the request
  was made (its name and redirect URIs), so a document that changes before the code is
  exchanged changes nothing.

  This module is the schema only.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.API.OAuth.Client

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_api_oauth_requests" do
    field :request_token_hash, :binary, redact: true
    field :redirect_uri, :string
    field :code_challenge, :string
    field :resource, :string
    field :state, :string
    field :requested_scopes, {:array, :string}, default: []
    field :client_snapshot, :map, default: %{}
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :client, Client, foreign_key: :client_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
