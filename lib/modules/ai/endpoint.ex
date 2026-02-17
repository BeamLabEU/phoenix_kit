defmodule PhoenixKit.Modules.AI.Endpoint do
  @moduledoc """
  AI endpoint schema for PhoenixKit AI system.

  An endpoint is a unified configuration that combines provider credentials,
  model selection, and generation parameters into a single entity. Each endpoint
  represents one complete AI configuration ready for making API requests.

  ## Schema Fields

  ### Identity
  - `name`: Display name for the endpoint (e.g., "Claude Fast", "GPT-4 Creative")
  - `description`: Optional description of the endpoint's purpose

  ### Provider Configuration
  - `provider`: Provider type (currently "openrouter")
  - `api_key`: Provider API key
  - `base_url`: Optional custom base URL for the provider
  - `provider_settings`: Provider-specific settings (JSON)
    - For OpenRouter: `http_referer`, `x_title` headers

  ### Model Configuration
  - `model`: AI model identifier (e.g., "anthropic/claude-3-haiku")

  ### Generation Parameters
  - `temperature`: Sampling temperature (0-2, default: 0.7)
  - `max_tokens`: Maximum tokens to generate (nil = model default)
  - `top_p`: Nucleus sampling threshold (0-1)
  - `top_k`: Top-k sampling parameter
  - `frequency_penalty`: Frequency penalty (-2 to 2)
  - `presence_penalty`: Presence penalty (-2 to 2)
  - `repetition_penalty`: Repetition penalty (0-2)
  - `stop`: Stop sequences (array of strings)
  - `seed`: Random seed for reproducibility

  ### Image Generation Parameters
  - `image_size`: Image size (e.g., "1024x1024", "1792x1024")
  - `image_quality`: Image quality ("standard", "hd")

  ### Embeddings Parameters
  - `dimensions`: Embedding dimensions (model-specific)

  ### Status
  - `enabled`: Whether the endpoint is active
  - `sort_order`: Display order for listing
  - `last_validated_at`: Last successful API key validation

  ## Usage Examples

      # Create an endpoint
      {:ok, endpoint} = PhoenixKit.Modules.AI.create_endpoint(%{
        name: "Claude Fast",
        provider: "openrouter",
        api_key: "sk-or-v1-...",
        model: "anthropic/claude-3-haiku",
        temperature: 0.7
      })

      # Use the endpoint
      {:ok, response} = PhoenixKit.Modules.AI.ask(endpoint.id, "Hello!")
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @valid_providers ~w(openrouter)

  @derive {Jason.Encoder,
           only: [
             :id,
             :uuid,
             :name,
             :description,
             :provider,
             :base_url,
             :provider_settings,
             :model,
             :temperature,
             :max_tokens,
             :top_p,
             :top_k,
             :frequency_penalty,
             :presence_penalty,
             :repetition_penalty,
             :stop,
             :seed,
             :image_size,
             :image_quality,
             :dimensions,
             :reasoning_enabled,
             :reasoning_effort,
             :reasoning_max_tokens,
             :reasoning_exclude,
             :enabled,
             :sort_order,
             :last_validated_at,
             :inserted_at,
             :updated_at
           ]}

  schema "phoenix_kit_ai_endpoints" do
    # Legacy integer ID - DB generates, Ecto reads back
    field :id, :integer, read_after_writes: true

    # Identity
    field :name, :string
    field :description, :string

    # Provider configuration
    field :provider, :string, default: "openrouter"
    field :api_key, :string
    field :base_url, :string
    field :provider_settings, :map, default: %{}

    # Model configuration
    field :model, :string

    # Generation parameters
    field :temperature, :float, default: 0.7
    field :max_tokens, :integer
    field :top_p, :float
    field :top_k, :integer
    field :frequency_penalty, :float
    field :presence_penalty, :float
    field :repetition_penalty, :float
    field :stop, {:array, :string}
    field :seed, :integer

    # Image generation parameters
    field :image_size, :string
    field :image_quality, :string

    # Embeddings parameters
    field :dimensions, :integer

    # Reasoning/thinking parameters (for models like DeepSeek R1, Qwen QwQ, etc.)
    field :reasoning_enabled, :boolean
    field :reasoning_effort, :string
    field :reasoning_max_tokens, :integer
    field :reasoning_exclude, :boolean

    # Status
    field :enabled, :boolean, default: true
    field :sort_order, :integer, default: 0
    field :last_validated_at, :utc_datetime

    has_many :requests, PhoenixKit.Modules.AI.Request,
      foreign_key: :endpoint_uuid,
      references: :uuid

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for endpoint creation and updates.
  """
  def changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [
      :name,
      :description,
      :provider,
      :api_key,
      :base_url,
      :provider_settings,
      :model,
      :temperature,
      :max_tokens,
      :top_p,
      :top_k,
      :frequency_penalty,
      :presence_penalty,
      :repetition_penalty,
      :stop,
      :seed,
      :image_size,
      :image_quality,
      :dimensions,
      :reasoning_enabled,
      :reasoning_effort,
      :reasoning_max_tokens,
      :reasoning_exclude,
      :enabled,
      :sort_order,
      :last_validated_at
    ])
    |> validate_required([:name, :provider, :api_key, :model])
    |> validate_inclusion(:provider, @valid_providers)
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_api_key_format()
    |> validate_temperature()
    |> validate_penalties()
    |> validate_reasoning()
    |> maybe_set_default_base_url()
  end

  @doc """
  Creates a changeset for updating the last_validated_at timestamp.
  """
  def validation_changeset(endpoint) do
    change(endpoint, last_validated_at: DateTime.utc_now())
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
  Checks if the endpoint has been validated recently (within the last 24 hours).
  """
  def recently_validated?(%__MODULE__{last_validated_at: nil}), do: false

  def recently_validated?(%__MODULE__{last_validated_at: validated_at}) do
    case DateTime.diff(DateTime.utc_now(), validated_at, :hour) do
      hours when hours < 24 -> true
      _ -> false
    end
  end

  @doc """
  Extracts the model name without the provider prefix.
  """
  def short_model_name(nil), do: nil
  def short_model_name(""), do: nil

  def short_model_name(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [_provider, name] -> name
      [name] -> name
    end
  end

  @doc """
  Returns image size options for form selects.
  """
  def image_size_options do
    [
      {"1024x1024 (Square)", "1024x1024"},
      {"1792x1024 (Landscape)", "1792x1024"},
      {"1024x1792 (Portrait)", "1024x1792"}
    ]
  end

  @doc """
  Returns image quality options for form selects.
  """
  def image_quality_options do
    [
      {"Standard", "standard"},
      {"HD", "hd"}
    ]
  end

  @doc """
  Returns reasoning effort options for form selects.
  """
  def reasoning_effort_options do
    [
      {"None (disabled)", "none"},
      {"Minimal (~10%)", "minimal"},
      {"Low (~20%)", "low"},
      {"Medium (~50%)", "medium"},
      {"High (~80%)", "high"},
      {"Extra High (~95%)", "xhigh"}
    ]
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

  defp validate_temperature(changeset) do
    case get_field(changeset, :temperature) do
      nil -> changeset
      temp when temp >= 0 and temp <= 2 -> changeset
      _ -> add_error(changeset, :temperature, "must be between 0 and 2")
    end
  end

  defp validate_penalties(changeset) do
    changeset
    |> validate_penalty(:frequency_penalty, -2, 2)
    |> validate_penalty(:presence_penalty, -2, 2)
    |> validate_penalty(:repetition_penalty, 0, 2)
    |> validate_penalty(:top_p, 0, 1)
  end

  defp validate_penalty(changeset, field, min, max) do
    case get_field(changeset, field) do
      nil -> changeset
      val when val >= min and val <= max -> changeset
      _ -> add_error(changeset, field, "must be between #{min} and #{max}")
    end
  end

  @valid_reasoning_efforts ~w(none minimal low medium high xhigh)

  defp validate_reasoning(changeset) do
    changeset
    |> validate_reasoning_effort()
    |> validate_reasoning_max_tokens()
  end

  defp validate_reasoning_effort(changeset) do
    case get_field(changeset, :reasoning_effort) do
      nil ->
        changeset

      "" ->
        changeset

      effort when effort in @valid_reasoning_efforts ->
        changeset

      _ ->
        add_error(
          changeset,
          :reasoning_effort,
          "must be one of: #{Enum.join(@valid_reasoning_efforts, ", ")}"
        )
    end
  end

  defp validate_reasoning_max_tokens(changeset) do
    case get_field(changeset, :reasoning_max_tokens) do
      nil ->
        changeset

      tokens when is_integer(tokens) and tokens >= 1024 and tokens <= 32_000 ->
        changeset

      tokens when is_integer(tokens) ->
        add_error(changeset, :reasoning_max_tokens, "must be between 1024 and 32,000")

      _ ->
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
