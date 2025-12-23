defmodule PhoenixKit.AI.OpenRouterClient do
  @moduledoc """
  OpenRouter API client for PhoenixKit AI system.

  Provides functions for interacting with the OpenRouter API, including:
  - API key validation
  - Model discovery (fetching available models)
  - Building request headers

  ## OpenRouter API Reference

  - Base URL: https://openrouter.ai/api/v1
  - Authentication: Bearer token in Authorization header
  - Optional headers: HTTP-Referer, X-Title (for rankings)

  ## Usage Examples

      # Validate an API key
      case PhoenixKit.AI.OpenRouterClient.validate_api_key("sk-or-v1-...") do
        {:ok, %{credits: credits}} -> IO.puts("Valid! Credits: \#{credits}")
        {:error, reason} -> IO.puts("Invalid: \#{reason}")
      end

      # Fetch available models
      {:ok, models} = PhoenixKit.AI.OpenRouterClient.fetch_models("sk-or-v1-...")
  """

  require Logger

  @base_url "https://openrouter.ai/api/v1"
  @timeout 30_000

  @doc """
  Validates an OpenRouter API key by making a request to the /models endpoint.

  Returns `{:ok, %{valid: true}}` on success, `{:error, reason}` on failure.
  """
  def validate_api_key(api_key) when is_binary(api_key) do
    # Use /models endpoint for validation as it's more reliable
    url = "#{@base_url}/models"
    headers = build_headers(api_key)

    Logger.debug("Validating API key via #{url}")

    case http_get(url, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => data}} when is_list(data) ->
            Logger.debug("API key valid - found #{length(data)} models")
            {:ok, %{valid: true, models_count: length(data)}}

          {:ok, _data} ->
            {:ok, %{valid: true}}

          {:error, _} ->
            {:error, "Invalid JSON response"}
        end

      {:ok, %{status_code: 401, body: body}} ->
        Logger.warning("OpenRouter 401 response: #{body}")
        {:error, "Invalid API key"}

      {:ok, %{status_code: 403, body: body}} ->
        Logger.warning("OpenRouter 403 response: #{body}")
        {:error, "API key forbidden"}

      {:ok, %{status_code: status, body: body}} ->
        Logger.warning("OpenRouter API key validation failed: #{status} - #{body}")
        {:error, "API error: #{status}"}

      {:error, reason} ->
        Logger.warning("OpenRouter API key validation error: #{inspect(reason)}")
        {:error, "Connection error: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetches available models from OpenRouter.

  Returns `{:ok, models}` where models is a list of model objects,
  or `{:error, reason}` on failure.

  ## Options
  - `:model_type` - Filter by model type: `:text`, `:vision`, `:image_gen`, `:all` (default: `:all`)
  - `:http_referer` - Site URL for rankings
  - `:x_title` - Site title for rankings

  ## Model Object Structure

  Each model has:
  - `id` - Model identifier (e.g., "anthropic/claude-3-opus")
  - `name` - Display name
  - `description` - Model description
  - `pricing` - Pricing information (prompt/completion costs)
  - `context_length` - Maximum context window
  - `architecture` - Model architecture details
  """
  def fetch_models(api_key, opts \\ []) do
    url = "#{@base_url}/models"
    headers = build_headers(api_key, opts)
    model_type = Keyword.get(opts, :model_type, :all)

    case http_get(url, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"data" => models}} when is_list(models) ->
            {:ok, normalize_models(models, model_type)}

          {:ok, _} ->
            {:error, "Unexpected response format"}

          {:error, _} ->
            {:error, "Invalid JSON response"}
        end

      {:ok, %{status_code: 401}} ->
        {:error, "Invalid API key"}

      {:ok, %{status_code: status, body: body}} ->
        Logger.warning("OpenRouter models fetch failed: #{status} - #{body}")
        {:error, "API error: #{status}"}

      {:error, reason} ->
        Logger.warning("OpenRouter models fetch error: #{inspect(reason)}")
        {:error, "Connection error: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetches models and groups them by provider.

  ## Options
  - `:model_type` - Filter by model type: `:text`, `:vision`, `:image_gen`, `:all` (default: `:text`)

  Returns a map where keys are provider names and values are lists of models.
  """
  def fetch_models_grouped(api_key, opts \\ []) do
    # Default to :text for backward compatibility
    opts = Keyword.put_new(opts, :model_type, :text)

    case fetch_models(api_key, opts) do
      {:ok, models} ->
        grouped =
          models
          |> Enum.group_by(fn model ->
            case String.split(model["id"], "/") do
              [provider | _] -> provider
              _ -> "other"
            end
          end)
          |> Enum.sort_by(fn {provider, _} -> provider end)

        {:ok, grouped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches models by type and groups them by provider.

  ## Model Types
  - `:text` - Text/chat completion models (text->text)
  - `:vision` - Vision/multimodal models (text+image->text)
  - `:image_gen` - Image generation models (text+image->text+image)
  - `:all` - All models without filtering

  ## Examples

      {:ok, grouped} = fetch_models_by_type(api_key, :vision)
  """
  def fetch_models_by_type(api_key, model_type, opts \\ [])
      when model_type in [:text, :vision, :image_gen, :all] do
    opts = Keyword.put(opts, :model_type, model_type)
    fetch_models_grouped(api_key, opts)
  end

  @doc """
  Fetches embedding models from OpenRouter.

  Note: Embedding models are fetched from a hardcoded list as OpenRouter
  doesn't return them from the /models endpoint. The actual embedding
  request goes to /api/v1/embeddings.

  Returns `{:ok, models}` with a list of known embedding models.
  """
  def fetch_embedding_models(_api_key, _opts \\ []) do
    # OpenRouter embedding models - these are not returned by /models endpoint
    # They must be used via POST /api/v1/embeddings
    models = [
      %{
        "id" => "openai/text-embedding-3-large",
        "name" => "Text Embedding 3 Large",
        "description" => "OpenAI's most capable embedding model",
        "context_length" => 8191,
        "dimensions" => 3072,
        "pricing" => %{"prompt" => 0.00000013, "completion" => 0}
      },
      %{
        "id" => "openai/text-embedding-3-small",
        "name" => "Text Embedding 3 Small",
        "description" => "OpenAI's efficient embedding model",
        "context_length" => 8191,
        "dimensions" => 1536,
        "pricing" => %{"prompt" => 0.00000002, "completion" => 0}
      },
      %{
        "id" => "openai/text-embedding-ada-002",
        "name" => "Text Embedding Ada 002",
        "description" => "OpenAI's legacy embedding model",
        "context_length" => 8191,
        "dimensions" => 1536,
        "pricing" => %{"prompt" => 0.0000001, "completion" => 0}
      },
      %{
        "id" => "cohere/embed-english-v3.0",
        "name" => "Embed English v3.0",
        "description" => "Cohere's English embedding model",
        "context_length" => 512,
        "dimensions" => 1024,
        "pricing" => %{"prompt" => 0.0000001, "completion" => 0}
      },
      %{
        "id" => "cohere/embed-multilingual-v3.0",
        "name" => "Embed Multilingual v3.0",
        "description" => "Cohere's multilingual embedding model",
        "context_length" => 512,
        "dimensions" => 1024,
        "pricing" => %{"prompt" => 0.0000001, "completion" => 0}
      },
      %{
        "id" => "voyage/voyage-3",
        "name" => "Voyage 3",
        "description" => "Voyage AI's general-purpose embedding model",
        "context_length" => 32_000,
        "dimensions" => 1024,
        "pricing" => %{"prompt" => 0.00000006, "completion" => 0}
      },
      %{
        "id" => "voyage/voyage-3-lite",
        "name" => "Voyage 3 Lite",
        "description" => "Voyage AI's lightweight embedding model",
        "context_length" => 32_000,
        "dimensions" => 512,
        "pricing" => %{"prompt" => 0.00000002, "completion" => 0}
      },
      %{
        "id" => "voyage/voyage-code-3",
        "name" => "Voyage Code 3",
        "description" => "Voyage AI's code-optimized embedding model",
        "context_length" => 32_000,
        "dimensions" => 1024,
        "pricing" => %{"prompt" => 0.00000006, "completion" => 0}
      },
      %{
        "id" => "qwen/qwen3-embedding-8b",
        "name" => "Qwen3 Embedding 8B",
        "description" => "Qwen's 8B parameter embedding model",
        "context_length" => 8192,
        "dimensions" => 4096,
        "pricing" => %{"prompt" => 0.00000002, "completion" => 0}
      }
    ]

    {:ok, models}
  end

  @doc """
  Fetches embedding models grouped by provider.
  """
  def fetch_embedding_models_grouped(api_key, opts \\ []) do
    {:ok, models} = fetch_embedding_models(api_key, opts)

    grouped =
      models
      |> Enum.group_by(fn model ->
        case String.split(model["id"], "/") do
          [provider | _] -> provider
          _ -> "other"
        end
      end)
      |> Enum.sort_by(fn {provider, _} -> provider end)

    {:ok, grouped}
  end

  @doc """
  Builds HTTP headers for OpenRouter API requests.

  ## Options
  - `:http_referer` - Site URL for rankings
  - `:x_title` - Site title for rankings
  - `:include_usage` - Include detailed usage/cost info (default: true for completions)
  """
  def build_headers(api_key, opts \\ []) do
    base_headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    # Request extra data from OpenRouter including cost information
    # X-Include-Usage: true returns detailed usage including cost
    include_usage = Keyword.get(opts, :include_usage, true)

    optional_headers =
      []
      |> maybe_add_header("HTTP-Referer", Keyword.get(opts, :http_referer))
      |> maybe_add_header("X-Title", Keyword.get(opts, :x_title))
      |> maybe_add_header("X-Include-Usage", if(include_usage, do: "true", else: nil))

    base_headers ++ optional_headers
  end

  @doc """
  Builds headers from an Account struct's settings.
  """
  def build_headers_from_account(%{api_key: api_key, settings: settings}) do
    opts =
      []
      |> maybe_add_opt(:http_referer, settings["http_referer"])
      |> maybe_add_opt(:x_title, settings["x_title"])

    build_headers(api_key, opts)
  end

  @doc """
  Builds headers from an Endpoint struct's provider_settings.
  """
  def build_headers_from_endpoint(%{api_key: api_key, provider_settings: settings}) do
    settings = settings || %{}

    opts =
      []
      |> maybe_add_opt(:http_referer, settings["http_referer"])
      |> maybe_add_opt(:x_title, settings["x_title"])

    build_headers(api_key, opts)
  end

  @doc """
  Returns the base URL for OpenRouter API.
  """
  def base_url, do: @base_url

  @doc """
  Formats a model for display in a select dropdown.

  Returns `{label, value}` tuple.
  """
  def model_option(model) do
    label =
      case model do
        %{"name" => name, "id" => id} when name != "" ->
          provider = extract_provider(id)
          "#{name} (#{provider})"

        %{"id" => id} ->
          id

        _ ->
          "Unknown"
      end

    value = model["id"] || ""

    {label, value}
  end

  @doc """
  Extracts the provider name from a model ID.

  ## Examples

      iex> extract_provider("anthropic/claude-3-opus")
      "Anthropic"

      iex> extract_provider("openai/gpt-4")
      "OpenAI"
  """
  def extract_provider(model_id) when is_binary(model_id) do
    case String.split(model_id, "/") do
      [provider | _] -> humanize_provider(provider)
      _ -> "Unknown"
    end
  end

  def extract_provider(_), do: "Unknown"

  @doc """
  Extracts the model name without provider prefix.
  """
  def extract_model_name(model_id) when is_binary(model_id) do
    case String.split(model_id, "/") do
      [_provider, name | _] -> name
      [name] -> name
      _ -> model_id
    end
  end

  def extract_model_name(_), do: "Unknown"

  # Private functions

  defp http_get(url, headers) do
    # Convert headers list to map format for Req
    headers_map = Map.new(headers)

    case Req.get(url,
           headers: headers_map,
           receive_timeout: @timeout,
           connect_options: [timeout: @timeout]
         ) do
      {:ok, %Req.Response{status: status, body: body}} ->
        # Req automatically decodes JSON, so encode it back to string for consistency
        body_string =
          if is_map(body) or is_list(body) do
            Jason.encode!(body)
          else
            to_string(body)
          end

        {:ok, %{status_code: status, body: body_string}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp normalize_models(models, model_type) do
    models
    |> Enum.filter(&model_matches_type?(&1, model_type))
    |> Enum.map(fn model ->
      top_provider = model["top_provider"] || %{}

      %{
        "id" => model["id"],
        "name" => model["name"] || extract_model_name(model["id"]),
        "description" => model["description"],
        "context_length" => model["context_length"],
        "max_completion_tokens" => top_provider["max_completion_tokens"],
        "supported_parameters" => model["supported_parameters"] || [],
        "pricing" => normalize_pricing(model["pricing"]),
        "architecture" => model["architecture"],
        "top_provider" => top_provider
      }
    end)
  end

  # Filter models by type based on architecture.modality
  # OpenRouter models have architecture.modality indicating input->output types:
  # - "text->text" = pure text chat/completion
  # - "text+image->text" = multimodal input, text output (vision models)
  # - "text->text+image" = pure text-to-image generation
  # - "text+image->text+image" = multimodal with image generation (can edit images)

  defp model_matches_type?(_model, :all), do: true

  defp model_matches_type?(model, :text) do
    get_modality(model) == "text->text"
  end

  defp model_matches_type?(model, :vision) do
    get_modality(model) == "text+image->text"
  end

  defp model_matches_type?(model, :image_gen) do
    modality = get_modality(model)
    # Include both pure text-to-image and multimodal image generation
    modality == "text->text+image" or modality == "text+image->text+image"
  end

  defp get_modality(model) do
    architecture = model["architecture"] || %{}
    architecture["modality"] || ""
  end

  @doc """
  Fetches details for a specific model by ID.

  Returns `{:ok, model}` or `{:error, reason}`.
  """
  def fetch_model(api_key, model_id, opts \\ []) do
    case fetch_models(api_key, opts) do
      {:ok, models} ->
        case Enum.find(models, fn m -> m["id"] == model_id end) do
          nil -> {:error, "Model not found"}
          model -> {:ok, model}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Checks if a model supports a specific parameter.

  ## Examples

      iex> model_supports_parameter?(model, "temperature")
      true

      iex> model_supports_parameter?(model, "tools")
      false
  """
  def model_supports_parameter?(model, param) when is_map(model) do
    supported = model["supported_parameters"] || []
    param in supported
  end

  @doc """
  Gets the effective max tokens for a model.

  Returns the model's max_completion_tokens if available,
  otherwise falls back to a percentage of context_length.
  """
  def get_model_max_tokens(model) when is_map(model) do
    cond do
      model["max_completion_tokens"] ->
        model["max_completion_tokens"]

      model["context_length"] ->
        # Default to 25% of context length if max_completion_tokens not specified
        div(model["context_length"], 4)

      true ->
        4096
    end
  end

  defp normalize_pricing(nil), do: %{"prompt" => 0, "completion" => 0}

  defp normalize_pricing(pricing) when is_map(pricing) do
    %{
      "prompt" => parse_price(pricing["prompt"]),
      "completion" => parse_price(pricing["completion"])
    }
  end

  defp parse_price(nil), do: 0
  defp parse_price(price) when is_number(price), do: price

  defp parse_price(price) when is_binary(price) do
    case Float.parse(price) do
      {float, _} -> float
      :error -> 0
    end
  end

  defp parse_price(_), do: 0

  defp humanize_provider("anthropic"), do: "Anthropic"
  defp humanize_provider("openai"), do: "OpenAI"
  defp humanize_provider("google"), do: "Google"
  defp humanize_provider("meta-llama"), do: "Meta"
  defp humanize_provider("mistralai"), do: "Mistral"
  defp humanize_provider("cohere"), do: "Cohere"
  defp humanize_provider("perplexity"), do: "Perplexity"
  defp humanize_provider("deepseek"), do: "DeepSeek"
  defp humanize_provider("microsoft"), do: "Microsoft"
  defp humanize_provider("x-ai"), do: "xAI"
  defp humanize_provider("qwen"), do: "Qwen"

  defp humanize_provider(provider) do
    provider
    |> String.split("-")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp maybe_add_header(headers, _name, nil), do: headers
  defp maybe_add_header(headers, _name, ""), do: headers
  defp maybe_add_header(headers, name, value), do: [{name, value} | headers]

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, _key, ""), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
