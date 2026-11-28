defmodule PhoenixKit.Plugs.RateLimit do
  @moduledoc """
  A rate limit for the host application's own routes, on the counters PhoenixKit already
  keeps.

      pipeline :partner_api do
        plug :accepts, ["json"]
        plug PhoenixKit.Plugs.RateLimit, bucket: :partner_api, key: :ip, limit: {60, :minute}
      end

      # In a controller, per signed-in user (anonymous visitors by their network):
      plug PhoenixKit.Plugs.RateLimit,
           bucket: :exports,
           key: :user,
           limit: {10, :hour}
           when action in [:create]

      # Any key the host computes (an API client id, a tenant):
      plug PhoenixKit.Plugs.RateLimit,
           bucket: :search,
           key: &MyAppWeb.RateKeys.tenant/1,
           limit: {600, :minute}

  ## Options

    * `:bucket` (required) - an atom or a string naming the counter. Two plugs with the same
      bucket share it; use one bucket per thing you limit.
    * `:key` (required) - who a request is counted for:
      * `:ip` - the client network (`PhoenixKit.Utils.IpAddress.extract_from_conn/1`, which
        reads `X-Forwarded-For` only behind a trusted proxy; an IPv6 address counts as its
        /64, `PhoenixKit.Utils.IpAddress.network/1`);
      * `:user` - the signed-in user of `conn.assigns.phoenix_kit_current_scope`, or the
        client network when nobody is signed in (so the plug must come after
        `:fetch_phoenix_kit_current_scope` to see the user);
      * a function of one argument (`&Mod.fun/1`), called with the conn: a string, an
        integer or an atom is the key; `nil` lets the request through uncounted.
    * `:limit` (required) - `{count, :second | :minute | :hour | :day}` or `{count, ms}`
      (a window in milliseconds), `count` a positive integer.
    * `:cost` - units one request takes, default `1`.

  ## What it answers

  Within the limit the request goes on, with `ratelimit-limit`, `ratelimit-remaining` and
  `ratelimit-reset` (seconds) response headers. Over it, the plug answers `429` with
  `retry-after` (seconds) and the same headers, and halts: a JSON body
  (`{"error": "rate_limited", "retry_after": seconds}`) when the request accepts JSON
  (the `:accepts` plug chose `json`, or the `accept` header names it), else
  `Too Many Requests` as plain text.

  ## Failing open

  This plug guards the host's routes, so a fault of its own never takes them down: a key
  function that raises or returns something else, or a counter that cannot be reached, lets
  the request through and logs a warning (the exception's module only, never request data).
  Bad options are refused when the plug is compiled (`ArgumentError`).

  ## Per node

  Counters live in an ETS table of each node (the Hammer table core supervises, under keys
  that start with `plug:`). Behind a load balancer with N nodes a client can reach up to N
  times the limit; a limit that must hold across nodes needs a shared store (Redis, the
  database), which this plug does not offer. Windows are fixed and aligned to the clock.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKit.Utils.IpAddress

  @units %{second: 1_000, minute: 60_000, hour: 3_600_000, day: 86_400_000}

  @impl Plug
  def init(opts) when is_list(opts) do
    bucket = Keyword.get(opts, :bucket)
    key = Keyword.get(opts, :key)
    cost = Keyword.get(opts, :cost, 1)

    unless (is_atom(bucket) and bucket not in [nil, true, false]) or
             (is_binary(bucket) and bucket != ""),
           do: invalid!(":bucket must be an atom or a non-empty string, got #{inspect(bucket)}")

    unless key in [:ip, :user] or is_function(key, 1),
      do: invalid!(":key must be :ip, :user or a function of one argument, got #{inspect(key)}")

    unless is_integer(cost) and cost > 0,
      do: invalid!(":cost must be a positive integer, got #{inspect(cost)}")

    {count, scale} = limit!(Keyword.get(opts, :limit))

    %{bucket: to_string(bucket), key: key, count: count, scale: scale, cost: cost}
  end

  def init(opts), do: invalid!("options must be a keyword list, got #{inspect(opts)}")

  defp limit!({count, unit}) when is_integer(count) and count > 0 and is_map_key(@units, unit),
    do: {count, Map.fetch!(@units, unit)}

  defp limit!({count, ms}) when is_integer(count) and count > 0 and is_integer(ms) and ms > 0,
    do: {count, ms}

  defp limit!(other),
    do:
      invalid!(
        ":limit must be {count, :second | :minute | :hour | :day} or {count, milliseconds}, got #{inspect(other)}"
      )

  defp invalid!(message), do: raise(ArgumentError, "PhoenixKit.Plugs.RateLimit: " <> message)

  @impl Plug
  def call(conn, %{} = opts) do
    case identity(conn, opts.key) do
      {:ok, nil} -> conn
      {:ok, id} -> charge(conn, opts, id)
      {:error, reason} -> fail_open(conn, opts, reason)
    end
  end

  defp identity(conn, :ip), do: {:ok, "ip:" <> network(conn)}

  defp identity(conn, :user) do
    case Scope.user_uuid(conn.assigns[:phoenix_kit_current_scope]) do
      uuid when is_binary(uuid) -> {:ok, "user:" <> uuid}
      _anonymous -> identity(conn, :ip)
    end
  end

  defp identity(conn, fun) when is_function(fun, 1) do
    case fun.(conn) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, "key:" <> value}
      value when is_integer(value) -> {:ok, "key:" <> Integer.to_string(value)}
      value when is_atom(value) -> {:ok, "key:" <> Atom.to_string(value)}
      other -> {:error, "the key function returned " <> LogSafe.shape(other)}
    end
  rescue
    error -> {:error, "the key function raised " <> LogSafe.exception_label(error)}
  catch
    kind, _reason -> {:error, "the key function failed (#{kind})"}
  end

  defp network(conn) do
    conn |> IpAddress.extract_from_conn() |> IpAddress.network() |> Kernel.||("unknown")
  end

  defp charge(conn, opts, id) do
    key = "plug:" <> opts.bucket <> ":" <> id

    case Backend.hit(key, opts.scale, opts.count, opts.cost) do
      {:allow, count} ->
        put_headers(conn, opts.count, max(opts.count - count, 0), seconds_left(opts.scale))

      {:deny, retry_after_ms} ->
        too_many(conn, opts.count, ms_to_seconds(retry_after_ms))
    end
  rescue
    error -> fail_open(conn, opts, "the counter raised " <> LogSafe.exception_label(error))
  catch
    kind, _reason -> fail_open(conn, opts, "the counter failed (#{kind})")
  end

  defp put_headers(conn, limit, remaining, reset) do
    conn
    |> put_resp_header("ratelimit-limit", Integer.to_string(limit))
    |> put_resp_header("ratelimit-remaining", Integer.to_string(remaining))
    |> put_resp_header("ratelimit-reset", Integer.to_string(reset))
  end

  defp too_many(conn, limit, retry_after) do
    conn =
      conn
      |> put_headers(limit, 0, retry_after)
      |> put_resp_header("retry-after", Integer.to_string(retry_after))

    if json?(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        429,
        Jason.encode!(%{"error" => "rate_limited", "retry_after" => retry_after})
      )
      |> halt()
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(429, "Too Many Requests")
      |> halt()
    end
  end

  defp json?(conn) do
    case conn.private do
      %{phoenix_format: "json"} ->
        true

      _other ->
        conn |> get_req_header("accept") |> Enum.any?(&String.contains?(&1, "json"))
    end
  end

  defp fail_open(conn, opts, reason) do
    Logger.warning(
      "[PhoenixKit.Plugs.RateLimit] bucket #{opts.bucket}: #{reason}; the request was let through"
    )

    conn
  end

  defp seconds_left(scale) do
    now = System.system_time(:millisecond)
    ms_to_seconds(scale - rem(now, scale))
  end

  defp ms_to_seconds(ms), do: max(div(ms + 999, 1000), 1)
end
