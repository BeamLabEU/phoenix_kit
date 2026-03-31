defmodule PhoenixKit.Integration.Languages.NormalizeTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings

  describe "normalize_language_settings/0" do
    test "no-op when admin_languages setting does not exist" do
      assert :ok = Languages.normalize_language_settings()
    end

    test "no-op when admin_languages is already empty" do
      Settings.update_setting("admin_languages", "[]")

      assert :ok = Languages.normalize_language_settings()
    end

    test "no-op when admin_languages contains invalid JSON" do
      Settings.update_setting("admin_languages", "not json")

      assert :ok = Languages.normalize_language_settings()
    end

    test "no-op when admin_languages is an empty JSON object" do
      Settings.update_setting("admin_languages", "{}")

      assert :ok = Languages.normalize_language_settings()
    end

    test "enables Languages module and merges admin-only languages" do
      # Disable the system first
      Languages.disable_system()
      refute Languages.enabled?()

      # Set up legacy admin_languages with codes
      Settings.update_setting("admin_languages", Jason.encode!(["en-US", "es-ES"]))

      # Normalize
      assert :ok = Languages.normalize_language_settings()

      # System should now be enabled
      assert Languages.enabled?()

      # Both languages should be in the unified config
      codes = Languages.get_language_codes()
      assert "en-US" in codes
      assert "es-ES" in codes

      # Legacy setting should be cleared
      assert Settings.get_setting("admin_languages") == "[]"
    end

    test "does not duplicate languages already in config" do
      # Enable with default English
      {:ok, _} = Languages.enable_system()

      # Set admin_languages to include en-US (already exists) and es-ES (new)
      Settings.update_setting("admin_languages", Jason.encode!(["en-US", "es-ES"]))

      # Normalize
      assert :ok = Languages.normalize_language_settings()

      # en-US should appear only once
      codes = Languages.get_language_codes()
      assert Enum.count(codes, &(&1 == "en-US")) == 1
      assert "es-ES" in codes
    end

    test "is idempotent — running twice produces same result" do
      {:ok, _} = Languages.enable_system()
      Settings.update_setting("admin_languages", Jason.encode!(["en-US", "fr-FR"]))

      assert :ok = Languages.normalize_language_settings()
      codes_after_first = Languages.get_language_codes()

      # Second run — admin_languages is now "[]", should be no-op
      assert :ok = Languages.normalize_language_settings()
      codes_after_second = Languages.get_language_codes()

      assert codes_after_first == codes_after_second
    end

    test "skips invalid language codes gracefully" do
      {:ok, _} = Languages.enable_system()

      # Include a valid code and an invalid one
      Settings.update_setting(
        "admin_languages",
        Jason.encode!(["en-US", "xx-INVALID-CODE"])
      )

      # Should not crash
      assert :ok = Languages.normalize_language_settings()

      # Valid language should be present, invalid one silently skipped
      codes = Languages.get_language_codes()
      assert "en-US" in codes
    end
  end
end
