defmodule PhoenixKit.Integrations.ProvidersTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Integrations.Providers

  describe "all/0" do
    test "returns a list of provider maps" do
      providers = Providers.all()
      assert is_list(providers)
      assert length(providers) >= 2
    end

    test "includes google provider" do
      providers = Providers.all()
      google = Enum.find(providers, &(&1.key == "google"))
      assert google != nil
      assert google.name == "Google"
      assert google.auth_type == :oauth2
      assert google.oauth_config != nil
      assert google.oauth_config[:auth_url] =~ "accounts.google.com"
      assert google.oauth_config[:token_url] =~ "oauth2.googleapis.com"
      assert google.oauth_config[:userinfo_url] =~ "googleapis.com/oauth2"
    end

    test "includes openrouter provider" do
      providers = Providers.all()
      openrouter = Enum.find(providers, &(&1.key == "openrouter"))
      assert openrouter != nil
      assert openrouter.name == "OpenRouter"
      assert openrouter.auth_type == :api_key
      assert openrouter.oauth_config == nil
    end

    test "google has required setup fields" do
      google = Providers.get("google")
      field_keys = Enum.map(google.setup_fields, & &1.key)
      assert "client_id" in field_keys
      assert "client_secret" in field_keys
    end

    test "openrouter has required setup fields" do
      openrouter = Providers.get("openrouter")
      field_keys = Enum.map(openrouter.setup_fields, & &1.key)
      assert "api_key" in field_keys
    end

    test "all providers have required keys" do
      for provider <- Providers.all() do
        assert is_binary(provider.key), "provider missing key"
        assert is_binary(provider.name), "#{provider.key} missing name"
        assert is_binary(provider.description), "#{provider.key} missing description"
        assert is_binary(provider.icon), "#{provider.key} missing icon"
        assert provider.auth_type in [:oauth2, :api_key, :key_secret, :bot_token, :credentials]
        assert is_list(provider.setup_fields), "#{provider.key} missing setup_fields"
        assert is_list(provider.capabilities), "#{provider.key} missing capabilities"
      end
    end
  end

  describe "get/1" do
    test "returns provider for known key" do
      assert %{key: "google"} = Providers.get("google")
      assert %{key: "openrouter"} = Providers.get("openrouter")
    end

    test "returns nil for unknown key" do
      assert Providers.get("nonexistent") == nil
      assert Providers.get("") == nil
    end
  end

  describe "used_by_modules/0" do
    test "returns a map" do
      result = Providers.used_by_modules()
      assert is_map(result)
    end
  end

  describe "clear_cache/0" do
    test "clears and repopulates on next call" do
      # Populate cache
      providers1 = Providers.all()
      assert is_list(providers1)

      # Clear
      :ok = Providers.clear_cache()

      # Should repopulate
      providers2 = Providers.all()
      assert providers1 == providers2
    end

    test "safe to call when cache is empty" do
      Providers.clear_cache()
      assert :ok = Providers.clear_cache()
    end
  end
end
