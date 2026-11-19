defmodule PhoenixKit.API.OAuth.Code do
  @moduledoc """
  An authorization code (table `phoenix_kit_api_oauth_codes`): the SHA-256 of 32 random
  bytes, good for 60 seconds, exchanged once (`used_at`). It is bound to the grant (client,
  resource, person) and to the `redirect_uri` and `code_challenge` of the request it came
  from.

  This module is the schema only.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.API.OAuth.Grant

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_api_oauth_codes" do
    field :code_hash, :binary, redact: true
    field :redirect_uri, :string
    field :code_challenge, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :grant, Grant, foreign_key: :grant_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
