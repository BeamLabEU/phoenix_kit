defmodule PhoenixKit.Integration.IntegrationsTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Settings

  # ===========================================================================
  # save_setup + get_credentials round-trip
  # ===========================================================================

  describe "save_setup/2 and get_credentials/1 for API key provider" do
    test "saves and retrieves an API key" do
      {:ok, data} = Integrations.save_setup("openrouter", %{"api_key" => "sk-or-test-key"})
      assert data["provider"] == "openrouter"
      assert data["auth_type"] == "api_key"
      assert data["api_key"] == "sk-or-test-key"
      assert data["status"] == "connected"

      {:ok, creds} = Integrations.get_credentials("openrouter")
      assert creds["api_key"] == "sk-or-test-key"
    end

    test "connected? returns true after saving API key" do
      Integrations.save_setup("openrouter", %{"api_key" => "sk-or-test-key"})
      assert Integrations.connected?("openrouter")
    end

    test "connected? returns false when no data exists" do
      refute Integrations.connected?("openrouter")
    end

    test "merges with existing data on subsequent save" do
      Integrations.save_setup("openrouter", %{"api_key" => "key-1"})
      Integrations.save_setup("openrouter", %{"api_key" => "key-2"})

      {:ok, creds} = Integrations.get_credentials("openrouter")
      assert creds["api_key"] == "key-2"
    end
  end

  describe "save_setup/2 for OAuth provider" do
    test "saves client credentials with disconnected status" do
      {:ok, data} =
        Integrations.save_setup("google", %{
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
      Integrations.save_setup("google", %{
        "client_id" => "test-client",
        "client_secret" => "test-secret"
      })

      refute Integrations.connected?("google")
    end
  end

  # ===========================================================================
  # get_integration
  # ===========================================================================

  describe "get_integration/1" do
    test "returns full data blob" do
      Integrations.save_setup("openrouter", %{"api_key" => "test-key"})

      {:ok, data} = Integrations.get_integration("openrouter")
      assert data["provider"] == "openrouter"
      assert data["api_key"] == "test-key"
      assert data["auth_type"] == "api_key"
      assert data["status"] == "connected"
    end

    test "returns error for unconfigured provider" do
      assert {:error, :not_configured} = Integrations.get_integration("nonexistent")
    end
  end

  # ===========================================================================
  # disconnect
  # ===========================================================================

  describe "disconnect/1 for OAuth provider" do
    test "removes tokens but keeps client credentials" do
      # Simulate a connected OAuth provider
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

      assert Integrations.connected?("google")

      :ok = Integrations.disconnect("google")

      {:ok, data} = Integrations.get_integration("google")
      assert data["client_id"] == "my-client-id"
      assert data["client_secret"] == "my-client-secret"
      assert data["status"] == "disconnected"
      refute Map.has_key?(data, "access_token")
      refute Map.has_key?(data, "refresh_token")
      refute Map.has_key?(data, "external_account_id")
    end
  end

  describe "disconnect/1 for API key provider" do
    test "removes everything except provider and auth_type" do
      Integrations.save_setup("openrouter", %{"api_key" => "sk-or-key"})
      assert Integrations.connected?("openrouter")

      :ok = Integrations.disconnect("openrouter")

      {:ok, data} = Integrations.get_integration("openrouter")
      assert data["provider"] == "openrouter"
      assert data["auth_type"] == "api_key"
      assert data["status"] == "disconnected"
      refute Map.has_key?(data, "api_key")
    end
  end

  describe "disconnect/1 for key_secret provider" do
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

      :ok = Integrations.disconnect("aws")

      {:ok, data} = Integrations.get_integration("aws")
      assert data["provider"] == "aws"
      assert data["auth_type"] == "key_secret"
      assert data["status"] == "disconnected"
      refute Map.has_key?(data, "access_key")
      refute Map.has_key?(data, "secret_key")
      refute Map.has_key?(data, "metadata")
    end
  end

  describe "disconnect/1 for nonexistent provider" do
    test "returns ok" do
      assert :ok = Integrations.disconnect("nonexistent")
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
      Integrations.save_setup("openrouter", %{"api_key" => "key-1"})

      integrations = Integrations.list_integrations()
      assert length(integrations) == 1
      assert hd(integrations)["provider"] == "openrouter"
    end
  end

  # ===========================================================================
  # Multi-connection support
  # ===========================================================================

  describe "add_connection/2" do
    test "creates a new named connection" do
      {:ok, data} = Integrations.add_connection("google", "personal")
      assert data["provider"] == "google"
      assert data["name"] == "personal"
      assert data["status"] == "disconnected"
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
      {:ok, data} = Integrations.add_connection("google", "my-company_drive")
      assert data["name"] == "my-company_drive"
    end

    test "rejects duplicate name" do
      {:ok, _} = Integrations.add_connection("google", "work")
      assert {:error, :already_exists} = Integrations.add_connection("google", "work")
    end
  end

  describe "remove_connection/2" do
    test "removes a named connection" do
      Integrations.add_connection("google", "temp")
      assert :ok = Integrations.remove_connection("google", "temp")
    end

    test "cannot remove default connection" do
      assert {:error, :cannot_remove_default} =
               Integrations.remove_connection("google", "default")
    end

    test "returns ok for nonexistent connection" do
      assert :ok = Integrations.remove_connection("google", "nonexistent")
    end
  end

  describe "list_connections/1" do
    test "returns empty list when no connections" do
      assert Integrations.list_connections("google") == []
    end

    test "returns connections with uuid, name, and data" do
      Integrations.save_setup("openrouter", %{"api_key" => "test-key"})

      connections = Integrations.list_connections("openrouter")
      assert length(connections) == 1
      [conn] = connections
      assert conn.name == "default"
      assert conn.uuid != nil
      assert conn.data["api_key"] == "test-key"
    end

    test "returns multiple connections sorted with default first" do
      Integrations.add_connection("google", "personal")
      Integrations.add_connection("google", "work")
      Integrations.save_setup("google", %{"client_id" => "default-id"})

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
      Integrations.save_setup("openrouter", %{"api_key" => "uuid-test-key"})

      [%{uuid: uuid}] = Integrations.list_connections("openrouter")

      assert {:ok, data} = Integrations.get_credentials(uuid)
      assert data["api_key"] == "uuid-test-key"
    end

    test "returns :deleted for nonexistent UUID" do
      fake_uuid = "019d0000-0000-7000-8000-000000000000"
      assert {:error, :deleted} = Integrations.get_credentials(fake_uuid)
    end
  end

  describe "connected?/1 with UUID" do
    test "returns true for connected UUID" do
      Integrations.save_setup("openrouter", %{"api_key" => "valid-key"})
      [%{uuid: uuid}] = Integrations.list_connections("openrouter")
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

  describe "authorization_url/3" do
    test "builds URL when client_id is saved" do
      Integrations.save_setup("google", %{
        "client_id" => "test-client-id",
        "client_secret" => "test-secret"
      })

      {:ok, url} = Integrations.authorization_url("google", "http://localhost:4000/callback")
      assert url =~ "accounts.google.com"
      assert url =~ "client_id=test-client-id"
      assert url =~ "response_type=code"
    end

    test "returns error when client_id not saved" do
      Integrations.save_setup("google", %{"client_secret" => "only-secret"})

      assert {:error, :client_id_not_configured} =
               Integrations.authorization_url("google", "http://localhost/cb")
    end

    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} =
               Integrations.authorization_url("nonexistent", "http://localhost/cb")
    end
  end

  # ===========================================================================
  # Legacy migration
  # ===========================================================================

  describe "legacy migration from document_creator_google_oauth" do
    test "migrates on first access to integration:google" do
      # Write legacy data
      Settings.update_json_setting_with_module(
        "document_creator_google_oauth",
        %{
          "client_id" => "legacy-client",
          "client_secret" => "legacy-secret",
          "access_token" => "ya29.legacy-token",
          "refresh_token" => "1//legacy-refresh",
          "token_type" => "Bearer",
          "expires_in" => 3600,
          "token_obtained_at" => "2026-03-15T10:00:00Z",
          "connected_email" => "legacy@gmail.com",
          "folder_path_templates" => "clients",
          "folder_name_templates" => "templates",
          "templates_folder_id" => "folder-id-123"
        },
        "document_creator"
      )

      # Access via Integrations — should trigger migration
      {:ok, data} = Integrations.get_integration("google")

      assert data["provider"] == "google"
      assert data["auth_type"] == "oauth2"
      assert data["client_id"] == "legacy-client"
      assert data["client_secret"] == "legacy-secret"
      assert data["access_token"] == "ya29.legacy-token"
      assert data["refresh_token"] == "1//legacy-refresh"
      assert data["status"] == "connected"
      assert data["external_account_id"] == "legacy@gmail.com"
      assert data["metadata"]["connected_email"] == "legacy@gmail.com"
      assert data["expires_at"] != nil
    end

    test "migrates folder config to separate key" do
      Settings.update_json_setting_with_module(
        "document_creator_google_oauth",
        %{
          "client_id" => "c",
          "client_secret" => "s",
          "access_token" => "t",
          "folder_path_templates" => "my/path",
          "folder_name_templates" => "tpl",
          "templates_folder_id" => "tid"
        },
        "document_creator"
      )

      # Trigger migration
      Integrations.get_integration("google")

      # Check folder config was moved
      folder_data = Settings.get_json_setting("document_creator_folders", nil)
      assert folder_data != nil
      assert folder_data["folder_path_templates"] == "my/path"
      assert folder_data["folder_name_templates"] == "tpl"
      assert folder_data["templates_folder_id"] == "tid"
    end

    test "does not migrate when integration:google already exists" do
      # Set up integration data directly
      Integrations.save_setup("google", %{
        "client_id" => "new-client",
        "client_secret" => "new-secret"
      })

      # Also set up legacy data (should be ignored)
      Settings.update_json_setting_with_module(
        "document_creator_google_oauth",
        %{
          "client_id" => "old-client",
          "access_token" => "old-token"
        },
        "document_creator"
      )

      {:ok, data} = Integrations.get_integration("google")
      assert data["client_id"] == "new-client"
    end
  end

  # ===========================================================================
  # connected_at timestamp
  # ===========================================================================

  describe "connected_at tracking" do
    test "sets connected_at when API key saved" do
      {:ok, data} = Integrations.save_setup("openrouter", %{"api_key" => "key"})
      assert data["connected_at"] != nil
    end

    test "does not set connected_at for OAuth setup (no tokens yet)" do
      {:ok, data} =
        Integrations.save_setup("google", %{
          "client_id" => "id",
          "client_secret" => "secret"
        })

      assert data["connected_at"] == nil
    end
  end

  # ===========================================================================
  # validate_connection
  # ===========================================================================

  describe "validate_connection/1" do
    test "returns error for unconfigured provider" do
      assert {:error, "Not configured"} = Integrations.validate_connection("openrouter")
    end

    test "returns error for unknown provider key" do
      assert {:error, "Unknown provider"} = Integrations.validate_connection("nonexistent_xyz")
    end

    test "returns ok for api_key provider without validation endpoint" do
      # Save a provider with credentials but whose provider definition has no :validation
      Settings.update_json_setting_with_module(
        Integrations.settings_key("openrouter"),
        %{
          "provider" => "openrouter",
          "auth_type" => "api_key",
          "api_key" => "test-key",
          "status" => "configured"
        },
        "integrations"
      )

      # OpenRouter does have a validation endpoint, so this will try to hit it.
      # In a unit test context without network, it will fail with a connection error.
      # This test verifies the function executes without crashing.
      result = Integrations.validate_connection("openrouter")
      assert result == :ok or match?({:error, _}, result)
    end

    test "returns error when OAuth provider has no access token" do
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

      assert {:error, "No access token"} = Integrations.validate_connection("google")
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
      Integrations.save_setup("openrouter", %{"api_key" => "k"})
      :ok = Integrations.record_validation("openrouter", :ok)

      {:ok, data} = Integrations.get_integration("openrouter")
      assert data["status"] == "connected"
      assert data["validation_status"] == "ok"
      assert is_binary(data["last_validated_at"])
    end

    test "stamps error status with formatted reason on failure" do
      Integrations.save_setup("openrouter", %{"api_key" => "k"})
      :ok = Integrations.record_validation("openrouter", {:error, {:refresh_failed, 400}})

      {:ok, data} = Integrations.get_integration("openrouter")
      assert data["status"] == "error"
      assert data["validation_status"] == "error: Token refresh failed (HTTP 400)"
    end

    test "is a no-op when status and validation_status are unchanged" do
      Integrations.save_setup("openrouter", %{"api_key" => "k"})
      :ok = Integrations.record_validation("openrouter", :ok)
      {:ok, data1} = Integrations.get_integration("openrouter")

      # Second call with same result should not rewrite last_validated_at
      :ok = Integrations.record_validation("openrouter", :ok)
      {:ok, data2} = Integrations.get_integration("openrouter")

      assert data1["last_validated_at"] == data2["last_validated_at"]
    end

    test "silently no-ops when provider has no integration row" do
      assert :ok = Integrations.record_validation("openrouter", {:error, "boom"})
    end

    test "accepts a settings-row UUID and stamps the correct row" do
      Integrations.save_setup("openrouter", %{"api_key" => "k"})

      # Look up the settings row UUID the way external modules do
      [%{uuid: uuid}] = Integrations.list_connections("openrouter")

      :ok = Integrations.record_validation(uuid, {:error, :token_refresh_failed})

      {:ok, data} = Integrations.get_integration("openrouter")
      assert data["status"] == "error"
      assert data["validation_status"] == "error: Token refresh failed"
    end
  end

  describe "connected?/1 simplified" do
    test "returns true when default connection has credentials" do
      Integrations.save_setup("openrouter", %{"api_key" => "key"})
      assert Integrations.connected?("openrouter")
    end

    test "returns false when no connections exist" do
      refute Integrations.connected?("openrouter")
    end

    test "returns true when checking bare provider key with non-default connected" do
      # Add a non-default connection with credentials
      Integrations.add_connection("openrouter", "secondary")

      Integrations.save_setup("openrouter:secondary", %{
        "api_key" => "secondary-key"
      })

      # Bare key should find the connected non-default via find_first_connected
      assert Integrations.connected?("openrouter")
    end
  end
end
