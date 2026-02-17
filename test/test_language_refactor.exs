defmodule LanguageRefactorTest do
  use ExUnit.Case
  doctest PhoenixKit.Modules.Languages
  doctest PhoenixKit.Modules.Languages.Language

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.Language

  test "Language struct creation and conversion" do
    # Test from_json_map with string-keyed map
    json_map = %{"code" => "en-US", "name" => "English (United States)", "is_default" => true}
    lang = Language.from_json_map(json_map)

    assert lang.code == "en-US"
    assert lang.name == "English (United States)"
    assert lang.is_default == true
    # default value
    assert lang.is_enabled == true

    # Test from_available_map with atom-keyed map
    available_map = %{
      code: "es-ES",
      name: "Spanish (Spain)",
      native: "Español (España)",
      flag: "🇪🇸"
    }

    lang2 = Language.from_available_map(available_map)

    assert lang2.code == "es-ES"
    assert lang2.name == "Spanish (Spain)"
    assert lang2.native == "Español (España)"
    assert lang2.flag == "🇪🇸"

    # Test to_json_map conversion
    json_output = Language.to_json_map(lang)
    assert json_output["code"] == "en-US"
    assert json_output["name"] == "English (United States)"
    assert json_output["is_default"] == true
    assert json_output["is_enabled"] == true
  end

  test "Languages module returns Language structs" do
    # This test assumes the Languages module is properly configured
    # In a real test environment, you'd need to set up the database

    # Test that get_predefined_language returns a Language struct
    predefined = Languages.get_predefined_language("en-US")
    assert is_struct(predefined, Language)
    assert predefined.code == "en-US"
    assert predefined.name == "English (United States)"
  end

  test "Boolean field handling with Map.get/3" do
    # Test that false values are preserved correctly
    json_map_false = %{"code" => "test", "name" => "Test", "is_enabled" => false}
    lang = Language.from_json_map(json_map_false)

    # Should preserve explicit false
    assert lang.is_enabled == false

    # Test default value when key is missing
    json_map_missing = %{"code" => "test2", "name" => "Test2"}
    lang2 = Language.from_json_map(json_map_missing)

    # Should use default
    assert lang2.is_enabled == true
  end

  test "Struct access vs map access" do
    lang = Language.from_json_map(%{"code" => "fr-FR", "name" => "French (France)"})

    # Struct access should work
    assert lang.code == "fr-FR"
    assert lang.name == "French (France)"

    # Bracket access raises on structs (Access behaviour not implemented)
    assert_raise UndefinedFunctionError, fn -> lang["code"] end
  end

  test "grouped languages converts structs before adding country metadata" do
    grouped_languages = Languages.get_languages_grouped_by_continent()

    assert is_list(grouped_languages)

    {country, languages} =
      grouped_languages
      |> Enum.flat_map(fn {_continent, countries} ->
        Enum.map(countries, fn {country, _flag, languages} -> {country, languages} end)
      end)
      |> Enum.find(fn {_country, languages} -> match?([_ | _], languages) end)

    refute country == nil

    language = hd(languages)

    assert Map.get(language, :country) == country
    assert is_binary(language.code)
    assert is_binary(language.name)
  end
end
