defmodule PhoenixKit.Integrations do
  @moduledoc """
  Centralized management of external service integrations.

  Stores credentials (OAuth tokens, API keys, bot tokens, etc.) using the
  existing `PhoenixKit.Settings` system with `value_json` JSONB storage.
  Each integration row's `key` column is just its UUID; the `module`
  column is stamped `"integrations"` and the JSONB body holds
  `{"provider", "name", "auth_type", "status", ...}`. There is no
  composite key shape — provider and name are pure JSONB.

  Connections are referenced by the storage row's UUID. Names are pure
  user-chosen labels with no system semantics — any string is allowed
  (including spaces and duplicates within a provider); consumer modules
  pin to UUIDs that survive renames.

  ## Auth types supported

  - `:oauth2` — Google, Microsoft, Slack, etc. (client_id/secret + access/refresh tokens)
  - `:api_key` — OpenRouter, Stripe, SendGrid, etc. (single API key)
  - `:key_secret` — AWS, Twilio, DataForSEO, etc. (a key or login + a secret)
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
    legacy `migrate_legacy/0` callbacks that walk pre-uuid data shapes.
    Since names are no longer unique, these now return first-match.

  The `key` column is the row's UUIDv7 — collisions are structurally
  impossible. JSONB `provider`/`name` are pure data; corruption there
  affects only this row's content, never routing.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.Events
  alias PhoenixKit.Integrations.OAuth
  alias PhoenixKit.Integrations.Probe
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Integrations.Validators
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Queries
  alias PhoenixKit.Settings.Setting

  @settings_module "integrations"
  @http_timeout 15_000

  @typedoc """
  Owner scope for a connection:

    * `:system` — no owner (website-wide)
    * `:any` — no filter (owner-agnostic reads: audit, consumer uuid pins)
    * `{type, id}` — a typed owner, `type` an atom (`:user`, `:dashboard`,
      `:team`, …) and `id` that entity's uuid

  Passed via the `:owner` option on scoped functions. Not hardcoded to `:user`,
  so new owner kinds (a shared dashboard, a team) need no schema change.
  """
  @type owner :: :system | :any | {atom(), String.t()}

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
    if uuid?(provider_key) do
      # Through resolve_uuid so only `module: "integrations"` rows qualify —
      # any JSONB settings row's uuid used to decrypt-as-integration.
      case resolve_uuid(provider_key, :any) do
        {:ok, %{data: data}} -> {:ok, data}
        _ -> {:error, :not_configured}
      end
    else
      # `"provider:name"` string lookup — first-match by name. Names
      # are no longer unique, so this returns the first row whose JSONB
      # name matches. Used by legacy `migrate_legacy/0` callbacks; new
      # callers should use uuid-based lookups.
      case find_uuid_by_provider_name(provider_key) do
        {:ok, uuid} ->
          case Settings.get_json_setting_by_uuid(uuid) do
            %{} = data -> {:ok, Encryption.decrypt_fields(data)}
            _ -> {:error, :not_configured}
          end

        _ ->
          {:error, :not_configured}
      end
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
  @spec get_integration_by_uuid(String.t(), owner()) ::
          {:ok, %{uuid: String.t(), provider: String.t(), name: String.t(), data: map()}}
          | {:error, :not_configured | :invalid_uuid}
  def get_integration_by_uuid(uuid, owner \\ :any)

  def get_integration_by_uuid(uuid, owner) when is_binary(uuid) and uuid != "" do
    # The storage row is identified solely by its uuid. Provider and name
    # both live in JSONB. `owner` scopes the read: consumers that pinned a
    # (system) uuid call this owner-agnostic (`:any`, the default), but the
    # edit-form load MUST pass an explicit owner (`:system` / `{:user, uuid}`)
    # so opening another owner's uuid can't surface decrypted credentials
    # (the IDOR the review flagged) — mismatch fails closed as :not_configured.
    case Queries.get_setting_by_uuid(uuid) do
      %{module: "integrations", value_json: data} when is_map(data) ->
        decrypted = Encryption.decrypt_fields(data)

        if owner_match?(decrypted, owner) do
          provider = Map.get(decrypted, "provider", "")
          name = Map.get(decrypted, "name", "")
          {:ok, %{uuid: uuid, provider: provider, name: name, data: decrypted}}
        else
          {:error, :not_configured}
        end

      _ ->
        {:error, :not_configured}
    end
  end

  def get_integration_by_uuid(_, _), do: {:error, :invalid_uuid}

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
  @spec find_uuid_by_provider_name(String.t() | {String.t(), String.t()}, keyword()) ::
          {:ok, String.t()} | {:error, :not_found | :invalid}
  def find_uuid_by_provider_name(input, opts \\ [])

  def find_uuid_by_provider_name({provider, name}, opts)
      when is_binary(provider) and is_binary(name) and provider != "" and name != "" do
    owner = Keyword.get(opts, :owner, :system)

    case Enum.find(list_connections(provider, owner: owner), &(&1.name == name)) do
      %{uuid: uuid} -> {:ok, uuid}
      _ -> {:error, :not_found}
    end
  end

  def find_uuid_by_provider_name(string, opts) when is_binary(string) and string != "" do
    owner = Keyword.get(opts, :owner, :system)

    case String.split(string, ":", parts: 2) do
      [provider, name] when provider != "" and name != "" ->
        find_uuid_by_provider_name({provider, name}, opts)

      [provider] when provider != "" ->
        # Bare provider — first connection of that provider (sorted by
        # name, lowercase). Defaults to the SYSTEM scope: a bare
        # `provider:name` legacy lookup meant "the system connection",
        # so it must never first-match a personal row.
        case list_connections(provider, owner: owner) do
          [%{uuid: uuid} | _] -> {:ok, uuid}
          _ -> {:error, :not_found}
        end

      _ ->
        {:error, :invalid}
    end
  end

  def find_uuid_by_provider_name(_, _), do: {:error, :invalid}

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
  @spec get_credentials(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_configured | :deleted}
  def get_credentials(provider_key, opts \\ [])

  def get_credentials(provider_key, opts) when is_binary(provider_key) and provider_key != "" do
    # `:owner` defaults to `:any` (owner-agnostic) for back-compat with
    # trusted consumers that pin a system uuid. A user-context caller
    # (e.g. a future notification channel resolving a user's own key)
    # passes `owner: {:user, uuid}` to verify ownership — mitigating
    # UUIDv7-enumeration of another user's credentials. A bare
    # `provider:name` lookup never uses `:any` (it meant "the system
    # connection" pre-feature) — it scopes to the user or to system.
    owner = Keyword.get(opts, :owner, :any)
    is_uuid = uuid?(provider_key)
    # Any TYPED owner scopes the bare `provider:name` lookup to itself; only
    # `:system`/`:any` fall back to the system scope.
    name_scope = if match?({t, _} when is_atom(t), owner), do: owner, else: :system

    data =
      if is_uuid do
        Settings.get_json_setting_by_uuid(provider_key)
      else
        case find_uuid_by_provider_name(provider_key, owner: name_scope) do
          {:ok, uuid} -> Settings.get_json_setting_by_uuid(uuid)
          _ -> nil
        end
      end

    case data do
      %{} = data when map_size(data) > 0 ->
        decrypted = Encryption.decrypt_fields(data)

        cond do
          not owner_match?(decrypted, owner) -> {:error, :deleted}
          has_credentials?(decrypted) -> {:ok, decrypted}
          true -> {:error, :not_configured}
        end

      _ ->
        # uuid lookup that missed → row was deleted; bare-provider /
        # provider:name lookup that missed → never configured.
        if is_uuid, do: {:error, :deleted}, else: {:error, :not_configured}
    end
  end

  def get_credentials(_, _), do: {:error, :not_configured}

  @doc """
  Check if an integration is connected and has valid credentials.

  Owner-scoped via `opts` (`:owner`, default `:any`) — same contract as
  `get_credentials/2`.
  """
  @spec connected?(String.t(), keyword()) :: boolean()
  def connected?(provider_key, opts \\ [])

  def connected?(provider_key, opts) when is_binary(provider_key) do
    case get_credentials(provider_key, opts) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def connected?(_, _), do: false

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
  @spec save_setup(String.t(), map(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, :not_configured | :invalid_uuid | term()}
  def save_setup(uuid, attrs, actor_uuid \\ nil, opts \\ [])
      when is_binary(uuid) and is_map(attrs) do
    owner = Keyword.get(opts, :owner, :system)
    # owner_type/owner_uuid are write-once (set at birth) — never let form attrs
    # overwrite/null it (would silently reassign or promote personal→system).
    attrs = Map.drop(attrs, ["owner_type", "owner_uuid"])

    with {:ok,
          %{
            provider: base_provider,
            name: name,
            setting: setting,
            data: existing,
            undecryptable_fields: undecryptable_fields
          }} <-
           resolve_uuid(uuid, owner) do
      provider = Providers.get(base_provider)

      data =
        existing
        |> Map.merge(attrs)
        |> Map.put("provider", base_provider)
        |> Map.put("name", name)
        |> Map.put("auth_type", provider && Atom.to_string(provider.auth_type))
        |> maybe_set_status(provider)
        |> maybe_set_connected_at()

      case save_integration(setting, data, undecryptable_fields) do
        {:ok, saved} = result ->
          Events.broadcast_setup_saved(base_provider, saved)

          log_activity(
            "integration.setup_saved",
            base_provider,
            name,
            %{"status" => saved["status"]},
            "manual",
            actor_uuid,
            uuid
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
    with {:ok, %{provider: base_provider, data: data}} <- resolve_uuid(uuid),
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
    with {:ok,
          %{
            provider: base_provider,
            name: name,
            setting: setting,
            data: data,
            undecryptable_fields: undecryptable_fields
          }} <-
           resolve_uuid(uuid),
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

      case save_integration(setting, updated, undecryptable_fields) do
        {:ok, saved} = result ->
          Events.broadcast_connected(base_provider, saved)

          log_activity(
            "integration.connected",
            base_provider,
            name,
            %{"account" => saved["external_account_id"]},
            "manual",
            actor_uuid,
            uuid
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
      with {:ok,
            %{
              provider: base_provider,
              name: name,
              setting: setting,
              data: data,
              undecryptable_fields: undecryptable_fields
            }} <-
             resolve_uuid(uuid),
           {:ok, provider} <- fetch_provider(base_provider),
           {:ok, new_token, updated_fields} <-
             OAuth.refresh_access_token(provider.oauth_config, data),
           # A failed persist must be an error: for IdPs that rotate the
           # refresh token, returning `{:ok, token}` here would leave the
           # now-burned old refresh token in the row.
           {:ok, _} <-
             save_integration(setting, Map.merge(data, updated_fields), undecryptable_fields) do
        log_activity("integration.token_refreshed", base_provider, name, %{}, "auto", nil, uuid)

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
  @spec disconnect(String.t(), String.t() | nil, keyword()) :: :ok
  def disconnect(uuid, actor_uuid \\ nil, opts \\ []) when is_binary(uuid) do
    case resolve_uuid(uuid, Keyword.get(opts, :owner, :system)) do
      {:ok, %{provider: base_provider, name: name, setting: setting, data: data}} ->
        auth_type = data["auth_type"]

        # `owner_type`/`owner_uuid` MUST be in the retained set — omitting them
        # (the prior bug) silently converted an owned connection into a system
        # one (and would now reclassify a dashboard/team owner as a user).
        cleaned =
          case auth_type do
            "oauth2" ->
              data
              |> Map.take([
                "provider",
                "auth_type",
                "name",
                "owner_type",
                "owner_uuid",
                "client_id",
                "client_secret"
              ])
              |> Map.put("status", "disconnected")

            _ ->
              data
              |> Map.take(["provider", "auth_type", "name", "owner_type", "owner_uuid"])
              |> Map.put("status", "disconnected")
          end

        save_integration(setting, cleaned)
        Events.broadcast_disconnected(base_provider, owner_of(data))

        log_activity(
          "integration.disconnected",
          base_provider,
          name,
          %{},
          "manual",
          actor_uuid,
          uuid
        )

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

  ## Security — `url` must come from a trusted source

  The integration's Bearer token is attached to every request this
  function dispatches. If a caller passes a URL that came from
  unvalidated user input, the token leaks to whatever host that URL
  points at. Callers MUST validate the URL before invoking — pin to
  a domain allowlist (the provider's own host, typically), enforce
  `https`, and reject RFC1918 / loopback / link-local ranges.

  Internal usage (`OpenRouterClient.fetch_models/2`, OAuth refresh,
  userinfo lookups) builds URLs from the Providers registry, which is
  hardcoded and therefore safe. The schema-level `validate_base_url/1`
  guard in `PhoenixKitAI.Endpoint` covers the AI module's
  operator-supplied `base_url` case. New callsites that take URLs
  from anywhere else need their own guard before reaching this
  function — there's no allowlist enforcement here.
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

  Order is determined by `load_all_connections/1`'s map iteration,
  which is alphabetical by provider key (Erlang `Map` order over
  string keys) — NOT the registration order from `Providers.all/0`.
  Within a provider, connections are sorted alphabetically by name
  (case-insensitive). Callers that need a specific provider order
  should walk `Providers.all/0` themselves.
  """
  @spec list_integrations(keyword()) :: [map()]
  def list_integrations(opts \\ []) do
    provider_keys = Providers.all() |> Enum.map(& &1.key)

    load_all_connections(provider_keys, opts)
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
  Lists all connections for a provider.

  Returns a list of `%{uuid, name, data, date_added}` maps, sorted by
  name (case-insensitive). Filters by `module = "integrations"` and
  JSONB `provider` — provider and name both live in JSONB; the row's
  `uuid` is the stable identifier. `date_added` is the row's creation
  timestamp (UTC, second precision), useful for "Created N days ago"
  display in UI pickers.
  """
  @spec list_connections(String.t(), keyword()) :: [
          %{
            uuid: String.t(),
            name: String.t(),
            data: map(),
            date_added: DateTime.t() | nil
          }
        ]
  def list_connections(provider_key, opts \\ []) when is_binary(provider_key) do
    owner = Keyword.get(opts, :owner, :system)

    from(s in Setting,
      where: s.module == ^@settings_module,
      where: fragment("?->>'provider' = ?", s.value_json, ^provider_key)
    )
    |> owner_where(owner)
    |> PhoenixKit.RepoHelper.repo().all()
    |> Enum.map(&to_connection_map/1)
    |> Enum.sort_by(fn %{name: name} -> String.downcase(name) end)
  end

  defp to_connection_map(%Setting{uuid: uuid, value_json: data, date_added: date_added}) do
    decrypted = Encryption.decrypt_fields(data || %{})

    %{
      uuid: uuid,
      name: Map.get(decrypted, "name", ""),
      data: decrypted,
      date_added: date_added
    }
  end

  @doc """
  Loads all connections for multiple providers in a single database query.

  More efficient than calling `list_connections/1` in a loop. Returns a
  map of `provider_key => [%{uuid, name, data, date_added}]`, with every
  requested provider key present (empty list when no connections exist).
  """
  @spec load_all_connections([String.t()], keyword()) :: %{
          String.t() => [
            %{
              uuid: String.t(),
              name: String.t(),
              data: map(),
              date_added: DateTime.t() | nil
            }
          ]
        }
  def load_all_connections(provider_keys, opts \\ []) when is_list(provider_keys) do
    owner = Keyword.get(opts, :owner, :system)

    all_settings =
      from(s in Setting,
        where: s.module == ^@settings_module,
        where: fragment("?->>'provider' = ANY(?)", s.value_json, ^provider_keys)
      )
      |> owner_where(owner)
      |> PhoenixKit.RepoHelper.repo().all()

    grouped =
      Enum.reduce(all_settings, %{}, fn %Setting{} = setting, acc ->
        conn = to_connection_map(setting)
        provider = conn.data["provider"]

        if is_binary(provider) do
          Map.update(acc, provider, [conn], &[conn | &1])
        else
          acc
        end
      end)

    Map.new(provider_keys, fn pk ->
      connections =
        Map.get(grouped, pk, [])
        |> Enum.sort_by(fn %{name: name} -> String.downcase(name) end)

      {pk, connections}
    end)
  end

  @doc """
  Adds a new named connection for a provider.

  This is the row-birth path. The row's UUIDv7 is generated up front and
  used as both the `uuid` and the `key` column; provider and name live
  in JSONB. Names are pure user-chosen labels with no character or
  uniqueness restrictions — any non-empty string (after trim) is valid,
  duplicates within a provider are allowed.

  Returns `{:ok, %{uuid: uuid, data: data}}` on success.
  """
  @spec add_connection(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, %{uuid: String.t(), data: map()}}
          | {:error, :empty_name | :unknown_provider | :scope_not_allowed | term()}
  def add_connection(provider_key, name, actor_uuid \\ nil, opts \\ [])
      when is_binary(provider_key) and is_binary(name) do
    owner = Keyword.get(opts, :owner, :system)
    trimmed = String.trim(name)
    provider = Providers.get(provider_key)
    # A typed owner (user, dashboard, team, …) births an owned connection, so it
    # requires the provider to allow the `:personal` scope; `:system` requires
    # `:system`. (A provider offered "personally" is fine for any entity owner.)
    scope_atom = if match?({t, _} when is_atom(t), owner), do: :personal, else: :system

    cond do
      trimmed == "" ->
        {:error, :empty_name}

      # Enforce provider existence at row-birth, NOT just in the picker —
      # same tamperable "select_provider" event as the scope check below.
      # Without this, an unregistered key makes `Providers.get/1` return
      # `nil`, which makes `scopes_of/1` default to `[:system]` and
      # trivially pass that check — a crafted key would birth a row that
      # `list_connections/1` then reports as a real connection for a
      # provider that was never installed.
      is_nil(provider) ->
        {:error, :unknown_provider}

      # Enforce the provider's declared scope at row-birth, NOT just in the
      # picker — the provider comes from a tamperable event, so a crafted
      # create_connection can't birth (e.g.) a personal Google connection.
      scope_atom not in Providers.scopes_of(provider) ->
        {:error, :scope_not_allowed}

      true ->
        data =
          %{
            "provider" => provider_key,
            "name" => trimmed,
            "auth_type" => provider_auth_type(provider_key),
            "status" => "disconnected"
          }
          |> put_owner(owner)

        case insert_integration_row(data) do
          {:ok, %Setting{uuid: uuid}} ->
            Events.broadcast_connection_added(provider_key, trimmed, owner)

            log_activity(
              "integration.connection_added",
              provider_key,
              trimmed,
              %{},
              "manual",
              actor_uuid,
              uuid
            )

            {:ok, %{uuid: uuid, data: data}}

          {:error, _} = error ->
            error
        end
    end
  end

  # Row-birth path: generate a UUIDv7, use it as both the primary key
  # and the `key` column, and insert with `module = "integrations"`. The
  # `put_change(:uuid, ...)` forces the changeset to use our generated
  # uuid instead of letting Ecto autogenerate a different one.
  defp insert_integration_row(data) do
    uuid = UUIDv7.generate()
    encrypted = Encryption.encrypt_fields(data)

    %Setting{}
    |> Setting.changeset(%{key: uuid, value_json: encrypted, module: @settings_module})
    |> Ecto.Changeset.put_change(:uuid, uuid)
    |> Queries.insert_setting()
  end

  @doc """
  Removes a connection by uuid.

  Names are pure user-chosen labels — no privileged values. The user is
  free to delete any connection; consumer modules that referenced the
  deleted integration row will surface a `:not_configured` (or similar)
  error on next use, which is the correct loud failure.
  """
  @spec remove_connection(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def remove_connection(uuid, actor_uuid \\ nil, opts \\ []) when is_binary(uuid) do
    case resolve_uuid(uuid, Keyword.get(opts, :owner, :system)) do
      {:ok, %{provider: provider, name: name, setting: setting, data: data}} ->
        case Settings.delete_setting(setting.key) do
          {:ok, _} ->
            Events.broadcast_connection_removed(provider, name, owner_of(data))

            log_activity(
              "integration.connection_removed",
              provider,
              name,
              %{},
              "manual",
              actor_uuid,
              uuid
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

  Updates only the JSONB `name` field; the storage key (= row uuid) is
  untouched, so consumers that pinned to the uuid keep working across
  the rename. Names are pure user-chosen labels; any non-empty string
  is valid, duplicates within a provider are allowed.

  No-ops when `new_name` (after trim) matches the current name.

  Returns `{:ok, new_data}` on success.
  """
  @spec rename_connection(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()}
          | {:error, :empty_name | :not_configured | term()}
  def rename_connection(uuid, new_name, actor_uuid \\ nil, opts \\ [])
      when is_binary(uuid) and is_binary(new_name) do
    trimmed = String.trim(new_name)

    with {:ok,
          %{
            provider: provider,
            name: old_name,
            setting: setting,
            data: data,
            undecryptable_fields: undecryptable_fields
          }} <-
           resolve_uuid(uuid, Keyword.get(opts, :owner, :system)) do
      cond do
        trimmed == old_name ->
          {:ok, data}

        trimmed == "" ->
          {:error, :empty_name}

        true ->
          updated = Map.put(data, "name", trimmed)

          case save_integration(setting, updated, undecryptable_fields) do
            {:ok, saved} ->
              Events.broadcast_connection_renamed(provider, old_name, trimmed, owner_of(data))

              log_activity(
                "integration.connection_renamed",
                provider,
                trimmed,
                %{"old_name" => old_name, "new_name" => trimmed},
                "manual",
                actor_uuid,
                uuid
              )

              {:ok, saved}

            error ->
              error
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validate that a provider's credentials are working.

  For OAuth: calls the provider's userinfo endpoint.
  For API key / bot token: calls the provider's validation endpoint if defined.
  Returns `:ok`, `{:ok, note}`, `:unverified` (the provider has no way to
  check a connection — see `do_validate/2`), or `{:error, reason}`.
  """
  @spec validate_connection(String.t(), String.t() | nil, keyword()) ::
          :ok | {:ok, Probe.note()} | :unverified | {:error, String.t()}
  def validate_connection(uuid, actor_uuid \\ nil, opts \\ []) when is_binary(uuid) do
    {result, log_provider, log_name} =
      case resolve_uuid(uuid, Keyword.get(opts, :owner, :system)) do
        {:ok, %{provider: base_provider, name: name, data: data}} ->
          provider = Providers.get(base_provider)

          inner =
            cond do
              is_nil(provider) -> {:error, gettext("Unknown provider")}
              not has_credentials?(data) -> {:error, gettext("Not configured")}
              true -> do_validate(provider, data, owner: Keyword.get(opts, :owner, :system))
            end

          {inner, base_provider, name}

        {:error, _} ->
          {{:error, gettext("Not configured")}, "unknown", ""}
      end

    case result do
      :ok ->
        log_activity(
          "integration.validated",
          log_provider,
          log_name,
          %{"result" => "ok"},
          "manual",
          actor_uuid,
          uuid
        )

      # Passed, but with something the operator needs to know — e.g. SES accepted the
      # signature while refusing GetSendQuota, which proves the credentials are real
      # without proving they can send.
      {:ok, note} ->
        log_activity(
          "integration.validated",
          log_provider,
          log_name,
          # The rendered line — fact and reading both — not the note itself,
          # which activity metadata (a flat string map) has no shape for. A
          # reading belongs in this row and nowhere else: an activity entry is
          # a timestamped record of one check, so "the balance was $1.00" is
          # true of it forever, which is exactly what it is not on the
          # connection.
          %{"result" => "ok", "note" => note_text({:ok, note})},
          "manual",
          actor_uuid,
          uuid
        )

      # This provider has no way to check a connection at all — nothing ran,
      # so there's nothing to log as a pass or a failure.
      :unverified ->
        log_activity(
          "integration.validated",
          log_provider,
          log_name,
          %{"result" => "unverified"},
          "manual",
          actor_uuid,
          uuid
        )

      {:error, reason} ->
        log_activity(
          "integration.validated",
          log_provider,
          log_name,
          %{"result" => "error", "reason" => reason},
          "manual",
          actor_uuid,
          uuid
        )
    end

    result
  rescue
    # Narrow rescue — only catch exceptions we expect from the
    # validate path so genuine logic bugs (KeyError, ArgumentError,
    # MatchError, etc.) bubble up to the supervisor instead of getting
    # swallowed under a generic "validation failed" message. The three
    # caught classes cover the realistic failure modes:
    #
    #   * `DBConnection.OwnershipError` — sandbox checkout race in
    #     tests that hit this path from an async-shared connection.
    #   * `Postgrex.Error` — DB outage / table-missing on the
    #     `log_activity` write (Activity.log hits `phoenix_kit_activity`
    #     and can raise when the table is unreachable or absent).
    #   * `Req.TransportError` / generic transport — should already
    #     be returned as `{:error, _}` by `check_http/2`; this is the
    #     belt-and-braces case.
    e in [DBConnection.OwnershipError, Postgrex.Error, Req.TransportError] ->
      Logger.error(
        "[Integrations] validate_connection error for #{uuid}: #{Exception.message(e)}"
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

  Returns `:unverified` when the provider has no way to check a
  connection at all — see `do_validate/2`.

  `opts[:owner]` (`:system`, the default, or `{:user, uuid}`) picks how strictly
  a provider that connects to a user-typed host checks it — a personal
  connection may not point at a local or private address.
  """
  @spec validate_credentials(String.t(), map(), keyword()) ::
          :ok | {:ok, Probe.note()} | :unverified | {:error, String.t()}
  def validate_credentials(provider_key, attrs, opts \\ [])
      when is_binary(provider_key) and is_map(attrs) do
    case Providers.get(provider_key) do
      nil -> {:error, gettext("Unknown provider")}
      provider -> do_validate(provider, attrs, owner: Keyword.get(opts, :owner, :system))
    end
  rescue
    # Mirror the narrow rescue on `validate_connection/2` — same
    # `do_validate/2` codepath, same expected exception surface. Logic
    # bugs (`KeyError`, `ArgumentError`, etc.) must bubble up instead
    # of being masked under a generic "validation failed".
    e in [DBConnection.OwnershipError, Postgrex.Error, Req.TransportError] ->
      Logger.error(
        "[Integrations] validate_credentials error for #{provider_key}: #{Exception.message(e)}"
      )

      {:error, gettext("Validation failed unexpectedly")}
  end

  # Only a provider that connects to a host the operator typed needs to know
  # whose connection it is checking; every other one ignores the owner.
  defp do_validate(
         %{auth_type: :key_secret, validation: %{strategy: :object_storage}},
         data,
         opts
       ),
       do: Validators.object_storage(data, opts)

  defp do_validate(provider, data, _opts), do: do_validate(provider, data)

  defp do_validate(%{auth_type: :oauth2} = provider, data) do
    token = data["access_token"]
    config = provider.oauth_config || %{}
    userinfo_url = config[:userinfo_url] || config["userinfo_url"]

    cond do
      not (is_binary(token) and token != "") -> {:error, gettext("No access token")}
      is_nil(userinfo_url) -> :unverified
      true -> check_http(userinfo_url, [{"authorization", "Bearer #{token}"}])
    end
  end

  # Providers that cannot be checked with a plain authenticated GET declare a
  # strategy instead. Without these clauses these fell through to the `:ok`
  # catch-all below (Brevo), or to the generic status-code-only check below
  # (Brevo before this validator existed), so "Test Connection" stamped the
  # connection "connected" without verifying anything, or without reporting
  # anything useful beyond a bare pass.
  defp do_validate(%{auth_type: :key_secret, validation: %{strategy: :aws_ses}}, data),
    do: Validators.aws_ses(data)

  defp do_validate(%{auth_type: :credentials, validation: %{strategy: :smtp}}, data),
    do: Validators.smtp(data)

  defp do_validate(%{auth_type: :api_key, validation: %{strategy: :brevo_api}}, data),
    do: Validators.brevo_api(data)

  defp do_validate(%{auth_type: :api_key, validation: %{strategy: :amazon_bedrock}}, data),
    do: Validators.amazon_bedrock(data)

  defp do_validate(%{auth_type: :bot_token, validation: %{strategy: :telegram}}, data),
    do: Validators.telegram(data)

  defp do_validate(%{auth_type: :key_secret, validation: %{strategy: :dataforseo}}, data),
    do: Validators.dataforseo(data)

  defp do_validate(%{auth_type: :api_key, validation: %{strategy: :serpapi}}, data),
    do: Validators.serpapi(data)

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
        :unverified
    end
  end

  defp do_validate(_, _data), do: :unverified

  if Mix.env() == :test do
    # Exposes the private do_validate/2 clauses for direct unit testing.
    # No registered provider today reaches the generic/catch-all clauses
    # (every built-in declares a real check), so the only way to prove
    # those clauses behave correctly for a *future* provider is to call
    # them directly with a synthetic provider map.
    @doc false
    def __do_validate__(provider, data), do: do_validate(provider, data)
  end

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
  Asks the provider for its current figures and returns them, without storing
  anything: `{:ok, reading}`, `:none` when this provider reports no figure, or
  `{:error, message}` when the check failed.

  This is how a page shows something that decays — a DataForSEO balance, the
  searches left on a SerpApi plan, Brevo's remaining credits. Those are never
  kept on the connection (see `t:PhoenixKit.Integrations.Probe.note/0`),
  because a stored figure reads as current however it is stamped; a page that
  wants one asks for it when it renders.

  It costs a provider request per call, and for some providers the check is
  not free of side effects (the SMTP check opens a connection to the relay),
  so call it where a person asked to see the figure — not on every render of
  a page that merely lists connections.

  ## Examples

      iex> reading(uuid)
      {:ok, "Balance: $0.92"}

      iex> reading(uuid)
      :none
  """
  @spec reading(String.t(), keyword()) :: {:ok, String.t()} | :none | {:error, String.t()}
  def reading(uuid, opts \\ []) when is_binary(uuid) do
    uuid
    |> validate_connection_without_logging(opts)
    |> reading_of()
  rescue
    # The same shield `validate_connection/3` carries: the callers are
    # LiveView callbacks, and a database blip or a transport error escaping a
    # validator must not take the page down for a figure it wanted to show.
    e in [DBConnection.OwnershipError, Postgrex.Error, Req.TransportError, Ecto.Query.CastError] ->
      Logger.error("[Integrations] reading error for #{uuid}: #{Exception.message(e)}")
      {:error, gettext("Could not read the current figures")}
  end

  @doc """
  The reading in a check's result, for a caller that ran the check itself:
  `{:ok, reading}`, `:none` when there is none, or the failure.

  `reading/2` is this applied to a fresh check.
  """
  @spec reading_of(term()) :: {:ok, String.t()} | :none | {:error, String.t()}
  def reading_of({:ok, %{reading: reading}}) when is_binary(reading) and reading != "",
    do: {:ok, reading}

  def reading_of({:error, reason}), do: {:error, format_validation_reason(reason)}
  def reading_of(_result), do: :none

  defp validate_connection_without_logging(uuid, opts) do
    case resolve_uuid(uuid, Keyword.get(opts, :owner, :system)) do
      {:ok, %{provider: base_provider, data: data}} ->
        case Providers.get(base_provider) do
          nil ->
            {:error, gettext("Unknown provider")}

          provider ->
            if has_credentials?(data),
              do: do_validate(provider, data),
              else: {:error, gettext("Not configured")}
        end

      {:error, _} ->
        {:error, gettext("Not configured")}
    end
  end

  @doc """
  A check's note as one line for a person, or `nil` when it has nothing to
  say: the fact and the reading joined, in that order.
  """
  @spec note_text(:ok | {:ok, Probe.note() | String.t()} | term()) :: String.t() | nil
  def note_text({:ok, %{} = note}) do
    case [note[:fact], note[:reading]] |> Enum.reject(&(is_nil(&1) or &1 == "")) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  def note_text({:ok, note}) when is_binary(note) and note != "", do: note
  def note_text(_other), do: nil

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

  @spec record_validation(
          String.t(),
          :ok | {:ok, Probe.note() | String.t()} | :unverified | {:error, term()},
          keyword()
        ) :: :ok
  def record_validation(uuid, result, opts \\ []) when is_binary(uuid) do
    {new_status, validation_text} = validation_fields(result)

    case resolve_uuid(uuid, Keyword.get(opts, :owner, :system)) do
      {:ok,
       %{
         provider: base_provider,
         setting: setting,
         data: data,
         undecryptable_fields: undecryptable_fields
       }} ->
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
        # exchange — keeping the two paths consistent. `{:ok, note}`
        # successes (SES quota / Brevo credits / scoped-credential
        # notes) are successful connections too — the credentials
        # provably worked — so they bump the timestamp the same way.
        update =
          if result == :ok or match?({:ok, _}, result) do
            Map.put(base_update, "connected_at", now_iso)
          else
            base_update
          end

        updated = Map.merge(data, update)

        case save_integration(setting, updated, undecryptable_fields) do
          {:ok, _} ->
            if status_changed,
              do: Events.broadcast_validated(base_provider, result, owner_of(data))

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

  # No check actually ran (a provider with no way to verify itself — see
  # the do_validate/2 fallback clauses). Reported as the same "configured"
  # status save_setup/3 already uses for "credentials saved, nothing tested
  # yet" — NOT "connected", which the operator reads as verified.
  defp validation_fields(:unverified),
    do: {"configured", gettext("Not verified — this provider has no connection check")}

  # A check that succeeded and had something to say. Only the FACT half is
  # stored: it stays true until the credentials or the account change, so it
  # belongs on screen with the connection. A reading — a balance, remaining
  # credits, a send quota — is out of date as soon as anything runs, and a
  # stored one reads as current however it is stamped, so it is reported to
  # whoever asked for the check and forgotten. See `reading/2` for a page that
  # wants a current figure, and `t:PhoenixKit.Integrations.Probe.note/0`.
  defp validation_fields({:ok, %{} = note}) do
    case note[:fact] do
      fact when is_binary(fact) and fact != "" -> {"connected", fact}
      _ -> {"connected", "ok"}
    end
  end

  # A bare string is a fact, which is what validators returned before the two
  # were told apart.
  defp validation_fields({:ok, note}) when is_binary(note), do: {"connected", note}

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
      {:ok, %{provider: provider, name: name}} ->
        log_activity(
          "integration.token_refresh_failed",
          provider,
          name,
          %{"reason" => reason_text},
          "auto",
          nil,
          uuid
        )

      _ ->
        :ok
    end
  end

  defp maybe_record_recovery(uuid) do
    case resolve_uuid(uuid) do
      {:ok, %{provider: provider, name: name, data: %{"status" => "error"}}} ->
        record_validation(uuid, :ok)
        log_activity("integration.auto_recovered", provider, name, %{}, "auto", nil, uuid)

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
  # truth for the uuid-strict public API AND the ownership chokepoint.
  # Provider and name are sourced from JSONB; the live `Setting` struct is
  # returned so callers can update in place via changeset.
  #
  # `owner` scopes the resolution (default `:system` — fail-safe):
  #   * `:system`       → resolves only a system row (no owner_uuid)
  #   * `{:user, uuid}` → resolves only a row owned by that user
  #   * `:any`          → no ownership check (OAuth/internal paths only)
  # A mismatch fails CLOSED as `{:error, :not_configured}` — the exact
  # atom every caller already handles — so cross-owner tampering can't
  # mutate/read another owner's connection at this single gate.
  defp resolve_uuid(uuid, owner \\ :system)

  defp resolve_uuid(uuid, owner) when is_binary(uuid) and uuid != "" do
    case Queries.get_setting_by_uuid(uuid) do
      %Setting{module: "integrations"} = setting ->
        {decrypted, undecryptable_fields} =
          Encryption.decrypt_fields_with_failures(setting.value_json || %{})

        if owner_match?(decrypted, owner) do
          {:ok,
           %{
             uuid: uuid,
             provider: Map.get(decrypted, "provider", ""),
             name: Map.get(decrypted, "name", ""),
             setting: setting,
             data: decrypted,
             undecryptable_fields: undecryptable_fields
           }}
        else
          {:error, :not_configured}
        end

      _ ->
        {:error, :not_configured}
    end
  end

  defp resolve_uuid(_, _), do: {:error, :invalid_uuid}

  # ── Ownership helpers (the one place owner is stamped / derived / matched) ──
  #
  # An owner is one of:
  #   * `:system`      — no owner (website-wide connection)
  #   * `:any`         — no filter (owner-agnostic reads: audit, consumer pins)
  #   * `{type, id}`   — a TYPED owner: `type` is an atom (`:user`, `:dashboard`,
  #                      `:team`, …) and `id` is that entity's uuid.
  #
  # Typed owners are stored as `owner_type` + `owner_uuid` in the connection
  # JSONB; `:system` carries neither. Nothing here is hardcoded to `:user`, so a
  # new owner kind (a shared dashboard, a team) works with no schema change —
  # `add_connection(..., owner: {:dashboard, id})` and everyone reads it back via
  # the same `{:dashboard, id}` scope. Rows written before typed owners existed
  # carry `owner_uuid` with NO `owner_type`; those are read as `{:user, uuid}`.

  # Stamp the owner into a connection's JSONB. A non-uuid id is rejected loudly
  # (never write a malformed owner).
  defp put_owner(data, :system), do: Map.drop(data, ["owner_type", "owner_uuid"])

  defp put_owner(data, {type, id}) when is_atom(type) and is_binary(id) do
    if uuid?(id) do
      data
      |> Map.put("owner_type", Atom.to_string(type))
      |> Map.put("owner_uuid", id)
    else
      raise ArgumentError, "invalid integration owner id: #{inspect(id)}"
    end
  end

  # Derive a row's owner from its (decrypted) JSONB. A valid `owner_uuid` ⇒ the
  # typed owner (`owner_type`, defaulting to `:user` for pre-typed rows);
  # absent/nil/malformed ⇒ system (fail toward admin-visible, never toward
  # another owner).
  defp owner_of(data) do
    case Map.get(data, "owner_uuid") do
      uuid when is_binary(uuid) ->
        if uuid?(uuid), do: {owner_type_atom(data), uuid}, else: :system

      _ ->
        :system
    end
  end

  # `String.to_existing_atom` guards against atom exhaustion from DB data — an
  # unrecognized type yields `:__unknown_owner__`, which matches no live scope
  # (fail-closed). A live caller's own owner atom (e.g. `:dashboard`) is always
  # loaded, so real owners round-trip.
  defp owner_type_atom(data) do
    case Map.get(data, "owner_type") do
      type when is_binary(type) and type != "" ->
        try do
          String.to_existing_atom(type)
        rescue
          ArgumentError -> :__unknown_owner__
        end

      # pre-typed rows: an owner_uuid with no owner_type was always a user
      _ ->
        :user
    end
  end

  defp owner_match?(_data, :any), do: true
  defp owner_match?(data, scope), do: owner_of(data) == scope

  # The scope's WHERE fragment for the provider-list reads. `:system` =
  # owner_uuid absent (NULL via ->>), `:any` = all, `{type, id}` = exact owner
  # match with owner_type defaulting to "user" for pre-typed rows.
  defp owner_where(query, :any), do: query

  defp owner_where(query, :system),
    do: from(s in query, where: fragment("?->>'owner_uuid' IS NULL", s.value_json))

  defp owner_where(query, {type, id}) when is_atom(type) and is_binary(id) do
    type_str = Atom.to_string(type)

    from(s in query,
      where:
        fragment("?->>'owner_uuid' = ?", s.value_json, ^id) and
          fragment("COALESCE(?->>'owner_type', 'user') = ?", s.value_json, ^type_str)
    )
  end

  defp provider_auth_type(provider_key) do
    case Providers.get(provider_key) do
      %{auth_type: auth_type} -> Atom.to_string(auth_type)
      nil -> nil
    end
  end

  # A field in `undecryptable_fields` (from the `resolve_uuid/2` call that
  # produced `data`) is absent from `data` only because it currently can't
  # be decrypted — not because anyone meant to remove it. `save_integration/3`
  # writes `value_json` wholesale, so leaving it absent here would
  # permanently erase it the moment a write lands (e.g. `record_validation/3`
  # running on every automatic token-refresh attempt, unrelated to the
  # stuck field). Restores each such field's untouched ciphertext from
  # `setting.value_json` into what gets WRITTEN — never decrypted, never
  # returned to the caller — UNLESS the caller's own merge already put a
  # fresh value under that same key, which always wins.
  #
  # Callers that deliberately rebuild a smaller shape from scratch
  # (`disconnect/3`'s allowlist) pass no `undecryptable_fields` (the
  # default `[]`): those fields are meant to be gone, decryptable or not,
  # and skipping this keeps that intent unambiguous instead of trying to
  # infer it here.
  defp carry_forward_undecryptable(data, %Setting{value_json: raw}, undecryptable_fields)
       when is_map(raw) and is_list(undecryptable_fields) do
    Enum.reduce(undecryptable_fields, data, fn field, acc ->
      if Map.has_key?(acc, field) do
        acc
      else
        case Map.get(raw, field) do
          value when is_binary(value) -> Map.put(acc, field, value)
          _ -> acc
        end
      end
    end)
  end

  defp carry_forward_undecryptable(data, _setting, _undecryptable_fields), do: data

  # `undecryptable_fields` (from the `resolve_uuid/2` call the caller
  # resolved `data`/`setting` from) is applied ONLY to what gets WRITTEN,
  # never to what's returned — a field carried forward this way is raw,
  # still-unreadable ciphertext, and `{:ok, data}` must keep matching
  # `Encryption.decrypt_fields/1`'s contract that a caller never sees that
  # ciphertext as if it were a usable value, even transiently in a
  # LiveView's socket assigns. Defaults to `[]` (no carry-forward) for
  # `disconnect/3`, which deliberately reconstructs a smaller shape from
  # scratch via an explicit allowlist — those fields are meant to be gone,
  # decryptable or not, so no field ever needs restoring there.
  defp save_integration(%Setting{} = setting, data, undecryptable_fields \\ []) do
    encrypted_data =
      data
      |> carry_forward_undecryptable(setting, undecryptable_fields)
      |> Encryption.encrypt_fields()

    setting
    |> Setting.update_changeset(%{value_json: encrypted_data, module: @settings_module})
    |> Queries.update_setting()
    |> case do
      {:ok, _setting} ->
        {:ok, data}

      {:error, changeset} = error ->
        Logger.error(
          "[Integrations] Failed to save integration #{setting.uuid}: #{inspect(changeset)}"
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
          :key_secret -> has_flat_credential_fields?(provider, data)
          :credentials -> has_custom_creds?(data) or has_flat_credential_fields?(provider, data)
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
        has_custom_creds?(data) or
        has_flat_credential_fields?(Providers.get(data["provider"]), data)

  defp has_custom_creds?(%{"credentials" => creds}) when is_map(creds) and map_size(creds) > 0,
    do: true

  defp has_custom_creds?(_), do: false

  # `:credentials` providers (e.g. universal SMTP) store their fields flat
  # on the data map — there's no privileged nested "credentials" shape to
  # check for them (that's `has_custom_creds?/1`, used by consumers that
  # actually nest their creds). Instead, treat the connection as having
  # credentials once every *required* setup field the provider declares is
  # present. Data-driven off the provider's own field list, so it applies
  # to any `:credentials` provider without hardcoding field names here.
  defp has_flat_credential_fields?(%{auth_type: auth_type, setup_fields: fields}, data)
       when auth_type in [:credentials, :key_secret] do
    required = Enum.filter(fields, & &1.required)

    # Guard the empty-required-list footgun: `Enum.all?([], _)` is `true`, which
    # would treat a credentials provider with no required fields as "configured".
    required != [] and
      Enum.all?(required, fn %{key: key} -> field_present?(data[key]) end)
  end

  defp has_flat_credential_fields?(_provider, _data), do: false

  # `:number` setup fields (e.g. SMTP `port`) may arrive as an integer rather
  # than a string, which `present?/1` (binary-only) would wrongly reject.
  defp field_present?(val) when is_number(val), do: true
  defp field_present?(val), do: present?(val)

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

  defp log_activity(action, provider, name, metadata, mode, actor_uuid, resource_uuid)
       when is_binary(provider) and is_binary(name) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      # The caller passes the row's actual uuid so the activity deep-links to the
      # right connection. It is NEVER re-resolved by provider:name here — that
      # first-match could bind to a DIFFERENT owner's row (wrong link, personal
      # metadata in the global feed). `nil` simply omits the link.

      PhoenixKit.Activity.log(%{
        action: action,
        module: "integrations",
        mode: mode,
        actor_uuid: actor_uuid,
        resource_type: "integration",
        resource_uuid: resource_uuid,
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

  Calling this delegates to the orchestrator for backwards compat (so
  it does nothing with `update_mode` on, like the orchestrator).
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
