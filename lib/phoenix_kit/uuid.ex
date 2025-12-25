defmodule PhoenixKit.UUID do
  @moduledoc """
  UUID utilities for PhoenixKit's graceful UUID migration.

  This module provides helper functions for working with dual ID systems
  (bigserial + UUID) during the transition period. It enables parent
  applications to gradually migrate from integer IDs to UUIDs.

  ## Background

  PhoenixKit V40 adds UUID columns to all legacy tables that previously
  used bigserial primary keys. This module provides utilities to:

  - Look up records by either integer ID or UUID
  - Generate UUIDv7 values for new records
  - Validate UUID formats
  - Help with the transition from integer to UUID-based lookups

  ## UUIDv7

  This module generates UUIDv7 (time-ordered UUIDs) which provide:
  - Time-based ordering (first 48 bits are Unix timestamp in milliseconds)
  - Better index locality than random UUIDs (UUIDv4)
  - Sortable by creation time
  - Compatible with standard UUID format

  ## Usage

  ### Looking up records by ID or UUID

      # Automatically detects ID type
      PhoenixKit.UUID.get(User, "123")                    # integer lookup
      PhoenixKit.UUID.get(User, "019b5704-3680-7b95-...")  # UUID lookup

      # Explicit lookups
      PhoenixKit.UUID.get_by_id(User, 123)
      PhoenixKit.UUID.get_by_uuid(User, "019b5704-3680-7b95-...")

      # With prefix for multi-tenant schemas
      PhoenixKit.UUID.get(User, "123", prefix: "tenant_123")

  ### Generating UUIDs

      PhoenixKit.UUID.generate()  # Returns a new UUIDv7 string

  ### Parsing identifiers

      PhoenixKit.UUID.parse_identifier("123")
      # => {:integer, 123}

      PhoenixKit.UUID.parse_identifier("019b5704-3680-7b95-9d82-ef16127f1fd2")
      # => {:uuid, "019b5704-3680-7b95-9d82-ef16127f1fd2"}

  ## Migration Strategy

  This module is part of PhoenixKit's graceful UUID migration strategy:

  1. **V40**: UUID columns added to all legacy tables (non-breaking)
  2. **Transition**: Parent apps can use UUIDs in URLs/APIs while
     internal FKs continue using bigserial
  3. **Future**: UUID becomes the primary identifier

  ## Best Practices

  - Use `get/2` for user-facing lookups (URLs, API params)
  - Use `get_by_id/2` for internal operations where you know the ID type
  - Always generate UUIDs for new records using schema changesets
  - Prefer UUIDs in URLs for security (non-enumerable)
  """

  alias PhoenixKit.RepoHelper

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc """
  Generates a new UUIDv7 string.

  UUIDv7 is a time-ordered UUID where the first 48 bits are a Unix timestamp
  in milliseconds, providing natural chronological ordering.

  ## Examples

      iex> PhoenixKit.UUID.generate()
      "019b5704-3680-7b95-9d82-ef16127f1fd2"
  """
  @spec generate() :: String.t()
  def generate do
    UUIDv7.generate()
  end

  @doc """
  Gets a record by either integer ID or UUID string.

  Automatically detects the identifier type and performs the appropriate lookup.
  Returns `nil` if the record is not found.

  ## Parameters

  - `schema` - The Ecto schema module
  - `identifier` - Either an integer ID, string integer, or UUID string
  - `opts` - Optional keyword list:
    - `:prefix` - Schema prefix for multi-tenant databases
    - `:repo` - Override the repository to use

  ## Examples

      iex> PhoenixKit.UUID.get(User, 123)
      %User{id: 123, uuid: "..."}

      iex> PhoenixKit.UUID.get(User, "123")
      %User{id: 123, uuid: "..."}

      iex> PhoenixKit.UUID.get(User, "019b5704-3680-7b95-9d82-ef16127f1fd2")
      %User{id: 123, uuid: "019b5704-3680-7b95-9d82-ef16127f1fd2"}

      iex> PhoenixKit.UUID.get(User, "nonexistent")
      nil

      # With prefix for multi-tenant schemas
      iex> PhoenixKit.UUID.get(User, "123", prefix: "tenant_abc")
      %User{id: 123, uuid: "..."}
  """
  @spec get(module(), integer() | String.t(), keyword()) :: struct() | nil
  def get(schema, identifier, opts \\ []) do
    case parse_identifier(identifier) do
      {:integer, id} -> get_by_id(schema, id, opts)
      {:uuid, uuid} -> get_by_uuid(schema, uuid, opts)
      :invalid -> nil
    end
  end

  @doc """
  Gets a record by either integer ID or UUID string, raising if not found.

  ## Examples

      iex> PhoenixKit.UUID.get!(User, "019b5704-3680-7b95-9d82-ef16127f1fd2")
      %User{uuid: "019b5704-3680-7b95-9d82-ef16127f1fd2"}

      iex> PhoenixKit.UUID.get!(User, "nonexistent")
      ** (Ecto.NoResultsError)
  """
  @spec get!(module(), integer() | String.t(), keyword()) :: struct()
  def get!(schema, identifier, opts \\ []) do
    case get(schema, identifier, opts) do
      nil -> raise Ecto.NoResultsError, queryable: schema
      record -> record
    end
  end

  @doc """
  Gets a record by its integer ID.

  ## Options

  - `:prefix` - Schema prefix for multi-tenant databases
  - `:repo` - Override the repository to use

  ## Examples

      iex> PhoenixKit.UUID.get_by_id(User, 123)
      %User{id: 123}

      iex> PhoenixKit.UUID.get_by_id(User, 999999)
      nil

      iex> PhoenixKit.UUID.get_by_id(User, 123, prefix: "tenant_abc")
      %User{id: 123}
  """
  @spec get_by_id(module(), integer() | String.t(), keyword()) :: struct() | nil
  def get_by_id(schema, id, opts \\ [])

  def get_by_id(schema, id, opts) when is_integer(id) do
    repo = Keyword.get(opts, :repo, RepoHelper.repo())
    query_opts = build_query_opts(opts)
    repo.get(schema, id, query_opts)
  end

  def get_by_id(schema, id, opts) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> get_by_id(schema, int_id, opts)
      _ -> nil
    end
  end

  @doc """
  Gets a record by its UUID.

  ## Options

  - `:prefix` - Schema prefix for multi-tenant databases
  - `:repo` - Override the repository to use

  ## Examples

      iex> PhoenixKit.UUID.get_by_uuid(User, "019b5704-3680-7b95-9d82-ef16127f1fd2")
      %User{uuid: "019b5704-3680-7b95-9d82-ef16127f1fd2"}

      iex> PhoenixKit.UUID.get_by_uuid(User, "nonexistent-uuid")
      nil

      iex> PhoenixKit.UUID.get_by_uuid(User, "019b5704-...", prefix: "tenant_abc")
      %User{uuid: "019b5704-..."}
  """
  @spec get_by_uuid(module(), String.t(), keyword()) :: struct() | nil
  def get_by_uuid(schema, uuid, opts \\ [])

  def get_by_uuid(schema, uuid, opts) when is_binary(uuid) do
    if valid_uuid?(uuid) do
      repo = Keyword.get(opts, :repo, RepoHelper.repo())
      query_opts = build_query_opts(opts)
      repo.get_by(schema, [uuid: uuid], query_opts)
    else
      nil
    end
  end

  @doc """
  Parses an identifier and returns its type.

  ## Examples

      iex> PhoenixKit.UUID.parse_identifier(123)
      {:integer, 123}

      iex> PhoenixKit.UUID.parse_identifier("123")
      {:integer, 123}

      iex> PhoenixKit.UUID.parse_identifier("019b5704-3680-7b95-9d82-ef16127f1fd2")
      {:uuid, "019b5704-3680-7b95-9d82-ef16127f1fd2"}

      iex> PhoenixKit.UUID.parse_identifier("invalid")
      :invalid
  """
  @spec parse_identifier(integer() | String.t()) ::
          {:integer, integer()} | {:uuid, String.t()} | :invalid
  def parse_identifier(id) when is_integer(id), do: {:integer, id}

  def parse_identifier(id) when is_binary(id) do
    cond do
      valid_uuid?(id) ->
        {:uuid, id}

      integer_string?(id) ->
        {int_id, ""} = Integer.parse(id)
        {:integer, int_id}

      true ->
        :invalid
    end
  end

  def parse_identifier(_), do: :invalid

  @doc """
  Checks if a string is a valid UUID format.

  Works with both UUIDv4 and UUIDv7 formats.

  ## Examples

      iex> PhoenixKit.UUID.valid_uuid?("019b5704-3680-7b95-9d82-ef16127f1fd2")
      true

      iex> PhoenixKit.UUID.valid_uuid?("not-a-uuid")
      false
  """
  @spec valid_uuid?(String.t()) :: boolean()
  def valid_uuid?(string) when is_binary(string) do
    Regex.match?(@uuid_regex, string)
  end

  def valid_uuid?(_), do: false

  @doc """
  Checks if an identifier is a UUID (vs integer).

  ## Examples

      iex> PhoenixKit.UUID.uuid?("019b5704-3680-7b95-9d82-ef16127f1fd2")
      true

      iex> PhoenixKit.UUID.uuid?("123")
      false

      iex> PhoenixKit.UUID.uuid?(123)
      false
  """
  @spec uuid?(any()) :: boolean()
  def uuid?(identifier) do
    case parse_identifier(identifier) do
      {:uuid, _} -> true
      _ -> false
    end
  end

  @doc """
  Checks if an identifier is an integer ID (vs UUID).

  ## Examples

      iex> PhoenixKit.UUID.integer_id?(123)
      true

      iex> PhoenixKit.UUID.integer_id?("123")
      true

      iex> PhoenixKit.UUID.integer_id?("019b5704-3680-7b95-9d82-ef16127f1fd2")
      false
  """
  @spec integer_id?(any()) :: boolean()
  def integer_id?(identifier) do
    case parse_identifier(identifier) do
      {:integer, _} -> true
      _ -> false
    end
  end

  @doc """
  Extracts the UUID from a record, returning nil if not present.

  ## Examples

      iex> PhoenixKit.UUID.extract_uuid(%User{uuid: "019b5704-..."})
      "019b5704-..."

      iex> PhoenixKit.UUID.extract_uuid(%User{uuid: nil})
      nil
  """
  @spec extract_uuid(struct()) :: String.t() | nil
  def extract_uuid(%{uuid: uuid}), do: uuid
  def extract_uuid(_), do: nil

  @doc """
  Extracts the integer ID from a record.

  ## Examples

      iex> PhoenixKit.UUID.extract_id(%User{id: 123})
      123
  """
  @spec extract_id(struct()) :: integer() | nil
  def extract_id(%{id: id}), do: id
  def extract_id(_), do: nil

  @doc """
  Returns the preferred identifier for a record.

  Prefers UUID if available, falls back to integer ID.

  ## Examples

      iex> PhoenixKit.UUID.preferred_identifier(%User{id: 123, uuid: "019b5704-..."})
      "019b5704-..."

      iex> PhoenixKit.UUID.preferred_identifier(%User{id: 123, uuid: nil})
      123
  """
  @spec preferred_identifier(struct()) :: String.t() | integer() | nil
  def preferred_identifier(%{uuid: uuid}) when is_binary(uuid), do: uuid
  def preferred_identifier(%{id: id}), do: id
  def preferred_identifier(_), do: nil

  # Private helpers

  defp integer_string?(string) do
    case Integer.parse(string) do
      {_, ""} -> true
      _ -> false
    end
  end

  # Build query options from keyword list, filtering to Ecto-supported options
  defp build_query_opts(opts) do
    opts
    |> Keyword.take([:prefix])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end
end
