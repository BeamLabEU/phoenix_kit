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
    test "dialect locale resolves bare-code translations (tim-dev shape)" do
      # Host registers bare codes (primary "et", translations under
      # "en"), but the locale pipeline resolves /en/ URLs to "en-US".
      data = %{
        "_primary_language" => "et",
        "et" => %{"_name" => "KORVID"},
        "en" => %{"_name" => "BASKETS"}
      }

      assert Multilang.get_language_data(data, "en-US")["_name"] == "BASKETS"
      # And the reverse: dialect-stored translations found via bare code.
      dialect_data = %{
        "_primary_language" => "et",
        "et" => %{"_name" => "KORVID"},
        "en-GB" => %{"_name" => "BASKETS"}
      }

      assert Multilang.get_language_data(dialect_data, "en")["_name"] == "BASKETS"
      # A dialect of the PRIMARY language returns the primary data.
      assert Multilang.get_language_data(data, "et-EE")["_name"] == "KORVID"
      # Unrelated locales still merge to the primary base.
      assert Multilang.get_language_data(data, "fr")["_name"] == "KORVID"
    end

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
    test "explicit rekey still works same-base; get_primary_data survives key drift (sweep)" do
      # An EXPLICIT same-base rekey still works (maybe_rekey_data's
      # skip is host-settings-gated and covered by the code path, not
      # drivable here without the settings DB).
      data = %{"_primary_language" => "en", "en" => %{"_name" => "X"}}
      assert Multilang.rekey_primary(data, "en-US")["_primary_language"] == "en-US"

      # get_primary_data falls back across siblings when the embedded
      # marker's exact key is missing.
      drifted = %{"_primary_language" => "en-US", "en" => %{"_name" => "X"}}
      assert Multilang.get_primary_data(drifted)["_name"] == "X"
    end

    test "sibling fallback is deterministic and primary-preferring (sweep)" do
      # Multiple entries share a base: the PRIMARY entry wins the
      # fallback (complete field set), never map iteration order.
      data = %{
        "_primary_language" => "en-US",
        "en-US" => %{"_name" => "Primary"},
        "en-GB" => %{"_name" => "Override"}
      }

      assert Multilang.get_language_data(data, "en-AU")["_name"] == "Primary"

      # Without a same-base primary, the lexicographically first sibling.
      data2 = %{
        "_primary_language" => "et",
        "et" => %{"_name" => "Eesti"},
        "en-US" => %{"_name" => "US"},
        "en-GB" => %{"_name" => "GB"}
      }

      assert Multilang.get_language_data(data2, "en-AU")["_name"] == "GB"
    end

    test "rekey_primary leaves no same-base ghost override (sweep)" do
      # en → en-US rekey: the old primary key must not survive as an
      # override, or it hijacks the base fallback for every en-* viewer.
      data = %{
        "_primary_language" => "en",
        "en" => %{"_name" => "Old"},
        "en-US" => %{"_name" => "New"},
        "et" => %{"_name" => "Eesti"}
      }

      rekeyed = Multilang.rekey_primary(data, "en-US")
      assert rekeyed["_primary_language"] == "en-US"
      assert rekeyed["en-US"]["_name"] == "New"
      refute Map.has_key?(rekeyed, "en")
      # Unrelated languages recompute normally.
      assert rekeyed["et"]["_name"] == "Eesti"
      assert Multilang.get_language_data(rekeyed, "en-GB")["_name"] == "New"
    end

    test "write normalization across code shapes (bulletproofing sweep)" do
      # A primary-tab save arriving under a dialect sibling of the
      # record's embedded primary updates the PRIMARY entry — no forked
      # override, no stale reads.
      data = %{"_primary_language" => "en-US", "en-US" => %{"_name" => "Old"}}
      updated = Multilang.put_language_data(data, "en", %{"_name" => "New"})
      assert updated["en-US"]["_name"] == "New"
      refute Map.has_key?(updated, "en")

      # A secondary write drops dialect-sibling entries of its language,
      # so one base language never carries two racing entries.
      mixed = %{
        "_primary_language" => "et",
        "et" => %{"_name" => "KORVID"},
        "en-GB" => %{"_name" => "Hampers"}
      }

      updated = Multilang.put_language_data(mixed, "en", %{"_name" => "Baskets"})
      assert updated["en"]["_name"] == "Baskets"
      refute Map.has_key?(updated, "en-GB")

      # And clearing an override also clears its siblings.
      cleared = Multilang.put_language_data(mixed, "en", %{"_name" => "KORVID"})
      refute Map.has_key?(cleared, "en")
      refute Map.has_key?(cleared, "en-GB")
    end

    test "genuinely distinct sibling dialects are never collapsed into one another (regression)" do
      # en-US (primary) and en-GB are two REAL, independently co-enabled
      # dialects (the tab UI supports this — compute_short_code/2
      # disambiguates the collision). Saving the en-GB tab must store its
      # own override, never overwrite the primary entry: en-GB is a
      # sibling of en-US, not a bare/dialect naming-drift of it.
      data = %{"_primary_language" => "en-US", "en-US" => %{"_name" => "American"}}

      updated = Multilang.put_language_data(data, "en-GB", %{"_name" => "British"})

      assert updated["en-US"]["_name"] == "American"
      assert updated["en-GB"]["_name"] == "British"

      # Reading each dialect back gets its own content, not the other's.
      assert Multilang.get_language_data(updated, "en-US")["_name"] == "American"
      assert Multilang.get_language_data(updated, "en-GB")["_name"] == "British"

      # Saving a THIRD distinct secondary sibling (en-CA) must not drop an
      # existing, unrelated secondary sibling (en-GB) — both are real,
      # independently maintained translations under a non-English primary.
      mixed = %{
        "_primary_language" => "et",
        "et" => %{"_name" => "KORVID"},
        "en-GB" => %{"_name" => "Hampers"}
      }

      updated2 = Multilang.put_language_data(mixed, "en-CA", %{"_name" => "Baskets"})
      assert updated2["en-CA"]["_name"] == "Baskets"
      assert updated2["en-GB"]["_name"] == "Hampers"
    end

    test "get_raw_language_data finds dialect-sibling entries" do
      data = %{"_primary_language" => "et", "en-US" => %{"_name" => "Baskets"}}
      assert Multilang.get_raw_language_data(data, "en")["_name"] == "Baskets"
      assert Multilang.get_raw_language_data(data, "ru") == %{}
    end

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

    test "promoting a sibling of the new primary keeps OTHER real siblings intact (regression)" do
      # et is primary; en-US and en-GB are two distinct, independently
      # maintained secondary dialects. Promoting en-US to primary must
      # only fold en-US itself into the new primary (it becomes the
      # promoted entry) — en-GB is a genuinely different translation and
      # must survive as its own secondary override, not get swept as a
      # "stale ghost" merely for sharing a base with the new primary.
      data = %{
        "_primary_language" => "et",
        "et" => %{"_name" => "KORVID"},
        "en-US" => %{"_name" => "American Baskets"},
        "en-GB" => %{"_name" => "British Hampers"}
      }

      result = Multilang.rekey_primary(data, "en-US")

      assert result["_primary_language"] == "en-US"
      assert result["en-US"]["_name"] == "American Baskets"
      assert result["en-GB"]["_name"] == "British Hampers"
      assert Map.has_key?(result, "et")
    end
  end

  describe "text_field/3" do
    @data %{
      "_primary_language" => "en",
      "en" => %{"_name" => "Buyer", "_description" => "Buys"},
      "de" => %{"_name" => "Käufer", "_description" => "   "}
    }

    test "reads the language, inheriting from the primary language" do
      assert Multilang.text_field(@data, "name", "de") == "Käufer"
      assert Multilang.text_field(@data, "name", "fr") == "Buyer"
      assert Multilang.text_field(@data, "name") == "Buyer"
    end

    test "reads a blank as absent" do
      assert Multilang.text_field(@data, "description", "de") == "Buys"
      assert Multilang.text_field(%{"_name" => " "}, "name") == nil
    end

    test "reads a bare field from data written by hand, and answers nil for the rest" do
      assert Multilang.text_field(%{"name" => "Plain"}, "name") == "Plain"
      assert Multilang.text_field(%{}, "name") == nil
      assert Multilang.text_field(nil, "name") == nil
      assert Multilang.text_field("a string", "name") == nil
    end
  end

  describe "valid_text_data?/1" do
    test "accepts flat text and the multilang shape" do
      assert Multilang.valid_text_data?(%{})
      assert Multilang.valid_text_data?(%{"_name" => "Buyer"})
      assert Multilang.valid_text_data?(%{"_primary_language" => "en", "en" => %{"_name" => "x"}})
    end

    test "refuses what would crash a reader" do
      refute Multilang.valid_text_data?("a string")
      refute Multilang.valid_text_data?(["a list"])
      refute Multilang.valid_text_data?(nil)
      refute Multilang.valid_text_data?(%{"_name" => 1})
      refute Multilang.valid_text_data?(%{"_primary_language" => "en"})
      refute Multilang.valid_text_data?(%{"_primary_language" => "en", "en" => "x"})

      refute Multilang.valid_text_data?(%{
               "_primary_language" => "en",
               "en" => %{"_name" => "x"},
               "de" => "y"
             })
    end
  end

  describe "build_text_data/1" do
    test "stores fields language by language, under an existing primary" do
      assert %{
               "_primary_language" => primary,
               "en" => %{"_name" => "Buyer", "_inverse_name" => "Buyers"},
               "de" => %{"_name" => "Käufer"}
             } =
               Multilang.build_text_data(%{
                 "_name" => %{"en" => "Buyer", "de" => "Käufer"},
                 "_inverse_name" => %{"en" => "Buyers"}
               })

      assert primary in ["en", "de"]
    end

    test "drops blanks, and gives an empty map for nothing" do
      assert Multilang.build_text_data(%{"_name" => nil}) == %{}
      assert Multilang.build_text_data(%{"_name" => %{"en" => "  "}}) == %{}
    end

    test "a string goes under the primary language" do
      data = Multilang.build_text_data(%{"_name" => "Buyer"})
      assert Multilang.text_field(data, "name") == "Buyer"
    end
  end
end
