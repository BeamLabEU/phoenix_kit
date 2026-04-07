defmodule PhoenixKit.Integrations do
  @moduledoc """
  Centralized management of external service integrations.

  Stores credentials (OAuth tokens, API keys, bot tokens, etc.) using the
  existing `PhoenixKit.Settings` system with `value_json` JSONB storage.
  Each integration is a JSON blob under a key like `"integration:google"`.

  ## Auth types supported

  - `:oauth2` — Google, Microsoft, Slack, etc. (client_id/secret + access/refresh tokens)
  - `:api_key` — OpenRouter, Stripe, SendGrid, etc. (single API key)
  - `:key_secret` — AWS, Twilio, etc. (access key + secret key)
  - `:bot_token` — Telegram, Discord, etc. (single bot token)
  - `:credentials` — SMTP, databases, etc. (freeform credential map)

  ## Usage

      # Check if a provider is connected
      PhoenixKit.Integrations.connected?("google")

      # Get credentials for API calls
      {:ok, creds} = PhoenixKit.Integrations.get_credentials("google")
      # => %{"access_token" => "ya29...", "token_type" => "Bearer", ...}

      # Make an authenticated request with auto-refresh on 401
      {:ok, response} = PhoenixKit.Integrations.authenticated_request("google", :get, url)
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.Events
  alias PhoenixKit.Integrations.OAuth
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Queries

  @settings_module "integrations"
  @http_timeout 15_000

  # ---------------------------------------------------------------------------
  # Reading credentials
  # ---------------------------------------------------------------------------

  @doc """
  Get the full integration data for a provider.

  Returns the entire JSON blob including credentials, status, and metadata.
  Automatically migrates legacy settings keys (e.g., `"document_creator_google_oauth"`)
  on first access.
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
      nil -> {:error, :not_configured}
      %{} = data -> {:ok, Encryption.decrypt_fields(data)}
    end
  end

  def get_integration(_), do: {:error, :invalid_provider_key}

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
        if is_uuid do
          # UUID was provided but not found — the integration was deleted
          {:error, :deleted}
        else
          # If checking a bare provider key, try to find any connected connection
          {_provider, name} = parse_provider_name(provider_key)

          if name == "default" do
            find_first_connected(provider_key)
          else
            {:error, :not_configured}
          end
        end
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
  Save setup credentials for a provider.

  For OAuth providers, this saves client_id/client_secret.
  For API key providers, this saves the api_key.
  For bot token providers, this saves the bot_token.

  Merges with existing data to preserve any previously obtained tokens.
  Sets status to "disconnected" if no runtime credentials exist yet.
  """
  @spec save_setup(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def save_setup(provider_key, attrs) when is_binary(provider_key) and is_map(attrs) do
    provider = Providers.get(provider_key)
    existing = Settings.get_json_setting(settings_key(provider_key), %{})

    data =
      existing
      |> Map.merge(attrs)
      |> Map.put("provider", provider_key)
      |> Map.put("auth_type", provider && Atom.to_string(provider.auth_type))
      |> maybe_set_status(provider)
      |> maybe_set_connected_at()

    case save_integration(provider_key, data) do
      {:ok, saved} = result ->
        Events.broadcast_setup_saved(provider_key, saved)
        result

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # OAuth flow
  # ---------------------------------------------------------------------------

  @doc """
  Build the OAuth authorization URL for a provider.

  Accepts an optional `state` parameter for CSRF protection. Use
  `PhoenixKit.Integrations.OAuth.generate_state/0` to generate one,
  store it in the session or socket assigns, and verify it when the
  callback arrives.
  """
  @spec authorization_url(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def authorization_url(provider_key, redirect_uri, extra_scopes \\ nil, state \\ nil) do
    with {:ok, provider} <- fetch_provider(provider_key),
         {:ok, data} <- get_integration(provider_key) do
      OAuth.authorization_url(provider.oauth_config, data, redirect_uri, extra_scopes, state)
    end
  end

  @doc """
  Exchange an OAuth authorization code for tokens and save them.
  """
  @spec exchange_code(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def exchange_code(provider_key, code, redirect_uri) do
    with {:ok, provider} <- fetch_provider(provider_key),
         {:ok, data} <- get_integration(provider_key),
         {:ok, token_data} <- OAuth.exchange_code(provider.oauth_config, data, code, redirect_uri) do
      # Fetch userinfo if the provider supports it
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
          result

        error ->
          error
      end
    end
  end

  @doc """
  Refresh an expired OAuth access token and save the new one.
  """
  @spec refresh_access_token(String.t()) :: {:ok, String.t()} | {:error, term()}
  def refresh_access_token(provider_key) do
    with {:ok, data} <- get_integration(provider_key),
         {:ok, provider_lookup_key} <- resolve_provider_lookup_key(provider_key, data),
         {:ok, provider} <- fetch_provider(provider_lookup_key),
         {:ok, new_token, updated_fields} <-
           OAuth.refresh_access_token(provider.oauth_config, data) do
      updated = Map.merge(data, updated_fields)
      save_integration(resolve_storage_key(provider_key, data), updated)
      {:ok, new_token}
    end
  end

  @doc """
  Disconnect an integration (remove tokens, keep setup credentials).

  For OAuth: removes access_token, refresh_token, keeps client_id/client_secret.
  For API key/bot token: removes the key entirely.
  """
  @spec disconnect(String.t()) :: :ok
  def disconnect(provider_key) when is_binary(provider_key) do
    case Settings.get_json_setting(settings_key(provider_key), nil) do
      nil ->
        :ok

      data ->
        auth_type = data["auth_type"]

        cleaned =
          case auth_type do
            "oauth2" ->
              data
              |> Map.take(["provider", "auth_type", "client_id", "client_secret"])
              |> Map.put("status", "disconnected")

            "key_secret" ->
              data
              |> Map.take(["provider", "auth_type"])
              |> Map.put("status", "disconnected")

            _ ->
              data
              |> Map.take(["provider", "auth_type"])
              |> Map.put("status", "disconnected")
          end

        save_integration(provider_key, cleaned)
        Events.broadcast_disconnected(provider_key)
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
  def authenticated_request(provider_key, method, url, opts \\ []) do
    with {:ok, data} <- get_credentials(provider_key) do
      token = resolve_bearer_token(data)
      opts = put_auth_header(opts, token)

      case do_request(method, url, opts) do
        {:ok, %{status: 401}} = _unauthorized ->
          retry_with_refreshed_token(provider_key, data, method, url, opts)

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

  The name can be any string alphanumeric with hyphens (e.g., "company-drive").
  """
  @spec add_connection(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @name_pattern ~r/^[a-zA-Z0-9][a-zA-Z0-9\-_]*$/

  def add_connection(provider_key, name) when is_binary(provider_key) and is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, :empty_name}

      not Regex.match?(@name_pattern, name) ->
        {:error, :invalid_name}

      Settings.get_json_setting(settings_key("#{provider_key}:#{name}"), nil) != nil ->
        {:error, :already_exists}

      true ->
        data = %{
          "provider" => provider_key,
          "name" => name,
          "auth_type" => provider_auth_type(provider_key),
          "status" => "disconnected"
        }

        save_integration("#{provider_key}:#{name}", data)
        |> tap(fn
          {:ok, _} -> Events.broadcast_connection_added(provider_key, name)
          _ -> :ok
        end)
    end
  end

  @doc """
  Removes a named connection. The "default" connection cannot be removed.
  """
  @spec remove_connection(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_connection(_provider_key, "default"), do: {:error, :cannot_remove_default}

  def remove_connection(provider_key, name) when is_binary(provider_key) and is_binary(name) do
    key = settings_key("#{provider_key}:#{name}")

    case Settings.delete_setting(key) do
      {:ok, _} ->
        Events.broadcast_connection_removed(provider_key, name)
        :ok

      {:error, :not_found} ->
        :ok

      error ->
        error
    end
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
  @spec validate_connection(String.t()) :: :ok | {:error, String.t()}
  def validate_connection(provider_key) do
    with {:ok, data} <- get_credentials(provider_key),
         provider when not is_nil(provider) <- Providers.get(provider_key) do
      do_validate(provider, data)
    else
      {:error, _} -> {:error, gettext("Not configured")}
      nil -> {:error, gettext("Unknown provider")}
    end
  rescue
    e ->
      Logger.error(
        "[Integrations] validate_connection crashed for #{provider_key}: #{Exception.message(e)}"
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

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  defp uuid?(str), do: is_binary(str) and Regex.match?(@uuid_pattern, str)

  defp find_first_connected(provider_key) do
    list_connections(provider_key)
    |> Enum.find_value({:error, :not_configured}, fn %{data: data} ->
      if has_credentials?(data), do: {:ok, data}
    end)
  end

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

  defp resolve_provider_lookup_key(provider_key, data) do
    case data["provider"] do
      saved_provider when is_binary(saved_provider) and saved_provider != "" ->
        {:ok, saved_provider}

      _ ->
        if uuid?(provider_key), do: {:error, :unknown_provider}, else: {:ok, provider_key}
    end
  end

  defp resolve_storage_key(provider_key, data) do
    case data["provider"] do
      saved_provider when is_binary(saved_provider) and saved_provider != "" -> saved_provider
      _ -> provider_key
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

      cond do
        # OAuth with tokens is connected (verified by the OAuth flow itself)
        provider.auth_type == :oauth2 and has_creds -> Map.put(data, "status", "connected")
        # Other types with credentials are "configured" until validated
        has_creds -> Map.put(data, "status", "configured")
        # No credentials at all
        true -> Map.put(data, "status", "disconnected")
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

  defp retry_with_refreshed_token(provider_key, data, method, url, opts) do
    if data["auth_type"] == "oauth2" and is_binary(data["refresh_token"]) and
         data["refresh_token"] != "" do
      case refresh_access_token(provider_key) do
        {:ok, new_token} ->
          opts = put_auth_header(opts, new_token)
          do_request(method, url, opts)

        {:error, reason} ->
          Logger.warning(
            "[Integrations] Token refresh failed for #{provider_key}: #{inspect(reason)}"
          )

          {:error, :token_refresh_failed}
      end
    else
      Logger.warning("[Integrations] 401 for #{provider_key} but no refresh_token available")
      {:error, :unauthorized}
    end
  end

  # ---------------------------------------------------------------------------
  # Legacy migration
  # ---------------------------------------------------------------------------

  # Map of legacy settings keys to provider keys.
  @legacy_keys %{
    "google" => "document_creator_google_oauth"
  }

  @doc """
  Run one-time legacy migrations for all known providers.

  Call this at application boot (e.g., in `Application.start/2`) to migrate
  legacy settings keys to the new `integration:{provider}:{name}` format.
  Safe to call multiple times — skips providers that already have data.
  """
  @spec run_legacy_migrations() :: :ok
  def run_legacy_migrations do
    for {provider_key, _legacy_key} <- @legacy_keys do
      # Only migrate if no data exists under the new key
      case Settings.get_json_setting(settings_key(provider_key), nil) do
        nil -> maybe_migrate_legacy(provider_key)
        _ -> :skip
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("[Integrations] Legacy migrations failed: #{Exception.message(e)}")
      :ok
  end

  defp maybe_migrate_legacy(provider_key) do
    {base_provider, _name} = parse_provider_name(provider_key)

    # Check module-specific legacy key (e.g., "document_creator_google_oauth")
    module_legacy_key = Map.get(@legacy_keys, base_provider)

    # Also check old single-connection format (e.g., "integration:google")
    old_format_key = "integration:#{base_provider}"

    cond do
      # Try module-specific legacy key first
      module_legacy_key && has_legacy_data?(module_legacy_key) ->
        do_migrate_legacy(base_provider, Settings.get_json_setting(module_legacy_key, %{}))

      # Try old format without name
      has_legacy_data?(old_format_key) ->
        data = Settings.get_json_setting(old_format_key, %{})
        save_integration(provider_key, data)

      true ->
        :skip
    end
  rescue
    e ->
      Logger.warning(
        "[Integrations] Legacy migration failed for #{provider_key}: #{Exception.message(e)}"
      )

      :skip
  end

  defp has_legacy_data?(key) do
    case Settings.get_json_setting(key, nil) do
      data when is_map(data) and map_size(data) > 0 -> true
      _ -> false
    end
  end

  defp do_migrate_legacy("google", legacy_data) do
    data = %{
      "provider" => "google",
      "auth_type" => "oauth2",
      "client_id" => legacy_data["client_id"],
      "client_secret" => legacy_data["client_secret"],
      "access_token" => legacy_data["access_token"],
      "refresh_token" => legacy_data["refresh_token"],
      "token_type" => legacy_data["token_type"] || "Bearer",
      "token_obtained_at" => legacy_data["token_obtained_at"],
      "status" =>
        if(is_binary(legacy_data["access_token"]) and legacy_data["access_token"] != "",
          do: "connected",
          else: "disconnected"
        ),
      "external_account_id" => legacy_data["connected_email"],
      "metadata" => %{
        "connected_email" => legacy_data["connected_email"]
      }
    }

    # Compute expires_at from legacy expires_in if available
    data =
      with expires_in when is_integer(expires_in) <- legacy_data["expires_in"],
           obtained_at when is_binary(obtained_at) <- legacy_data["token_obtained_at"],
           {:ok, dt, _} <- DateTime.from_iso8601(obtained_at) do
        Map.put(
          data,
          "expires_at",
          dt |> DateTime.add(expires_in, :second) |> DateTime.to_iso8601()
        )
      else
        _ -> data
      end

    # Set connected_at
    data =
      if data["status"] == "connected" do
        Map.put(
          data,
          "connected_at",
          legacy_data["token_obtained_at"] || DateTime.utc_now() |> DateTime.to_iso8601()
        )
      else
        data
      end

    # Save the integration — if this fails, return :skip so caller gets :not_configured
    case save_integration("google", data) do
      {:ok, saved_data} ->
        # Best-effort: move folder config to its own key
        migrate_legacy_folders(legacy_data)

        Logger.info(
          "[Integrations] Migrated legacy 'document_creator_google_oauth' → 'integration:google'"
        )

        {:ok, saved_data}

      {:error, reason} ->
        Logger.warning("[Integrations] Legacy migration save failed: #{inspect(reason)}")
        :skip
    end
  end

  defp do_migrate_legacy(_provider_key, _legacy_data), do: :skip

  defp migrate_legacy_folders(legacy_data) do
    folder_fields = ~w(
      folder_path_templates folder_name_templates
      folder_path_documents folder_name_documents
      folder_path_deleted folder_name_deleted
      templates_folder_id documents_folder_id
      deleted_templates_folder_id deleted_documents_folder_id
    )

    folder_data = Map.take(legacy_data, folder_fields)

    if map_size(folder_data) > 0 do
      case Settings.update_json_setting_with_module(
             "document_creator_folders",
             folder_data,
             "document_creator"
           ) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Integrations] Legacy migration: failed to save folder config: #{inspect(reason)}"
          )
      end
    end
  end
end
