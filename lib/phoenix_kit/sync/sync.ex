defmodule PhoenixKit.Sync do
  @moduledoc """
  Main context for Sync module.

  Provides peer-to-peer data sync between PhoenixKit instances.
  Supports sync between dev↔prod, dev↔dev, or even different websites.

  ## Programmatic API

  This module provides a complete API for programmatic data sync, suitable
  for use from code, scripts, or AI agents.

  ### System Control

  - `enabled?/0` - Check if Sync module is enabled
  - `enable_system/0` - Enable Sync module
  - `disable_system/0` - Disable Sync module
  - `get_config/0` - Get current configuration and stats

  ### Session Management (for LiveView UI)

  - `create_session/1` - Create a new sync session with connection code
  - `get_session/1` - Get session by code
  - `validate_code/1` - Validate and mark code as used
  - `delete_session/1` - Delete a session

  ### Local Database Inspection

  - `list_tables/0` - List all syncable tables with row counts
  - `get_schema/1` - Get schema (columns, types) for a table
  - `get_count/1` - Get exact row count for a table
  - `table_exists?/1` - Check if a table exists locally
  - `export_records/2` - Export records from a table with pagination

  ### Data Import

  - `import_records/3` - Import records into a table with conflict strategy
  - `create_table/2` - Create a table from a schema definition

  ### Remote Operations (via Client)

  For connecting to a remote sender and fetching data, use `PhoenixKit.Sync.Client`:

      {:ok, client} = PhoenixKit.Sync.Client.connect("https://example.com", "ABC12345")
      {:ok, tables} = PhoenixKit.Sync.Client.list_tables(client)
      {:ok, records} = PhoenixKit.Sync.Client.fetch_records(client, "users")
      PhoenixKit.Sync.Client.disconnect(client)

  ## Usage Examples

      # List local tables
      {:ok, tables} = PhoenixKit.Sync.list_tables()
      # => [{name: "users", estimated_count: 150}, ...]

      # Get table schema
      {:ok, schema} = PhoenixKit.Sync.get_schema("users")
      # => %{table: "users", columns: [...], primary_key: ["id"]}

      # Export records with pagination
      {:ok, records} = PhoenixKit.Sync.export_records("users", limit: 100, offset: 0)

      # Import records with conflict strategy
      {:ok, result} = PhoenixKit.Sync.import_records("users", records, :skip)
      # => %{created: 5, updated: 0, skipped: 3, errors: []}

      # Full sync workflow
      {:ok, client} = PhoenixKit.Sync.Client.connect(url, code)
      {:ok, tables} = PhoenixKit.Sync.Client.list_tables(client)
      {:ok, result} = PhoenixKit.Sync.Client.transfer(client, "users", strategy: :skip)
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Sync.DataExporter
  alias PhoenixKit.Sync.DataImporter
  alias PhoenixKit.Sync.SchemaInspector
  alias PhoenixKit.Sync.SessionStore

  @module_name "sync"
  @enabled_key "sync_enabled"
  @incoming_mode_key "sync_incoming_mode"
  @incoming_password_key "sync_incoming_password"

  # ===========================================
  # SYSTEM CONTROL
  # ===========================================

  @doc """
  Checks if the Sync module is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting(@enabled_key, false)
  end

  @doc """
  Enables the Sync module.
  """
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, true, @module_name)
  end

  @doc """
  Disables the Sync module.
  """
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system do
    Settings.update_boolean_setting_with_module(@enabled_key, false, @module_name)
  end

  @doc """
  Gets the Sync module configuration with statistics.

  Returns a map with:
  - `enabled` - Whether the module is enabled
  - `active_sessions` - Number of active sessions (sessions tied to LiveView processes)
  - `incoming_mode` - How incoming connections are handled
  - `incoming_password_set` - Whether a password is set for incoming connections
  """
  @spec get_config() :: map()
  def get_config do
    %{
      enabled: enabled?(),
      active_sessions: SessionStore.count_active(),
      incoming_mode: get_incoming_mode(),
      incoming_password_set: incoming_password_set?()
    }
  end

  # ===========================================
  # INCOMING CONNECTION SETTINGS
  # ===========================================

  @doc """
  Gets the current incoming connection mode.

  Modes:
  - `"auto_accept"` - Automatically accept and activate incoming connections
  - `"require_approval"` - Accept but set as pending, requires manual approval
  - `"require_password"` - Require password before accepting
  - `"deny_all"` - Reject all incoming connection requests

  Default is `"require_approval"`.
  """
  @spec get_incoming_mode() :: String.t()
  def get_incoming_mode do
    Settings.get_setting(@incoming_mode_key, "require_approval")
  end

  @doc """
  Sets the incoming connection mode.
  """
  @spec set_incoming_mode(String.t()) :: {:ok, any()} | {:error, any()}
  def set_incoming_mode(mode)
      when mode in ["auto_accept", "require_approval", "require_password", "deny_all"] do
    Settings.update_setting_with_module(@incoming_mode_key, mode, @module_name)
  end

  @doc """
  Gets the incoming connection password (if set).
  Returns nil if not set.
  """
  @spec get_incoming_password() :: String.t() | nil
  def get_incoming_password do
    case Settings.get_setting(@incoming_password_key, nil) do
      nil -> nil
      "" -> nil
      password -> password
    end
  end

  @doc """
  Sets the incoming connection password.
  Pass nil or empty string to clear the password.
  """
  @spec set_incoming_password(String.t() | nil) :: {:ok, any()} | {:error, any()}
  def set_incoming_password(nil) do
    Settings.update_setting_with_module(@incoming_password_key, "", @module_name)
  end

  def set_incoming_password(password) when is_binary(password) do
    Settings.update_setting_with_module(@incoming_password_key, password, @module_name)
  end

  @doc """
  Checks if an incoming connection password is set.
  """
  @spec incoming_password_set?() :: boolean()
  def incoming_password_set? do
    get_incoming_password() != nil
  end

  @doc """
  Validates an incoming connection password.
  """
  @spec validate_incoming_password(String.t() | nil) :: boolean()
  def validate_incoming_password(provided_password) do
    case get_incoming_password() do
      nil -> true
      stored_password -> stored_password == provided_password
    end
  end

  # ===========================================
  # SESSION MANAGEMENT
  # ===========================================

  @doc """
  Creates a new transfer session tied to the calling process.

  The session remains valid as long as the owner process (typically a LiveView)
  is alive. When the process terminates, the session is automatically deleted.

  ## Parameters

  - `direction` - Either `:send` or `:receive`
  - `owner_pid` - The PID of the owning process (defaults to self())

  ## Returns

  - `{:ok, session}` - Session with `code`, `direction`, `status`, `owner_pid`
  - `{:error, reason}` - If creation failed

  ## Examples

      {:ok, session} = PhoenixKit.Sync.create_session(:receive)
      # => %{
      #   code: "A7X9K2M4",
      #   direction: :receive,
      #   status: :pending,
      #   owner_pid: #PID<0.123.0>,
      #   created_at: ~U[2025-12-16 12:15:00Z]
      # }
  """
  @spec create_session(:send | :receive, pid()) :: {:ok, map()} | {:error, any()}
  def create_session(direction, owner_pid \\ self()) when direction in [:send, :receive] do
    code = generate_secure_code()

    session = %{
      code: code,
      direction: direction,
      status: :pending,
      owner_pid: owner_pid,
      created_at: DateTime.utc_now(),
      connected_at: nil,
      sender_info: nil,
      receiver_info: nil
    }

    case SessionStore.create(session) do
      :ok -> {:ok, session}
      error -> error
    end
  end

  @doc """
  Gets a session by its connection code.

  Sessions remain valid as long as the owning LiveView process is alive.
  When the page is closed, the session is automatically deleted.

  Returns `{:ok, session}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_session(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_session(code) when is_binary(code) do
    SessionStore.get(code)
  end

  @doc """
  Validates a connection code and marks it as used if valid.

  This is called when a sender connects to a receiver's session.
  Sessions remain valid as long as the owner's LiveView process is alive.

  ## Returns

  - `{:ok, session}` - Code is valid, session is now marked as connected
  - `{:error, :invalid_code}` - Code doesn't exist (or owner closed the page)
  - `{:error, :already_used}` - Code was already used for a connection
  """
  @spec validate_code(String.t()) :: {:ok, map()} | {:error, atom()}
  def validate_code(code) when is_binary(code) do
    case SessionStore.get(code) do
      {:ok, session} ->
        if session.status == :connected do
          {:error, :already_used}
        else
          updated_session = %{session | status: :connected, connected_at: DateTime.utc_now()}
          SessionStore.update(code, updated_session)
          {:ok, updated_session}
        end

      {:error, :not_found} ->
        {:error, :invalid_code}
    end
  end

  @doc """
  Deletes a session by code.
  """
  @spec delete_session(String.t()) :: :ok
  def delete_session(code) when is_binary(code) do
    SessionStore.delete(code)
  end

  @doc """
  Updates session status and metadata.
  """
  @spec update_session(String.t(), map()) :: {:ok, map()} | {:error, :not_found}
  def update_session(code, updates) when is_binary(code) and is_map(updates) do
    case SessionStore.get(code) do
      {:ok, session} ->
        updated_session = Map.merge(session, updates)
        SessionStore.update(code, updated_session)
        {:ok, updated_session}

      error ->
        error
    end
  end

  # ===========================================
  # LOCAL DATABASE INSPECTION
  # ===========================================

  @doc """
  Lists all transferable tables in the local database with row counts.

  Returns tables from the public schema, excluding system tables and
  security-sensitive tables (like session tokens).

  ## Options

  - `:include_phoenix_kit` - Include phoenix_kit_* tables (default: true)
  - `:exact_counts` - Use exact COUNT(*) instead of estimates (default: true)

  ## Examples

      {:ok, tables} = PhoenixKit.Sync.list_tables()
      # => [%{name: "users", estimated_count: 150}, %{name: "posts", estimated_count: 1200}]
  """
  @spec list_tables(keyword()) :: {:ok, [map()]} | {:error, any()}
  def list_tables(opts \\ []) do
    SchemaInspector.list_tables(opts)
  end

  @doc """
  Gets the schema (columns, types, constraints) for a specific table.

  ## Examples

      {:ok, schema} = PhoenixKit.Sync.get_schema("users")
      # => %{
      #   table: "users",
      #   columns: [
      #     %{name: "id", type: "bigint", nullable: false, primary_key: true},
      #     %{name: "email", type: "character varying", nullable: false},
      #     ...
      #   ],
      #   primary_key: ["id"]
      # }
  """
  @spec get_schema(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def get_schema(table_name, opts \\ []) do
    SchemaInspector.get_schema(table_name, opts)
  end

  @doc """
  Gets the exact row count for a table.

  ## Examples

      {:ok, count} = PhoenixKit.Sync.get_count("users")
      # => 150
  """
  @spec get_count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, any()}
  def get_count(table_name, opts \\ []) do
    SchemaInspector.get_local_count(table_name, opts)
  end

  @doc """
  Checks if a table exists in the local database.

  ## Examples

      PhoenixKit.Sync.table_exists?("users")
      # => true
  """
  @spec table_exists?(String.t(), keyword()) :: boolean()
  def table_exists?(table_name, opts \\ []) do
    SchemaInspector.table_exists?(table_name, opts)
  end

  @doc """
  Exports records from a table with pagination.

  ## Options

  - `:offset` - Number of records to skip (default: 0)
  - `:limit` - Maximum records to return (default: 100)

  ## Examples

      {:ok, records} = PhoenixKit.Sync.export_records("users", limit: 50, offset: 0)
      # => [%{"id" => 1, "email" => "user@example.com", ...}, ...]
  """
  @spec export_records(String.t(), keyword()) :: {:ok, [map()]} | {:error, any()}
  def export_records(table_name, opts \\ []) do
    DataExporter.fetch_records(table_name, opts)
  end

  # ===========================================
  # DATA IMPORT
  # ===========================================

  @doc """
  Imports records into a table with conflict resolution.

  ## Conflict Strategies

  - `:skip` - Skip if record with same primary key exists (default)
  - `:overwrite` - Replace existing record with imported data
  - `:merge` - Merge imported data with existing (keeps existing where new is nil)
  - `:append` - Always insert as new record with auto-generated ID

  ## Examples

      records = [%{"email" => "user@example.com", "name" => "John"}, ...]
      {:ok, result} = PhoenixKit.Sync.import_records("users", records, :skip)
      # => %{created: 5, updated: 0, skipped: 3, errors: []}

      # Append mode (ignores primary keys, creates new records)
      {:ok, result} = PhoenixKit.Sync.import_records("users", records, :append)
  """
  @spec import_records(String.t(), [map()], atom()) ::
          {:ok, DataImporter.import_result()} | {:error, any()}
  def import_records(table_name, records, strategy \\ :skip) do
    DataImporter.import_records(table_name, records, strategy)
  end

  @doc """
  Creates a table from a schema definition.

  Used when receiving data for a table that doesn't exist locally.
  The schema definition should match the format returned by `get_schema/1`.

  ## Examples

      schema = %{
        "columns" => [
          %{"name" => "id", "type" => "bigint", "nullable" => false, "primary_key" => true},
          %{"name" => "email", "type" => "character varying", "nullable" => false}
        ],
        "primary_key" => ["id"]
      }
      :ok = PhoenixKit.Sync.create_table("users", schema)
  """
  @spec create_table(String.t(), map(), keyword()) :: :ok | {:error, any()}
  def create_table(table_name, schema_def, opts \\ []) do
    SchemaInspector.create_table(table_name, schema_def, opts)
  end

  # ===========================================
  # PRIVATE FUNCTIONS
  # ===========================================

  @code_length 8
  # Exclude ambiguous characters: 0/O, 1/I/L
  @code_alphabet "23456789ABCDEFGHJKMNPQRSTUVWXYZ"

  defp generate_secure_code do
    alphabet_length = String.length(@code_alphabet)

    Enum.map_join(1..@code_length, fn _ ->
      index = :rand.uniform(alphabet_length) - 1
      String.at(@code_alphabet, index)
    end)
  end
end
