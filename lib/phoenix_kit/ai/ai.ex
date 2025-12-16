defmodule PhoenixKit.AI do
  @moduledoc """
  Main context for PhoenixKit AI system.

  Provides AI provider account management, text processing configuration,
  and usage tracking for AI API requests.

  ## Features

  - **Account Management**: Store multiple AI provider accounts (OpenRouter, etc.)
  - **Text Processing Slots**: Configure 3 preset slots for different use cases
  - **Fallback Chain**: Slots can be used as a fallback chain (1 → 2 → 3)
  - **Usage Tracking**: Track every request for history and statistics

  ## Core Functions

  ### System Management
  - `enabled?/0` - Check if AI module is enabled
  - `enable_system/0` - Enable the AI module
  - `disable_system/0` - Disable the AI module
  - `get_config/0` - Get module configuration with statistics

  ### Account CRUD
  - `list_accounts/1` - List all accounts with filters
  - `get_account!/1` - Get account by ID (raises)
  - `get_account/1` - Get account by ID
  - `create_account/1` - Create new account
  - `update_account/2` - Update existing account
  - `delete_account/1` - Delete account
  - `validate_account/1` - Test API key validity

  ### Text Processing Slots
  - `get_text_slots/0` - Get all 3 slot configurations
  - `update_text_slots/1` - Update slot configurations
  - `get_slot/1` - Get specific slot by index
  - `get_enabled_slots/0` - Get only enabled slots
  - `get_fallback_chain/0` - Get slots ordered for fallback

  ### Usage Tracking
  - `list_requests/1` - List requests with pagination/filters
  - `create_request/1` - Log a new request
  - `get_usage_stats/1` - Get aggregated statistics
  - `get_dashboard_stats/0` - Get stats for dashboard display

  ## Usage Examples

      # Check if module is enabled
      if PhoenixKit.AI.enabled?() do
        # Module is active
      end

      # Create an OpenRouter account
      {:ok, account} = PhoenixKit.AI.create_account(%{
        name: "Main OpenRouter",
        provider: "openrouter",
        api_key: "sk-or-v1-..."
      })

      # Configure text processing slots
      {:ok, slots} = PhoenixKit.AI.update_text_slots([
        %{name: "Fast", account_id: 1, model: "anthropic/claude-3-haiku", enabled: true},
        %{name: "Quality", account_id: 1, model: "anthropic/claude-3-opus", enabled: true},
        %{name: "Cheap", account_id: 1, model: "mistralai/mixtral-8x7b-instruct", enabled: false}
      ])

      # Get usage statistics
      stats = PhoenixKit.AI.get_dashboard_stats()
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.AI.Account
  alias PhoenixKit.AI.Request
  alias PhoenixKit.Settings

  # ===========================================
  # HELPERS
  # ===========================================

  defp repo do
    PhoenixKit.RepoHelper.repo()
  end

  # ===========================================
  # SYSTEM MANAGEMENT
  # ===========================================

  @doc """
  Checks if the AI module is enabled.
  """
  def enabled? do
    Settings.get_setting("ai_enabled", "false") == "true"
  end

  @doc """
  Enables the AI module.
  """
  def enable_system do
    Settings.update_setting("ai_enabled", "true")
  end

  @doc """
  Disables the AI module.
  """
  def disable_system do
    Settings.update_setting("ai_enabled", "false")
  end

  @doc """
  Gets the AI module configuration with statistics.
  """
  def get_config do
    %{
      enabled: enabled?(),
      accounts_count: count_accounts(),
      configured_slots_count: count_configured_slots(),
      total_requests: count_requests(),
      total_tokens: sum_tokens()
    }
  end

  # ===========================================
  # ACCOUNT CRUD
  # ===========================================

  @doc """
  Lists all AI accounts.

  ## Options
  - `:provider` - Filter by provider type
  - `:enabled` - Filter by enabled status
  - `:preload` - Associations to preload

  ## Examples

      PhoenixKit.AI.list_accounts()
      PhoenixKit.AI.list_accounts(provider: "openrouter", enabled: true)
  """
  def list_accounts(opts \\ []) do
    query = from(a in Account, order_by: [desc: a.inserted_at])

    query =
      case Keyword.get(opts, :provider) do
        nil -> query
        provider -> where(query, [a], a.provider == ^provider)
      end

    query =
      case Keyword.get(opts, :enabled) do
        nil -> query
        enabled -> where(query, [a], a.enabled == ^enabled)
      end

    query =
      case Keyword.get(opts, :preload) do
        nil -> query
        preloads -> preload(query, ^preloads)
      end

    repo().all(query)
  end

  @doc """
  Gets a single account by ID.

  Raises `Ecto.NoResultsError` if the account does not exist.
  """
  def get_account!(id), do: repo().get!(Account, id)

  @doc """
  Gets a single account by ID.

  Returns `nil` if the account does not exist.
  """
  def get_account(id), do: repo().get(Account, id)

  @doc """
  Creates a new AI account.

  ## Examples

      {:ok, account} = PhoenixKit.AI.create_account(%{
        name: "Main OpenRouter",
        provider: "openrouter",
        api_key: "sk-or-v1-..."
      })
  """
  def create_account(attrs) do
    %Account{}
    |> Account.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates an existing AI account.
  """
  def update_account(%Account{} = account, attrs) do
    account
    |> Account.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes an AI account.
  """
  def delete_account(%Account{} = account) do
    repo().delete(account)
  end

  @doc """
  Returns an account changeset for use in forms.
  """
  def change_account(%Account{} = account, attrs \\ %{}) do
    Account.changeset(account, attrs)
  end

  @doc """
  Marks an account as validated by updating its last_validated_at timestamp.
  """
  def mark_account_validated(%Account{} = account) do
    account
    |> Account.validation_changeset()
    |> repo().update()
  end

  @doc """
  Counts the total number of accounts.
  """
  def count_accounts do
    repo().aggregate(Account, :count, :id)
  end

  @doc """
  Counts the number of enabled accounts.
  """
  def count_enabled_accounts do
    query = from(a in Account, where: a.enabled == true)
    repo().aggregate(query, :count, :id)
  end

  # ===========================================
  # SLOT TYPES AND DEFAULTS
  # ===========================================

  @slot_types ~w(text vision image_gen embeddings)

  @default_text_slots [
    %{
      "name" => "Slot 1",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "temperature" => 0.7,
      "max_tokens" => nil,
      "top_p" => nil,
      "top_k" => nil,
      "frequency_penalty" => nil,
      "presence_penalty" => nil,
      "repetition_penalty" => nil,
      "stop" => nil,
      "seed" => nil,
      "enabled" => false
    },
    %{
      "name" => "Slot 2",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "temperature" => 0.7,
      "max_tokens" => nil,
      "top_p" => nil,
      "top_k" => nil,
      "frequency_penalty" => nil,
      "presence_penalty" => nil,
      "repetition_penalty" => nil,
      "stop" => nil,
      "seed" => nil,
      "enabled" => false
    },
    %{
      "name" => "Slot 3",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "temperature" => 0.7,
      "max_tokens" => nil,
      "top_p" => nil,
      "top_k" => nil,
      "frequency_penalty" => nil,
      "presence_penalty" => nil,
      "repetition_penalty" => nil,
      "stop" => nil,
      "seed" => nil,
      "enabled" => false
    }
  ]

  @default_vision_slots [
    %{
      "name" => "Slot 1",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "temperature" => 0.7,
      "max_tokens" => nil,
      "top_p" => nil,
      "top_k" => nil,
      "frequency_penalty" => nil,
      "presence_penalty" => nil,
      "repetition_penalty" => nil,
      "stop" => nil,
      "seed" => nil,
      "enabled" => false
    },
    %{
      "name" => "Slot 2",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "temperature" => 0.7,
      "max_tokens" => nil,
      "top_p" => nil,
      "top_k" => nil,
      "frequency_penalty" => nil,
      "presence_penalty" => nil,
      "repetition_penalty" => nil,
      "stop" => nil,
      "seed" => nil,
      "enabled" => false
    },
    %{
      "name" => "Slot 3",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "temperature" => 0.7,
      "max_tokens" => nil,
      "top_p" => nil,
      "top_k" => nil,
      "frequency_penalty" => nil,
      "presence_penalty" => nil,
      "repetition_penalty" => nil,
      "stop" => nil,
      "seed" => nil,
      "enabled" => false
    }
  ]

  @default_image_gen_slots [
    %{
      "name" => "Slot 1",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "size" => "1024x1024",
      "quality" => "standard",
      "enabled" => false
    },
    %{
      "name" => "Slot 2",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "size" => "1024x1024",
      "quality" => "hd",
      "enabled" => false
    },
    %{
      "name" => "Slot 3",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "size" => "1792x1024",
      "quality" => "standard",
      "enabled" => false
    }
  ]

  @default_embeddings_slots [
    %{
      "name" => "Slot 1",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "dimensions" => nil,
      "enabled" => false
    },
    %{
      "name" => "Slot 2",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "dimensions" => nil,
      "enabled" => false
    },
    %{
      "name" => "Slot 3",
      "description" => "",
      "account_id" => nil,
      "model" => "",
      "dimensions" => nil,
      "enabled" => false
    }
  ]

  @doc """
  Returns the list of supported slot types.
  """
  def slot_types, do: @slot_types

  # ===========================================
  # GENERIC SLOT FUNCTIONS
  # ===========================================

  @doc """
  Gets all slot configurations for a given type.

  ## Supported Types
  - `:text` - Text/chat completion models
  - `:vision` - Vision/multimodal models
  - `:image_gen` - Image generation models
  - `:embeddings` - Embedding models

  Returns a list of 3 slot configurations.
  """
  def get_slots(type) when type in [:text, :vision, :image_gen, :embeddings] do
    setting_key = slot_setting_key(type)
    default_slots = default_slots_for_type(type)

    case Settings.get_json_setting(setting_key, %{"slots" => default_slots}) do
      %{"slots" => slots} when is_list(slots) -> slots
      _ -> default_slots
    end
  end

  @doc """
  Updates the slot configurations for a given type.

  Accepts a list of up to 3 slot configurations.
  """
  def update_slots(type, slots)
      when type in [:text, :vision, :image_gen, :embeddings] and is_list(slots) do
    setting_key = slot_setting_key(type)
    default_slots = default_slots_for_type(type)

    # Ensure we have exactly 3 slots
    normalized_slots =
      slots
      |> Enum.take(3)
      |> pad_slots(default_slots)

    config = %{"slots" => normalized_slots}

    case Settings.update_json_setting_with_module(setting_key, config, "ai") do
      {:ok, _setting} -> {:ok, normalized_slots}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Gets a specific slot by type and index (0, 1, or 2).
  """
  def get_slot(type, index)
      when type in [:text, :vision, :image_gen, :embeddings] and index in [0, 1, 2] do
    slots = get_slots(type)
    Enum.at(slots, index)
  end

  def get_slot(_, _), do: nil

  @doc """
  Gets only enabled slots for a given type.
  """
  def get_enabled_slots(type) when type in [:text, :vision, :image_gen, :embeddings] do
    get_slots(type)
    |> Enum.with_index()
    |> Enum.filter(fn {slot, _idx} -> slot["enabled"] == true end)
  end

  @doc """
  Gets the fallback chain for a given type - enabled slots in order.

  Returns a list of {slot, index} tuples for fallback processing.
  """
  def get_fallback_chain(type) when type in [:text, :vision, :image_gen, :embeddings] do
    get_enabled_slots(type)
    |> Enum.sort_by(fn {_slot, idx} -> idx end)
  end

  @doc """
  Counts the number of configured (enabled) slots for a given type.
  """
  def count_configured_slots(type) when type in [:text, :vision, :image_gen, :embeddings] do
    get_enabled_slots(type) |> length()
  end

  @doc """
  Counts total configured slots across all types.
  """
  def count_configured_slots do
    Enum.reduce(@slot_types, 0, fn type, acc ->
      acc + count_configured_slots(String.to_atom(type))
    end)
  end

  # ===========================================
  # LEGACY TEXT SLOT FUNCTIONS (backward compatible)
  # ===========================================

  @doc """
  Gets all text processing slot configurations.

  Returns a list of 3 slot configurations.

  This is a convenience function that calls `get_slots(:text)`.
  """
  def get_text_slots, do: get_slots(:text)

  @doc """
  Updates the text processing slot configurations.

  This is a convenience function that calls `update_slots(:text, slots)`.
  """
  def update_text_slots(slots) when is_list(slots), do: update_slots(:text, slots)

  @doc """
  Gets a specific text slot by index (0, 1, or 2).

  This is a convenience function that calls `get_slot(:text, index)`.
  """
  def get_slot(index) when index in [0, 1, 2], do: get_slot(:text, index)
  def get_slot(_), do: nil

  @doc """
  Gets only enabled text slots.

  This is a convenience function that calls `get_enabled_slots(:text)`.
  """
  def get_enabled_slots, do: get_enabled_slots(:text)

  @doc """
  Gets the text fallback chain - enabled slots in order.

  This is a convenience function that calls `get_fallback_chain(:text)`.
  """
  def get_fallback_chain, do: get_fallback_chain(:text)

  # ===========================================
  # SLOT HELPER FUNCTIONS
  # ===========================================

  defp slot_setting_key(:text), do: "ai_text_processing_slots"
  defp slot_setting_key(:vision), do: "ai_vision_processing_slots"
  defp slot_setting_key(:image_gen), do: "ai_image_gen_slots"
  defp slot_setting_key(:embeddings), do: "ai_embeddings_slots"

  defp default_slots_for_type(:text), do: @default_text_slots
  defp default_slots_for_type(:vision), do: @default_vision_slots
  defp default_slots_for_type(:image_gen), do: @default_image_gen_slots
  defp default_slots_for_type(:embeddings), do: @default_embeddings_slots

  defp pad_slots(slots, default_slots) do
    count = length(slots)

    if count >= 3 do
      Enum.take(slots, 3)
    else
      slots ++ Enum.slice(default_slots, count, 3 - count)
    end
  end

  # ===========================================
  # USAGE TRACKING (REQUESTS)
  # ===========================================

  @doc """
  Lists AI requests with pagination and filters.

  ## Options
  - `:page` - Page number (default: 1)
  - `:page_size` - Results per page (default: 20)
  - `:account_id` - Filter by account
  - `:user_id` - Filter by user
  - `:status` - Filter by status
  - `:model` - Filter by model
  - `:since` - Filter by date (requests after this date)
  - `:preload` - Associations to preload

  ## Returns
  `{requests, total_count}`
  """
  def list_requests(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)
    offset = (page - 1) * page_size

    base_query = from(r in Request, order_by: [desc: r.inserted_at])

    base_query = apply_request_filters(base_query, opts)

    total = repo().aggregate(base_query, :count, :id)

    query =
      base_query
      |> limit(^page_size)
      |> offset(^offset)

    query =
      case Keyword.get(opts, :preload) do
        nil -> query
        preloads -> preload(query, ^preloads)
      end

    requests = repo().all(query)

    {requests, total}
  end

  @doc """
  Gets a single request by ID.
  """
  def get_request!(id), do: repo().get!(Request, id)

  @doc """
  Gets a single request by ID.
  """
  def get_request(id), do: repo().get(Request, id)

  @doc """
  Creates a new AI request record.

  Used to log every AI API call for tracking and statistics.
  """
  def create_request(attrs) do
    %Request{}
    |> Request.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Counts the total number of requests.
  """
  def count_requests do
    repo().aggregate(Request, :count, :id)
  end

  @doc """
  Sums the total tokens used across all requests.
  """
  def sum_tokens do
    repo().aggregate(Request, :sum, :total_tokens) || 0
  end

  defp apply_request_filters(query, opts) do
    query
    |> maybe_filter_by(:account_id, Keyword.get(opts, :account_id))
    |> maybe_filter_by(:user_id, Keyword.get(opts, :user_id))
    |> maybe_filter_by(:status, Keyword.get(opts, :status))
    |> maybe_filter_by(:model, Keyword.get(opts, :model))
    |> maybe_filter_since(Keyword.get(opts, :since))
  end

  defp maybe_filter_by(query, _field, nil), do: query
  defp maybe_filter_by(query, :account_id, id), do: where(query, [r], r.account_id == ^id)
  defp maybe_filter_by(query, :user_id, id), do: where(query, [r], r.user_id == ^id)
  defp maybe_filter_by(query, :status, status), do: where(query, [r], r.status == ^status)
  defp maybe_filter_by(query, :model, model), do: where(query, [r], r.model == ^model)

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, date), do: where(query, [r], r.inserted_at >= ^date)

  # ===========================================
  # STATISTICS
  # ===========================================

  @doc """
  Gets aggregated usage statistics.

  ## Options
  - `:since` - Start date for statistics
  - `:until` - End date for statistics
  - `:account_id` - Filter by account

  ## Returns
  Map with statistics including total_requests, total_tokens, success_rate, etc.
  """
  def get_usage_stats(opts \\ []) do
    base_query = from(r in Request)
    base_query = apply_request_filters(base_query, opts)

    total_requests = repo().aggregate(base_query, :count, :id)
    total_tokens = repo().aggregate(base_query, :sum, :total_tokens) || 0
    total_cost = repo().aggregate(base_query, :sum, :cost_cents) || 0
    avg_latency = repo().aggregate(base_query, :avg, :latency_ms)

    success_query = where(base_query, [r], r.status == "success")
    success_count = repo().aggregate(success_query, :count, :id)

    success_rate =
      if total_requests > 0 do
        Float.round(success_count / total_requests * 100, 1)
      else
        0.0
      end

    %{
      total_requests: total_requests,
      total_tokens: total_tokens,
      total_cost_cents: total_cost,
      success_count: success_count,
      error_count: total_requests - success_count,
      success_rate: success_rate,
      avg_latency_ms: decimal_to_int(avg_latency)
    }
  end

  # Convert Decimal or number to integer, handling nil
  defp decimal_to_int(nil), do: nil
  defp decimal_to_int(%Decimal{} = d), do: d |> Decimal.round() |> Decimal.to_integer()
  defp decimal_to_int(n) when is_float(n), do: round(n)
  defp decimal_to_int(n) when is_integer(n), do: n

  @doc """
  Gets dashboard statistics for display.

  Returns stats for the last 30 days plus all-time totals.
  """
  def get_dashboard_stats do
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30, :day)
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    all_time = get_usage_stats()
    last_30_days = get_usage_stats(since: thirty_days_ago)
    today = get_usage_stats(since: today_start)

    tokens_by_model = get_tokens_by_model(since: thirty_days_ago)
    requests_by_day = get_requests_by_day(since: thirty_days_ago)

    %{
      all_time: all_time,
      last_30_days: last_30_days,
      today: today,
      tokens_by_model: tokens_by_model,
      requests_by_day: requests_by_day
    }
  end

  @doc """
  Gets token usage grouped by model.
  """
  def get_tokens_by_model(opts \\ []) do
    base_query = from(r in Request)
    base_query = apply_request_filters(base_query, opts)

    query =
      from r in subquery(base_query),
        where: not is_nil(r.model) and r.model != "",
        group_by: r.model,
        select: %{
          model: r.model,
          total_tokens: sum(r.total_tokens),
          request_count: count(r.id)
        },
        order_by: [desc: sum(r.total_tokens)]

    repo().all(query)
  end

  @doc """
  Gets request counts grouped by day.
  """
  def get_requests_by_day(opts \\ []) do
    base_query = from(r in Request)
    base_query = apply_request_filters(base_query, opts)

    query =
      from r in subquery(base_query),
        group_by: fragment("DATE(?)", r.inserted_at),
        select: %{
          date: fragment("DATE(?)", r.inserted_at),
          count: count(r.id),
          tokens: sum(r.total_tokens)
        },
        order_by: [asc: fragment("DATE(?)", r.inserted_at)]

    repo().all(query)
  end

  # ===========================================
  # COMPLETION API
  # ===========================================

  alias PhoenixKit.AI.Completion

  @doc """
  Makes a chat completion request using a configured slot.

  ## Parameters

  - `type` - Slot type (`:text`, `:vision`)
  - `slot_index` - Slot index (0, 1, or 2)
  - `messages` - List of message maps with `:role` and `:content`
  - `opts` - Optional parameter overrides

  ## Examples

      # Simple completion
      {:ok, response} = PhoenixKit.AI.complete(:text, 0, [
        %{role: "user", content: "Hello!"}
      ])

      # With system message
      {:ok, response} = PhoenixKit.AI.complete(:text, 0, [
        %{role: "system", content: "You are a helpful assistant."},
        %{role: "user", content: "What is 2+2?"}
      ])

      # With parameter overrides
      {:ok, response} = PhoenixKit.AI.complete(:text, 0, messages,
        temperature: 0.5,
        max_tokens: 500
      )

  ## Returns

  - `{:ok, response}` - Full API response including usage stats
  - `{:error, reason}` - Error with reason string
  """
  def complete(type, slot_index, messages, opts \\ [])
      when type in [:text, :vision] and slot_index in [0, 1, 2] do
    with {:ok, slot} <- get_configured_slot(type, slot_index),
         {:ok, account} <- get_slot_account(slot) do
      merged_opts = merge_slot_opts(slot, opts)

      case Completion.chat_completion(account, slot["model"], messages, merged_opts) do
        {:ok, response} ->
          # Log successful request for usage tracking
          log_request(account, slot, slot_index, response)
          {:ok, response}

        {:error, reason} ->
          # Log failed request too (for usage history visibility)
          log_failed_request(account, slot, slot_index, reason)
          {:error, reason}
      end
    end
  end

  @doc """
  Simple helper for single-turn chat completion.

  ## Parameters

  - `type` - Slot type (`:text`, `:vision`)
  - `slot_index` - Slot index (0, 1, or 2)
  - `prompt` - User prompt string
  - `opts` - Optional parameter overrides and system message

  ## Options

  All options from `complete/4` plus:
  - `:system` - System message string

  ## Examples

      # Simple question
      {:ok, response} = PhoenixKit.AI.ask(:text, 0, "What is the capital of France?")

      # With system message
      {:ok, response} = PhoenixKit.AI.ask(:text, 0, "Translate: Hello",
        system: "You are a translator. Translate to French."
      )

      # Extract just the text content
      {:ok, response} = PhoenixKit.AI.ask(:text, 0, "Hello!")
      {:ok, text} = PhoenixKit.AI.extract_content(response)

  ## Returns

  Same as `complete/4`
  """
  def ask(type, slot_index, prompt, opts \\ []) when is_binary(prompt) do
    {system, opts} = Keyword.pop(opts, :system)

    messages =
      case system do
        nil -> [%{role: "user", content: prompt}]
        sys -> [%{role: "system", content: sys}, %{role: "user", content: prompt}]
      end

    complete(type, slot_index, messages, opts)
  end

  @doc """
  Makes a completion request with automatic fallback to next slot on failure.

  Tries each enabled slot in order (0 → 1 → 2) until one succeeds.

  ## Examples

      # Will try slot 0, then 1, then 2 if earlier slots fail
      {:ok, response} = PhoenixKit.AI.complete_with_fallback(:text, [
        %{role: "user", content: "Hello!"}
      ])

  ## Returns

  - `{:ok, response, slot_index}` - Response with the slot index that succeeded
  - `{:error, reason}` - Error if all slots failed
  """
  def complete_with_fallback(type, messages, opts \\ []) when type in [:text, :vision] do
    fallback_chain = get_fallback_chain(type)

    if Enum.empty?(fallback_chain) do
      {:error, "No enabled slots configured for #{type}"}
    else
      try_fallback_chain(fallback_chain, type, messages, opts)
    end
  end

  @doc """
  Simple helper with automatic fallback.

  ## Examples

      {:ok, response, slot_index} = PhoenixKit.AI.ask_with_fallback(:text, "Hello!")
  """
  def ask_with_fallback(type, prompt, opts \\ []) when is_binary(prompt) do
    {system, opts} = Keyword.pop(opts, :system)

    messages =
      case system do
        nil -> [%{role: "user", content: prompt}]
        sys -> [%{role: "system", content: sys}, %{role: "user", content: prompt}]
      end

    complete_with_fallback(type, messages, opts)
  end

  @doc """
  Makes an embeddings request using a configured slot.

  ## Parameters

  - `slot_index` - Slot index (0, 1, or 2)
  - `input` - Text or list of texts to embed
  - `opts` - Optional parameter overrides

  ## Examples

      # Single text
      {:ok, response} = PhoenixKit.AI.embed(0, "Hello, world!")

      # Multiple texts
      {:ok, response} = PhoenixKit.AI.embed(0, ["Hello", "World"])

      # With dimension override
      {:ok, response} = PhoenixKit.AI.embed(0, "Hello", dimensions: 512)

  ## Returns

  - `{:ok, response}` - Response with embeddings
  - `{:error, reason}` - Error with reason
  """
  def embed(slot_index, input, opts \\ []) when slot_index in [0, 1, 2] do
    with {:ok, slot} <- get_configured_slot(:embeddings, slot_index),
         {:ok, account} <- get_slot_account(slot) do
      merged_opts = merge_embedding_opts(slot, opts)

      case Completion.embeddings(account, slot["model"], input, merged_opts) do
        {:ok, response} ->
          log_embedding_request(account, slot, slot_index, input, response)
          {:ok, response}

        {:error, reason} ->
          log_failed_embedding_request(account, slot, slot_index, reason)
          {:error, reason}
      end
    end
  end

  @doc """
  Extracts the text content from a completion response.

  ## Examples

      {:ok, response} = PhoenixKit.AI.ask(:text, 0, "Hello!")
      {:ok, text} = PhoenixKit.AI.extract_content(response)
      # => "Hello! How can I help you today?"
  """
  defdelegate extract_content(response), to: Completion

  @doc """
  Extracts usage information from a response.

  ## Examples

      {:ok, response} = PhoenixKit.AI.complete(:text, 0, messages)
      usage = PhoenixKit.AI.extract_usage(response)
      # => %{prompt_tokens: 10, completion_tokens: 15, total_tokens: 25}
  """
  defdelegate extract_usage(response), to: Completion

  # Private helpers for completion API

  defp get_configured_slot(type, slot_index) do
    slot = get_slot(type, slot_index)

    cond do
      slot == nil ->
        {:error, "Slot #{slot_index} not found for #{type}"}

      slot["account_id"] == nil ->
        {:error, "Slot #{slot_index} has no account configured"}

      slot["model"] == nil or slot["model"] == "" ->
        {:error, "Slot #{slot_index} has no model configured"}

      true ->
        {:ok, slot}
    end
  end

  defp get_slot_account(slot) do
    case get_account(slot["account_id"]) do
      nil -> {:error, "Account not found"}
      account -> {:ok, account}
    end
  end

  defp merge_slot_opts(slot, opts) do
    # Slot defaults, then user overrides
    base_opts = [
      temperature: slot["temperature"],
      max_tokens: slot["max_tokens"],
      top_p: slot["top_p"],
      top_k: slot["top_k"],
      frequency_penalty: slot["frequency_penalty"],
      presence_penalty: slot["presence_penalty"],
      repetition_penalty: slot["repetition_penalty"],
      stop: slot["stop"],
      seed: slot["seed"]
    ]

    # Filter out nil values and merge with user opts
    base_opts
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.merge(opts)
  end

  defp merge_embedding_opts(slot, opts) do
    base_opts = [dimensions: slot["dimensions"]]

    base_opts
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.merge(opts)
  end

  defp try_fallback_chain([], _type, _messages, _opts) do
    {:error, "All slots failed"}
  end

  defp try_fallback_chain([{slot, index} | rest], type, messages, opts) do
    case get_slot_account(slot) do
      {:ok, account} ->
        merged_opts = merge_slot_opts(slot, opts)

        case Completion.chat_completion(account, slot["model"], messages, merged_opts) do
          {:ok, response} ->
            log_request(account, slot, index, response)
            {:ok, response, index}

          {:error, reason} ->
            Logger.warning("Slot #{index} failed: #{reason}, trying next slot")
            log_failed_request(account, slot, index, reason)
            try_fallback_chain(rest, type, messages, opts)
        end

      {:error, _reason} ->
        try_fallback_chain(rest, type, messages, opts)
    end
  end

  defp log_request(account, slot, slot_index, response) do
    usage = Completion.extract_usage(response)

    create_request(%{
      account_id: account.id,
      slot_index: slot_index,
      model: slot["model"],
      request_type: "chat",
      input_tokens: usage.prompt_tokens,
      output_tokens: usage.completion_tokens,
      total_tokens: usage.total_tokens,
      latency_ms: response["latency_ms"],
      status: "success",
      metadata: %{
        temperature: slot["temperature"],
        max_tokens: slot["max_tokens"]
      }
    })
  end

  defp log_failed_request(account, slot, slot_index, reason) do
    create_request(%{
      account_id: account.id,
      slot_index: slot_index,
      model: slot["model"],
      request_type: "chat",
      status: "error",
      error_message: reason
    })
  end

  defp log_embedding_request(account, slot, slot_index, input, response) do
    usage = Completion.extract_usage(response)
    input_count = if is_list(input), do: length(input), else: 1

    create_request(%{
      account_id: account.id,
      slot_index: slot_index,
      model: slot["model"],
      request_type: "embeddings",
      input_tokens: usage.prompt_tokens,
      total_tokens: usage.total_tokens,
      latency_ms: response["latency_ms"],
      status: "success",
      metadata: %{
        input_count: input_count,
        dimensions: slot["dimensions"]
      }
    })
  end

  defp log_failed_embedding_request(account, slot, slot_index, reason) do
    create_request(%{
      account_id: account.id,
      slot_index: slot_index,
      model: slot["model"],
      request_type: "embeddings",
      status: "error",
      error_message: reason
    })
  end
end
