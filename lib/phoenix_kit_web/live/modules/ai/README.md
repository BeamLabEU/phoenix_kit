# AI Module

The PhoenixKit AI module provides a complete AI integration system with provider account management, model configuration slots, usage tracking, and a simple API for making AI calls. Currently supports OpenRouter as the AI provider gateway, giving access to hundreds of models from various providers.

## Quick Links

- **Admin Interface**: `/{prefix}/admin/ai`
- **Account Management**: `/{prefix}/admin/ai/accounts`
- **Settings**: Configure slots at `/{prefix}/admin/ai` under "Model Configuration"

## Architecture Overview

- **PhoenixKit.AI** – Main API module with completion functions and slot management
- **PhoenixKit.AI.Account** – Account schema for storing provider credentials
- **PhoenixKit.AI.Request** – Request logging schema for usage tracking
- **PhoenixKit.AI.Completion** – HTTP client for making API calls to OpenRouter
- **PhoenixKit.AI.OpenRouterClient** – Model discovery and API key validation

## Core Features

- **Multi-Account Support** – Store multiple AI provider accounts
- **Slot-Based Configuration** – 3 configurable presets per model type (text, vision, image gen, embeddings)
- **Fallback Chain** – Automatic failover to next slot on errors
- **Usage Tracking** – All requests logged with tokens, latency, and cost
- **Parameter Overrides** – Override slot parameters per-request
- **Model Discovery** – Dynamic model fetching from OpenRouter API

## Database Tables

- **phoenix_kit_ai_accounts** – Provider account storage (API keys, settings)
- **phoenix_kit_ai_requests** – Request logging with usage statistics

## Model Type Slots

Each model type has 3 configurable slots:

| Type | Use Case | Parameters |
|------|----------|------------|
| **Text** | Chat/completion models | temperature, max_tokens, top_p, top_k, penalties, stop, seed |
| **Vision** | Multimodal models | Same as text |
| **Image Gen** | Image generation | size, quality |
| **Embeddings** | Vector embeddings | dimensions |

## API Usage

### Simple Chat Completion

```elixir
# Using slot 0 for text completion
{:ok, response} = PhoenixKit.AI.ask(:text, 0, "What is 2+2?")
{:ok, text} = PhoenixKit.AI.extract_content(response)
# => "4"
```

### With System Message

```elixir
{:ok, response} = PhoenixKit.AI.ask(:text, 0, "Hello",
  system: "You are a pirate. Always respond like a pirate."
)
```

### Multi-Turn Conversation

```elixir
{:ok, response} = PhoenixKit.AI.complete(:text, 0, [
  %{role: "system", content: "You are a helpful assistant."},
  %{role: "user", content: "What's the weather like?"},
  %{role: "assistant", content: "I don't have real-time weather data..."},
  %{role: "user", content: "That's okay, just make something up."}
])
```

### Parameter Overrides

```elixir
# Override temperature and max_tokens for this request only
{:ok, response} = PhoenixKit.AI.ask(:text, 0, "Write a creative poem",
  temperature: 1.5,
  max_tokens: 500
)
```

### Automatic Fallback

```elixir
# Tries slot 0, then 1, then 2 if earlier slots fail
{:ok, response, slot_used} = PhoenixKit.AI.ask_with_fallback(:text, "Hello!")

# Works with full message format too
{:ok, response, slot_used} = PhoenixKit.AI.complete_with_fallback(:text, [
  %{role: "user", content: "Hello!"}
])
```

### Embeddings

```elixir
# Single text
{:ok, response} = PhoenixKit.AI.embed(0, "Hello, world!")

# Multiple texts (batch)
{:ok, response} = PhoenixKit.AI.embed(0, ["Text 1", "Text 2", "Text 3"])

# With dimension override
{:ok, response} = PhoenixKit.AI.embed(0, "Hello", dimensions: 512)
```

### Extracting Response Data

```elixir
{:ok, response} = PhoenixKit.AI.ask(:text, 0, "Hello!")

# Get just the text content
{:ok, text} = PhoenixKit.AI.extract_content(response)

# Get usage statistics
usage = PhoenixKit.AI.extract_usage(response)
# => %{prompt_tokens: 10, completion_tokens: 15, total_tokens: 25}

# Full response includes latency
response["latency_ms"]  # => 850
```

## Configuration

### Account Setup

1. Navigate to `/{prefix}/admin/ai/accounts`
2. Click "Add Account"
3. Enter your OpenRouter API key (must start with `sk-or-v1-`)
4. Optionally configure HTTP-Referer and X-Title headers (for OpenRouter rankings)

> **Note**: Get your API key from https://openrouter.ai/keys. The key must include the full prefix `sk-or-v1-...`

### Slot Configuration

1. Navigate to `/{prefix}/admin/ai`
2. Select model type tab (Text, Vision, Image Gen, Embeddings)
3. Configure each slot:
   - Select account
   - Choose model from dropdown
   - Adjust parameters (temperature, max_tokens, etc.)
   - Enable/disable slot
4. Click "Save Configuration"

### Max Tokens Behavior

By default, `max_tokens` is set to `nil`, which lets the API decide the appropriate output length based on the model's context window and your input size. This avoids context length errors that occur when `max_tokens + input_tokens > context_length`.

**Recommendations:**
- Leave `max_tokens` as `nil` for dynamic behavior
- Set a specific value (e.g., 1000-4000) if you need consistent output lengths
- Override per-request with the `max_tokens` option when needed

```elixir
# Let API decide (nil max_tokens in slot)
{:ok, response} = PhoenixKit.AI.ask(:text, 0, "Hello!")

# Override for specific request
{:ok, response} = PhoenixKit.AI.ask(:text, 0, "Hello!", max_tokens: 500)
```

