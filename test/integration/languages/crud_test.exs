defmodule PhoenixKit.Integration.Languages.CrudTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Languages

  setup do
    {:ok, _} = Languages.enable_system()
    :ok
  end

  describe "add_language/1" do
    test "adds a predefined language" do
      assert {:ok, _config} = Languages.add_language("es-ES")

      codes = Languages.get_language_codes()
      assert "es-ES" in codes
    end

    test "new language is enabled but not default" do
      {:ok, _} = Languages.add_language("fr-FR")

      lang = Languages.get_language("fr-FR")
      assert lang.is_enabled == true
      assert lang.is_default == false
    end

    test "rejects duplicate language" do
      {:ok, _} = Languages.add_language("de-DE")
      assert {:error, "Language already exists"} = Languages.add_language("de-DE")
    end

    test "rejects unknown language code" do
      assert {:error, "Language not found in available languages"} =
               Languages.add_language("xx-INVALID")
    end

    test "en-US already exists by default" do
      assert {:error, "Language already exists"} = Languages.add_language("en-US")
    end
  end

  describe "remove_language/1" do
    setup do
      {:ok, _} = Languages.add_language("es-ES")
      :ok
    end

    test "removes a non-default language" do
      assert {:ok, _} = Languages.remove_language("es-ES")
      refute "es-ES" in Languages.get_language_codes()
    end

    test "cannot remove the default language" do
      assert {:error, "Cannot remove default language"} = Languages.remove_language("en-US")
    end

    test "cannot remove the last language" do
      # Remove es-ES, leaving only en-US (the default)
      {:ok, _} = Languages.remove_language("es-ES")
      assert {:error, "Cannot remove default language"} = Languages.remove_language("en-US")
    end

    test "returns error for unknown language" do
      assert {:error, "Language not found"} = Languages.remove_language("nonexistent")
    end
  end

  describe "reorder_languages/1" do
    setup do
      {:ok, _} = Languages.add_language("es-ES")
      {:ok, _} = Languages.add_language("fr-FR")
      {:ok, _} = Languages.add_language("de-DE")
      :ok
    end

    test "reorders languages to match the given codes" do
      assert {:ok, _} = Languages.reorder_languages(["de-DE", "fr-FR", "es-ES", "en-US"])
      assert Languages.get_language_codes() == ["de-DE", "fr-FR", "es-ES", "en-US"]
    end

    test "languages not in the list keep their relative order at the end" do
      assert {:ok, _} = Languages.reorder_languages(["fr-FR", "de-DE"])
      codes = Languages.get_language_codes()
      assert Enum.take(codes, 2) == ["fr-FR", "de-DE"]
      # en-US and es-ES preserve their pre-reorder relative order
      assert Enum.drop(codes, 2) == ["en-US", "es-ES"]
    end

    test "unknown codes in the list are ignored" do
      assert {:ok, _} = Languages.reorder_languages(["xx-YY", "de-DE", "zz-ZZ"])
      codes = Languages.get_language_codes()
      assert hd(codes) == "de-DE"
      refute "xx-YY" in codes
      refute "zz-ZZ" in codes
    end

    test "empty list leaves order unchanged" do
      before = Languages.get_language_codes()
      assert {:ok, _} = Languages.reorder_languages([])
      assert Languages.get_language_codes() == before
    end

    test "duplicate codes in the list are deduped to the first occurrence" do
      assert {:ok, _} = Languages.reorder_languages(["de-DE", "fr-FR", "de-DE"])
      codes = Languages.get_language_codes()
      assert Enum.count(codes, &(&1 == "de-DE")) == 1
      assert Enum.take(codes, 2) == ["de-DE", "fr-FR"]
    end
  end

  describe "set_default_language/1" do
    setup do
      {:ok, _} = Languages.add_language("fr-FR")
      :ok
    end

    test "changes the default language" do
      assert {:ok, _} = Languages.set_default_language("fr-FR")

      default = Languages.get_default_language()
      assert default.code == "fr-FR"
      assert default.is_default == true
    end

    test "old default loses is_default flag" do
      {:ok, _} = Languages.set_default_language("fr-FR")

      en = Languages.get_language("en-US")
      assert en.is_default == false
    end

    test "returns error for unknown language" do
      assert {:error, "Language not found"} = Languages.set_default_language("nonexistent")
    end
  end

  describe "enable_language/1 and disable_language/1" do
    setup do
      {:ok, _} = Languages.add_language("it")
      :ok
    end

    test "disables a non-default language" do
      assert {:ok, _} = Languages.disable_language("it")

      lang = Languages.get_language("it")
      assert lang.is_enabled == false
    end

    test "disabled language excluded from get_enabled_languages" do
      {:ok, _} = Languages.disable_language("it")

      enabled_codes = Languages.get_enabled_language_codes()
      refute "it" in enabled_codes
    end

    test "re-enables a disabled language" do
      {:ok, _} = Languages.disable_language("it")
      assert {:ok, _} = Languages.enable_language("it")

      lang = Languages.get_language("it")
      assert lang.is_enabled == true
    end

    test "cannot disable the default language" do
      assert {:error, "Cannot disable default language"} = Languages.disable_language("en-US")
    end
  end

  describe "move_language_up/1 and move_language_down/1" do
    setup do
      {:ok, _} = Languages.add_language("es-ES")
      {:ok, _} = Languages.add_language("fr-FR")
      # Order is now: en-US, es-ES, fr-FR
      :ok
    end

    test "moves a language up in the list" do
      assert {:ok, _} = Languages.move_language_up("es-ES")

      codes = Languages.get_language_codes()
      assert Enum.at(codes, 0) == "es-ES"
      assert Enum.at(codes, 1) == "en-US"
    end

    test "cannot move first language up" do
      assert {:error, "Language is already at the top"} = Languages.move_language_up("en-US")
    end

    test "moves a language down in the list" do
      assert {:ok, _} = Languages.move_language_down("en-US")

      codes = Languages.get_language_codes()
      assert Enum.at(codes, 0) == "es-ES"
      assert Enum.at(codes, 1) == "en-US"
    end

    test "cannot move last language down" do
      assert {:error, "Language is already at the bottom"} = Languages.move_language_down("fr-FR")
    end

    test "returns error for unknown language" do
      assert {:error, "Language not found"} = Languages.move_language_up("nonexistent")
      assert {:error, "Language not found"} = Languages.move_language_down("nonexistent")
    end
  end

  describe "get_config/0" do
    test "returns complete config summary" do
      {:ok, _} = Languages.add_language("ja")

      config = Languages.get_config()
      assert config.enabled == true
      assert config.language_count >= 2
      assert config.enabled_count >= 2
      assert config.default_language != nil
      assert config.default_language.code == "en-US"
    end
  end

  describe "query functions with enabled system" do
    setup do
      {:ok, _} = Languages.add_language("ja")
      {:ok, _} = Languages.add_language("de-DE")
      :ok
    end

    test "get_languages returns all configured languages" do
      langs = Languages.get_languages()
      codes = Enum.map(langs, & &1.code)
      assert "en-US" in codes
      assert "ja" in codes
      assert "de-DE" in codes
    end

    test "get_enabled_languages returns only enabled" do
      {:ok, _} = Languages.disable_language("ja")

      enabled = Languages.get_enabled_languages()
      codes = Enum.map(enabled, & &1.code)
      assert "en-US" in codes
      assert "de-DE" in codes
      refute "ja" in codes
    end

    test "get_language returns specific language" do
      lang = Languages.get_language("ja")
      assert lang.code == "ja"
      assert is_binary(lang.name)
    end

    test "get_language returns nil for unknown code" do
      assert Languages.get_language("nonexistent") == nil
    end

    test "valid_language? checks existence" do
      assert Languages.valid_language?("ja")
      refute Languages.valid_language?("nonexistent")
    end

    test "language_enabled? checks both existence and enabled status" do
      assert Languages.language_enabled?("ja")

      {:ok, _} = Languages.disable_language("ja")
      refute Languages.language_enabled?("ja")
    end

    test "enabled_locale_codes returns enabled codes" do
      codes = Languages.enabled_locale_codes()
      assert is_list(codes)
      assert "en-US" in codes
    end
  end

  describe "system enable/disable cycle" do
    test "disable preserves config, re-enable restores it" do
      {:ok, _} = Languages.add_language("ko")
      assert "ko" in Languages.get_language_codes()

      # Disable
      {:ok, _} = Languages.disable_system()
      refute Languages.enabled?()
      assert Languages.get_languages() == []

      # Re-enable — config should be preserved
      {:ok, _} = Languages.enable_system()
      assert Languages.enabled?()
      assert "ko" in Languages.get_language_codes()
    end
  end
end
