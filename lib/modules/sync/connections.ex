defmodule PhoenixKit.Modules.Sync.Connections do
  @moduledoc """
  Context module for managing DB Sync connections.

  Provides CRUD operations and business logic for persistent connections
  between PhoenixKit instances. Connections replace ephemeral session codes
  with permanent token-based authentication.

  ## Connection Directions

  - `"sender"` - This site sends data to other sites
  - `"receiver"` - This site receives data from other sites

  ## Approval Modes (Sender-side)

  - `"auto_approve"` - All transfers are automatically approved
  - `"require_approval"` - Each transfer needs manual approval
  - `"per_table"` - Tables in `auto_approve_tables` don't need approval

  ## Connection Status Flow

  ```
  pending → active → suspended → revoked
                  ↘
                  expired (auto-set when limits exceeded or past expires_at)
  ```

  ## Usage Examples

      # Create a sender connection
      {:ok, conn, token} = Connections.create_connection(%{
        name: "Production Receiver",
        direction: "sender",
        site_url: "https://receiver.example.com",
        approval_mode: "auto_approve"
      })

      # Validate an incoming connection
      {:ok, conn} = Connections.validate_connection(token, "192.168.1.1")

      # Update connection statistics after transfer
      {:ok, conn} = Connections.record_transfer(conn, %{
        records_count: 100,
        bytes_count: 50000
      })
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Sync.Connection
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  # ===========================================
  # CRUD OPERATIONS
  # ===========================================

  @doc """
  Creates a new connection with a generated auth token.

  Returns both the connection and the raw auth token (token is only shown once).

  ## Parameters

  - `attrs` - Connection attributes:
    - `:name` (required) - Human-readable name
    - `:direction` (required) - "sender" or "receiver"
    - `:site_url` (required) - URL of the remote site
    - `:approval_mode` - "auto_approve", "require_approval", "per_table"
    - `:created_by` - User ID who created the connection
    - Other optional settings

  ## Examples

      {:ok, conn, token} = Connections.create_connection(%{
        name: "Staging Server",
        direction: "sender",
        site_url: "https://staging.example.com",
        created_by_uuid: current_user.uuid
      })

      # Token is only returned once - store it securely!
      IO.puts("Auth token: \#{token}")
  """
  @spec create_connection(map()) ::
          {:ok, Connection.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_connection(attrs) do
    repo = RepoHelper.repo()

    # Use provided token or generate a new one
    token = attrs["auth_token"] || attrs[:auth_token] || Connection.generate_auth_token()

    # Use string key to match form params (avoid mixed atom/string keys)
    attrs_with_token = Map.put(attrs, "auth_token", token)

    %Connection{}
    |> Connection.changeset(attrs_with_token)
    |> repo.insert()
    |> case do
      {:ok, connection} -> {:ok, connection, token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Gets a connection by UUID.

  Accepts:
  - UUID string: `get_connection("01234567-89ab-cdef-0123-456789abcdef")`
  """
  @spec get_connection(String.t()) :: Connection.t() | nil
  def get_connection(id) when is_binary(id) do
    repo = RepoHelper.repo()

    if UUIDUtils.valid?(id) do
      repo.get_by(Connection, uuid: id)
    else
      nil
    end
  end

  def get_connection(_), do: nil

  @doc """
  Gets a connection by UUID, raising if not found.

  Accepts same inputs as `get_connection/1`.
  """
  @spec get_connection!(String.t()) :: Connection.t()
  def get_connection!(id) do
    case get_connection(id) do
      nil -> raise Ecto.NoResultsError, queryable: Connection
      connection -> connection
    end
  end

  @doc """
  Lists all connections with optional filters.

  ## Options

  - `:direction` - Filter by direction ("sender" or "receiver")
  - `:status` - Filter by status
  - `:limit` - Maximum results
  - `:offset` - Number of results to skip
  - `:preload` - Associations to preload

  ## Examples

      connections = Connections.list_connections(direction: "sender", status: "active")
  """
  @spec list_connections(keyword()) :: [Connection.t()]
  def list_connections(opts \\ []) do
    repo = RepoHelper.repo()

    Connection
    |> filter_by_direction(opts[:direction])
    |> filter_by_status(opts[:status])
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> order_by([c], desc: c.inserted_at)
    |> maybe_preload(opts[:preload])
    |> repo.all()
  end

  @doc """
  Counts connections with optional filters.

  ## Options

  - `:direction` - Filter by direction
  - `:status` - Filter by status
  """
  @spec count_connections(keyword()) :: non_neg_integer()
  def count_connections(opts \\ []) do
    repo = RepoHelper.repo()

    Connection
    |> filter_by_direction(opts[:direction])
    |> filter_by_status(opts[:status])
    |> repo.aggregate(:count)
  end

  @doc """
  Updates a connection's settings.

  ## Examples

      {:ok, conn} = Connections.update_connection(conn, %{
        name: "New Name",
        max_downloads: 100
      })
  """
  @spec update_connection(Connection.t(), map()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def update_connection(%Connection{} = connection, attrs) do
    repo = RepoHelper.repo()

    connection
    |> Connection.settings_changeset(attrs)
    |> repo.update()
  end

  @doc """
  Deletes a connection.

  ## Examples

      {:ok, conn} = Connections.delete_connection(conn)
  """
  @spec delete_connection(Connection.t()) :: {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def delete_connection(%Connection{} = connection) do
    repo = RepoHelper.repo()
    repo.delete(connection)
  end

  # ===========================================
  # STATUS MANAGEMENT
  # ===========================================

  @doc """
  Approves a pending connection, making it active.

  ## Parameters

  - `connection` - The connection to approve
  - `admin_user_uuid` - The user ID approving the connection

  ## Examples

      {:ok, conn} = Connections.approve_connection(conn, current_user.uuid)
  """
  @spec approve_connection(Connection.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def approve_connection(%Connection{} = connection, admin_user_uuid) do
    repo = RepoHelper.repo()

    connection
    |> Connection.approve_changeset(admin_user_uuid)
    |> repo.update()
  end

  @doc """
  Suspends an active connection.

  ## Parameters

  - `connection` - The connection to suspend
  - `admin_user_uuid` - The user ID suspending the connection
  - `reason` - Optional reason for suspension

  ## Examples

      {:ok, conn} = Connections.suspend_connection(conn, current_user.uuid, "Security audit")
  """
  @spec suspend_connection(Connection.t(), String.t(), String.t() | nil) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def suspend_connection(%Connection{} = connection, admin_user_uuid, reason \\ nil) do
    repo = RepoHelper.repo()

    connection
    |> Connection.suspend_changeset(admin_user_uuid, reason)
    |> repo.update()
  end

  @doc """
  Revokes a connection permanently.

  ## Parameters

  - `connection` - The connection to revoke
  - `admin_user_uuid` - The user ID revoking the connection
  - `reason` - Optional reason for revocation

  ## Examples

      {:ok, conn} = Connections.revoke_connection(conn, current_user.uuid, "Compromised")
  """
  @spec revoke_connection(Connection.t(), String.t(), String.t() | nil) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def revoke_connection(%Connection{} = connection, admin_user_uuid, reason \\ nil) do
    repo = RepoHelper.repo()

    connection
    |> Connection.revoke_changeset(admin_user_uuid, reason)
    |> repo.update()
  end

  @doc """
  Reactivates a suspended connection.

  ## Examples

      {:ok, conn} = Connections.reactivate_connection(conn)
  """
  @spec reactivate_connection(Connection.t()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def reactivate_connection(%Connection{} = connection) do
    repo = RepoHelper.repo()

    connection
    |> Connection.reactivate_changeset()
    |> repo.update()
  end

  # ===========================================
  # AUTHENTICATION & VALIDATION
  # ===========================================

  @doc """
  Validates an auth token and returns the connection if valid.

  Performs comprehensive validation including:
  - Token verification
  - Status check (must be active)
  - Expiration check
  - Download limits check
  - Record limits check
  - IP whitelist check (if provided)
  - Time-of-day restrictions check

  ## Parameters

  - `token` - The auth token to validate
  - `client_ip` - The client's IP address (optional)

  ## Returns

  - `{:ok, connection}` - Connection is valid and ready to use
  - `{:error, reason}` - Validation failed with reason:
    - `:invalid_token` - Token doesn't match any connection
    - `:connection_not_active` - Connection status is not "active"
    - `:connection_expired` - Connection has expired
    - `:download_limit_reached` - Max downloads exceeded
    - `:record_limit_reached` - Max records exceeded
    - `:ip_not_allowed` - Client IP not in whitelist
    - `:outside_allowed_hours` - Current time outside allowed hours

  ## Examples

      case Connections.validate_connection(token, client_ip) do
        {:ok, conn} -> proceed_with_transfer(conn)
        {:error, :connection_expired} -> send_error("Connection has expired")
        {:error, reason} -> send_error("Access denied: \#{reason}")
      end
  """
  @spec validate_connection(String.t(), String.t() | nil) ::
          {:ok, Connection.t()} | {:error, atom()}
  def validate_connection(token, client_ip \\ nil) do
    with {:ok, connection} <- find_by_token(token),
         :ok <- check_status(connection),
         :ok <- check_expiration(connection),
         :ok <- check_download_limits(connection),
         :ok <- check_record_limits(connection),
         :ok <- check_ip_whitelist(connection, client_ip),
         :ok <- check_allowed_hours(connection) do
      {:ok, connection}
    end
  end

  @doc """
  Validates a download password for a connection.

  ## Examples

      case Connections.validate_download_password(conn, password) do
        :ok -> proceed()
        {:error, :invalid_password} -> deny_access()
      end
  """
  @spec validate_download_password(Connection.t(), String.t() | nil) ::
          :ok | {:error, :invalid_password}
  def validate_download_password(%Connection{} = connection, password) do
    if Connection.verify_download_password(connection, password) do
      :ok
    else
      {:error, :invalid_password}
    end
  end

  @doc """
  Finds a connection by auth token.

  ## Examples

      {:ok, conn} = Connections.find_by_token(token)
  """
  @spec find_by_token(String.t()) :: {:ok, Connection.t()} | {:error, :invalid_token}
  def find_by_token(token) when is_binary(token) do
    repo = RepoHelper.repo()
    token_hash = hash_token(token)

    case repo.get_by(Connection, auth_token_hash: token_hash) do
      nil -> {:error, :invalid_token}
      connection -> {:ok, connection}
    end
  end

  @doc """
  Finds a connection by site URL and direction.

  ## Examples

      conn = Connections.find_by_site_url("https://example.com", "sender")
  """
  @spec find_by_site_url(String.t(), String.t()) :: Connection.t() | nil
  def find_by_site_url(site_url, direction) when is_binary(site_url) and is_binary(direction) do
    repo = RepoHelper.repo()
    repo.get_by(Connection, site_url: site_url, direction: direction)
  end

  @doc """
  Finds a connection by site URL and auth token hash.

  Used to identify a specific connection when the remote site requests deletion.

  ## Examples

      conn = Connections.find_by_site_url_and_hash("https://example.com", "abc123hash")
  """
  @spec find_by_site_url_and_hash(String.t(), String.t()) :: Connection.t() | nil
  def find_by_site_url_and_hash(site_url, auth_token_hash)
      when is_binary(site_url) and is_binary(auth_token_hash) do
    repo = RepoHelper.repo()

    from(c in Connection,
      where: c.site_url == ^site_url and c.auth_token_hash == ^auth_token_hash
    )
    |> repo.one()
  end

  @doc """
  Finds a connection by auth token hash and direction.

  The auth_token_hash is unique per connection pair, so this can be used
  to find a specific connection without needing the site URL.
  """
  @spec find_by_hash_and_direction(String.t(), String.t()) :: Connection.t() | nil
  def find_by_hash_and_direction(auth_token_hash, direction)
      when is_binary(auth_token_hash) and is_binary(direction) do
    repo = RepoHelper.repo()

    from(c in Connection,
      where: c.auth_token_hash == ^auth_token_hash and c.direction == ^direction
    )
    |> repo.one()
  end

  # ===========================================
  # TRANSFER TRACKING
  # ===========================================

  @doc """
  Records a transfer and updates connection statistics.

  Should be called after each successful data transfer.

  ## Parameters

  - `connection` - The connection to update
  - `attrs` - Transfer statistics:
    - `:records_count` - Number of records transferred
    - `:bytes_count` - Bytes transferred

  ## Examples

      {:ok, conn} = Connections.record_transfer(conn, %{
        records_count: 500,
        bytes_count: 250000
      })
  """
  @spec record_transfer(Connection.t(), map()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def record_transfer(%Connection{} = connection, attrs) do
    repo = RepoHelper.repo()

    records_count = Map.get(attrs, :records_count, 0)
    bytes_count = Map.get(attrs, :bytes_count, 0)

    stats_attrs = %{
      downloads_used: connection.downloads_used + 1,
      records_downloaded: connection.records_downloaded + records_count,
      total_transfers: connection.total_transfers + 1,
      total_records_transferred: connection.total_records_transferred + records_count,
      total_bytes_transferred: connection.total_bytes_transferred + bytes_count,
      last_connected_at: UtilsDate.utc_now(),
      last_transfer_at: UtilsDate.utc_now()
    }

    connection
    |> Connection.stats_changeset(stats_attrs)
    |> repo.update()
  end

  @doc """
  Updates last connected timestamp.

  ## Examples

      {:ok, conn} = Connections.touch_connected(conn)
  """
  @spec touch_connected(Connection.t()) :: {:ok, Connection.t()} | {:error, Ecto.Changeset.t()}
  def touch_connected(%Connection{} = connection) do
    repo = RepoHelper.repo()

    connection
    |> Connection.stats_changeset(%{last_connected_at: UtilsDate.utc_now()})
    |> repo.update()
  end

  # ===========================================
  # ACCESS CONTROL HELPERS
  # ===========================================

  @doc """
  Checks if a table is allowed for this connection.

  Takes into account both `allowed_tables` and `excluded_tables`.

  ## Examples

      Connections.table_allowed?(conn, "users")
      # => true

      Connections.table_allowed?(conn, "secrets")
      # => false
  """
  @spec table_allowed?(Connection.t(), String.t()) :: boolean()
  def table_allowed?(%Connection{} = connection, table_name) do
    Connection.table_allowed?(connection, table_name)
  end

  @doc """
  Checks if a table requires approval for this connection.

  ## Examples

      Connections.requires_approval?(conn, "users")
      # => true (for require_approval mode)
      # => false (for auto_approve mode)
      # => depends on auto_approve_tables (for per_table mode)
  """
  @spec requires_approval?(Connection.t(), String.t()) :: boolean()
  def requires_approval?(%Connection{} = connection, table_name) do
    Connection.requires_approval?(connection, table_name)
  end

  @doc """
  Gets the remaining download allowance for a connection.

  Returns `:unlimited` if no limit is set.

  ## Examples

      Connections.remaining_downloads(conn)
      # => 45 (if max_downloads: 50, downloads_used: 5)
      # => :unlimited (if max_downloads: nil)
  """
  @spec remaining_downloads(Connection.t()) :: non_neg_integer() | :unlimited
  def remaining_downloads(%Connection{max_downloads: nil}), do: :unlimited

  def remaining_downloads(%Connection{max_downloads: max, downloads_used: used}) do
    max(0, max - used)
  end

  @doc """
  Gets the remaining record allowance for a connection.

  Returns `:unlimited` if no limit is set.

  ## Examples

      Connections.remaining_records(conn)
      # => 9500 (if max_records_total: 10000, records_downloaded: 500)
      # => :unlimited (if max_records_total: nil)
  """
  @spec remaining_records(Connection.t()) :: non_neg_integer() | :unlimited
  def remaining_records(%Connection{max_records_total: nil}), do: :unlimited

  def remaining_records(%Connection{max_records_total: max, records_downloaded: downloaded}) do
    max(0, max - downloaded)
  end

  # ===========================================
  # EXPIRATION & CLEANUP
  # ===========================================

  @doc """
  Finds and marks expired connections.

  A connection is expired if:
  - `expires_at` is in the past, OR
  - `max_downloads` is exceeded, OR
  - `max_records_total` is exceeded

  Returns the number of connections marked as expired.

  ## Examples

      {count, nil} = Connections.expire_connections()
      IO.puts("Expired \#{count} connections")
  """
  @spec expire_connections() :: {non_neg_integer(), nil | term()}
  def expire_connections do
    repo = RepoHelper.repo()
    now = UtilsDate.utc_now()

    # Find connections to expire
    query =
      from c in Connection,
        where: c.status == "active",
        where:
          (not is_nil(c.expires_at) and c.expires_at < ^now) or
            (not is_nil(c.max_downloads) and c.downloads_used >= c.max_downloads) or
            (not is_nil(c.max_records_total) and c.records_downloaded >= c.max_records_total)

    repo.update_all(query, set: [status: "expired", updated_at: now])
  end

  @doc """
  Gets connections expiring soon (within given hours).

  Useful for sending expiration warnings.

  ## Examples

      expiring = Connections.expiring_soon(24)  # Expiring within 24 hours
  """
  @spec expiring_soon(non_neg_integer()) :: [Connection.t()]
  def expiring_soon(hours \\ 24) do
    repo = RepoHelper.repo()
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, hours * 3600, :second)

    from(c in Connection,
      where: c.status == "active",
      where: not is_nil(c.expires_at),
      where: c.expires_at > ^now and c.expires_at <= ^cutoff,
      order_by: [asc: c.expires_at]
    )
    |> repo.all()
  end

  # ===========================================
  # TOKEN MANAGEMENT
  # ===========================================

  @doc """
  Regenerates the auth token for a connection.

  Returns the new raw token (only shown once).

  ## Examples

      {:ok, conn, new_token} = Connections.regenerate_token(conn)
  """
  @spec regenerate_token(Connection.t()) ::
          {:ok, Connection.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def regenerate_token(%Connection{} = connection) do
    repo = RepoHelper.repo()
    new_token = Connection.generate_auth_token()

    connection
    |> Connection.changeset(%{auth_token: new_token})
    |> repo.update()
    |> case do
      {:ok, updated_connection} -> {:ok, updated_connection, new_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp filter_by_direction(query, nil), do: query
  defp filter_by_direction(query, direction), do: where(query, [c], c.direction == ^direction)

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [c], c.status == ^status)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  defp check_status(%Connection{status: "active"}), do: :ok
  defp check_status(_), do: {:error, :connection_not_active}

  defp check_expiration(%Connection{} = connection) do
    if Connection.expired?(connection) do
      {:error, :connection_expired}
    else
      :ok
    end
  end

  defp check_download_limits(%Connection{} = connection) do
    if Connection.within_download_limits?(connection) do
      :ok
    else
      {:error, :download_limit_reached}
    end
  end

  defp check_record_limits(%Connection{} = connection) do
    if Connection.within_record_limits?(connection) do
      :ok
    else
      {:error, :record_limit_reached}
    end
  end

  defp check_ip_whitelist(%Connection{} = connection, ip) do
    if Connection.ip_allowed?(connection, ip) do
      :ok
    else
      {:error, :ip_not_allowed}
    end
  end

  defp check_allowed_hours(%Connection{} = connection) do
    if Connection.within_allowed_hours?(connection) do
      :ok
    else
      {:error, :outside_allowed_hours}
    end
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
