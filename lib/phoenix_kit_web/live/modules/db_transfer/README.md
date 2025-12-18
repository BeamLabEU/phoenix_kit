# DB Transfer Module

The PhoenixKit DB Transfer module provides peer-to-peer data transfer between PhoenixKit instances. Transfer data between development and production environments, between different websites, or create database backups - all through a secure WebSocket connection with visual UI and programmatic API.

## Quick Links

- **Admin Interface**: `/{prefix}/admin/db-transfer`
- **Send Data**: `/{prefix}/admin/db-transfer/send`
- **Receive Data**: `/{prefix}/admin/db-transfer/receive`

## Architecture Overview

### Core Modules

- **PhoenixKit.DBTransfer** – Main API for local operations and session management
- **PhoenixKit.DBTransfer.Client** – Synchronous client for remote operations
- **PhoenixKit.DBTransfer.SchemaInspector** – Database introspection
- **PhoenixKit.DBTransfer.DataExporter** – Record export with pagination
- **PhoenixKit.DBTransfer.DataImporter** – Record import with conflict resolution
- **PhoenixKit.DBTransfer.WebSocketClient** – Async WebSocket communication
- **PhoenixKit.DBTransfer.SessionStore** – ETS-based session management

### Web Components

- **PhoenixKitWeb.DBTransferChannel** – Phoenix Channel for data serving
- **PhoenixKitWeb.Live.Modules.DBTransfer.Sender** – Sender LiveView UI
- **PhoenixKitWeb.Live.Modules.DBTransfer.Receiver** – Receiver LiveView UI
- **PhoenixKit.DBTransfer.Workers.ImportWorker** – Oban worker for background imports

## Core Features

- **Peer-to-Peer Transfer** – Direct connection between sites, no intermediary server
- **Multi-Receiver Support** – Sender can serve multiple receivers simultaneously
- **Auto Table Creation** – Creates missing tables on receiver from sender's schema
- **Conflict Resolution** – Skip, overwrite, merge, or append strategies
- **Background Import** – Large transfers processed via Oban jobs
- **Visual Progress** – Real-time progress tracking in UI
- **Programmatic API** – Full API for scripts, migrations, and AI agents

## Transfer Flow

### Sender Side

1. Navigate to Send Data page
2. Generate connection code
3. Share code and site URL with receiver
4. Keep page open while receiver transfers data

### Receiver Side

1. Navigate to Receive Data page
2. Enter sender's URL and connection code
3. Connect to sender
4. Browse available tables
5. Select tables and conflict strategy
6. Start transfer

## Conflict Strategies

| Strategy | Behavior |
|----------|----------|
| **Skip** | Skip if record with same primary key exists (default) |
| **Overwrite** | Replace existing record with imported data |
| **Merge** | Merge imported data with existing (keeps existing where new is nil) |
| **Append** | Always insert as new record with auto-generated ID |

## Programmatic API

### Local Database Operations

```elixir
# System control
PhoenixKit.DBTransfer.enabled?()
PhoenixKit.DBTransfer.enable_system()
PhoenixKit.DBTransfer.disable_system()

# List available tables
{:ok, tables} = PhoenixKit.DBTransfer.list_tables()
# => [%{name: "users", estimated_count: 150}, ...]

# Get table schema
{:ok, schema} = PhoenixKit.DBTransfer.get_schema("users")
# => %{table: "users", columns: [...], primary_key: ["id"]}

# Get row count
{:ok, count} = PhoenixKit.DBTransfer.get_count("users")

# Check if table exists
PhoenixKit.DBTransfer.table_exists?("users")

# Export records with pagination
{:ok, records} = PhoenixKit.DBTransfer.export_records("users", limit: 100, offset: 0)

# Import records
{:ok, result} = PhoenixKit.DBTransfer.import_records("users", records, :skip)
# => %{created: 50, updated: 0, skipped: 5, errors: []}

# Create table from schema
:ok = PhoenixKit.DBTransfer.create_table("users", schema)
```

