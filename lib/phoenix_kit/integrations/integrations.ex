defmodule PhoenixKit.Integrations do
  @moduledoc """
  Centralized management of external service integrations.

  Stores credentials (OAuth tokens, API keys, bot tokens, etc.) using the
  existing `PhoenixKit.Settings` system with `value_json` JSONB storage.
  Each integration is a JSON blob under a key like
  `"integration:google:default"` (`integration:{provider}:{name}`).

  Connections are referenced by the storage row's UUID. Names are pure
  user-chosen labels with no system semantics — they can be renamed or
  removed freely; consumer modules pin to UUIDs that survive renames.

  ## Auth types supported

  - `:oauth2` — Google, Microsoft, Slack, etc. (client_id/secret + access/refresh tokens)
  - `:api_key` — OpenRouter, Stripe, SendGrid, etc. (single API key)
  - `:key_secret` — AWS, Twilio, etc. (access key + secret key)
  - `:bot_token` — Telegram, Discord, etc. (single bot token)
  - `:credentials` — SMTP, databases, etc. (freeform credential map)

  ## Usage

  Consumer modules (AI endpoints, document creator, etc.) store an
  integration's UUID on their own records and resolve credentials by UUID:

      # Look up the row by uuid (the stable reference consumers store)
      {:ok, %{provider: "openrouter", name: "default", data: data}} =
        PhoenixKit.Integrations.get_integration_by_uuid(integration_uuid)

      # Get credentials for API calls — accepts either a uuid or a
      # `provider:name` shape
      {:ok, creds} = PhoenixKit.Integrations.get_credentials(integration_uuid)
      # => %{"access_token" => "ya29...", "token_type" => "Bearer", ...}

      # Make an authenticated request with auto-refresh on 401
      {:ok, response} =
        PhoenixKit.Integrations.authenticated_request(integration_uuid, :get, url)

  ## Renaming and removing

  Any connection can be renamed or removed — there's no privileged
  `"default"` name. The storage row's UUID stays stable across renames,
  so consumer references don't break:

      {:ok, _} = PhoenixKit.Integrations.rename_connection(uuid, "work")
      :ok = PhoenixKit.Integrations.remove_connection(uuid)

  ## API shape (uuid-strict)

  Every operation past row creation takes the row's `uuid`. The only
  exceptions are:

  - `add_connection/3` — row birth, no uuid exists yet
  - `get_integration/1`, `find_uuid_by_provider_name/1` — read shims for
    legacy `migrate_legacy/0` callbacks that walk pre-uuid data shapes

  The structural rule: `"integration:{provider}:{name}"` storage-key
  construction happens only inside `add_connection/3` (creation) and
  module-side `migrate_legacy/0` migrators (translation). Every other
  caller routes by uuid, so a corrupted JSONB `provider`/`name` field
  cannot leak into a new storage key.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.Events
  alias PhoenixKit.Integrations.OAuth
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Settings.Setting

  @settings_module "integrations"
  @http_timeout 15_000

  # ---------------------------------------------------------------------------
  # Reading credentials
  # ---------------------------------------------------------------------------

  @doc """
  Get the full integration data for a provider.

  Returns the entire JSON blob including credentials, status, and metadata.
  Misses return `:not_configured` (or `:deleted` for uuid input) — there's
  no on-read legacy-shape migration in core anymore. Modules with legacy
  data own their own migration via the `migrate_legacy/0` callback on
  `PhoenixKit.Module` (orchestrated by
  `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`).
  """
  @spec get_integration(String.t()) ::
          {:ok, map()} | {:error, :not_configured | :invalid_provider_key}
  def get_integration(provider_key) when is_binary(provider_key) and provider_key != "" do
    # Check if this looks like a UUID (used when endpoints store the settings UUID)
    data =
      if uuid?(provider_key) do
        Settings.get_json_setting_by_uuid(provider_key)
      else
        Settings.get_json_setting(settings_key(provider_key), nil)
      end

    case data do
      nil ->
        # No on-read legacy fallback in core anymore — module-side
        # `migrate_legacy/0` callbacks handle data-shape migrations.
        # Boot-time orchestration via `ModuleRegistry.run_all_legacy_migrations/0`.
        {:error, :not_configured}

      %{} = data ->
        {:ok, Encryption.decrypt_fields(data)}
    end
  end

  def get_integration(_), do: {:error, :invalid_provider_key}

  @doc """
  Look up an integration row by its settings UUID and return a normalized
  shape with `provider`, `name`, `data`, and the original `uuid`.

  Used by the integration form LV (route `/admin/settings/integrations/:uuid`)
  so the URL is stable across renames — the human-readable `name` lives in
  the JSONB blob, the URL stays pinned to the row's storage UUID.
  """
  @spec get_integration_by_uuid(String.t()) ::
          {:ok, %{uuid: String.t(), provider: String.t(), name: String.t(), data: map()}}
          | {:error, :not_configured | :invalid_uuid}
  def get_integration_by_uuid(uuid) when is_binary(uuid) and uuid != "" do
    # Read the row's `key` column directly — it's the canonical
    # `integration:{provider}:{name}` shape and can't drift from the
    # row's actual location. The JSONB `provider` / `name` fields are
    # internal duplicates that have historically gotten out of sync
    # (a buggy save round can write `name` = "foo:default" because of
    # a bad full_key concat upstream); always source provider+name
    # from the storage key, never from the JSONB body.
    case Queries.get_setting_by_uuid(uuid) do
      %{key: "integration:" <> rest, value_json: data} when is_map(data) ->
        {provider, name} = parse_provider_name(rest)

        {:ok,
         %{uuid: uuid, provider: provider, name: name, data: Encryption.decrypt_fields(data)}}

      _ ->
        {:error, :not_configured}
    end
  end

  def get_integration_by_uuid(_), do: {:error, :invalid_uuid}

  @doc """
  Resolve a `provider:name`-style reference to the storage row's uuid.

  Used by consumer modules' `migrate_legacy/0` implementations to walk
  legacy name-string references and rewrite them to uuid references.
  Accepts a few input shapes for convenience:

  - `"openrouter:work"` — full provider:name pair
  - `"openrouter"` — bare provider, treated as `provider:default`
  - `{"openrouter", "work"}` — explicit tuple

  Returns `{:ok, uuid}` if a matching row exists, `{:error, :not_found}`
  if not, `{:error, :invalid}` for malformed input. Does NOT auto-pick
  an arbitrary connection when multiple match — that's not the
  caller's intent here.
  """
  @spec find_uuid_by_provider_name(String.t() | {String.t(), String.t()}) ::
          {:ok, String.t()} | {:error, :not_found | :invalid}
  def find_uuid_by_provider_name(input)

  def find_uuid_by_provider_name({provider, name})
      when is_binary(provider) and is_binary(name) and provider != "" and name != "" do
    case Enum.find(list_connections(provider), &(&1.name == name)) do
      %{uuid: uuid} -> {:ok, uuid}
      _ -> {:error, :not_found}
    end
  end

  def find_uuid_by_provider_name(string) when is_binary(string) and string != "" do
    {provider, name} = parse_provider_name(string)
    find_uuid_by_provider_name({provider, name})
  end

  def find_uuid_by_provider_name(_), do: {:error, :invalid}

  @doc """
  Resolves a binary that may be EITHER an integration row's uuid OR a
  `provider:name` string into the canonical row uuid.

  This is the dual-input lookup that consumer modules' lazy-promotion
  paths and migration sweeps converge on — code that reads a legacy
  string from a column where the operator might have stuffed a uuid
  pre-V107, or a `provider:name` shape pre-uuid-strict, or a bare
  provider key. Each consumer used to copy the same regex + dispatch
  pair into its own helper; this primitive centralises it so a future
  provider doesn't tempt a third copy.

  Returns `{:ok, uuid}` if the input resolves to a current row,
  `{:error, :not_found}` if it parses cleanly but no matching row
  exists, `{:error, :invalid}` for malformed input (empty string, nil,
  non-binary).

  ## Examples

      iex> resolve_to_uuid("019b669c-3c9d-7256-8ed1-edbc6ae29703")
      {:ok, "019b669c-3c9d-7256-8ed1-edbc6ae29703"}  # already-uuid path

      iex> resolve_to_uuid("openrouter:default")
      {:ok, "..."}  # provider:name path → find_uuid_by_provider_name

      iex> resolve_to_uuid("openrouter")
      {:ok, "..."}  # bare provider, treated as provider:default

  See `find_uuid_by_provider_name/1` for the provider:name half of the
  lookup. The split exists because that primitive doesn't handle the
  "input is already a uuid" case — it'd treat `"019b669c-..."` as a
  provider name and search `integration:019b669c-...:default`.
  """
  @spec resolve_to_uuid(String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :invalid}
  def resolve_to_uuid(input) when is_binary(input) and input != "" do
    if uuid?(input) do
      case get_integration_by_uuid(input) do
        {:ok, _} -> {:ok, input}
        _ -> {:error, :not_found}
      end
    else
      find_uuid_by_provider_name(input)
    end
  end

  def resolve_to_uuid(_), do: {:error, :invalid}

  @doc """
  Get credentials for a provider, suitable for making API calls.

  Returns the full integration data map. The caller extracts what it needs
  based on the auth type (e.g., `"access_token"` for OAuth, `"api_key"` for API key).
  """
  @spec get_credentials(String.t()) :: {:ok, map()} | {:error, :not_configured | :deleted}
  def get_credentials(provider_key) when is_binary(provider_key) and provider_key != "" do
    is_uuid = uuid?(provider_key)

    data =
      if is_uuid do
        Settings.get_json_setting_by_uuid(provider_key)
      else
        Settings.get_json_setting(settings_key(provider_key), nil)
      end

    case data do
      %{} = data when map_size(data) > 0 ->
        decrypted = Encryption.decrypt_fields(data)
        if has_credentials?(decrypted), do: {:ok, decrypted}, else: {:error, :not_configured}

      _ ->
        # uuid lookup that missed → row was deleted; bare-provider /
        # provider:name lookup that missed → never configured. Both
        # surface as the appropriate atom so callers can distinguish.
        if is_uuid, do: {:error, :deleted}, else: {:error, :not_configured}
    end
  end

  def get_credentials(_), do: {:error, :not_configured}

  @doc """
  Check if an integration is connected and has valid credentials.
  """
  @spec connected?(String.t()) :: boolean()
  def connected?(provider_key) when is_binary(provider_key) do
    case get_credentials(provider_key) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def connected?(_), do: false

  # ---------------------------------------------------------------------------
  # Setup (saving app-level credentials)
  # ---------------------------------------------------------------------------

  @doc """
  Save setup credentials for an existing connection (referenced by uuid).

  For OAuth providers, this saves client_id/client_secret.
  For API key providers, this saves the api_key.
  For bot token providers, this saves the bot_token.

  Merges with existing data to preserve any previously obtained tokens.
  Sets status to "disconnected" if no runtime credentials exist yet.

  The connection must exist (`add_connection/3` is the row-birth path).
  Returns `{:error, :not_configured}` if the uuid doesn't resolve.
  """
  @spec save_setup(String.t(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_configured | :invalid_uuid | term()}
  def save_setup(uuid, attrs, actor_uuid \\ nil) when is_binary(uuid) and is_map(attrs) do
    with {:ok, %{provider_key: provider_key, data: existing}} <- resolve_uuid(uuid) do
      {base_provider, name} = parse_provider_name(provider_key)
      provider = Providers.get(base_provider)

      data =
        existing
        |> Map.merge(attrs)
        |> Map.put("provider", base_provider)
        |> Map.put("name", name)
        |> Map.put("auth_type", provider && Atom.to_string(provider.auth_type))
        |> maybe_set_status(provider)
        |> maybe_set_connected_at()

      case save_integration(provider_key, data) do
        {:ok, saved} = result ->
          Events.broadcast_setup_saved(provider_key, saved)

          log_activity(
            "integration.setup_saved",
            provider_key,
            %{"status" => saved["status"]},
            "manual",
            actor_uuid
          )

          result

        error ->
          error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # OAuth flow
  # ---------------------------------------------------------------------------

  @doc """
  Build the OAuth authorization URL for a connection (by uuid).

  Accepts an optional `state` parameter for CSRF protection. Use
  `PhoenixKit.Integrations.OAuth.generate_state/0` to generate one,
  store it in the session or socket assigns, and verify it when the
  callback arrives.
  """
  @spec authorization_url(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def authorization_url(uuid, redirect_uri, extra_scopes \\ nil, state \\ nil)
      when is_binary(uuid) do
    with {:ok, %{provider_key: provider_key, data: data}} <- resolve_uuid(uuid),
         {base_provider, _name} = parse_provider_name(provider_key),
         {:ok, provider} <- fetch_provider(base_provider) do
      OAuth.authorization_url(provider.oauth_config, data, redirect_uri, extra_scopes, state)
    end
  end

  @doc """
  Exchange an OAuth authorization code for tokens and save them on the
  connection identified by `uuid`.
  """
  @spec exchange_code(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def exchange_code(uuid, code, redirect_uri, actor_uuid \\ nil) when is_binary(uuid) do
    with {:ok, %{provider_key: provider_key, data: data}} <- resolve_uuid(uuid),
         {base_provider, _name} = parse_provider_name(provider_key),
         {:ok, provider} <- fetch_provider(base_provider),
         {:ok, token_data} <- OAuth.exchange_code(provider.oauth_config, data, code, redirect_uri) do
      userinfo = fetch_userinfo_safe(provider, token_data["access_token"])

      updated =
        data
        |> Map.merge(token_data)
        |> Map.put("status", "connected")
        |> Map.put("connected_at", DateTime.utc_now() |> DateTime.to_iso8601())
        |> Map.put(
          "scopes",
          provider.oauth_config[:default_scopes] || provider.oauth_config["default_scopes"]
        )
        |> maybe_set_userinfo(userinfo)

      case save_integration(provider_key, updated) do
        {:ok, saved} = result ->
          Events.broadcast_connected(provider_key, saved)

          log_activity(
            "integration.connected",
            provider_key,
            %{
              "account" => saved["external_account_id"]
            },
            "manual",
            actor_uuid
          )

          result

        error ->
          error
      end
    end
  end

  @doc """
  Refresh an expired OAuth access token and save the new one.

  On failure, stamps the integration record with `status: "error"` and a
  human-readable `validation_status` so the UI reflects the broken state
  without waiting for an admin to click "Test Connection".
  On success following a previously-errored state, auto-recovers the status
  back to `"connected"`.
  """
  @spec refresh_access_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def refresh_access_token(uuid) when is_binary(uuid) do
    result =
      with {:ok, %{provider_key: provider_key, data: data}} <- resolve_uuid(uuid),
           {base_provider, _name} = parse_provider_name(provider_key),
           {:ok, provider} <- fetch_provider(base_provider),
           {:ok, new_token, updated_fields} <-
             OAuth.refresh_access_token(provider.oauth_config, data) do
        updated = Map.merge(data, updated_fields)
        save_integration(provider_key, updated)

        log_activity("integration.token_refreshed", provider_key, %{}, "auto", nil)

        {:ok, new_token}
      end

    case result do
      {:ok, _token} ->
        maybe_record_recovery(uuid)
        result

      {:error, reason} ->
        record_refresh_failure(uuid, reason)
        result
    end
  end

  @doc """
  Disconnect a connection (remove tokens, keep setup credentials).

  For OAuth: removes access_token, refresh_token, keeps client_id/client_secret.
  For API key/bot token: removes the key entirely.

  No-op when the uuid doesn't resolve (already gone).
  """
  @spec disconnect(String.t(), String.t() | nil) :: :ok
  def disconnect(uuid, actor_uuid \\ nil) when is_binary(uuid) do
    case resolve_uuid(uuid) do
      {:ok, %{provider_key: provider_key, data: data}} ->
        auth_type = data["auth_type"]

        cleaned =
          case auth_type do
            "oauth2" ->
              data
              |> Map.take(["provider", "auth_type", "name", "client_id", "client_secret"])
              |> Map.put("status", "disconnected")

            _ ->
              data
              |> Map.take(["provider", "auth_type", "name"])
              |> Map.put("status", "disconnected")
          end

        save_integration(provider_key, cleaned)
        Events.broadcast_disconnected(provider_key)
        log_activity("integration.disconnected", provider_key, %{}, "manual", actor_uuid)
        :ok

      {:error, _} ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP helper with auto-refresh
  # ---------------------------------------------------------------------------

  @doc """
  Make an authenticated HTTP request with automatic token refresh on 401.

  For OAuth providers: adds Bearer token, retries with refreshed token on 401.
  For API key providers: adds Bearer token from the api_key.
  For bot token providers: returns credentials for the caller to use directly.

  `opts` are passed through to `Req.request/1`.
  """
  @spec authenticated_request(String.t(), atom(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def authenticated_request(uuid, method, url, opts \\ []) when is_binary(uuid) do
    with {:ok, data} <- get_credentials(uuid) do
      token = resolve_bearer_token(data)
      opts = put_auth_header(opts, token)

      case do_request(method, url, opts) do
        {:ok, %{status: 401}} = _unauthorized ->
          retry_with_refreshed_token(uuid, data, method, url, opts)

        other ->
          other
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Listing
  # ---------------------------------------------------------------------------

  @doc """
  List all configured integrations (those that have saved data).
  """
  @spec list_integrations() :: [map()]
  def list_integrations do
    provider_keys = Providers.all() |> Enum.map(& &1.key)

    load_all_connections(provider_keys)
    |> Enum.flat_map(fn {_provider, connections} ->
      Enum.map(connections, fn %{data: data} -> data end)
    end)
  end

  @doc """
  List all known providers.
  """
  @spec list_providers() :: [map()]
  def list_providers do
    Providers.all()
  end

  @doc """
  Returns the settings key for a provider connection.

  Accepts `"google"` (returns default connection key) or
  `"google:personal"` (returns named connection key).

  ## Examples

      iex> PhoenixKit.Integrations.settings_key("google")
      "integration:google:default"

      iex> PhoenixKit.Integrations.settings_key("google:personal")
      "integration:google:personal"
  """
  @spec settings_key(String.t()) :: String.t()
  def settings_key(provider_key) do
    {provider, name} = parse_provider_name(provider_key)
    "integration:#{provider}:#{name}"
  end

  @doc """
  Lists all connections for a provider.

  Returns a list of `%{uuid: uuid, name: name, data: data}` maps, with "default" first.
  The `uuid` is the stable identifier for the settings row.
  """
  @spec list_connections(String.t()) :: [%{uuid: String.t(), name: String.t(), data: map()}]
  def list_connections(provider_key) do
    prefix = "integration:#{provider_key}:"

    connections =
      Settings.get_json_settings_by_prefix_with_uuid(prefix)
      |> Enum.map(fn {uuid, key, data} ->
        name = key |> String.replace_prefix(prefix, "")
        %{uuid: uuid, name: name, data: Encryption.decrypt_fields(data)}
      end)

    # Also check for old non-named key (e.g., "integration:google" without ":default")
    # and include it as "default" if no default connection exists yet
    has_default = Enum.any?(connections, fn %{name: name} -> name == "default" end)

    connections =
      if has_default do
        connections
      else
        old_key = "integration:#{provider_key}"

        case Queries.get_setting_by_key(old_key) do
          %{uuid: uuid, value_json: data} when is_map(data) and map_size(data) > 0 ->
            [%{uuid: uuid, name: "default", data: Encryption.decrypt_fields(data)} | connections]

          _ ->
            connections
        end
      end

    Enum.sort_by(connections, fn %{name: name} -> if name == "default", do: "0", else: name end)
  end

  @doc """
  Loads all connections for multiple providers in a single database query.

  More efficient than calling `list_connections/1` in a loop.
  Returns a map of `provider_key => [%{uuid, name, data}]`.
  """
  @spec load_all_connections([String.t()]) :: %{
          String.t() => [%{uuid: String.t(), name: String.t(), data: map()}]
        }
  def load_all_connections(provider_keys) when is_list(provider_keys) do
    prefixes = Enum.map(provider_keys, &"integration:#{&1}:")

    # Single query for all providers
    all_settings = Settings.get_json_settings_by_prefixes_with_uuid(prefixes)

    # Group by provider
    grouped =
      Enum.reduce(all_settings, %{}, fn {uuid, key, data}, acc ->
        # key is like "integration:google:default" — extract provider and name
        case String.split(key, ":", parts: 3) do
          ["integration", provider, name] ->
            conn = %{uuid: uuid, name: name, data: Encryption.decrypt_fields(data)}
            Map.update(acc, provider, [conn], &[conn | &1])

          _ ->
            acc
        end
      end)

    # Sort each provider's connections (default first) and fill missing providers
    Map.new(provider_keys, fn pk ->
      connections =
        Map.get(grouped, pk, [])
        |> Enum.sort_by(fn %{name: name} -> if name == "default", do: "0", else: name end)

      {pk, connections}
    end)
  end

  @doc """
  Adds a new named connection for a provider.

  This is the row-birth path — the only place a new
  `integration:{provider}:{name}` storage key is constructed. Every
  other public API takes the row's uuid; callers can find it via the
  returned `:uuid` or by listing the provider's connections.

  The name can be any string alphanumeric with hyphens / underscores
  (e.g., "company-drive"), starting with an alphanumeric character.

  Returns `{:ok, %{uuid: uuid, data: data}}` on success.
  """
  @spec add_connection(String.t(), String.t(), String.t() | nil) ::
          {:ok, %{uuid: String.t(), data: map()}}
          | {:error, :empty_name | :invalid_name | :already_exists | term()}
  @name_pattern ~r/^[a-zA-Z0-9][a-zA-Z0-9\-_]*$/

  def add_connection(provider_key, name, actor_uuid \\ nil)
      when is_binary(provider_key) and is_binary(name) do
    name = String.trim(name)
    storage_key = "#{provider_key}:#{name}"

    cond do
      name == "" ->
        {:error, :empty_name}

      not Regex.match?(@name_pattern, name) ->
        {:error, :invalid_name}

      Settings.get_json_setting(settings_key(storage_key), nil) != nil ->
        {:error, :already_exists}

      true ->
        data = %{
          "provider" => provider_key,
          "name" => name,
          "auth_type" => provider_auth_type(provider_key),
          "status" => "disconnected"
        }

        with {:ok, saved} <- save_integration(storage_key, data),
             %{uuid: uuid} <- Queries.get_setting_by_key(settings_key(storage_key)) do
          Events.broadcast_connection_added(provider_key, name)

          log_activity(
            "integration.connection_added",
            provider_key,
            %{"name" => name},
            "manual",
            actor_uuid
          )

          {:ok, %{uuid: uuid, data: saved}}
        end
    end
  end

  @doc """
  Removes a connection by uuid.

  Names are pure user-chosen labels — no privileged values. The user is
  free to delete any connection; consumer modules that referenced the
  deleted integration row will surface a `:not_configured` (or similar)
  error on next use, which is the correct loud failure.
  """
  @spec remove_connection(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def remove_connection(uuid, actor_uuid \\ nil) when is_binary(uuid) do
    case resolve_uuid(uuid) do
      {:ok, %{provider_key: provider_key, setting: setting}} ->
        {provider, name} = parse_provider_name(provider_key)

        case Settings.delete_setting(setting.key) do
          {:ok, _} ->
            Events.broadcast_connection_removed(provider, name)

            log_activity(
              "integration.connection_removed",
              provider_key,
              %{"name" => name},
              "manual",
              actor_uuid
            )

            :ok

          {:error, :not_found} ->
            :ok

          error ->
            error
        end

      {:error, _} ->
        :ok
    end
  end

  @doc """
  Renames a connection identified by uuid.

  Updates the row's `key` column in place (preserving the uuid) and
  rewrites the JSONB `name` field. Consumers that pinned to the uuid
  keep working across the rename — that's the whole point of uuid-based
  references. Names are pure user-chosen labels; any name (including
  the literal string `"default"`) is valid.

  No-ops when `new_name` matches the current name. Refuses if the new
  name already exists for this provider, or if it doesn't match the
  connection-name pattern.

  Returns `{:ok, new_data}` on success, with the same JSONB body as
  before but `"name"` rewritten.
  """
  @spec rename_connection(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()}
          | {:error, :empty_name | :invalid_name | :already_exists | :not_configured | term()}
  def rename_connection(uuid, new_name, actor_uuid \\ nil)
      when is_binary(uuid) and is_binary(new_name) do
    new_name = String.trim(new_name)

    with {:ok, %{provider_key: provider_key, setting: setting, data: data}} <- resolve_uuid(uuid) do
      {provider, old_name} = parse_provider_name(provider_key)

      cond do
        new_name == old_name ->
          {:ok, data}

        new_name == "" ->
          {:error, :empty_name}

        not Regex.match?(@name_pattern, new_name) ->
          {:error, :invalid_name}

        Settings.get_json_setting(settings_key("#{provider}:#{new_name}"), nil) != nil ->
          {:error, :already_exists}

        true ->
          do_rename_connection(setting, provider, old_name, new_name, actor_uuid)
      end
    end
  end

  defp do_rename_connection(setting, provider, old_name, new_name, actor_uuid) do
    new_key = "integration:#{provider}:#{new_name}"
    new_data = Map.put(setting.value_json || %{}, "name", new_name)

    case rename_setting_row(setting, new_key, new_data) do
      {:ok, _updated} ->
        Events.broadcast_connection_renamed(provider, old_name, new_name)

        log_activity(
          "integration.connection_renamed",
          "#{provider}:#{new_name}",
          %{"old_name" => old_name, "new_name" => new_name},
          "manual",
          actor_uuid
        )

        {:ok, Encryption.decrypt_fields(new_data)}

      error ->
        error
    end
  end

  # In-place key + value rewrite via Ecto changeset; preserves the row
  # uuid (which is the stable reference consumers store on their own
  # records). Goes through `Repo.update` so the same encryption /
  # cache-invalidation hooks fire as for `update_setting`.
  defp rename_setting_row(setting, new_key, new_data) do
    encrypted_data = Encryption.encrypt_fields(new_data)

    setting
    |> Setting.changeset(%{
      key: new_key,
      value_json: encrypted_data
    })
    |> PhoenixKit.RepoHelper.repo().update()
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validate that a provider's credentials are working.

  For OAuth: calls the provider's userinfo endpoint.
  For API key / bot token: calls the provider's validation endpoint if defined.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_connection(String.t(), String.t() | nil) :: :ok | {:error, String.t()}
  def validate_connection(uuid, actor_uuid \\ nil) when is_binary(uuid) do
    {result, log_provider_key} =
      case resolve_uuid(uuid) do
        {:ok, %{provider_key: provider_key, data: data}} ->
          {base_provider, _name} = parse_provider_name(provider_key)
          provider = Providers.get(base_provider)

          inner =
            cond do
              is_nil(provider) -> {:error, gettext("Unknown provider")}
              not has_credentials?(data) -> {:error, gettext("Not configured")}
              true -> do_validate(provider, data)
            end

          {inner, provider_key}

        {:error, _} ->
          {{:error, gettext("Not configured")}, uuid}
      end

    case result do
      :ok ->
        log_activity(
          "integration.validated",
          log_provider_key,
          %{"result" => "ok"},
          "manual",
          actor_uuid
        )

      {:error, reason} ->
        log_activity(
          "integration.validated",
          log_provider_key,
          %{"result" => "error", "reason" => reason},
          "manual",
          actor_uuid
        )
    end

    result
  rescue
    e ->
      Logger.error(
        "[Integrations] validate_connection crashed for #{uuid}: #{Exception.message(e)}"
      )

      {:error, gettext("Validation failed unexpectedly")}
  end

  @doc """
  Probe a provider's API with in-memory credentials, without
  persisting anything. Used by the integration form to let
  operators test what they typed before committing — same HTTP
  validation as `validate_connection/2`, but no storage row, no
  `last_validated_at` stamp, no PubSub broadcast.

  `attrs` is the same shape `save_setup/3` accepts (e.g.
  `%{"api_key" => "..."}` for api_key providers,
  `%{"client_id" => "...", "client_secret" => "..."}` for OAuth).

  OAuth providers without a saved `access_token` will return
  `{:error, "No access token"}` — pre-save validation is most
  useful for api_key / bot_token providers where the secret the
  user just typed IS the credential.
  """
  @spec validate_credentials(String.t(), map()) :: :ok | {:error, String.t()}
  def validate_credentials(provider_key, attrs)
      when is_binary(provider_key) and is_map(attrs) do
    case Providers.get(provider_key) do
      nil -> {:error, gettext("Unknown provider")}
      provider -> do_validate(provider, attrs)
    end
  rescue
    e ->
      Logger.error(
        "[Integrations] validate_credentials crashed for #{provider_key}: #{Exception.message(e)}"
      )

      {:error, gettext("Validation failed unexpectedly")}
  end

  defp do_validate(%{auth_type: :oauth2} = provider, data) do
    token = data["access_token"]
    config = provider.oauth_config || %{}
    userinfo_url = config[:userinfo_url] || config["userinfo_url"]

    cond do
      not (is_binary(token) and token != "") -> {:error, gettext("No access token")}
      is_nil(userinfo_url) -> :ok
      true -> check_http(userinfo_url, [{"authorization", "Bearer #{token}"}])
    end
  end

  defp do_validate(%{auth_type: auth_type} = provider, data)
       when auth_type in [:api_key, :bot_token] do
    token = data["api_key"] || data["bot_token"] || ""

    cond do
      token == "" ->
        {:error, gettext("No credentials configured")}

      Map.has_key?(provider, :validation) and provider.validation != nil ->
        v = provider.validation
        headers = [{v.auth_header, "#{v.auth_prefix}#{token}"}]
        check_http(v.url, headers)

      true ->
        :ok
    end
  end

  defp do_validate(_, _data), do: :ok

  defp check_http(url, headers) do
    case Req.get(url, headers: headers, receive_timeout: @http_timeout) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 401}} -> {:error, gettext("Invalid credentials")}
      {:ok, %{status: 403}} -> {:error, gettext("Access denied")}
      {:ok, %{status: status}} -> {:error, gettext("Service error %{status}", status: status)}
      {:error, _reason} -> {:error, gettext("Could not reach the service")}
    end
  end

  @doc """
  Persist the outcome of a connection check (manual or automatic) onto the
  integration record and broadcast a PubSub event when status changes.

  `last_validated_at` is always rewritten — it is the canonical
  "moment of the last validation attempt" timestamp, and a manual
  Test-Connection click that returns the same result must still
  advance the field (otherwise the form's "Last tested N ago" reading
  goes stale). Status and `validation_status` are merged in
  unconditionally too — usually the same value as before, so it's a
  no-op write at the JSONB level. The PubSub broadcast is gated on an
  actual state change so high-frequency automatic paths (e.g. token
  refresh failing on every API call) don't spam listing-LV reloads.
  """
  @spec record_validation(String.t(), :ok | {:error, term()}) :: :ok
  def record_validation(uuid, result) when is_binary(uuid) do
    {new_status, validation_text} = validation_fields(result)

    case resolve_uuid(uuid) do
      {:ok, %{provider_key: provider_key, data: data}} ->
        status_changed =
          data["status"] != new_status or data["validation_status"] != validation_text

        now_iso = DateTime.utc_now() |> DateTime.to_iso8601()

        base_update = %{
          "status" => new_status,
          "last_validated_at" => now_iso,
          "validation_status" => validation_text
        }

        # `connected_at` tracks the LAST successful connection — it's
        # the timestamp the form's "Connected N ago" line reads from,
        # so the user expects it to bump on every successful re-test
        # (a stuck "Connected 35 minutes ago" after a fresh `:ok`
        # reads as "didn't update even though it connected"). This
        # also matches the OAuth `exchange_code/4` path, which
        # always overwrites `connected_at` on a successful token
        # exchange — keeping the two paths consistent.
        update =
          if result == :ok do
            Map.put(base_update, "connected_at", now_iso)
          else
            base_update
          end

        updated = Map.merge(data, update)

        case save_integration(provider_key, updated) do
          {:ok, _} ->
            if status_changed, do: Events.broadcast_validated(provider_key, result)
            :ok

          _ ->
            :ok
        end

      {:error, _} ->
        Logger.debug("[Integrations] record_validation skipped — uuid #{inspect(uuid)} not found")

        :ok
    end
  end

  defp validation_fields(:ok), do: {"connected", "ok"}

  defp validation_fields({:error, reason}),
    do: {"error", "error: #{format_validation_reason(reason)}"}

  defp format_validation_reason(reason) when is_binary(reason), do: reason

  defp format_validation_reason({:refresh_failed, status}),
    do: "Token refresh failed (HTTP #{status})"

  defp format_validation_reason(:token_refresh_failed), do: "Token refresh failed"
  defp format_validation_reason(reason), do: inspect(reason)

  defp record_refresh_failure(uuid, reason) do
    reason_text = format_validation_reason(reason)
    record_validation(uuid, {:error, reason_text})

    case resolve_uuid(uuid) do
      {:ok, %{provider_key: provider_key}} ->
        log_activity(
          "integration.token_refresh_failed",
          provider_key,
          %{"reason" => reason_text},
          "auto",
          nil
        )

      _ ->
        :ok
    end
  end

  defp maybe_record_recovery(uuid) do
    case resolve_uuid(uuid) do
      {:ok, %{provider_key: provider_key, data: %{"status" => "error"}}} ->
        record_validation(uuid, :ok)
        log_activity("integration.auto_recovered", provider_key, %{}, "auto", nil)

      _ ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  defp uuid?(str), do: is_binary(str) and Regex.match?(@uuid_pattern, str)

  # Resolve a settings-row uuid to its storage info — single source of
  # truth for the uuid-strict public API. Sources `provider_key`
  # (`"provider:name"`) directly from the row's `key` column so a
  # corrupted JSONB `provider`/`name` field cannot leak into downstream
  # writes. Returns the live `Setting` struct too so callers like
  # `rename_connection/3` can update in place via changeset.
  defp resolve_uuid(uuid) when is_binary(uuid) and uuid != "" do
    case Queries.get_setting_by_uuid(uuid) do
      %Setting{key: "integration:" <> provider_key} = setting ->
        decrypted = Encryption.decrypt_fields(setting.value_json || %{})

        {:ok,
         %{
           uuid: uuid,
           provider_key: provider_key,
           setting: setting,
           data: decrypted
         }}

      _ ->
        {:error, :not_configured}
    end
  end

  defp resolve_uuid(_), do: {:error, :invalid_uuid}

  defp parse_provider_name(key) do
    case String.split(key, ":", parts: 2) do
      [provider, name] when name != "" -> {provider, name}
      [provider] -> {provider, "default"}
    end
  end

  defp provider_auth_type(provider_key) do
    case Providers.get(provider_key) do
      %{auth_type: auth_type} -> Atom.to_string(auth_type)
      nil -> nil
    end
  end

  defp save_integration(provider_key, data) do
    encrypted_data = Encryption.encrypt_fields(data)

    case Settings.update_json_setting_with_module(
           settings_key(provider_key),
           encrypted_data,
           @settings_module
         ) do
      {:ok, _setting} ->
        {:ok, data}

      {:error, changeset} = error ->
        Logger.error(
          "[Integrations] Failed to save integration for #{provider_key}: #{inspect(changeset)}"
        )

        error
    end
  end

  defp fetch_provider(provider_key) do
    case Providers.get(provider_key) do
      nil -> {:error, :unknown_provider}
      provider -> {:ok, provider}
    end
  end

  defp fetch_userinfo_safe(provider, access_token) do
    if provider.oauth_config do
      case OAuth.fetch_userinfo(provider.oauth_config, access_token) do
        {:ok, info} -> info
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp maybe_set_userinfo(data, userinfo) do
    metadata = Map.get(data, "metadata", %{})

    updated_metadata =
      metadata
      |> maybe_put("connected_email", userinfo["email"])
      |> maybe_put("name", userinfo["name"])
      |> maybe_put("picture", userinfo["picture"])

    data
    |> Map.put("metadata", updated_metadata)
    |> maybe_put("external_account_id", userinfo["email"])
    |> maybe_put("external_account_name", userinfo["name"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_set_status(data, nil), do: Map.put_new(data, "status", "disconnected")

  defp maybe_set_status(data, provider) do
    # If already validated as "connected" or "error", keep the status
    # Only set status on initial save
    if data["status"] in ["connected", "error"] do
      data
    else
      has_creds =
        case provider.auth_type do
          :oauth2 -> has_token?(data)
          :api_key -> present?(data["api_key"])
          :bot_token -> present?(data["bot_token"])
          :key_secret -> present?(data["access_key"])
          :credentials -> has_custom_creds?(data)
        end

      # Saved-but-not-validated. Setting "connected" here was optimistic —
      # nothing has actually been tested. Callers that want a real
      # `connected` status should follow up with `validate_connection/2`
      # and `record_validation/2`. The form LV does this automatically on
      # the save_setup / create_connection flow.
      if has_creds do
        Map.put(data, "status", "configured")
      else
        Map.put(data, "status", "disconnected")
      end
    end
  end

  defp maybe_set_connected_at(data) do
    if data["status"] == "connected" and is_nil(data["connected_at"]) do
      Map.put(data, "connected_at", DateTime.utc_now() |> DateTime.to_iso8601())
    else
      data
    end
  end

  defp has_credentials?(%{"status" => status}) when status in ["connected", "configured"],
    do: true

  defp has_credentials?(data),
    do:
      present?(data["access_token"]) or present?(data["api_key"]) or present?(data["bot_token"]) or
        present?(data["access_key"]) or has_custom_creds?(data)

  defp has_custom_creds?(%{"credentials" => creds}) when is_map(creds) and map_size(creds) > 0,
    do: true

  defp has_custom_creds?(_), do: false

  defp present?(val), do: is_binary(val) and val != ""

  defp has_token?(data), do: present?(data["access_token"])

  defp resolve_bearer_token(data) do
    data["access_token"] || data["api_key"] || data["bot_token"] || ""
  end

  defp put_auth_header(opts, token) do
    headers =
      opts
      |> Keyword.get(:headers, [])
      |> Enum.reject(fn {k, _} -> String.downcase(to_string(k)) == "authorization" end)

    headers = [{"authorization", "Bearer #{token}"} | headers]
    Keyword.put(opts, :headers, headers)
  end

  defp do_request(method, url, opts) do
    Req.request([method: method, url: url] ++ opts)
  end

  defp retry_with_refreshed_token(uuid, data, method, url, opts) do
    if data["auth_type"] == "oauth2" and is_binary(data["refresh_token"]) and
         data["refresh_token"] != "" do
      case refresh_access_token(uuid) do
        {:ok, new_token} ->
          opts = put_auth_header(opts, new_token)
          do_request(method, url, opts)

        {:error, reason} ->
          Logger.warning("[Integrations] Token refresh failed for #{uuid}: #{inspect(reason)}")

          {:error, :token_refresh_failed}
      end
    else
      Logger.warning("[Integrations] 401 for #{uuid} but no refresh_token available")
      {:error, :unauthorized}
    end
  end

  # ---------------------------------------------------------------------------
  # Activity logging
  # ---------------------------------------------------------------------------

  defp log_activity(action, provider_key, metadata, mode, actor_uuid) do
    {provider, name} = parse_provider_name(provider_key)

    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: action,
        module: "integrations",
        mode: mode,
        actor_uuid: actor_uuid,
        resource_type: "integration",
        metadata:
          Map.merge(metadata, %{
            "provider" => provider,
            "connection" => name,
            "actor_role" => "admin"
          })
      })
    end
  rescue
    e ->
      Logger.warning("[Integrations] Failed to log activity #{action}: #{Exception.message(e)}")
  end

  # ---------------------------------------------------------------------------
  # Legacy migration (deprecated entry point)
  # ---------------------------------------------------------------------------

  @doc """
  Deprecated. Use `PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0`
  from your host app's `Application.start/2` instead.

  Each module that has legacy data now implements its own
  `migrate_legacy/0` callback. The orchestrator walks every registered
  module and runs them all — same single entry point as before, but
  modules own their own data shape.

  Calling this delegates to the orchestrator for backwards compat.
  Returns `:ok` regardless of per-module outcome (matches the previous
  semantics of "best-effort, never crash boot").
  """
  @deprecated "Use PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0 instead"
  @spec run_legacy_migrations() :: :ok
  def run_legacy_migrations do
    _ = PhoenixKit.ModuleRegistry.run_all_legacy_migrations()
    :ok
  end
end
