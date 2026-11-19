defmodule PhoenixKit.API.OAuth.Limits do
  @moduledoc """
  Rate limits of the OAuth endpoints, in the Hammer table the machine API already uses
  (`PhoenixKit.Users.RateLimiter.Backend`) under keys that start with `api:oauth:`.

  | Bucket | Counted per | Window | Limit (setting) |
  |---|---|---|---|
  | `authorize` | client network | 1 min | `api_oauth_authorize_per_min`, 30 |
  | `token` (the token and revocation endpoints) | client network | 1 min | `api_oauth_token_per_min`, 60 |
  | `cimd_ip` (a client metadata document fetch) | client network | 1 min | `api_oauth_cimd_per_min`, 20 |
  | `cimd_client` (a client metadata document fetch) | `client_id` | 1 min | `api_oauth_cimd_client_per_min`, 5 |
  | `register_ip` (Dynamic Client Registration) | client network | 1 h | `api_oauth_register_per_hour`, 10 |
  | `register_global` (Dynamic Client Registration) | the whole install | 1 day | `api_oauth_register_per_day`, 200 |

  A client network is `PhoenixKit.Utils.IpAddress.network/1`: an IPv4 address as it is, an IPv6
  address as its /64. The failures of these endpoints are counted here and nowhere else: they never
  touch the pre-authentication bucket of the MCP endpoint (`PhoenixKit.API.RateLimit`). A request is
  counted when it arrives, whatever its answer, so a client cannot probe for free.

  The windows are fixed and counted per node.
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKit.Utils.IpAddress

  @minute 60_000
  @hour 3_600_000
  @day 86_400_000

  @type bucket ::
          :authorize | :token | :cimd_ip | :cimd_client | :register_ip | :register_global

  @doc """
  Counts one request of `bucket`: `subject` is the client address for the per-network buckets,
  the `client_id` for `:cimd_client`, and ignored for `:register_global`. `:ok`, or
  `{:error, retry_after_seconds}` once the window is used up.
  """
  @spec hit(bucket(), String.t() | nil) :: :ok | {:error, pos_integer()}
  def hit(bucket, subject) do
    {scale, limit} = window(bucket)

    case Backend.hit(key(bucket, subject), scale, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, max(div(retry_after_ms + 999, 1000), 1)}
    end
  end

  # Empties a bucket, for the tests whose counters would otherwise live as long as the node. It
  # exists only in a build compiled with `config :phoenix_kit, oauth_test_seams: true` (this
  # library's own `config/test.exs`): the public API of an application has no such function.
  if Application.compile_env(:phoenix_kit, :oauth_test_seams, false) do
    @doc false
    @spec reset(bucket(), String.t() | nil) :: :ok
    def reset(bucket, subject) do
      {scale, _limit} = window(bucket)
      Backend.set(key(bucket, subject), scale, 0)
      :ok
    end
  end

  defp window(:authorize), do: {@minute, Config.oauth_authorize_per_min()}
  defp window(:token), do: {@minute, Config.oauth_token_per_min()}
  defp window(:cimd_ip), do: {@minute, Config.oauth_cimd_per_min()}
  defp window(:cimd_client), do: {@minute, Config.oauth_cimd_client_per_min()}
  defp window(:register_ip), do: {@hour, Config.oauth_register_per_hour()}
  defp window(:register_global), do: {@day, Config.oauth_register_per_day()}

  defp key(:cimd_client, client_id),
    do: "api:oauth:cimd_client:" <> Base.url_encode64(:crypto.hash(:sha256, to_string(client_id)))

  defp key(:register_global, _subject), do: "api:oauth:register_global"

  defp key(bucket, ip), do: "api:oauth:#{bucket}:" <> (IpAddress.network(ip) || "unknown")
end
