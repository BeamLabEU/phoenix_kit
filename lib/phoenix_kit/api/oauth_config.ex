defmodule PhoenixKit.API.OAuthConfig do
  @moduledoc """
  The form of Settings -> API -> OAuth: how long an access token lives, how many connections a
  person may hold, the limits of the public OAuth endpoints, and which clients may connect.
  (The two switches, `api_oauth_enabled` and `api_oauth_dcr_enabled`, are toggles of their own and
  are not part of this form.)

  | Setting | Default | Allowed |
  |---|---|---|
  | `api_oauth_access_ttl_seconds` | `3600` | 300 to 86400 |
  | `api_oauth_grants_per_person` | `10` | 1 to 100 |
  | `api_oauth_authorize_per_min` | `30` | 1 to 1000000 |
  | `api_oauth_token_per_min` | `60` | 1 to 1000000 |
  | `api_oauth_requests_ceiling` | `1000` | 1 to 1000000 |
  | `api_oauth_cimd_per_min` | `20` | 1 to 1000 |
  | `api_oauth_cimd_client_per_min` | `5` | 1 to 1000 |
  | `api_oauth_cimd_concurrency` | `4` | 1 to 64 |
  | `api_oauth_register_per_hour` | `10` | 1 to 10000 |
  | `api_oauth_register_per_day` | `200` | 1 to 100000 |
  | `api_oauth_client_policy` | `any` | `any` or `allow_list` |
  | `api_oauth_client_allow_hosts` | empty | up to 100 host names, one per line |

  The life of a **connection** is not here: the person chooses it on the consent screen, up to the
  ceiling of personal keys (`PhoenixKit.API.PersonalKeysConfig.max_days/0`), and the refresh token
  lives as long as the connection.

  The readers are the ones of `PhoenixKit.API.Config`: a stored value that does not parse reads as
  the default, and an access token life outside its range reads as the nearest end of it. The form
  is all or nothing in its validation, like `PhoenixKit.API.FlowConfig`'s: one invalid field saves
  nothing. Once every field is valid only the values that changed are written, each on its own (no
  transaction) and each as a permanent `setting.changed` Activity entry
  (`Settings.update_setting_with_module/4`); if a database error stops one of them,
  `save/2` answers `{:error, :save_failed}` and the others may be saved, so a page shows
  `current/0` again rather than what was typed.

  The allowed hosts are plain host names (`claude.ai`, an IP literal, `[::1]`): lower-cased,
  trimmed, without duplicates. They apply to clients that name or register themselves, never to
  one an administrator added by hand (`PhoenixKit.API.OAuth.ClientPolicy`).
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.Settings

  @fields [
    %{
      field: "access_ttl_seconds",
      setting: "api_oauth_access_ttl_seconds",
      min: 300,
      max: 86_400,
      reader: :oauth_access_ttl_seconds
    },
    %{
      field: "grants_per_person",
      setting: "api_oauth_grants_per_person",
      min: 1,
      max: 100,
      reader: :oauth_grants_per_person
    },
    %{
      field: "authorize_per_min",
      setting: "api_oauth_authorize_per_min",
      min: 1,
      max: 1_000_000,
      reader: :oauth_authorize_per_min
    },
    %{
      field: "token_per_min",
      setting: "api_oauth_token_per_min",
      min: 1,
      max: 1_000_000,
      reader: :oauth_token_per_min
    },
    %{
      field: "requests_ceiling",
      setting: "api_oauth_requests_ceiling",
      min: 1,
      max: 1_000_000,
      reader: :oauth_requests_ceiling
    },
    %{
      field: "cimd_per_min",
      setting: "api_oauth_cimd_per_min",
      min: 1,
      max: 1000,
      reader: :oauth_cimd_per_min
    },
    %{
      field: "cimd_client_per_min",
      setting: "api_oauth_cimd_client_per_min",
      min: 1,
      max: 1000,
      reader: :oauth_cimd_client_per_min
    },
    %{
      field: "cimd_concurrency",
      setting: "api_oauth_cimd_concurrency",
      min: 1,
      max: 64,
      reader: :oauth_cimd_concurrency
    },
    %{
      field: "register_per_hour",
      setting: "api_oauth_register_per_hour",
      min: 1,
      max: 10_000,
      reader: :oauth_register_per_hour
    },
    %{
      field: "register_per_day",
      setting: "api_oauth_register_per_day",
      min: 1,
      max: 100_000,
      reader: :oauth_register_per_day
    }
  ]

  @policy_setting "api_oauth_client_policy"
  @hosts_setting "api_oauth_client_allow_hosts"
  @max_hosts 100
  @max_host_length 253

  @doc "The numeric fields of the form, in the order the page shows them."
  @spec fields() :: [map()]
  def fields, do: @fields

  @doc "The current value of every form field, as the text the field shows."
  @spec current() :: %{String.t() => String.t()}
  def current do
    numbers =
      Map.new(@fields, fn %{field: field, reader: reader} ->
        {field, Config |> apply(reader, []) |> Integer.to_string()}
      end)

    Map.merge(numbers, %{
      "client_policy" => policy_text(Config.oauth_client_policy()),
      "allow_hosts" => hosts_text()
    })
  end

  defp policy_text(:any), do: "any"
  defp policy_text(:allow_list), do: "allow_list"

  defp hosts_text do
    case Config.fetch_oauth_allow_hosts() do
      {:ok, hosts} -> Config.encode_list(hosts)
      :unreadable -> ""
    end
  end

  @doc """
  Checks a submitted form. `{:ok, [{setting, text}]}` (the text each setting is stored as) when
  every field is valid; otherwise `{:error, fields}` naming every bad field, a missing one
  included (never read as the default).
  """
  @spec validate(term()) :: {:ok, [{String.t(), String.t()}]} | {:error, [String.t()]}
  def validate(params) when is_map(params) do
    parsed =
      Enum.map(@fields, fn %{field: field, setting: setting, min: min, max: max} ->
        {field, setting, number(Map.get(params, field), min, max)}
      end) ++
        [
          {"client_policy", @policy_setting, policy(Map.get(params, "client_policy"))},
          {"allow_hosts", @hosts_setting, hosts(Map.get(params, "allow_hosts"))}
        ]

    case for({field, _setting, :error} <- parsed, do: field) do
      [] -> {:ok, for({_field, setting, {:ok, text}} <- parsed, do: {setting, text})}
      bad -> {:error, bad}
    end
  end

  def validate(_params),
    do: {:error, Enum.map(@fields, & &1.field) ++ ["client_policy", "allow_hosts"]}

  @doc """
  Validates and writes a form. Returns the settings that changed. `opts` are the history options
  of `Settings.update_setting_with_module/4` (`actor_uuid:`, `source:`).
  """
  @spec save(term(), keyword()) :: {:ok, [String.t()]} | {:error, [String.t()] | :save_failed}
  def save(params, opts) do
    with {:ok, pairs} <- validate(params) do
      current = current()
      names = Map.new(all_settings(), fn {field, setting} -> {setting, field} end)
      changed = for {setting, text} <- pairs, text != current[names[setting]], do: {setting, text}

      results =
        Enum.map(changed, fn {setting, text} ->
          Settings.update_setting_with_module(setting, text, "api", opts)
        end)

      if Enum.all?(results, &match?({:ok, _setting}, &1)),
        do: {:ok, Enum.map(changed, &elem(&1, 0))},
        else: {:error, :save_failed}
    end
  end

  defp all_settings do
    Enum.map(@fields, &{&1.field, &1.setting}) ++
      [{"client_policy", @policy_setting}, {"allow_hosts", @hosts_setting}]
  end

  # --- parsing ---------------------------------------------------------

  defp number(value, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number >= min and number <= max -> {:ok, Integer.to_string(number)}
      _ -> :error
    end
  end

  defp number(_value, _min, _max), do: :error

  defp policy(value) when value in ["any", "allow_list"], do: {:ok, value}
  defp policy(_value), do: :error

  defp hosts(value) when is_binary(value) do
    with true <- String.valid?(value),
         list = value |> Config.parse_list() |> Enum.map(&String.downcase/1) |> Enum.uniq(),
         true <- length(list) <= @max_hosts,
         true <- Enum.all?(list, &host?/1) do
      {:ok, Config.encode_list(list)}
    else
      _ -> :error
    end
  end

  defp hosts(_value), do: :error

  # A host name, an IPv4 literal or a bracketed IPv6 literal: nothing that carries a scheme, a
  # path, a port or whitespace.
  defp host?(host) do
    byte_size(host) <= @max_host_length and
      (Regex.match?(~r/\A[a-z0-9]([a-z0-9.-]*[a-z0-9])?\z/, host) or
         Regex.match?(~r/\A\[[0-9a-f:.]+\]\z/, host))
  end
end
