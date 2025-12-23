defmodule PhoenixKit.DBSync.Transfers do
  @moduledoc """
  Context module for managing DB Sync transfers.

  Provides CRUD operations and business logic for tracking data transfers
  between PhoenixKit instances, including approval workflow support.

  ## Transfer Directions

  - `"send"` - This site sent data to another site
  - `"receive"` - This site received data from another site

  ## Status Flow

  ```
  pending → pending_approval → approved → in_progress → completed
                            ↘
                            denied
                            ↘
                            expired (approval timed out)

  pending → in_progress → completed
                       ↘
                       failed
                       ↘
                       cancelled
  ```

  ## Usage Examples

      # Create a transfer record
      {:ok, transfer} = Transfers.create_transfer(%{
        direction: "receive",
        connection_id: conn.id,
        table_name: "users",
        records_requested: 100,
        conflict_strategy: "skip"
      })

      # Start a transfer
      {:ok, transfer} = Transfers.start_transfer(transfer)

      # Update progress
      {:ok, transfer} = Transfers.update_progress(transfer, %{
        records_transferred: 50,
        records_created: 45,
        records_skipped: 5
      })

      # Complete a transfer
      {:ok, transfer} = Transfers.complete_transfer(transfer)
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.DBSync.Transfer
  alias PhoenixKit.RepoHelper

  # ===========================================
  # CRUD OPERATIONS
  # ===========================================

  @doc """
  Creates a new transfer record.

  ## Parameters

  - `attrs` - Transfer attributes:
    - `:direction` (required) - "send" or "receive"
    - `:table_name` (required) - Name of the table being transferred
    - `:connection_id` - ID of the permanent connection (if used)
    - `:session_code` - Ephemeral session code (if used)
    - `:remote_site_url` - URL of the other site
    - `:records_requested` - Number of records requested
    - `:conflict_strategy` - "skip", "overwrite", "merge", "append"
    - `:requires_approval` - Whether this transfer needs approval
    - `:requester_ip` - IP address of the requester
    - `:requester_user_agent` - User agent of the requester
    - `:initiated_by` - User ID who initiated the transfer
    - `:metadata` - Additional context as a map

  ## Examples

      {:ok, transfer} = Transfers.create_transfer(%{
        direction: "receive",
        table_name: "users",
        connection_id: 123,
        records_requested: 500,
        conflict_strategy: "skip",
        initiated_by: current_user.id
      })
  """
  @spec create_transfer(map()) :: {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def create_transfer(attrs) do
    repo = RepoHelper.repo()

    %Transfer{}
    |> Transfer.changeset(attrs)
    |> repo.insert()
  end

  @doc """
  Gets a transfer by ID.
  """
  @spec get_transfer(integer()) :: Transfer.t() | nil
  def get_transfer(id) do
    repo = RepoHelper.repo()
    repo.get(Transfer, id)
  end

  @doc """
  Gets a transfer by ID, raising if not found.
  """
  @spec get_transfer!(integer()) :: Transfer.t()
  def get_transfer!(id) do
    repo = RepoHelper.repo()
    repo.get!(Transfer, id)
  end

  @doc """
  Gets a transfer by ID with associations preloaded.

  ## Options

  - `:preload` - List of associations to preload

  ## Examples

      transfer = Transfers.get_transfer_with_preloads(123, [:connection])
  """
  @spec get_transfer_with_preloads(integer(), keyword()) :: Transfer.t() | nil
  def get_transfer_with_preloads(id, opts \\ []) do
    repo = RepoHelper.repo()
    preloads = Keyword.get(opts, :preload, [])

    Transfer
    |> repo.get(id)
    |> case do
      nil -> nil
      transfer -> repo.preload(transfer, preloads)
    end
  end

  @doc """
  Lists transfers with optional filters.

  ## Options

  - `:direction` - Filter by direction ("send" or "receive")
  - `:status` - Filter by status or list of statuses
  - `:connection_id` - Filter by connection ID
  - `:table_name` - Filter by table name
  - `:requires_approval` - Filter by approval requirement
  - `:from` - Filter by inserted_at >= date
  - `:to` - Filter by inserted_at <= date
  - `:limit` - Maximum results
  - `:offset` - Number of results to skip
  - `:preload` - Associations to preload
  - `:order` - Order direction (:asc or :desc, default :desc)

  ## Examples

      # List all pending approvals
      transfers = Transfers.list_transfers(status: "pending_approval", requires_approval: true)

      # List recent transfers for a connection
      transfers = Transfers.list_transfers(connection_id: 123, limit: 10)

      # List transfers within date range
      transfers = Transfers.list_transfers(from: ~U[2025-01-01 00:00:00Z], to: ~U[2025-12-31 23:59:59Z])
  """
  @spec list_transfers(keyword()) :: [Transfer.t()]
  def list_transfers(opts \\ []) do
    repo = RepoHelper.repo()
    order = Keyword.get(opts, :order, :desc)

    Transfer
    |> filter_by_direction(opts[:direction])
    |> filter_by_status(opts[:status])
    |> filter_by_connection(opts[:connection_id])
    |> filter_by_table(opts[:table_name])
    |> filter_by_approval_requirement(opts[:requires_approval])
    |> filter_by_date_range(opts[:from], opts[:to])
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
    |> order_by([t], [{^order, t.inserted_at}])
    |> maybe_preload(opts[:preload])
    |> repo.all()
  end

  @doc """
  Counts transfers with optional filters.

  Accepts same filter options as `list_transfers/1`.
  """
  @spec count_transfers(keyword()) :: non_neg_integer()
  def count_transfers(opts \\ []) do
    repo = RepoHelper.repo()

    Transfer
    |> filter_by_direction(opts[:direction])
    |> filter_by_status(opts[:status])
    |> filter_by_connection(opts[:connection_id])
    |> filter_by_table(opts[:table_name])
    |> filter_by_approval_requirement(opts[:requires_approval])
    |> filter_by_date_range(opts[:from], opts[:to])
    |> repo.aggregate(:count, :id)
  end

  @doc """
  Deletes a transfer.

  ## Examples

      {:ok, transfer} = Transfers.delete_transfer(transfer)
  """
  @spec delete_transfer(Transfer.t()) :: {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def delete_transfer(%Transfer{} = transfer) do
    repo = RepoHelper.repo()
    repo.delete(transfer)
  end

  # ===========================================
  # TRANSFER WORKFLOW
  # ===========================================

  @doc """
  Starts a transfer (changes status to "in_progress").

  Only transfers that can be started (pending without approval, or approved)
  will be updated.

  ## Examples

      {:ok, transfer} = Transfers.start_transfer(transfer)
  """
  @spec start_transfer(Transfer.t()) ::
          {:ok, Transfer.t()} | {:error, :cannot_start | Ecto.Changeset.t()}
  def start_transfer(%Transfer{} = transfer) do
    if Transfer.can_start?(transfer) do
      repo = RepoHelper.repo()

      transfer
      |> Transfer.start_changeset()
      |> repo.update()
    else
      {:error, :cannot_start}
    end
  end

  @doc """
  Updates transfer progress.

  ## Parameters

  - `transfer` - The transfer to update
  - `attrs` - Progress attributes:
    - `:records_transferred` - Total records transferred so far
    - `:records_created` - New records created
    - `:records_updated` - Existing records updated
    - `:records_skipped` - Records skipped (conflicts)
    - `:records_failed` - Records that failed
    - `:bytes_transferred` - Total bytes transferred

  ## Examples

      {:ok, transfer} = Transfers.update_progress(transfer, %{
        records_transferred: 100,
        records_created: 95,
        records_skipped: 5
      })
  """
  @spec update_progress(Transfer.t(), map()) :: {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def update_progress(%Transfer{} = transfer, attrs) do
    repo = RepoHelper.repo()

    transfer
    |> Transfer.progress_changeset(attrs)
    |> repo.update()
  end

  @doc """
  Completes a transfer successfully.

  ## Parameters

  - `transfer` - The transfer to complete
  - `final_stats` - Optional final statistics to record

  ## Examples

      {:ok, transfer} = Transfers.complete_transfer(transfer, %{
        records_transferred: 500,
        records_created: 480,
        records_updated: 15,
        records_skipped: 5
      })
  """
  @spec complete_transfer(Transfer.t(), map()) ::
          {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def complete_transfer(%Transfer{} = transfer, final_stats \\ %{}) do
    repo = RepoHelper.repo()

    transfer
    |> Transfer.complete_changeset(final_stats)
    |> repo.update()
  end

  @doc """
  Marks a transfer as failed.

  ## Parameters

  - `transfer` - The transfer to fail
  - `error_message` - Description of the failure

  ## Examples

      {:ok, transfer} = Transfers.fail_transfer(transfer, "Connection timeout")
  """
  @spec fail_transfer(Transfer.t(), String.t()) ::
          {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def fail_transfer(%Transfer{} = transfer, error_message) do
    repo = RepoHelper.repo()

    transfer
    |> Transfer.fail_changeset(error_message)
    |> repo.update()
  end

  @doc """
  Cancels a transfer.

  ## Examples

      {:ok, transfer} = Transfers.cancel_transfer(transfer)
  """
  @spec cancel_transfer(Transfer.t()) :: {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def cancel_transfer(%Transfer{} = transfer) do
    repo = RepoHelper.repo()

    transfer
    |> Transfer.cancel_changeset()
    |> repo.update()
  end

  # ===========================================
  # APPROVAL WORKFLOW
  # ===========================================

  @doc """
  Requests approval for a transfer.

  Sets the transfer to "pending_approval" status with an expiration time.

  ## Parameters

  - `transfer` - The transfer requiring approval
  - `expires_in_hours` - Hours until approval expires (default: 24)

  ## Examples

      {:ok, transfer} = Transfers.request_approval(transfer, 48)
  """
  @spec request_approval(Transfer.t(), non_neg_integer()) ::
          {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def request_approval(%Transfer{} = transfer, expires_in_hours \\ 24) do
    repo = RepoHelper.repo()

    transfer
    |> Transfer.request_approval_changeset(expires_in_hours)
    |> repo.update()
  end

  @doc """
  Approves a pending transfer.

  ## Parameters

  - `transfer` - The transfer to approve
  - `admin_user_id` - The user ID approving the transfer

  ## Examples

      {:ok, transfer} = Transfers.approve_transfer(transfer, current_user.id)
  """
  @spec approve_transfer(Transfer.t(), integer()) ::
          {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def approve_transfer(%Transfer{} = transfer, admin_user_id) do
    repo = RepoHelper.repo()

    transfer
    |> Transfer.approve_changeset(admin_user_id)
    |> repo.update()
  end

  @doc """
  Denies a pending transfer.

  ## Parameters

  - `transfer` - The transfer to deny
  - `admin_user_id` - The user ID denying the transfer
  - `reason` - Optional reason for denial

  ## Examples

      {:ok, transfer} = Transfers.deny_transfer(transfer, current_user.id, "Data too sensitive")
  """
  @spec deny_transfer(Transfer.t(), integer(), String.t() | nil) ::
          {:ok, Transfer.t()} | {:error, Ecto.Changeset.t()}
  def deny_transfer(%Transfer{} = transfer, admin_user_id, reason \\ nil) do
    repo = RepoHelper.repo()

    transfer
    |> Transfer.deny_changeset(admin_user_id, reason)
    |> repo.update()
  end

  @doc """
  Expires pending approval requests that have timed out.

  Returns the number of transfers expired.

  ## Examples

      {count, nil} = Transfers.expire_pending_approvals()
      IO.puts("Expired \#{count} approval requests")
  """
  @spec expire_pending_approvals() :: {non_neg_integer(), nil | term()}
  def expire_pending_approvals do
    repo = RepoHelper.repo()
    now = DateTime.utc_now()

    query =
      from t in Transfer,
        where: t.status == "pending_approval",
        where: not is_nil(t.approval_expires_at),
        where: t.approval_expires_at < ^now

    repo.update_all(query, set: [status: "expired"])
  end

  @doc """
  Lists transfers pending approval.

  ## Options

  - `:connection_id` - Filter by connection ID
  - `:table_name` - Filter by table name
  - `:limit` - Maximum results
  - `:preload` - Associations to preload

  ## Examples

      pending = Transfers.list_pending_approvals(connection_id: 123)
  """
  @spec list_pending_approvals(keyword()) :: [Transfer.t()]
  def list_pending_approvals(opts \\ []) do
    list_transfers(Keyword.merge(opts, status: "pending_approval", requires_approval: true))
  end

  # ===========================================
  # STATISTICS & QUERIES
  # ===========================================

  @doc """
  Gets transfer statistics for a connection.

  ## Returns

  Map with:
  - `:total_transfers` - Total number of transfers
  - `:completed` - Number of completed transfers
  - `:failed` - Number of failed transfers
  - `:total_records` - Total records transferred
  - `:total_bytes` - Total bytes transferred

  ## Examples

      stats = Transfers.connection_stats(123)
      # => %{total_transfers: 50, completed: 48, failed: 2, ...}
  """
  @spec connection_stats(integer()) :: map()
  def connection_stats(connection_id) do
    repo = RepoHelper.repo()

    query =
      from t in Transfer,
        where: t.connection_id == ^connection_id,
        select: %{
          total_transfers: count(t.id),
          completed: sum(fragment("CASE WHEN status = 'completed' THEN 1 ELSE 0 END")),
          failed: sum(fragment("CASE WHEN status = 'failed' THEN 1 ELSE 0 END")),
          total_records:
            sum(fragment("COALESCE(records_created, 0) + COALESCE(records_updated, 0)")),
          total_bytes: sum(t.bytes_transferred)
        }

    case repo.one(query) do
      nil ->
        %{total_transfers: 0, completed: 0, failed: 0, total_records: 0, total_bytes: 0}

      stats ->
        %{
          total_transfers: stats.total_transfers || 0,
          completed: stats.completed || 0,
          failed: stats.failed || 0,
          total_records: stats.total_records || 0,
          total_bytes: stats.total_bytes || 0
        }
    end
  end

  @doc """
  Gets transfer statistics grouped by table.

  ## Options

  - `:direction` - Filter by direction
  - `:connection_id` - Filter by connection
  - `:from` - Start date
  - `:to` - End date

  ## Examples

      stats = Transfers.table_stats(direction: "receive")
      # => [%{table_name: "users", count: 10, records: 5000}, ...]
  """
  @spec table_stats(keyword()) :: [map()]
  def table_stats(opts \\ []) do
    repo = RepoHelper.repo()

    Transfer
    |> filter_by_direction(opts[:direction])
    |> filter_by_connection(opts[:connection_id])
    |> filter_by_date_range(opts[:from], opts[:to])
    |> where([t], t.status == "completed")
    |> group_by([t], t.table_name)
    |> select([t], %{
      table_name: t.table_name,
      count: count(t.id),
      records: sum(fragment("COALESCE(records_created, 0) + COALESCE(records_updated, 0)")),
      bytes: sum(t.bytes_transferred)
    })
    |> order_by([t], desc: count(t.id))
    |> repo.all()
  end

  @doc """
  Gets recent transfers for display.

  ## Parameters

  - `limit` - Number of transfers to return (default: 10)

  ## Examples

      recent = Transfers.recent_transfers(5)
  """
  @spec recent_transfers(non_neg_integer()) :: [Transfer.t()]
  def recent_transfers(limit \\ 10) do
    list_transfers(limit: limit, order: :desc)
  end

  @doc """
  Gets active (in-progress) transfers.

  ## Examples

      active = Transfers.active_transfers()
  """
  @spec active_transfers() :: [Transfer.t()]
  def active_transfers do
    list_transfers(status: "in_progress")
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  defp filter_by_direction(query, nil), do: query
  defp filter_by_direction(query, direction), do: where(query, [t], t.direction == ^direction)

  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, statuses) when is_list(statuses),
    do: where(query, [t], t.status in ^statuses)

  defp filter_by_status(query, status), do: where(query, [t], t.status == ^status)

  defp filter_by_connection(query, nil), do: query

  defp filter_by_connection(query, connection_id),
    do: where(query, [t], t.connection_id == ^connection_id)

  defp filter_by_table(query, nil), do: query
  defp filter_by_table(query, table_name), do: where(query, [t], t.table_name == ^table_name)

  defp filter_by_approval_requirement(query, nil), do: query

  defp filter_by_approval_requirement(query, requires_approval),
    do: where(query, [t], t.requires_approval == ^requires_approval)

  defp filter_by_date_range(query, nil, nil), do: query
  defp filter_by_date_range(query, from, nil), do: where(query, [t], t.inserted_at >= ^from)
  defp filter_by_date_range(query, nil, to), do: where(query, [t], t.inserted_at <= ^to)

  defp filter_by_date_range(query, from, to),
    do: where(query, [t], t.inserted_at >= ^from and t.inserted_at <= ^to)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)
end
