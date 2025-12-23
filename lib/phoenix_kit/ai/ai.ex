defmodule PhoenixKit.AI do
  @moduledoc """
  Main context for PhoenixKit AI system.

  Provides AI endpoint management and usage tracking for AI API requests.

  ## Architecture

  Each **Endpoint** is a unified configuration that combines:
  - Provider credentials (api_key, base_url, provider_settings)
  - Model selection (single model per endpoint)
  - Generation parameters (temperature, max_tokens, etc.)

  Users create as many endpoints as needed, each representing one complete
  AI configuration ready for making API requests.

  ## Core Functions

  ### System Management
  - `enabled?/0` - Check if AI module is enabled
  - `enable_system/0` - Enable the AI module
  - `disable_system/0` - Disable the AI module
  - `get_config/0` - Get module configuration with statistics

  ### Endpoint CRUD
  - `list_endpoints/1` - List all endpoints with filters
  - `get_endpoint!/1` - Get endpoint by ID (raises)
  - `get_endpoint/1` - Get endpoint by ID
  - `create_endpoint/1` - Create new endpoint
  - `update_endpoint/2` - Update existing endpoint
  - `delete_endpoint/1` - Delete endpoint

  ### Completion API
  - `ask/3` - Simple single-turn completion
  - `complete/3` - Multi-turn chat completion
  - `embed/3` - Generate embeddings

  ### Usage Tracking
  - `list_requests/1` - List requests with pagination/filters
  - `create_request/1` - Log a new request
  - `get_usage_stats/1` - Get aggregated statistics
  - `get_dashboard_stats/0` - Get stats for dashboard display

  ## Usage Examples

      # Enable the module
      PhoenixKit.AI.enable_system()

      # Create an endpoint
      {:ok, endpoint} = PhoenixKit.AI.create_endpoint(%{
        name: "Claude Fast",
        provider: "openrouter",
        api_key: "sk-or-v1-...",
        model: "anthropic/claude-3-haiku",
        temperature: 0.7
      })

      # Use the endpoint
      {:ok, response} = PhoenixKit.AI.ask(endpoint.id, "Hello!")

      # Extract the response text
      {:ok, text} = PhoenixKit.AI.extract_content(response)
  """

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.AI.Endpoint
  alias PhoenixKit.AI.Prompt
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
      endpoints_count: count_endpoints(),
      total_requests: count_requests(),
      total_tokens: sum_tokens()
    }
  end

  # ===========================================
  # ENDPOINT CRUD
  # ===========================================

  @doc """
  Lists all AI endpoints.

  ## Options
  - `:provider` - Filter by provider type
  - `:enabled` - Filter by enabled status
  - `:preload` - Associations to preload

  ## Examples

      PhoenixKit.AI.list_endpoints()
      PhoenixKit.AI.list_endpoints(provider: "openrouter", enabled: true)
  """
  def list_endpoints(opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :sort_order)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)

    query = from(e in Endpoint)

    # Apply sorting
    query = apply_endpoint_sorting(query, sort_by, sort_dir)

    query =
      case Keyword.get(opts, :provider) do
        nil -> query
        provider -> where(query, [e], e.provider == ^provider)
      end

    query =
      case Keyword.get(opts, :enabled) do
        nil -> query
        enabled -> where(query, [e], e.enabled == ^enabled)
      end

    query =
      case Keyword.get(opts, :preload) do
        nil -> query
        preloads -> preload(query, ^preloads)
      end

    repo().all(query)
  end

  defp apply_endpoint_sorting(query, :usage, dir) do
    # Sort by total request count using a subquery
    from(e in query,
      left_join: r in assoc(e, :requests),
      group_by: e.id,
      order_by: [{^dir, count(r.id)}]
    )
  end

  defp apply_endpoint_sorting(query, :tokens, dir) do
    # Sort by total tokens used
    from(e in query,
      left_join: r in assoc(e, :requests),
      group_by: e.id,
      order_by: [{^dir, coalesce(sum(r.total_tokens), 0)}]
    )
  end

  defp apply_endpoint_sorting(query, :cost, dir) do
    # Sort by total cost
    from(e in query,
      left_join: r in assoc(e, :requests),
      group_by: e.id,
      order_by: [{^dir, coalesce(sum(r.cost_cents), 0)}]
    )
  end

  defp apply_endpoint_sorting(query, :last_used, dir) do
    # Sort by most recent request time
    from(e in query,
      left_join: r in assoc(e, :requests),
      group_by: e.id,
      order_by: [{^dir, max(r.inserted_at)}]
    )
  end

  defp apply_endpoint_sorting(query, field, dir)
       when field in [:id, :name, :enabled, :model, :sort_order] do
    order_by(query, [e], [{^dir, field(e, ^field)}])
  end

  defp apply_endpoint_sorting(query, _field, _dir) do
    # Default sorting
    order_by(query, [e], asc: e.sort_order, desc: e.inserted_at)
  end

  @doc """
  Returns usage statistics for each endpoint.

  Returns a map of endpoint_id => %{request_count, total_tokens, total_cost, last_used_at}
  """
  def get_endpoint_usage_stats do
    query =
      from(r in Request,
        where: not is_nil(r.endpoint_id),
        group_by: r.endpoint_id,
        select: {
          r.endpoint_id,
          %{
            request_count: count(r.id),
            total_tokens: coalesce(sum(r.total_tokens), 0),
            total_cost: coalesce(sum(r.cost_cents), 0),
            last_used_at: max(r.inserted_at)
          }
        }
      )

    query
    |> repo().all()
    |> Map.new()
  end

  @doc """
  Gets a single endpoint by ID.

  Raises `Ecto.NoResultsError` if the endpoint does not exist.
  """
  def get_endpoint!(id), do: repo().get!(Endpoint, id)

  @doc """
  Gets a single endpoint by ID.

  Returns `nil` if the endpoint does not exist.
  """
  def get_endpoint(id), do: repo().get(Endpoint, id)

  @doc """
  Resolves an endpoint from an ID or Endpoint struct.

  ## Examples

      {:ok, endpoint} = PhoenixKit.AI.resolve_endpoint(1)
      {:ok, endpoint} = PhoenixKit.AI.resolve_endpoint(endpoint)
  """
  def resolve_endpoint(id) when is_integer(id) do
    case get_endpoint(id) do
      nil -> {:error, "Endpoint not found"}
      endpoint -> {:ok, endpoint}
    end
  end

  def resolve_endpoint(%Endpoint{} = endpoint), do: {:ok, endpoint}

  @doc """
  Creates a new AI endpoint.

  ## Examples

      {:ok, endpoint} = PhoenixKit.AI.create_endpoint(%{
        name: "Claude Fast",
        provider: "openrouter",
        api_key: "sk-or-v1-...",
        model: "anthropic/claude-3-haiku",
        temperature: 0.7
      })
  """
  def create_endpoint(attrs) do
    %Endpoint{}
    |> Endpoint.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates an existing AI endpoint.
  """
  def update_endpoint(%Endpoint{} = endpoint, attrs) do
    endpoint
    |> Endpoint.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes an AI endpoint.
  """
  def delete_endpoint(%Endpoint{} = endpoint) do
    repo().delete(endpoint)
  end

  @doc """
  Returns an endpoint changeset for use in forms.
  """
  def change_endpoint(%Endpoint{} = endpoint, attrs \\ %{}) do
    Endpoint.changeset(endpoint, attrs)
  end

  @doc """
  Marks an endpoint as validated by updating its last_validated_at timestamp.
  """
  def mark_endpoint_validated(%Endpoint{} = endpoint) do
    endpoint
    |> Endpoint.validation_changeset()
    |> repo().update()
  end

  @doc """
  Counts the total number of endpoints.
  """
  def count_endpoints do
    repo().aggregate(Endpoint, :count, :id)
  end

  @doc """
  Counts the number of enabled endpoints.
  """
  def count_enabled_endpoints do
    query = from(e in Endpoint, where: e.enabled == true)
    repo().aggregate(query, :count, :id)
  end

  # ===========================================
  # PROMPT CRUD
  # ===========================================

  @doc """
  Lists all AI prompts.

  ## Options
  - `:sort_by` - Field to sort by (default: :sort_order)
  - `:sort_dir` - Sort direction, :asc or :desc (default: :asc)
  - `:enabled` - Filter by enabled status

  ## Examples

      PhoenixKit.AI.list_prompts()
      PhoenixKit.AI.list_prompts(sort_by: :name, sort_dir: :asc)
      PhoenixKit.AI.list_prompts(enabled: true)
  """
  def list_prompts(opts \\ []) do
    sort_by = Keyword.get(opts, :sort_by, :sort_order)
    sort_dir = Keyword.get(opts, :sort_dir, :asc)

    query = from(p in Prompt)

    query =
      case Keyword.get(opts, :enabled) do
        nil -> query
        enabled -> where(query, [p], p.enabled == ^enabled)
      end

    query = order_by(query, [p], [{^sort_dir, field(p, ^sort_by)}])

    repo().all(query)
  end

  @doc """
  Lists only enabled prompts.

  Convenience wrapper for `list_prompts(enabled: true)`.

  ## Examples

      PhoenixKit.AI.list_enabled_prompts()
  """
  def list_enabled_prompts do
    list_prompts(enabled: true)
  end

  @doc """
  Gets a single prompt by ID.

  Raises `Ecto.NoResultsError` if the prompt does not exist.
  """
  def get_prompt!(id), do: repo().get!(Prompt, id)

  @doc """
  Gets a single prompt by ID.

  Returns `nil` if the prompt does not exist.
  """
  def get_prompt(id), do: repo().get(Prompt, id)

  @doc """
  Gets a prompt by slug.

  Returns `nil` if the prompt does not exist.
  """
  def get_prompt_by_slug(slug) when is_binary(slug) do
    repo().get_by(Prompt, slug: slug)
  end

  @doc """
  Creates a new AI prompt.

  ## Examples

      {:ok, prompt} = PhoenixKit.AI.create_prompt(%{
        name: "Translator",
        content: "Translate the following text to {{Language}}:\\n\\n{{Text}}"
      })
  """
  def create_prompt(attrs) do
    %Prompt{}
    |> Prompt.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates an existing AI prompt.
  """
  def update_prompt(%Prompt{} = prompt, attrs) do
    prompt
    |> Prompt.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes an AI prompt.
  """
  def delete_prompt(%Prompt{} = prompt) do
    repo().delete(prompt)
  end

  @doc """
  Returns a prompt changeset for use in forms.
  """
  def change_prompt(%Prompt{} = prompt, attrs \\ %{}) do
    Prompt.changeset(prompt, attrs)
  end

  @doc """
  Increments the usage count for a prompt and updates last_used_at.
  """
  def record_prompt_usage(%Prompt{} = prompt) do
    prompt
    |> Prompt.usage_changeset()
    |> repo().update()
  end

  @doc """
  Counts the total number of prompts.
  """
  def count_prompts do
    repo().aggregate(Prompt, :count, :id)
  end

  @doc """
  Counts the number of enabled prompts.
  """
  def count_enabled_prompts do
    query = from(p in Prompt, where: p.enabled == true)
    repo().aggregate(query, :count, :id)
  end

  @doc """
  Resolves a prompt from various input types.

  Accepts:
  - Integer ID
  - String slug
  - Prompt struct (returned as-is)

  Returns `{:ok, prompt}` or `{:error, reason}`.
  """
  def resolve_prompt(%Prompt{} = prompt), do: {:ok, prompt}

  def resolve_prompt(id) when is_integer(id) do
    case get_prompt(id) do
      nil -> {:error, "Prompt not found"}
      prompt -> {:ok, prompt}
    end
  end

  def resolve_prompt(slug) when is_binary(slug) do
    case Integer.parse(slug) do
      {id, ""} ->
        resolve_prompt(id)

      _ ->
        case get_prompt_by_slug(slug) do
          nil -> {:error, "Prompt not found"}
          prompt -> {:ok, prompt}
        end
    end
  end

  def resolve_prompt(_), do: {:error, "Invalid prompt identifier"}

  @doc """
  Renders a prompt by replacing variables with provided values.

  Returns `{:ok, rendered_text}` or `{:error, reason}`.
  """
  def render_prompt(prompt_id, variables \\ %{}) do
    with {:ok, prompt} <- resolve_prompt(prompt_id) do
      Prompt.render(prompt, variables)
    end
  end

  @doc """
  Increments the usage count for a prompt and updates last_used_at.
  """
  def increment_prompt_usage(prompt_id) do
    with {:ok, prompt} <- resolve_prompt(prompt_id) do
      record_prompt_usage(prompt)
    end
  end

  @doc """
  Makes an AI completion using a prompt template.

  The prompt content is rendered with the provided variables and sent as
  the user message.
  """
  def ask_with_prompt(endpoint_id, prompt_id, variables \\ %{}, opts \\ []) do
    with {:ok, prompt} <- resolve_prompt(prompt_id),
         {:ok, _} <- validate_prompt(prompt),
         {:ok, rendered} <- Prompt.render(prompt, variables),
         {:ok, response} <- ask(endpoint_id, rendered, opts) do
      # Only increment usage on successful completion
      increment_prompt_usage(prompt_id)
      {:ok, response}
    end
  end

  @doc """
  Makes an AI completion with a prompt template as the system message.

  The prompt is rendered and used as the system message, with the user_message
  as the user message.
  """
  def complete_with_system_prompt(endpoint_id, prompt_id, variables, user_message, opts \\ []) do
    with {:ok, prompt} <- resolve_prompt(prompt_id),
         {:ok, _} <- validate_prompt(prompt),
         {:ok, system_prompt} <- Prompt.render(prompt, variables) do
      # Build messages with system prompt
      messages = [
        %{role: "system", content: system_prompt},
        %{role: "user", content: user_message}
      ]

      case complete(endpoint_id, messages, opts) do
        {:ok, response} ->
          # Only increment usage on successful completion
          increment_prompt_usage(prompt_id)
          {:ok, response}

        error ->
          error
      end
    end
  end

  @doc """
  Validates that a prompt is ready for use.

  Returns `{:ok, prompt}` if valid, or `{:error, reason}` if not.
  """
  def validate_prompt(prompt) do
    cond do
      prompt.content == nil or prompt.content == "" ->
        {:error, "Prompt has no content"}

      prompt.enabled == false ->
        {:error, "Prompt is disabled"}

      true ->
        {:ok, prompt}
    end
  end

  @doc """
  Duplicates a prompt with a new name.
  """
  def duplicate_prompt(prompt_id, new_name) when is_binary(new_name) do
    with {:ok, prompt} <- resolve_prompt(prompt_id) do
      create_prompt(%{
        name: new_name,
        description: prompt.description,
        content: prompt.content,
        enabled: prompt.enabled,
        sort_order: prompt.sort_order,
        metadata: prompt.metadata
      })
    end
  end

  @doc """
  Enables a prompt.
  """
  def enable_prompt(prompt_id) do
    with {:ok, prompt} <- resolve_prompt(prompt_id) do
      update_prompt(prompt, %{enabled: true})
    end
  end

  @doc """
  Disables a prompt.
  """
  def disable_prompt(prompt_id) do
    with {:ok, prompt} <- resolve_prompt(prompt_id) do
      update_prompt(prompt, %{enabled: false})
    end
  end

  @doc """
  Gets the variables defined in a prompt.
  """
  def get_prompt_variables(prompt_id) do
    with {:ok, prompt} <- resolve_prompt(prompt_id) do
      {:ok, prompt.variables || []}
    end
  end

  @doc """
  Previews a rendered prompt without making an AI call.
  """
  def preview_prompt(prompt_id, variables \\ %{}) do
    render_prompt(prompt_id, variables)
  end

  @doc """
  Validates that all required variables are provided for a prompt.
  """
  def validate_prompt_variables(prompt_id, variables) do
    with {:ok, prompt} <- resolve_prompt(prompt_id) do
      Prompt.validate_variables(prompt, variables)
    end
  end

  @doc """
  Searches prompts by name, description, or content.
  """
  def search_prompts(query, opts \\ []) when is_binary(query) do
    pattern = "%#{query}%"
    limit = Keyword.get(opts, :limit, 50)

    base_query =
      from(p in Prompt,
        where:
          ilike(p.name, ^pattern) or
            ilike(p.description, ^pattern) or
            ilike(p.content, ^pattern),
        order_by: [asc: p.sort_order, desc: p.inserted_at],
        limit: ^limit
      )

    base_query =
      case Keyword.get(opts, :enabled) do
        nil -> base_query
        enabled -> where(base_query, [p], p.enabled == ^enabled)
      end

    repo().all(base_query)
  end

  @doc """
  Finds all prompts that use a specific variable.
  """
  def get_prompts_with_variable(variable_name) when is_binary(variable_name) do
    query =
      from(p in Prompt,
        where: ^variable_name in p.variables,
        order_by: [asc: p.sort_order, desc: p.inserted_at]
      )

    repo().all(query)
  end

  @doc """
  Validates that the content has valid variable syntax.
  """
  def validate_prompt_content(content) when is_binary(content) do
    all_patterns = Regex.scan(~r/\{\{([^}]+)\}\}/, content)

    invalid =
      all_patterns
      |> Enum.map(fn [_full, inner] -> inner end)
      |> Enum.reject(fn inner -> Regex.match?(~r/^\w+$/, inner) end)

    if Enum.empty?(invalid) do
      :ok
    else
      {:error, invalid}
    end
  end

  def validate_prompt_content(_), do: {:error, "Content must be a string"}

  @doc """
  Gets usage statistics for all prompts.
  """
  def get_prompt_usage_stats(opts \\ []) do
    query =
      from(p in Prompt,
        select: %{
          prompt: p,
          usage_count: p.usage_count,
          last_used_at: p.last_used_at
        },
        order_by: [desc: p.usage_count, desc: p.last_used_at]
      )

    query =
      case Keyword.get(opts, :enabled) do
        nil -> query
        enabled -> where(query, [p], p.enabled == ^enabled)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    repo().all(query)
  end

  @doc """
  Resets the usage statistics for a prompt.
  """
  def reset_prompt_usage(prompt_id) do
    with {:ok, prompt} <- resolve_prompt(prompt_id) do
      prompt
      |> Ecto.Changeset.change(%{usage_count: 0, last_used_at: nil})
      |> repo().update()
    end
  end

  @doc """
  Updates the sort order for multiple prompts.
  """
  def reorder_prompts(order_list) when is_list(order_list) do
    repo().transaction(fn ->
      Enum.each(order_list, fn {id, sort_order} ->
        from(p in Prompt, where: p.id == ^id)
        |> repo().update_all(set: [sort_order: sort_order])
      end)
    end)

    :ok
  end

  # ===========================================
  # USAGE TRACKING (REQUESTS)
  # ===========================================

  @doc """
  Lists AI requests with pagination and filters.

  ## Options
  - `:page` - Page number (default: 1)
  - `:page_size` - Results per page (default: 20)
  - `:endpoint_id` - Filter by endpoint
  - `:user_id` - Filter by user
  - `:status` - Filter by status
  - `:model` - Filter by model
  - `:source` - Filter by source (from metadata)
  - `:since` - Filter by date (requests after this date)
  - `:preload` - Associations to preload

  ## Returns
  `{requests, total_count}`
  """
  def list_requests(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)
    offset = (page - 1) * page_size
    sort_by = Keyword.get(opts, :sort_by, :inserted_at)
    sort_dir = Keyword.get(opts, :sort_dir, :desc)

    base_query = from(r in Request)
    base_query = apply_request_filters(base_query, opts)
    base_query = apply_request_sorting(base_query, sort_by, sort_dir)

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

  defp apply_request_sorting(query, field, dir)
       when field in [
              :inserted_at,
              :model,
              :total_tokens,
              :latency_ms,
              :cost_cents,
              :status,
              :endpoint_name
            ] do
    order_by(query, [r], [{^dir, field(r, ^field)}])
  end

  defp apply_request_sorting(query, _field, _dir) do
    order_by(query, [r], desc: r.inserted_at)
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
    |> maybe_filter_by(:endpoint_id, Keyword.get(opts, :endpoint_id))
    |> maybe_filter_by(:user_id, Keyword.get(opts, :user_id))
    |> maybe_filter_by(:status, Keyword.get(opts, :status))
    |> maybe_filter_by(:model, Keyword.get(opts, :model))
    |> maybe_filter_by(:source, Keyword.get(opts, :source))
    |> maybe_filter_since(Keyword.get(opts, :since))
  end

  defp maybe_filter_by(query, _field, nil), do: query
  defp maybe_filter_by(query, :endpoint_id, id), do: where(query, [r], r.endpoint_id == ^id)
  defp maybe_filter_by(query, :user_id, id), do: where(query, [r], r.user_id == ^id)
  defp maybe_filter_by(query, :status, status), do: where(query, [r], r.status == ^status)
  defp maybe_filter_by(query, :model, model), do: where(query, [r], r.model == ^model)

  defp maybe_filter_by(query, :source, source),
    do: where(query, [r], fragment("?->>'source' = ?", r.metadata, ^source))

  defp maybe_filter_since(query, nil), do: query
  defp maybe_filter_since(query, date), do: where(query, [r], r.inserted_at >= ^date)

  @doc """
  Returns filter options for requests (distinct endpoints, models, and sources).
  """
  def get_request_filter_options do
    endpoints_query =
      from(r in Request,
        where: not is_nil(r.endpoint_id) and not is_nil(r.endpoint_name),
        distinct: true,
        select: {r.endpoint_id, r.endpoint_name},
        order_by: r.endpoint_name
      )

    models_query =
      from(r in Request,
        where: not is_nil(r.model),
        distinct: r.model,
        select: r.model,
        order_by: r.model
      )

    # Query unique sources from metadata JSONB field
    sources_query =
      from(r in Request,
        where: not is_nil(fragment("?->>'source'", r.metadata)),
        distinct: fragment("?->>'source'", r.metadata),
        select: fragment("?->>'source'", r.metadata),
        order_by: fragment("?->>'source'", r.metadata)
      )

    %{
      endpoints: repo().all(endpoints_query),
      models: repo().all(models_query),
      statuses: Request.valid_statuses(),
      sources: repo().all(sources_query)
    }
  end

  # ===========================================
  # STATISTICS
  # ===========================================

  @doc """
  Gets aggregated usage statistics.

  ## Options
  - `:since` - Start date for statistics
  - `:until` - End date for statistics
  - `:endpoint_id` - Filter by endpoint

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
  Makes a chat completion request using a configured endpoint.

  ## Parameters

  - `endpoint_id` - Endpoint ID (integer) or Endpoint struct
  - `messages` - List of message maps with `:role` and `:content`
  - `opts` - Optional parameter overrides

  ## Options

  All standard completion parameters plus:
  - `:source` - Override auto-detected source for request tracking

  ## Examples

      {:ok, response} = PhoenixKit.AI.complete(1, [
        %{role: "user", content: "Hello!"}
      ])

      # With system message
      {:ok, response} = PhoenixKit.AI.complete(1, [
        %{role: "system", content: "You are a helpful assistant."},
        %{role: "user", content: "What is 2+2?"}
      ])

      # With parameter overrides
      {:ok, response} = PhoenixKit.AI.complete(1, messages,
        temperature: 0.5,
        max_tokens: 500
      )

      # With custom source for tracking
      {:ok, response} = PhoenixKit.AI.complete(1, messages,
        source: "MyModule"
      )

  ## Returns

  - `{:ok, response}` - Full API response including usage stats
  - `{:error, reason}` - Error with reason string
  """
  def complete(endpoint_id, messages, opts \\ []) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_id),
         {:ok, _} <- validate_endpoint(endpoint) do
      # Capture caller info (source + stacktrace + context)
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      # Allow manual override of source, but all debug info is always captured
      source = Keyword.get(opts, :source) || auto_source

      merged_opts = merge_endpoint_opts(endpoint, opts)

      case Completion.chat_completion(endpoint, messages, merged_opts) do
        {:ok, response} ->
          log_request(endpoint, messages, response, source, stacktrace, caller_context)
          {:ok, response}

        {:error, reason} ->
          log_failed_request(endpoint, messages, reason, source, stacktrace, caller_context)
          {:error, reason}
      end
    end
  end

  @doc """
  Simple helper for single-turn chat completion.

  ## Parameters

  - `endpoint_id` - Endpoint ID (integer) or Endpoint struct
  - `prompt` - User prompt string
  - `opts` - Optional parameter overrides and system message

  ## Options

  All options from `complete/3` plus:
  - `:system` - System message string
  - `:source` - Override auto-detected source for request tracking

  ## Examples

      # Simple question
      {:ok, response} = PhoenixKit.AI.ask(1, "What is the capital of France?")

      # With system message
      {:ok, response} = PhoenixKit.AI.ask(1, "Translate: Hello",
        system: "You are a translator. Translate to French."
      )

      # With custom source for tracking
      {:ok, response} = PhoenixKit.AI.ask(1, "Hello!",
        source: "Languages"
      )

      # Extract just the text content
      {:ok, response} = PhoenixKit.AI.ask(1, "Hello!")
      {:ok, text} = PhoenixKit.AI.extract_content(response)

  ## Returns

  Same as `complete/3`
  """
  def ask(endpoint_id, prompt, opts \\ []) when is_binary(prompt) do
    {system, opts} = Keyword.pop(opts, :system)

    messages =
      case system do
        nil -> [%{role: "user", content: prompt}]
        sys -> [%{role: "system", content: sys}, %{role: "user", content: prompt}]
      end

    complete(endpoint_id, messages, opts)
  end

  @doc """
  Makes an embeddings request using a configured endpoint.

  ## Parameters

  - `endpoint_id` - Endpoint ID (integer) or Endpoint struct
  - `input` - Text or list of texts to embed
  - `opts` - Optional parameter overrides

  ## Options

  - `:dimensions` - Override embedding dimensions
  - `:source` - Override auto-detected source for request tracking

  ## Examples

      # Single text
      {:ok, response} = PhoenixKit.AI.embed(1, "Hello, world!")

      # Multiple texts
      {:ok, response} = PhoenixKit.AI.embed(1, ["Hello", "World"])

      # With dimension override
      {:ok, response} = PhoenixKit.AI.embed(1, "Hello", dimensions: 512)

      # With custom source for tracking
      {:ok, response} = PhoenixKit.AI.embed(1, "Hello",
        source: "SemanticSearch"
      )

  ## Returns

  - `{:ok, response}` - Response with embeddings
  - `{:error, reason}` - Error with reason
  """
  def embed(endpoint_id, input, opts \\ []) do
    with {:ok, endpoint} <- resolve_endpoint(endpoint_id),
         {:ok, _} <- validate_endpoint(endpoint) do
      # Capture caller info (source + stacktrace + context)
      {auto_source, stacktrace, caller_context} = capture_caller_info()
      # Allow manual override of source, but all debug info is always captured
      source = Keyword.get(opts, :source) || auto_source

      merged_opts = merge_embedding_opts(endpoint, opts)

      case Completion.embeddings(endpoint, input, merged_opts) do
        {:ok, response} ->
          log_embedding_request(endpoint, input, response, source, stacktrace, caller_context)
          {:ok, response}

        {:error, reason} ->
          log_failed_embedding_request(endpoint, reason, source, stacktrace, caller_context)
          {:error, reason}
      end
    end
  end

  @doc """
  Extracts the text content from a completion response.

  ## Examples

      {:ok, response} = PhoenixKit.AI.ask(1, "Hello!")
      {:ok, text} = PhoenixKit.AI.extract_content(response)
      # => "Hello! How can I help you today?"
  """
  defdelegate extract_content(response), to: Completion

  @doc """
  Extracts usage information from a response.

  ## Examples

      {:ok, response} = PhoenixKit.AI.complete(1, messages)
      usage = PhoenixKit.AI.extract_usage(response)
      # => %{prompt_tokens: 10, completion_tokens: 15, total_tokens: 25}
  """
  defdelegate extract_usage(response), to: Completion

  # Private helpers for completion API

  defp validate_endpoint(endpoint) do
    cond do
      endpoint.model == nil or endpoint.model == "" ->
        {:error, "Endpoint has no model configured"}

      endpoint.api_key == nil or endpoint.api_key == "" ->
        {:error, "Endpoint has no API key configured"}

      endpoint.enabled == false ->
        {:error, "Endpoint is disabled"}

      true ->
        {:ok, endpoint}
    end
  end

  defp merge_endpoint_opts(endpoint, opts) do
    # Endpoint defaults, then user overrides
    base_opts = [
      temperature: endpoint.temperature,
      max_tokens: endpoint.max_tokens,
      top_p: endpoint.top_p,
      top_k: endpoint.top_k,
      frequency_penalty: endpoint.frequency_penalty,
      presence_penalty: endpoint.presence_penalty,
      repetition_penalty: endpoint.repetition_penalty,
      stop: endpoint.stop,
      seed: endpoint.seed
    ]

    # Filter out nil values and merge with user opts
    base_opts
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.merge(opts)
  end

  defp merge_embedding_opts(endpoint, opts) do
    base_opts = [dimensions: endpoint.dimensions]

    base_opts
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Keyword.merge(opts)
  end

  # ===========================================
  # CALLER INFO CAPTURE (for source tracking & debugging)
  # ===========================================

  @doc false
  # Captures full debug context: source, stacktrace, and caller context
  defp capture_caller_info do
    # Get process info (stacktrace + memory in one call)
    [{:current_stacktrace, stack}, {:memory, memory}] =
      Process.info(self(), [:current_stacktrace, :memory])

    # Format stacktrace for storage
    formatted_stack = format_stacktrace(stack)

    # Extract clean source from first non-internal caller
    source = extract_source(stack)

    # Build caller context with additional debug info
    caller_context = build_caller_context(memory)

    {source, formatted_stack, caller_context}
  end

  defp format_stacktrace(stack) do
    stack
    # Limit depth for storage
    |> Enum.take(20)
    |> Enum.map(fn {mod, fun, arity, location} ->
      mod_str = Atom.to_string(mod) |> String.replace_prefix("Elixir.", "")
      file = Keyword.get(location, :file, ~c"unknown") |> to_string()
      line = Keyword.get(location, :line, 0)
      "#{mod_str}.#{fun}/#{arity} (#{file}:#{line})"
    end)
  end

  defp extract_source(stack) do
    # Modules to skip (PhoenixKit.AI internals, Elixir/Erlang core)
    skip_prefixes = ["PhoenixKit.AI", "Elixir.PhoenixKit.AI"]
    skip_modules = [Process, :proc_lib, :gen_server, :gen, :elixir, :erl_eval]

    caller =
      Enum.find(stack, fn {mod, _fun, _arity, _loc} ->
        mod_str = Atom.to_string(mod)

        not Enum.any?(skip_prefixes, &String.starts_with?(mod_str, &1)) and
          mod not in skip_modules
      end)

    case caller do
      {mod, fun, _arity, _loc} ->
        mod_str = Atom.to_string(mod) |> String.replace_prefix("Elixir.", "")
        "#{mod_str}.#{fun}"

      nil ->
        nil
    end
  end

  defp build_caller_context(memory) do
    # Get Phoenix request_id from Logger metadata (if in request context)
    logger_meta = Logger.metadata()

    %{
      request_id: Keyword.get(logger_meta, :request_id),
      node: node() |> Atom.to_string(),
      pid: self() |> inspect(),
      memory_bytes: memory
    }
  end

  # ===========================================
  # REQUEST LOGGING
  # ===========================================

  defp log_request(endpoint, messages, response, source, stacktrace, caller_context) do
    usage = Completion.extract_usage(response)

    # Extract response content
    response_content =
      case Completion.extract_content(response) do
        {:ok, content} -> content
        _ -> nil
      end

    # Build the request payload we sent (for debugging)
    request_payload = %{
      model: endpoint.model,
      messages: normalize_messages(messages),
      temperature: endpoint.temperature,
      max_tokens: endpoint.max_tokens
    }

    create_request(%{
      endpoint_id: endpoint.id,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "chat",
      input_tokens: usage.prompt_tokens,
      output_tokens: usage.completion_tokens,
      total_tokens: usage.total_tokens,
      cost_cents: usage.cost_cents,
      latency_ms: response["latency_ms"],
      status: "success",
      metadata: %{
        temperature: endpoint.temperature,
        max_tokens: endpoint.max_tokens,
        messages: normalize_messages(messages),
        response: response_content,
        request_payload: request_payload,
        raw_response: response,
        # Debug context (source tracking)
        source: source,
        stacktrace: stacktrace,
        caller_context: caller_context
      }
    })
  end

  defp log_failed_request(endpoint, messages, reason, source, stacktrace, caller_context) do
    create_request(%{
      endpoint_id: endpoint.id,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "chat",
      status: "error",
      error_message: reason,
      metadata: %{
        messages: normalize_messages(messages),
        # Debug context (source tracking)
        source: source,
        stacktrace: stacktrace,
        caller_context: caller_context
      }
    })
  end

  # Normalize messages to ensure consistent format for storage
  defp normalize_messages(messages) do
    Enum.map(messages, fn msg ->
      %{
        "role" => to_string(msg[:role] || msg["role"]),
        "content" => msg[:content] || msg["content"]
      }
    end)
  end

  defp log_embedding_request(endpoint, input, response, source, stacktrace, caller_context) do
    usage = Completion.extract_usage(response)
    input_count = if is_list(input), do: length(input), else: 1

    create_request(%{
      endpoint_id: endpoint.id,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "embedding",
      input_tokens: usage.prompt_tokens,
      total_tokens: usage.total_tokens,
      cost_cents: usage.cost_cents,
      latency_ms: response["latency_ms"],
      status: "success",
      metadata: %{
        input_count: input_count,
        dimensions: endpoint.dimensions,
        # Debug context (source tracking)
        source: source,
        stacktrace: stacktrace,
        caller_context: caller_context
      }
    })
  end

  defp log_failed_embedding_request(endpoint, reason, source, stacktrace, caller_context) do
    create_request(%{
      endpoint_id: endpoint.id,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "embedding",
      status: "error",
      error_message: reason,
      metadata: %{
        # Debug context (source tracking)
        source: source,
        stacktrace: stacktrace,
        caller_context: caller_context
      }
    })
  end
end
