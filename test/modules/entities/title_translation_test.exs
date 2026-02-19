defmodule PhoenixKit.Modules.Entities.TitleTranslationTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Entities.EntityData

  # Pure-function tests for get_title_translation/2 and get_all_title_translations/1.
  # set_title_translation/3 requires DB access and is covered in parent app integration tests.

  # --- Test Fixtures ---

  defp record_with_title_in_data do
    %EntityData{
      title: "Acme",
      data: %{
        "_primary_language" => "en-US",
        "en-US" => %{"name" => "Acme Corp", "_title" => "Acme"},
        "es-ES" => %{"name" => "Acme España", "_title" => "Acme ES"}
      },
      metadata: %{}
    }
  end

  defp record_with_old_metadata_translations do
    %EntityData{
      title: "Acme",
      data: %{
        "_primary_language" => "en-US",
        "en-US" => %{"name" => "Acme Corp"}
      },
      metadata: %{
        "translations" => %{
          "es-ES" => %{"title" => "Acme Metadata ES"}
        }
      }
    }
  end

  defp record_with_no_translations do
    %EntityData{
      title: "Acme",
      data: %{
        "_primary_language" => "en-US",
        "en-US" => %{"name" => "Acme Corp"}
      },
      metadata: %{}
    }
  end

  defp record_with_flat_data do
    %EntityData{
      title: "Acme",
      data: %{"name" => "Acme Corp"},
      metadata: %{}
    }
  end

  defp record_with_nil_data do
    %EntityData{
      title: "Acme",
      data: nil,
      metadata: nil
    }
  end

  # --- get_title_translation/2 ---

  describe "get_title_translation/2" do
    test "returns _title from JSONB data for primary language" do
      assert EntityData.get_title_translation(record_with_title_in_data(), "en-US") == "Acme"
    end

    test "returns _title from JSONB data for secondary language" do
      assert EntityData.get_title_translation(record_with_title_in_data(), "es-ES") == "Acme ES"
    end

    test "falls back to metadata translations for unmigrated records" do
      assert EntityData.get_title_translation(record_with_old_metadata_translations(), "es-ES") ==
               "Acme Metadata ES"
    end

    test "falls back to title column when no translations exist" do
      assert EntityData.get_title_translation(record_with_no_translations(), "es-ES") == "Acme"
    end

    test "falls back to title column for unknown language" do
      assert EntityData.get_title_translation(record_with_title_in_data(), "de-DE") == "Acme"
    end

    test "handles flat (non-multilang) data" do
      assert EntityData.get_title_translation(record_with_flat_data(), "en-US") == "Acme"
    end

    test "handles nil data" do
      assert EntityData.get_title_translation(record_with_nil_data(), "en-US") == "Acme"
    end

    test "prefers JSONB _title over metadata translations" do
      # Record has _title in data AND old metadata translations
      record = %EntityData{
        title: "Fallback",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_title" => "From Data"},
          "es-ES" => %{"_title" => "Desde Datos"}
        },
        metadata: %{
          "translations" => %{
            "es-ES" => %{"title" => "Desde Metadata"}
          }
        }
      }

      assert EntityData.get_title_translation(record, "es-ES") == "Desde Datos"
    end

    test "skips empty _title and falls back" do
      record = %EntityData{
        title: "Fallback Title",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_title" => ""},
          "es-ES" => %{"_title" => ""}
        },
        metadata: %{}
      }

      assert EntityData.get_title_translation(record, "en-US") == "Fallback Title"
      assert EntityData.get_title_translation(record, "es-ES") == "Fallback Title"
    end

    test "secondary language without override inherits primary _title" do
      record = %EntityData{
        title: "Acme",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"name" => "Acme Corp", "_title" => "Acme Products"}
        },
        metadata: %{}
      }

      # fr-FR has no override, get_language_data merges primary → _title inherited
      assert EntityData.get_title_translation(record, "fr-FR") == "Acme Products"
    end
  end

  # --- get_all_title_translations/1 ---

  describe "get_all_title_translations/1" do
    test "returns map with all enabled languages" do
      result = EntityData.get_all_title_translations(record_with_title_in_data())

      # In test env, enabled_languages falls back to ["en-US"]
      assert is_map(result)
      assert Map.has_key?(result, "en-US")
      assert result["en-US"] == "Acme"
    end

    test "handles record with no translations" do
      result = EntityData.get_all_title_translations(record_with_no_translations())

      assert is_map(result)
      assert result["en-US"] == "Acme"
    end
  end
end
