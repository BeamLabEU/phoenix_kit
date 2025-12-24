defmodule PhoenixKitWeb.Live.Modules.DBSync.ConnectionsLive do
  @moduledoc """
  LiveView for managing DB Sync permanent connections.

  Allows creating, editing, and managing persistent connections between
  PhoenixKit instances with access control settings.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.DBSync
  alias PhoenixKit.DBSync.Connection
  alias PhoenixKit.DBSync.ConnectionNotifier
  alias PhoenixKit.DBSync.Connections
  alias PhoenixKit.DBSync.SchemaInspector
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    locale = params["locale"] || "en"
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    config = DBSync.get_config()

    # Subscribe to connection updates
    if connected?(socket) do
      pubsub = PhoenixKit.Config.pubsub_server()

      if pubsub do
        Phoenix.PubSub.subscribe(pubsub, "db_sync:connections")
      end
    end

    socket =
      socket
      |> assign(:page_title, "Connections")
      |> assign(:project_title, project_title)
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/db-sync/connections", locale: locale))
      |> assign(:config, config)
      |> assign(:view_mode, :list)
      |> assign(:selected_connection, nil)
      |> assign(:changeset, nil)
      |> assign(:direction_filter, nil)
      |> assign(:sender_statuses, %{})
      |> load_connections()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    action = params["action"]
    id = params["id"]
    socket = handle_action(socket, action, id, params)
    {:noreply, socket}
  end

  defp handle_action(socket, "new", _id, _params) do
    changeset = Connection.changeset(%Connection{}, %{"direction" => "sender"})

    socket
    |> assign(:view_mode, :new)
    |> assign(:changeset, changeset)
  end

  defp handle_action(socket, "edit", id, _params) when not is_nil(id) do
    handle_connection_action(socket, id, :edit)
  end

  defp handle_action(socket, "show", id, _params) when not is_nil(id) do
    handle_connection_action(socket, id, :show)
  end

  defp handle_action(socket, "sync", id, _params) when not is_nil(id) do
    handle_sync_action(socket, id)
  end

  defp handle_action(socket, _action, _id, params) do
    socket
    |> assign(:view_mode, :list)
    |> assign(:selected_connection, nil)
    |> assign(:changeset, nil)
    |> assign(:direction_filter, params["direction"])
    |> load_connections()
  end

  defp handle_connection_action(socket, id, mode) do
    case Connections.get_connection(String.to_integer(id)) do
      nil ->
        socket
        |> put_flash(:error, "Connection not found")
        |> assign(:view_mode, :list)
        |> load_connections()

      connection ->
        setup_connection_view(socket, connection, mode)
    end
  end

  defp setup_connection_view(socket, connection, :edit) do
    changeset = Connection.settings_changeset(connection, %{})

    socket
    |> assign(:view_mode, :edit)
    |> assign(:selected_connection, connection)
    |> assign(:changeset, changeset)
  end

  defp setup_connection_view(socket, connection, :show) do
    socket
    |> assign(:view_mode, :show)
    |> assign(:selected_connection, connection)
  end

  defp handle_sync_action(socket, id) do
    case Connections.get_connection(String.to_integer(id)) do
      nil ->
        socket
        |> put_flash(:error, "Connection not found")
        |> assign(:view_mode, :list)
        |> load_connections()

      connection ->
        setup_sync_view(socket, connection)
    end
  end

  defp setup_sync_view(socket, connection) do
    send(self(), {:fetch_sender_tables, connection})

    socket
    |> assign(:view_mode, :sync)
    |> assign(:selected_connection, connection)
    |> assign(:sync_tables, [])
    |> assign(:sync_local_counts, %{})
    |> assign(:sync_loading, true)
    |> assign(:sync_error, nil)
    |> assign(:selected_sync_tables, MapSet.new())
    |> assign(:sync_in_progress, false)
    |> assign(:sync_progress, nil)
    |> assign(:conflict_strategy, connection.default_conflict_strategy || "skip")
    |> assign(:sync_active_tab, :bulk)
    |> assign(:selected_detail_table, nil)
    |> assign(:detail_table_schema, nil)
    |> assign(:detail_filter, %{mode: :all, ids: "", range_start: "", range_end: ""})
    |> assign(:detail_preview, nil)
    |> assign(:loading_schema, false)
    |> assign(:loading_preview, false)
    |> assign(:local_table_exists, true)
    |> assign(:creating_table, false)
  end

  defp load_connections(socket, opts \\ []) do
    direction = socket.assigns[:direction_filter]
    filter_opts = if direction, do: [direction: direction], else: []

    sender_connections =
      Connections.list_connections(Keyword.put(filter_opts, :direction, "sender"))

    receiver_connections =
      Connections.list_connections(Keyword.put(filter_opts, :direction, "receiver"))

    # Only do async HTTP calls on initial load, not on PubSub updates
    # This prevents feedback loops where status queries trigger broadcasts
    unless Keyword.get(opts, :skip_async, false) do
      # Fetch sender statuses for receiver connections (async)
      fetch_sender_statuses(receiver_connections)

      # Verify receiver connections still exist for sender connections (async)
      # This handles cases where receiver severed but notification was missed
      verify_receiver_connections(sender_connections)
    end

    socket
    |> assign(:sender_connections, sender_connections)
    |> assign(:receiver_connections, receiver_connections)
  end

  defp fetch_sender_statuses(receiver_connections) do
    pid = self()

    Enum.each(receiver_connections, fn conn ->
      Task.start(fn ->
        case ConnectionNotifier.query_sender_status(conn) do
          {:ok, status} when is_binary(status) ->
            send(pid, {:sender_status_fetched, conn.id, status})

          {:ok, :offline} ->
            send(pid, {:sender_status_fetched, conn.id, "offline"})

          {:ok, :not_found} ->
            send(pid, {:sender_status_fetched, conn.id, "not_found"})

          {:error, _reason} ->
            send(pid, {:sender_status_fetched, conn.id, "error"})
        end
      end)
    end)
  end

  defp verify_receiver_connections(sender_connections) do
    pid = self()

    Enum.each(sender_connections, fn conn ->
      if should_verify_connection?(conn) do
        verify_single_connection(conn, pid)
      end
    end)
  end

  defp should_verify_connection?(conn) do
    notification_success =
      get_in(conn.metadata || %{}, ["remote_notification", "notification_success"])

    conn.status in ["active", "pending", "suspended"] && notification_success == true
  end

  defp verify_single_connection(conn, pid) do
    Task.start(fn ->
      handle_verification_result(ConnectionNotifier.verify_connection(conn), conn.id, pid)
    end)
  end

  defp handle_verification_result({:ok, :not_found}, conn_id, pid) do
    send(pid, {:receiver_connection_severed, conn_id})
  end

  defp handle_verification_result(_result, _conn_id, _pid), do: :ok

  @impl true
  def handle_event("filter", %{"direction" => direction}, socket) do
    params = if direction != "", do: %{direction: direction}, else: %{}
    path = path_with_params("/admin/db-sync/connections", params)
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("new_connection", _params, socket) do
    path = path_with_params("/admin/db-sync/connections", %{action: "new"})
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("show_connection", %{"id" => id}, socket) do
    path = path_with_params("/admin/db-sync/connections", %{action: "show", id: id})
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("edit_connection", %{"id" => id}, socket) do
    path = path_with_params("/admin/db-sync/connections", %{action: "edit", id: id})
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("cancel", _params, socket) do
    path = Routes.path("/admin/db-sync/connections")
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("validate", %{"connection" => params}, socket) do
    changeset =
      case socket.assigns.view_mode do
        :new ->
          %Connection{}
          |> Connection.changeset(params)
          |> Map.put(:action, :validate)

        :edit ->
          socket.assigns.selected_connection
          |> Connection.settings_changeset(params)
          |> Map.put(:action, :validate)
      end

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"connection" => params}, socket) do
    case socket.assigns.view_mode do
      :new -> do_create_connection(socket, params)
      :edit -> do_update_connection(socket, params)
    end
  end

  def handle_event("approve_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))
    current_user = socket.assigns.phoenix_kit_current_scope.user

    case Connections.approve_connection(connection, current_user.id) do
      {:ok, updated_connection} ->
        # Notify receiver of status change (async)
        Task.start(fn ->
          ConnectionNotifier.notify_status_change(updated_connection, "active")
        end)

        socket =
          socket
          |> put_flash(:info, "Connection approved")
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to approve connection")}
    end
  end

  def handle_event("suspend_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))
    current_user = socket.assigns.phoenix_kit_current_scope.user

    case Connections.suspend_connection(connection, current_user.id) do
      {:ok, updated_connection} ->
        # Notify receiver of status change (async)
        Task.start(fn ->
          ConnectionNotifier.notify_status_change(updated_connection, "suspended")
        end)

        socket =
          socket
          |> put_flash(:info, "Connection suspended")
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to suspend connection")}
    end
  end

  def handle_event("reactivate_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))

    case Connections.reactivate_connection(connection) do
      {:ok, updated_connection} ->
        # Notify receiver of status change (async)
        Task.start(fn ->
          ConnectionNotifier.notify_status_change(updated_connection, "active")
        end)

        socket =
          socket
          |> put_flash(:info, "Connection reactivated")
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to reactivate connection")}
    end
  end

  def handle_event("revoke_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))
    current_user = socket.assigns.phoenix_kit_current_scope.user

    case Connections.revoke_connection(connection, current_user.id, "Revoked by admin") do
      {:ok, updated_connection} ->
        # Notify receiver of status change (async)
        Task.start(fn ->
          ConnectionNotifier.notify_status_change(updated_connection, "revoked")
        end)

        socket =
          socket
          |> put_flash(:info, "Connection revoked")
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to revoke connection")}
    end
  end

  def handle_event("regenerate_token", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))

    case Connections.regenerate_token(connection) do
      {:ok, _connection, _new_token} ->
        socket =
          socket
          |> put_flash(:info, "Token regenerated")
          |> load_connections()

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to regenerate token")}
    end
  end

  def handle_event("delete_connection", %{"id" => id}, socket) do
    connection = Connections.get_connection!(String.to_integer(id))

    # If receiver is severing, notify the sender first
    if connection.direction == "receiver" do
      Task.start(fn ->
        ConnectionNotifier.notify_delete(connection)
      end)
    end

    case Connections.delete_connection(connection) do
      {:ok, _connection} ->
        message =
          if connection.direction == "receiver",
            do: "Connection severed",
            else: "Connection deleted"

        socket =
          socket
          |> put_flash(:info, message)
          |> load_connections()

        path = Routes.path("/admin/db-sync/connections")
        {:noreply, push_patch(socket, to: path)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete connection")}
    end
  end

  def handle_event("start_sync", %{"id" => id}, socket) do
    path = path_with_params("/admin/db-sync/connections", %{action: "sync", id: id})
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("refresh_tables", _params, socket) do
    connection = socket.assigns.selected_connection
    socket = assign(socket, :sync_loading, true)
    send(self(), {:fetch_sender_tables, connection})
    {:noreply, socket}
  end

  def handle_event("toggle_table", %{"table" => table_name}, socket) do
    selected = socket.assigns.selected_sync_tables

    selected =
      if MapSet.member?(selected, table_name) do
        MapSet.delete(selected, table_name)
      else
        MapSet.put(selected, table_name)
      end

    {:noreply, assign(socket, :selected_sync_tables, selected)}
  end

  def handle_event("toggle_all_tables", _params, socket) do
    tables = socket.assigns.sync_tables
    selected = socket.assigns.selected_sync_tables
    all_names = Enum.map(tables, fn t -> t.name || t["name"] end) |> MapSet.new()

    selected =
      if MapSet.equal?(selected, all_names) do
        MapSet.new()
      else
        all_names
      end

    {:noreply, assign(socket, :selected_sync_tables, selected)}
  end

  def handle_event("select_all_tables", _params, socket) do
    tables = socket.assigns.sync_tables
    all_names = Enum.map(tables, fn t -> t.name || t["name"] end) |> MapSet.new()
    {:noreply, assign(socket, :selected_sync_tables, all_names)}
  end

  def handle_event("deselect_all_tables", _params, socket) do
    {:noreply, assign(socket, :selected_sync_tables, MapSet.new())}
  end

  def handle_event("select_different_tables", _params, socket) do
    # Select tables that either don't exist locally or have different counts
    different_tables =
      socket.assigns.sync_tables
      |> Enum.filter(fn table ->
        name = table.name || table["name"]
        sender_count = table.row_count || table["row_count"] || 0
        local_count = Map.get(socket.assigns.sync_local_counts, name)

        # Select if: no local table, or counts differ
        is_nil(local_count) or local_count != sender_count
      end)
      |> Enum.map(fn t -> t.name || t["name"] end)

    {:noreply, assign(socket, :selected_sync_tables, MapSet.new(different_tables))}
  end

  def handle_event("change_conflict_strategy", %{"strategy" => strategy}, socket) do
    {:noreply, assign(socket, :conflict_strategy, strategy)}
  end

  def handle_event("execute_sync", _params, socket) do
    selected_tables = socket.assigns.selected_sync_tables |> MapSet.to_list()

    if Enum.empty?(selected_tables) do
      {:noreply, put_flash(socket, :error, "Please select at least one table")}
    else
      socket =
        socket
        |> assign(:sync_in_progress, true)
        |> assign(:sync_progress, %{
          total: length(selected_tables),
          current: 0,
          tables_done: 0,
          records_fetched: 0,
          table: nil,
          status: :running
        })

      # Start the sync process
      send(self(), {:do_pull_table, selected_tables, 0})

      {:noreply, socket}
    end
  end

  # Precise Transfer Tab Events
  def handle_event("switch_sync_tab", %{"tab" => "bulk"}, socket) do
    {:noreply, assign(socket, :sync_active_tab, :bulk)}
  end

  def handle_event("switch_sync_tab", %{"tab" => "details"}, socket) do
    {:noreply, assign(socket, :sync_active_tab, :details)}
  end

  def handle_event("select_detail_table", %{"table" => ""}, socket) do
    socket =
      socket
      |> assign(:selected_detail_table, nil)
      |> assign(:detail_table_schema, nil)
      |> assign(:detail_preview, nil)
      |> assign(:detail_filter, %{mode: :all, ids: "", range_start: "", range_end: ""})

    {:noreply, socket}
  end

  def handle_event("select_detail_table", %{"table" => table_name}, socket) do
    connection = socket.assigns.selected_connection

    socket =
      socket
      |> assign(:selected_detail_table, table_name)
      |> assign(:loading_schema, true)
      |> assign(:detail_table_schema, nil)
      |> assign(:detail_preview, nil)
      |> assign(:detail_filter, %{mode: :all, ids: "", range_start: "", range_end: ""})

    # Fetch schema for the selected table
    send(self(), {:fetch_table_schema, connection, table_name})

    {:noreply, socket}
  end

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
      range_end: params["range_end"] || socket.assigns.detail_filter.range_end
    }

    {:noreply, assign(socket, :detail_filter, filter)}
  end

  def handle_event("preview_detail_records", _params, socket) do
    table = socket.assigns.selected_detail_table
    connection = socket.assigns.selected_connection

    if table do
      socket = assign(socket, :loading_preview, true)
      send(self(), {:fetch_preview_records, connection, table, socket.assigns.detail_filter})
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_detail_table", _params, socket) do
    table = socket.assigns.selected_detail_table
    schema = socket.assigns.detail_table_schema

    if table && schema do
      socket = assign(socket, :creating_table, true)

      # Create the table locally based on schema
      case SchemaInspector.create_table(table, schema) do
        :ok ->
          socket =
            socket
            |> assign(:creating_table, false)
            |> assign(:local_table_exists, true)
            |> put_flash(:info, "Table #{table} created successfully")

          {:noreply, socket}

        {:error, reason} ->
          socket =
            socket
            |> assign(:creating_table, false)
            |> put_flash(:error, "Failed to create table: #{inspect(reason)}")

          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("transfer_detail_table", _params, socket) do
    table = socket.assigns.selected_detail_table
    connection = socket.assigns.selected_connection
    filter = socket.assigns.detail_filter

    if table do
      socket =
        socket
        |> assign(:sync_in_progress, true)
        |> assign(:sync_progress, %{
          total: 1,
          current: 1,
          tables_done: 0,
          records_fetched: 0,
          table: table,
          status: :running
        })

      # Start the transfer
      send(self(), {:start_detail_sync, connection, table, filter})

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ===========================================
  # HANDLE_INFO CALLBACKS FOR SYNC
  # ===========================================

  @impl true
  def handle_info({:fetch_sender_tables, connection}, socket) do
    liveview_pid = self()

    Task.start(fn ->
      result = ConnectionNotifier.fetch_sender_tables(connection)
      send(liveview_pid, {:sender_tables_result, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sender_tables_result, result}, socket) do
    socket =
      case result do
        {:ok, tables} ->
          # Get local counts for comparison
          local_counts =
            tables
            |> Enum.map(fn t ->
              name = t.name || t["name"]

              count =
                case SchemaInspector.get_local_count(name) do
                  {:ok, c} -> c
                  {:error, _} -> nil
                end

              {name, count}
            end)
            |> Enum.into(%{})

          socket
          |> assign(:sync_tables, tables)
          |> assign(:sync_local_counts, local_counts)
          |> assign(:sync_loading, false)
          |> assign(:sync_error, nil)

        {:error, :offline} ->
          socket
          |> assign(:sync_loading, false)
          |> assign(:sync_error, "Sender site is offline or unreachable")

        {:error, reason} ->
          socket
          |> assign(:sync_loading, false)
          |> assign(:sync_error, "Failed to fetch tables: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:fetch_table_schema, connection, table_name}, socket) do
    liveview_pid = self()

    Task.start(fn ->
      result = ConnectionNotifier.fetch_table_schema(connection, table_name)
      send(liveview_pid, {:table_schema_result, table_name, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:table_schema_result, table_name, result}, socket) do
    # Only update if still on the same table
    if socket.assigns.selected_detail_table == table_name do
      socket =
        case result do
          {:ok, schema} ->
            local_exists = SchemaInspector.table_exists?(table_name)

            socket
            |> assign(:detail_table_schema, schema)
            |> assign(:loading_schema, false)
            |> assign(:local_table_exists, local_exists)

          {:error, reason} ->
            socket
            |> assign(:detail_table_schema, nil)
            |> assign(:loading_schema, false)
            |> put_flash(:error, "Failed to load schema: #{inspect(reason)}")
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:fetch_preview_records, connection, table_name, filter}, socket) do
    liveview_pid = self()

    Task.start(fn ->
      opts =
        case filter.mode do
          :all ->
            [limit: 10]

          :ids ->
            [ids: parse_id_list(filter.ids), limit: 10]

          :range ->
            [id_range: {parse_int(filter.range_start), parse_int(filter.range_end)}, limit: 10]
        end

      result = ConnectionNotifier.fetch_table_records(connection, table_name, opts)
      send(liveview_pid, {:preview_records_result, table_name, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:preview_records_result, table_name, result}, socket) do
    if socket.assigns.selected_detail_table == table_name do
      socket =
        case result do
          {:ok, records} ->
            socket
            |> assign(:detail_preview, %{records: Enum.take(records, 10), total: length(records)})
            |> assign(:loading_preview, false)

          {:error, reason} ->
            socket
            |> assign(:detail_preview, nil)
            |> assign(:loading_preview, false)
            |> put_flash(:error, "Failed to load preview: #{inspect(reason)}")
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:start_detail_sync, connection, table, filter}, socket) do
    liveview_pid = self()
    strategy = socket.assigns.conflict_strategy

    Task.start(fn ->
      opts =
        case filter.mode do
          :all ->
            [conflict_strategy: strategy]

          :ids ->
            [conflict_strategy: strategy, ids: parse_id_list(filter.ids)]

          :range ->
            [
              conflict_strategy: strategy,
              id_range: {parse_int(filter.range_start), parse_int(filter.range_end)}
            ]
        end

      result = ConnectionNotifier.pull_table_data(connection, table, opts)
      send(liveview_pid, {:sync_table_complete, table, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:do_pull_table, [], _index}, socket) do
    # All tables done
    progress = Map.put(socket.assigns.sync_progress, :status, :completed)

    socket =
      socket
      |> assign(:sync_in_progress, false)
      |> assign(:sync_progress, progress)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:do_pull_table, [table | rest], index}, socket) do
    liveview_pid = self()
    connection = socket.assigns.selected_connection
    strategy = socket.assigns.conflict_strategy

    progress =
      socket.assigns.sync_progress
      |> Map.put(:current, index + 1)
      |> Map.put(:table, table)

    socket = assign(socket, :sync_progress, progress)

    Task.start(fn ->
      result = ConnectionNotifier.pull_table_data(connection, table, conflict_strategy: strategy)
      send(liveview_pid, {:sync_table_complete, table, result, rest, index + 1})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_table_complete, _table, result, rest, index}, socket) do
    records_fetched =
      case result do
        {:ok, %{imported: count}} -> count
        _ -> 0
      end

    progress =
      socket.assigns.sync_progress
      |> Map.update(:tables_done, 1, &(&1 + 1))
      |> Map.update(:records_fetched, records_fetched, &(&1 + records_fetched))

    socket = assign(socket, :sync_progress, progress)

    # Continue with next table
    send(self(), {:do_pull_table, rest, index})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_table_complete, _table, result}, socket) do
    # Single table sync (from precise transfer)
    records_fetched =
      case result do
        {:ok, %{imported: count}} -> count
        _ -> 0
      end

    progress =
      socket.assigns.sync_progress
      |> Map.put(:tables_done, 1)
      |> Map.put(:records_fetched, records_fetched)
      |> Map.put(:status, :completed)

    socket =
      socket
      |> assign(:sync_in_progress, false)
      |> assign(:sync_progress, progress)

    {:noreply, socket}
  end

  def handle_info({:sender_status_fetched, connection_id, status}, socket) do
    # Store the sender's status in the sender_statuses map
    sender_statuses = Map.put(socket.assigns.sender_statuses, connection_id, status)
    {:noreply, assign(socket, :sender_statuses, sender_statuses)}
  end

  def handle_info({:receiver_connection_severed, connection_id}, socket) do
    # Receiver severed their connection - delete our sender connection
    case Connections.get_connection(connection_id) do
      nil ->
        # Already deleted
        {:noreply, socket}

      connection ->
        case Connections.delete_connection(connection) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Connection '#{connection.name}' was severed by remote site")
              |> load_connections()

            {:noreply, socket}

          {:error, _} ->
            {:noreply, socket}
        end
    end
  end

  # PubSub handlers for real-time updates
  # Use skip_async: true to prevent feedback loops - just reload from DB without
  # triggering HTTP calls that could cause more broadcasts
  def handle_info({:connection_created, _connection_id}, socket) do
    {:noreply, load_connections(socket, skip_async: true)}
  end

  def handle_info({:connection_status_changed, _connection_id, _status}, socket) do
    {:noreply, load_connections(socket, skip_async: true)}
  end

  # ===========================================
  # PRIVATE HELPERS FOR SAVE
  # ===========================================

  defp do_create_connection(socket, params) do
    current_user = socket.assigns.phoenix_kit_current_scope.user
    params = Map.put(params, "created_by", current_user.id)

    case Connections.create_connection(params) do
      {:ok, connection, token} ->
        # Notify the remote site to register this connection (async)
        if connection.direction == "sender" do
          Task.start(fn ->
            result = ConnectionNotifier.notify_remote_site(connection, token)
            Logger.info("DBSync: Remote notification result: #{inspect(result)}")
          end)
        end

        socket =
          socket
          |> put_flash(:info, "Connection created successfully")
          |> load_connections()

        path = Routes.path("/admin/db-sync/connections")
        {:noreply, push_patch(socket, to: path)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp do_update_connection(socket, params) do
    case Connections.update_connection(socket.assigns.selected_connection, params) do
      {:ok, _connection} ->
        socket =
          socket
          |> put_flash(:info, "Connection updated successfully")
          |> load_connections()

        path = Routes.path("/admin/db-sync/connections")
        {:noreply, push_patch(socket, to: path)}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Connections"
      current_path={@current_path}
      project_title={@project_title}
      current_locale={@current_locale}
    >
      <div class="container flex flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <.link
            navigate={Routes.path("/admin/db-sync", locale: @current_locale)}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> Back to DB Sync
          </.link>

          <div class="text-center">
            <h1 class="text-3xl font-bold text-base-content mb-2">Connections</h1>
            <p class="text-base-content/70">
              Manage permanent connections for data sync
            </p>
          </div>
        </header>

        <%= if not @config.enabled do %>
          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>DB Sync module is disabled.</span>
          </div>
        <% end %>

        <%= case @view_mode do %>
          <% :list -> %>
            <.connections_list
              sender_connections={@sender_connections}
              receiver_connections={@receiver_connections}
              direction_filter={@direction_filter}
              sender_statuses={@sender_statuses}
            />
          <% :new -> %>
            <.connection_form changeset={@changeset} action={:new} />
          <% :edit -> %>
            <.connection_form
              changeset={@changeset}
              action={:edit}
              connection={@selected_connection}
            />
          <% :show -> %>
            <.connection_details connection={@selected_connection} />
          <% :sync -> %>
            <.sync_view
              connection={@selected_connection}
              tables={@sync_tables}
              local_counts={@sync_local_counts}
              loading={@sync_loading}
              error={@sync_error}
              selected_tables={@selected_sync_tables}
              sync_in_progress={@sync_in_progress}
              progress={@sync_progress}
              conflict_strategy={@conflict_strategy}
              active_tab={@sync_active_tab}
              selected_detail_table={@selected_detail_table}
              detail_table_schema={@detail_table_schema}
              detail_filter={@detail_filter}
              detail_preview={@detail_preview}
              loading_schema={@loading_schema}
              loading_preview={@loading_preview}
              local_table_exists={@local_table_exists}
              creating_table={@creating_table}
            />
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  # ===========================================
  # LIST VIEW
  # ===========================================

  defp connections_list(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Actions Bar --%>
      <div class="flex justify-between items-center">
        <div class="flex gap-2">
          <select
            class="select select-bordered select-sm"
            phx-change="filter"
            name="direction"
          >
            <option value="" selected={@direction_filter == nil}>All Directions</option>
            <option value="sender" selected={@direction_filter == "sender"}>Senders Only</option>
            <option value="receiver" selected={@direction_filter == "receiver"}>
              Receivers Only
            </option>
          </select>
        </div>
        <button type="button" phx-click="new_connection" class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> New Connection
        </button>
      </div>

      <%!-- Sender Connections --%>
      <%= if @direction_filter != "receiver" do %>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title">
              <.icon name="hero-arrow-up-tray" class="w-5 h-5" /> Sender Connections
              <span class="badge badge-ghost">{length(@sender_connections)}</span>
            </h2>
            <p class="text-sm text-base-content/70 mb-4">
              Sites that can pull data from this site
            </p>

            <%= if Enum.empty?(@sender_connections) do %>
              <p class="text-center text-base-content/50 py-4">
                No sender connections configured
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Site URL</th>
                      <th>Status</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for conn <- @sender_connections do %>
                      <tr>
                        <td class="font-semibold">{conn.name}</td>
                        <td class="text-sm font-mono">{conn.site_url}</td>
                        <td><.status_badge status={conn.status} /></td>
                        <td>
                          <.connection_actions connection={conn} />
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%!-- Receiver Connections --%>
      <%= if @direction_filter != "sender" do %>
        <div class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title">
              <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> Receiver Connections
              <span class="badge badge-ghost">{length(@receiver_connections)}</span>
            </h2>
            <p class="text-sm text-base-content/70 mb-4">
              Sites this site can pull data from
            </p>

            <%= if Enum.empty?(@receiver_connections) do %>
              <p class="text-center text-base-content/50 py-4">
                No receiver connections configured
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table">
                  <thead>
                    <tr>
                      <th>Site URL</th>
                      <th>Status</th>
                      <th>Actions</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for conn <- @receiver_connections do %>
                      <tr>
                        <td class="text-sm font-mono">{conn.site_url}</td>
                        <td>
                          <.status_badge status={Map.get(@sender_statuses, conn.id, "loading")} />
                        </td>
                        <td>
                          <.connection_actions
                            connection={conn}
                            sender_status={Map.get(@sender_statuses, conn.id)}
                          />
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp connection_actions(assigns) do
    # Default sender_status to nil if not provided
    assigns = assign_new(assigns, :sender_status, fn -> nil end)

    ~H"""
    <div class="flex gap-1">
      <%!-- Sync button only for receivers when sender status is active --%>
      <%= if @connection.direction == "receiver" and @sender_status == "active" do %>
        <button
          type="button"
          phx-click="start_sync"
          phx-value-id={@connection.id}
          class="btn btn-primary btn-xs"
          title="Sync data"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" />
        </button>
      <% end %>
      <button
        type="button"
        phx-click="show_connection"
        phx-value-id={@connection.id}
        class="btn btn-ghost btn-xs"
        title="View details"
      >
        <.icon name="hero-eye" class="w-4 h-4" />
      </button>
      <%!-- Edit button only for senders (receivers get info from sender) --%>
      <%= if @connection.direction == "sender" do %>
        <button
          type="button"
          phx-click="edit_connection"
          phx-value-id={@connection.id}
          class="btn btn-ghost btn-xs"
          title="Edit"
        >
          <.icon name="hero-pencil" class="w-4 h-4" />
        </button>
      <% end %>
      <%!-- Delete/Sever connection button --%>
      <button
        type="button"
        phx-click="delete_connection"
        phx-value-id={@connection.id}
        class="btn btn-error btn-xs"
        title={
          if @connection.direction == "receiver", do: "Sever connection", else: "Delete connection"
        }
        data-confirm="Are you sure you want to delete this connection? You will need to set it up again."
      >
        <.icon name="hero-trash" class="w-4 h-4" />
      </button>
      <%!-- Status controls only for sender connections (receivers sync from sender) --%>
      <%= if @connection.direction == "sender" do %>
        <%= if @connection.status == "active" do %>
          <button
            type="button"
            phx-click="suspend_connection"
            phx-value-id={@connection.id}
            class="btn btn-warning btn-xs"
            title="Suspend"
          >
            <.icon name="hero-pause" class="w-4 h-4" />
          </button>
        <% end %>
        <%= if @connection.status == "suspended" do %>
          <button
            type="button"
            phx-click="reactivate_connection"
            phx-value-id={@connection.id}
            class="btn btn-info btn-xs"
            title="Reactivate"
          >
            <.icon name="hero-play" class="w-4 h-4" />
          </button>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ===========================================
  # FORM VIEW
  # ===========================================

  defp connection_form(assigns) do
    assigns = assign_new(assigns, :connection, fn -> nil end)

    ~H"""
    <div class="card bg-base-100 shadow max-w-2xl mx-auto">
      <div class="card-body">
        <h2 class="card-title mb-4">
          <%= if @action == :new do %>
            New Connection
          <% else %>
            Edit Connection
          <% end %>
        </h2>

        <.form
          for={@changeset}
          phx-submit="save"
          class="space-y-6"
        >
          <%!-- Name Field --%>
          <div>
            <label class="block text-sm font-medium mb-2">Name *</label>
            <input
              type="text"
              name="connection[name]"
              value={Ecto.Changeset.get_field(@changeset, :name)}
              class={"input input-bordered w-full #{if @changeset.action && @changeset.errors[:name], do: "input-error"}"}
              placeholder="Production Server"
              required
            />
            <%= if @changeset.action && @changeset.errors[:name] do %>
              <p class="text-error text-sm mt-1">{elem(@changeset.errors[:name], 0)}</p>
            <% end %>
          </div>

          <%!-- Direction Field --%>
          <div>
            <label class="block text-sm font-medium mb-2">Direction</label>
            <%= if @action == :new do %>
              <input type="hidden" name="connection[direction]" value="sender" />
              <div class="bg-base-200 rounded-lg p-3">
                <p class="font-semibold">Sender</p>
                <p class="text-sm text-base-content/70">Allow remote site to pull data from here</p>
              </div>
              <p class="text-sm text-base-content/60 mt-1">
                Receiver connections are created automatically when remote sites connect
              </p>
            <% else %>
              <div class="bg-base-200 rounded-lg p-3">
                <p class="font-semibold capitalize">
                  {Ecto.Changeset.get_field(@changeset, :direction)}
                </p>
              </div>
            <% end %>
          </div>

          <%!-- Site URL Field --%>
          <div>
            <label class="block text-sm font-medium mb-2">Site URL *</label>
            <input
              type="url"
              name="connection[site_url]"
              value={Ecto.Changeset.get_field(@changeset, :site_url)}
              class={"input input-bordered w-full #{if @changeset.action && @changeset.errors[:site_url], do: "input-error"}"}
              placeholder="https://example.com"
              required
            />
            <p class="text-sm text-base-content/60 mt-1">
              The URL of the remote site that will connect to pull data
            </p>
          </div>

          <%!-- Receiver-specific settings --%>
          <%= if Ecto.Changeset.get_field(@changeset, :direction) == "receiver" do %>
            <div class="divider">Import Settings</div>

            <div>
              <label class="block text-sm font-medium mb-2">Default Conflict Strategy</label>
              <select
                name="connection[default_conflict_strategy]"
                class="select select-bordered w-full"
              >
                <option
                  value="skip"
                  selected={
                    Ecto.Changeset.get_field(@changeset, :default_conflict_strategy) == "skip"
                  }
                >
                  Skip - Don't overwrite existing records
                </option>
                <option
                  value="overwrite"
                  selected={
                    Ecto.Changeset.get_field(@changeset, :default_conflict_strategy) == "overwrite"
                  }
                >
                  Overwrite - Replace existing records
                </option>
                <option
                  value="merge"
                  selected={
                    Ecto.Changeset.get_field(@changeset, :default_conflict_strategy) == "merge"
                  }
                >
                  Merge - Combine with existing records
                </option>
              </select>
            </div>

            <div class="flex items-center gap-3 mt-4">
              <input
                type="checkbox"
                name="connection[auto_sync_enabled]"
                class="checkbox checkbox-primary"
                checked={Ecto.Changeset.get_field(@changeset, :auto_sync_enabled)}
              />
              <label class="text-sm font-medium">Enable Auto Sync</label>
            </div>
          <% end %>

          <%!-- Actions --%>
          <div class="flex justify-end gap-2 pt-4">
            <button type="button" phx-click="cancel" class="btn btn-ghost">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary">
              {if @action == :new, do: "Create Connection", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ===========================================
  # DETAILS VIEW
  # ===========================================

  defp connection_details(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow max-w-2xl mx-auto">
      <div class="card-body">
        <div class="flex justify-between items-start">
          <div>
            <h2 class="card-title">{@connection.name}</h2>
            <.status_badge status={@connection.status} />
          </div>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="edit_connection"
              phx-value-id={@connection.id}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="w-4 h-4" /> Edit
            </button>
          </div>
        </div>

        <div class="divider"></div>

        <%!-- Basic Info --%>
        <div class="grid grid-cols-2 gap-4">
          <div>
            <label class="text-sm text-base-content/70">Direction</label>
            <p class="font-semibold capitalize">{@connection.direction}</p>
          </div>
          <div>
            <label class="text-sm text-base-content/70">Site URL</label>
            <p class="font-mono text-sm">{@connection.site_url}</p>
          </div>
        </div>

        <%!-- Receiver Settings --%>
        <%= if @connection.direction == "receiver" do %>
          <div class="divider">Import Settings</div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="text-sm text-base-content/70">Conflict Strategy</label>
              <p class="capitalize">{@connection.default_conflict_strategy}</p>
            </div>
            <div>
              <label class="text-sm text-base-content/70">Auto Sync</label>
              <p>
                <%= if @connection.auto_sync_enabled do %>
                  <span class="badge badge-success">Enabled</span>
                <% else %>
                  <span class="badge badge-ghost">Disabled</span>
                <% end %>
              </p>
            </div>
          </div>
        <% end %>

        <%!-- Statistics --%>
        <div class="divider">Statistics</div>

        <div class="grid grid-cols-3 gap-4">
          <div>
            <label class="text-sm text-base-content/70">Total Transfers</label>
            <p class="text-2xl font-bold">{@connection.total_transfers}</p>
          </div>
          <div>
            <label class="text-sm text-base-content/70">Records Transferred</label>
            <p class="text-2xl font-bold">{@connection.total_records_transferred}</p>
          </div>
          <div>
            <label class="text-sm text-base-content/70">Bytes Transferred</label>
            <p class="text-2xl font-bold">{format_bytes(@connection.total_bytes_transferred)}</p>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4 mt-4">
          <div>
            <label class="text-sm text-base-content/70">Last Connected</label>
            <p>
              <%= if @connection.last_connected_at do %>
                {format_time_ago(@connection.last_connected_at)}
              <% else %>
                Never
              <% end %>
            </p>
          </div>
          <div>
            <label class="text-sm text-base-content/70">Last Transfer</label>
            <p>
              <%= if @connection.last_transfer_at do %>
                {format_time_ago(@connection.last_transfer_at)}
              <% else %>
                Never
              <% end %>
            </p>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="divider">Actions</div>

        <div class="flex flex-wrap gap-2">
          <%!-- Status controls only for sender connections (receivers sync status from sender) --%>
          <%= if @connection.direction == "sender" do %>
            <%= if @connection.status == "active" do %>
              <button
                type="button"
                phx-click="suspend_connection"
                phx-value-id={@connection.id}
                class="btn btn-warning btn-sm"
              >
                <.icon name="hero-pause" class="w-4 h-4" /> Suspend
              </button>
            <% end %>

            <%= if @connection.status == "suspended" do %>
              <button
                type="button"
                phx-click="reactivate_connection"
                phx-value-id={@connection.id}
                class="btn btn-info btn-sm"
              >
                <.icon name="hero-play" class="w-4 h-4" /> Reactivate
              </button>
            <% end %>
          <% end %>

          <%= if @connection.status not in ["revoked"] do %>
            <button
              type="button"
              phx-click="regenerate_token"
              phx-value-id={@connection.id}
              class="btn btn-outline btn-sm"
            >
              <.icon name="hero-key" class="w-4 h-4" /> Regenerate Token
            </button>

            <button
              type="button"
              phx-click="revoke_connection"
              phx-value-id={@connection.id}
              class="btn btn-error btn-sm"
              data-confirm="Are you sure you want to revoke this connection?"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" /> Revoke
            </button>
          <% end %>

          <button
            type="button"
            phx-click="delete_connection"
            phx-value-id={@connection.id}
            class="btn btn-ghost btn-sm text-error"
            data-confirm="Are you sure you want to delete this connection?"
          >
            <.icon name="hero-trash" class="w-4 h-4" /> Delete
          </button>
        </div>

        <%!-- Back Button --%>
        <div class="card-actions justify-end pt-4">
          <button type="button" phx-click="cancel" class="btn btn-ghost">
            Back to List
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ===========================================
  # SYNC VIEW
  # ===========================================

  defp sync_view(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow max-w-4xl mx-auto">
      <div class="card-body">
        <div class="flex justify-between items-start">
          <div>
            <h2 class="card-title">
              <.icon name="hero-arrow-path" class="w-6 h-6" /> Sync Data
            </h2>
            <p class="text-sm text-base-content/70 mt-1">
              Pull data from <span class="font-semibold">{@connection.name}</span>
            </p>
          </div>
          <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">
            <.icon name="hero-x-mark" class="w-4 h-4" /> Close
          </button>
        </div>

        <%!-- Tab Navigation --%>
        <div role="tablist" class="tabs tabs-bordered mb-4">
          <button
            type="button"
            role="tab"
            class={"tab #{if @active_tab == :bulk, do: "tab-active"}"}
            phx-click="switch_sync_tab"
            phx-value-tab="bulk"
          >
            <.icon name="hero-table-cells" class="w-4 h-4 mr-2" /> Bulk Transfer
          </button>
          <button
            type="button"
            role="tab"
            class={"tab #{if @active_tab == :details, do: "tab-active"}"}
            phx-click="switch_sync_tab"
            phx-value-tab="details"
          >
            <.icon name="hero-adjustments-horizontal" class="w-4 h-4 mr-2" /> Precise Transfer
          </button>
        </div>

        <%!-- Error State --%>
        <%= if @error do %>
          <div class="alert alert-error mb-4">
            <.icon name="hero-exclamation-circle" class="w-5 h-5" />
            <span>{@error}</span>
            <button type="button" phx-click="refresh_tables" class="btn btn-sm btn-ghost">
              Retry
            </button>
          </div>
        <% end %>

        <%!-- Loading State --%>
        <%= if @loading do %>
          <div class="flex flex-col items-center justify-center py-12">
            <span class="loading loading-spinner loading-lg text-primary"></span>
            <p class="mt-4 text-base-content/70">Fetching available tables...</p>
          </div>
        <% else %>
          <%= if @active_tab == :bulk do %>
            <%!-- ========== BULK TRANSFER TAB ========== --%>
            <%= if @progress && Map.get(@progress, :status) == :completed do %>
              <div class="flex flex-col items-center justify-center py-12">
                <div class="text-6xl mb-4">🎉</div>
                <h3 class="text-2xl font-bold text-success mb-4">Sync Complete!</h3>
                <div class="stats shadow mb-6">
                  <div class="stat">
                    <div class="stat-title">Tables Synced</div>
                    <div class="stat-value text-primary">{@progress.tables_done}</div>
                  </div>
                  <div class="stat">
                    <div class="stat-title">Records Imported</div>
                    <div class="stat-value text-success">
                      {format_number(@progress.records_fetched)}
                    </div>
                  </div>
                </div>
                <button type="button" phx-click="cancel" class="btn btn-primary">
                  Done
                </button>
              </div>
            <% else %>
              <%= if @sync_in_progress do %>
                <div class="flex flex-col items-center justify-center py-12">
                  <span class="loading loading-spinner loading-lg text-primary"></span>
                  <%= if @progress do %>
                    <p class="mt-4 font-semibold">
                      Syncing {@progress.current}/{@progress.total}
                    </p>
                    <p class="text-base-content/70">
                      <%= if @progress.table do %>
                        Processing: <span class="font-mono">{@progress.table}</span>
                      <% else %>
                        Preparing...
                      <% end %>
                    </p>
                  <% end %>
                </div>
              <% else %>
                <%= if Enum.empty?(@tables) do %>
                  <div class="text-center py-8 text-base-content/50">
                    <.icon name="hero-table-cells" class="w-12 h-12 mx-auto mb-2 opacity-30" />
                    <p>No tables available for sync</p>
                  </div>
                <% else %>
                  <%!-- Legend --%>
                  <div class="bg-base-200 rounded-lg p-3 mb-4 text-sm">
                    <div class="flex flex-wrap gap-x-6 gap-y-1 items-center">
                      <span class="text-base-content/70">Record counts:</span>
                      <span>
                        <span class="font-semibold text-primary">Sender</span> = remote data
                      </span>
                      <span>
                        <span class="font-semibold text-success">Local</span> = your database
                      </span>
                      <span class="badge badge-warning badge-sm gap-1">
                        <.icon name="hero-exclamation-triangle" class="w-3 h-3" /> = differs
                      </span>
                    </div>
                  </div>

                  <%!-- Selection buttons and conflict strategy --%>
                  <div class="flex flex-wrap gap-4 items-center justify-between mb-4">
                    <div class="flex gap-2 flex-wrap">
                      <button type="button" phx-click="select_all_tables" class="btn btn-ghost btn-xs">
                        Select All
                      </button>
                      <button
                        type="button"
                        phx-click="deselect_all_tables"
                        class="btn btn-ghost btn-xs"
                      >
                        Deselect All
                      </button>
                      <button
                        type="button"
                        phx-click="select_different_tables"
                        class="btn btn-ghost btn-xs"
                      >
                        Select Different
                      </button>
                      <span class="text-sm text-base-content/70 ml-2">
                        {MapSet.size(@selected_tables)} of {length(@tables)} selected
                      </span>
                    </div>

                    <form
                      phx-change="change_conflict_strategy"
                      class="form-control flex-row items-center gap-2"
                    >
                      <span class="label-text font-semibold text-sm">Conflict:</span>
                      <select name="strategy" class="select select-bordered select-sm">
                        <option value="skip" selected={@conflict_strategy == "skip"}>Skip</option>
                        <option value="overwrite" selected={@conflict_strategy == "overwrite"}>
                          Overwrite
                        </option>
                        <option value="merge" selected={@conflict_strategy == "merge"}>Merge</option>
                        <option value="append" selected={@conflict_strategy == "append"}>
                          Append
                        </option>
                      </select>
                    </form>
                  </div>

                  <div class="overflow-x-auto">
                    <table class="table table-sm">
                      <thead>
                        <tr>
                          <th>
                            <button
                              type="button"
                              phx-click="toggle_all_tables"
                              class="btn btn-ghost btn-xs"
                            >
                              <%= if MapSet.size(@selected_tables) == length(@tables) do %>
                                <.icon name="hero-check-circle" class="w-4 h-4 text-primary" />
                              <% else %>
                                <.icon name="hero-stop" class="w-4 h-4" />
                              <% end %>
                            </button>
                          </th>
                          <th>Table</th>
                          <th class="text-right">Sender</th>
                          <th class="text-right">Local</th>
                          <th class="text-right">Size</th>
                          <th class="text-center">Status</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for table <- @tables do %>
                          <% table_name = table.name || table["name"] %>
                          <% is_selected = MapSet.member?(@selected_tables, table_name) %>
                          <% local_count = Map.get(@local_counts, table_name) %>
                          <tr class={if is_selected, do: "bg-primary/10"}>
                            <td>
                              <button
                                type="button"
                                phx-click="toggle_table"
                                phx-value-table={table_name}
                                class="btn btn-ghost btn-xs"
                              >
                                <%= if is_selected do %>
                                  <.icon name="hero-check-circle" class="w-4 h-4 text-primary" />
                                <% else %>
                                  <.icon name="hero-stop" class="w-4 h-4" />
                                <% end %>
                              </button>
                            </td>
                            <td class="font-mono text-sm">{table_name}</td>
                            <td class="text-right">{format_number(table.row_count || 0)}</td>
                            <td class="text-right">
                              <%= if local_count do %>
                                {format_number(local_count)}
                              <% else %>
                                <span class="text-base-content/50">—</span>
                              <% end %>
                            </td>
                            <td class="text-right text-base-content/70">
                              {format_bytes(table.size_bytes || 0)}
                            </td>
                            <td class="text-center">
                              <%= cond do %>
                                <% local_count == nil -> %>
                                  <span class="badge badge-info badge-sm gap-1">
                                    <.icon name="hero-plus-circle-mini" class="w-3 h-3" /> New
                                  </span>
                                <% local_count == (table.row_count || 0) -> %>
                                  <span class="badge badge-success badge-sm gap-1">
                                    <.icon name="hero-check-circle-mini" class="w-3 h-3" /> Match
                                  </span>
                                <% true -> %>
                                  <span class="badge badge-warning badge-sm gap-1">
                                    <.icon name="hero-exclamation-triangle-mini" class="w-3 h-3" />
                                    {abs((table.row_count || 0) - local_count)} diff
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
                        label="Match"
                        count={count_same_tables(@tables, @local_counts)}
                        color="success"
                      />
                    </div>
                  </div>

                  <div class="flex justify-between items-center mt-4">
                    <div class="text-sm text-base-content/70">
                      {MapSet.size(@selected_tables)} table(s) selected
                    </div>
                    <button
                      type="button"
                      phx-click="execute_sync"
                      class="btn btn-primary"
                      disabled={MapSet.size(@selected_tables) == 0}
                    >
                      <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                      Pull {MapSet.size(@selected_tables)} Table(s)
                    </button>
                  </div>
                <% end %>
              <% end %>
            <% end %>
          <% else %>
            <%!-- ========== PRECISE TRANSFER TAB ========== --%>
            <%= if @progress && Map.get(@progress, :status) == :completed do %>
              <div class="flex flex-col items-center justify-center py-12">
                <div class="text-6xl mb-4">🎉</div>
                <h3 class="text-2xl font-bold text-success mb-4">Transfer Complete!</h3>
                <div class="stats shadow mb-6">
                  <div class="stat">
                    <div class="stat-title">Table</div>
                    <div class="stat-value text-primary font-mono text-lg">
                      {@progress[:table] || @selected_detail_table || "1 table"}
                    </div>
                  </div>
                  <div class="stat">
                    <div class="stat-title">Records Imported</div>
                    <div class="stat-value text-success">
                      {format_number(@progress.records_fetched || 0)}
                    </div>
                  </div>
                </div>
                <button type="button" phx-click="cancel" class="btn btn-primary">Done</button>
              </div>
            <% else %>
              <div class="space-y-4">
                <form phx-change="select_detail_table" class="form-control">
                  <label class="label">
                    <span class="label-text font-semibold">Select Table</span>
                  </label>
                  <select class="select select-bordered w-full max-w-md" name="table">
                    <option value="">-- Select a table --</option>
                    <%= for table <- @tables do %>
                      <% table_name = if is_map(table), do: table.name || table["name"], else: table %>
                      <% sender_count =
                        if is_map(table), do: table.row_count || table["row_count"] || 0, else: 0 %>
                      <option value={table_name} selected={@selected_detail_table == table_name}>
                        {table_name} ({format_number(sender_count)} records)
                      </option>
                    <% end %>
                  </select>
                </form>

                <%= if @selected_detail_table do %>
                  <%= if @loading_schema do %>
                    <div class="flex items-center gap-2 text-base-content/70">
                      <span class="loading loading-spinner loading-sm"></span>
                      <span>Loading table schema...</span>
                    </div>
                  <% else %>
                    <div class="bg-base-200 rounded-lg p-4">
                      <h3 class="font-semibold font-mono">{@selected_detail_table}</h3>
                      <% local_count = Map.get(@local_counts, @selected_detail_table) %>
                      <% table_info =
                        Enum.find(@tables, fn t -> (t.name || t["name"]) == @selected_detail_table end) %>
                      <% sender_count =
                        if table_info,
                          do: table_info.row_count || table_info["row_count"] || 0,
                          else: 0 %>
                      <div class="text-sm text-base-content/70 mt-1">
                        Sender:
                        <span class="font-semibold text-primary">{format_number(sender_count)}</span>
                        records
                        <%= if local_count do %>
                          | Local:
                          <span class="font-semibold text-success">{format_number(local_count)}</span>
                          records
                        <% else %>
                          | <span class="badge badge-info badge-sm">New table</span>
                        <% end %>
                      </div>
                    </div>

                    <%!-- Table Schema Display --%>
                    <%= if @detail_table_schema do %>
                      <% schema_columns = get_schema_columns(@detail_table_schema) %>
                      <%= if length(schema_columns) > 0 do %>
                        <div class="bg-base-100 border border-base-300 rounded-lg p-4">
                          <h4 class="font-semibold text-sm mb-3">Table Schema</h4>
                          <div class="overflow-x-auto max-h-48">
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
                                      {col["name"] || col[:name]}
                                      <%= if col["primary_key"] || col[:primary_key] do %>
                                        <span class="badge badge-primary badge-xs ml-1">PK</span>
                                      <% end %>
                                    </td>
                                    <td class="text-xs text-base-content/70">
                                      {col["type"] || col[:type]}
                                    </td>
                                    <td class="text-xs">
                                      {if col["nullable"] || col[:nullable], do: "Yes", else: "No"}
                                    </td>
                                    <td class="text-xs font-mono text-base-content/50">
                                      {col["default"] || col[:default] || "-"}
                                    </td>
                                  </tr>
                                <% end %>
                              </tbody>
                            </table>
                          </div>
                        </div>
                      <% end %>
                    <% end %>

                    <%!-- Create Table Button (when table doesn't exist locally) --%>
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
                          type="button"
                          phx-click="create_detail_table"
                          class="btn btn-sm btn-primary"
                          disabled={@creating_table or is_nil(@detail_table_schema)}
                        >
                          <%= if @creating_table do %>
                            <span class="loading loading-spinner loading-xs"></span> Creating...
                          <% else %>
                            <.icon name="hero-plus" class="w-4 h-4" /> Create Table
                          <% end %>
                        </button>
                      </div>
                    <% end %>

                    <form phx-change="update_detail_filter" class="space-y-3">
                      <label class="label">
                        <span class="label-text font-semibold">Filter Records</span>
                      </label>
                      <div class="flex flex-wrap gap-4">
                        <label class="flex items-center gap-2 cursor-pointer">
                          <input
                            type="radio"
                            name="mode"
                            value="all"
                            class="radio radio-primary radio-sm"
                            checked={@detail_filter.mode == :all}
                          />
                          <span>All records</span>
                        </label>
                        <label class="flex items-center gap-2 cursor-pointer">
                          <input
                            type="radio"
                            name="mode"
                            value="ids"
                            class="radio radio-primary radio-sm"
                            checked={@detail_filter.mode == :ids}
                          />
                          <span>Specific IDs</span>
                        </label>
                        <label class="flex items-center gap-2 cursor-pointer">
                          <input
                            type="radio"
                            name="mode"
                            value="range"
                            class="radio radio-primary radio-sm"
                            checked={@detail_filter.mode == :range}
                          />
                          <span>ID Range</span>
                        </label>
                      </div>
                      <%= if @detail_filter.mode == :ids do %>
                        <input
                          type="text"
                          name="ids"
                          value={@detail_filter.ids}
                          class="input input-bordered w-full"
                          placeholder="Enter IDs (e.g., 1,2,3)"
                        />
                      <% end %>
                      <%= if @detail_filter.mode == :range do %>
                        <div class="flex gap-2 items-center">
                          <input
                            type="number"
                            name="range_start"
                            value={@detail_filter.range_start}
                            class="input input-bordered w-32"
                            placeholder="From"
                          />
                          <span>to</span>
                          <input
                            type="number"
                            name="range_end"
                            value={@detail_filter.range_end}
                            class="input input-bordered w-32"
                            placeholder="To"
                          />
                        </div>
                      <% end %>
                    </form>

                    <%!-- Preview Button --%>
                    <div class="flex gap-2">
                      <button
                        type="button"
                        phx-click="preview_detail_records"
                        class="btn btn-outline btn-sm"
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
                      <div class="bg-base-100 border border-base-300 rounded-lg p-4">
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

                    <form phx-change="change_conflict_strategy" class="form-control">
                      <label class="label">
                        <span class="label-text font-semibold">Conflict Strategy</span>
                      </label>
                      <select name="strategy" class="select select-bordered w-full max-w-xs">
                        <option value="skip" selected={@conflict_strategy == "skip"}>
                          Skip existing
                        </option>
                        <option value="overwrite" selected={@conflict_strategy == "overwrite"}>
                          Overwrite
                        </option>
                        <option value="merge" selected={@conflict_strategy == "merge"}>Merge</option>
                        <option value="append" selected={@conflict_strategy == "append"}>
                          Append
                        </option>
                      </select>
                    </form>

                    <div class="flex justify-end">
                      <button
                        type="button"
                        phx-click="transfer_detail_table"
                        class="btn btn-primary"
                        disabled={@sync_in_progress or not @local_table_exists}
                      >
                        <%= if @sync_in_progress do %>
                          <span class="loading loading-spinner loading-sm"></span> Transferring...
                        <% else %>
                          <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
                          Transfer {@selected_detail_table}
                        <% end %>
                      </button>
                    </div>
                  <% end %>
                <% else %>
                  <div class="text-center py-8 text-base-content/50">
                    <.icon name="hero-table-cells" class="w-12 h-12 mx-auto mb-2 opacity-30" />
                    <p>Select a table above to view details and transfer options</p>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ===========================================
  # HELPER COMPONENTS
  # ===========================================

  defp status_badge(assigns) do
    {color, label} =
      case assigns.status do
        "pending" -> {"badge-warning", "Pending"}
        "active" -> {"badge-success", "Active"}
        "suspended" -> {"badge-error", "Suspended"}
        "revoked" -> {"badge-ghost", "Revoked"}
        "expired" -> {"badge-ghost", "Expired"}
        "loading" -> {"badge-ghost animate-pulse", "Loading..."}
        "offline" -> {"badge-warning", "Sender Offline"}
        "not_found" -> {"badge-error", "Not Found"}
        "error" -> {"badge-error", "Error"}
        _ -> {"badge-ghost", String.capitalize(to_string(assigns.status))}
      end

    assigns = assigns |> assign(:color, color) |> assign(:label, label)

    ~H"""
    <span class={"badge badge-sm #{@color}"}>
      {@label}
    </span>
    """
  end

  # ===========================================
  # HELPER FUNCTIONS
  # ===========================================

  defp format_time_ago(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  defp format_bytes(bytes) when is_nil(bytes) or bytes == 0, do: "0 B"

  defp format_bytes(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp path_with_params(base_path, params) when map_size(params) == 0 do
    Routes.path(base_path)
  end

  defp path_with_params(base_path, params) do
    query_string = URI.encode_query(params)
    "#{Routes.path(base_path)}?#{query_string}"
  end

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_number(num), do: "#{num}"

  defp parse_id_list(ids_string) when is_binary(ids_string) do
    ids_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(&1 != ""))
    |> Enum.map(fn id ->
      case Integer.parse(id) do
        {int, _} -> int
        :error -> nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp parse_id_list(_), do: []

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(_), do: nil

  # Get schema columns, handling both atom and string keys
  defp get_schema_columns(nil), do: []

  defp get_schema_columns(schema) when is_map(schema) do
    Map.get(schema, :columns) || Map.get(schema, "columns") || []
  end

  defp get_schema_columns(_), do: []

  # Table summary stat component
  defp table_summary_stat(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <span class={"badge badge-#{@color} badge-sm"}>{@count}</span>
      <span class="text-base-content/70">{@label}</span>
    </div>
    """
  end

  # Count tables that don't exist locally
  defp count_new_tables(tables, local_counts) do
    Enum.count(tables, fn table ->
      name = table.name || table["name"]
      not Map.has_key?(local_counts, name)
    end)
  end

  # Count tables with different counts
  defp count_different_tables(tables, local_counts) do
    Enum.count(tables, fn table ->
      name = table.name || table["name"]
      local_count = Map.get(local_counts, name)
      sender_count = table.row_count || table["row_count"] || 0

      not is_nil(local_count) and local_count != sender_count
    end)
  end

  # Count tables that match (same count)
  defp count_same_tables(tables, local_counts) do
    Enum.count(tables, fn table ->
      name = table.name || table["name"]
      local_count = Map.get(local_counts, name)
      sender_count = table.row_count || table["row_count"] || 0

      not is_nil(local_count) and local_count == sender_count
    end)
  end
end
