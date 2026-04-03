defmodule PhoenixKit.Utils.MultilangTest do
  use ExUnit.Case

  alias PhoenixKit.Utils.Multilang

  @primary_key "_primary_language"

  describe "multilang_data?/1" do
    test "returns true when _primary_language key exists" do
      assert Multilang.multilang_data?(%{@primary_key => "en-US", "en-US" => %{"name" => "Test"}})
    end

    test "returns false for flat data" do
      refute Multilang.multilang_data?(%{"name" => "Test"})
    end

    test "returns false for nil" do
      refute Multilang.multilang_data?(nil)
    end

    test "returns false for non-map" do
      refute Multilang.multilang_data?("string")
      refute Multilang.multilang_data?(123)
    end
  end

  describe "get_language_data/2" do
    test "returns primary data for primary language" do
      data = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme", "tagline" => "Quality"}
      }

      result = Multilang.get_language_data(data, "en-US")
      assert result["name"] == "Acme"
      assert result["tagline"] == "Quality"
    end

    test "merges primary with overrides for secondary language" do
      data = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme", "tagline" => "Quality"},
        "es-ES" => %{"name" => "Acme España"}
      }

      result = Multilang.get_language_data(data, "es-ES")
      assert result["name"] == "Acme España"
      # Inherited from primary
      assert result["tagline"] == "Quality"
    end

    test "returns empty map for missing language" do
      data = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme"}
      }

      result = Multilang.get_language_data(data, "fr-FR")
      # Falls back to primary data (merge with empty map)
      assert result["name"] == "Acme"
    end

    test "returns flat data as-is for non-multilang" do
      data = %{"name" => "Acme"}
      assert Multilang.get_language_data(data, "en-US") == data
    end

    test "returns empty map for nil" do
      assert Multilang.get_language_data(nil, "en-US") == %{}
    end
  end

  describe "get_primary_data/1" do
    test "extracts primary language data" do
      data = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme"},
        "es-ES" => %{"name" => "Acme ES"}
      }

      assert Multilang.get_primary_data(data) == %{"name" => "Acme"}
    end

    test "returns flat data as-is for non-multilang" do
      data = %{"name" => "Acme"}
      assert Multilang.get_primary_data(data) == data
    end

    test "returns empty map for nil" do
      assert Multilang.get_primary_data(nil) == %{}
    end
  end

  describe "get_raw_language_data/2" do
    test "returns only language-specific overrides without merging" do
      data = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme", "tagline" => "Quality"},
        "es-ES" => %{"name" => "Acme ES"}
      }

      result = Multilang.get_raw_language_data(data, "es-ES")
      assert result == %{"name" => "Acme ES"}
      # tagline NOT present because it's inherited, not overridden
      refute Map.has_key?(result, "tagline")
    end

    test "returns empty map for missing language" do
      data = %{@primary_key => "en-US", "en-US" => %{"name" => "Acme"}}
      assert Multilang.get_raw_language_data(data, "fr-FR") == %{}
    end
  end

  describe "put_language_data/3" do
    test "stores all fields for primary language" do
      result = Multilang.put_language_data(nil, "en-US", %{"name" => "Acme"})
      assert result[@primary_key] == "en-US"
      assert result["en-US"]["name"] == "Acme"
    end

    test "stores only overrides for secondary language" do
      existing = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme", "tagline" => "Quality"}
      }

      result =
        Multilang.put_language_data(existing, "es-ES", %{
          "name" => "Acme ES",
          "tagline" => "Quality"
        })

      # tagline matches primary, should NOT be stored
      assert result["es-ES"] == %{"name" => "Acme ES"}
    end

    test "removes secondary language entry when no overrides" do
      existing = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme"},
        "es-ES" => %{"name" => "Acme ES"}
      }

      # Set secondary to match primary exactly
      result = Multilang.put_language_data(existing, "es-ES", %{"name" => "Acme"})
      refute Map.has_key?(result, "es-ES")
    end

    test "converts flat data to multilang on first write" do
      flat = %{"name" => "Acme"}
      result = Multilang.put_language_data(flat, "en-US", %{"name" => "Updated"})

      assert Multilang.multilang_data?(result)
      assert result[@primary_key] == "en-US"
      assert result["en-US"]["name"] == "Updated"
    end
  end

  describe "migrate_to_multilang/2" do
    test "wraps flat data with primary language marker" do
      result = Multilang.migrate_to_multilang(%{"name" => "Acme"}, "en-US")
      assert result[@primary_key] == "en-US"
      assert result["en-US"] == %{"name" => "Acme"}
    end

    test "handles nil data" do
      result = Multilang.migrate_to_multilang(nil, "en-US")
      assert result[@primary_key] == "en-US"
      assert result["en-US"] == %{}
    end
  end

  describe "flatten_to_primary/1" do
    test "extracts primary language data" do
      data = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme"},
        "es-ES" => %{"name" => "Acme ES"}
      }

      assert Multilang.flatten_to_primary(data) == %{"name" => "Acme"}
    end

    test "returns non-multilang data as-is" do
      data = %{"name" => "Acme"}
      assert Multilang.flatten_to_primary(data) == data
    end

    test "returns empty map for nil" do
      assert Multilang.flatten_to_primary(nil) == %{}
    end
  end

  describe "rekey_primary/2" do
    test "promotes new primary with complete data" do
      data = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme", "tagline" => "Quality"},
        "es-ES" => %{"name" => "Acme ES"}
      }

      result = Multilang.rekey_primary(data, "es-ES")
      assert result[@primary_key] == "es-ES"
      # Promoted: has both name override and inherited tagline
      assert result["es-ES"]["name"] == "Acme ES"
      assert result["es-ES"]["tagline"] == "Quality"
    end

    test "old primary becomes secondary with overrides only" do
      data = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme", "tagline" => "Quality"},
        "es-ES" => %{"name" => "Acme ES"}
      }

      result = Multilang.rekey_primary(data, "es-ES")
      # en-US now a secondary — "tagline" matches new primary, so only "name" is an override
      assert result["en-US"]["name"] == "Acme"
      refute Map.has_key?(result["en-US"], "tagline")
    end

    test "removes secondary with zero overrides after rekey" do
      data = %{
        @primary_key => "en-US",
        "en-US" => %{"name" => "Acme"},
        "es-ES" => %{"name" => "Acme"}
      }

      result = Multilang.rekey_primary(data, "es-ES")
      # en-US had same data as promoted es-ES, so it should be removed
      refute Map.has_key?(result, "en-US")
    end

    test "returns data unchanged if already the primary" do
      data = %{@primary_key => "en-US", "en-US" => %{"name" => "Acme"}}
      assert Multilang.rekey_primary(data, "en-US") == data
    end

    test "returns non-multilang data unchanged" do
      data = %{"name" => "Acme"}
      assert Multilang.rekey_primary(data, "en-US") == data
    end

    test "returns nil unchanged" do
      assert Multilang.rekey_primary(nil, "en-US") == nil
    end
  end
end
