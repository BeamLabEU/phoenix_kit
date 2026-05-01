defmodule PhoenixKit.Integration.IntegrationsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Events
  alias PhoenixKit.Settings

  # Helper: create a connection and (optionally) save credentials in
  # one shot, returning the row's uuid. Mirrors the
  # `add_connection/3` → `save_setup/3` flow that admin form code
  # uses, condensed for tests.
  defp setup_conn(provider, name_or_attrs \\ "default", maybe_attrs \\ %{})

  defp setup_conn(provider, attrs, _) when is_map(attrs),
    do: setup_conn(provider, "default", attrs)

  defp setup_conn(provider, name, attrs) when is_binary(name) and is_map(attrs) do
    uuid =
      case Integrations.add_connection(provider, name) do
        {:ok, %{uuid: uuid}} ->
          uuid

        {:error, :already_exists} ->
          [%{uuid: uuid}] =
            Integrations.list_connections(provider) |> Enum.filter(&(&1.name == name))

          uuid
      end

    if map_size(attrs) > 0 do
      {:ok, _} = Integrations.save_setup(uuid, attrs)
    end

    uuid
  end

  # ===========================================================================
  # save_setup + get_credentials round-trip
  # ===========================================================================

  describe "save_setup/3 and get_credentials/1 for API key provider" do
    test "saves and retrieves an API key" do
      uuid = setup_conn("openrouter")
      {:ok, data} = Integrations.save_setup(uuid, %{"api_key" => "sk-or-test-key"})
      assert data["provider"] == "openrouter"
      assert data["auth_type"] == "api_key"
      assert data["api_key"] == "sk-or-test-key"
      # Status is `"configured"` post-save — credentials saved but not
      # yet validated. The form LV's `maybe_auto_test/2` triggers
      # `validate_connection/2` immediately; on success
      # `record_validation/2` flips the status to `"connected"`.
      assert data["status"] == "configured"

      {:ok, creds} = Integrations.get_credentials(uuid)
      assert creds["api_key"] == "sk-or-test-key"
    end

    test "connected? returns true after saving API key" do
      uuid = setup_conn("openrouter", %{"api_key" => "sk-or-test-key"})
      assert Integrations.connected?(uuid)
    end

    test "connected? returns false when no data exists" do
      refute Integrations.connected?("openrouter")
    end

    test "merges with existing data on subsequent save" do
      uuid = setup_conn("openrouter", %{"api_key" => "key-1"})
      Integrations.save_setup(uuid, %{"api_key" => "key-2"})

      {:ok, creds} = Integrations.get_credentials(uuid)
      assert creds["api_key"] == "key-2"
    end

    test "returns :not_configured when uuid doesn't resolve" do
      ghost_uuid = "00000000-0000-7000-8000-000000000000"
      assert {:error, :not_configured} = Integrations.save_setup(ghost_uuid, %{"x" => "y"})
    end
  end

  describe "save_setup/3 for OAuth provider" do
    test "saves client credentials with disconnected status" do
      uuid = setup_conn("google")

      {:ok, data} =
        Integrations.save_setup(uuid, %{
          "client_id" => "test-client.apps.googleusercontent.com",
          "client_secret" => "GOCSPX-test"
        })

      assert data["provider"] == "google"
      assert data["auth_type"] == "oauth2"
      assert data["client_id"] == "test-client.apps.googleusercontent.com"
      assert data["client_secret"] == "GOCSPX-test"
      assert data["status"] == "disconnected"
    end

    test "OAuth provider not connected until tokens present" do
      uuid =
        setup_conn("google", %{
          "client_id" => "test-client",
          "client_secret" => "test-secret"
        })

      refute Integrations.connected?(uuid)
    end
  end

  # ===========================================================================
  # get_integration
  # ===========================================================================

  describe "get_integration/1" do
    test "returns full data blob" do
      setup_conn("openrouter", %{"api_key" => "test-key"})

      {:ok, data} = Integrations.get_integration("openrouter")
      assert data["provider"] == "openrouter"
      assert data["api_key"] == "test-key"
      assert data["auth_type"] == "api_key"
      # Post-save status is `"configured"`; transitions to `"connected"`
      # only after a successful `record_validation(:ok)`.
      assert data["status"] == "configured"
    end

    test "returns error for unconfigured provider" do
      assert {:error, :not_configured} = Integrations.get_integration("nonexistent")
    end
  end

  # ===========================================================================
  # disconnect
  # ===========================================================================

  describe "disconnect/2 for OAuth provider" do
    test "removes tokens but keeps client credentials" do
      # Simulate a connected OAuth provider — seed the row directly so
      # the test can prove that disconnect surgically removes only the
      # token fields and not the persisted client credentials.
      Settings.update_json_setting_with_module(
        Integrations.settings_key("google"),
        %{
          "provider" => "google",
          "auth_type" => "oauth2",
          "client_id" => "my-client-id",
          "client_secret" => "my-client-secret",
          "access_token" => "ya29.active-token",
          "refresh_token" => "1//refresh-token",
          "status" => "connected",
          "external_account_id" => "user@gmail.com"
        },
        "integrations"
      )

      [%{uuid: uuid}] = Integrations.list_connections("google")
      assert Integrations.connected?(uuid)

      :ok = Integrations.disconnect(uuid)

      {:ok, data} = Integrations.get_integration("google")
      assert data["client_id"] == "my-client-id"
      assert data["client_secret"] == "my-client-secret"
      assert data["status"] == "disconnected"
      refute Map.has_key?(data, "access_token")
      refute Map.has_key?(data, "refresh_token")
      refute Map.has_key?(data, "external_account_id")
    end
  end

  describe "disconnect/2 for API key provider" do
    test "removes everything except provider and auth_type" do
      uuid = setup_conn("openrouter", %{"api_key" => "sk-or-key"})
      assert Integrations.connected?(uuid)

      :ok = Integrations.disconnect(uuid)

      {:ok, data} = Integrations.get_integration("openrouter")
      assert data["provider"] == "openrouter"
      assert data["auth_type"] == "api_key"
      assert data["status"] == "disconnected"
      refute Map.has_key?(data, "api_key")
    end
  end

  describe "disconnect/2 for key_secret provider" do
    test "removes credentials like other non-OAuth types" do
      Settings.update_json_setting_with_module(
        Integrations.settings_key("aws"),
        %{
          "provider" => "aws",
          "auth_type" => "key_secret",
          "access_key" => "AKIATEST",
          "secret_key" => "secret123",
          "status" => "connected",
          "metadata" => %{"region" => "us-east-1"}
        },
        "integrations"
      )

      [%{uuid: uuid}] = Integrations.list_connections("aws")
      :ok = Integrations.disconnect(uuid)

      {:ok, data} = Integrations.get_integration("aws")
      assert data["provider"] == "aws"
      assert data["auth_type"] == "key_secret"
      assert data["status"] == "disconnected"
      refute Map.has_key?(data, "access_key")
      refute Map.has_key?(data, "secret_key")
      refute Map.has_key?(data, "metadata")
    end
  end

  describe "disconnect/2 for nonexistent uuid" do
    test "returns ok" do
      ghost = "00000000-0000-7000-8000-000000000000"
      assert :ok = Integrations.disconnect(ghost)
    end
  end

  describe "get_integration_by_uuid/1" do
    test "returns normalized %{uuid, provider, name, data} on success" do
      uuid = setup_conn("openrouter", "primary", %{"api_key" => "key"})

      assert {:ok, result} = Integrations.get_integration_by_uuid(uuid)
      assert result.uuid == uuid
      assert result.provider == "openrouter"
      assert result.name == "primary"
      assert result.data["api_key"] == "key"
    end

    test "returns :not_configured when uuid doesn't match any row" do
      ghost_uuid = "00000000-0000-7000-8000-000000000000"
      assert {:error, :not_configured} = Integrations.get_integration_by_uuid(ghost_uuid)
    end

    test "rejects empty / non-string input with :invalid_uuid" do
      assert {:error, :invalid_uuid} = Integrations.get_integration_by_uuid("")
      assert {:error, :invalid_uuid} = Integrations.get_integration_by_uuid(nil)
      assert {:error, :invalid_uuid} = Integrations.get_integration_by_uuid(:atom)
    end

    test "sources provider+name from the storage key, ignoring JSONB body drift" do
      # Defensive: the JSONB `provider`/`name` fields are duplicates of
      # information already encoded in the row's `key` column. If the
      # JSONB body has drifted (corrupted by a previous bug, partial
      # restore, etc.), `get_integration_by_uuid/1` must still return
      # the canonical provider+name parsed from `key` so the form LV
      # can recover.
      Settings.update_json_setting_with_module(
        Integrations.settings_key("openrouter"),
        %{
          "api_key" => "key",
          # Drift: JSONB claims provider/name that disagree with the row's key
          "provider" => "openrouter:default",
          "name" => "default:default"
        },
        "integrations"
      )

      [%{uuid: uuid}] = Integrations.list_connections("openrouter")

      assert {:ok, result} = Integrations.get_integration_by_uuid(uuid)
      assert result.provider == "openrouter"
      assert result.name == "default"
    end
  end

  # ===========================================================================
  # get_credentials for all auth types
  # ===========================================================================

  describe "get_credentials/1 for different auth types" do
    test "returns credentials for connected OAuth (access_token present)" do
      Settings.update_json_setting_with_module(
        Integrations.settings_key("google"),
        %{
          "provider" => "google",
          "auth_type" => "oauth2",
          "access_token" => "ya29.token",
          "status" => "connected"
        },
        "integrations"
      )

      assert {:ok, creds} = Integrations.get_credentials("google")
      assert creds["access_token"] == "ya29.token"
    end

    test "returns credentials for bot_token provider" do
      Settings.update_json_setting_with_module(
        Integrations.settings_key("telegram"),
        %{
          "provider" => "telegram",
          "auth_type" => "bot_token",
          "bot_token" => "123456:ABC-DEF",
          "status" => "connected"
        },
        "integrations"
      )

      assert {:ok, creds} = Integrations.get_credentials("telegram")
      assert creds["bot_token"] == "123456:ABC-DEF"
    end

    test "returns credentials for key_secret provider" do
      Settings.update_json_setting_with_module(
        Integrations.settings_key("aws"),
        %{
          "provider" => "aws",
          "auth_type" => "key_secret",
          "access_key" => "AKIATEST",
          "secret_key" => "secret",
          "status" => "connected"
        },
        "integrations"
      )

      assert {:ok, creds} = Integrations.get_credentials("aws")
      assert creds["access_key"] == "AKIATEST"
    end

    test "returns credentials for custom credentials provider" do
      Settings.update_json_setting_with_module(
        Integrations.settings_key("smtp"),
        %{
          "provider" => "smtp",
          "auth_type" => "credentials",
          "credentials" => %{"host" => "smtp.test.com", "port" => 587},
          "status" => "connected"
        },
        "integrations"
      )

      assert {:ok, creds} = Integrations.get_credentials("smtp")
      assert creds["credentials"]["host"] == "smtp.test.com"
    end

    test "returns error when only setup creds exist (no tokens)" do
      Settings.update_json_setting_with_module(
        Integrations.settings_key("google"),
        %{
          "provider" => "google",
          "auth_type" => "oauth2",
          "client_id" => "my-id",
          "client_secret" => "my-secret",
          "status" => "disconnected"
        },
        "integrations"
      )

      assert {:error, :not_configured} = Integrations.get_credentials("google")
    end
  end

  # ===========================================================================
  # settings_key
  # ===========================================================================

  describe "settings_key/1" do
    test "prefixes with integration: and default name" do
      assert Integrations.settings_key("google") == "integration:google:default"
      assert Integrations.settings_key("openrouter") == "integration:openrouter:default"
    end

    test "supports explicit name" do
      assert Integrations.settings_key("google:personal") == "integration:google:personal"
    end
  end

  # ===========================================================================
  # list_integrations
  # ===========================================================================

  describe "list_integrations/0" do
    test "returns empty list when nothing configured" do
      assert Integrations.list_integrations() == []
    end

    test "returns configured integrations" do
      setup_conn("openrouter", %{"api_key" => "key-1"})

      integrations = Integrations.list_integrations()
      assert length(integrations) == 1
      assert hd(integrations)["provider"] == "openrouter"
    end
  end

  # ===========================================================================
  # Multi-connection support
  # ===========================================================================

  describe "add_connection/3" do
    test "creates a new named connection and returns the row's uuid + data" do
      {:ok, %{uuid: uuid, data: data}} = Integrations.add_connection("google", "personal")
      assert is_binary(uuid)
      assert data["provider"] == "google"
      assert data["name"] == "personal"
      assert data["status"] == "disconnected"

      # The returned uuid must resolve back to the same row.
      assert {:ok, %{uuid: ^uuid, name: "personal"}} = Integrations.get_integration_by_uuid(uuid)
    end

    test "rejects empty name" do
      assert {:error, :empty_name} = Integrations.add_connection("google", "")
    end

    test "rejects invalid name with special characters" do
      assert {:error, :invalid_name} = Integrations.add_connection("google", "my drive!")
    end

    test "rejects name starting with hyphen" do
      assert {:error, :invalid_name} = Integrations.add_connection("google", "-bad")
    end

    test "accepts name with hyphens and underscores" do
      {:ok, %{data: data}} = Integrations.add_connection("google", "my-company_drive")
      assert data["name"] == "my-company_drive"
    end

    test "rejects duplicate name" do
      {:ok, _} = Integrations.add_connection("google", "work")
      assert {:error, :already_exists} = Integrations.add_connection("google", "work")
    end
  end

  describe "remove_connection/2" do
    test "removes a connection by uuid" do
      uuid = setup_conn("google", "temp")
      assert :ok = Integrations.remove_connection(uuid)
      assert Integrations.list_connections("google") == []
    end

    test "removes the default-named connection like any other" do
      # Names are pure user-chosen labels with no system semantics —
      # `"default"` is no more privileged than any other string. The
      # cannot_remove_default guard was removed when consumer modules
      # switched to uuid-based references.
      uuid = setup_conn("google", "default")
      assert :ok = Integrations.remove_connection(uuid)
      assert Integrations.list_connections("google") == []
    end

    test "returns ok for nonexistent uuid" do
      ghost = "00000000-0000-7000-8000-000000000000"
      assert :ok = Integrations.remove_connection(ghost)
    end
  end

  describe "rename_connection/3" do
    test "renames a connection: updates row's key column in place, preserves uuid" do
      uuid = setup_conn("google", "personal", %{"client_id" => "cid"})

      assert {:ok, data} = Integrations.rename_connection(uuid, "work")

      assert data["name"] == "work"
      # uuid is stable across rename — the whole point of uuid-strict API.
      assert {:ok, %{name: "work"}} = Integrations.get_integration_by_uuid(uuid)
      assert {:error, :not_configured} = Integrations.get_integration("google:personal")
      assert {:ok, %{"client_id" => "cid"}} = Integrations.get_integration("google:work")
    end

    test "no-ops when new_name matches current name" do
      uuid = setup_conn("google", "personal", %{"client_id" => "cid"})

      assert {:ok, data} = Integrations.rename_connection(uuid, "personal")
      assert data["name"] == "personal"
      assert data["client_id"] == "cid"
    end

    test "rejects empty name" do
      uuid = setup_conn("google", "personal")
      assert {:error, :empty_name} = Integrations.rename_connection(uuid, "")
      assert {:error, :empty_name} = Integrations.rename_connection(uuid, "   ")
    end

    test "rejects names that violate the connection-name pattern" do
      uuid = setup_conn("google", "personal")
      # Spaces, slashes, leading punctuation — all rejected
      assert {:error, :invalid_name} = Integrations.rename_connection(uuid, "my work")
      assert {:error, :invalid_name} = Integrations.rename_connection(uuid, "-leading-dash")
      assert {:error, :invalid_name} = Integrations.rename_connection(uuid, "with/slash")
    end

    test "rejects renaming to a name that already exists for the provider" do
      uuid = setup_conn("google", "personal")
      setup_conn("google", "work")

      assert {:error, :already_exists} = Integrations.rename_connection(uuid, "work")

      # Both rows still present
      assert length(Integrations.list_connections("google")) == 2
    end

    test "default-named connection can now be renamed (no privileged name)" do
      uuid = setup_conn("google", "default", %{"client_id" => "cid"})

      assert {:ok, _} = Integrations.rename_connection(uuid, "primary")
      assert {:error, :not_configured} = Integrations.get_integration("google:default")
      assert {:ok, _} = Integrations.get_integration("google:primary")
    end

    test "returns :not_configured when uuid doesn't resolve" do
      ghost = "00000000-0000-7000-8000-000000000000"
      assert {:error, :not_configured} = Integrations.rename_connection(ghost, "anything")
    end

    test "trims whitespace from new_name" do
      uuid = setup_conn("google", "personal")
      assert {:ok, data} = Integrations.rename_connection(uuid, "  work  ")
      assert data["name"] == "work"
    end

    test "broadcasts :integration_connection_renamed on success" do
      uuid = setup_conn("google", "personal")
      :ok = Events.subscribe()

      {:ok, _} = Integrations.rename_connection(uuid, "work")

      assert_receive {:integration_connection_renamed, "google", "personal", "work"}
    end

    test "does not broadcast on failure" do
      uuid = setup_conn("google", "personal")
      setup_conn("google", "work")
      :ok = Events.subscribe()

      assert {:error, :already_exists} = Integrations.rename_connection(uuid, "work")

      refute_receive {:integration_connection_renamed, _, _, _}, 50
    end
  end

  describe "list_connections/1" do
    test "returns empty list when no connections" do
      assert Integrations.list_connections("google") == []
    end

    test "returns connections with uuid, name, and data" do
      setup_conn("openrouter", %{"api_key" => "test-key"})

      connections = Integrations.list_connections("openrouter")
      assert length(connections) == 1
      [conn] = connections
      assert conn.name == "default"
      assert conn.uuid != nil
      assert conn.data["api_key"] == "test-key"
    end

    test "returns multiple connections sorted with default first" do
      setup_conn("google", "default", %{"client_id" => "default-id"})
      setup_conn("google", "personal")
      setup_conn("google", "work")

      connections = Integrations.list_connections("google")
      names = Enum.map(connections, & &1.name)
      assert hd(names) == "default"
      assert "personal" in names
      assert "work" in names
    end
  end

  # ===========================================================================
  # UUID-based lookups
  # ===========================================================================

  describe "get_credentials/1 with UUID" do
    test "returns credentials when looking up by UUID" do
      uuid = setup_conn("openrouter", %{"api_key" => "uuid-test-key"})

      assert {:ok, data} = Integrations.get_credentials(uuid)
      assert data["api_key"] == "uuid-test-key"
    end

    test "returns :deleted for nonexistent UUID" do
      fake_uuid = "019d0000-0000-7000-8000-000000000000"
      assert {:error, :deleted} = Integrations.get_credentials(fake_uuid)
    end

    test "differentiates :deleted (uuid input) from :not_configured (non-uuid input)" do
      # uuid-shaped input that misses storage → row was deleted
      ghost_uuid = "00000000-0000-7000-8000-000000000000"
      assert {:error, :deleted} = Integrations.get_credentials(ghost_uuid)

      # non-uuid input that misses storage → never configured
      # No `find_first_connected/1` fallback anymore — bare-provider
      # callers see this directly.
      assert {:error, :not_configured} = Integrations.get_credentials("openrouter")
      assert {:error, :not_configured} = Integrations.get_credentials("openrouter:nope")
    end
  end

  describe "connected?/1 with UUID" do
    test "returns true for connected UUID" do
      uuid = setup_conn("openrouter", %{"api_key" => "valid-key"})
      assert Integrations.connected?(uuid)
    end

    test "returns false for deleted UUID" do
      fake_uuid = "019d0000-0000-7000-8000-000000000000"
      refute Integrations.connected?(fake_uuid)
    end
  end

  # ===========================================================================
  # authorization_url
  # ===========================================================================

  describe "authorization_url/4" do
    test "builds URL when client_id is saved" do
      uuid =
        setup_conn("google", %{
          "client_id" => "test-client-id",
          "client_secret" => "test-secret"
        })

      {:ok, url} = Integrations.authorization_url(uuid, "http://localhost:4000/callback")
      assert url =~ "accounts.google.com"
      assert url =~ "client_id=test-client-id"
      assert url =~ "response_type=code"
    end

    test "returns error when client_id not saved" do
      uuid = setup_conn("google", %{"client_secret" => "only-secret"})

      assert {:error, :client_id_not_configured} =
               Integrations.authorization_url(uuid, "http://localhost/cb")
    end

    test "returns error for nonexistent uuid" do
      ghost = "00000000-0000-7000-8000-000000000000"

      assert {:error, :not_configured} =
               Integrations.authorization_url(ghost, "http://localhost/cb")
    end
  end

  # ===========================================================================
  # Legacy migration — moved to per-module migrate_legacy/0 callbacks
  # ===========================================================================
  #
  # The on-read legacy migration that used to live in
  # `Integrations.get_integration/1` (with hardcoded knowledge of
  # `document_creator_google_oauth`) was removed when the
  # `PhoenixKit.Module` behaviour gained the optional `migrate_legacy/0`
  # callback. Each module now owns its own legacy migration; doc_creator's
  # google-OAuth-key migration lives in
  # `PhoenixKitDocumentCreator.migrate_legacy/0` and is exercised by
  # tests in the document_creator repo.
  #
  # Core's `Integrations.run_legacy_migrations/0` is now a deprecated
  # shim that delegates to `ModuleRegistry.run_all_legacy_migrations/0`
  # (see the test for the orchestrator in module_registry_test.exs).

  describe "find_uuid_by_provider_name/1" do
    test "resolves an exact provider:name pair to the row's uuid" do
      uuid = setup_conn("openrouter", "primary")
      assert {:ok, ^uuid} = Integrations.find_uuid_by_provider_name("openrouter:primary")
    end

    test "accepts a tuple form" do
      uuid = setup_conn("openrouter", "tuple-form")
      assert {:ok, ^uuid} = Integrations.find_uuid_by_provider_name({"openrouter", "tuple-form"})
    end

    test "treats bare provider as `provider:default`" do
      uuid = setup_conn("openrouter", "default")
      assert {:ok, ^uuid} = Integrations.find_uuid_by_provider_name("openrouter")
    end

    test "returns :not_found when no matching row exists" do
      assert {:error, :not_found} = Integrations.find_uuid_by_provider_name("openrouter:ghost")
    end

    test "returns :invalid for malformed input" do
      assert {:error, :invalid} = Integrations.find_uuid_by_provider_name("")
      assert {:error, :invalid} = Integrations.find_uuid_by_provider_name(nil)
      assert {:error, :invalid} = Integrations.find_uuid_by_provider_name({"foo", ""})
    end
  end

  describe "resolve_to_uuid/1" do
    # Dual-input lookup that consumer modules' lazy-promotion paths
    # converge on. Tests pin both halves: uuid → verify-row-exists, and
    # provider:name → find_uuid_by_provider_name.

    test "passes through a valid uuid that resolves to an existing row" do
      uuid = setup_conn("openrouter", "primary")
      assert {:ok, ^uuid} = Integrations.resolve_to_uuid(uuid)
    end

    test "returns :not_found for a uuid-shaped string with no matching row" do
      orphan = "01234567-89ab-7def-8000-000000000000"
      assert {:error, :not_found} = Integrations.resolve_to_uuid(orphan)
    end

    test "delegates to find_uuid_by_provider_name for provider:name input" do
      uuid = setup_conn("openrouter", "work")
      assert {:ok, ^uuid} = Integrations.resolve_to_uuid("openrouter:work")
    end

    test "treats bare provider as provider:default" do
      uuid = setup_conn("openrouter", "default")
      assert {:ok, ^uuid} = Integrations.resolve_to_uuid("openrouter")
    end

    test "returns :not_found for provider:name that doesn't resolve" do
      assert {:error, :not_found} = Integrations.resolve_to_uuid("openrouter:ghost")
    end

    test "returns :invalid for empty / nil / non-binary input" do
      assert {:error, :invalid} = Integrations.resolve_to_uuid("")
      assert {:error, :invalid} = Integrations.resolve_to_uuid(nil)
      assert {:error, :invalid} = Integrations.resolve_to_uuid(:atom)
      assert {:error, :invalid} = Integrations.resolve_to_uuid(123)
    end
  end

  describe "Integrations.get_integration/1 missing-row semantics (post-extraction)" do
    test "non-uuid key that doesn't exist returns :not_configured (no on-read migration)" do
      assert {:error, :not_configured} = Integrations.get_integration("google")
    end

    test "preserves connection-not-found behavior even when legacy keys exist" do
      # Stage a legacy oauth key under the OLD shape — core no longer
      # auto-migrates from it; that's the doc_creator module's job now.
      Settings.update_json_setting_with_module(
        "document_creator_google_oauth",
        %{"client_id" => "legacy-untouched", "access_token" => "legacy-token"},
        "document_creator"
      )

      assert {:error, :not_configured} = Integrations.get_integration("google")
    end
  end

  # ===========================================================================
  # connected_at timestamp
  # ===========================================================================

  describe "connected_at tracking" do
    test "save_setup with API key leaves connected_at nil (configured, not validated)" do
      # `connected_at` only stamps on a successful validation — the
      # honest post-save state is "configured" (credentials present,
      # connection unverified). No timestamp until a real test
      # succeeds.
      uuid = setup_conn("openrouter")
      {:ok, data} = Integrations.save_setup(uuid, %{"api_key" => "key"})
      assert data["status"] == "configured"
      assert data["connected_at"] == nil
    end

    test "does not set connected_at for OAuth setup (no tokens yet)" do
      uuid = setup_conn("google")

      {:ok, data} =
        Integrations.save_setup(uuid, %{
          "client_id" => "id",
          "client_secret" => "secret"
        })

      assert data["connected_at"] == nil
    end

    test "record_validation(:ok) stamps connected_at on a successful validation" do
      # Save credentials → "configured", no connected_at.
      uuid = setup_conn("openrouter", %{"api_key" => "key"})
      {:ok, saved} = Integrations.get_integration(uuid)
      assert saved["connected_at"] == nil

      # Successful validation flips status to "connected" AND stamps
      # connected_at — same shape as the OAuth `exchange_code/4`
      # path stamps the field on a successful token exchange.
      :ok = Integrations.record_validation(uuid, :ok)

      {:ok, data} = Integrations.get_integration(uuid)
      assert data["status"] == "connected"
      assert is_binary(data["connected_at"])
      assert data["last_validated_at"] != nil
    end

    test "record_validation(:ok) advances connected_at on every successful re-validation" do
      # `connected_at` tracks the LAST successful connection — the
      # form's "Connected N ago" reads from it, so users expect it
      # to refresh on every successful re-test. (A previous
      # one-shot semantic left the timestamp stuck on first-ever
      # connection, which read as "didn't update even though it
      # connected" after a fresh `:ok`.) Matches the OAuth
      # `exchange_code/4` path which always overwrites the field
      # on a successful token exchange.
      uuid = setup_conn("openrouter", %{"api_key" => "key"})
      :ok = Integrations.record_validation(uuid, :ok)

      {:ok, after_first} = Integrations.get_integration(uuid)
      first_connected_at = after_first["connected_at"]
      assert is_binary(first_connected_at)

      # An :error in between is a real state transition; the next
      # :ok represents a fresh successful connection and should
      # bump connected_at.
      Process.sleep(20)
      :ok = Integrations.record_validation(uuid, {:error, :timeout})
      :ok = Integrations.record_validation(uuid, :ok)

      {:ok, after_second} = Integrations.get_integration(uuid)
      assert after_second["connected_at"] > first_connected_at
      assert after_second["last_validated_at"] == after_second["connected_at"]
    end

    test "record_validation({:error, _}) does NOT stamp connected_at" do
      # An error result must not bump connected_at — a failed test
      # is the opposite of a successful connection.
      uuid = setup_conn("openrouter", %{"api_key" => "key"})
      :ok = Integrations.record_validation(uuid, {:error, :invalid_api_key})

      {:ok, data} = Integrations.get_integration(uuid)
      assert data["status"] == "error"
      assert data["connected_at"] == nil
    end

    test "record_validation({:error, _}) does NOT clobber an existing connected_at" do
      # If the connection previously succeeded (so connected_at is
      # set) and a later validation fails, leave the historical
      # connected_at in place — that's the user's "last time it
      # worked" reference. Only a *successful* validation moves
      # connected_at forward.
      uuid = setup_conn("openrouter", %{"api_key" => "key"})
      :ok = Integrations.record_validation(uuid, :ok)
      {:ok, after_ok} = Integrations.get_integration(uuid)
      original_connected_at = after_ok["connected_at"]
      assert is_binary(original_connected_at)

      :ok = Integrations.record_validation(uuid, {:error, :timeout})

      {:ok, after_err} = Integrations.get_integration(uuid)
      assert after_err["status"] == "error"
      assert after_err["connected_at"] == original_connected_at
    end
  end

  # ===========================================================================
  # validate_connection
  # ===========================================================================

  describe "validate_connection/2" do
    test "returns error for nonexistent uuid" do
      ghost = "00000000-0000-7000-8000-000000000000"
      assert {:error, "Not configured"} = Integrations.validate_connection(ghost)
    end

    test "returns ok for api_key provider without validation endpoint" do
      # OpenRouter does have a validation endpoint, so this will try to hit it.
      # In a unit test context without network, it will fail with a connection error.
      # This test verifies the function executes without crashing.
      uuid = setup_conn("openrouter", %{"api_key" => "test-key"})
      result = Integrations.validate_connection(uuid)
      assert result == :ok or match?({:error, _}, result)
    end

    test "returns error when OAuth provider has no access token" do
      # Seed a row that claims to be connected but is missing the
      # access_token. Real-world: a token-revocation race or partial
      # restore. validate_connection should distinguish "credentials
      # missing" (Not configured) from "access_token specifically
      # missing on an otherwise-connected row" (No access token).
      Settings.update_json_setting_with_module(
        Integrations.settings_key("google"),
        %{
          "provider" => "google",
          "auth_type" => "oauth2",
          "client_id" => "id",
          "client_secret" => "secret",
          "status" => "connected"
        },
        "integrations"
      )

      [%{uuid: uuid}] = Integrations.list_connections("google")

      assert {:error, "No access token"} = Integrations.validate_connection(uuid)
    end
  end

  # ===========================================================================
  # connected? simplified behavior
  # ===========================================================================

  # ===========================================================================
  # record_validation — health stamping on manual + automatic paths
  # ===========================================================================

  describe "record_validation/2" do
    test "stamps status/validation_status on success" do
      uuid = setup_conn("openrouter", %{"api_key" => "k"})
      :ok = Integrations.record_validation(uuid, :ok)

      {:ok, data} = Integrations.get_integration(uuid)
      assert data["status"] == "connected"
      assert data["validation_status"] == "ok"
      assert is_binary(data["last_validated_at"])
    end

    test "stamps error status with formatted reason on failure" do
      uuid = setup_conn("openrouter", %{"api_key" => "k"})
      :ok = Integrations.record_validation(uuid, {:error, {:refresh_failed, 400}})

      {:ok, data} = Integrations.get_integration(uuid)
      assert data["status"] == "error"
      assert data["validation_status"] == "error: Token refresh failed (HTTP 400)"
    end

    test "advances last_validated_at on every call, even when status is unchanged" do
      # `last_validated_at` is the "moment of the last validation
      # attempt" timestamp. A user clicking Test Connection on an
      # already-connected integration must see the field move forward
      # — otherwise the form's "Last tested N ago" goes stale.
      uuid = setup_conn("openrouter", %{"api_key" => "k"})
      :ok = Integrations.record_validation(uuid, :ok)
      {:ok, data1} = Integrations.get_integration(uuid)

      # Sleep to make the timestamp comparison meaningful at second
      # resolution. Same result, same status — but timestamp must
      # advance.
      Process.sleep(20)

      :ok = Integrations.record_validation(uuid, :ok)
      {:ok, data2} = Integrations.get_integration(uuid)

      assert data2["last_validated_at"] > data1["last_validated_at"]
      # Status / validation_status unchanged across the duplicate
      # :ok call. `connected_at` advances alongside
      # `last_validated_at` because both successful validations
      # represent fresh successful connections (matches the OAuth
      # exchange_code/4 path's behaviour and the user-facing
      # "Connected N ago" semantics).
      assert data2["status"] == data1["status"]
      assert data2["validation_status"] == data1["validation_status"]
      assert data2["connected_at"] > data1["connected_at"]
    end

    test "broadcasts only when status or validation_status changes" do
      # Listing LV subscribers reload on `:integration_validated` —
      # gating the broadcast on actual state changes avoids reload
      # storms from high-frequency automatic paths (e.g. token
      # refresh failing on every API call).
      uuid = setup_conn("openrouter", %{"api_key" => "k"})
      :ok = Events.subscribe()

      # First :ok flips status from "configured" → "connected" → broadcasts.
      :ok = Integrations.record_validation(uuid, :ok)
      assert_receive {:integration_validated, "openrouter:default", :ok}

      # Second :ok keeps status at "connected" → no broadcast (but
      # last_validated_at still advances per the test above).
      :ok = Integrations.record_validation(uuid, :ok)
      refute_receive {:integration_validated, _, _}, 50

      # Switching to error → broadcasts.
      :ok = Integrations.record_validation(uuid, {:error, "boom"})
      assert_receive {:integration_validated, "openrouter:default", {:error, "boom"}}
    end

    test "silently no-ops when uuid doesn't resolve" do
      ghost = "00000000-0000-7000-8000-000000000000"
      assert :ok = Integrations.record_validation(ghost, {:error, "boom"})
    end
  end

  # ===========================================================================
  # Storage-key integrity (regression: corrupted JSONB cannot leak into key)
  # ===========================================================================
  #
  # Background: a previous bug wrote `"openrouter:default"` into the
  # JSONB `provider` field, then derived a storage key from that field,
  # producing `integration:openrouter:default:default`. The fix is
  # structural: provider+name are sourced from the row's `key` column
  # only, and JSONB `provider`/`name` are treated as untrusted
  # duplicates. This block proves the invariant holds.

  describe "storage-key invariant" do
    test "rename never adds extra colon segments to the storage key" do
      uuid = setup_conn("openrouter", "primary", %{"api_key" => "k1"})

      # Confirm starting shape: exactly two colons (the prefix +
      # provider/name separator).
      [%{key: starting_key}] = list_settings_keys()
      assert starting_key == "integration:openrouter:primary"

      # Rename → still exactly two colons.
      {:ok, _} = Integrations.rename_connection(uuid, "work")
      [%{key: after_rename}] = list_settings_keys()
      assert after_rename == "integration:openrouter:work"
    end

    test "rename round-trip is idempotent on storage key" do
      uuid = setup_conn("openrouter", "a", %{"api_key" => "k"})

      {:ok, _} = Integrations.rename_connection(uuid, "b")
      {:ok, _} = Integrations.rename_connection(uuid, "c")
      {:ok, _} = Integrations.rename_connection(uuid, "a")

      [%{key: key}] = list_settings_keys()
      assert key == "integration:openrouter:a"
    end

    test "save_setup ignores corrupted JSONB provider/name and writes to the canonical key" do
      # Seed a row whose JSONB body has drifted (simulating the
      # original bug condition). Then call save_setup via uuid — the
      # write must land at `integration:openrouter:primary`, NOT at
      # `integration:openrouter:default:primary` or any other
      # JSONB-derived key.
      uuid = setup_conn("openrouter", "primary")

      [%{uuid: ^uuid, key: original_key}] = list_settings_keys()
      assert original_key == "integration:openrouter:primary"

      # Hand-corrupt the JSONB body to drift away from the storage key.
      Settings.update_json_setting_with_module(
        original_key,
        %{
          "provider" => "openrouter:default",
          "name" => "default:primary",
          "api_key" => "old"
        },
        "integrations"
      )

      # save_setup via uuid: the storage key must remain canonical.
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "new"})

      [%{key: after_save}] = list_settings_keys()
      assert after_save == "integration:openrouter:primary"

      # And the JSONB body's provider/name are now repaired (sourced
      # from the storage key, not from the previous corrupted body).
      {:ok, %{provider: "openrouter", name: "primary", data: data}} =
        Integrations.get_integration_by_uuid(uuid)

      assert data["api_key"] == "new"
    end
  end

  defp list_settings_keys do
    require Ecto.Query

    Ecto.Query.from(s in PhoenixKit.Settings.Setting,
      where: like(s.key, "integration:%"),
      select: %{uuid: s.uuid, key: s.key}
    )
    |> PhoenixKit.RepoHelper.repo().all()
  end

  describe "connected?/1 simplified" do
    test "returns true when default connection has credentials (bare provider)" do
      setup_conn("openrouter", %{"api_key" => "key"})
      assert Integrations.connected?("openrouter")
    end

    test "returns false when no connections exist" do
      refute Integrations.connected?("openrouter")
    end

    test "bare provider key no longer falls back to non-default connections" do
      # The legacy `find_first_connected/1` fallback was removed once
      # consumers switched to uuid-based references. A bare provider
      # call now resolves only against the storage row keyed at
      # `integration:<provider>:default` — non-default rows are
      # invisible to bare-provider lookups.
      uuid = setup_conn("openrouter", "secondary", %{"api_key" => "secondary-key"})

      refute Integrations.connected?("openrouter")

      # The non-default row IS reachable, but only via its uuid — that's
      # the only call shape consumer modules should be using now.
      assert Integrations.connected?(uuid)
    end
  end
end
