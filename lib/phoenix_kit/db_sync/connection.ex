defmodule PhoenixKit.DBSync.Connection do
  @moduledoc """
  Schema for DB Sync persistent connections between PhoenixKit instances.

  Connections allow two PhoenixKit sites to establish a permanent relationship
  for data synchronization, replacing ephemeral session codes with token-based
  authentication.

  ## Direction

  Each connection has a direction:
  - `"sender"` - This site will send data (configured on the data-sharing site)
  - `"receiver"` - This site will receive data (configured on the data-receiving site)

  ## Approval Modes (Sender-side)

  - `"auto_approve"` - All transfers are automatically approved
  - `"require_approval"` - Each transfer needs manual approval
  - `"per_table"` - Tables in `auto_approve_tables` don't need approval, others do

  ## Status Flow

  ```
  pending → active → suspended → revoked
                  ↘
                  expired (auto-set when limits exceeded or past expires_at)
  ```

  ## Security Features

  - Token-based authentication (auth_token_hash)
  - Optional download password
  - IP whitelist
  - Time-of-day restrictions
  - Download and record limits
  - Expiration date

  ## Usage Examples

      # Create a sender connection
      {:ok, conn} = Connections.create_connection(%{
        name: "Production Receiver",
        direction: "sender",
        site_url: "https://receiver.example.com",
        approval_mode: "auto_approve"
      })

      # Approve a pending connection
      {:ok, conn} = Connections.approve_connection(conn, admin_user_id)

      # Suspend a connection
      {:ok, conn} = Connections.suspend_connection(conn, admin_user_id, "Security audit")
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Users.Auth.User

  @type t :: %__MODULE__{}

  @primary_key {:id, :id, autogenerate: true}

  @valid_directions ~w(sender receiver)
  @valid_statuses ~w(pending active suspended revoked expired)
  @valid_approval_modes ~w(auto_approve require_approval per_table)
  @valid_conflict_strategies ~w(skip overwrite merge append)

  schema "phoenix_kit_db_sync_connections" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :direction, :string
    field :site_url, :string
    field :auth_token, :string, virtual: true
    field :auth_token_hash, :string
    field :status, :string, default: "pending"

    # Sender-side settings
    field :approval_mode, :string, default: "auto_approve"
    field :allowed_tables, {:array, :string}, default: []
    field :excluded_tables, {:array, :string}, default: []
    field :auto_approve_tables, {:array, :string}, default: []

    # Expiration & limits
    field :expires_at, :utc_datetime_usec
    field :max_downloads, :integer
    field :downloads_used, :integer, default: 0
    field :max_records_total, :integer
    field :records_downloaded, :integer, default: 0

    # Per-request limits
    field :max_records_per_request, :integer, default: 10_000
    field :rate_limit_requests_per_minute, :integer, default: 60

    # Additional security
    field :download_password, :string, virtual: true
    field :download_password_hash, :string
    field :ip_whitelist, {:array, :string}, default: []
    field :allowed_hours_start, :integer
    field :allowed_hours_end, :integer

    # Receiver-side settings
    field :default_conflict_strategy, :string, default: "skip"
    field :auto_sync_enabled, :boolean, default: false
    field :auto_sync_tables, {:array, :string}, default: []
    field :auto_sync_interval_minutes, :integer, default: 60

    # Approval & status tracking
    field :approved_at, :utc_datetime_usec
    field :suspended_at, :utc_datetime_usec
    field :suspended_reason, :string
    field :revoked_at, :utc_datetime_usec
    field :revoked_reason, :string

    # Audit & statistics
    field :last_connected_at, :utc_datetime_usec
    field :last_transfer_at, :utc_datetime_usec
    field :total_transfers, :integer, default: 0
    field :total_records_transferred, :integer, default: 0
    field :total_bytes_transferred, :integer, default: 0

    field :metadata, :map, default: %{}

    belongs_to :approved_by_user, User, foreign_key: :approved_by
    belongs_to :suspended_by_user, User, foreign_key: :suspended_by
    belongs_to :revoked_by_user, User, foreign_key: :revoked_by
    belongs_to :created_by_user, User, foreign_key: :created_by

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for connection creation.
  """
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :name,
      :direction,
      :site_url,
      :auth_token,
      :status,
      :approval_mode,
      :allowed_tables,
      :excluded_tables,
      :auto_approve_tables,
      :expires_at,
      :max_downloads,
      :downloads_used,
      :max_records_total,
      :records_downloaded,
      :max_records_per_request,
      :rate_limit_requests_per_minute,
      :download_password,
      :ip_whitelist,
      :allowed_hours_start,
      :allowed_hours_end,
      :default_conflict_strategy,
      :auto_sync_enabled,
      :auto_sync_tables,
      :auto_sync_interval_minutes,
      :metadata,
      :created_by
    ])
    |> validate_required([:name, :direction, :site_url])
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:approval_mode, @valid_approval_modes)
    |> validate_inclusion(:default_conflict_strategy, @valid_conflict_strategies)
    |> validate_number(:max_records_per_request, greater_than: 0)
    |> validate_number(:rate_limit_requests_per_minute, greater_than: 0)
    |> validate_number(:allowed_hours_start,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 23
    )
    |> validate_number(:allowed_hours_end, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:auto_sync_interval_minutes, greater_than: 0)
    |> unique_constraint([:site_url, :direction],
      name: :phoenix_kit_db_sync_connections_site_direction_uidx
    )
    |> hash_auth_token()
    |> hash_download_password()
  end

  @doc """
  Changeset for approving a connection.
  """
  def approve_changeset(connection, admin_user_id) do
    connection
    |> change(%{
      status: "active",
      approved_at: DateTime.utc_now(),
      approved_by: admin_user_id
    })
  end

  @doc """
  Changeset for suspending a connection.
  """
  def suspend_changeset(connection, admin_user_id, reason \\ nil) do
    connection
    |> change(%{
      status: "suspended",
      suspended_at: DateTime.utc_now(),
      suspended_by: admin_user_id,
      suspended_reason: reason
    })
  end

  @doc """
  Changeset for revoking a connection.
  """
  def revoke_changeset(connection, admin_user_id, reason \\ nil) do
    connection
    |> change(%{
      status: "revoked",
      revoked_at: DateTime.utc_now(),
      revoked_by: admin_user_id,
      revoked_reason: reason
    })
  end

  @doc """
  Changeset for reactivating a suspended connection.
  """
  def reactivate_changeset(connection) do
    connection
    |> change(%{
      status: "active",
      suspended_at: nil,
      suspended_by: nil,
      suspended_reason: nil
    })
  end

  @doc """
  Changeset for updating connection statistics.
  """
  def stats_changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :downloads_used,
      :records_downloaded,
      :last_connected_at,
      :last_transfer_at,
      :total_transfers,
      :total_records_transferred,
      :total_bytes_transferred
    ])
  end

  @doc """
  Changeset for updating connection settings.
  """
  def settings_changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :name,
      :status,
      :approval_mode,
      :allowed_tables,
      :excluded_tables,
      :auto_approve_tables,
      :expires_at,
      :max_downloads,
      :downloads_used,
      :max_records_total,
      :records_downloaded,
      :max_records_per_request,
      :rate_limit_requests_per_minute,
      :download_password,
      :ip_whitelist,
      :allowed_hours_start,
      :allowed_hours_end,
      :default_conflict_strategy,
      :auto_sync_enabled,
      :auto_sync_tables,
      :auto_sync_interval_minutes,
      :approved_at,
      :suspended_at,
      :suspended_reason,
      :revoked_at,
      :revoked_reason,
      :last_connected_at,
      :last_transfer_at,
      :total_transfers,
      :total_records_transferred,
      :total_bytes_transferred,
      :metadata
    ])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:approval_mode, @valid_approval_modes)
    |> validate_inclusion(:default_conflict_strategy, @valid_conflict_strategies)
    |> validate_number(:max_records_per_request, greater_than: 0)
    |> validate_number(:rate_limit_requests_per_minute, greater_than: 0)
    |> validate_number(:allowed_hours_start,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 23
    )
    |> validate_number(:allowed_hours_end, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:auto_sync_interval_minutes, greater_than: 0)
    |> hash_download_password()
  end

  # Hash auth_token if provided
  defp hash_auth_token(changeset) do
    case get_change(changeset, :auth_token) do
      nil ->
        changeset

      token when is_binary(token) and byte_size(token) > 0 ->
        put_change(changeset, :auth_token_hash, hash_token(token))

      _ ->
        changeset
    end
  end

  # Hash download_password if provided
  defp hash_download_password(changeset) do
    case get_change(changeset, :download_password) do
      nil ->
        changeset

      "" ->
        # Empty string clears the password
        put_change(changeset, :download_password_hash, nil)

      password when is_binary(password) ->
        put_change(changeset, :download_password_hash, hash_token(password))

      _ ->
        changeset
    end
  end

  # Hash a token/password using SHA256
  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies an auth token against the stored hash.
  """
  def verify_auth_token(%__MODULE__{auth_token_hash: hash}, token) when is_binary(token) do
    hash_token(token) == hash
  end

  def verify_auth_token(_, _), do: false

  @doc """
  Verifies a download password against the stored hash.
  """
  def verify_download_password(%__MODULE__{download_password_hash: nil}, _), do: true
  def verify_download_password(%__MODULE__{download_password_hash: ""}, _), do: true

  def verify_download_password(%__MODULE__{download_password_hash: hash}, password)
      when is_binary(password) do
    hash_token(password) == hash
  end

  def verify_download_password(_, _), do: false

  @doc """
  Generates a secure random token for connection authentication.
  """
  def generate_auth_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc """
  Checks if a connection is currently active and within limits.
  """
  def active?(%__MODULE__{status: "active"} = conn) do
    not expired?(conn) and within_download_limits?(conn) and within_record_limits?(conn)
  end

  def active?(_), do: false

  @doc """
  Checks if a connection has expired.
  """
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Checks if a connection is within download limits.
  """
  def within_download_limits?(%__MODULE__{max_downloads: nil}), do: true

  def within_download_limits?(%__MODULE__{max_downloads: max, downloads_used: used}) do
    used < max
  end

  @doc """
  Checks if a connection is within record limits.
  """
  def within_record_limits?(%__MODULE__{max_records_total: nil}), do: true

  def within_record_limits?(%__MODULE__{max_records_total: max, records_downloaded: downloaded}) do
    downloaded < max
  end

  @doc """
  Checks if current time is within allowed hours.
  """
  def within_allowed_hours?(%__MODULE__{allowed_hours_start: nil}), do: true
  def within_allowed_hours?(%__MODULE__{allowed_hours_end: nil}), do: true

  def within_allowed_hours?(%__MODULE__{
        allowed_hours_start: start_hour,
        allowed_hours_end: end_hour
      }) do
    current_hour = DateTime.utc_now().hour

    if start_hour <= end_hour do
      current_hour >= start_hour and current_hour <= end_hour
    else
      # Handles overnight ranges (e.g., 22:00 to 06:00)
      current_hour >= start_hour or current_hour <= end_hour
    end
  end

  @doc """
  Checks if an IP address is in the whitelist.
  """
  def ip_allowed?(%__MODULE__{ip_whitelist: []}), do: true
  def ip_allowed?(%__MODULE__{ip_whitelist: nil}), do: true

  def ip_allowed?(%__MODULE__{ip_whitelist: whitelist}, ip) when is_binary(ip) do
    ip in whitelist
  end

  def ip_allowed?(_, _), do: false

  @doc """
  Checks if a table requires approval based on the connection's approval mode.
  """
  def requires_approval?(%__MODULE__{approval_mode: "auto_approve"}, _table), do: false
  def requires_approval?(%__MODULE__{approval_mode: "require_approval"}, _table), do: true

  def requires_approval?(
        %__MODULE__{approval_mode: "per_table", auto_approve_tables: tables},
        table
      ) do
    table not in tables
  end

  def requires_approval?(_, _), do: true

  @doc """
  Checks if a table is allowed to be accessed.
  """
  def table_allowed?(%__MODULE__{excluded_tables: excluded, allowed_tables: allowed}, table) do
    not_excluded = table not in excluded

    allowed_or_empty =
      case allowed do
        [] -> true
        _ -> table in allowed
      end

    not_excluded and allowed_or_empty
  end
end
