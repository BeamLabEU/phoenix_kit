# AI Module

The PhoenixKit AI module provides a complete AI integration system with unified endpoint management, usage tracking, and a simple API for making AI calls. Currently supports OpenRouter as the AI provider gateway, giving access to hundreds of models from various providers.

## Quick Links

- **Admin Interface**: `/{prefix}/admin/ai/endpoints`
- **Prompt Templates**: `/{prefix}/admin/ai/prompts`
- **Usage Statistics**: `/{prefix}/admin/ai/usage`
- **Create Endpoint**: `/{prefix}/admin/ai/endpoints/new`

## Architecture Overview

The AI module uses a unified **Endpoint** architecture where each endpoint contains everything needed to make AI calls:

- **Provider credentials** (API key, base URL)
- **Model selection** (e.g., `anthropic/claude-3-haiku`)
- **Generation parameters** (temperature, max_tokens, etc.)

### Core Modules

- **PhoenixKit.AI** – Main API module with completion functions and endpoint management
- **PhoenixKit.AI.Endpoint** – Endpoint schema combining credentials + model + parameters
- **PhoenixKit.AI.Prompt** – Reusable prompt templates with variable substitution
- **PhoenixKit.AI.Request** – Request logging schema for usage tracking
- **PhoenixKit.AI.Completion** – HTTP client for making API calls
- **PhoenixKit.AI.OpenRouterClient** – Model discovery and API key validation

## Core Features

- **Unified Endpoints** – Each endpoint is a complete AI configuration
- **Unlimited Endpoints** – Create as many endpoints as needed
- **Prompt Templates** – Reusable prompts with `{{Variable}}` substitution
- **Usage Tracking** – All requests logged with tokens, latency, and cost
- **Parameter Overrides** – Override endpoint parameters per-request
- **Model Discovery** – Dynamic model fetching from OpenRouter API
- **Sortable Lists** – Sort endpoints by ID, name, usage, cost, last used, etc.
- **Filterable History** – Filter request history by endpoint, model, status, source

## Database Tables

- **phoenix_kit_ai_endpoints** – Endpoint storage (credentials, model, parameters)
- **phoenix_kit_ai_prompts** – Reusable prompt templates with variables
- **phoenix_kit_ai_requests** – Request logging with usage statistics

## API Usage

### Simple Chat Completion

```elixir
# Using endpoint ID
{:ok, response} = PhoenixKit.AI.ask(1, "What is 2+2?")
{:ok, text} = PhoenixKit.AI.extract_content(response)
# => "4"
```

### With System Message

```elixir
{:ok, response} = PhoenixKit.AI.ask(1, "Hello",
  system: "You are a pirate. Always respond like a pirate."
)
```

### Multi-Turn Conversation

```elixir
{:ok, response} = PhoenixKit.AI.complete(1, [
  %{role: "system", content: "You are a helpful assistant."},
  %{role: "user", content: "What's the weather like?"},
  %{role: "assistant", content: "I don't have real-time weather data..."},
  %{role: "user", content: "That's okay, just make something up."}
])
```

### Parameter Overrides

```elixir
# Override temperature and max_tokens for this request only
{:ok, response} = PhoenixKit.AI.ask(1, "Write a creative poem",
  temperature: 1.5,
  max_tokens: 500
)
```

### Embeddings

```elixir
# Single text
{:ok, response} = PhoenixKit.AI.embed(1, "Hello, world!")

# Multiple texts (batch)
{:ok, response} = PhoenixKit.AI.embed(1, ["Text 1", "Text 2", "Text 3"])

# With dimension override
{:ok, response} = PhoenixKit.AI.embed(1, "Hello", dimensions: 512)
```

### Extracting Response Data

```elixir
{:ok, response} = PhoenixKit.AI.ask(1, "Hello!")

# Get just the text content
{:ok, text} = PhoenixKit.AI.extract_content(response)

# Get usage statistics (includes cost in nanodollars)
usage = PhoenixKit.AI.extract_usage(response)
# => %{prompt_tokens: 10, completion_tokens: 15, total_tokens: 25, cost_cents: 30}

# Full response includes latency
response["latency_ms"]  # => 850
```

## Source Tracking & Debugging

All AI requests automatically capture caller information for analytics and debugging.

### Automatic Tracking

Every request automatically stores:

