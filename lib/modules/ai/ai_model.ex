defmodule PhoenixKit.Modules.AI.AIModel do
  @moduledoc """
  Struct representing a normalized AI model from the OpenRouter API.

  Constructed in `OpenRouterClient.normalize_models/2` from JSON API responses.
  Consumed by `EndpointForm` LiveView for model selection and configuration.

  ## Fields

  - `id` - Model identifier (e.g., `"anthropic/claude-3-opus"`)
  - `name` - Human-readable name (e.g., `"Claude 3 Opus"`)
  - `description` - Model description
  - `context_length` - Maximum context window size in tokens
  - `max_completion_tokens` - Maximum output tokens
  - `supported_parameters` - List of supported parameters (e.g., `["temperature", "top_p"]`)
  - `pricing` - Pricing info map with `"prompt"` and `"completion"` keys
  - `architecture` - Architecture info map with `"modality"` key
  - `top_provider` - Top provider metadata map
  """

  @enforce_keys [:id]
  defstruct [
    :id,
    :name,
    :description,
    :context_length,
    :max_completion_tokens,
    supported_parameters: [],
    pricing: %{},
    architecture: %{},
    top_provider: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          context_length: integer() | nil,
          max_completion_tokens: integer() | nil,
          supported_parameters: [String.t()],
          pricing: map(),
          architecture: map(),
          top_provider: map()
        }
end
