defmodule PhoenixKit.AI.Account do
  @moduledoc """
  AI provider account schema for PhoenixKit AI system.

  Stores AI provider credentials and configuration for making API requests.
  Currently supports OpenRouter, with architecture designed for future providers.

  ## Schema Fields

  ### Account Identity
  - `name`: Display name for the account (e.g., "Main OpenRouter")
  - `provider`: Provider type (currently "openrouter")
  - `enabled`: Whether the account is active

  ### Credentials
  - `api_key`: Provider API key (stored in plain text like OAuth credentials)
  - `base_url`: Optional custom base URL for the provider

  ### Configuration
  - `settings`: Provider-specific settings (JSON)
    - For OpenRouter: `http_referer`, `x_title` headers
  - `last_validated_at`: Last successful API key validation timestamp

  ## Provider Types

  Currently supported:
  - `openrouter` - OpenRouter.ai (default)

  Future providers (architecture ready):
  - `openai` - OpenAI direct
  - `anthropic` - Anthropic direct
  - `google` - Google AI

  ## Usage Examples

      # Create OpenRouter account
      {:ok, account} = PhoenixKit.AI.create_account(%{
        name: "Main OpenRouter",
        provider: "openrouter",
        api_key: "sk-or-v1-...",
        settings: %{
          "http_referer" => "https://myapp.com",
          "x_title" => "My Application"
        }
      })

      # Update account
      {:ok, account} = PhoenixKit.AI.update_account(account, %{
        name: "Production OpenRouter"
      })

      # Validate API key
      {:ok, account} = PhoenixKit.AI.validate_account(account)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @valid_providers ~w(openrouter)

  @derive {Jason.Encoder,
           only: [
             :id,
             :name,
             :provider,
             :base_url,
             :settings,
             :enabled,
             :last_validated_at,
             :inserted_at,
             :updated_at
           ]}

  schema "phoenix_kit_ai_accounts" do
    field :name, :string
    field :provider, :string, default: "openrouter"
    field :api_key, :string
    field :base_url, :string
    field :settings, :map, default: %{}
    field :enabled, :boolean, default: true
    field :last_validated_at, :utc_datetime_usec

    has_many :requests, PhoenixKit.AI.Request, foreign_key: :account_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Creates a changeset for account creation and updates.
  """
  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :name,
      :provider,
      :api_key,
      :base_url,
      :settings,
      :enabled,
      :last_validated_at
    ])
    |> validate_required([:name, :provider, :api_key])
    |> validate_inclusion(:provider, @valid_providers)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_api_key_format()
    |> maybe_set_default_base_url()
  end

  @doc """
  Creates a changeset for updating the last_validated_at timestamp.
  """
  def validation_changeset(account) do
    change(account, last_validated_at: DateTime.utc_now())
  end

  @doc """
  Returns the list of valid provider types.
  """
  def valid_providers, do: @valid_providers

  @doc """
  Returns provider options for form selects.
  """
  def provider_options do
    [
      {"OpenRouter", "openrouter"}
    ]
  end

  @doc """
  Returns the default base URL for a provider.
  """
  def default_base_url("openrouter"), do: "https://openrouter.ai/api/v1"
  def default_base_url(_), do: nil

  @doc """
  Masks the API key for display, showing only the last 4 characters.
  """
  def masked_api_key(nil), do: "Not set"
  def masked_api_key(""), do: "Not set"

  def masked_api_key(api_key) when is_binary(api_key) do
    case String.length(api_key) do
      len when len <= 8 -> String.duplicate("*", len)
      len -> String.duplicate("*", len - 4) <> String.slice(api_key, -4..-1)
    end
  end

  @doc """
  Returns a display label for the provider.
  """
  def provider_label("openrouter"), do: "OpenRouter"
  def provider_label(provider), do: provider

  @doc """
  Checks if the account has been validated recently (within the last 24 hours).
  """
  def recently_validated?(%__MODULE__{last_validated_at: nil}), do: false

  def recently_validated?(%__MODULE__{last_validated_at: validated_at}) do
    case DateTime.diff(DateTime.utc_now(), validated_at, :hour) do
      hours when hours < 24 -> true
      _ -> false
    end
  end

  # Private functions

  defp validate_api_key_format(changeset) do
    provider = get_field(changeset, :provider)
    api_key = get_change(changeset, :api_key)

    if api_key do
      case provider do
        "openrouter" ->
          if String.starts_with?(api_key, "sk-or-") or String.length(api_key) >= 32 do
            changeset
          else
            add_error(changeset, :api_key, "doesn't look like a valid OpenRouter API key")
          end

        _ ->
          changeset
      end
    else
      changeset
    end
  end

  defp maybe_set_default_base_url(changeset) do
    provider = get_field(changeset, :provider)
    base_url = get_field(changeset, :base_url)

    if is_nil(base_url) or base_url == "" do
      put_change(changeset, :base_url, default_base_url(provider))
    else
      changeset
    end
  end
end