- **Source** - Clean identifier like `PhoenixKitWeb.Live.Modules.Languages.translate`
- **Stacktrace** - Full call stack (up to 20 frames) for debugging
- **Caller Context** - Additional debug info:
  - `request_id` - Phoenix request ID (if in HTTP/LiveView context)
  - `node` - Node name (useful for distributed systems)
  - `pid` - Process ID
  - `memory_bytes` - Process memory at call time

```elixir
# Automatic detection - no code changes needed
{:ok, response} = PhoenixKit.AI.ask(1, "Hello!")
# Source automatically detected from caller: "MyApp.ContentGenerator.summarize"
```

### Manual Source Override

Override the auto-detected source when needed:

```elixir
{:ok, response} = PhoenixKit.AI.ask(1, "Hello!",
  source: "CustomLabel"
)
# Manual source used, but stacktrace and caller context still captured
```

### Viewing Debug Info

In the Usage tab request details modal:
- **Source** is displayed prominently for quick identification
- **Caller Context** shows request ID, node, PID, and memory usage
- **Stacktrace** is in a collapsible section for debugging

This information is stored in the request's `metadata` field (JSONB) and requires no database migration.

## Endpoint Management

### Creating Endpoints

```elixir
{:ok, endpoint} = PhoenixKit.AI.create_endpoint(%{
  name: "Claude Fast",
  provider: "openrouter",
  api_key: "sk-or-v1-...",
  model: "anthropic/claude-3-haiku",
  temperature: 0.7,
  max_tokens: 1000
})
```

### Listing Endpoints

```elixir
# List all endpoints
endpoints = PhoenixKit.AI.list_endpoints()

# With sorting
endpoints = PhoenixKit.AI.list_endpoints(sort_by: :usage, sort_dir: :desc)

# Filter by provider or status
endpoints = PhoenixKit.AI.list_endpoints(provider: "openrouter", enabled: true)
```

### Updating Endpoints

```elixir
endpoint = PhoenixKit.AI.get_endpoint!(1)
{:ok, updated} = PhoenixKit.AI.update_endpoint(endpoint, %{temperature: 0.5})
```

### Enabling/Disabling Endpoints

```elixir
# Disabled endpoints return an error when called
endpoint = PhoenixKit.AI.get_endpoint!(1)
{:ok, _} = PhoenixKit.AI.update_endpoint(endpoint, %{enabled: false})

# Calling a disabled endpoint
{:error, "Endpoint is disabled"} = PhoenixKit.AI.ask(1, "Hello")
```

## Prompt Templates

Prompts are reusable templates with variable substitution using `{{VariableName}}` syntax.

### Creating Prompts

```elixir
{:ok, prompt} = PhoenixKit.AI.create_prompt(%{
  name: "Email Writer",
  slug: "email-writer",
  content: "Write a professional email about {{Topic}} to {{Recipient}}.",
  description: "Generates professional emails",
  enabled: true
})
```

### Using Prompts with AI Calls

```elixir
# Simple: render prompt and make AI call
{:ok, response} = PhoenixKit.AI.ask_with_prompt(
  endpoint_id,
  "email-writer",  # Can use ID, slug, or Prompt struct
  %{"Topic" => "project update", "Recipient" => "the team"}
)

# Advanced: use prompt as system message with user input
{:ok, response} = PhoenixKit.AI.complete_with_system_prompt(
  endpoint_id,
  "email-writer",
  %{"Topic" => "Q4 results", "Recipient" => "stakeholders"},
  "Make it concise and include key metrics.",
  temperature: 0.7
)
```

### Variable Management

```elixir
# Get variables from a prompt
{:ok, variables} = PhoenixKit.AI.get_prompt_variables("email-writer")
# => ["Topic", "Recipient"]

# Preview rendered prompt
{:ok, rendered} = PhoenixKit.AI.preview_prompt("email-writer", %{
  "Topic" => "meeting notes",
  "Recipient" => "the manager"
})
# => "Write a professional email about meeting notes to the manager."

# Validate variables before use
case PhoenixKit.AI.validate_prompt_variables("email-writer", %{"Topic" => "test"}) do
  {:ok, _} -> # All required variables provided
  {:error, {:missing_variables, missing}} -> # Handle missing: ["Recipient"]
end
```

### Prompt Discovery

