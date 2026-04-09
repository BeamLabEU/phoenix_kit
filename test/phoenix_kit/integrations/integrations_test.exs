defmodule PhoenixKit.Integrations.IntegrationsTest do
  @moduledoc """
  Unit tests for the Integrations context (no DB required).
  See test/integration/integrations_test.exs for full DB integration tests.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Integrations

  describe "settings_key/1" do
    test "returns prefixed key with default name" do
      assert Integrations.settings_key("google") == "integration:google:default"
      assert Integrations.settings_key("openrouter") == "integration:openrouter:default"
    end

    test "returns prefixed key with explicit name" do
      assert Integrations.settings_key("google:personal") == "integration:google:personal"

      assert Integrations.settings_key("openrouter:secondary") ==
               "integration:openrouter:secondary"
    end
  end

  describe "settings_key/1 with names" do
    test "supports names with spaces and special characters" do
      assert Integrations.settings_key("google:My Company Drive") ==
               "integration:google:My Company Drive"
    end
  end

  describe "validate_connection/1 (no DB)" do
    test "returns error for invalid input" do
      assert {:error, _} = Integrations.validate_connection("")
    end
  end

  describe "list_providers/0" do
    test "returns a list of provider maps" do
      providers = Integrations.list_providers()
      assert is_list(providers)
      assert length(providers) >= 2
      keys = Enum.map(providers, & &1.key)
      assert "google" in keys
      assert "openrouter" in keys
    end
  end
end