### Remote Operations (Client)

```elixir
# Connect to remote sender
{:ok, client} = PhoenixKit.DBTransfer.Client.connect("https://sender.com", "ABC12345")

# With options
{:ok, client} = PhoenixKit.DBTransfer.Client.connect(url, code,
  timeout: 60_000,
  receiver_info: %{project: "MyApp", user: "admin@example.com"}
)

# List remote tables
{:ok, tables} = PhoenixKit.DBTransfer.Client.list_tables(client)

# Get remote table schema
{:ok, schema} = PhoenixKit.DBTransfer.Client.get_schema(client, "users")

# Get remote record count
{:ok, count} = PhoenixKit.DBTransfer.Client.get_count(client, "users")

# Fetch records (manual pagination)
{:ok, result} = PhoenixKit.DBTransfer.Client.fetch_records(client, "users",
  limit: 100,
  offset: 0
)
# => %{records: [...], has_more: true, offset: 0}

# Transfer single table (auto-pagination, auto-create table)
{:ok, result} = PhoenixKit.DBTransfer.Client.transfer(client, "users",
  strategy: :skip,
  batch_size: 500,
  create_missing_tables: true
)
# => %{created: 150, updated: 0, skipped: 0, errors: []}

# Transfer multiple tables
{:ok, results} = PhoenixKit.DBTransfer.Client.transfer_all(client,
  tables: ["users", "posts"],
  strategy: :skip
)
# => %{"users" => %{created: 150, ...}, "posts" => %{created: 500, ...}}

# Transfer all tables with per-table strategies
{:ok, results} = PhoenixKit.DBTransfer.Client.transfer_all(client,
  strategies: %{"users" => :skip, "posts" => :overwrite}
)

# Disconnect when done
:ok = PhoenixKit.DBTransfer.Client.disconnect(client)
```

### Full Transfer Example

```elixir
# Complete transfer workflow
alias PhoenixKit.DBTransfer
alias PhoenixKit.DBTransfer.Client

# Connect to sender
{:ok, client} = Client.connect("https://production.example.com", "ABC12345")

# List available tables
{:ok, tables} = Client.list_tables(client)
IO.inspect(tables, label: "Available tables")

# Transfer specific tables
{:ok, results} = Client.transfer_all(client,
  tables: ["users", "posts", "comments"],
  strategy: :skip,
  create_missing_tables: true
)

# Report results
for {table, result} <- results do
  IO.puts("#{table}: created=#{result.created}, skipped=#{result.skipped}")
end

# Disconnect
Client.disconnect(client)
```

## Session Management

Sessions are stored in ETS and tied to the sender's LiveView process:

```elixir
# Create a session (typically done by LiveView)
{:ok, session} = PhoenixKit.DBTransfer.create_session(:send)
# => %{code: "A7X9K2M4", direction: :send, status: :pending, ...}

# Get session by code
{:ok, session} = PhoenixKit.DBTransfer.get_session("A7X9K2M4")

# Validate and use a code (receiver connecting)
{:ok, session} = PhoenixKit.DBTransfer.validate_code("A7X9K2M4")

# Delete session
:ok = PhoenixKit.DBTransfer.delete_session("A7X9K2M4")
```

## Background Import (Oban)

Large transfers are processed in the background using Oban:

```elixir
# Queue configuration - add to your Oban config
config :my_app, Oban,
  queues: [default: 10, db_transfer: 5]

# The ImportWorker handles:
# - Auto-creating missing tables from schema
# - Importing records in batches
# - Logging progress and errors
```

## UI Features

### Sender Interface

- Generate secure connection code (8 characters, no ambiguous chars)
- Display site URL for sharing
- Show connected receivers (supports multiple)
- Display receiver identity info (name, email, project, site URL)
- Show connection details (IP, user agent, timestamps)
- Individual receiver disconnect buttons
- "End All Sessions" to disconnect everyone

### Receiver Interface