### Fallback Chain

Enable multiple slots to create a fallback chain. When making requests with `complete_with_fallback/3` or `ask_with_fallback/3`:

1. Tries Slot 0 first
2. On failure, tries Slot 1
3. On failure, tries Slot 2
4. Returns error if all slots fail

Each attempt is logged for debugging and usage tracking.

## Response Structure

### Chat Completion Response

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
  },
  "latency_ms" => 850
}
```

### Embeddings Response

```elixir
%{
  "data" => [
    %{
      "embedding" => [0.123, -0.456, ...],
      "index" => 0
    }
  ],
  "usage" => %{
    "prompt_tokens" => 5,
    "total_tokens" => 5
  },
  "latency_ms" => 120
}
```

## Error Handling

All functions return `{:ok, result}` or `{:error, reason}`:

```elixir
case PhoenixKit.AI.ask(:text, 0, "Hello") do
  {:ok, response} ->
    {:ok, text} = PhoenixKit.AI.extract_content(response)
    IO.puts(text)

  {:error, "Slot 0 has no account configured"} ->
    IO.puts("Please configure an account for this slot")

  {:error, "Invalid API key"} ->
    IO.puts("Check your OpenRouter API key")

  {:error, "Rate limited"} ->
    Process.sleep(1000)
    # Retry...

  {:error, reason} ->
    IO.puts("Error: #{reason}")
end
```

### Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `"Slot X has no account configured"` | Slot missing account | Configure account in slot settings |
| `"Slot X has no model configured"` | Slot missing model | Select a model in slot settings |
| `"Account not found"` | Account was deleted | Reconfigure slot with valid account |
| `"Invalid API key"` | API key rejected | Update API key in account settings |
| `"Insufficient credits"` | OpenRouter balance empty | Add credits to OpenRouter account |
| `"Rate limited"` | Too many requests | Implement backoff/retry logic |
| `"Request timeout"` | Slow response | Increase timeout or use faster model |
| `"No enabled slots configured"` | No slots enabled for fallback | Enable at least one slot |

## Usage Tracking

All requests are automatically logged to `phoenix_kit_ai_requests`:

```elixir
# Get usage statistics
stats = PhoenixKit.AI.get_usage_stats()
# => %{
#   total_requests: 1234,
#   total_tokens: 2_500_000,
#   total_cost_cents: 4567,
#   success_rate: 98.5,
#   avg_latency_ms: 850
# }

# Get dashboard stats (includes today, last 30 days, all time)
dashboard = PhoenixKit.AI.get_dashboard_stats()

# List recent requests
{requests, total} = PhoenixKit.AI.list_requests(
  page: 1,
  page_size: 20,
  status: "success"
)
```

## LiveView Interfaces

- **Settings** – Main AI configuration at `/{prefix}/admin/ai`
  - Model type tabs (Text, Vision, Image Gen, Embeddings)
  - Slot configuration with account/model selection
  - Parameter tuning (temperature, max_tokens, etc.)
  - Model info display (context length, pricing, supported params)

- **Accounts** – Account management at `/{prefix}/admin/ai/accounts`
  - Add/edit/delete provider accounts
  - API key validation
  - Optional HTTP headers for rankings

- **Usage** – Usage statistics at `/{prefix}/admin/ai` under "Usage" tab
  - Today/Last 30 days/All time statistics
  - Success rate and average latency
  - Recent requests table with status, tokens, and latency
  - Error message tooltips for failed requests

## Supported Models

OpenRouter provides access to models from:

- **Anthropic** – Claude 3.5 Sonnet, Claude 3 Opus/Sonnet/Haiku
- **OpenAI** – GPT-4o, GPT-4 Turbo, GPT-3.5 Turbo
- **Google** – Gemini Pro, Gemini Flash
- **Meta** – Llama 3.1, Llama 3
- **Mistral** – Mistral Large, Mixtral
- **And many more** – DeepSeek, Qwen, Cohere, etc.

Models are dynamically fetched from OpenRouter and filtered by type:
- **Text**: `text->text` modality
- **Vision**: `text+image->text` modality
- **Image Gen**: `text->text+image` or `text+image->text+image` modality
- **Embeddings**: Hardcoded list of known embedding models

## Extending the Module

### Adding a New Provider

Currently only OpenRouter is supported. To add a new provider:

1. Create a new client module (e.g., `PhoenixKit.AI.AnthropicClient`)
2. Implement `chat_completion/4` and `embeddings/4` functions
3. Update `PhoenixKit.AI.Completion` to route by provider
4. Add provider option to account form

### Custom Request Logging

Override the logging behavior:

```elixir
# After making a request, access the raw response
{:ok, response} = PhoenixKit.AI.complete(:text, 0, messages)

# Log additional metadata
PhoenixKit.AI.create_request(%{
  account_id: account_id,
  model: "custom/model",
  request_type: "custom",
  metadata: %{custom_field: "value"}
})
```

## Troubleshooting

### Models Not Loading

1. Check API key is valid: Test in account settings
2. Verify account has credits on OpenRouter
3. Check browser console for network errors
4. Try refreshing the page

### Slow Responses

1. Use a faster model (e.g., Haiku instead of Opus)
2. Reduce `max_tokens` parameter
3. Check OpenRouter status page for outages

### High Costs

1. Monitor usage in the Usage tab
2. Use cheaper models for simple tasks
3. Reduce `max_tokens` to limit output length
4. Implement caching for repeated queries

## Getting Help

1. Check this README for API documentation
2. Review OpenRouter docs: https://openrouter.ai/docs
3. Enable debug logging: `Logger.configure(level: :debug)`
4. Check request logs in `phoenix_kit_ai_requests` table
