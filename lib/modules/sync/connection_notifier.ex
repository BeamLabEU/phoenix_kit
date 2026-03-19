defmodule PhoenixKit.Modules.Sync.ConnectionNotifier do
  @moduledoc """
  Handles cross-site notification when creating sender connections.

  When a sender connection is created, this module notifies the remote site
  so they can automatically register the incoming connection on their end.

  ## How It Works

  1. When you create a sender connection pointing to a remote site (e.g., "https://remote.com")
  2. This module calls `POST https://remote.com/{prefix}/db-sync/api/register-connection`
  3. The remote site creates a receiver connection automatically
  4. The result is recorded in the connection's metadata

  ## Remote Site Responses

  - 200 OK - Connection registered successfully
  - 401 Unauthorized - Password required or invalid
  - 403 Forbidden - Incoming connections denied
  - 409 Conflict - Connection already exists
  - 503 Service Unavailable - DB Sync module disabled

  ## Usage

  Usually called automatically when creating connections via the LiveView UI.
  Can also be called manually:

      {:ok, result} = ConnectionNotifier.notify_remote_site(connection, token, password: "optional")
  """

  require Logger

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Sync.Connections
  alias PhoenixKit.Modules.Sync.SchemaInspector
  alias PhoenixKit.Modules.Sync.Transfers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @default_timeout 30_000
  @connect_timeout 10_000

  @type notify_result :: %{
          success: boolean(),
          status: :registered | :pending | :failed | :skipped,
          message: String.t(),
          remote_connection_uuid: String.t() | nil,
          http_status: integer() | nil,
          error: String.t() | nil
        }

  @doc """
  Notifies a remote site about a new sender connection.

  ## Parameters

  - `connection` - The sender connection that was just created
  - `raw_token` - The raw auth token (only available at creation time)
  - `opts` - Options:
    - `:password` - Password to provide to remote site (if required)
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, result}` - Notification sent, result contains details
  - `{:error, reason}` - Failed to send notification
  """
  @spec notify_remote_site(map(), String.t(), keyword()) ::
          {:ok, notify_result()} | {:error, any()}
  def notify_remote_site(connection, raw_token, opts \\ []) do
    # Only notify for sender connections
    direction = Map.get(connection, :direction) || Map.get(connection, "direction")

    if direction != "sender" do
      {:ok,
       %{
         success: true,
         status: :skipped,
         message: "Notification skipped for receiver connections",
         remote_connection_uuid: nil,
         http_status: nil,
         error: nil
       }}
    else
      do_notify_remote_site(connection, raw_token, opts)
    end
  end

  defp do_notify_remote_site(connection, raw_token, opts) do
    password = Keyword.get(opts, :password)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Get connection fields (support both atom and string keys)
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")
    conn_name = Map.get(connection, :name) || Map.get(connection, "name")
    conn_uuid = Map.get(connection, :uuid) || Map.get(connection, "uuid")

    # Build the API URL
    api_url = build_api_url(site_url)

    # Resolve our URL for the request body
    our_url = get_our_site_url()

    # Build request body
    body = build_request_body(conn_name, our_url, raw_token, password)

    Logger.info(
      "[Sync.Notifier] Creating outgoing connection " <>
        "| connection_uuid=#{conn_uuid} " <>
        "| name=#{inspect(conn_name)} " <>
        "| remote_url=#{site_url} " <>
        "| api_url=#{api_url} " <>
        "| our_url=#{our_url} " <>
        "| has_password=#{password != nil} " <>
        "| timeout=#{timeout}ms"
    )

    case make_http_request(api_url, body, timeout) do
      {:ok, response} ->
        result = parse_response(response)

        Logger.info(
          "[Sync.Notifier] Remote site responded " <>
            "| connection_uuid=#{conn_uuid} " <>
            "| http_status=#{response.status} " <>
            "| success=#{result.success} " <>
            "| result_status=#{result.status} " <>
            "| remote_connection_uuid=#{result.remote_connection_uuid} " <>
            "| message=#{inspect(result.message)}"
        )

        update_connection_metadata(connection, result)
        {:ok, result}

      {:error, reason} ->
        Logger.error(
          "[Sync.Notifier] Failed to contact remote site " <>
            "| connection_uuid=#{conn_uuid} " <>
            "| remote_url=#{site_url} " <>
            "| api_url=#{api_url} " <>
            "| error=#{inspect(reason)}"
        )

        result = %{
          success: false,
          status: :failed,
          message: "Failed to contact remote site",
          remote_connection_uuid: nil,
          http_status: nil,
          error: format_error(reason)
        }

        update_connection_metadata(connection, result)
        {:ok, result}
    end
  end

  @doc """
  Checks the status of a remote site's DB Sync API.

  ## Parameters

  - `site_url` - The remote site's base URL

  ## Returns

  - `{:ok, status}` - Remote site status
  - `{:error, reason}` - Failed to contact site
  """
  @spec check_remote_status(String.t()) :: {:ok, map()} | {:error, any()}
  def check_remote_status(site_url) do
    status_url = build_status_url(site_url)

    case make_get_request(status_url, @default_timeout) do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Notifies a remote site to delete a connection.

  Called when a receiver deletes their connection - notifies the sender to also delete.

  ## Parameters

  - `connection` - The connection being deleted (must have site_url and auth_token_hash)
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, :deleted}` - Remote site deleted the connection
  - `{:ok, :not_found}` - Connection didn't exist on remote (already deleted)
  - `{:ok, :offline}` - Remote site is offline (will self-heal later)
  - `{:error, reason}` - Failed to notify
  """
  def notify_delete(connection, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")

    auth_token_hash =
      Map.get(connection, :auth_token_hash) || Map.get(connection, "auth_token_hash")

    if is_nil(site_url) or is_nil(auth_token_hash) do
      {:error, :missing_connection_info}
    else
      api_url = build_delete_url(site_url)
      our_url = get_our_site_url()

      body = %{
        "sender_url" => our_url,
        "auth_token_hash" => auth_token_hash
      }

      Logger.info("Sync: Notifying remote site to delete connection", %{
        remote_url: site_url,
        api_url: api_url
      })

      case make_http_request(api_url, body, timeout) do
        {:ok, %{status: status}} when status in [200, 204] ->
          Logger.info("Sync: Remote site deleted connection successfully")
          {:ok, :deleted}

        {:ok, %{status: 404}} ->
          Logger.info("Sync: Connection not found on remote site (already deleted)")
          {:ok, :not_found}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("Sync: Remote site returned unexpected status #{status}: #{resp_body}")
          {:error, {:unexpected_status, status}}

        {:error, %{reason: reason}} when reason in [:econnrefused, :timeout, :nxdomain] ->
          Logger.info("Sync: Remote site offline, connection will self-heal")
          {:ok, :offline}

        {:error, reason} ->
          Logger.error("Sync: Failed to notify delete: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Notifies a remote site of a status change (suspend, reactivate, revoke).

  Called when a sender changes their connection status - the receiver should mirror it.

  ## Parameters

  - `connection` - The connection with updated status
  - `new_status` - The new status ("active", "suspended", "revoked")
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, :updated}` - Remote site updated the status
  - `{:ok, :not_found}` - Connection not found on remote
  - `{:ok, :offline}` - Remote site is offline
  - `{:error, reason}` - Failed to notify
  """
  def notify_status_change(connection, new_status, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")

    auth_token_hash =
      Map.get(connection, :auth_token_hash) || Map.get(connection, "auth_token_hash")

    if is_nil(site_url) or is_nil(auth_token_hash) do
      {:error, :missing_connection_info}
    else
      api_url = build_status_change_url(site_url)
      our_url = get_our_site_url()

      body = %{
        "sender_url" => our_url,
        "auth_token_hash" => auth_token_hash,
        "status" => new_status
      }

      Logger.info("Sync: Notifying remote site of status change", %{
        remote_url: site_url,
        new_status: new_status
      })

      case make_http_request(api_url, body, timeout) do
        {:ok, %{status: status}} when status in [200, 204] ->
          Logger.info("Sync: Remote site updated status successfully")
          {:ok, :updated}

        {:ok, %{status: 404}} ->
          Logger.info("Sync: Connection not found on remote site")
          {:ok, :not_found}

        {:ok, %{status: status, body: resp_body}} ->
          Logger.warning("Sync: Remote site returned unexpected status #{status}: #{resp_body}")
          {:error, {:unexpected_status, status}}

        {:error, %{reason: reason}} when reason in [:econnrefused, :timeout, :nxdomain] ->
          Logger.info("Sync: Remote site offline")
          {:ok, :offline}

        {:error, reason} ->
          Logger.error("Sync: Failed to notify status change: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Queries the sender for the current connection status.

  Called by receiver to sync their status with the sender's status.

  ## Parameters

  - `connection` - The receiver connection (must have site_url and auth_token_hash)
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, status}` - Current status from sender ("active", "suspended", "revoked")
  - `{:ok, :offline}` - Sender is offline
  - `{:ok, :not_found}` - Connection not found on sender
  - `{:error, reason}` - Failed to query
  """
  def query_sender_status(connection, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_query_sender_status(site_url, auth_token_hash, opts)
    end
  end

  defp do_query_sender_status(site_url, auth_token_hash, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    api_url = build_get_status_url(site_url)

    body = %{
      "receiver_url" => get_our_site_url(),
      "auth_token_hash" => auth_token_hash
    }

    Logger.debug("Sync: Querying sender for connection status", %{sender_url: site_url})

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_status_response(resp_body)

      {:ok, %{status: 404}} ->
        {:ok, :not_found}

      result ->
        handle_standard_http_result(result)
    end
  end

  defp parse_status_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "status" => status}} -> {:ok, status}
      {:ok, %{"success" => false}} -> {:ok, :not_found}
      _ -> {:error, :invalid_response}
    end
  end

  @doc """
  Verifies a connection still exists on the remote site.

  Called by sender to check if receiver still has the connection.
  If not, the sender should delete their own connection.

  ## Returns

  - `{:ok, :exists}` - Connection exists on remote
  - `{:ok, :not_found}` - Connection was deleted on remote
  - `{:ok, :offline}` - Remote site is offline
  - `{:error, reason}` - Failed to verify
  """
  def verify_connection(connection, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")

    auth_token_hash =
      Map.get(connection, :auth_token_hash) || Map.get(connection, "auth_token_hash")

    if is_nil(site_url) or is_nil(auth_token_hash) do
      {:error, :missing_connection_info}
    else
      api_url = build_verify_url(site_url)
      our_url = get_our_site_url()

      body = %{
        "sender_url" => our_url,
        "auth_token_hash" => auth_token_hash
      }

      case make_http_request(api_url, body, timeout) do
        {:ok, %{status: 200}} ->
          {:ok, :exists}

        {:ok, %{status: 404}} ->
          {:ok, :not_found}

        {:ok, %{status: _status}} ->
          # Assume exists if we get any other response
          {:ok, :exists}

        {:error, %{reason: reason}} when reason in [:econnrefused, :timeout, :nxdomain] ->
          {:ok, :offline}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Fetches the list of available tables from the sender.

  Called by receiver to get a list of tables that can be synced.

  ## Parameters

  - `connection` - The receiver connection (must have site_url and auth_token/auth_token_hash)
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 30_000ms)

  ## Returns

  - `{:ok, tables}` - List of table info maps with :name, :row_count, :size_bytes
  - `{:error, :offline}` - Sender is offline
  - `{:error, reason}` - Failed to fetch
  """
  def fetch_sender_tables(connection, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_fetch_sender_tables(site_url, auth_token_hash, opts)
    end
  end

  defp do_fetch_sender_tables(site_url, auth_token_hash, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    api_url = build_list_tables_url(site_url)
    body = %{"auth_token_hash" => auth_token_hash}

    Logger.debug("Sync: Fetching tables from sender", %{sender_url: site_url})

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_tables_response(resp_body)

      result ->
        handle_api_http_result(result)
    end
  end

  defp parse_tables_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "tables" => tables}} ->
        {:ok, convert_tables_to_structs(tables)}

      {:ok, %{"success" => false, "error" => error}} ->
        {:error, error}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp convert_tables_to_structs(tables) do
    Enum.map(tables, fn t ->
      %{
        name: t["name"],
        row_count: t["row_count"] || 0,
        size_bytes: t["size_bytes"] || 0,
        checksum: t["checksum"],
        depends_on: t["depends_on"] || []
      }
    end)
  end

  @doc """
  Pulls data for a specific table from the sender.

  Called by receiver to fetch table data during sync.

  ## Parameters

  - `connection` - The receiver connection
  - `table_name` - Name of the table to pull
  - `opts` - Options:
    - `:timeout` - HTTP request timeout (default: 60_000ms for large data)
    - `:conflict_strategy` - How to handle existing records ("skip", "overwrite", "merge")

  ## Returns

  - `{:ok, result}` - Map with :records_imported, :records_skipped, etc.
  - `{:error, :offline}` - Sender is offline
  - `{:error, reason}` - Failed to pull
  """
  def pull_table_data(connection, table_name, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      connection_uuid = Map.get(connection, :uuid)

      do_pull_table_data(
        site_url,
        auth_token_hash,
        connection_uuid,
        table_name,
        opts
      )
    end
  end

  @doc """
  Same as pull_table_data but accepts and returns a uuid_remap for FK remapping across tables.
  Returns {:ok, import_result, updated_remap} or {:error, reason, unchanged_remap}.
  """
  def pull_table_data_with_remap(connection, table_name, uuid_remap, opts \\ []) do
    case extract_connection_info(connection) do
      {:ok, site_url, auth_token_hash} ->
        connection_uuid = Map.get(connection, :uuid)

        do_pull_table_data_with_remap(
          site_url,
          auth_token_hash,
          connection_uuid,
          table_name,
          uuid_remap,
          opts
        )

      {:error, reason} ->
        {:error, reason, uuid_remap}
    end
  end

  defp do_pull_table_data(
         site_url,
         auth_token_hash,
         connection_uuid,
         table_name,
         opts
       ) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    conflict_strategy = Keyword.get(opts, :conflict_strategy, "skip")

    Logger.info("Sync: Pulling data for table #{table_name}", %{sender_url: site_url})

    {:ok, transfer} =
      create_pull_transfer(
        connection_uuid,
        table_name,
        site_url,
        conflict_strategy
      )

    api_url = build_pull_data_url(site_url)

    body = %{
      "auth_token_hash" => auth_token_hash,
      "table_name" => table_name,
      "conflict_strategy" => conflict_strategy
    }

    result = make_http_request(api_url, body, timeout)
    handle_pull_response(result, transfer, table_name, conflict_strategy)
  end

  defp do_pull_table_data_with_remap(
         site_url,
         auth_token_hash,
         connection_uuid,
         table_name,
         uuid_remap,
         opts
       ) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    conflict_strategy = Keyword.get(opts, :conflict_strategy, "skip")

    Logger.info("Sync: Pulling data for table #{table_name}", %{sender_url: site_url})

    {:ok, transfer} =
      create_pull_transfer(
        connection_uuid,
        table_name,
        site_url,
        conflict_strategy
      )

    api_url = build_pull_data_url(site_url)

    body = %{
      "auth_token_hash" => auth_token_hash,
      "table_name" => table_name,
      "conflict_strategy" => conflict_strategy
    }

    result = make_http_request(api_url, body, timeout)
    handle_pull_response_with_remap(result, transfer, table_name, conflict_strategy, uuid_remap)
  end

  defp create_pull_transfer(
         connection_uuid,
         table_name,
         site_url,
         conflict_strategy
       ) do
    Transfers.create_transfer(%{
      direction: "receive",
      connection_uuid: connection_uuid,
      table_name: table_name,
      remote_site_url: site_url,
      conflict_strategy: conflict_strategy,
      status: "in_progress",
      started_at: UtilsDate.utc_now()
    })
  end

  defp handle_pull_response(
         {:ok, %{status: 200, body: resp_body}},
         transfer,
         table_name,
         strategy
       ) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "data" => data}} ->
        complete_pull_transfer(transfer, table_name, data, strategy)

      {:ok, %{"success" => false, "error" => error}} ->
        Logger.error("Sync: Pull failed - remote error: #{error}")
        Transfers.fail_transfer(transfer, error)
        {:error, error}

      other ->
        Logger.error("Sync: Pull failed - invalid response format: #{inspect(other)}")
        Transfers.fail_transfer(transfer, "Invalid response from remote site")
        {:error, :invalid_response}
    end
  end

  defp handle_pull_response({:ok, %{status: 401}}, transfer, _table_name, _strategy) do
    Logger.error("Sync: Pull failed - unauthorized (401)")
    Transfers.fail_transfer(transfer, "Unauthorized")
    {:error, :unauthorized}
  end

  defp handle_pull_response({:ok, %{status: 404}}, transfer, _table_name, _strategy) do
    Logger.error("Sync: Pull failed - table not found (404)")
    Transfers.fail_transfer(transfer, "Table not found")
    {:error, :table_not_found}
  end

  defp handle_pull_response({:ok, %{status: status}}, transfer, _table_name, _strategy) do
    Logger.error("Sync: Pull failed - HTTP error #{status}")
    Transfers.fail_transfer(transfer, "HTTP error #{status}")
    {:error, :unexpected_response}
  end

  defp handle_pull_response({:error, %{reason: reason}}, transfer, _table_name, _strategy)
       when reason in [:econnrefused, :timeout, :nxdomain] do
    Logger.error("Sync: Pull failed - sender offline (#{reason})")
    Transfers.fail_transfer(transfer, "Sender offline")
    {:error, :offline}
  end

  defp handle_pull_response({:error, reason}, transfer, _table_name, _strategy) do
    Logger.error("Sync: Pull failed - #{inspect(reason)}")
    Transfers.fail_transfer(transfer, inspect(reason))
    {:error, reason}
  end

  # Remap-aware versions that thread uuid_remap through
  defp handle_pull_response_with_remap(
         {:ok, %{status: 200, body: resp_body}},
         transfer,
         table_name,
         strategy,
         uuid_remap
       ) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "data" => data}} ->
        complete_pull_transfer_with_remap(transfer, table_name, data, strategy, uuid_remap)

      {:ok, %{"success" => false, "error" => error}} ->
        Logger.error("Sync: Pull failed - remote error: #{error}")
        Transfers.fail_transfer(transfer, error)
        {:error, error, uuid_remap}

      other ->
        Logger.error("Sync: Pull failed - invalid response format: #{inspect(other)}")
        Transfers.fail_transfer(transfer, "Invalid response from remote site")
        {:error, :invalid_response, uuid_remap}
    end
  end

  defp handle_pull_response_with_remap(result, transfer, table_name, strategy, uuid_remap) do
    case handle_pull_response(result, transfer, table_name, strategy) do
      {:ok, import_result} -> {:ok, import_result, uuid_remap}
      {:error, reason} -> {:error, reason, uuid_remap}
    end
  end

  defp complete_pull_transfer(transfer, table_name, data, conflict_strategy) do
    import_result = import_table_data(table_name, data, conflict_strategy)

    Transfers.complete_transfer(transfer, %{
      records_transferred: length(data),
      records_created: import_result.imported,
      records_skipped: import_result.skipped,
      records_failed: import_result.errors
    })

    {:ok, import_result}
  end

  defp complete_pull_transfer_with_remap(
         transfer,
         table_name,
         data,
         conflict_strategy,
         uuid_remap
       ) do
    {import_result, updated_remap} =
      import_table_data_with_remap(table_name, data, conflict_strategy, uuid_remap)

    Transfers.complete_transfer(transfer, %{
      records_transferred: length(data),
      records_created: import_result.imported,
      records_skipped: import_result.skipped,
      records_failed: import_result.errors
    })

    {:ok, import_result, updated_remap}
  end

  @doc """
  Fetch table schema from a sender site via HTTP API.

  Returns:
  - `{:ok, schema}` - Map with :columns list
  - `{:error, :offline}` - Sender is offline
  - `{:error, reason}` - Failed to fetch schema
  """
  def fetch_table_schema(connection, table_name, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_fetch_table_schema(site_url, auth_token_hash, table_name, opts)
    end
  end

  defp do_fetch_table_schema(site_url, auth_token_hash, table_name, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    api_url = build_schema_url(site_url)
    body = %{"auth_token_hash" => auth_token_hash, "table_name" => table_name}

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_schema_response(resp_body)

      result ->
        handle_table_http_result(result)
    end
  end

  defp parse_schema_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "schema" => schema}} -> {:ok, schema}
      {:ok, %{"success" => false, "error" => error}} -> {:error, error}
      _ -> {:error, :invalid_response}
    end
  end

  @doc """
  Fetch table records from a sender site via HTTP API for preview.

  Options:
  - `:limit` - Maximum number of records to fetch (default: 10)
  - `:offset` - Offset for pagination (default: 0)
  - `:ids` - List of specific IDs to fetch
  - `:id_range` - Tuple of {start_id, end_id}

  Returns:
  - `{:ok, records}` - List of record maps
  - `{:error, :offline}` - Sender is offline
  - `{:error, reason}` - Failed to fetch records
  """
  def fetch_table_records(connection, table_name, opts \\ []) do
    with {:ok, site_url, auth_token_hash} <- extract_connection_info(connection) do
      do_fetch_table_records(site_url, auth_token_hash, table_name, opts)
    end
  end

  defp do_fetch_table_records(site_url, auth_token_hash, table_name, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    api_url = build_records_url(site_url)
    body = build_records_request_body(auth_token_hash, table_name, opts)

    case make_http_request(api_url, body, timeout) do
      {:ok, %{status: 200, body: resp_body}} ->
        parse_records_response(resp_body)

      result ->
        handle_table_http_result(result)
    end
  end

  defp build_records_request_body(auth_token_hash, table_name, opts) do
    %{
      "auth_token_hash" => auth_token_hash,
      "table_name" => table_name,
      "limit" => Keyword.get(opts, :limit, 10),
      "offset" => Keyword.get(opts, :offset, 0)
    }
    |> maybe_add_ids(Keyword.get(opts, :ids))
    |> maybe_add_id_range(Keyword.get(opts, :id_range))
  end

  defp parse_records_response(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"success" => true, "records" => records}} -> {:ok, records}
      {:ok, %{"success" => false, "error" => error}} -> {:error, error}
      _ -> {:error, :invalid_response}
    end
  end

  defp maybe_add_ids(body, nil), do: body
  defp maybe_add_ids(body, []), do: body
  defp maybe_add_ids(body, ids), do: Map.put(body, "ids", ids)

  defp maybe_add_id_range(body, nil), do: body

  defp maybe_add_id_range(body, {start_id, end_id}) do
    Map.merge(body, %{"id_start" => start_id, "id_end" => end_id})
  end

  # --- Connection Info Helpers ---

  defp extract_connection_info(connection) do
    site_url = Map.get(connection, :site_url) || Map.get(connection, "site_url")

    auth_token_hash =
      Map.get(connection, :auth_token_hash) || Map.get(connection, "auth_token_hash")

    if is_nil(site_url) or is_nil(auth_token_hash) do
      {:error, :missing_connection_info}
    else
      {:ok, site_url, auth_token_hash}
    end
  end

  # --- HTTP Response Handlers ---

  defp handle_standard_http_result({:ok, %{status: _status}}), do: {:error, :unexpected_response}

  defp handle_standard_http_result({:error, %{reason: reason}})
       when reason in [:econnrefused, :timeout, :nxdomain] do
    {:ok, :offline}
  end

  defp handle_standard_http_result({:error, reason}), do: {:error, reason}

  defp handle_api_http_result({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_api_http_result({:ok, %{status: 404}}), do: {:error, :not_found}
  defp handle_api_http_result({:ok, %{status: _status}}), do: {:error, :unexpected_response}

  defp handle_api_http_result({:error, %{reason: reason}})
       when reason in [:econnrefused, :timeout, :nxdomain] do
    {:error, :offline}
  end

  defp handle_api_http_result({:error, reason}), do: {:error, reason}

  defp handle_table_http_result({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_table_http_result({:ok, %{status: 404}}), do: {:error, :table_not_found}
  defp handle_table_http_result({:ok, %{status: _status}}), do: {:error, :unexpected_response}

  defp handle_table_http_result({:error, %{reason: reason}})
       when reason in [:econnrefused, :timeout, :nxdomain] do
    {:error, :offline}
  end

  defp handle_table_http_result({:error, reason}), do: {:error, reason}

  # --- Private Functions ---

  defp build_api_url(site_url) do
    # Normalize URL and add API path
    base_url = String.trim_trailing(site_url, "/")

    # Try to detect the PhoenixKit prefix from the URL
    # Default is /phoenix_kit but could be configured differently
    prefix = detect_prefix(base_url)

    "#{base_url}#{prefix}/sync/api/register-connection"
  end

  defp build_status_url(site_url) do
    base_url = String.trim_trailing(site_url, "/")
    prefix = detect_prefix(base_url)
    "#{base_url}#{prefix}/sync/api/status"
  end

  defp build_delete_url(site_url) do
    base_url = String.trim_trailing(site_url, "/")
    prefix = detect_prefix(base_url)
    "#{base_url}#{prefix}/sync/api/delete-connection"
  end

  defp build_verify_url(site_url) do
    base_url = String.trim_trailing(site_url, "/")
    prefix = detect_prefix(base_url)
    "#{base_url}#{prefix}/sync/api/verify-connection"
  end

  defp build_status_change_url(site_url) do
    base_url = String.trim_trailing(site_url, "/")
    prefix = detect_prefix(base_url)
    "#{base_url}#{prefix}/sync/api/update-status"
  end

  defp build_get_status_url(site_url) do
    base_url = String.trim_trailing(site_url, "/")
    prefix = detect_prefix(base_url)
    "#{base_url}#{prefix}/sync/api/get-connection-status"
  end

  defp build_list_tables_url(site_url) do
    base_url = String.trim_trailing(site_url, "/")
    prefix = detect_prefix(base_url)
    "#{base_url}#{prefix}/sync/api/list-tables"
  end

  defp build_pull_data_url(site_url) do
    base_url = String.trim_trailing(site_url, "/")
    prefix = detect_prefix(base_url)
    "#{base_url}#{prefix}/sync/api/pull-data"
  end

  defp build_schema_url(site_url) do
    base_url = String.trim_trailing(site_url, "/")
    prefix = detect_prefix(base_url)
    "#{base_url}#{prefix}/sync/api/table-schema"
  end

  defp build_records_url(site_url) do
    base_url = String.trim_trailing(site_url, "/")
    prefix = detect_prefix(base_url)
    "#{base_url}#{prefix}/sync/api/table-records"
  end

  defp detect_prefix(_base_url) do
    # For now, use default prefix
    # In future, could try to detect from site or make configurable per-connection
    "/phoenix_kit"
  end

  defp build_request_body(conn_name, our_url, raw_token, password) do
    body = %{
      "sender_url" => our_url,
      "connection_name" => conn_name,
      "auth_token" => raw_token
    }

    if password do
      Map.put(body, "password", password)
    else
      body
    end
  end

  defp get_our_site_url do
    case Settings.get_setting("site_url", nil) do
      nil ->
        url = get_our_site_url_fallback()

        Logger.warning(
          "[Sync.Notifier] site_url not set in Settings, using fallback " <>
            "| resolved_url=#{url}"
        )

        url

      "" ->
        url = get_our_site_url_fallback()

        Logger.warning(
          "[Sync.Notifier] site_url is empty in Settings, using fallback " <>
            "| resolved_url=#{url}"
        )

        url

      url ->
        Logger.debug("[Sync.Notifier] Using site_url from Settings | url=#{url}")
        url
    end
  end

  defp get_our_site_url_fallback do
    case Application.get_env(:phoenix_kit, :public_url) do
      nil ->
        url = PhoenixKit.Config.get_dynamic_base_url()
        Logger.debug("[Sync.Notifier] Fallback: dynamic base URL | url=#{url}")
        url

      url ->
        Logger.debug("[Sync.Notifier] Fallback: :public_url config | url=#{url}")
        url
    end
  end

  defp make_http_request(url, body, timeout) do
    # Check if Finch is available
    finch_name = get_finch_name()

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "PhoenixKit-Sync/1.0"}
    ]

    case Jason.encode(body) do
      {:ok, json_body} ->
        request = Finch.build(:post, url, headers, json_body)

        case Finch.request(request, finch_name,
               receive_timeout: timeout,
               pool_timeout: @connect_timeout
             ) do
          {:ok, %Finch.Response{status: status, body: response_body}} ->
            {:ok, %{status: status, body: response_body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:json_encode_error, reason}}
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  defp make_get_request(url, timeout) do
    finch_name = get_finch_name()

    headers = [
      {"accept", "application/json"},
      {"user-agent", "PhoenixKit-Sync/1.0"}
    ]

    request = Finch.build(:get, url, headers)

    case Finch.request(request, finch_name,
           receive_timeout: timeout,
           pool_timeout: @connect_timeout
         ) do
      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:ok, %{status: status, body: response_body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  end

  defp get_finch_name do
    # Use Swoosh.Finch if available (added by PhoenixKit install)
    # Fall back to PhoenixKit.Finch
    if Process.whereis(Swoosh.Finch) do
      Swoosh.Finch
    else
      PhoenixKit.Finch
    end
  end

  defp parse_response(%{status: 200, body: body}) do
    case Jason.decode(body) do
      {:ok, %{"success" => true} = data} ->
        status =
          case data["connection_status"] do
            "active" -> :registered
            "pending" -> :pending
            _ -> :registered
          end

        %{
          success: true,
          status: status,
          message: data["message"] || "Connection registered",
          remote_connection_uuid: data["connection_uuid"] || data["connection_id"],
          http_status: 200,
          error: nil
        }

      {:ok, %{"success" => false} = data} ->
        %{
          success: false,
          status: :failed,
          message: data["error"] || "Remote site rejected connection",
          remote_connection_uuid: nil,
          http_status: 200,
          error: data["error"]
        }

      _ ->
        %{
          success: false,
          status: :failed,
          message: "Invalid response from remote site",
          remote_connection_uuid: nil,
          http_status: 200,
          error: "Invalid JSON response"
        }
    end
  end

  defp parse_response(%{status: 401, body: body}) do
    error_msg = extract_error(body, "Password required or invalid")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: 401,
      error: error_msg
    }
  end

  defp parse_response(%{status: 403, body: body}) do
    error_msg = extract_error(body, "Incoming connections denied")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: 403,
      error: error_msg
    }
  end

  defp parse_response(%{status: 409, body: body}) do
    error_msg = extract_error(body, "Connection already exists")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: 409,
      error: error_msg
    }
  end

  defp parse_response(%{status: 503, body: body}) do
    error_msg = extract_error(body, "DB Sync module disabled on remote site")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: 503,
      error: error_msg
    }
  end

  defp parse_response(%{status: status, body: body}) do
    error_msg = extract_error(body, "HTTP error #{status}")

    %{
      success: false,
      status: :failed,
      message: error_msg,
      remote_connection_uuid: nil,
      http_status: status,
      error: error_msg
    }
  end

  defp extract_error(body, default) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> error
      _ -> default
    end
  end

  defp format_error(%Mint.TransportError{reason: reason}) do
    "Connection failed: #{inspect(reason)}"
  end

  defp format_error({:exception, msg}) do
    "Exception: #{msg}"
  end

  defp format_error(reason) do
    inspect(reason)
  end

  defp update_connection_metadata(connection, result) do
    # Only update metadata for actual database structs (have :uuid field)
    # Skip for temp maps passed before connection is saved
    case Map.get(connection, :uuid) do
      nil ->
        # Temp map, nothing to update
        :ok

      _uuid ->
        current_metadata = Map.get(connection, :metadata) || %{}

        notification_data = %{
          "notified_at" => UtilsDate.utc_now() |> DateTime.to_iso8601(),
          "notification_success" => result.success,
          "notification_status" => Atom.to_string(result.status),
          "notification_message" => result.message,
          "remote_connection_uuid" => result.remote_connection_uuid,
          "http_status" => result.http_status
        }

        updated_metadata = Map.put(current_metadata, "remote_notification", notification_data)

        # Update the connection with new metadata
        Connections.update_connection(connection, %{metadata: updated_metadata})
    end
  rescue
    e ->
      Logger.error("Failed to update connection metadata: #{Exception.message(e)}")
      :ok
  end

  defp import_table_data(table_name, data, conflict_strategy) when is_list(data) do
    repo = PhoenixKit.RepoHelper.repo()

    Logger.info("Sync: Importing #{length(data)} records into #{table_name}")

    # Execute raw SQL insert for each record
    results =
      Enum.reduce(data, %{imported: 0, skipped: 0, errors: 0, error_sample: nil}, fn record,
                                                                                     acc ->
        case insert_record(repo, table_name, record, conflict_strategy) do
          :ok ->
            %{acc | imported: acc.imported + 1}

          :skipped ->
            %{acc | skipped: acc.skipped + 1}

          {:error, reason} ->
            # Keep only first error as sample
            acc = if is_nil(acc.error_sample), do: %{acc | error_sample: reason}, else: acc
            %{acc | errors: acc.errors + 1}

          :error ->
            %{acc | errors: acc.errors + 1}
        end
      end)

    Logger.info(
      "Sync: Import complete for #{table_name} - imported: #{results.imported}, skipped: #{results.skipped}, errors: #{results.errors}"
    )

    if results.errors > 0 && results.error_sample do
      Logger.warning("Sync: Sample error for #{table_name}: #{results.error_sample}")
    end

    Map.drop(results, [:error_sample])
  end

  defp import_table_data(_table_name, _data, _strategy) do
    %{imported: 0, skipped: 0, errors: 0}
  end

  defp import_table_data_with_remap(table_name, data, conflict_strategy, uuid_remap)
       when is_list(data) do
    repo = PhoenixKit.RepoHelper.repo()
    pk_col = PhoenixKit.RepoHelper.get_pk_column(table_name)

    Logger.info("Sync: Importing #{length(data)} records into #{table_name} (with remap)")

    # Get FK info for this table
    fk_columns =
      case SchemaInspector.get_foreign_key_columns(table_name) do
        {:ok, fks} -> fks
        _ -> []
      end

    # Get unique columns for this table (for matching existing records)
    unique_sets =
      case SchemaInspector.get_unique_columns(table_name) do
        {:ok, sets} -> sets
        _ -> []
      end

    import_ctx = %{
      repo: repo,
      table_name: table_name,
      pk_col: pk_col,
      fk_columns: fk_columns,
      unique_sets: unique_sets,
      conflict_strategy: conflict_strategy
    }

    {results, updated_remap} =
      Enum.reduce(
        data,
        {%{imported: 0, skipped: 0, errors: 0, error_sample: nil}, uuid_remap},
        fn record, {acc, remap} ->
          import_single_record_with_remap(import_ctx, record, acc, remap)
        end
      )

    Logger.info(
      "Sync: Import complete for #{table_name} - imported: #{results.imported}, skipped: #{results.skipped}, errors: #{results.errors}"
    )

    if results.errors > 0 && results.error_sample do
      Logger.warning("Sync: Sample error for #{table_name}: #{results.error_sample}")
    end

    remap_additions = map_size(updated_remap) - map_size(uuid_remap)

    if remap_additions > 0 do
      Logger.info("Sync: Added #{remap_additions} UUID remap(s) from #{table_name}")
    end

    {Map.drop(results, [:error_sample]), updated_remap}
  end

  defp import_table_data_with_remap(_table_name, _data, _strategy, uuid_remap) do
    {%{imported: 0, skipped: 0, errors: 0}, uuid_remap}
  end

  defp import_single_record_with_remap(ctx, record, acc, remap) do
    record_pk = get_record_field(record, ctx.pk_col)

    {match_action, remap} =
      match_existing_record(ctx.repo, ctx.table_name, ctx.pk_col, record, ctx.unique_sets, remap)

    case match_action do
      :skip_matched ->
        Logger.debug("Sync: Skipped #{ctx.table_name} record #{record_pk} (matched existing)")
        {%{acc | skipped: acc.skipped + 1}, remap}

      :import ->
        remapped_record = apply_fk_remap(record, ctx.fk_columns, remap)

        case insert_record(ctx.repo, ctx.table_name, remapped_record, ctx.conflict_strategy) do
          :ok ->
            {%{acc | imported: acc.imported + 1}, remap}

          :skipped ->
            {%{acc | skipped: acc.skipped + 1}, remap}

          {:error, reason} ->
            acc = if is_nil(acc.error_sample), do: %{acc | error_sample: reason}, else: acc
            {%{acc | errors: acc.errors + 1}, remap}

          :error ->
            {%{acc | errors: acc.errors + 1}, remap}
        end
    end
  end

  # Try to match a record by unique columns to an existing local record.
  # If matched, adds a PK remap (sender_pk → local_pk) and returns :skip_matched.
  # If no match, returns :import.
  defp match_existing_record(repo, table_name, pk_col, record, unique_sets, remap) do
    record_pk = get_record_field(record, pk_col)

    # First check if this PK already exists locally
    case check_pk_exists(repo, table_name, pk_col, record_pk) do
      true ->
        # PK exists — skip, the ON CONFLICT clause would handle it anyway but
        # this avoids an unnecessary INSERT attempt
        {:skip_matched, remap}

      false ->
        # PK doesn't exist — try to match by unique columns
        case find_match_by_unique(repo, table_name, pk_col, record, unique_sets) do
          {:ok, local_pk} ->
            # Found a match! Record the remap and skip import
            remap_key = {table_name, stringify_pk(record_pk)}
            remap = Map.put(remap, remap_key, stringify_pk(local_pk))

            Logger.info(
              "Sync: Matched #{table_name} by unique columns: #{inspect(record_pk)} → #{inspect(local_pk)}"
            )

            {:skip_matched, remap}

          :no_match ->
            # No match — import as new record
            {:import, remap}
        end
    end
  end

  defp stringify_pk(pk) when is_binary(pk), do: pk
  defp stringify_pk(pk), do: inspect(pk)

  defp check_pk_exists(repo, table_name, pk_col, pk_value) do
    sql = ~s[SELECT 1 FROM "#{table_name}" WHERE "#{pk_col}" = $1 LIMIT 1]

    case SQL.query(repo, sql, [prepare_value(pk_value)]) do
      {:ok, %{num_rows: 1}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp find_match_by_unique(_repo, _table_name, _pk_col, _record, []), do: :no_match

  defp find_match_by_unique(repo, table_name, pk_col, record, [unique_cols | rest]) do
    # Get values for this unique constraint's columns
    col_values =
      Enum.map(unique_cols, fn col ->
        {col, get_record_field(record, col)}
      end)

    # Skip if any value is nil (can't match on nil)
    if Enum.any?(col_values, fn {_col, val} -> is_nil(val) end) do
      find_match_by_unique(repo, table_name, pk_col, record, rest)
    else
      where_clauses =
        col_values
        |> Enum.with_index(1)
        |> Enum.map_join(" AND ", fn {{col, _val}, idx} -> ~s["#{col}" = $#{idx}] end)

      values = Enum.map(col_values, fn {_col, val} -> prepare_value(val) end)

      sql = ~s[SELECT "#{pk_col}" FROM "#{table_name}" WHERE #{where_clauses} LIMIT 1]

      case SQL.query(repo, sql, values) do
        {:ok, %{rows: [[local_pk]]}} -> {:ok, local_pk}
        _ -> find_match_by_unique(repo, table_name, pk_col, record, rest)
      end
    end
  rescue
    _ -> find_match_by_unique(repo, table_name, pk_col, record, rest)
  end

  # Apply FK remaps to a record before inserting
  defp apply_fk_remap(record, [], _remap), do: record

  defp apply_fk_remap(record, fk_columns, remap) do
    Enum.reduce(fk_columns, record, fn %{column: col, referenced_table: ref_table}, rec ->
      fk_value = get_record_field(rec, col)

      if fk_value && is_binary(fk_value) do
        remap_key = {ref_table, fk_value}

        case Map.get(remap, remap_key) do
          nil ->
            rec

          local_value ->
            # Replace the FK value with the local one — normalize to string key
            rec = put_record_field(rec, col, local_value)
            Logger.debug("Sync: Remapped #{col}: #{fk_value} → #{local_value}")
            rec
        end
      else
        rec
      end
    end)
  end

  defp insert_record(repo, table_name, record, conflict_strategy) when is_map(record) do
    pk_col = PhoenixKit.RepoHelper.get_pk_column(table_name)

    # For append strategy, strip primary key to let DB auto-generate new ID
    record =
      if conflict_strategy == "append" do
        drop_record_field(record, pk_col)
      else
        record
      end

    # Normalize all keys to strings for consistent SQL generation
    record = normalize_record_keys(record)
    columns = Map.keys(record)
    values = Map.values(record) |> Enum.map(&prepare_value/1)

    placeholders =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_col, idx} -> "$#{idx}" end)

    columns_str = Enum.map_join(columns, ", ", &~s["#{&1}"])

    on_conflict =
      case conflict_strategy do
        "skip" ->
          "ON CONFLICT DO NOTHING"

        "overwrite" ->
          ~s[ON CONFLICT ("#{pk_col}") DO UPDATE SET #{build_update_clause(columns, pk_col)}]

        "merge" ->
          "ON CONFLICT DO NOTHING"

        "append" ->
          ""

        _ ->
          "ON CONFLICT DO NOTHING"
      end

    sql = ~s[INSERT INTO "#{table_name}" (#{columns_str}) VALUES (#{placeholders}) #{on_conflict}]

    case SQL.query(repo, sql, values) do
      {:ok, %{num_rows: 1}} ->
        :ok

      {:ok, %{num_rows: 0}} ->
        :skipped

      {:error, %{postgres: %{code: code, message: msg}}} ->
        {:error, "[#{code}] #{msg}"}

      {:error, error} ->
        {:error, inspect(error)}
    end
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp insert_record(_repo, _table_name, _record, _strategy), do: :error

  defp build_update_clause(columns, pk_col) do
    columns
    |> Enum.reject(&(to_string(&1) == pk_col))
    |> Enum.map_join(", ", fn col -> ~s["#{col}" = EXCLUDED."#{col}"] end)
  end

  # Convert ISO8601 strings to DateTime/Date/Time structs for Postgrex
  defp prepare_value(value) when is_binary(value) do
    parse_datetime_string(value) || parse_date_string(value) || parse_time_string(value) || value
  end

  defp prepare_value(%{"__phoenix_kit_binary__" => encoded}) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, binary} -> binary
      :error -> encoded
    end
  end

  defp prepare_value(value), do: value

  # Record field helpers — records may have string or atom keys depending on
  # whether they came from JSON (string keys) or internal code (atom keys).
  # These helpers safely access/set fields without creating atoms from untrusted data.
  defp get_record_field(record, field) when is_binary(field) do
    case Map.get(record, field) do
      nil -> Map.get(record, String.to_existing_atom(field))
      val -> val
    end
  rescue
    ArgumentError -> nil
  end

  defp put_record_field(record, field, value) when is_binary(field) do
    record
    |> Map.delete(field)
    |> Map.reject(fn {k, _} -> is_atom(k) and Atom.to_string(k) == field end)
    |> Map.put(field, value)
  end

  defp drop_record_field(record, field) when is_binary(field) do
    record
    |> Map.delete(field)
    |> Map.reject(fn {k, _} -> is_atom(k) and Atom.to_string(k) == field end)
  end

  # Normalize all map keys to strings for consistent SQL column generation
  defp normalize_record_keys(record) when is_map(record) do
    Map.new(record, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # DateTime with timezone (e.g., "2025-12-15T18:56:59.387453Z")
  @datetime_regex ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$/
  defp parse_datetime_string(value) do
    if Regex.match?(@datetime_regex, value) do
      case DateTime.from_iso8601(value) do
        {:ok, dt, _offset} -> dt
        _ -> parse_naive_datetime(value)
      end
    end
  end

  defp parse_naive_datetime(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, ndt} -> ndt
      _ -> nil
    end
  end

  # Date only (e.g., "2025-12-15")
  @date_regex ~r/^\d{4}-\d{2}-\d{2}$/
  defp parse_date_string(value) do
    if Regex.match?(@date_regex, value) do
      case Date.from_iso8601(value) do
        {:ok, d} -> d
        _ -> nil
      end
    end
  end

  # Time only (e.g., "18:56:59" or "18:56:59.387453")
  @time_regex ~r/^\d{2}:\d{2}:\d{2}(\.\d+)?$/
  defp parse_time_string(value) do
    if Regex.match?(@time_regex, value) do
      case Time.from_iso8601(value) do
        {:ok, t} -> t
        _ -> nil
      end
    end
  end
end
