defmodule PhoenixKit.Modules.Sync.Web.Receiver do
  @moduledoc """
  Receiver-side LiveView for DB Sync.

  This is the site that wants to receive data from another site.

  ## Flow

  1. Enter the sender's URL and connection code
  2. Connect to the sender via WebSocket
  3. Browse sender's available tables
  4. Select tables to transfer
  5. Configure conflict resolution and execute transfer
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Sync.SchemaInspector
  alias PhoenixKit.Modules.Sync.WebSocketClient
  alias PhoenixKit.Modules.Sync.Workers.ImportWorker
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  require Logger

  @batch_size 500

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    site_url = Settings.get_setting("site_url", "")

    # Get current user info from scope
    current_user = get_current_user(socket)

    socket =
      socket
      |> assign(:page_title, "Receive Data")
      |> assign(:project_title, project_title)
      |> assign(:site_url, site_url)
      |> assign(:current_user, current_user)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/sync/receive", locale: locale))
      |> assign(:step, :enter_credentials)
      |> assign(:sender_url, "")
      |> assign(:connection_code, "")
      |> assign(:connecting, false)
      |> assign(:connected, false)
      |> assign(:error_message, nil)
      |> assign(:ws_client, nil)
      |> assign(:connection_status, nil)
      |> assign(:tables, [])
      |> assign(:local_counts, %{})
      |> assign(:loading_tables, false)
      |> assign(:selected_tables, MapSet.new())
      |> assign(:conflict_strategy, :skip)
      |> assign(:transferring, false)
      |> assign(:transfer_progress, nil)
      # Tab-related assigns
      |> assign(:active_tab, :global)
      |> assign(:selected_detail_table, nil)
      |> assign(:detail_table_schema, nil)
      |> assign(:detail_filter, %{mode: :all, ids: "", range_start: "", range_end: "", search: ""})
      |> assign(:detail_preview, nil)
      |> assign(:loading_schema, false)
      |> assign(:loading_preview, false)
      |> assign(:local_table_exists, true)
      |> assign(:creating_table, false)
      # Schemas cache for bulk transfer auto-creation
      |> assign(:table_schemas, %{})
      |> assign(:pending_schemas, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Clean up WebSocket client on unmount
    if socket.assigns.ws_client do
      WebSocketClient.disconnect(socket.assigns.ws_client)
    end

    :ok
  end

  # ===========================================
  # EVENT HANDLERS
  # ===========================================

  @impl true
  def handle_event("update_form", %{"sender_url" => url, "connection_code" => code}, socket) do
    socket =
      socket
      |> assign(:sender_url, url)
      |> assign(:connection_code, String.upcase(code))
      |> assign(:error_message, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("connect", _params, socket) do
    url = socket.assigns.sender_url
    code = socket.assigns.connection_code

    cond do
      String.trim(url) == "" ->
        {:noreply, assign(socket, :error_message, "Please enter the sender's URL")}

      String.trim(code) == "" ->
        {:noreply, assign(socket, :error_message, "Please enter the connection code")}

      String.length(code) != 8 ->
        {:noreply, assign(socket, :error_message, "Connection code must be 8 characters")}

      true ->
        # Start connecting
        socket =
          socket
          |> assign(:connecting, true)
          |> assign(:error_message, nil)
          |> assign(:connection_status, "Establishing connection...")

        # Start WebSocket client asynchronously
        send(self(), :start_websocket)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    # Disconnect WebSocket if connected
    if socket.assigns.ws_client do
      WebSocketClient.disconnect(socket.assigns.ws_client)
    end

    socket =
      socket
      |> assign(:connecting, false)
      |> assign(:connected, false)
      |> assign(:step, :enter_credentials)
      |> assign(:ws_client, nil)
      |> assign(:connection_status, nil)
      |> assign(:tables, [])
      |> assign(:selected_tables, MapSet.new())
      |> assign(:transferring, false)
      |> assign(:transfer_progress, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("disconnect", _params, socket) do
    if socket.assigns.ws_client do
      WebSocketClient.disconnect(socket.assigns.ws_client)
    end

    socket =
      socket
      |> assign(:connecting, false)
      |> assign(:connected, false)
      |> assign(:step, :enter_credentials)
      |> assign(:ws_client, nil)
      |> assign(:connection_status, nil)
      |> assign(:tables, [])
      |> assign(:selected_tables, MapSet.new())

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_tables", _params, socket) do
    if socket.assigns.ws_client do
      WebSocketClient.request_tables(socket.assigns.ws_client)
      {:noreply, assign(socket, :loading_tables, true)}
    else
      {:noreply, put_flash(socket, :error, "Not connected to sender")}
    end
  end

  @impl true
  def handle_event("toggle_table", %{"table" => table}, socket) do
    selected = socket.assigns.selected_tables

    selected =
      if MapSet.member?(selected, table) do
        MapSet.delete(selected, table)
      else
        MapSet.put(selected, table)
      end

    {:noreply, assign(socket, :selected_tables, selected)}
  end

  @impl true
  def handle_event("select_all_tables", _params, socket) do
    all_tables = Enum.map(socket.assigns.tables, & &1["name"])
    {:noreply, assign(socket, :selected_tables, MapSet.new(all_tables))}
  end

  @impl true
  def handle_event("deselect_all_tables", _params, socket) do
    {:noreply, assign(socket, :selected_tables, MapSet.new())}
  end

  @impl true
  def handle_event("select_different_tables", _params, socket) do
    # Select tables that either don't exist locally or have different counts
    different_tables =
      socket.assigns.tables
      |> Enum.filter(fn table ->
        name = table["name"]
        sender_count = table["estimated_count"] || 0
        local_count = Map.get(socket.assigns.local_counts, name)

        # Select if: no local table, or counts differ
        is_nil(local_count) or local_count != sender_count
      end)
      |> Enum.map(& &1["name"])

    {:noreply, assign(socket, :selected_tables, MapSet.new(different_tables))}
  end

  @impl true
  def handle_event("set_conflict_strategy", %{"strategy" => strategy}, socket) do
    strategy = String.to_existing_atom(strategy)
    {:noreply, assign(socket, :conflict_strategy, strategy)}
  end

  @impl true
  def handle_event("start_transfer", _params, socket) do
    if MapSet.size(socket.assigns.selected_tables) == 0 do
      {:noreply, put_flash(socket, :error, "Please select at least one table")}
    else
      tables_list = MapSet.to_list(socket.assigns.selected_tables)

      # Start transfer process - first fetch schemas for auto-creation support
      socket =
        socket
        |> assign(:transferring, true)
        |> assign(:pending_schemas, tables_list)
        |> assign(:table_schemas, %{})
        |> assign(:transfer_progress, %{
          status: :fetching_schemas,
          current_table: nil,
          tables_pending: tables_list,
          tables_fetched: [],
          tables_done: 0,
          total_tables: length(tables_list),
          records_fetched: 0,
          jobs_queued: 0,
          pending_fetch: nil
        })

      # Request schemas for all selected tables
      for table <- tables_list do
        WebSocketClient.request_schema(socket.assigns.ws_client, table)
      end

      {:noreply, socket}
    end
  end

  # ===========================================
  # TAB EVENT HANDLERS
  # ===========================================

  @impl true
  def handle_event("switch_tab", %{"tab" => "global"}, socket) do
    {:noreply, assign(socket, :active_tab, :global)}
  end

  def handle_event("switch_tab", %{"tab" => "table_details"}, socket) do
    {:noreply, assign(socket, :active_tab, :table_details)}
  end

  @impl true
  def handle_event("select_detail_table", %{"table" => ""}, socket) do
    # Clear selection when "Choose a table..." is selected
    socket =
      socket
      |> assign(:selected_detail_table, nil)
      |> assign(:loading_schema, false)
      |> assign(:detail_table_schema, nil)
      |> assign(:detail_preview, nil)
      |> assign(:detail_filter, %{mode: :all, ids: "", range_start: "", range_end: "", search: ""})

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_detail_table", %{"table" => table_name}, socket) do
    Logger.info(
      "Sync.Receiver: Selecting table: #{table_name}, ws_client: #{inspect(socket.assigns.ws_client)}"
    )

    # Request schema for the selected table
    if socket.assigns.ws_client do
      Logger.info("Sync.Receiver: Requesting schema for #{table_name}")
      WebSocketClient.request_schema(socket.assigns.ws_client, table_name)
    else
      Logger.warning("Sync.Receiver: No ws_client available!")
    end

    socket =
      socket
      |> assign(:selected_detail_table, table_name)
      |> assign(:loading_schema, true)
      |> assign(:detail_table_schema, nil)
      |> assign(:detail_preview, nil)
      |> assign(:detail_filter, %{mode: :all, ids: "", range_start: "", range_end: "", search: ""})

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_detail_filter", params, socket) do
    mode =
      case params["mode"] do
        "all" -> :all
        "ids" -> :ids
        "range" -> :range
        _ -> socket.assigns.detail_filter.mode
      end

    filter = %{
      mode: mode,
      ids: params["ids"] || socket.assigns.detail_filter.ids,
      range_start: params["range_start"] || socket.assigns.detail_filter.range_start,
      range_end: params["range_end"] || socket.assigns.detail_filter.range_end,
      search: params["search"] || socket.assigns.detail_filter.search
    }

    {:noreply, assign(socket, :detail_filter, filter)}
  end

  @impl true
  def handle_event("preview_detail_records", _params, socket) do
    table = socket.assigns.selected_detail_table
    filter = socket.assigns.detail_filter

    if table && socket.assigns.ws_client do
      # Request a small preview based on filter
      case filter.mode do
        :all ->
          WebSocketClient.request_records(socket.assigns.ws_client, table, offset: 0, limit: 10)

        :ids ->
          # For IDs mode, we'll fetch all and filter client-side in preview
          WebSocketClient.request_records(socket.assigns.ws_client, table, offset: 0, limit: 100)

        :range ->
          # For range mode, calculate offset/limit from range
          start_id = parse_int(filter.range_start, 1)
          end_id = parse_int(filter.range_end, start_id + 99)
          # This is a rough approximation - real implementation would use WHERE clause
          WebSocketClient.request_records(socket.assigns.ws_client, table,
            offset: max(0, start_id - 1),
            limit: min(100, end_id - start_id + 1)
          )
      end

      {:noreply, assign(socket, :loading_preview, true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create_table", _params, socket) do
    table = socket.assigns.selected_detail_table
    schema = socket.assigns.detail_table_schema

    if table && schema do
      socket = assign(socket, :creating_table, true)

      case SchemaInspector.create_table(table, schema) do
        :ok ->
          Logger.info("Sync.Receiver: Created table #{table}")

          # Update local_counts to reflect the new table
          local_counts = Map.put(socket.assigns.local_counts, table, 0)

          socket =
            socket
            |> assign(:creating_table, false)
            |> assign(:local_table_exists, true)
            |> assign(:local_counts, local_counts)
            |> put_flash(:info, "Table '#{table}' created successfully")

          {:noreply, socket}

        {:error, reason} ->
          Logger.error("Sync.Receiver: Failed to create table #{table}: #{inspect(reason)}")

          socket =
            socket
            |> assign(:creating_table, false)
            |> put_flash(:error, "Failed to create table: #{inspect(reason)}")

          {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "No table selected or schema not loaded")}
    end
  end

  @impl true
  def handle_event("transfer_detail_table", _params, socket) do
    table = socket.assigns.selected_detail_table
    filter = socket.assigns.detail_filter
    schema = socket.assigns.detail_table_schema

    if table do
      # Store the schema for this table so it gets passed to import jobs
      table_schemas =
        if schema do
          Map.put(socket.assigns.table_schemas, table, schema)
        else
          socket.assigns.table_schemas
        end

      socket =
        socket
        |> assign(:transferring, true)
        |> assign(:table_schemas, table_schemas)
        |> assign(:pending_schemas, [])
        |> assign(:transfer_progress, %{
          status: :starting,
          current_table: table,
          tables_pending: [table],
          tables_fetched: [],
          tables_done: 0,
          total_tables: 1,
          records_fetched: 0,
          jobs_queued: 0,
          pending_fetch: nil,
          filter: filter
        })

      send(self(), :execute_transfer)
      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Please select a table first")}
    end
  end

  # ===========================================
  # MESSAGE HANDLERS
  # ===========================================

  @impl true
  def handle_info(:start_websocket, socket) do
    url = socket.assigns.sender_url
    code = socket.assigns.connection_code

    # Build receiver info to send to sender
    receiver_info = %{
      site_url: socket.assigns.site_url,
      project_title: socket.assigns.project_title,
      user_email: get_in(socket.assigns, [:current_user, :email]),
      user_name: get_in(socket.assigns, [:current_user, :name])
    }

    case WebSocketClient.start_link(
           url: url,
           code: code,
           caller: self(),
           receiver_info: receiver_info
         ) do
      {:ok, pid} ->
        socket =
          socket
          |> assign(:ws_client, pid)
          |> assign(:connection_status, "Connecting to sender...")

        {:noreply, socket}

      {:error, reason} ->
        Logger.error("Sync.Receiver: Failed to start WebSocket client: #{inspect(reason)}")

        socket =
          socket
          |> assign(:connecting, false)
          |> assign(:error_message, format_connection_error(reason))
          |> assign(:connection_status, nil)

        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:sync_client, :connected}, socket) do
    Logger.info("Sync.Receiver: Connected to sender")

    # Request tables immediately
    WebSocketClient.request_tables(socket.assigns.ws_client)

    socket =
      socket
      |> assign(:connecting, false)
      |> assign(:connected, true)
      |> assign(:step, :connected)
      |> assign(:connection_status, "Connected - loading tables...")
      |> assign(:loading_tables, true)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_client, :disconnected}, socket) do
    Logger.info("Sync.Receiver: Disconnected from sender")

    socket =
      socket
      |> assign(:connecting, false)
      |> assign(:connected, false)
      |> assign(:ws_client, nil)
      |> assign(:connection_status, nil)
      |> put_flash(:info, "Disconnected from sender")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_client, {:disconnected, reason}}, socket) do
    Logger.info("Sync.Receiver: Disconnected - #{inspect(reason)}")

    socket =
      socket
      |> assign(:connecting, false)
      |> assign(:connected, false)
      |> assign(:ws_client, nil)
      |> assign(:connection_status, nil)

    socket =
      if socket.assigns.step == :enter_credentials do
        assign(socket, :error_message, format_connection_error(reason))
      else
        put_flash(socket, :info, "Connection closed")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_client, {:error, reason}}, socket) do
    Logger.warning("Sync.Receiver: Connection error - #{inspect(reason)}")

    socket =
      socket
      |> assign(:connecting, false)
      |> assign(:error_message, format_connection_error(reason))
      |> assign(:connection_status, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_client, {:terminated, _reason}}, socket) do
    socket =
      socket
      |> assign(:connecting, false)
      |> assign(:connected, false)
      |> assign(:ws_client, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_client, :channel_closed}, socket) do
    socket =
      socket
      |> assign(:connecting, false)
      |> assign(:connected, false)
      |> assign(:ws_client, nil)
      |> assign(:step, :enter_credentials)
      |> put_flash(:info, "Sender closed the connection")

    {:noreply, socket}
  end

  # Handle tables response from WebSocketClient
  @impl true
  def handle_info({:sync_client, {:tables, tables}}, socket) do
    # Fetch local counts for comparison
    local_counts = fetch_local_counts(tables)

    socket =
      socket
      |> assign(:tables, tables)
      |> assign(:local_counts, local_counts)
      |> assign(:loading_tables, false)
      |> assign(:connection_status, nil)

    {:noreply, socket}
  end

  # Handle schema response from WebSocketClient
  @impl true
  def handle_info({:sync_client, {:schema, table, schema}}, socket) do
    Logger.info(
      "Sync.Receiver: Received schema for #{table}, selected: #{socket.assigns.selected_detail_table}"
    )

    Logger.debug("Sync.Receiver: Schema data: #{inspect(schema, limit: 500)}")

    # Check if this is during bulk transfer schema fetching
    if socket.assigns.transferring and
         socket.assigns.transfer_progress.status == :fetching_schemas do
      handle_bulk_transfer_schema(socket, table, schema)
    else
      # Table details tab - single table selection
      if socket.assigns.selected_detail_table == table do
        # Check if local table exists
        local_exists = SchemaInspector.table_exists?(table)

        socket =
          socket
          |> assign(:detail_table_schema, schema)
          |> assign(:loading_schema, false)
          |> assign(:local_table_exists, local_exists)

        {:noreply, socket}
      else
        Logger.warning(
          "Sync.Receiver: Schema table mismatch - received #{table}, expected #{socket.assigns.selected_detail_table}"
        )

        {:noreply, socket}
      end
    end
  end

  # Handle schema request errors
  @impl true
  def handle_info({:sync_client, {:request_error, {:schema, table}, error}}, socket) do
    Logger.error("Sync.Receiver: Error fetching schema for #{table}: #{error}")

    # Check if this is during bulk transfer schema fetching
    if socket.assigns.transferring and
         socket.assigns.transfer_progress.status == :fetching_schemas do
      # Continue without schema for this table (table won't be auto-created)
      pending_schemas = List.delete(socket.assigns.pending_schemas, table)

      socket =
        socket
        |> assign(:pending_schemas, pending_schemas)
        |> put_flash(:warning, "Could not get schema for #{table}, table won't be auto-created")

      # Check if all schemas have been received/failed
      if Enum.empty?(pending_schemas) do
        Logger.info("Sync.Receiver: All schemas processed, starting record fetch")

        socket =
          socket
          |> assign(:transfer_progress, %{
            socket.assigns.transfer_progress
            | status: :fetching
          })

        socket = fetch_next_table(socket)
        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      # Table details tab error
      socket =
        socket
        |> assign(:loading_schema, false)
        |> assign(:detail_table_schema, nil)
        |> put_flash(:error, "Failed to load schema for #{table}: #{error}")

      {:noreply, socket}
    end
  end

  # Handle records response for preview (not transferring)
  @impl true
  def handle_info({:sync_client, {:records, table, result}}, socket)
      when not socket.assigns.transferring and socket.assigns.loading_preview do
    if socket.assigns.selected_detail_table == table do
      records = Map.get(result, :records, [])
      filter = socket.assigns.detail_filter

      # Apply client-side filtering for IDs mode
      filtered_records = filter_records_by_mode(records, filter)

      socket =
        socket
        |> assign(:detail_preview, %{
          records: Enum.take(filtered_records, 10),
          total: length(filtered_records)
        })
        |> assign(:loading_preview, false)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Handle records response from WebSocketClient during transfer
  @impl true
  def handle_info({:sync_client, {:records, table, result}}, socket)
      when socket.assigns.transferring do
    progress = socket.assigns.transfer_progress

    # Result is a map with atom keys from WebSocketClient
    records = Map.get(result, :records, [])
    has_more = Map.get(result, :has_more, false)
    offset = Map.get(result, :offset, 0)
    strategy = socket.assigns.conflict_strategy

    # Get schema for this table (for auto-creation of missing tables)
    table_schema = Map.get(socket.assigns.table_schemas, table)

    # Queue import job for this batch
    socket =
      if records != [] do
        case queue_import_job(table, records, strategy, offset, schema: table_schema) do
          {:ok, _job} ->
            assign(socket, :transfer_progress, %{
              progress
              | records_fetched: progress.records_fetched + length(records),
                jobs_queued: progress.jobs_queued + 1
            })

          {:error, reason} ->
            Logger.error("Failed to queue import job: #{inspect(reason)}")
            socket
        end
      else
        socket
      end

    progress = socket.assigns.transfer_progress

    # If there are more records, fetch next batch
    socket =
      if has_more do
        new_offset = offset + @batch_size

        WebSocketClient.request_records(socket.assigns.ws_client, table,
          offset: new_offset,
          limit: @batch_size
        )

        assign(socket, :transfer_progress, %{
          progress
          | current_table: table,
            pending_fetch: {table, new_offset}
        })
      else
        # Table complete, move to next
        tables_fetched = [table | progress.tables_fetched]
        tables_pending = List.delete(progress.tables_pending, table)

        socket =
          assign(socket, :transfer_progress, %{
            progress
            | tables_fetched: tables_fetched,
              tables_pending: tables_pending,
              tables_done: progress.tables_done + 1,
              pending_fetch: nil
          })

        # Fetch next table if any
        if tables_pending != [] do
          fetch_next_table(socket)
        else
          # All tables fetched, transfer complete
          complete_transfer(socket)
        end
      end

    {:noreply, socket}
  end

  # Handle error response during transfer
  @impl true
  def handle_info({:sync_client, {:request_error, {:records, table}, error}}, socket)
      when socket.assigns.transferring do
    Logger.error("Sync.Receiver: Error fetching records for #{table}: #{error}")

    progress = socket.assigns.transfer_progress
    tables_pending = List.delete(progress.tables_pending, table)

    socket =
      socket
      |> assign(:transfer_progress, %{
        progress
        | tables_pending: tables_pending,
          tables_done: progress.tables_done + 1,
          pending_fetch: nil
      })
      |> put_flash(:warning, "Failed to fetch records from #{table}: #{error}")

    # Continue with next table
    socket =
      if tables_pending != [] do
        fetch_next_table(socket)
      else
        complete_transfer(socket)
      end

    {:noreply, socket}
  end

  # Handle error response for tables
  @impl true
  def handle_info({:sync_client, {:request_error, :tables, error}}, socket) do
    Logger.error("Sync.Receiver: Error fetching tables: #{error}")

    socket =
      socket
      |> assign(:loading_tables, false)
      |> put_flash(:error, "Failed to load tables: #{error}")

    {:noreply, socket}
  end

  @impl true
  def handle_info(:execute_transfer, socket) do
    socket =
      socket
      |> assign(:transfer_progress, %{
        socket.assigns.transfer_progress
        | status: :fetching
      })

    # Start fetching first table
    socket = fetch_next_table(socket)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_client, msg}, socket) do
    Logger.debug("Sync.Receiver: Received message - #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Handle schema received during bulk transfer
  defp handle_bulk_transfer_schema(socket, table, schema) do
    # Store the schema
    table_schemas = Map.put(socket.assigns.table_schemas, table, schema)
    pending_schemas = List.delete(socket.assigns.pending_schemas, table)

    socket =
      socket
      |> assign(:table_schemas, table_schemas)
      |> assign(:pending_schemas, pending_schemas)

    # Check if all schemas have been received
    if Enum.empty?(pending_schemas) do
      Logger.info("Sync.Receiver: All schemas received, starting record fetch")

      # All schemas received - start fetching records
      socket =
        socket
        |> assign(:transfer_progress, %{
          socket.assigns.transfer_progress
          | status: :fetching
        })

      # Start fetching records
      socket = fetch_next_table(socket)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ===========================================
  # RENDER
  # ===========================================

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Receive Data"
      current_path={@current_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-8">
          <.link
            navigate={Routes.path("/admin/sync", locale: @current_locale)}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back
          </.link>

          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">Receive Data</h1>
            <p class="text-lg text-base-content/70">
              Connect to another site and pull their data
            </p>
          </div>
        </header>

        <div class="max-w-4xl mx-auto w-full">
          <%= cond do %>
            <% @connected -> %>
              <.render_connected_step {assigns} />
            <% @connecting -> %>
              <.render_connecting_step {assigns} />
            <% true -> %>
              <.render_credentials_form {assigns} />
          <% end %>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp render_credentials_form(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <div class="text-center mb-6">
          <div class="text-6xl mb-4">📥</div>
          <h2 class="card-title text-2xl justify-center">Connect to Sender</h2>
          <p class="text-base-content/70">
            Enter the sender's site URL and the connection code they shared with you.
          </p>
        </div>

        <form phx-change="update_form" phx-submit="connect" class="space-y-4">
          <%!-- Sender URL --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold">Sender's Site URL</span>
            </label>
            <input
              type="url"
              name="sender_url"
              value={@sender_url}
              placeholder="https://example.com"
              class="input input-bordered w-full"
              required
            />
            <label class="label">
              <span class="label-text-alt text-base-content/50">
                The URL of the site you want to receive data from
              </span>
            </label>
          </div>

          <%!-- Connection Code --%>
          <div class="form-control">
            <label class="label">
              <span class="label-text font-semibold">Connection Code</span>
            </label>
            <input
              type="text"
              name="connection_code"
              value={@connection_code}
              placeholder="ABC12345"
              maxlength="8"
              class="input input-bordered w-full font-mono text-xl tracking-widest uppercase"
              required
            />
            <label class="label">
              <span class="label-text-alt text-base-content/50">
                8-character code from the sending site
              </span>
            </label>
          </div>

          <%!-- Error Message --%>
          <%= if @error_message do %>
            <div class="alert alert-error">
              <.icon name="hero-exclamation-circle" class="w-5 h-5" />
              <span>{@error_message}</span>
            </div>
          <% end %>

          <%!-- Submit Button --%>
          <div class="form-control mt-6">
            <button type="submit" class="btn btn-primary btn-lg">
              <.icon name="hero-link" class="w-5 h-5" /> Connect
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp render_connecting_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body items-center text-center">
        <div class="text-6xl mb-4">
          <span class="loading loading-spinner loading-lg text-primary"></span>
        </div>
        <h2 class="card-title text-2xl mb-4">Connecting...</h2>

        <div class="bg-base-200 rounded-lg p-4 mb-6 w-full">
          <p class="text-sm text-base-content/70 mb-1">Connecting to:</p>
          <p class="font-mono text-sm break-all">{@sender_url}</p>
          <p class="text-sm text-base-content/70 mt-2 mb-1">Code:</p>
          <p class="font-mono font-bold tracking-widest">{@connection_code}</p>
        </div>

        <%= if @connection_status do %>
          <p class="text-base-content/70 mb-6">{@connection_status}</p>
        <% end %>

        <button phx-click="cancel" class="btn btn-ghost">
          Cancel
        </button>
      </div>
    </div>
    """
  end

  defp render_connected_step(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Connection Status Card --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3">
              <div class="text-3xl">✅</div>
              <div>
                <h2 class="text-xl font-bold text-success">Connected to Sender</h2>
                <p class="text-sm text-base-content/70 font-mono">{@sender_url}</p>
              </div>
            </div>
            <button phx-click="disconnect" class="btn btn-outline btn-error btn-sm">
              <.icon name="hero-x-mark" class="w-4 h-4" /> Disconnect
            </button>
          </div>
        </div>
      </div>

      <%= if @transferring do %>
        <.render_transfer_progress {assigns} />
      <% else %>
        <%!-- Tab Navigation --%>
        <div role="tablist" class="tabs tabs-boxed bg-base-200 p-1">
          <button
            role="tab"
            class={["tab", @active_tab == :global && "tab-active"]}
            phx-click="switch_tab"
            phx-value-tab="global"
          >
            <.icon name="hero-globe-alt" class="w-4 h-4 mr-1" /> Bulk Transfer
          </button>
          <button
            role="tab"
            class={["tab", @active_tab == :table_details && "tab-active"]}
            phx-click="switch_tab"
            phx-value-tab="table_details"
          >
            <.icon name="hero-table-cells" class="w-4 h-4 mr-1" /> Table Details
          </button>
        </div>

        <%= if @active_tab == :global do %>
          <%!-- Global Tab: Bulk Table Browser --%>
          <.render_table_browser {assigns} />

          <%!-- Transfer Configuration --%>
          <%= if MapSet.size(@selected_tables) > 0 do %>
            <.render_transfer_config {assigns} />
          <% end %>
        <% else %>
          <%!-- Table Details Tab --%>
          <.render_table_details {assigns} />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp render_table_browser(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-lg font-bold">
            <.icon name="hero-table-cells" class="w-5 h-5 inline" /> Available Tables
          </h3>
          <button phx-click="refresh_tables" class="btn btn-ghost btn-sm" disabled={@loading_tables}>
            <.icon
              name="hero-arrow-path"
              class={if @loading_tables, do: "w-4 h-4 animate-spin", else: "w-4 h-4"}
            /> Refresh
          </button>
        </div>

        <%= if @loading_tables do %>
          <div class="flex items-center justify-center py-8">
            <span class="loading loading-spinner loading-lg text-primary"></span>
          </div>
        <% else %>
          <%= if length(@tables) == 0 do %>
            <div class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>No tables available from sender.</span>
            </div>
          <% else %>
            <%!-- Legend --%>
            <div class="bg-base-200 rounded-lg p-3 mb-4 text-sm">
              <div class="flex flex-wrap gap-x-6 gap-y-1 items-center">
                <span class="text-base-content/70">Record counts:</span>
                <span><span class="font-semibold text-primary">Sender</span> = remote data</span>
                <span><span class="font-semibold text-success">Local</span> = your database</span>
                <span class="badge badge-warning badge-sm gap-1">
                  <.icon name="hero-exclamation-triangle" class="w-3 h-3" /> = differs
                </span>
              </div>
            </div>

            <div class="flex gap-2 mb-4">
              <button phx-click="select_all_tables" class="btn btn-ghost btn-xs">
                Select All
              </button>
              <button phx-click="deselect_all_tables" class="btn btn-ghost btn-xs">
                Deselect All
              </button>
              <button phx-click="select_different_tables" class="btn btn-ghost btn-xs">
                Select Different
              </button>
              <span class="text-sm text-base-content/70 ml-auto">
                {MapSet.size(@selected_tables)} of {length(@tables)} selected
              </span>
            </div>

            <div class="overflow-x-auto">
              <table class="table table-zebra">
                <thead>
                  <tr>
                    <th class="w-12"></th>
                    <th>Table Name</th>
                    <th class="text-right">Sender</th>
                    <th class="text-right">Local</th>
                    <th class="text-center">Status</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for table <- @tables do %>
                    <% sender_count = table["estimated_count"] || 0 %>
                    <% local_count = Map.get(@local_counts, table["name"]) %>
                    <% has_local = not is_nil(local_count) %>
                    <% is_different = has_local and local_count != sender_count %>
                    <% is_large = sender_count > 100 %>
                    <tr
                      class={[
                        "cursor-pointer hover",
                        is_different && "bg-warning/10"
                      ]}
                      phx-click="toggle_table"
                      phx-value-table={table["name"]}
                    >
                      <td>
                        <input
                          type="checkbox"
                          class="checkbox checkbox-primary"
                          checked={MapSet.member?(@selected_tables, table["name"])}
                          phx-click="toggle_table"
                          phx-value-table={table["name"]}
                        />
                      </td>
                      <td class="font-mono">
                        {table["name"]}
                        <%= if is_large do %>
                          <span class="badge badge-ghost badge-xs ml-1">large</span>
                        <% end %>
                      </td>
                      <td class="text-right font-semibold text-primary">
                        {format_number(sender_count)}
                      </td>
                      <td class="text-right">
                        <%= if has_local do %>
                          <span class={
                            if is_different, do: "font-semibold text-warning", else: "text-success"
                          }>
                            {format_number(local_count)}
                          </span>
                        <% else %>
                          <span class="text-base-content/40 italic">none</span>
                        <% end %>
                      </td>
                      <td class="text-center">
                        <%= cond do %>
                          <% not has_local -> %>
                            <span class="badge badge-info badge-sm">new</span>
                          <% is_different -> %>
                            <span class="badge badge-warning badge-sm gap-1">
                              <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
                              {if sender_count > local_count,
                                do: "+#{format_number(sender_count - local_count)}",
                                else: "-#{format_number(local_count - sender_count)}"}
                            </span>
                          <% true -> %>
                            <span class="badge badge-success badge-sm gap-1">
                              <.icon name="hero-check" class="w-3 h-3" /> same
                            </span>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>

            <%!-- Summary Stats --%>
            <div class="mt-4 pt-4 border-t border-base-300">
              <div class="flex flex-wrap gap-4 text-sm">
                <.table_summary_stat
                  label="New tables"
                  count={count_new_tables(@tables, @local_counts)}
                  color="info"
                />
                <.table_summary_stat
                  label="Different"
                  count={count_different_tables(@tables, @local_counts)}
                  color="warning"
                />
                <.table_summary_stat
                  label="In sync"
                  count={count_same_tables(@tables, @local_counts)}
                  color="success"
                />
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp table_summary_stat(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class={"badge badge-#{@color} badge-sm"}>{@count}</span>
      <span class="text-base-content/70">{@label}</span>
    </div>
    """
  end

  defp render_table_details(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Table Selector --%>
      <div class="card bg-base-100 shadow-xl">
        <div class="card-body">
          <h3 class="text-lg font-bold mb-4">
            <.icon name="hero-table-cells" class="w-5 h-5 inline" /> Select Table
          </h3>

          <form phx-change="select_detail_table" class="form-control">
            <select class="select select-bordered w-full" name="table">
              <option value="">Choose a table...</option>
              <%= for table <- @tables do %>
                <% sender_count = table["estimated_count"] || 0 %>
                <% local_count = Map.get(@local_counts, table["name"]) %>
                <option value={table["name"]} selected={@selected_detail_table == table["name"]}>
                  {table["name"]} ({format_number(sender_count)} records<%= if local_count do %>
                    , {format_number(local_count)} local
                  <% end %>)
                </option>
              <% end %>
            </select>
          </form>
        </div>
      </div>

      <%= if @selected_detail_table do %>
        <%!-- Table Schema Info --%>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <h3 class="text-lg font-bold mb-4">
              <.icon name="hero-document-text" class="w-5 h-5 inline" /> Table:
              <span class="font-mono text-primary">{@selected_detail_table}</span>
            </h3>

            <%= if @loading_schema do %>
              <div class="flex items-center justify-center py-4">
                <span class="loading loading-spinner loading-md text-primary"></span>
                <span class="ml-2 text-base-content/70">Loading schema...</span>
              </div>
            <% else %>
              <% schema_columns = get_schema_columns(@detail_table_schema) %>
              <%= if length(schema_columns) > 0 do %>
                <div class="overflow-x-auto mb-4">
                  <table class="table table-xs">
                    <thead>
                      <tr>
                        <th>Column</th>
                        <th>Type</th>
                        <th>Nullable</th>
                        <th>Default</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for col <- schema_columns do %>
                        <tr>
                          <td class="font-mono text-xs">
                            {col["name"]}
                            <%= if col["primary_key"] do %>
                              <span class="badge badge-primary badge-xs ml-1">PK</span>
                            <% end %>
                          </td>
                          <td class="text-xs text-base-content/70">{col["type"]}</td>
                          <td class="text-xs">{if col["nullable"], do: "Yes", else: "No"}</td>
                          <td class="text-xs font-mono text-base-content/50">
                            {col["default"] || "-"}
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>

              <% table_info = get_table_info(@tables, @selected_detail_table) %>
              <% sender_count = (table_info && table_info["estimated_count"]) || 0 %>
              <% local_count = Map.get(@local_counts, @selected_detail_table) %>

              <div class="stats stats-horizontal shadow w-full mb-4">
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Sender Records</div>
                  <div class="stat-value text-lg text-primary">{format_number(sender_count)}</div>
                </div>
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Local Records</div>
                  <div class="stat-value text-lg text-success">
                    {if local_count, do: format_number(local_count), else: "N/A"}
                  </div>
                </div>
                <div class="stat py-2 px-4">
                  <div class="stat-title text-xs">Difference</div>
                  <div class={[
                    "stat-value text-lg",
                    local_count && local_count != sender_count && "text-warning"
                  ]}>
                    <%= if local_count do %>
                      {if sender_count >= local_count,
                        do: "+#{format_number(sender_count - local_count)}",
                        else: format_number(sender_count - local_count)}
                    <% else %>
                      N/A
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Table doesn't exist locally --%>
              <%= if not @local_table_exists do %>
                <div class="alert alert-warning">
                  <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                  <div>
                    <h3 class="font-bold">Table doesn't exist locally</h3>
                    <p class="text-sm">
                      The table <code class="font-mono">{@selected_detail_table}</code>
                      doesn't exist in your local database. Create it first to transfer data.
                    </p>
                  </div>
                  <button
                    phx-click="create_table"
                    class="btn btn-sm btn-primary"
                    disabled={@creating_table}
                  >
                    <%= if @creating_table do %>
                      <span class="loading loading-spinner loading-xs"></span> Creating...
                    <% else %>
                      <.icon name="hero-plus" class="w-4 h-4" /> Create Table
                    <% end %>
                  </button>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <%!-- Filter Options (only show if table exists) --%>
        <%= if @local_table_exists do %>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="text-lg font-bold mb-4">
                <.icon name="hero-funnel" class="w-5 h-5 inline" /> Filter Records
              </h3>

              <div class="form-control mb-4">
                <div class="flex flex-wrap gap-4">
                  <label class="label cursor-pointer gap-2">
                    <input
                      type="radio"
                      name="mode"
                      class="radio radio-primary"
                      value="all"
                      checked={@detail_filter.mode == :all}
                      phx-click="update_detail_filter"
                      phx-value-mode="all"
                    />
                    <span class="label-text">All Records</span>
                  </label>
                  <label class="label cursor-pointer gap-2">
                    <input
                      type="radio"
                      name="mode"
                      class="radio radio-primary"
                      value="ids"
                      checked={@detail_filter.mode == :ids}
                      phx-click="update_detail_filter"
                      phx-value-mode="ids"
                    />
                    <span class="label-text">Specific IDs</span>
                  </label>
                  <label class="label cursor-pointer gap-2">
                    <input
                      type="radio"
                      name="mode"
                      class="radio radio-primary"
                      value="range"
                      checked={@detail_filter.mode == :range}
                      phx-click="update_detail_filter"
                      phx-value-mode="range"
                    />
                    <span class="label-text">ID Range</span>
                  </label>
                </div>
              </div>

              <%= case @detail_filter.mode do %>
                <% :ids -> %>
                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Enter IDs (comma-separated)</span>
                    </label>
                    <textarea
                      class="textarea textarea-bordered h-24 font-mono"
                      placeholder="1, 2, 3, 10, 25..."
                      name="ids"
                      phx-change="update_detail_filter"
                      phx-debounce="300"
                    >{@detail_filter.ids}</textarea>
                    <label class="label">
                      <span class="label-text-alt text-base-content/50">
                        Enter the IDs you want to transfer, separated by commas or newlines
                      </span>
                    </label>
                  </div>
                <% :range -> %>
                  <div class="flex gap-4">
                    <div class="form-control flex-1">
                      <label class="label">
                        <span class="label-text">Start ID</span>
                      </label>
                      <input
                        type="number"
                        class="input input-bordered font-mono"
                        placeholder="1"
                        name="range_start"
                        value={@detail_filter.range_start}
                        phx-change="update_detail_filter"
                        phx-debounce="300"
                      />
                    </div>
                    <div class="form-control flex-1">
                      <label class="label">
                        <span class="label-text">End ID</span>
                      </label>
                      <input
                        type="number"
                        class="input input-bordered font-mono"
                        placeholder="100"
                        name="range_end"
                        value={@detail_filter.range_end}
                        phx-change="update_detail_filter"
                        phx-debounce="300"
                      />
                    </div>
                  </div>
                <% _ -> %>
                  <div class="alert alert-info">
                    <.icon name="hero-information-circle" class="w-5 h-5" />
                    <span>All records from this table will be transferred.</span>
                  </div>
              <% end %>

              <div class="flex gap-2 mt-4">
                <button
                  phx-click="preview_detail_records"
                  class="btn btn-outline btn-primary"
                  disabled={@loading_preview}
                >
                  <%= if @loading_preview do %>
                    <span class="loading loading-spinner loading-sm"></span>
                  <% else %>
                    <.icon name="hero-eye" class="w-4 h-4" />
                  <% end %>
                  Preview
                </button>
              </div>

              <%!-- Preview Results --%>
              <%= if @detail_preview do %>
                <div class="mt-4 pt-4 border-t border-base-300">
                  <p class="text-sm font-semibold mb-2">
                    Preview ({@detail_preview.total} matching records)
                  </p>
                  <%= if length(@detail_preview.records) > 0 do %>
                    <div class="overflow-x-auto max-h-64">
                      <table class="table table-xs">
                        <thead>
                          <tr>
                            <%= for key <- Map.keys(List.first(@detail_preview.records)) |> Enum.sort() |> Enum.take(6) do %>
                              <th class="text-xs">{key}</th>
                            <% end %>
                          </tr>
                        </thead>
                        <tbody>
                          <%= for record <- @detail_preview.records do %>
                            <tr>
                              <%= for key <- Map.keys(record) |> Enum.sort() |> Enum.take(6) do %>
                                <td class="text-xs font-mono max-w-32 truncate">
                                  {inspect(Map.get(record, key)) |> String.slice(0, 50)}
                                </td>
                              <% end %>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                    <%= if @detail_preview.total > 10 do %>
                      <p class="text-xs text-base-content/50 mt-2">
                        Showing first 10 of {@detail_preview.total} records
                      </p>
                    <% end %>
                  <% else %>
                    <div class="alert alert-warning">
                      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                      <span>No records match your filter criteria.</span>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Transfer Button --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h3 class="text-lg font-bold mb-4">
                <.icon name="hero-arrow-down-tray" class="w-5 h-5 inline" /> Transfer Options
              </h3>

              <%!-- Conflict Strategy --%>
              <div class="form-control mb-4">
                <label class="label">
                  <span class="label-text font-semibold">Conflict Resolution</span>
                </label>
                <div class="flex flex-wrap gap-4">
                  <label class="label cursor-pointer gap-2">
                    <input
                      type="radio"
                      name="conflict_strategy"
                      class="radio radio-primary"
                      value="skip"
                      checked={@conflict_strategy == :skip}
                      phx-click="set_conflict_strategy"
                      phx-value-strategy="skip"
                    />
                    <span class="label-text">Skip existing</span>
                  </label>
                  <label class="label cursor-pointer gap-2">
                    <input
                      type="radio"
                      name="conflict_strategy"
                      class="radio radio-primary"
                      value="overwrite"
                      checked={@conflict_strategy == :overwrite}
                      phx-click="set_conflict_strategy"
                      phx-value-strategy="overwrite"
                    />
                    <span class="label-text">Overwrite</span>
                  </label>
                  <label class="label cursor-pointer gap-2">
                    <input
                      type="radio"
                      name="conflict_strategy"
                      class="radio radio-primary"
                      value="merge"
                      checked={@conflict_strategy == :merge}
                      phx-click="set_conflict_strategy"
                      phx-value-strategy="merge"
                    />
                    <span class="label-text">Merge</span>
                  </label>
                  <label class="label cursor-pointer gap-2">
                    <input
                      type="radio"
                      name="conflict_strategy"
                      class="radio radio-primary"
                      value="append"
                      checked={@conflict_strategy == :append}
                      phx-click="set_conflict_strategy"
                      phx-value-strategy="append"
                    />
                    <span class="label-text">Append (new IDs)</span>
                  </label>
                </div>
              </div>

              <button phx-click="transfer_detail_table" class="btn btn-primary btn-lg w-full">
                <.icon name="hero-arrow-down-tray" class="w-5 h-5" />
                Transfer {@selected_detail_table}
                <%= case @detail_filter.mode do %>
                  <% :all -> %>
                    (All Records)
                  <% :ids -> %>
                    (Selected IDs)
                  <% :range -> %>
                    (ID Range)
                <% end %>
              </button>
            </div>
          </div>
        <% end %>
        <%!-- End of @local_table_exists condition --%>
      <% end %>
    </div>
    """
  end

  defp render_transfer_config(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h3 class="text-lg font-bold mb-4">
          <.icon name="hero-cog-6-tooth" class="w-5 h-5 inline" /> Transfer Configuration
        </h3>

        <%!-- Conflict Resolution --%>
        <div class="form-control mb-6">
          <label class="label">
            <span class="label-text font-semibold">Conflict Resolution</span>
          </label>
          <p class="text-sm text-base-content/70 mb-2">
            How to handle records that already exist (matching primary key)?
          </p>
          <div class="flex flex-wrap gap-4">
            <label class="label cursor-pointer gap-2">
              <input
                type="radio"
                name="conflict_strategy"
                class="radio radio-primary"
                value="skip"
                checked={@conflict_strategy == :skip}
                phx-click="set_conflict_strategy"
                phx-value-strategy="skip"
              />
              <span class="label-text">
                <strong>Skip</strong> - Keep existing records
              </span>
            </label>
            <label class="label cursor-pointer gap-2">
              <input
                type="radio"
                name="conflict_strategy"
                class="radio radio-primary"
                value="overwrite"
                checked={@conflict_strategy == :overwrite}
                phx-click="set_conflict_strategy"
                phx-value-strategy="overwrite"
              />
              <span class="label-text">
                <strong>Overwrite</strong> - Replace with new data
              </span>
            </label>
            <label class="label cursor-pointer gap-2">
              <input
                type="radio"
                name="conflict_strategy"
                class="radio radio-primary"
                value="merge"
                checked={@conflict_strategy == :merge}
                phx-click="set_conflict_strategy"
                phx-value-strategy="merge"
              />
              <span class="label-text">
                <strong>Merge</strong> - Update only non-null fields
              </span>
            </label>
            <label class="label cursor-pointer gap-2">
              <input
                type="radio"
                name="conflict_strategy"
                class="radio radio-primary"
                value="append"
                checked={@conflict_strategy == :append}
                phx-click="set_conflict_strategy"
                phx-value-strategy="append"
              />
              <span class="label-text">
                <strong>Append</strong> - Insert as new records with new IDs
              </span>
            </label>
          </div>
        </div>

        <%!-- Summary --%>
        <div class="bg-base-200 rounded-lg p-4 mb-6">
          <p class="font-semibold mb-2">Transfer Summary</p>
          <ul class="text-sm text-base-content/70 space-y-1">
            <li>Tables to transfer: {MapSet.size(@selected_tables)}</li>
            <li>Conflict strategy: {format_strategy(@conflict_strategy)}</li>
          </ul>
        </div>

        <%!-- Start Transfer Button --%>
        <div class="flex justify-end">
          <button phx-click="start_transfer" class="btn btn-primary btn-lg">
            <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> Start Transfer
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp render_transfer_progress(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body items-center text-center">
        <%= if @transfer_progress.status == :completed do %>
          <div class="text-6xl mb-4">🎉</div>
          <h3 class="text-2xl font-bold text-success mb-4">Transfer Complete!</h3>
          <p class="text-base-content/70 mb-4">
            Successfully queued data import from {@transfer_progress.total_tables} table(s).
          </p>
          <div class="stats shadow mb-6">
            <div class="stat">
              <div class="stat-title">Records Fetched</div>
              <div class="stat-value text-primary">
                {format_number(Map.get(@transfer_progress, :records_fetched, 0))}
              </div>
            </div>
            <div class="stat">
              <div class="stat-title">Import Jobs Queued</div>
              <div class="stat-value text-success">
                {Map.get(@transfer_progress, :jobs_queued, 0)}
              </div>
            </div>
          </div>
          <div class="alert alert-info text-left mb-6">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <div>
              <p class="font-semibold">Import jobs are processing in the background</p>
              <p class="text-sm">
                You can safely close this page. Check the Jobs module (coming soon) or server logs
                to monitor import progress.
              </p>
            </div>
          </div>
          <button phx-click="cancel" class="btn btn-primary">
            Done
          </button>
        <% else %>
          <span class="loading loading-spinner loading-lg text-primary mb-4"></span>
          <h3 class="text-xl font-bold mb-2">
            <%= case @transfer_progress.status do %>
              <% :fetching_schemas -> %>
                Preparing Transfer...
              <% :fetching -> %>
                Fetching Data...
              <% _ -> %>
                Transferring Data...
            <% end %>
          </h3>
          <p class="text-base-content/70 mb-4">
            <%= cond do %>
              <% @transfer_progress.status == :fetching_schemas -> %>
                Loading table structures...
                <span class="text-sm ml-2">
                  ({@transfer_progress.total_tables - length(@pending_schemas)}/{@transfer_progress.total_tables})
                </span>
              <% @transfer_progress.current_table -> %>
                Fetching from: <span class="font-mono">{@transfer_progress.current_table}</span>
              <% true -> %>
                Starting...
            <% end %>
          </p>
          <progress
            class="progress progress-primary w-full max-w-md"
            value={
              if @transfer_progress.status == :fetching_schemas,
                do: @transfer_progress.total_tables - length(@pending_schemas),
                else: @transfer_progress.tables_done
            }
            max={@transfer_progress.total_tables}
          >
          </progress>
          <p class="text-sm text-base-content/50 mt-2">
            <%= if @transfer_progress.status == :fetching_schemas do %>
              {@transfer_progress.total_tables - length(@pending_schemas)} / {@transfer_progress.total_tables} schemas loaded
            <% else %>
              {@transfer_progress.tables_done} / {@transfer_progress.total_tables} tables
            <% end %>
          </p>
          <div class="stats stats-horizontal shadow mt-4">
            <div class="stat py-2 px-4">
              <div class="stat-title text-xs">Records</div>
              <div class="stat-value text-lg">
                {format_number(Map.get(@transfer_progress, :records_fetched, 0))}
              </div>
            </div>
            <div class="stat py-2 px-4">
              <div class="stat-title text-xs">Jobs Queued</div>
              <div class="stat-value text-lg">{Map.get(@transfer_progress, :jobs_queued, 0)}</div>
            </div>
          </div>
          <p class="text-xs text-base-content/50 mt-4">
            <.icon name="hero-exclamation-triangle" class="w-3 h-3 inline" />
            Please keep this page open. Transfer cannot be cancelled once started.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  # ===========================================
  # HELPERS
  # ===========================================

  defp fetch_next_table(socket) do
    progress = socket.assigns.transfer_progress
    tables_pending = progress.tables_pending

    case tables_pending do
      [table | _rest] ->
        # Start fetching first batch of records
        WebSocketClient.request_records(socket.assigns.ws_client, table,
          offset: 0,
          limit: @batch_size
        )

        assign(socket, :transfer_progress, %{
          progress
          | current_table: table,
            pending_fetch: {table, 0}
        })

      [] ->
        # No more tables to fetch
        complete_transfer(socket)
    end
  end

  defp queue_import_job(table, records, strategy, batch_index, opts) do
    # Generate a simple session code for tracking
    session_code = "transfer_#{:os.system_time(:millisecond)}"
    schema = Keyword.get(opts, :schema)

    job_opts = [batch_index: div(batch_index, @batch_size)]
    job_opts = if schema, do: Keyword.put(job_opts, :schema, schema), else: job_opts

    ImportWorker.create_job(table, records, strategy, session_code, job_opts)
    |> Oban.insert()
  end

  defp complete_transfer(socket) do
    progress = socket.assigns.transfer_progress

    socket
    |> assign(:transferring, false)
    |> assign(:transfer_progress, %{progress | status: :completed})
    |> put_flash(:info, transfer_summary_message(progress))
  end

  defp transfer_summary_message(progress) do
    jobs = Map.get(progress, :jobs_queued, 0)
    records = Map.get(progress, :records_fetched, 0)
    tables = Map.get(progress, :total_tables, 0)

    if jobs > 0 do
      "Transfer queued! #{jobs} import job(s) for #{records} records from #{tables} table(s) are being processed in the background."
    else
      "Transfer complete. No records were found to import."
    end
  end

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(_), do: "?"

  defp format_strategy(:skip), do: "Skip existing"
  defp format_strategy(:overwrite), do: "Overwrite existing"
  defp format_strategy(:merge), do: "Merge data"
  defp format_strategy(:append), do: "Append (new IDs)"

  defp format_connection_error(:join_timeout),
    do: "Connection timed out. Please check the URL and code."

  defp format_connection_error(%{"message" => msg}), do: msg

  defp format_connection_error({:error, :econnrefused}),
    do: "Could not connect to sender. Please check the URL."

  defp format_connection_error({:error, :nxdomain}),
    do: "Could not find the sender's server. Please check the URL."

  defp format_connection_error({:error, :timeout}),
    do: "Connection timed out. Please try again."

  defp format_connection_error(%WebSockex.ConnError{original: original}),
    do: format_connection_error(original)

  defp format_connection_error(reason) when is_binary(reason), do: reason

  defp format_connection_error(reason), do: "Connection failed: #{inspect(reason)}"

  defp get_current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %Scope{user: user} when not is_nil(user) ->
        %{
          email: user.email,
          name: Map.get(user, :name) || user.email
        }

      _ ->
        nil
    end
  end

  defp fetch_local_counts(tables) do
    Enum.reduce(tables, %{}, fn table, acc ->
      case SchemaInspector.get_local_count(table["name"]) do
        {:ok, count} -> Map.put(acc, table["name"], count)
        _ -> acc
      end
    end)
  end

  defp count_new_tables(tables, local_counts) do
    Enum.count(tables, fn table ->
      not Map.has_key?(local_counts, table["name"])
    end)
  end

  defp count_different_tables(tables, local_counts) do
    Enum.count(tables, fn table ->
      name = table["name"]
      local_count = Map.get(local_counts, name)
      sender_count = table["estimated_count"] || 0

      not is_nil(local_count) and local_count != sender_count
    end)
  end

  defp count_same_tables(tables, local_counts) do
    Enum.count(tables, fn table ->
      name = table["name"]
      local_count = Map.get(local_counts, name)
      sender_count = table["estimated_count"] || 0

      not is_nil(local_count) and local_count == sender_count
    end)
  end

  # Parse a comma-separated list of IDs into integers
  defp parse_id_list(ids_string) when is_binary(ids_string) do
    ids_string
    |> String.split([",", " ", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&parse_int(&1, nil))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_id_list(_), do: []

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  # Get the ID from a record (assumes "id" key exists)
  defp get_record_id(record) when is_map(record) do
    Map.get(record, "id") || Map.get(record, :id)
  end

  defp get_record_id(_), do: nil

  # Get table info by name from tables list
  defp get_table_info(tables, table_name) do
    Enum.find(tables, fn t -> t["name"] == table_name end)
  end

  # Get schema columns, handling both atom and string keys
  defp get_schema_columns(nil), do: []

  defp get_schema_columns(schema) when is_map(schema) do
    # Try both atom and string keys (data comes through JSON as strings)
    Map.get(schema, :columns) || Map.get(schema, "columns") || []
  end

  defp get_schema_columns(_), do: []

  # Filter records based on filter mode
  defp filter_records_by_mode(records, %{mode: :ids, ids: ids_string}) do
    ids = parse_id_list(ids_string)

    if Enum.empty?(ids) do
      records
    else
      Enum.filter(records, fn r -> get_record_id(r) in ids end)
    end
  end

  defp filter_records_by_mode(records, _filter), do: records
end