```elixir
# Search prompts by name or content
prompts = PhoenixKit.AI.search_prompts("email", enabled_only: true)

# Find prompts using a specific variable
prompts = PhoenixKit.AI.get_prompts_with_variable("Recipient")

# Validate prompt content syntax
{:ok, variables} = PhoenixKit.AI.validate_prompt_content("Hello {{Name}}")
# => ["Name"]
```

### Prompt Management

```elixir
# List all prompts
prompts = PhoenixKit.AI.list_prompts()

# List enabled prompts only
prompts = PhoenixKit.AI.list_enabled_prompts()

# Get by ID or slug
prompt = PhoenixKit.AI.get_prompt!(1)
prompt = PhoenixKit.AI.get_prompt_by_slug("email-writer")

# Enable/disable
{:ok, prompt} = PhoenixKit.AI.enable_prompt(prompt_id)
{:ok, prompt} = PhoenixKit.AI.disable_prompt(prompt_id)

# Duplicate a prompt
{:ok, new_prompt} = PhoenixKit.AI.duplicate_prompt(prompt_id, "Email Writer v2")

# Delete
{:ok, _} = PhoenixKit.AI.delete_prompt(prompt)
```

### Usage Statistics

```elixir
# Get usage stats for all prompts
stats = PhoenixKit.AI.get_prompt_usage_stats()
# => [%{id: 1, name: "Email Writer", usage_count: 150, ...}, ...]

# Reset usage counter
{:ok, prompt} = PhoenixKit.AI.reset_prompt_usage(prompt_id)
```

### Prompt Schema

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Display name (required) |
| `slug` | string | URL-friendly identifier (auto-generated) |
| `content` | text | Prompt template with `{{Variables}}` |
| `description` | string | Optional description |
| `enabled` | boolean | Whether prompt is active |
| `usage_count` | integer | Number of times used |
| `sort_order` | integer | Display order |

## Endpoint Schema

Each endpoint contains:

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Display name (required) |
| `description` | string | Optional description |
| `provider` | string | Provider type ("openrouter") |
| `api_key` | string | Provider API key (required) |
| `base_url` | string | Custom API base URL |
| `provider_settings` | map | Provider-specific settings |
| `model` | string | Model identifier (required) |
| `temperature` | float | Sampling temperature (0-2) |
| `max_tokens` | integer | Maximum tokens to generate |
| `top_p` | float | Nucleus sampling (0-1) |
| `top_k` | integer | Top-k sampling |
| `frequency_penalty` | float | Frequency penalty (-2 to 2) |
| `presence_penalty` | float | Presence penalty (-2 to 2) |
| `repetition_penalty` | float | Repetition penalty (0-2) |
| `stop` | array | Stop sequences |
| `seed` | integer | Random seed for reproducibility |
| `image_size` | string | Image generation size |
| `image_quality` | string | Image generation quality |
| `dimensions` | integer | Embeddings dimensions |
| `enabled` | boolean | Whether endpoint is active |
| `sort_order` | integer | Display order |
| `last_validated_at` | datetime | Last API key validation time |

## Configuration via Admin UI

### Creating an Endpoint

1. Navigate to `/{prefix}/admin/ai/endpoints`
2. Click "New Endpoint"
3. Enter endpoint details:
   - Name and optional description
   - OpenRouter API key (must start with `sk-or-v1-`)
   - Select a model from the dropdown
   - Adjust parameters as needed
4. Click "Create Endpoint"

> **Note**: Get your API key from https://openrouter.ai/keys

### Sorting Endpoints

The endpoints list supports sorting by:
- **ID** – Endpoint ID (default)
- **Name** – Alphabetical
- **Status** – Enabled/Disabled
- **Model** – Model name
- **Requests** – Total request count
- **Tokens** – Total tokens used
- **Cost** – Total cost
- **Last Used** – Most recent request time

Sort parameters are preserved in the URL for bookmarking.

## Usage Tracking

All requests are automatically logged to `phoenix_kit_ai_requests`.

### Dashboard Statistics

```elixir
# Get dashboard stats (today, last 30 days, all time)
stats = PhoenixKit.AI.get_dashboard_stats()
# => %{
#   today: %{total_requests: 50, total_tokens: 25000, ...},
#   last_30_days: %{...},
#   all_time: %{total_requests: 1234, success_rate: 98.5, ...}
# }
```

### Endpoint Usage Statistics

