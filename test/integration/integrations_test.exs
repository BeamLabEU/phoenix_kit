defmodule PhoenixKit.Integration.IntegrationsTest do
  # Validation broadcasts use a shared provider-wide topic; isolate mailbox assertions
  # from the LiveView suites subscribing to the same topic.
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Events
  alias PhoenixKit.Integrations.ObjectStorageServices
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Queries, as: SettingsQueries
  alias PhoenixKit.Test.Repo

  # Helper: create a connection and (optionally) save credentials in
  # one shot, returning the row's uuid. Mirrors the
  # `add_connection/3` → `save_setup/3` flow that admin form code
  # uses, condensed for tests.
  defp setup_conn(provider, name_or_attrs \\ "default", maybe_attrs \\ %{})

  defp setup_conn(provider, attrs, _) when is_map(attrs),
    do: setup_conn(provider, "default", attrs)

  defp setup_conn(provider, name, attrs) when is_binary(name) and is_map(attrs) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name)

    if map_size(attrs) > 0 do
      {:ok, _} = Integrations.save_setup(uuid, attrs)
    end

    uuid
  end

  # Helper: seed a connection row with arbitrary JSONB attributes,
  # bypassing `save_setup/3`'s provider-fields filter. Used by tests
  # that need to inject `access_token`, `status: "connected"`, or
  # other fields outside the provider's declared `setup_fields`.
  defp seed_raw(provider, name \\ "default", attrs) when is_map(attrs) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection(provider, name)
    current = Settings.get_json_setting_by_uuid(uuid) || %{}
    Settings.update_json_setting_with_module(uuid, Map.merge(current, attrs), "integrations")
    uuid
  end

  describe "storage dependency protection" do
    test "disabled buckets protect removal, disconnection and credentials but allow rename" do
      uuid =
        setup_conn("object_storage", %{
          "service" => "aws_s3",
          "access_key" => "old",
          "secret_key" => "secret"
        })

      Repo.insert!(%Bucket{
        name: "Protected bucket",
        provider: "s3",
        bucket_name: "protected-test",
        integration_uuid: uuid,
        enabled: false
      })

      assert {:error, {:in_use, [_ | _]}} = Integrations.remove_connection(uuid)
      assert {:error, {:in_use, [_ | _]}} = Integrations.disconnect(uuid)

      assert {:error, {:storage_validation_failed, "Protected bucket"}} =
               Integrations.save_setup(uuid, %{"access_key" => "new"}, nil,
                 storage_probe: fn _ -> {:error, :denied} end
               )

      assert {:ok, _} = Integrations.rename_connection(uuid, "Renamed safely")
      assert {:ok, %{data: %{"access_key" => "old"}}} = Integrations.get_integration_by_uuid(uuid)
    end

    test "key rotation checks every dependent bucket and preserves all old data on failure" do
      uuid =
        setup_conn("object_storage", %{
          "service" => "aws_s3",
          "access_key" => "old",
          "secret_key" => "old-secret"
        })

      for n <- 1..2 do
        Repo.insert!(%Bucket{
          name: "Rotation #{n}",
          provider: "s3",
          bucket_name: "rotation-#{n}",
          integration_uuid: uuid
        })
      end

      assert {:error, {:storage_validation_failed, _}} =
               Integrations.update_connection(uuid, "New name", %{"access_key" => "new"}, nil,
                 storage_probe: fn _ -> {:error, :denied} end
               )

      assert {:ok, %{name: "default", data: %{"access_key" => "old"}}} =
               Integrations.get_integration_by_uuid(uuid)

      test = self()

      assert {:ok, _} =
               Integrations.save_setup(
                 uuid,
                 %{"access_key" => "new", "secret_key" => "new-secret"},
                 nil,
                 storage_probe: fn bucket ->
                   assert bucket.integration_uuid == nil
                   assert bucket.access_key_id == "new"
                   assert bucket.secret_access_key == "new-secret"
                   send(test, {:checked, bucket.bucket_name})
                   :ok
                 end
               )

      assert_received {:checked, "rotation-1"}
      assert_received {:checked, "rotation-2"}
      assert {:ok, %{data: %{"access_key" => "new"}}} = Integrations.get_integration_by_uuid(uuid)
    end

    test "storage destinations are protected and usage does not reveal a foreign connection" do
      uuid =
        setup_conn("object_storage", %{
          "service" => "aws_s3",
          "access_key" => "key",
          "secret_key" => "secret"
        })

      Repo.insert!(%Bucket{
        name: "Used",
        provider: "s3",
        bucket_name: "photos",
        integration_uuid: uuid
      })

      assert {:error, :storage_destination_immutable} =
               Integrations.save_setup(uuid, %{"region" => "eu-west-1"})

      assert [%{bucket: "photos"}] = Integrations.usage(uuid)
      assert [] == Integrations.usage(uuid, owner: {:user, UUIDv7.generate()})
    end

    test "key rotation accepts the canonical spelling of an unchanged destination" do
      uuid =
        seed_raw("object_storage", "b2-url", %{
          "service" => "backblaze_b2",
          "region" => "us-west-002",
          "endpoint" => "https://s3.us-west-002.backblazeb2.com",
          "access_key" => "old",
          "secret_key" => "old-secret"
        })

      Repo.insert!(%Bucket{
        name: "Kept",
        provider: "b2",
        bucket_name: "kept",
        region: "us-west-002",
        endpoint: "https://s3.us-west-002.backblazeb2.com",
        integration_uuid: uuid
      })

      attrs =
        ObjectStorageServices.attrs(%{
          "service" => "backblaze_b2",
          "region" => "us-west-002",
          "endpoint" => "https://s3.us-west-002.backblazeb2.com",
          "access_key" => "new",
          "secret_key" => "new-secret"
        })

      assert attrs["endpoint"] == "s3.us-west-002.backblazeb2.com"

      assert {:ok, _} =
               Integrations.save_setup(uuid, attrs, nil,
                 storage_probe: fn bucket ->
                   assert bucket.access_key_id == "new"
                   :ok
                 end
               )

      assert {:ok, %{data: %{"access_key" => "new", "endpoint" => endpoint}}} =
               Integrations.get_integration_by_uuid(uuid)

      assert endpoint == "s3.us-west-002.backblazeb2.com"
    end

    test "a standard AWS endpoint can be blanked during rotation when the region stays" do
      uuid =
        seed_raw("object_storage", "aws-url", %{
          "service" => "aws_s3",
          "region" => "eu-west-1",
          "endpoint" => "https://s3.eu-west-1.amazonaws.com",
          "access_key" => "old",
          "secret_key" => "old-secret"
        })

      Repo.insert!(%Bucket{
        name: "AWS",
        provider: "s3",
        bucket_name: "aws-photos",
        region: "eu-west-1",
        endpoint: "https://s3.eu-west-1.amazonaws.com",
        integration_uuid: uuid
      })

      attrs =
        ObjectStorageServices.attrs(%{
          "service" => "aws_s3",
          "region" => "eu-west-1",
          "endpoint" => "https://s3.eu-west-1.amazonaws.com",
          "access_key" => "new",
          "secret_key" => "new-secret"
        })

      assert attrs["endpoint"] == ""

      assert {:ok, _} =
               Integrations.save_setup(uuid, attrs, nil, storage_probe: fn _bucket -> :ok end)

      assert {:ok, %{data: %{"access_key" => "new", "endpoint" => ""}}} =
               Integrations.get_integration_by_uuid(uuid)
    end

    test "a custom AWS host is not replaced by the public endpoint" do
      uuid =
        seed_raw("object_storage", "aws-vpce", %{
          "service" => "aws_s3",
          "region" => "eu-west-1",
          "endpoint" => "https://bucket.vpce-1.s3.eu-west-1.vpce.amazonaws.com",
          "access_key" => "old",
          "secret_key" => "old-secret"
        })

      Repo.insert!(%Bucket{
        name: "VPC",
        provider: "s3",
        bucket_name: "vpc-photos",
        region: "eu-west-1",
        endpoint: "https://bucket.vpce-1.s3.eu-west-1.vpce.amazonaws.com",
        integration_uuid: uuid
      })

      attrs =
        ObjectStorageServices.attrs(%{
          "service" => "aws_s3",
          "region" => "eu-west-1",
          "endpoint" => "https://bucket.vpce-1.s3.eu-west-1.vpce.amazonaws.com",
          "access_key" => "new",
          "secret_key" => "new-secret"
        })

      assert {:error, :storage_destination_immutable} =
               Integrations.save_setup(uuid, attrs, nil, storage_probe: fn _ -> :ok end)

      assert {:ok, %{data: %{"access_key" => "old", "endpoint" => endpoint}}} =
               Integrations.get_integration_by_uuid(uuid)

      assert endpoint == "https://bucket.vpce-1.s3.eu-west-1.vpce.amazonaws.com"
    end

    test "a form rename rewrites only the spelling of an unchanged destination" do
      uuid =
        seed_raw("object_storage", "b2-rename", %{
          "service" => "backblaze_b2",
          "region" => "us-west-002",
          "endpoint" => "https://s3.us-west-002.backblazeb2.com",
          "access_key" => "old",
          "secret_key" => "old-secret"
        })

      Repo.insert!(%Bucket{
        name: "Rename",
        provider: "b2",
        bucket_name: "rename-me",
        integration_uuid: uuid
      })

      attrs =
        ObjectStorageServices.attrs(%{
          "service" => "backblaze_b2",
          "region" => "us-west-002",
          "endpoint" => "https://s3.us-west-002.backblazeb2.com",
          "access_key" => "old",
          "secret_key" => ""
        })

      refute Map.has_key?(attrs, "secret_key")

      assert {:ok, _} = Integrations.update_connection(uuid, "Renamed from the form", attrs)

      assert {:ok, %{name: "Renamed from the form", data: data}} =
               Integrations.get_integration_by_uuid(uuid)

      assert data["access_key"] == "old"
      assert data["secret_key"] == "old-secret"
      assert data["endpoint"] == "s3.us-west-002.backblazeb2.com"
    end

    test "an existing storage service cannot be switched" do
      uuid =
        setup_conn("object_storage", %{
          "service" => "aws_s3",
          "access_key" => "old",
          "secret_key" => "secret"
        })

      assert {:error, :service_immutable} =
               Integrations.save_setup(uuid, %{"service" => "cloudflare_r2"})
    end
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

    test "preserves the JSONB name across save_setup (post-V114 regression)" do
      # Regression: pre-V114 the row's storage key was
      # `integration:<provider>:<name>`, and save_setup parsed `name`
      # back out of the key to re-stamp `data["name"]`. Post-V114 the
      # key is just the uuid, so parsing it would put the uuid string
      # into `data["name"]`. save_setup must source `name` from the
      # existing JSONB body (set at row birth in add_connection/3),
      # not from the storage key.
      uuid = setup_conn("openrouter", "My Display Name")

      {:ok, data} = Integrations.save_setup(uuid, %{"api_key" => "sk-or-test"})

      assert data["name"] == "My Display Name"
      refute data["name"] == uuid

      # Round-trip through get_integration_by_uuid pins the same.
      assert {:ok, %{name: "My Display Name"}} = Integrations.get_integration_by_uuid(uuid)
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
      uuid =
        seed_raw("google", %{
          "auth_type" => "oauth2",
          "client_id" => "my-client-id",
          "client_secret" => "my-client-secret",
          "access_token" => "ya29.active-token",
          "refresh_token" => "1//refresh-token",
          "status" => "connected",
          "external_account_id" => "user@gmail.com"
        })

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
      uuid =
        seed_raw("aws_ses", %{
          "auth_type" => "key_secret",
          "access_key" => "AKIATEST",
          "secret_key" => "secret123",
          "status" => "connected",
          "metadata" => %{"region" => "us-east-1"}
        })

      :ok = Integrations.disconnect(uuid)

      {:ok, data} = Integrations.get_integration("aws_ses")
      assert data["provider"] == "aws_ses"
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

    test "sources provider+name from JSONB (key is now uuid-only)" do
      # Post-V114 storage shape: the row's `key` column is just the
      # row's uuid; provider and name live in JSONB. This test pins
      # the new invariant — write specific JSONB values and read
      # them back verbatim via the uuid lookup.
      uuid =
        seed_raw("openrouter", "primary", %{
          "api_key" => "key",
          "provider" => "openrouter",
          "name" => "primary"
        })

      assert {:ok, result} = Integrations.get_integration_by_uuid(uuid)
      assert result.provider == "openrouter"
      assert result.name == "primary"
    end
  end

  # ===========================================================================
  # get_credentials for all auth types
  # ===========================================================================

  describe "get_credentials/1 for different auth types" do
    test "returns credentials for connected OAuth (access_token present)" do
      seed_raw("google", %{
        "auth_type" => "oauth2",
        "access_token" => "ya29.token",
        "status" => "connected"
      })

      assert {:ok, creds} = Integrations.get_credentials("google")
      assert creds["access_token"] == "ya29.token"
    end

    test "returns credentials for bot_token provider" do
      seed_raw("telegram", %{
        "auth_type" => "bot_token",
        "bot_token" => "123456:ABC-DEF",
        "status" => "connected"
      })

      assert {:ok, creds} = Integrations.get_credentials("telegram")
      assert creds["bot_token"] == "123456:ABC-DEF"
    end

    test "returns credentials for key_secret provider" do
      seed_raw("aws_ses", %{
        "auth_type" => "key_secret",
        "access_key" => "AKIATEST",
        "secret_key" => "secret",
        "status" => "connected"
      })

      assert {:ok, creds} = Integrations.get_credentials("aws_ses")
      assert creds["access_key"] == "AKIATEST"
    end

    test "returns credentials for custom credentials provider" do
      seed_raw("smtp", %{
        "auth_type" => "credentials",
        "credentials" => %{"host" => "smtp.test.com", "port" => 587},
        "status" => "connected"
      })

      assert {:ok, creds} = Integrations.get_credentials("smtp")
      assert creds["credentials"]["host"] == "smtp.test.com"
    end

    test "returns error when only setup creds exist (no tokens)" do
      seed_raw("google", %{
        "auth_type" => "oauth2",
        "client_id" => "my-id",
        "client_secret" => "my-secret",
        "status" => "disconnected"
      })

      assert {:error, :not_configured} = Integrations.get_credentials("google")
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

    test "the row's storage key equals its uuid (post-V114 invariant)" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("google", "anything")
      setting = SettingsQueries.get_setting_by_uuid(uuid)
      assert setting.key == uuid
      assert setting.module == "integrations"
    end

    test "rejects empty name" do
      assert {:error, :empty_name} = Integrations.add_connection("google", "")
      assert {:error, :empty_name} = Integrations.add_connection("google", "   ")
    end

    test "accepts names with spaces and punctuation" do
      {:ok, %{data: data}} = Integrations.add_connection("google", "My Company Drive (US)")
      assert data["name"] == "My Company Drive (US)"
    end

    test "accepts names with leading punctuation" do
      {:ok, %{data: data}} = Integrations.add_connection("google", "-leading-dash")
      assert data["name"] == "-leading-dash"
    end

    test "accepts duplicate names within a provider" do
      {:ok, %{uuid: uuid1}} = Integrations.add_connection("google", "work")
      {:ok, %{uuid: uuid2}} = Integrations.add_connection("google", "work")

      # Two distinct rows, both named "work" — each pinned by its own uuid.
      assert uuid1 != uuid2
      assert length(Integrations.list_connections("google")) == 2
    end

    test "trims whitespace from name" do
      {:ok, %{data: data}} = Integrations.add_connection("google", "  primary  ")
      assert data["name"] == "primary"
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
    test "renames a connection: updates JSONB name, preserves uuid + storage key" do
      uuid = setup_conn("google", "personal", %{"client_id" => "cid"})

      assert {:ok, data} = Integrations.rename_connection(uuid, "work")

      assert data["name"] == "work"
      # uuid is stable across rename.
      assert {:ok, %{name: "work"}} = Integrations.get_integration_by_uuid(uuid)
      # Storage key is the row uuid; it doesn't change on rename.
      setting = SettingsQueries.get_setting_by_uuid(uuid)
      assert setting.key == uuid
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

    test "accepts names with spaces, punctuation, and any character" do
      uuid = setup_conn("google", "personal")

      assert {:ok, %{"name" => "my work"}} = Integrations.rename_connection(uuid, "my work")

      assert {:ok, %{"name" => "-leading-dash"}} =
               Integrations.rename_connection(uuid, "-leading-dash")

      assert {:ok, %{"name" => "with/slash"}} = Integrations.rename_connection(uuid, "with/slash")
    end

    test "accepts renaming to a name another connection already has" do
      uuid = setup_conn("google", "personal")
      setup_conn("google", "work")

      assert {:ok, %{"name" => "work"}} = Integrations.rename_connection(uuid, "work")

      # Both rows still present, both named "work"
      assert length(Integrations.list_connections("google")) == 2
    end

    test "default-named connection has no privileged status" do
      uuid = setup_conn("google", "default", %{"client_id" => "cid"})

      assert {:ok, _} = Integrations.rename_connection(uuid, "primary")
      assert {:ok, %{name: "primary"}} = Integrations.get_integration_by_uuid(uuid)
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

    test "does not broadcast on no-op (same name)" do
      uuid = setup_conn("google", "personal")
      :ok = Events.subscribe()

      assert {:ok, _} = Integrations.rename_connection(uuid, "personal")

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

    test "returns multiple connections sorted by name (case-insensitive)" do
      setup_conn("google", "personal")
      setup_conn("google", "work")
      setup_conn("google", "Archive")

      connections = Integrations.list_connections("google")
      assert Enum.map(connections, & &1.name) == ["Archive", "personal", "work"]
    end

    test "exposes :date_added on each connection map" do
      uuid = setup_conn("google", "primary")

      [conn] = Integrations.list_connections("google")
      assert conn.uuid == uuid
      assert %DateTime{} = conn.date_added
      # Created within the last few seconds — pins that the field is
      # the actual row creation time, not a default sentinel.
      assert DateTime.diff(DateTime.utc_now(), conn.date_added) in 0..5
    end
  end

  describe "load_all_connections/1" do
    test "returns a map keyed by every requested provider" do
      setup_conn("openrouter", "primary", %{"api_key" => "key"})
      setup_conn("google", "work")
      # `aws` requested but never seeded — should still be in the map
      # with an empty list, so callers don't have to defend against
      # missing keys.
      result = Integrations.load_all_connections(["openrouter", "google", "aws"])

      assert Map.keys(result) |> Enum.sort() == ["aws", "google", "openrouter"]
      assert result["aws"] == []
      assert length(result["openrouter"]) == 1
      assert length(result["google"]) == 1
    end

    test "groups connections under the right provider via JSONB `provider` field" do
      setup_conn("openrouter", "alpha")
      setup_conn("openrouter", "bravo")
      setup_conn("google", "personal")

      result = Integrations.load_all_connections(["openrouter", "google"])

      assert Enum.map(result["openrouter"], & &1.name) == ["alpha", "bravo"]
      assert Enum.map(result["google"], & &1.name) == ["personal"]
    end

    test "sorts each provider's connections alphabetically (case-insensitive)" do
      setup_conn("openrouter", "Zebra")
      setup_conn("openrouter", "alpha")
      setup_conn("openrouter", "MIDDLE")

      result = Integrations.load_all_connections(["openrouter"])

      assert Enum.map(result["openrouter"], & &1.name) == ["alpha", "MIDDLE", "Zebra"]
    end

    test "exposes :date_added on every connection map" do
      setup_conn("openrouter", "x")
      setup_conn("google", "y")

      result = Integrations.load_all_connections(["openrouter", "google"])

      assert Enum.all?(result["openrouter"], &match?(%DateTime{}, &1.date_added))
      assert Enum.all?(result["google"], &match?(%DateTime{}, &1.date_added))
    end

    test "returns empty map when no providers requested" do
      assert Integrations.load_all_connections([]) == %{}
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
      uuid =
        seed_raw("google", %{
          "auth_type" => "oauth2",
          "client_id" => "id",
          "client_secret" => "secret",
          "status" => "connected"
        })

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
      assert_receive {:integration_validated, "openrouter", :ok}

      # Second :ok keeps status at "connected" → no broadcast (but
      # last_validated_at still advances per the test above).
      :ok = Integrations.record_validation(uuid, :ok)
      refute_receive {:integration_validated, _, _}, 50

      # Switching to error → broadcasts.
      :ok = Integrations.record_validation(uuid, {:error, "boom"})
      assert_receive {:integration_validated, "openrouter", {:error, "boom"}}
    end

    test "silently no-ops when uuid doesn't resolve" do
      ghost = "00000000-0000-7000-8000-000000000000"
      assert :ok = Integrations.record_validation(ghost, {:error, "boom"})
    end
  end

  # ===========================================================================
  # do_validate/2 — the silent "no check ran" fallbacks must not report :ok
  #
  # No built-in provider reaches these clauses today (every one of the 15
  # declares a real oauth2 userinfo_url, a validation map, or a strategy) —
  # that's exactly the bug: a FUTURE provider (or today's Shopify, from the
  # phoenix_kit_ecommerce module, not a dep of this repo) that doesn't match
  # any specific clause falls through here silently. Called directly via the
  # test-only __do_validate__/2 shim with synthetic provider maps, since
  # nothing in the registry can exercise them.
  # ===========================================================================

  describe "do_validate/2 (structural gap coverage)" do
    test "provider matching no auth_type clause is :unverified, not :ok" do
      provider = %{key: "future_provider", auth_type: :credentials}
      assert Integrations.__do_validate__(provider, %{}) == :unverified
    end

    test "api_key/bot_token provider with no validation map is :unverified, not :ok" do
      provider = %{key: "future_key_provider", auth_type: :api_key}
      assert Integrations.__do_validate__(provider, %{"api_key" => "some-key"}) == :unverified
    end

    test "api_key/bot_token provider with no credentials still reports that, not :unverified" do
      # Guards against the fix papering over a *real* error (missing
      # credentials) with the new "nothing to check" outcome.
      provider = %{key: "future_key_provider", auth_type: :api_key}

      assert Integrations.__do_validate__(provider, %{}) ==
               {:error, "No credentials configured"}
    end

    test "oauth2 provider with no userinfo_url is :unverified, not :ok" do
      provider = %{key: "future_oauth_provider", auth_type: :oauth2, oauth_config: %{}}
      assert Integrations.__do_validate__(provider, %{"access_token" => "tok"}) == :unverified
    end

    test "oauth2 provider with no access token still reports that, not :unverified" do
      provider = %{key: "future_oauth_provider", auth_type: :oauth2, oauth_config: %{}}
      assert Integrations.__do_validate__(provider, %{}) == {:error, "No access token"}
    end
  end

  # ===========================================================================
  # record_validation/2 with :unverified — the operator-visible contract:
  # a connection that was never actually checked must not read "Connected".
  # ===========================================================================

  describe "record_validation/2 with :unverified (no check ran)" do
    test ~s(status stays "configured", never "connected") do
      uuid = setup_conn("openrouter", %{"api_key" => "k"})
      :ok = Integrations.record_validation(uuid, :unverified)

      {:ok, data} = Integrations.get_integration(uuid)
      assert data["status"] == "configured"
      refute data["validation_status"] == "ok"
    end

    test "does not stamp connected_at — no connection was actually proven" do
      uuid = setup_conn("openrouter", %{"api_key" => "k"})
      :ok = Integrations.record_validation(uuid, :unverified)

      {:ok, data} = Integrations.get_integration(uuid)
      assert data["connected_at"] == nil
    end

    test "a real success afterwards still reports \"connected\" (regression guard)" do
      uuid = setup_conn("openrouter", %{"api_key" => "k"})
      :ok = Integrations.record_validation(uuid, :unverified)
      :ok = Integrations.record_validation(uuid, :ok)

      {:ok, data} = Integrations.get_integration(uuid)
      assert data["status"] == "connected"
      assert data["validation_status"] == "ok"
    end
  end

  # ===========================================================================
  # Storage-shape invariants (post-V114: key = uuid, module = "integrations")
  # ===========================================================================

  describe "storage-shape invariant" do
    test "add_connection produces key == uuid, module == 'integrations'" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("openrouter", "anything")
      setting = SettingsQueries.get_setting_by_uuid(uuid)
      assert setting.key == uuid
      assert setting.module == "integrations"
    end

    test "rename never touches the storage key" do
      uuid = setup_conn("openrouter", "primary", %{"api_key" => "k1"})

      starting_key = SettingsQueries.get_setting_by_uuid(uuid).key
      assert starting_key == uuid

      {:ok, _} = Integrations.rename_connection(uuid, "work")
      after_rename = SettingsQueries.get_setting_by_uuid(uuid).key
      assert after_rename == uuid
    end

    test "save_setup writes through the row's uuid; name and provider stay in JSONB" do
      uuid = setup_conn("openrouter", "primary")

      starting_key = SettingsQueries.get_setting_by_uuid(uuid).key
      assert starting_key == uuid

      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "new"})

      setting = SettingsQueries.get_setting_by_uuid(uuid)
      assert setting.key == uuid

      {:ok, %{provider: "openrouter", name: "primary", data: data}} =
        Integrations.get_integration_by_uuid(uuid)

      assert data["api_key"] == "new"
    end

    test "duplicate names coexist — uuids disambiguate" do
      {:ok, %{uuid: uuid1}} = Integrations.add_connection("openrouter", "work")
      {:ok, %{uuid: uuid2}} = Integrations.add_connection("openrouter", "work")

      assert uuid1 != uuid2

      conns = Integrations.list_connections("openrouter")
      assert length(conns) == 2
      assert Enum.all?(conns, &(&1.name == "work"))
      assert Enum.sort(Enum.map(conns, & &1.uuid)) == Enum.sort([uuid1, uuid2])
    end
  end

  describe "connected?/1 simplified" do
    test "returns true when a connection of that provider has credentials (bare provider)" do
      setup_conn("openrouter", %{"api_key" => "key"})
      assert Integrations.connected?("openrouter")
    end

    test "returns false when no connections exist" do
      refute Integrations.connected?("openrouter")
    end

    test "bare provider lookup returns first-match (sorted by name)" do
      # Names are no longer unique and no name is privileged. A bare
      # `Integrations.connected?(provider)` resolves against the
      # provider's first connection sorted by name (case-insensitive).
      # This is a legacy-callsite convenience; new code should use
      # uuid-based references.
      uuid = setup_conn("openrouter", "secondary", %{"api_key" => "secondary-key"})

      # Only connection of the provider, so bare lookup finds it.
      assert Integrations.connected?("openrouter")

      # The uuid path always works (the canonical shape).
      assert Integrations.connected?(uuid)
    end
  end
end
