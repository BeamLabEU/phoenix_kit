defmodule PhoenixKit.Modules.Languages.Language do
  @moduledoc """
  Struct representing a language in PhoenixKit.

  Provides a consistent data type for all language-related operations,
  replacing the previous mix of string-keyed and atom-keyed maps.

  ## Fields

  - `code` - Language code (e.g., "en-US", "es-ES")
  - `name` - Full language name (e.g., "English (United States)")
  - `native` - Native name (e.g., "English (US)")
  - `flag` - Flag emoji (e.g., "🇺🇸")
  - `is_default` - Whether this is the default language
  - `is_enabled` - Whether this language is active
  - `position` - Sort position for ordering
  - `countries` - List of country names where this language is spoken

  ## Usage

      # All Languages module public functions return Language structs:
      lang = Languages.get_default_language()
      lang.code    #=> "en-US"
      lang.name    #=> "English (United States)"
  """

  @enforce_keys [:code, :name]
  defstruct [
    :code,
    :name,
    :native,
    :flag,
    :position,
    is_default: false,
    is_enabled: true,
    countries: []
  ]

  @type t :: %__MODULE__{
          code: String.t(),
          name: String.t(),
          native: String.t() | nil,
          flag: String.t() | nil,
          position: integer() | nil,
          is_default: boolean(),
          is_enabled: boolean(),
          countries: [String.t()]
        }

  @doc """
  Converts a string-keyed JSONB map to a Language struct.

  Used when reading language data from database JSON settings.

  ## Examples

      iex> Language.from_json_map(%{"code" => "en-US", "name" => "English (United States)", "is_default" => true})
      %Language{code: "en-US", name: "English (United States)", is_default: true, is_enabled: true}
  """
  @spec from_json_map(map()) :: t()
  def from_json_map(map) when is_map(map) do
    %__MODULE__{
      code: map["code"],
      name: map["name"],
      native: map["native"],
      flag: map["flag"],
      is_default: Map.get(map, "is_default", false),
      is_enabled: Map.get(map, "is_enabled", true),
      position: map["position"],
      countries: Map.get(map, "countries", [])
    }
  end

  @doc """
  Converts an atom-keyed map (e.g., from BeamLabCountries) to a Language struct.

  ## Examples

      iex> Language.from_available_map(%{code: "en-US", name: "English (United States)", native: "English (US)", flag: "🇺🇸"})
      %Language{code: "en-US", name: "English (United States)", native: "English (US)", flag: "🇺🇸"}
  """
  @spec from_available_map(map()) :: t()
  def from_available_map(map) when is_map(map) do
    %__MODULE__{
      code: map[:code],
      name: map[:name],
      native: map[:native],
      flag: map[:flag],
      is_default: Map.get(map, :is_default, false),
      is_enabled: Map.get(map, :is_enabled, true),
      position: map[:position],
      countries: Map.get(map, :countries, [])
    }
  end

  @doc """
  Converts a Language struct to a string-keyed map for JSONB storage.

  Only includes the fields that are stored in the database JSON config.

  ## Examples

      iex> Language.to_json_map(%Language{code: "en-US", name: "English (United States)", is_default: true})
      %{"code" => "en-US", "name" => "English (United States)", "is_default" => true, "is_enabled" => true}
  """
  @spec to_json_map(t()) :: map()
  def to_json_map(%__MODULE__{} = lang) do
    map = %{
      "code" => lang.code,
      "name" => lang.name,
      "is_default" => lang.is_default,
      "is_enabled" => lang.is_enabled
    }

    if lang.position do
      Map.put(map, "position", lang.position)
    else
      map
    end
  end
end
