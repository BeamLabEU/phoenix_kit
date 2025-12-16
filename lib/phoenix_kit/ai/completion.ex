defmodule PhoenixKit.AI.Completion do
  @moduledoc """
  OpenRouter completion client for making AI API calls.

  This module handles the actual HTTP requests to OpenRouter's chat completions
  and other endpoints. It's used internally by `PhoenixKit.AI` public functions.

  ## Supported Endpoints

  - `/chat/completions` - Text and vision completions
  - `/embeddings` - Text embeddings (planned)
  - `/images/generations` - Image generation (planned)
  """

  require Logger

  alias PhoenixKit.AI.OpenRouterClient

  @base_url "https://openrouter.ai/api/v1"
  @timeout 120_000

  @doc """
  Makes a chat completion request to OpenRouter.

  ## Parameters

  - `account` - The AI account struct with API key
  - `model` - Model ID (e.g., "anthropic/claude-3-haiku")
  - `messages` - List of message maps with `:role` and `:content`
  - `opts` - Additional options (temperature, max_tokens, etc.)

  ## Options

  - `:temperature` - Sampling temperature (0-2)
  - `:max_tokens` - Maximum tokens in response
  - `:top_p` - Nucleus sampling parameter
  - `:top_k` - Top-k sampling parameter
  - `:frequency_penalty` - Frequency penalty (-2 to 2)
  - `:presence_penalty` - Presence penalty (-2 to 2)
  - `:repetition_penalty` - Repetition penalty (0 to 2)
  - `:stop` - Stop sequences (list of strings)
  - `:seed` - Random seed for reproducibility
  - `:stream` - Enable streaming (default: false)

  ## Returns

  - `{:ok, response}` - Successful response with completion
  - `{:error, reason}` - Error with reason string

  ## Response Structure

  ```elixir
  %{
    "id" => "gen-...",
    "model" => "anthropic/claude-3-haiku",
    "choices" => [
      %{
        "message" => %{
          "role" => "assistant",
          "content" => "Hello! How can I help you today?"
        },
        "finish_reason" => "stop"
      }
    ],
    "usage" => %{
      "prompt_tokens" => 10,
      "completion_tokens" => 15,
      "total_tokens" => 25
    }
  }
  ```
  """
  def chat_completion(account, model, messages, opts \\ []) do
    url = "#{@base_url}/chat/completions"
    headers = OpenRouterClient.build_headers_from_account(account)

    body = build_chat_body(model, messages, opts)

    start_time = System.monotonic_time(:millisecond)

    case http_post(url, headers, body) do
      {:ok, %{status_code: 200, body: response_body}} ->
        end_time = System.monotonic_time(:millisecond)
        latency_ms = end_time - start_time

        case Jason.decode(response_body) do
          {:ok, response} ->
            {:ok, Map.put(response, "latency_ms", latency_ms)}

          {:error, _} ->
            {:error, "Invalid JSON response"}
        end

      {:ok, %{status_code: 401}} ->
        {:error, "Invalid API key"}

      {:ok, %{status_code: 402}} ->
        {:error, "Insufficient credits"}

      {:ok, %{status_code: 429}} ->
        {:error, "Rate limited"}

      {:ok, %{status_code: status, body: response_body}} ->
        error_msg = extract_error_message(response_body) || "API error: #{status}"
        Logger.warning("OpenRouter completion failed: #{status} - #{response_body}")
        {:error, error_msg}

      {:error, :timeout} ->
        {:error, "Request timeout"}

      {:error, reason} ->
        Logger.warning("OpenRouter completion error: #{inspect(reason)}")
        {:error, "Connection error: #{inspect(reason)}"}
    end
  end

  @doc """
  Makes an embeddings request to OpenRouter.

  ## Parameters

  - `account` - The AI account struct with API key
  - `model` - Embedding model ID
  - `input` - Text or list of texts to embed
  - `opts` - Additional options

  ## Options

  - `:dimensions` - Output dimensions (model-specific)

  ## Returns

  - `{:ok, response}` - Response with embeddings
  - `{:error, reason}` - Error with reason
  """
  def embeddings(account, model, input, opts \\ []) do
    url = "#{@base_url}/embeddings"
    headers = OpenRouterClient.build_headers_from_account(account)

    body =
      %{
        "model" => model,
        "input" => input
      }
      |> maybe_add("dimensions", Keyword.get(opts, :dimensions))

    start_time = System.monotonic_time(:millisecond)

    case http_post(url, headers, body) do
      {:ok, %{status_code: 200, body: response_body}} ->
        end_time = System.monotonic_time(:millisecond)
        latency_ms = end_time - start_time

        case Jason.decode(response_body) do
          {:ok, response} ->
            {:ok, Map.put(response, "latency_ms", latency_ms)}

          {:error, _} ->
            {:error, "Invalid JSON response"}
        end

      {:ok, %{status_code: status, body: response_body}} ->
        error_msg = extract_error_message(response_body) || "API error: #{status}"
        {:error, error_msg}

      {:error, reason} ->
        {:error, "Connection error: #{inspect(reason)}"}
    end
  end

  @doc """
  Extracts the text content from a chat completion response.
  """
  def extract_content(response) do
    case response do
      %{"choices" => [%{"message" => %{"content" => content}} | _]} ->
        {:ok, content}

      %{"choices" => []} ->
        {:error, "No choices in response"}

      _ ->
        {:error, "Invalid response format"}
    end
  end

  @doc """
  Extracts usage information from a response.
  """
  def extract_usage(response) do
    case response do
      %{"usage" => usage} when is_map(usage) ->
        %{
          prompt_tokens: usage["prompt_tokens"] || 0,
          completion_tokens: usage["completion_tokens"] || 0,
          total_tokens: usage["total_tokens"] || 0
        }

      _ ->
        %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    end
  end

  # Private functions

  defp build_chat_body(model, messages, opts) do
    # Normalize messages to ensure string keys
    normalized_messages =
      Enum.map(messages, fn msg ->
        %{
          "role" => to_string(msg[:role] || msg["role"]),
          "content" => msg[:content] || msg["content"]
        }
      end)

    %{
      "model" => model,
      "messages" => normalized_messages
    }
    |> maybe_add("temperature", Keyword.get(opts, :temperature))
    |> maybe_add("max_tokens", Keyword.get(opts, :max_tokens))
    |> maybe_add("top_p", Keyword.get(opts, :top_p))
    |> maybe_add("top_k", Keyword.get(opts, :top_k))
    |> maybe_add("frequency_penalty", Keyword.get(opts, :frequency_penalty))
    |> maybe_add("presence_penalty", Keyword.get(opts, :presence_penalty))
    |> maybe_add("repetition_penalty", Keyword.get(opts, :repetition_penalty))
    |> maybe_add("stop", Keyword.get(opts, :stop))
    |> maybe_add("seed", Keyword.get(opts, :seed))
    |> maybe_add("stream", Keyword.get(opts, :stream))
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, _key, []), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp http_post(url, headers, body) do
    :inets.start()
    :ssl.start()

    json_body = Jason.encode!(body)

    case :httpc.request(
           :post,
           {String.to_charlist(url),
            Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end),
            ~c"application/json", json_body},
           [
             {:timeout, @timeout},
             {:connect_timeout, @timeout},
             {:ssl, [verify: :verify_none]}
           ],
           [{:body_format, :binary}]
         ) do
      {:ok, {{_, status_code, _}, _resp_headers, response_body}} ->
        {:ok, %{status_code: status_code, body: to_string(response_body)}}

      {:error, {:failed_connect, _}} ->
        {:error, :connection_failed}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("HTTP POST failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_error_message(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      {:ok, %{"error" => error}} when is_binary(error) -> error
      _ -> nil
    end
  end
end
