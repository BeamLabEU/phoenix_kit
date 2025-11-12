defmodule PhoenixKit.AuditLog do
  @moduledoc """
  Context for managing audit logs in PhoenixKit.

  Provides functionality for logging administrative actions such as password resets,
  user modifications, and other sensitive operations that require tracking.

  ## Examples

      # Log an admin password reset
      PhoenixKit.AuditLog.log_password_change(%{
        target_user_id: 123,
        admin_user_id: 1,
        action: :admin_password_reset,
        ip_address: "192.168.1.1",
        user_agent: "Mozilla/5.0..."
      })

      # Query audit logs for a specific user
      PhoenixKit.AuditLog.list_logs_for_user(123)

      # Query audit logs by action type
      PhoenixKit.AuditLog.list_logs_by_action(:admin_password_reset)
  """

  import Ecto.Query, warn: false
  alias PhoenixKit.AuditLog.Entry
  alias PhoenixKit.Repo

  @doc """
  Logs a password change action performed by an admin.

  ## Parameters
    * `attrs` - Map containing:
      * `:target_user_id` - ID of the user whose password was changed (required)
      * `:admin_user_id` - ID of the admin who performed the action (required)
      * `:action` - The action performed (default: `:admin_password_reset`)
      * `:ip_address` - IP address of the admin (optional)
      * `:user_agent` - User agent string of the admin (optional)
      * `:metadata` - Additional metadata (optional)

  ## Examples

      iex> log_password_change(%{
      ...>   target_user_id: 123,
      ...>   admin_user_id: 1,
      ...>   action: :admin_password_reset,
      ...>   ip_address: "192.168.1.1"
      ...> })
      {:ok, %Entry{}}

  """
  def log_password_change(attrs) do
    attrs
    |> Map.put_new(:action, :admin_password_reset)
    |> create_log_entry()
  end

  @doc """
  Creates a generic audit log entry.

  ## Parameters
    * `attrs` - Map containing:
      * `:target_user_id` - ID of the user affected by the action (required)
      * `:admin_user_id` - ID of the admin who performed the action (required)
      * `:action` - The action performed (required)
      * `:ip_address` - IP address of the admin (optional)
      * `:user_agent` - User agent string of the admin (optional)
      * `:metadata` - Additional metadata (optional)

  ## Examples

      iex> create_log_entry(%{
      ...>   target_user_id: 123,
      ...>   admin_user_id: 1,
      ...>   action: :user_created,
      ...>   ip_address: "192.168.1.1"
      ...> })
      {:ok, %Entry{}}

  """
  def create_log_entry(attrs) do
    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists all audit log entries for a specific user.

  Returns entries where the user is either the target or the admin.

  ## Examples

      iex> list_logs_for_user(123)
      [%Entry{}, ...]

  """
  def list_logs_for_user(user_id) do
    from(e in Entry,
      where: e.target_user_id == ^user_id or e.admin_user_id == ^user_id,
      order_by: [desc: e.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists all audit log entries by action type.

  ## Examples

      iex> list_logs_by_action(:admin_password_reset)
      [%Entry{}, ...]

  """
  def list_logs_by_action(action) do
    action_string = to_string(action)

    from(e in Entry,
      where: e.action == ^action_string,
      order_by: [desc: e.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists all audit log entries with optional filters.

  ## Options
    * `:limit` - Maximum number of entries to return (default: 100)
    * `:offset` - Number of entries to skip (default: 0)
    * `:action` - Filter by action type
    * `:target_user_id` - Filter by target user ID
    * `:admin_user_id` - Filter by admin user ID
    * `:from_date` - Filter entries after this date
    * `:to_date` - Filter entries before this date

  ## Examples

      iex> list_logs(limit: 50, action: :admin_password_reset)
      [%Entry{}, ...]

  """
  def list_logs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    query = from(e in Entry, order_by: [desc: e.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:action, action}, query ->
          from(e in query, where: e.action == ^to_string(action))

        {:target_user_id, user_id}, query ->
          from(e in query, where: e.target_user_id == ^user_id)

        {:admin_user_id, user_id}, query ->
          from(e in query, where: e.admin_user_id == ^user_id)

        {:from_date, date}, query ->
          from(e in query, where: e.inserted_at >= ^date)

        {:to_date, date}, query ->
          from(e in query, where: e.inserted_at <= ^date)

        _other, query ->
          query
      end)

    query
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc """
  Gets a single audit log entry by ID.

  ## Examples

      iex> get_log!(123)
      %Entry{}

      iex> get_log!(456)
      ** (Ecto.NoResultsError)

  """
  def get_log!(id) do
    Repo.get!(Entry, id)
  end

  @doc """
  Counts audit log entries with optional filters.

  ## Options
    Same options as `list_logs/1` except `:limit` and `:offset`

  ## Examples

      iex> count_logs(action: :admin_password_reset)
      42

  """
  def count_logs(opts \\ []) do
    query = from(e in Entry)

    query =
      Enum.reduce(opts, query, fn
        {:action, action}, query ->
          from(e in query, where: e.action == ^to_string(action))

        {:target_user_id, user_id}, query ->
          from(e in query, where: e.target_user_id == ^user_id)

        {:admin_user_id, user_id}, query ->
          from(e in query, where: e.admin_user_id == ^user_id)

        {:from_date, date}, query ->
          from(e in query, where: e.inserted_at >= ^date)

        {:to_date, date}, query ->
          from(e in query, where: e.inserted_at <= ^date)

        _other, query ->
          query
      end)

    Repo.aggregate(query, :count)
  end
end
