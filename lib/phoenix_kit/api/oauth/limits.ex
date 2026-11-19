defmodule PhoenixKit.API.OAuth.Limits do
  @moduledoc """
  Rate limits of the OAuth endpoints, per client network (`PhoenixKit.Utils.IpAddress.network/1`:
  an IPv4 address as it is, an IPv6 address as its /64), in the Hammer table the machine API
  already uses (`PhoenixKit.Users.RateLimiter.Backend`) under keys that start with `api:oauth:`.

  | Bucket | Window | Limit (setting) |
  |---|---|---|
  | `authorize` | 1 min | `api_oauth_authorize_per_min`, 30 |
  | `token` (the token and revocation endpoints) | 1 min | `api_oauth_token_per_min`, 60 |

  The failures of these endpoints are counted here and nowhere else: they never touch the
  pre-authentication bucket of the MCP endpoint (`PhoenixKit.API.RateLimit`). A request is
  counted when it arrives, whatever its answer, so a client cannot probe for free.

  The windows are fixed and counted per node.
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKit.Utils.IpAddress

  @minute 60_000

  @type bucket :: :authorize | :token

  @doc """
  Counts one request of `bucket` from `ip`. `:ok`, or `{:error, retry_after_seconds}` once the
  network has used its minute up.
  """
  @spec hit(bucket(), String.t() | nil) :: :ok | {:error, pos_integer()}
  def hit(bucket, ip) when bucket in [:authorize, :token] do
    key = "api:oauth:#{bucket}:" <> (IpAddress.network(ip) || "unknown")

    case Backend.hit(key, @minute, limit(bucket)) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, max(div(retry_after_ms + 999, 1000), 1)}
    end
  end

  defp limit(:authorize), do: Config.oauth_authorize_per_min()
  defp limit(:token), do: Config.oauth_token_per_min()
end
