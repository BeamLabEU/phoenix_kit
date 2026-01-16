defmodule PhoenixKit.Modules.Sync.Web.ApiController do
  @moduledoc """
  API controller for Sync cross-site operations.

  Handles incoming connection registration requests from remote PhoenixKit sites.
  When a remote site creates a sender connection pointing to this site, they call
  this API to automatically register the connection here.

  ## Security

  - Incoming connection mode controls how requests are handled
  - Optional password protection for incoming connections
  - All connections are logged with remote site information

  ## Endpoints

  - `POST /{prefix}/sync/api/register-connection` - Register incoming connection
  """

  use PhoenixKitWeb, :controller

  require Logger

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Sync
  alias PhoenixKit.Modules.Sync.Connections
  alias PhoenixKit.Modules.Sync.Transfers

  @doc """
  Registers an incoming connection from a remote site.

  Expected JSON body:
  - `sender_url` (required) - URL of the site sending this request
  - `connection_name` (required) - Name for the connection
  - `auth_token` (required) - The auth token for the connection
  - `password` (optional) - Password if this site requires one

  ## Responses

  - 200 OK - Connection registered successfully
  - 400 Bad Request - Missing required fields
  - 401 Unauthorized - Invalid password
  - 403 Forbidden - Incoming connections are denied
  - 409 Conflict - Connection already exists for this site
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def register_connection(conn, params) do
    with :ok <- check_module_enabled(),
         :ok <- check_incoming_allowed(),
         {:ok, validated_params} <- validate_params(params),
         :ok <- validate_password(params["password"]),
         {:ok, result} <- create_incoming_connection(validated_params, conn) do
      Logger.info("Incoming connection registered", %{
        sender_url: validated_params.sender_url,
        connection_name: validated_params.connection_name,
        status: result.status
      })

      conn
      |> put_status(200)
      |> json(%{
        success: true,
        message: result.message,
        connection_status: result.status,
        connection_id: result.connection_id
      })
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :incoming_denied} ->
        conn
        |> put_status(403)
        |> json(%{success: false, error: "Incoming connections are not allowed"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :invalid_password} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Invalid password"})

      {:error, :password_required} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Password required for incoming connections"})

      {:error, :connection_exists} ->
        conn
        |> put_status(409)
        |> json(%{success: false, error: "Connection already exists for this site"})

      {:error, reason} ->
        Logger.error("Failed to register incoming connection", %{reason: inspect(reason)})

        conn
        |> put_status(500)
        |> json(%{success: false, error: "Failed to create connection"})
    end
  end

  @doc """
  Health check endpoint for DB Sync API.

  Returns whether the module is enabled and accepting connections.
  """
  def status(conn, _params) do
    config = Sync.get_config()

    conn
    |> put_status(200)
    |> json(%{
      enabled: config.enabled,
      incoming_mode: config.incoming_mode,
      password_required: config.incoming_mode == "require_password"
    })
  end

  @doc """
  Deletes a connection when requested by the remote site.

  Called when a receiver deletes their connection - the sender should also delete.

  Expected JSON body:
  - `sender_url` (required) - URL of the site sending this request
  - `auth_token_hash` (required) - The auth token hash to identify the connection

  ## Responses

  - 200 OK - Connection deleted successfully
  - 404 Not Found - Connection not found
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def delete_connection(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_delete_params(params),
         {:ok, connection} <-
           find_connection_by_hash(validated.sender_url, validated.auth_token_hash),
         {:ok, _deleted} <- Connections.delete_connection(connection) do
      Logger.info("Connection deleted via API", %{
        sender_url: validated.sender_url,
        connection_id: connection.id
      })

      conn
      |> put_status(200)
      |> json(%{success: true, message: "Connection deleted"})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{success: false, error: "Connection not found"})

      {:error, reason} ->
        Logger.error("Failed to delete connection via API", %{reason: inspect(reason)})

        conn
        |> put_status(500)
        |> json(%{success: false, error: "Failed to delete connection"})
    end
  end

  @doc """
  Updates the status of a connection when notified by the sender.

  Called when the sender suspends, reactivates, or revokes their connection.
  The receiver should mirror the status change.

  Expected JSON body:
  - `sender_url` (required) - URL of the site sending this request
  - `auth_token_hash` (required) - The auth token hash to identify the connection
  - `status` (required) - The new status ("active", "suspended", "revoked")

  ## Responses

  - 200 OK - Status updated successfully
  - 404 Not Found - Connection not found
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def update_status(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_status_params(params),
         {:ok, connection} <-
           find_connection_by_hash(validated.sender_url, validated.auth_token_hash),
         {:ok, updated} <- update_connection_status(connection, validated.status) do
      Logger.info("Connection status updated via API", %{
        sender_url: validated.sender_url,
        connection_id: connection.id,
        new_status: validated.status
      })

      # Broadcast to any listening LiveViews to refresh
      pubsub = PhoenixKit.Config.pubsub_server()

      if pubsub do
        Phoenix.PubSub.broadcast(
          pubsub,
          "sync:connections",
          {:connection_status_changed, connection.id, validated.status}
        )
      end

      conn
      |> put_status(200)
      |> json(%{success: true, message: "Status updated to #{updated.status}"})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :invalid_status} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Invalid status value"})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{success: false, error: "Connection not found"})

      {:error, reason} ->
        Logger.error("Failed to update connection status via API", %{reason: inspect(reason)})

        conn
        |> put_status(500)
        |> json(%{success: false, error: "Failed to update status"})
    end
  end

  @doc """
  Verifies a connection still exists.

  Called by sender to check if receiver still has the connection.
  Used for self-healing when the receiver was offline during delete.

  Expected JSON body:
  - `sender_url` (required) - URL of the site sending this request
  - `auth_token_hash` (required) - The auth token hash to identify the connection

  ## Responses

  - 200 OK - Connection exists
  - 404 Not Found - Connection not found (deleted)
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def verify_connection(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_delete_params(params),
         {:ok, _connection} <-
           find_connection_by_hash(validated.sender_url, validated.auth_token_hash) do
      conn
      |> put_status(200)
      |> json(%{success: true, exists: true})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{success: false, exists: false})
    end
  end

  @doc """
  Returns the current status of a connection.

  Called by receiver to get the sender's current connection status.
  This allows receivers to sync their status with the sender.

  Expected JSON body:
  - `receiver_url` (required) - URL of the receiver site requesting status
  - `auth_token_hash` (required) - The auth token hash to identify the connection

  ## Responses

  - 200 OK - Returns connection status
  - 404 Not Found - Connection not found
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def get_connection_status(conn, params) do
    Logger.info("Sync API: get_connection_status called with params: #{inspect(params)}")

    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_get_status_params(params),
         {:ok, connection} <-
           find_sender_connection(validated.receiver_url, validated.auth_token_hash) do
      # If connection is pending, activate it since receiver is now querying
      # This confirms the connection is working
      {updated_connection, status} =
        if connection.status == "pending" do
          case Connections.update_connection(connection, %{status: "active"}) do
            {:ok, updated} ->
              # Broadcast to refresh sender's LiveView
              pubsub = PhoenixKit.Config.pubsub_server()

              if pubsub do
                Phoenix.PubSub.broadcast(
                  pubsub,
                  "sync:connections",
                  {:connection_status_changed, connection.id, "active"}
                )
              end

              {updated, "active"}

            {:error, _} ->
              {connection, connection.status}
          end
        else
          {connection, connection.status}
        end

      Logger.info(
        "Sync API: Found sender connection #{updated_connection.id} with status '#{status}'"
      )

      conn
      |> put_status(200)
      |> json(%{
        success: true,
        status: status,
        name: updated_connection.name
      })
    else
      {:error, :module_disabled} ->
        Logger.warning("Sync API: get_connection_status - module disabled")

        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        Logger.warning("Sync API: get_connection_status - missing fields: #{inspect(fields)}")

        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        Logger.warning(
          "Sync API: get_connection_status - connection not found for hash: #{params["auth_token_hash"]}"
        )

        conn
        |> put_status(404)
        |> json(%{success: false, error: "Connection not found"})
    end
  end

  @doc """
  Lists available tables for sync.

  Called by receiver to get a list of tables that can be synced from this sender.

  Expected JSON body:
  - `auth_token_hash` (required) - The auth token hash to identify the connection

  ## Responses

  - 200 OK - Returns list of tables with row counts and sizes
  - 401 Unauthorized - Invalid auth token
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def list_tables(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_list_tables_params(params),
         {:ok, connection} <- find_sender_by_hash(validated.auth_token_hash),
         :ok <- check_connection_active(connection) do
      tables = get_syncable_tables()

      # Update last_connected_at
      Connections.update_connection(connection, %{last_connected_at: DateTime.utc_now()})

      conn
      |> put_status(200)
      |> json(%{success: true, tables: tables})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Invalid connection"})

      {:error, :connection_not_active} ->
        conn
        |> put_status(403)
        |> json(%{success: false, error: "Connection is not active"})
    end
  end

  @doc """
  Pulls data for a specific table.

  Called by receiver to fetch table data during sync.

  Expected JSON body:
  - `auth_token_hash` (required) - The auth token hash to identify the connection
  - `table_name` (required) - Name of the table to pull
  - `conflict_strategy` (optional) - How to handle conflicts (skip, overwrite, merge)

  ## Responses

  - 200 OK - Returns table data
  - 401 Unauthorized - Invalid auth token
  - 404 Not Found - Table not found
  - 503 Service Unavailable - DB Sync module is disabled
  """
  def pull_data(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_pull_data_params(params),
         {:ok, connection} <- find_sender_by_hash(validated.auth_token_hash),
         :ok <- check_connection_active(connection),
         {:ok, data} <- fetch_table_data(validated.table_name, connection) do
      # Update connection stats
      record_count = length(data)

      Connections.update_connection(connection, %{
        last_transfer_at: DateTime.utc_now(),
        downloads_used: (connection.downloads_used || 0) + 1,
        records_downloaded: (connection.records_downloaded || 0) + record_count,
        total_transfers: (connection.total_transfers || 0) + 1,
        total_records_transferred: (connection.total_records_transferred || 0) + record_count
      })

      # Record the transfer in history (sender side)
      Transfers.create_transfer(%{
        direction: "send",
        connection_id: connection.id,
        table_name: validated.table_name,
        remote_site_url: connection.site_url,
        conflict_strategy: validated.conflict_strategy,
        status: "completed",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        records_transferred: record_count
      })

      Logger.info("Sending #{record_count} records for table #{validated.table_name}")

      conn
      |> put_status(200)
      |> json(%{success: true, table: validated.table_name, data: data})
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields", fields: fields})

      {:error, :not_found} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Invalid connection"})

      {:error, :connection_not_active} ->
        conn
        |> put_status(403)
        |> json(%{success: false, error: "Connection is not active"})

      {:error, :table_not_found} ->
        conn
        |> put_status(404)
        |> json(%{success: false, error: "Table not found"})

      {:error, reason} ->
        Logger.error("Failed to pull data", %{reason: inspect(reason)})

        conn
        |> put_status(500)
        |> json(%{success: false, error: "Failed to pull data"})
    end
  end

  @doc """
  Returns schema for a specific table.

  Expected JSON body:
  - `auth_token_hash` - Hash of the auth token
  - `table_name` - Name of the table

  Returns:
  - 200 OK with schema data
  - 401 Unauthorized
  - 404 Not Found
  """
  def table_schema(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_schema_params(params),
         {:ok, connection} <- find_sender_by_hash(validated.auth_token_hash),
         :ok <- check_connection_active(connection) do
      table_name = validated.table_name

      # Check if table is in syncable list
      case get_table_schema(table_name) do
        {:ok, schema} ->
          conn
          |> put_status(200)
          |> json(%{success: true, schema: schema})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{success: false, error: "Table not found"})
      end
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :not_found} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Invalid connection"})

      {:error, :connection_not_active} ->
        conn
        |> put_status(403)
        |> json(%{success: false, error: "Connection is not active"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields: #{Enum.join(fields, ", ")}"})
    end
  end

  @doc """
  Returns records from a specific table for preview.

  Expected JSON body:
  - `auth_token_hash` - Hash of the auth token
  - `table_name` - Name of the table
  - `limit` - Maximum number of records (default: 10)
  - `offset` - Offset for pagination (default: 0)
  - `ids` (optional) - List of specific IDs to fetch
  - `id_start`, `id_end` (optional) - ID range filter

  Returns:
  - 200 OK with records
  - 401 Unauthorized
  - 404 Not Found
  """
  def table_records(conn, params) do
    with :ok <- check_module_enabled(),
         {:ok, validated} <- validate_records_params(params),
         {:ok, connection} <- find_sender_by_hash(validated.auth_token_hash),
         :ok <- check_connection_active(connection) do
      table_name = validated.table_name
      limit = min(validated.limit, 100)
      offset = validated.offset

      # Build filter options
      filter_opts =
        []
        |> maybe_add_filter(:ids, validated[:ids])
        |> maybe_add_filter(:id_start, validated[:id_start])
        |> maybe_add_filter(:id_end, validated[:id_end])

      case get_table_records(table_name, limit, offset, filter_opts) do
        {:ok, records} ->
          conn
          |> put_status(200)
          |> json(%{success: true, records: records})

        {:error, :not_found} ->
          conn
          |> put_status(404)
          |> json(%{success: false, error: "Table not found"})

        {:error, reason} ->
          conn
          |> put_status(500)
          |> json(%{success: false, error: "Failed to get records: #{inspect(reason)}"})
      end
    else
      {:error, :module_disabled} ->
        conn
        |> put_status(503)
        |> json(%{success: false, error: "DB Sync module is disabled"})

      {:error, :not_found} ->
        conn
        |> put_status(401)
        |> json(%{success: false, error: "Invalid connection"})

      {:error, :connection_not_active} ->
        conn
        |> put_status(403)
        |> json(%{success: false, error: "Connection is not active"})

      {:error, :missing_fields, fields} ->
        conn
        |> put_status(400)
        |> json(%{success: false, error: "Missing required fields: #{Enum.join(fields, ", ")}"})
    end
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: [{key, value} | opts]

  # --- Private Functions ---

  defp check_module_enabled do
    if Sync.enabled?() do
      :ok
    else
      {:error, :module_disabled}
    end
  end

  defp check_incoming_allowed do
    case Sync.get_incoming_mode() do
      "deny_all" -> {:error, :incoming_denied}
      _ -> :ok
    end
  end

  defp validate_params(params) do
    required_fields = ["sender_url", "connection_name", "auth_token"]
    missing = Enum.filter(required_fields, &(is_nil(params[&1]) or params[&1] == ""))

    if Enum.empty?(missing) do
      {:ok,
       %{
         sender_url: params["sender_url"],
         connection_name: params["connection_name"],
         auth_token: params["auth_token"]
       }}
    else
      {:error, :missing_fields, missing}
    end
  end

  defp validate_delete_params(params) do
    required_fields = ["sender_url", "auth_token_hash"]
    missing = Enum.filter(required_fields, &(is_nil(params[&1]) or params[&1] == ""))

    if Enum.empty?(missing) do
      {:ok,
       %{
         sender_url: params["sender_url"],
         auth_token_hash: params["auth_token_hash"]
       }}
    else
      {:error, :missing_fields, missing}
    end
  end

  defp find_connection_by_hash(sender_url, auth_token_hash) do
    case Connections.find_by_site_url_and_hash(sender_url, auth_token_hash) do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
  end

  defp validate_get_status_params(params) do
    required_fields = ["receiver_url", "auth_token_hash"]
    missing = Enum.filter(required_fields, &(is_nil(params[&1]) or params[&1] == ""))

    if Enum.empty?(missing) do
      {:ok,
       %{
         receiver_url: params["receiver_url"],
         auth_token_hash: params["auth_token_hash"]
       }}
    else
      {:error, :missing_fields, missing}
    end
  end

  # Find a sender connection by token hash
  # The receiver is asking "what's the status of my connection to you?"
  # We look for our sender connection with matching hash (ignores receiver_url since it may be unreliable)
  defp find_sender_connection(_receiver_url, auth_token_hash) do
    # We're the sender, look for our sender connection with this hash
    case Connections.find_by_hash_and_direction(auth_token_hash, "sender") do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
  end

  defp validate_status_params(params) do
    required_fields = ["sender_url", "auth_token_hash", "status"]
    missing = Enum.filter(required_fields, &(is_nil(params[&1]) or params[&1] == ""))

    cond do
      not Enum.empty?(missing) ->
        {:error, :missing_fields, missing}

      params["status"] not in ["active", "suspended", "revoked"] ->
        {:error, :invalid_status}

      true ->
        {:ok,
         %{
           sender_url: params["sender_url"],
           auth_token_hash: params["auth_token_hash"],
           status: params["status"]
         }}
    end
  end

  defp update_connection_status(connection, new_status) do
    Connections.update_connection(connection, %{status: new_status})
  end

  defp validate_password(provided_password) do
    case Sync.get_incoming_mode() do
      "require_password" ->
        stored_password = Sync.get_incoming_password()

        cond do
          is_nil(stored_password) or stored_password == "" ->
            # No password set but mode requires it - accept for now
            :ok

          is_nil(provided_password) or provided_password == "" ->
            {:error, :password_required}

          provided_password == stored_password ->
            :ok

          true ->
            {:error, :invalid_password}
        end

      _ ->
        :ok
    end
  end

  defp create_incoming_connection(params, conn) do
    # Check if connection already exists from this sender
    existing = Connections.find_by_site_url(params.sender_url, "receiver")

    if existing do
      {:error, :connection_exists}
    else
      do_create_incoming_connection(params, conn)
    end
  end

  defp do_create_incoming_connection(params, conn) do
    # If we get here, the connection was approved (passed mode/password checks)
    # So it should be active - the sender already approved by creating their connection
    initial_status = "active"

    # Build connection attributes (use string keys to match form params)
    attrs = %{
      "name" => "From: #{params.connection_name}",
      "direction" => "receiver",
      "site_url" => params.sender_url,
      "auth_token" => params.auth_token,
      "status" => initial_status,
      "approval_mode" => "auto_approve",
      "metadata" => %{
        "registered_via" => "api",
        "registered_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "remote_ip" => get_remote_ip(conn),
        "user_agent" => get_user_agent(conn)
      }
    }

    case Connections.create_connection(attrs) do
      {:ok, connection, _token} ->
        # Broadcast to any listening LiveViews to refresh
        pubsub = PhoenixKit.Config.pubsub_server()

        if pubsub do
          Phoenix.PubSub.broadcast(
            pubsub,
            "sync:connections",
            {:connection_created, connection.id}
          )
        end

        {:ok,
         %{
           status: initial_status,
           message: "Connection registered and activated",
           connection_id: connection.id
         }}

      {:error, changeset} ->
        {:error, {:changeset_error, changeset}}
    end
  end

  defp get_remote_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded_ips] ->
        forwarded_ips
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua] -> ua
      [] -> "unknown"
    end
  end

  defp validate_list_tables_params(params) do
    required_fields = ["auth_token_hash"]
    missing = Enum.filter(required_fields, &(is_nil(params[&1]) or params[&1] == ""))

    if Enum.empty?(missing) do
      {:ok, %{auth_token_hash: params["auth_token_hash"]}}
    else
      {:error, :missing_fields, missing}
    end
  end

  defp validate_pull_data_params(params) do
    required_fields = ["auth_token_hash", "table_name"]
    missing = Enum.filter(required_fields, &(is_nil(params[&1]) or params[&1] == ""))

    if Enum.empty?(missing) do
      {:ok,
       %{
         auth_token_hash: params["auth_token_hash"],
         table_name: params["table_name"],
         conflict_strategy: params["conflict_strategy"] || "skip"
       }}
    else
      {:error, :missing_fields, missing}
    end
  end

  defp find_sender_by_hash(auth_token_hash) do
    case Connections.find_by_hash_and_direction(auth_token_hash, "sender") do
      nil -> {:error, :not_found}
      connection -> {:ok, connection}
    end
  end

  defp check_connection_active(connection) do
    if connection.status == "active" do
      :ok
    else
      {:error, :connection_not_active}
    end
  end

  defp get_syncable_tables do
    repo = PhoenixKit.RepoHelper.repo()

    # Get list of tables from the database
    # Filter to only include PhoenixKit tables that are allowed for sync
    tables_query = """
    SELECT
      t.table_name as name,
      pg_total_relation_size(c.oid) as size_bytes
    FROM information_schema.tables t
    JOIN pg_class c ON c.relname = t.table_name
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
      AND t.table_name NOT LIKE 'schema_%'
      AND t.table_name NOT LIKE 'pg_%'
    ORDER BY t.table_name
    """

    case SQL.query(repo, tables_query, []) do
      {:ok, %{rows: rows}} ->
        # Get actual row counts for each table
        Enum.map(rows, fn [name, size_bytes] ->
          row_count = get_actual_row_count(repo, name)
          %{"name" => name, "row_count" => row_count, "size_bytes" => size_bytes}
        end)

      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  defp get_actual_row_count(repo, table_name) do
    # Validate table name to prevent SQL injection
    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, table_name) do
      count_query = "SELECT COUNT(*) FROM #{table_name}"

      case SQL.query(repo, count_query, []) do
        {:ok, %{rows: [[count]]}} -> count
        _ -> 0
      end
    else
      0
    end
  rescue
    _ -> 0
  end

  defp fetch_table_data(table_name, connection) do
    if valid_table_name?(table_name) do
      do_fetch_table_data(table_name, connection)
    else
      {:error, :table_not_found}
    end
  rescue
    e ->
      Logger.error("Failed to fetch table data: #{Exception.message(e)}")
      {:error, :fetch_failed}
  end

  defp do_fetch_table_data(table_name, connection) do
    repo = PhoenixKit.RepoHelper.repo()

    case table_exists?(repo, table_name) do
      {:ok, true} ->
        fetch_table_rows(repo, table_name, connection.max_records_per_request || 10_000)

      {:ok, false} ->
        {:error, :table_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_table_name?(table_name) do
    Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, table_name)
  end

  defp table_exists?(repo, table_name) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_schema = 'public'
        AND table_name = $1
    )
    """

    case SQL.query(repo, query, [table_name]) do
      {:ok, %{rows: [[exists]]}} -> {:ok, exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_table_rows(repo, table_name, limit) do
    query = "SELECT * FROM #{table_name} LIMIT $1"

    case SQL.query(repo, query, [limit]) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, rows_to_maps(rows, columns)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rows_to_maps(rows, columns) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {col, val} -> {col, serialize_value(val)} end)
    end)
  end

  # Serialize values for JSON transport
  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp serialize_value(%Date{} = d), do: Date.to_iso8601(d)
  defp serialize_value(%Time{} = t), do: Time.to_iso8601(t)
  defp serialize_value(%Decimal{} = d), do: Decimal.to_string(d)
  defp serialize_value(binary) when is_binary(binary), do: binary
  defp serialize_value(val), do: val

  defp validate_schema_params(params) do
    required_fields = ["auth_token_hash", "table_name"]
    missing = Enum.filter(required_fields, &(is_nil(params[&1]) or params[&1] == ""))

    if Enum.empty?(missing) do
      {:ok,
       %{
         auth_token_hash: params["auth_token_hash"],
         table_name: params["table_name"]
       }}
    else
      {:error, :missing_fields, missing}
    end
  end

  defp validate_records_params(params) do
    required_fields = ["auth_token_hash", "table_name"]
    missing = Enum.filter(required_fields, &(is_nil(params[&1]) or params[&1] == ""))

    if Enum.empty?(missing) do
      {:ok,
       %{
         auth_token_hash: params["auth_token_hash"],
         table_name: params["table_name"],
         limit: parse_int(params["limit"], 10),
         offset: parse_int(params["offset"], 0),
         ids: params["ids"],
         id_start: params["id_start"],
         id_end: params["id_end"]
       }}
    else
      {:error, :missing_fields, missing}
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, _default) when is_integer(val), do: val

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp get_table_schema(table_name) do
    if valid_table_name?(table_name) do
      do_get_table_schema(table_name)
    else
      {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp do_get_table_schema(table_name) do
    repo = PhoenixKit.RepoHelper.repo()

    query = """
    SELECT
      column_name,
      data_type,
      is_nullable,
      column_default,
      character_maximum_length
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = $1
    ORDER BY ordinal_position
    """

    case SQL.query(repo, query, [table_name]) do
      {:ok, %{rows: [], columns: _columns}} ->
        {:error, :not_found}

      {:ok, %{rows: rows, columns: columns}} ->
        schema_columns = Enum.map(rows, fn row -> Enum.zip(columns, row) |> Map.new() end)
        {:ok, %{table_name: table_name, columns: schema_columns}}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  defp get_table_records(table_name, limit, offset, filter_opts) do
    if valid_table_name?(table_name) do
      do_get_table_records(table_name, limit, offset, filter_opts)
    else
      {:error, :not_found}
    end
  rescue
    e ->
      Logger.error("Failed to fetch table records: #{Exception.message(e)}")
      {:error, :fetch_failed}
  end

  defp do_get_table_records(table_name, limit, offset, filter_opts) do
    repo = PhoenixKit.RepoHelper.repo()

    case table_exists?(repo, table_name) do
      {:ok, true} ->
        fetch_filtered_records(repo, table_name, limit, offset, filter_opts)

      {:ok, false} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_filtered_records(repo, table_name, limit, offset, filter_opts) do
    {where_clause, params, next_param} = build_where_clause(filter_opts)

    data_query =
      "SELECT * FROM #{table_name}#{where_clause} ORDER BY id LIMIT $#{next_param} OFFSET $#{next_param + 1}"

    all_params = params ++ [limit, offset]

    case SQL.query(repo, data_query, all_params) do
      {:ok, %{rows: rows, columns: columns}} ->
        {:ok, serialize_rows(rows, columns)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp serialize_rows(rows, columns) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Enum.map(fn {col, val} -> {col, serialize_value(val)} end)
      |> Map.new()
    end)
  end

  defp build_where_clause(opts) do
    ids = Keyword.get(opts, :ids)
    id_start = Keyword.get(opts, :id_start)
    id_end = Keyword.get(opts, :id_end)

    cond do
      is_list(ids) and ids != [] ->
        {" WHERE id = ANY($1)", [ids], 2}

      not is_nil(id_start) and not is_nil(id_end) ->
        {" WHERE id >= $1 AND id <= $2", [id_start, id_end], 3}

      not is_nil(id_start) ->
        {" WHERE id >= $1", [id_start], 2}

      not is_nil(id_end) ->
        {" WHERE id <= $1", [id_end], 2}

      true ->
        {"", [], 1}
    end
  end
end