```elixir
# Get usage stats per endpoint
stats = PhoenixKit.AI.get_endpoint_usage_stats()
# => %{
#   1 => %{request_count: 100, total_tokens: 50000, total_cost: 150000, last_used_at: ~U[...]},
#   2 => %{...}
# }
```

### Request History

```elixir
# List requests with pagination
{requests, total} = PhoenixKit.AI.list_requests(page: 1, page_size: 20)

# With filters
{requests, total} = PhoenixKit.AI.list_requests(
  endpoint_id: 1,
  model: "anthropic/claude-3-haiku",
  status: "success",
  source: "MyApp.ContentGenerator"
)

# With sorting
{requests, total} = PhoenixKit.AI.list_requests(
  sort_by: :cost_cents,
  sort_dir: :desc
)

# Get filter options (for UI dropdowns)
options = PhoenixKit.AI.get_request_filter_options()
# => %{endpoints: [{1, "Claude Fast"}, ...], models: [...], statuses: [...], sources: [...]}
```

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
    "total_tokens" => 25,
    "cost" => 0.00003  # Cost in dollars from OpenRouter
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
case PhoenixKit.AI.ask(1, "Hello") do
  {:ok, response} ->
    {:ok, text} = PhoenixKit.AI.extract_content(response)
    IO.puts(text)

  {:error, "Endpoint not found"} ->
    IO.puts("Endpoint doesn't exist")

  {:error, "Endpoint is disabled"} ->
    IO.puts("Enable the endpoint first")

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
| `"Endpoint not found"` | Invalid endpoint ID | Check endpoint exists |
| `"Endpoint is disabled"` | Endpoint not active | Enable endpoint in settings |
| `"Invalid API key"` | API key rejected | Update API key |
| `"Insufficient credits"` | OpenRouter balance empty | Add credits to OpenRouter |
| `"Rate limited"` | Too many requests | Implement backoff/retry |
| `"Request timeout"` | Slow response | Use faster model |

## LiveView Interfaces

> **Note**: The AI module must be enabled before accessing admin pages. Enable via Admin UI at `/{prefix}/admin/modules` or programmatically with `PhoenixKit.AI.enable_system()`.

### Endpoints Page (`/{prefix}/admin/ai/endpoints`)

- List all endpoints with usage statistics
- Sort by ID, name, status, usage, cost, last used
- Quick actions: edit, enable/disable, delete
- Each card shows: model, temperature, request count, tokens, cost

### Prompts Page (`/{prefix}/admin/ai/prompts`)

- List all prompt templates with usage counts
- Create, edit, duplicate, and delete prompts
- Variable preview with live substitution
- Enable/disable prompts
- Drag-and-drop reordering

### Usage Page (`/{prefix}/admin/ai/usage`)

- Dashboard statistics (today, 30 days, all time)
- Recent requests table with filtering and sorting
- Filter by endpoint, model, status, source (filters only appear when there are 2+ options)
- Sort by time, endpoint, model, tokens, latency, cost, status
- Request details modal with full request/response JSON, source, and debug info
- Responsive table design (columns adapt to screen size)

### Endpoint Form (`/{prefix}/admin/ai/endpoints/new` or `.../edit`)

- Name and description
- API key configuration
- Model selection from dropdown
- Parameter configuration (temperature, max_tokens, etc.)

## Cost Tracking

Costs are tracked in **nanodollars** (1/1,000,000 of a dollar) for precision with cheap API calls.

```elixir
# In database: cost_cents stores nanodollars
# Example: $0.00003 = 30 nanodollars

# Format for display
PhoenixKit.AI.Request.format_cost(30)
# => "$0.000030"

PhoenixKit.AI.Request.format_cost(1_500_000)
# => "$1.50"
```

## Supported Models

OpenRouter provides access to models from:

- **Anthropic** – Claude 3.5 Sonnet, Claude 3 Opus/Sonnet/Haiku
- **OpenAI** – GPT-4o, GPT-4 Turbo, GPT-3.5 Turbo
- **Google** – Gemini Pro, Gemini Flash
- **Meta** – Llama 3.1, Llama 3
- **Mistral** – Mistral Large, Mixtral
- **And many more** – DeepSeek, Qwen, Cohere, etc.

Models are dynamically fetched from OpenRouter's API.

## Troubleshooting

### Models Not Loading

1. Check API key is valid in endpoint settings
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
