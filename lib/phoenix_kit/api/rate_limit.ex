defmodule PhoenixKit.API.RateLimit do
  @moduledoc """
  Rate limits of the machine API.

  Counters live in the one Hammer ETS table core already supervises
  (`PhoenixKit.Users.RateLimiter.Backend`), under keys that start with `api:`.
  Windows are fixed, aligned to the wall clock, and counted per node. Limits are
  read from Settings on every call (`PhoenixKit.API.Config.rate_limits/0`), so an
  edit takes effect at once.

  | Bucket | Window | Counts | Setting |
  |---|---|---|---|
  | admin pre-auth, per client network | 1 min | **failed** authentications only | `api_admin_preauth_fail_per_min` |
  | admin, per key | 1 min | cost units | the key's own `rate_limit_per_minute`, else `api_admin_rate_per_min` |
  | admin, all keys together (optional) | 1 min | cost units | `api_total_rate_per_min` (unset: no total cap) |
  | admin, per user acting through a live session | 1 min | cost units | `api_admin_rate_per_min` |
  | public, per client token | 1 min | cost units | `api_public_token_rate_per_min` |
  | public, per client network | 1 min | cost units | `api_public_ip_rate_per_min` |
  | new rows, per client network | 1 hour | new rows | `api_public_new_rows_per_ip_hour` |
  | new rows, all clients | 1 hour | new rows | `api_public_new_rows_global_hour` |

  The client network is `PhoenixKit.Utils.IpAddress.network/1`: an IPv4 address
  as it is, an IPv6 address as its /64.

  The client token is a hash of the input field a public tool declares as its
  client token (`PhoenixKit.API.Tool`): the caller's identity where it has no
  key. The new-rows quota (`check_new_rows/1`) is charged by the module that
  creates the rows, and is one quota shared by every module.

  ## Throttling key guessing without locking out a valid key

  The pre-auth bucket is **peeked** (`check_preauth/1` charges nothing) only
  **after** a key has been rejected, and **charged only by a failure**
  (`record_auth_failure/1`). A request is authenticated whatever the state of
  the bucket: a valid key from an exhausted address goes through, because the
  per-key bucket is independent of the address; a request that fails is
  answered `429` instead of `401`, and that failure is not charged again. A
  neighbour sharing an egress address therefore cannot lock the accounting
  system out by guessing.

  The order the Auth plug (`PhoenixKit.API.Auth`) follows, after the API switch
  check (`404` when off) and the refusal of a credential in the URL (`400`):

      case Keys.verify(token, ip) do
        {:ok, actor} ->
          check_admin(actor.key_uuid, cost)

        {:error, _reason} ->
          case check_preauth(ip) do
            # 429: the address is exhausted; the failure is not charged again.
            {:error, retry_after_s} -> :too_many_requests
            # Charge the failure and answer 401 (403 for a key used from a
            # forbidden address).
            :ok -> :ok = record_auth_failure(ip)
          end
      end

  The bucket limits the answers a guessing address gets. It does not save the
  database lookup of `Keys.verify/2`: a guessed token with an unknown prefix is
  not cached negatively (accepted, see `PhoenixKit.API.Keys.Cache.fetch/2`).

  ## Headers

  A successful check returns `ratelimit-limit`, `ratelimit-remaining` and
  `ratelimit-reset` (seconds until the window ends). A refusal also carries
  `retry-after`. Names are lower case, as `Plug.Conn.put_resp_header/3` requires.
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKit.Utils.IpAddress

  @type headers :: [{String.t(), String.t()}]

  @minute 60_000
  @hour 3_600_000

  @doc """
  Whether `ip` may still fail authentication. Peeks; charges nothing.

  Returns `{:error, retry_after_s}` once the address has failed
  `api_admin_preauth_fail_per_min` times in the current minute.
  """
  @spec check_preauth(String.t() | nil) :: :ok | {:error, pos_integer()}
  def check_preauth(ip) do
    limit = Config.rate_limits().preauth_fail_per_min

    if Backend.get(preauth_key(ip), @minute) >= limit,
      do: {:error, seconds_left(@minute)},
      else: :ok
  end

  @doc "Counts one failed authentication from `ip`."
  @spec record_auth_failure(String.t() | nil) :: :ok
  def record_auth_failure(ip) do
    Backend.inc(preauth_key(ip), @minute)
    :ok
  end

  @doc """
  Charges `cost` units to the admin bucket of a key.

  `key_limit` is the key's own limit (`rate_limit_per_minute`, V238; `nil`, the default, for
  none). It replaces the shared `api_admin_rate_per_min` for that key, higher or lower; a key
  without one is limited exactly as before.

  When `api_total_rate_per_min` is set (`PhoenixKit.API.Config.admin_total_per_min/0`), every
  key's call is also charged to one bucket shared by all keys, so own limits cannot multiply
  what the API serves past that cap. A call the total bucket has no room for is refused
  before the key's bucket is charged. Unset (the default), there is no total bucket.

  Returns the headers to send (of the bucket with the least room left), or
  `{:error, retry_after_s, headers}` when a bucket is full.
  """
  @spec check_admin(String.t(), pos_integer(), pos_integer() | nil) ::
          {:ok, headers()} | {:error, pos_integer(), headers()}
  def check_admin(key_uuid, cost, key_limit \\ nil)
      when is_binary(key_uuid) and is_integer(cost) and cost > 0 do
    case Config.admin_total_per_min() do
      nil ->
        ("api:admin:key:" <> key_uuid)
        |> charge(@minute, admin_limit(key_limit), cost)
        |> result()

      total ->
        check_admin_with_total(key_uuid, cost, admin_limit(key_limit), total)
    end
  end

  @total_key "api:admin:total"

  defp check_admin_with_total(key_uuid, cost, key_limit, total) do
    if Backend.get(@total_key, @minute) + cost > total do
      result({:denied, %{limit: total, remaining: 0, reset: seconds_left(@minute)}})
    else
      case charge("api:admin:key:" <> key_uuid, @minute, key_limit, cost) do
        {:denied, _info} = denied ->
          result(denied)

        {:allowed, _info} = key ->
          case charge(@total_key, @minute, total, cost) do
            {:denied, _info} = denied -> result(denied)
            {:allowed, _info} = all -> result(tightest(key, all))
          end
      end
    end
  end

  defp admin_limit(key_limit) when is_integer(key_limit) and key_limit > 0, do: key_limit
  defp admin_limit(_none), do: Config.rate_limits().admin_per_min

  @doc """
  Charges `cost` units to the admin bucket of a user acting through a live session
  (`PhoenixKit.API.Executor.execute_as/5`): one bucket per user, shared by all of that
  user's sessions and apart from the buckets of the user's keys. The limit is the per-key
  one, `api_admin_rate_per_min`.
  """
  @spec check_user(String.t(), pos_integer()) ::
          {:ok, headers()} | {:error, pos_integer(), headers()}
  def check_user(user_uuid, cost)
      when is_binary(user_uuid) and is_integer(cost) and cost > 0 do
    ("api:admin:user:" <> user_uuid)
    |> charge(@minute, Config.rate_limits().admin_per_min, cost)
    |> result()
  end

  @doc """
  Charges `cost` units to the public buckets: the client network's room is
  checked first, then the client token's bucket (when there is one) is charged
  `cost`, then the network's is charged `network_cost` (`cost` unless given;
  `0` charges it nothing, and only reports its state).

  The executor charges the network bucket 1 unit before it looks a tool up
  (`check_public(ip, nil, 1)`: the token is not known yet), then the token
  bucket the tool's full price and the network bucket the rest
  (`check_public(ip, hash, cost, cost - 1)`), so one call costs `cost` units in
  each bucket.

  A client whose network bucket is full is refused before any token counter is
  created, so fresh random tokens cannot grow the shared counter table. A
  request refused by the token bucket is not charged to the network bucket (but
  it paid its first unit there, before the lookup), so a client hammering with
  one token does not use up the shared address. Headers describe the bucket
  with the least room left.
  """
  @spec check_public(String.t() | nil, String.t() | nil, pos_integer()) ::
          {:ok, headers()} | {:error, pos_integer(), headers()}
  def check_public(ip, client_token_hash, cost) when is_integer(cost) and cost > 0,
    do: check_public(ip, client_token_hash, cost, cost)

  @spec check_public(String.t() | nil, String.t() | nil, pos_integer(), non_neg_integer()) ::
          {:ok, headers()} | {:error, pos_integer(), headers()}
  def check_public(ip, client_token_hash, cost, network_cost)
      when is_integer(cost) and cost > 0 and is_integer(network_cost) and network_cost >= 0 do
    limits = Config.rate_limits()
    ip_limit = limits.public_ip_per_min

    case peek_network(ip, ip_limit, network_cost) do
      {:denied, _info} = denied ->
        result(denied)

      :room ->
        case charge_token(client_token_hash, limits.public_token_per_min, cost) do
          {:denied, _info} = denied -> result(denied)
          token -> result(charge_network(token, ip, ip_limit, network_cost))
        end
    end
  end

  @doc """
  Counts the first write of a new row against the per-network and the global
  hourly limits. A module calls it when it creates a row for a caller without a
  key; the quota is shared by every module.
  """
  @spec check_new_rows(String.t() | nil) :: :ok | {:error, pos_integer()}
  def check_new_rows(ip) do
    limits = Config.rate_limits()

    with :ok <- hit_hour("api:new_rows:ip:" <> network(ip), limits.new_rows_ip_hour) do
      hit_hour("api:new_rows:global", limits.new_rows_global_hour)
    end
  end

  # Charges nothing: whether `cost` more units still fit the network's window.
  defp peek_network(ip, limit, cost) do
    if Backend.get("api:public:ip:" <> network(ip), @minute) + cost > limit,
      do: {:denied, %{limit: limit, remaining: 0, reset: seconds_left(@minute)}},
      else: :room
  end

  # An anonymous request has no client token: that bucket is skipped.
  defp charge_token(nil, _limit, _cost), do: {:skipped, nil}

  defp charge_token(client_token_hash, limit, cost) when is_binary(client_token_hash),
    do: charge("api:public:token:" <> client_token_hash, @minute, limit, cost)

  # Nothing to add to the network bucket: report where it stands.
  defp charge_network(token, ip, limit, 0) do
    used = Backend.get("api:public:ip:" <> network(ip), @minute)

    tightest(
      token,
      {:allowed, %{limit: limit, remaining: max(limit - used, 0), reset: seconds_left(@minute)}}
    )
  end

  defp charge_network(token, ip, limit, cost) do
    case charge("api:public:ip:" <> network(ip), @minute, limit, cost) do
      {:denied, _info} = denied -> denied
      {:allowed, _info} = network -> tightest(token, network)
    end
  end

  # The headers describe the bucket with the least room left.
  defp tightest({:skipped, nil}, network), do: network

  defp tightest({:allowed, token}, {:allowed, network}),
    do: {:allowed, Enum.min_by([token, network], & &1.remaining)}

  defp hit_hour(key, limit) do
    case Backend.hit(key, @hour, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, ms_to_seconds(retry_after_ms)}
    end
  end

  defp charge(key, scale, limit, cost) do
    case Backend.hit(key, scale, limit, cost) do
      {:allow, count} ->
        {:allowed, %{limit: limit, remaining: max(limit - count, 0), reset: seconds_left(scale)}}

      {:deny, retry_after_ms} ->
        {:denied, %{limit: limit, remaining: 0, reset: ms_to_seconds(retry_after_ms)}}
    end
  end

  defp result({:allowed, info}), do: {:ok, headers(info)}

  defp result({:denied, %{reset: reset} = info}),
    do: {:error, reset, [{"retry-after", Integer.to_string(reset)} | headers(info)]}

  defp headers(%{limit: limit, remaining: remaining, reset: reset}) do
    [
      {"ratelimit-limit", Integer.to_string(limit)},
      {"ratelimit-remaining", Integer.to_string(remaining)},
      {"ratelimit-reset", Integer.to_string(reset)}
    ]
  end

  defp preauth_key(ip), do: "api:admin:preauth:ip:" <> network(ip)

  defp network(ip), do: IpAddress.network(ip) || "unknown"

  # Whole seconds until the current fixed window ends; at least 1.
  defp seconds_left(scale), do: ms_to_seconds(scale - rem(Hammer.ETS.now(), scale))

  # A refusal takes its time from the clock read of the `hit` that refused, so
  # the answer cannot name a different window than the one that was full.
  defp ms_to_seconds(ms), do: max(div(ms + 999, 1000), 1)
end
