defmodule PhoenixKit.API.Keys.Key do
  @moduledoc """
  One API bearer key (table `phoenix_kit_api_keys`).

  A token is `pk_<prefix>_<secret>`: `prefix` (8 lowercase hex characters, unique) finds the
  row, and `secret_hash` (the SHA-256 of the 32-byte secret) is compared in constant time.
  The secret itself is never stored; `PhoenixKit.API.Keys` shows a token once, when it is
  created or rotated.

    * `user_uuid` - the owner. The key acts with the owner's permissions, evaluated on every
      request. Deleting the owner deletes the key.
    * `created_by_uuid` - who issued the key. Kept (as `nil`) when that person is deleted.
    * `scopes` - what the key may ask for, `"<module>.<resource>:<action>"`.
    * `allowed_ips` - CIDR ranges the key may be used from; empty means anywhere.
    * `requires_approval` - every write call of the key (not a read, not a `dry_run`)
      waits for a human, dangerous or not.
    * `expires_at`, `revoked_at` - a key past either is dead.
    * `personal` - a person's own key, made through `PhoenixKit.API.Keys.create_personal_key/3`
      (V226). Set by the server only, never cast from attributes: it works only while the
      owner holds `api_personal_keys` or `api`, always expires, never needs approval, and
      only its owner may rotate it. `false` for every other key.
    * `last_used_at`, `last_used_ip` - written at most once a minute.

  This module is the schema only. Creating, verifying, revoking and rotating keys is
  `PhoenixKit.API.Keys`.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.Users.Auth.User

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_api_keys" do
    field :name, :string
    field :prefix, :string
    field :secret_hash, :binary, redact: true
    field :scopes, {:array, :string}, default: []
    field :requires_approval, :boolean, default: false
    field :allowed_ips, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :last_used_ip, :string
    field :personal, :boolean, default: false

    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7
    belongs_to :created_by, User, foreign_key: :created_by_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime)
  end
end