- Connect to sender via URL and code
- **Bulk Transfer Tab**:
  - Table comparison view (new/different/same counts)
  - Multi-select tables with checkboxes
  - Conflict strategy selection
  - Real-time transfer progress
- **Table Details Tab**:
  - Individual table inspection
  - Schema viewer with column details
  - Record preview with filtering
  - Filter modes: All, ID range, Specific IDs
  - Create missing tables button
  - Single-table transfer

## Security Considerations

- Connection codes are single-use and tied to sender's session
- Codes expire when sender closes the page
- Session data stored in-memory (ETS), not persisted
- Excluded tables: `schema_migrations`, `oban_*`, `phoenix_kit_user_tokens`
- SQL injection prevention via identifier validation
- No direct database access - all queries through schema inspector

## Error Handling

```elixir
case PhoenixKit.DBTransfer.Client.connect(url, code) do
  {:ok, client} ->
    # Connected successfully

  {:error, :connection_timeout} ->
    # Connection timed out

  {:error, {:disconnected, reason}} ->
    # WebSocket disconnected

  {:error, reason} ->
    # Other error
end

case PhoenixKit.DBTransfer.Client.transfer(client, "users") do
  {:ok, result} ->
    IO.puts("Created: #{result.created}, Errors: #{length(result.errors)}")

  {:error, {:table_not_found, table}} ->
    IO.puts("Table #{table} doesn't exist and create_missing_tables is false")

  {:error, reason} ->
    IO.puts("Transfer failed: #{inspect(reason)}")
end
```

## LiveView Interfaces

- **Index** (`/{prefix}/admin/db-transfer`) – Module overview with send/receive options
- **Sender** (`/{prefix}/admin/db-transfer/send`) – Generate code, manage connections
- **Receiver** (`/{prefix}/admin/db-transfer/receive`) – Connect, browse, transfer

## Extending the Module

### Custom Table Filtering

The `SchemaInspector` excludes certain tables by default. To modify:

```elixir
# In SchemaInspector module
@excluded_tables ["schema_migrations", "oban_jobs", ...]
@excluded_prefixes ["pg_", "oban_"]
```

### Custom Import Logic

For custom import behavior, use the lower-level API:

```elixir
# Fetch records manually
{:ok, result} = Client.fetch_records(client, "users", limit: 100)

# Process/transform records
transformed = Enum.map(result.records, &transform_record/1)

# Import with custom logic
{:ok, import_result} = DBTransfer.import_records("users", transformed, :merge)
```

### Adding Progress Callbacks

The Client module supports custom progress tracking:

```elixir
# The transfer/3 function processes in batches
# For custom progress, use fetch_records in a loop:
def transfer_with_progress(client, table, callback) do
  loop(client, table, 0, callback)
end

defp loop(client, table, offset, callback) do
  case Client.fetch_records(client, table, offset: offset, limit: 500) do
    {:ok, %{records: records, has_more: has_more}} ->
      DBTransfer.import_records(table, records, :skip)
      callback.({:progress, offset + length(records)})

      if has_more do
        loop(client, table, offset + 500, callback)
      else
        callback.(:complete)
      end

    {:error, reason} ->
      callback.({:error, reason})
  end
end
```

## Troubleshooting

### Connection Issues

1. Verify sender page is still open (session expires on close)
2. Check connection code is correct (case-sensitive)
3. Ensure sender URL is accessible from receiver
4. Check for CORS/firewall issues blocking WebSocket

### Transfer Failures

1. Check Oban job status for import errors
2. Review server logs for detailed error messages
3. Verify table schema compatibility
4. Check for constraint violations (foreign keys, unique indexes)

### Performance

1. Use appropriate batch sizes (default: 500)
2. Consider using `:append` strategy for faster inserts
3. Monitor Oban queue for job backlog
4. For very large tables, transfer during off-peak hours

## Getting Help

1. Check this README for API documentation
2. Review server logs with `Logger.configure(level: :debug)`
3. Check Oban dashboard for import job status
4. Inspect `phoenix_kit_ai_requests` for request logging
