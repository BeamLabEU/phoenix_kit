defmodule PhoenixKit.Modules.Sitemap.LLMText.Cache do
  @moduledoc """
  ETS-based cache with TTL for LLM text content.

  Runs as a GenServer that owns the ETS table, ensuring the table persists
  across HTTP requests (each Phoenix request runs in a short-lived process;
  without a long-lived owner the table would be destroyed after every request).

  TTL defaults to 5 minutes but is configurable:

      config :phoenix_kit, :llm_text_cache_ttl, 300  # seconds

  Cache keys:
  - `{:index, language}` — llms.txt index content
  - `{:page, path_parts, language}` — individual page markdown
  - `:robots_txt` — dynamic robots.txt content

  ## Negative caching

  `fetch/2` caches whatever the callback returns, including `nil`.
  This means a 404 (page not found) is also cached for the TTL duration.
  New pages won't appear until the cache entry expires or `invalidate/0` is called.
  """

  use GenServer

  @table_name :llm_text_cache
  @default_ttl 300

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns cached value if present and not expired, otherwise calls `fun`,
  caches the result, and returns it.
  """
  @spec fetch(term(), (-> term())) :: term()
  def fetch(key, fun) do
    case get(key) do
      {:ok, value} ->
        value

      :error ->
        value = fun.()
        put(key, value)
        value
    end
  end

  @doc """
  Retrieves a cached value. Returns `:error` if missing or expired.
  """
  @spec get(term()) :: {:ok, term()} | :error
  def get(key) do
    now = monotonic_now()

    case :ets.lookup(@table_name, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Stores a value under `key` with the configured TTL.
  """
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    ttl = Application.get_env(:phoenix_kit, :llm_text_cache_ttl, @default_ttl)
    expires_at = monotonic_now() + ttl
    :ets.insert(@table_name, {key, value, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Removes all cached entries. Call when LLM text settings or content change.
  """
  @spec invalidate() :: :ok
  def invalidate do
    :ets.delete_all_objects(@table_name)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl GenServer
  def init([]) do
    :ets.new(@table_name, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])

    {:ok, %{}}
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp monotonic_now do
    System.monotonic_time(:second)
  end
end
