defmodule PhoenixKit.Users.Auth.KnownDevice do
  @moduledoc """
  A device (IP + hashed user-agent) a user has previously logged in from.

  Backs the new-login security alert: a login whose `(network,
  user_agent_hash)` pair has no matching row for the user is a "new
  device" and — when `new_login_alert_enabled` is on — triggers
  `user.new_login_detected` in the activity log plus an email via
  `PhoenixKit.Users.Auth.UserNotifier.deliver_new_login_alert/2`.

  Match uses `PhoenixKit.Utils.IpAddress.network/1` (IPv4 is the address,
  IPv6 is its `/64`). The unique index and stored `ip_address` stay the
  full address so Active Sessions / geo / audit still see it.

  `country_code` (V230) is the ISO 3166-1 alpha-2 country the device first
  signed in from, or `nil` when the lookup failed or the row predates V230.
  It backs the new-country alert (`new_country_login_alert_enabled`).

  `device_token_hash` (V230) recognizes the browser across updates and IP
  changes: a SHA-256 of the account's uuid and the browser's device cookie
  (`PhoenixKit.Users.LoginAlerts`, "Recognizing a browser"). `nil` on rows
  from before V230 until that browser signs in again from the same address.

  The user agent is stored pre-hashed (SHA-256 hex, via
  `PhoenixKit.Utils.SessionFingerprint.hash_user_agent/1`) — the raw UA
  string is never persisted.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  alias PhoenixKit.Users.Auth.User

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_user_known_devices" do
    field :ip_address, :string
    field :user_agent_hash, :string
    field :browser, :string
    field :os, :string
    field :location, :string
    field :country_code, :string
    field :device_token_hash, :string
    field :first_seen_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7
  end

  @doc false
  def changeset(known_device, attrs) do
    known_device
    |> Ecto.Changeset.cast(attrs, [
      :user_uuid,
      :ip_address,
      :user_agent_hash,
      :browser,
      :os,
      :location,
      :country_code,
      :device_token_hash,
      :first_seen_at,
      :last_seen_at
    ])
    |> Ecto.Changeset.validate_required([
      :user_uuid,
      :ip_address,
      :user_agent_hash,
      :first_seen_at,
      :last_seen_at
    ])
    |> Ecto.Changeset.validate_format(:country_code, ~r/\A[A-Z]{2}\z/)
    |> Ecto.Changeset.unique_constraint([:user_uuid, :ip_address, :user_agent_hash],
      name: :phoenix_kit_known_devices_user_ip_ua_index
    )
  end
end
