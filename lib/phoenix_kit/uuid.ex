defmodule PhoenixKit.UUID do
  @moduledoc """
  TEMPORARY: Dual ID lookup utilities for UUID migration transition.

  > #### Transitional Module {: .warning}
  >
  > This module exists ONLY for the transition period while PhoenixKit
  > migrates from bigserial to UUID primary keys. It will be **removed
  > in PhoenixKit 2.0** when all tables use UUID as the primary key.
  >
  > - For UUID generation, use `UUIDv7.generate()` directly
  > - For lookups, use standard `Repo.get/2` with UUIDs after 2.0
  >
  > **DELETE THIS MODULE** when PhoenixKit switches to UUID-native PKs.

  ## Purpose

  This module provides helper functions for working with dual ID systems
  (bigserial + UUID column) during the transition period. It enables parent
  applications to accept either integer IDs or UUIDs in URLs/APIs.

  ## When to Use

  Use this module in parent application controllers/LiveViews when you want
  to accept either ID type in user-facing URLs:

      # In your controller - accepts /users/5 OR /users/019b57...
      def show(conn, %{"id" => identifier}) do
        user = PhoenixKit.UUID.get(User, identifier)
      end

  ## When NOT to Use

  - PhoenixKit internal code still uses integer IDs for all operations
  - Foreign key relationships remain integer-based
  - If you know you have an integer ID, use `Repo.get/2` directly

  ## Usage Examples

      # Dual lookup (auto-detects type)
      PhoenixKit.UUID.get(User, "123")           # integer lookup
      PhoenixKit.UUID.get(User, "019b57...")     # UUID lookup

      # With multi-tenant prefix
      PhoenixKit.UUID.get(User, id, prefix: "tenant_123")

      # UUID generation (prefer UUIDv7.generate() directly)
      PhoenixKit.UUID.generate()

  ## Migration Timeline

  1. **V40 (current)**: UUID columns added, this helper available
  2. **Transition**: Parent apps can start using UUIDs in URLs
  3. **2.0**: UUID becomes PK, this module is deleted
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
