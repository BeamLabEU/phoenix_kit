defmodule PhoenixKit.API.OAuth.Token do
  @moduledoc """
  An access or refresh token (table `phoenix_kit_api_oauth_tokens`). Only the SHA-256 of the
  token is stored (`PhoenixKit.API.OAuth.Tokens`).

    * `kind` - `"access"` or `"refresh"`.
    * `family` - the chain of rotations a token belongs to.
    * `parent_uuid` - the refresh token this one replaced when a refresh was retried (a plain
      column: the rows of one grant go together with the grant).
    * `used_at` - a refresh token is exchanged once.
    * `revoked_at`, `revoke_reason` - why a token was ended (`retry_superseded`,
      `grant_revoked`, `rotated`, ...).

  This module is the schema only.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.API.OAuth.Grant

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @kinds ~w(access refresh)

  schema "phoenix_kit_api_oauth_tokens" do
    field :token_hash, :binary, redact: true
    field :kind, :string
    field :family, UUIDv7
    field :parent_uuid, UUIDv7
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :revoke_reason, :string

    belongs_to :grant, Grant, foreign_key: :grant_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The kinds a token can be."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds
end
