defmodule PhoenixKit.Modules.Entities.MultilangTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Entities.Multilang

  # --- Test Data ---

  defp multilang_data do
    %{
      "_primary_language" => "en-US",
      "en-US" => %{"name" => "Acme", "category" => "Tech", "desc" => "A company"},
      "es-ES" => %{"name" => "Acme España"},
      "fr-FR" => %{"desc" => "Une entreprise"}
    }
  end

  defp flat_data do
    %{"name" => "Acme", "category" => "Tech"}
  end

  # --- multilang_data?/1 ---

  describe "multilang_data?/1" do
    test "returns true for data with _primary_language key" do
      assert Multilang.multilang_data?(multilang_data())
    end

    test "returns false for flat data" do
      refute Multilang.multilang_data?(flat_data())
    end

    test "returns false for nil" do
      refute Multilang.multilang_data?(nil)
    end

    test "returns false for empty map" do
      refute Multilang.multilang_data?(%{})
    end

    test "returns false for non-map values" do
      refute Multilang.multilang_data?("string")
      refute Multilang.multilang_data?(42)
      refute Multilang.multilang_data?([])
    end
  end

  # --- get_language_data/2 ---

  describe "get_language_data/2" do
    test "returns primary data for primary language" do
      result = Multilang.get_language_data(multilang_data(), "en-US")

      assert result == %{
               "name" => "Acme",
               "category" => "Tech",
               "desc" => "A company"
             }
    end

    test "returns merged data for secondary language" do
      result = Multilang.get_language_data(multilang_data(), "es-ES")

      assert result == %{
               "name" => "Acme España",
               "category" => "Tech",
               "desc" => "A company"
             }
    end

    test "secondary language overrides only differ from primary" do
      result = Multilang.get_language_data(multilang_data(), "fr-FR")

      assert result == %{
               "name" => "Acme",
               "category" => "Tech",
               "desc" => "Une entreprise"
             }
    end

    test "returns primary data for language with no overrides" do
      result = Multilang.get_language_data(multilang_data(), "de-DE")

      assert result == %{
               "name" => "Acme",
               "category" => "Tech",
               "desc" => "A company"
             }
    end

    test "returns flat data as-is for non-multilang data" do
      result = Multilang.get_language_data(flat_data(), "en-US")
      assert result == flat_data()
    end

    test "returns empty map for nil data" do
      assert Multilang.get_language_data(nil, "en-US") == %{}
    end
  end

  # --- get_primary_data/1 ---

  describe "get_primary_data/1" do
    test "extracts primary language data from multilang" do
      result = Multilang.get_primary_data(multilang_data())

      assert result == %{
               "name" => "Acme",
               "category" => "Tech",
               "desc" => "A company"
             }
    end

    test "returns flat data as-is" do
      assert Multilang.get_primary_data(flat_data()) == flat_data()
    end

    test "returns empty map for nil" do
      assert Multilang.get_primary_data(nil) == %{}
    end
  end

  # --- get_raw_language_data/2 ---

  describe "get_raw_language_data/2" do
    test "returns raw primary data (all fields)" do
      result = Multilang.get_raw_language_data(multilang_data(), "en-US")

      assert result == %{
               "name" => "Acme",
               "category" => "Tech",
               "desc" => "A company"
             }
    end

    test "returns raw overrides only for secondary language" do
      result = Multilang.get_raw_language_data(multilang_data(), "es-ES")
      assert result == %{"name" => "Acme España"}
    end

    test "returns empty map for language with no overrides" do
      result = Multilang.get_raw_language_data(multilang_data(), "de-DE")
      assert result == %{}
    end

    test "returns flat data as-is for non-multilang" do
      result = Multilang.get_raw_language_data(flat_data(), "en-US")
      assert result == flat_data()
    end

    test "returns empty map for nil" do
      assert Multilang.get_raw_language_data(nil, "en-US") == %{}
    end
  end

  # --- put_language_data/3 ---

  describe "put_language_data/3" do
    test "stores all fields for primary language" do
      new_fields = %{"name" => "Acme Corp", "category" => "Business", "desc" => "Updated"}
      result = Multilang.put_language_data(multilang_data(), "en-US", new_fields)

      assert result["_primary_language"] == "en-US"
      assert result["en-US"] == new_fields
      # Other languages preserved
      assert result["es-ES"] == %{"name" => "Acme España"}
    end

    test "stores only overrides for secondary language" do
      new_fields = %{"name" => "Acme Frankreich", "category" => "Tech", "desc" => "A company"}
      result = Multilang.put_language_data(multilang_data(), "de-DE", new_fields)

      # Only "name" differs from primary, so only "name" is stored
      assert result["de-DE"] == %{"name" => "Acme Frankreich"}
    end

    test "removes secondary language key when all fields match primary" do
      # Submit exact same data as primary
      primary_data = %{"name" => "Acme", "category" => "Tech", "desc" => "A company"}
      result = Multilang.put_language_data(multilang_data(), "es-ES", primary_data)

      refute Map.has_key?(result, "es-ES")
    end

    test "removes secondary language key when all fields are empty" do
      result =
        Multilang.put_language_data(multilang_data(), "es-ES", %{"name" => "", "category" => ""})

      refute Map.has_key?(result, "es-ES")
    end

    test "converts flat data to multilang structure on first put" do
      result = Multilang.put_language_data(flat_data(), "en-US", %{"name" => "Updated"})

      assert Multilang.multilang_data?(result)
      assert result["en-US"] == %{"name" => "Updated"}
    end

    test "handles nil existing data" do
      result = Multilang.put_language_data(nil, "en-US", %{"name" => "New"})

      assert Multilang.multilang_data?(result)
    end

    test "uses embedded primary for existing multilang data" do
      data = multilang_data()
      new_es = %{"name" => "Nuevo Nombre", "category" => "Tech", "desc" => "A company"}
      result = Multilang.put_language_data(data, "es-ES", new_es)

      # Only the override (name) should be stored
      assert result["es-ES"] == %{"name" => "Nuevo Nombre"}
      # Primary unchanged
      assert result["_primary_language"] == "en-US"
    end
  end

  # --- migrate_to_multilang/2 ---

  describe "migrate_to_multilang/2" do
    test "wraps flat data into multilang structure" do
      result = Multilang.migrate_to_multilang(flat_data(), "en-US")

      assert result["_primary_language"] == "en-US"
      assert result["en-US"] == flat_data()
    end

    test "handles nil data" do
      result = Multilang.migrate_to_multilang(nil, "en-US")

      assert result["_primary_language"] == "en-US"
      assert result["en-US"] == %{}
    end

    test "uses provided language code" do
      result = Multilang.migrate_to_multilang(flat_data(), "es-ES")

      assert result["_primary_language"] == "es-ES"
      assert result["es-ES"] == flat_data()
    end
  end

  # --- flatten_to_primary/1 ---

  describe "flatten_to_primary/1" do
    test "extracts primary language data" do
      result = Multilang.flatten_to_primary(multilang_data())

      assert result == %{
               "name" => "Acme",
               "category" => "Tech",
               "desc" => "A company"
             }
    end

    test "returns flat data as-is (no _primary_language key)" do
      assert Multilang.flatten_to_primary(flat_data()) == flat_data()
    end

    test "returns empty map for nil" do
      assert Multilang.flatten_to_primary(nil) == %{}
    end

    test "returns empty map for non-map input" do
      assert Multilang.flatten_to_primary("string") == %{}
    end

    test "handles missing primary language data gracefully" do
      data = %{"_primary_language" => "ja-JP"}
      assert Multilang.flatten_to_primary(data) == %{}
    end
  end

  # --- rekey_primary/2 ---

  describe "rekey_primary/2" do
    test "promotes new primary with all fields from old primary" do
      result = Multilang.rekey_primary(multilang_data(), "es-ES")

      assert result["_primary_language"] == "es-ES"

      # New primary gets merged: old primary base + its own overrides
      assert result["es-ES"] == %{
               "name" => "Acme España",
               "category" => "Tech",
               "desc" => "A company"
             }
    end

    test "preserves old primary data untouched" do
      result = Multilang.rekey_primary(multilang_data(), "es-ES")

      # Old primary still has its original data
      assert result["en-US"] == %{
               "name" => "Acme",
               "category" => "Tech",
               "desc" => "A company"
             }
    end

    test "preserves other languages untouched" do
      result = Multilang.rekey_primary(multilang_data(), "es-ES")
      assert result["fr-FR"] == %{"desc" => "Une entreprise"}
    end

    test "returns data unchanged when already using that primary" do
      result = Multilang.rekey_primary(multilang_data(), "en-US")
      assert result == multilang_data()
    end

    test "returns non-multilang data unchanged" do
      result = Multilang.rekey_primary(flat_data(), "es-ES")
      assert result == flat_data()
    end

    test "returns nil unchanged" do
      assert Multilang.rekey_primary(nil, "es-ES") == nil
    end

    test "re-keys to language with no existing overrides" do
      result = Multilang.rekey_primary(multilang_data(), "de-DE")

      assert result["_primary_language"] == "de-DE"

      # de-DE gets all fields from old primary (no overrides existed)
      assert result["de-DE"] == %{
               "name" => "Acme",
               "category" => "Tech",
               "desc" => "A company"
             }
    end

    test "is idempotent" do
      once = Multilang.rekey_primary(multilang_data(), "es-ES")
      twice = Multilang.rekey_primary(once, "es-ES")
      assert once == twice
    end

    test "round-trip preserves all data" do
      rekeyed = Multilang.rekey_primary(multilang_data(), "es-ES")
      back = Multilang.rekey_primary(rekeyed, "en-US")

      # Primary data should be fully restored
      assert back["_primary_language"] == "en-US"

      assert back["en-US"] == %{
               "name" => "Acme",
               "category" => "Tech",
               "desc" => "A company"
             }
    end
  end

  # --- maybe_rekey_data/1 ---
  # Note: In test env without Languages module DB, primary_language() falls
  # back to "en-US". So data with embedded "en-US" is a no-op, while data
  # with any other embedded primary will be re-keyed to "en-US".

  describe "maybe_rekey_data/1" do
    test "re-keys when embedded primary differs from global" do
      # Embedded is "es-ES", global fallback is "en-US" → should re-key
      data = %{
        "_primary_language" => "es-ES",
        "es-ES" => %{"name" => "Acme España", "category" => "Tech"},
        "en-US" => %{"name" => "Acme"}
      }

      result = Multilang.maybe_rekey_data(data)

      assert result["_primary_language"] == "en-US"
      # New primary promoted with all fields from old primary
      assert result["en-US"] == %{"name" => "Acme", "category" => "Tech"}
    end

    test "returns data unchanged when already using global primary" do
      # Embedded is "en-US" which matches the fallback global
      result = Multilang.maybe_rekey_data(multilang_data())

      assert result == multilang_data()
    end

    test "returns non-multilang data unchanged" do
      result = Multilang.maybe_rekey_data(flat_data())
      assert result == flat_data()
    end

    test "returns nil unchanged" do
      assert Multilang.maybe_rekey_data(nil) == nil
    end
  end

  # --- Integration: migrate then put ---

  describe "migrate + put workflow" do
    test "flat data -> multilang -> add secondary" do
      data = flat_data()
      multilang = Multilang.migrate_to_multilang(data, "en-US")

      assert Multilang.multilang_data?(multilang)

      result =
        Multilang.put_language_data(multilang, "es-ES", %{
          "name" => "Acme España",
          "category" => "Tech"
        })

      # Only name differs, category matches primary
      assert result["es-ES"] == %{"name" => "Acme España"}
      assert result["en-US"] == flat_data()
    end

    test "get_language_data returns correct merged result after put" do
      data = multilang_data()

      updated =
        Multilang.put_language_data(data, "de-DE", %{
          "name" => "Acme DE",
          "category" => "Tech",
          "desc" => "A company"
        })

      result = Multilang.get_language_data(updated, "de-DE")

      assert result["name"] == "Acme DE"
      assert result["category"] == "Tech"
      assert result["desc"] == "A company"
    end
  end
end
