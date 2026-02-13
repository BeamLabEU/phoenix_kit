defmodule PhoenixKit.Modules.Legal.ConsentLog do
  @moduledoc """
  Schema for consent log entries.

  Tracks user consent for cookies and data processing, supporting GDPR, CCPA,
  and other privacy regulations.

  ## Fields
    * `user_id` - The ID of the logged-in user (nil for anonymous)
    * `session_id` - Session identifier for anonymous tracking
    * `consent_type` - Type of consent (necessary, analytics, marketing, preferences)
    * `consent_given` - Whether consent was given
    * `consent_version` - Version of privacy/cookie policy
    * `ip_address` - IP address when consent was recorded
    * `user_agent_hash` - SHA256 hash of user agent for fingerprinting
    * `metadata` - Additional metadata about the consent

  ## Consent Types
    * `necessary` - Essential cookies (always required)
    * `analytics` - Performance and analytics cookies
    * `marketing` - Advertising and targeting cookies
    * `preferences` - Functionality and preference cookies

  ## Usage

      # Log consent for anonymous user
      ConsentLog.create(%{
        session_id: "abc123",
        consent_type: "analytics",
        consent_given: true,
        consent_version: "1.0",
        ip_address: "192.168.1.1"
      })

      # Log consent for logged-in user
      ConsentLog.create(%{
        user_id: 123,
        consent_type: "marketing",
        consent_given: false
      })

      # Get current consent status
      ConsentLog.get_consent_status(user_id: 123)
      ConsentLog.get_consent_status(session_id: "abc123")
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @type t :: %__MODULE__{
          id: integer() | nil,
          uuid: Ecto.UUID.t() | nil,
          user_id: integer() | nil,
          user_uuid: Ecto.UUID.t() | nil,
          session_id: String.t() | nil,
          consent_type: String.t(),
          consent_given: boolean(),
          consent_version: String.t() | nil,
          ip_address: String.t() | nil,
          user_agent_hash: String.t() | nil,
          metadata: map() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @consent_types ["necessary", "analytics", "marketing", "preferences"]

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_consent_logs" do
    field :id, :integer, read_after_writes: true
    # legacy
    field :user_id, :integer
    field :user_uuid, UUIDv7
    field :session_id, :string
    field :consent_type, :string
    field :consent_given, :boolean, default: false
    field :consent_version, :string
    field :ip_address, :string
    field :user_agent_hash, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns valid consent types.
  """
  @spec consent_types() :: list(String.t())
  def consent_types, do: @consent_types

  @doc """
  Creates a changeset for consent log entry.

  ## Required Fields
    * `:consent_type` - Type of consent

  ## Optional Fields
    * `:user_id` - User ID (for logged-in users)
    * `:session_id` - Session ID (for anonymous users)
    * `:consent_given` - Whether consent was given (default: false)
    * `:consent_version` - Version of policy
    * `:ip_address` - IP address
    * `:user_agent_hash` - Hashed user agent
    * `:metadata` - Additional metadata
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(consent_log, attrs) do
    consent_log
    |> cast(attrs, [
      :user_id,
      :user_uuid,
      :session_id,
      :consent_type,
      :consent_given,
      :consent_version,
      :ip_address,
      :user_agent_hash,
      :metadata
    ])
    |> validate_required([:consent_type])
    |> validate_inclusion(:consent_type, @consent_types)
    |> validate_user_or_session()
  end

  # Validate that either user_id, user_uuid, or session_id is present
  defp validate_user_or_session(changeset) do
    user_id = get_field(changeset, :user_id)
    user_uuid = get_field(changeset, :user_uuid)
    session_id = get_field(changeset, :session_id)

    if is_nil(user_id) and is_nil(user_uuid) and is_nil(session_id) do
      add_error(changeset, :base, "Either user_id, user_uuid, or session_id must be present")
    else
      changeset
    end
  end

  # ===================================
  # CRUD OPERATIONS
  # ===================================

  @doc """
  Create a new consent log entry.
  """
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    attrs = maybe_resolve_user_uuid(attrs)

    %__MODULE__{}
    |> changeset(attrs)
    |> repo().insert()
  end

  defp maybe_resolve_user_uuid(%{user_uuid: _} = attrs), do: attrs
  defp maybe_resolve_user_uuid(%{"user_uuid" => _} = attrs), do: attrs

  defp maybe_resolve_user_uuid(%{user_id: user_id} = attrs) when is_integer(user_id) do
    Map.put(attrs, :user_uuid, resolve_user_uuid(user_id))
  end

  defp maybe_resolve_user_uuid(%{"user_id" => user_id} = attrs) when is_integer(user_id) do
    Map.put(attrs, "user_uuid", resolve_user_uuid(user_id))
  end

  defp maybe_resolve_user_uuid(attrs), do: attrs

  @doc """
  Gets a single consent log by ID or UUID.

  Accepts integer ID, UUID string, or string-formatted integer.

  ## Examples

      iex> ConsentLog.get_consent_log(123)
      %ConsentLog{}

      iex> ConsentLog.get_consent_log("550e8400-e29b-41d4-a716-446655440000")
      %ConsentLog{}

      iex> ConsentLog.get_consent_log(999)
      nil
  """
  @spec get_consent_log(integer() | String.t()) :: t() | nil
  def get_consent_log(id) when is_integer(id) do
    repo().get_by(__MODULE__, id: id)
  end

  def get_consent_log(id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      repo().get_by(__MODULE__, uuid: id)
    else
      case Integer.parse(id) do
        {int_id, ""} -> get_consent_log(int_id)
        _ -> nil
      end
    end
  end

  def get_consent_log(_), do: nil

  @doc """
  Same as `get_consent_log/1`, but raises `Ecto.NoResultsError` if not found.

  ## Examples

      iex> ConsentLog.get_consent_log!(123)
      %ConsentLog{}

      iex> ConsentLog.get_consent_log!(999)
      ** (Ecto.NoResultsError)
  """
  @spec get_consent_log!(integer() | String.t()) :: t()
  def get_consent_log!(id) do
    case get_consent_log(id) do
      nil -> raise Ecto.NoResultsError, queryable: __MODULE__
      log -> log
    end
  end

  @doc """
  Get consent status for a user or session.

  Returns a map of consent_type => consent_given for the most recent entries.

  ## Options
    * `:user_id` - Get consent for logged-in user
    * `:session_id` - Get consent for anonymous session
  """
  @spec get_consent_status(keyword()) :: map()
  def get_consent_status(opts) do
    user_id = Keyword.get(opts, :user_id)
    user_uuid = Keyword.get(opts, :user_uuid)
    session_id = Keyword.get(opts, :session_id)

    query =
      from(c in __MODULE__,
        select: %{consent_type: c.consent_type, consent_given: c.consent_given},
        order_by: [desc: c.inserted_at]
      )

    query =
      cond do
        user_id -> where(query, [c], c.user_id == ^user_id)
        user_uuid -> where(query, [c], c.user_uuid == ^user_uuid)
        session_id -> where(query, [c], c.session_id == ^session_id)
        true -> query
      end

    query
    |> repo().all()
    |> Enum.uniq_by(& &1.consent_type)
    |> Map.new(fn %{consent_type: type, consent_given: given} -> {type, given} end)
  rescue
    _ -> %{}
  end

  @doc """
  Log consent for multiple types at once.

  ## Parameters
    * `consents` - Map of consent_type => consent_given
    * `opts` - Options including :user_id, :session_id, :ip_address, etc.

  ## Example

      ConsentLog.log_consents(
        %{"analytics" => true, "marketing" => false},
        user_id: 123,
        consent_version: "1.0"
      )
  """
  @spec log_consents(map(), keyword()) :: {:ok, list(t())} | {:error, term()}
  def log_consents(consents, opts) when is_map(consents) do
    user_id = Keyword.get(opts, :user_id)

    base_attrs = %{
      user_id: user_id,
      user_uuid: Keyword.get(opts, :user_uuid) || resolve_user_uuid(user_id),
      session_id: Keyword.get(opts, :session_id),
      consent_version: Keyword.get(opts, :consent_version),
      ip_address: Keyword.get(opts, :ip_address),
      user_agent_hash: Keyword.get(opts, :user_agent_hash),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    results =
      Enum.map(consents, fn {consent_type, consent_given} ->
        attrs =
          Map.merge(base_attrs, %{
            consent_type: consent_type,
            consent_given: consent_given
          })

        create(attrs)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, log} -> log end)}
    else
      {:error, errors}
    end
  end

  @doc """
  Hash user agent string for privacy-focused storage.
  """
  @spec hash_user_agent(String.t()) :: String.t()
  def hash_user_agent(user_agent) when is_binary(user_agent) do
    :crypto.hash(:sha256, user_agent)
    |> Base.encode16(case: :lower)
  end

  def hash_user_agent(_), do: nil

  # ===================================
  # PRIVATE HELPERS
  # ===================================

  # Resolves user UUID from a user struct or integer user_id (dual-write)
  defp resolve_user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid

  defp resolve_user_uuid(user_id) when is_integer(user_id) do
    import Ecto.Query, only: [from: 2]
    alias PhoenixKit.Users.Auth.User
    from(u in User, where: u.id == ^user_id, select: u.uuid) |> repo().one()
  end

  defp resolve_user_uuid(_), do: nil

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end
end
