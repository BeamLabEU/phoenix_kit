defmodule PhoenixKit.Handoff.Token do
  @moduledoc """
  One cross-domain handoff (V236, `phoenix_kit_handoff_tokens`), see `PhoenixKit.Handoff`.

  The raw token is never stored: `token_hash` is its SHA-256. The row is redeemable on
  `target_host` only, by the browser whose nonce hashes to `browser_nonce_hash`, until
  `expires_at`, once (`used_at`). `payload` maps a module's key to that module's snapshot.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.Users.Auth.User

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_handoff_tokens" do
    field :token_hash, :binary
    field :target_host, :string
    field :redirect_path, :string
    field :payload, :map, default: %{}
    field :browser_nonce_hash, :binary
    field :user_agent_hash, :binary
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
