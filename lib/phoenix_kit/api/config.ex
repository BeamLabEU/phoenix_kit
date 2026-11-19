defmodule PhoenixKit.API.Config do
  @moduledoc """
  Settings accessors for the machine API.

  Every function reads a core setting through `PhoenixKit.Settings` and applies a
  safe default. The API is **off by default and fails closed**: a switch is on
  only when its setting reads exactly `"true"`, so a missing row, an unreadable
  database, an unexpected value or a Settings error all count as off.

  ## Settings

  | Key | Default |
  |---|---|
  | `api_admin_enabled` | `false` |
  | `api_public_enabled` | `false` |
  | `api_oauth_enabled` | `false` (only counts while `api_admin_enabled` is on) |
  | `api_oauth_access_ttl_seconds` | `3600` (clamped to 300..86400) |
  | `api_oauth_authorize_per_min` | `30` (authorization requests per client network) |
  | `api_oauth_token_per_min` | `60` (token and revocation requests per client network) |
  | `api_oauth_requests_ceiling` | `1000` (authorization requests waiting for consent, all clients) |
  | `api_oauth_grants_per_person` | `10` (live grants one person may hold) |
  | `api_disabled_tools` | `""` (newline separated tool names) |
  | `api_disabled_modules` | `""` (newline separated module keys) |
  | `api_session_write_modules` | `""` (newline separated module keys) |
  | `api_mcp_allowed_origins` | `""` (newline separated origins) |
  | `api_admin_preauth_fail_per_min` | `20` |
  | `api_admin_rate_per_min` | `600` |
  | `api_public_token_rate_per_min` | `120` |
  | `api_public_ip_rate_per_min` | `300` |
  | `api_public_new_rows_per_ip_hour` | `120` |
  | `api_public_new_rows_global_hour` | `2000` |

  List settings are stored as newline-separated strings: `PhoenixKit.Settings`
  has no list setter and a JSON setting cannot hold a bare list. Use
  `encode_list/1` when writing one and `parse_list/1` when reading one.
  """

  alias PhoenixKit.Settings

  @type rate_limits :: %{
          preauth_fail_per_min: pos_integer(),
          admin_per_min: pos_integer(),
          public_token_per_min: pos_integer(),
          public_ip_per_min: pos_integer(),
          new_rows_ip_hour: pos_integer(),
          new_rows_global_hour: pos_integer()
        }

  @max_body_bytes 2_097_152

  @rate_defaults [
    preauth_fail_per_min: {"api_admin_preauth_fail_per_min", 20},
    admin_per_min: {"api_admin_rate_per_min", 600},
    public_token_per_min: {"api_public_token_rate_per_min", 120},
    public_ip_per_min: {"api_public_ip_rate_per_min", 300},
    new_rows_ip_hour: {"api_public_new_rows_per_ip_hour", 120},
    new_rows_global_hour: {"api_public_new_rows_global_hour", 2000}
  ]

  @doc "Whether the admin API (`/api/admin/v1`) is switched on. Fails closed."
  @spec admin_enabled?() :: boolean()
  def admin_enabled?, do: flag("api_admin_enabled")

  @doc "Whether the public API (`/api/public/v1`, MCP) is switched on. Fails closed."
  @spec public_enabled?() :: boolean()
  def public_enabled?, do: flag("api_public_enabled")

  @doc """
  Whether OAuth for the admin MCP endpoint (`PhoenixKit.API.OAuth`) is switched on: the
  `api_oauth_enabled` setting reads exactly `"true"` **and** the admin API is on. Fails closed
  like the other switches. While it is off, no OAuth token is accepted, the `401` challenge of
  the MCP endpoint is the plain one and the OAuth paths read no body.
  """
  @spec oauth_enabled?() :: boolean()
  def oauth_enabled?, do: admin_enabled?() and flag("api_oauth_enabled")

  @oauth_access_ttl_default 3_600
  @oauth_access_ttl_range 300..86_400

  @doc """
  Seconds an OAuth access token lives (`api_oauth_access_ttl_seconds`): 5 minutes to 24 hours,
  one hour when the setting is missing or unreadable.
  """
  @spec oauth_access_ttl_seconds() :: pos_integer()
  def oauth_access_ttl_seconds do
    "api_oauth_access_ttl_seconds"
    |> int(@oauth_access_ttl_default)
    |> max(@oauth_access_ttl_range.first)
    |> min(@oauth_access_ttl_range.last)
  end

  @doc """
  Tool names the install has hidden (`api_disabled_tools`). For display only: a list that
  cannot be read is `[]` here, so request paths (`PhoenixKit.API.Registry`) use
  `fetch_disabled_tools/0`, which does not treat it as "nothing is hidden".
  """
  @spec disabled_tools() :: [String.t()]
  def disabled_tools do
    case fetch_disabled_tools() do
      {:ok, names} -> names
      :unreadable -> []
    end
  end

  @doc "Authorization requests per minute and client network (`api_oauth_authorize_per_min`, 30)."
  @spec oauth_authorize_per_min() :: pos_integer()
  def oauth_authorize_per_min, do: int("api_oauth_authorize_per_min", 30)

  @doc "Token and revocation requests per minute and client network (`api_oauth_token_per_min`, 60)."
  @spec oauth_token_per_min() :: pos_integer()
  def oauth_token_per_min, do: int("api_oauth_token_per_min", 60)

  @doc """
  How many authorization requests may wait for a person's consent at once, all clients
  together (`api_oauth_requests_ceiling`, 1000).
  """
  @spec oauth_requests_ceiling() :: pos_integer()
  def oauth_requests_ceiling, do: int("api_oauth_requests_ceiling", 1000)

  @doc """
  How many live grants (activated, or not yet activated with a code still alive) one person may
  hold (`api_oauth_grants_per_person`, 10).
  """
  @spec oauth_grants_per_person() :: pos_integer()
  def oauth_grants_per_person, do: int("api_oauth_grants_per_person", 10)

  @doc """
  Tool names the install has hidden (`api_disabled_tools`), telling a list that is empty
  from one that could not be read at all (a read that raises or exits).

  The tool registry fails closed on `:unreadable`: a tool the admin switched off must not
  come back because of a settings problem. This is the one reader of the setting.
  """
  @spec fetch_disabled_tools() :: {:ok, [String.t()]} | :unreadable
  def fetch_disabled_tools, do: fetch_list("api_disabled_tools")

  @doc """
  Module keys whose API tools the install has switched off (`api_disabled_modules`). For
  display only, like `disabled_tools/0`: a list that cannot be read is `[]` here.
  """
  @spec disabled_modules() :: [String.t()]
  def disabled_modules do
    case fetch_disabled_modules() do
      {:ok, keys} -> keys
      :unreadable -> []
    end
  end

  @doc """
  Module keys whose API tools the install has switched off (`api_disabled_modules`), telling
  an empty list from one that could not be read at all. A module that is not in the list has
  its API on, so every install starts with all of them on.

  The tool registry fails closed on `:unreadable`, as with `fetch_disabled_tools/0`. This is
  the one reader of the setting.
  """
  @spec fetch_disabled_modules() :: {:ok, [String.t()]} | :unreadable
  def fetch_disabled_modules, do: fetch_list("api_disabled_modules")

  @doc """
  Module keys whose write tools a person's live session may call
  (`api_session_write_modules`, the "Agent may act" boxes of Settings -> API). For display
  only, like `disabled_modules/0`: a list that cannot be read is `[]` here.
  """
  @spec session_write_modules() :: [String.t()]
  def session_write_modules do
    case fetch_session_write_modules() do
      {:ok, keys} -> keys
      :unreadable -> []
    end
  end

  @doc """
  Module keys whose write tools a person's live session may call
  (`api_session_write_modules`), telling an empty list from one that could not be read.

  An allow-list that fails closed: a module that is not listed has no write for a session,
  so every install starts with none, and the executor treats `:unreadable` as an empty
  list. API keys do not read it. This is the one reader of the setting.
  """
  @spec fetch_session_write_modules() :: {:ok, [String.t()]} | :unreadable
  def fetch_session_write_modules, do: fetch_list("api_session_write_modules")

  @doc "Extra origins allowed to call the MCP endpoint (`api_mcp_allowed_origins`)."
  @spec mcp_allowed_origins() :: [String.t()]
  def mcp_allowed_origins, do: list("api_mcp_allowed_origins")

  @doc """
  Reads an integer setting.

  Returns `default` when the setting is missing, is not a whole number (`"12abc"` and
  `"1.5"` are not read by their prefix), is zero or negative, or cannot be read. Every API
  integer setting is a positive limit, and a zero limit would silently refuse every
  request, so a non-positive value is treated as unset.
  """
  @spec int(String.t(), integer()) :: integer()
  def int(key, default) when is_binary(key) and is_integer(default) do
    limit(key) || default
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  @doc "Largest request body the API accepts, in bytes (2 MB)."
  @spec max_body_bytes() :: 2_097_152
  def max_body_bytes, do: @max_body_bytes

  @doc """
  The rate-limit settings as one map.

  `*_per_min` limits count over a 60 second window and `*_hour` limits over a
  one hour window (see `PhoenixKit.API.RateLimit`).
  """
  @spec rate_limits() :: rate_limits()
  def rate_limits do
    Map.new(@rate_defaults, fn {name, {key, default}} ->
      {name, int(key, default)}
    end)
  end

  @doc """
  Splits a newline-separated setting value into a list.

  Lines are trimmed; blank lines and duplicates are dropped. `nil` is `[]`.
  """
  @spec parse_list(String.t() | nil) :: [String.t()]
  def parse_list(value) when is_binary(value) do
    value
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_list(_), do: []

  @doc "Joins a list into the newline-separated form the list settings are stored in."
  @spec encode_list([String.t()]) :: String.t()
  def encode_list(items) when is_list(items), do: Enum.join(items, "\n")

  defp flag(key) do
    Settings.get_boolean_setting(key, false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp list(key) do
    case fetch_list(key) do
      {:ok, items} -> items
      :unreadable -> []
    end
  end

  # The setting as a limit: a whole number above zero, else `nil`.
  defp limit(key) do
    case key |> Settings.get_setting_cached(nil) |> whole_number() do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp whole_number(value) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp whole_number(_value), do: nil

  defp fetch_list(key) do
    case Settings.fetch_setting_cached(key) do
      {:ok, value} when is_binary(value) or is_nil(value) -> {:ok, parse_list(value)}
      _ -> :unreadable
    end
  rescue
    _ -> :unreadable
  catch
    :exit, _ -> :unreadable
  end
end
