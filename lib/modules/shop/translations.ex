defmodule PhoenixKit.Modules.Shop.Translations do
  @moduledoc """
  Translation helpers for Shop module entities (Products, Categories).

  Provides a consistent API for reading and writing translations stored
  in the JSONB `translations` field on products and categories.

  ## Translation Structure

  Translations are stored per language code (e.g., "en-US", "es-ES"):

      %{
        "en-US" => %{
          "title" => "Geometric Planter",
          "slug" => "geometric-planter",
          "description" => "Modern faceted plant pot..."
        },
        "es-ES" => %{
          "title" => "Maceta Geométrica",
          "slug" => "maceta-geometrica",
          "description" => "Maceta moderna facetada..."
        }
      }

  ## Fallback Chain

  When retrieving a translated field, the fallback chain is:
  1. Exact language match (e.g., "es-ES")
  2. Default language from Languages module
  3. Canonical field value from main entity

  ## Usage Examples

      # Get translated field with automatic fallback
      Translations.get_field(product, :title, "es-ES")
      # => "Maceta Geométrica" or fallback to default language or canonical field

      # Set a single translated field
      product = Translations.put_field(product, :title, "es-ES", "Maceta Geométrica")

      # Get all translations for a language
      Translations.get_translation(product, "es-ES")
      # => %{"title" => "...", "slug" => "...", ...}

      # Set full translation for a language
      product = Translations.put_translation(product, "es-ES", %{
        title: "Maceta Geométrica",
        slug: "maceta-geometrica",
        description: "..."
      })

      # Check if entity has translation
      Translations.has_translation?(product, "es-ES")
      # => true

      # List available languages for entity
      Translations.available_languages(product)
      # => ["en-US", "es-ES"]
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings

  @product_fields [:title, :slug, :description, :body_html, :seo_title, :seo_description]
  @category_fields [:name, :slug, :description]

  # ============================================================================
  # Language Configuration
  # ============================================================================

  @doc """
  Returns the default/master language code.

  Checks Languages module first, falls back to Settings content language,
  then defaults to "en-US".

  ## Examples

      iex> Translations.default_language()
      "en-US"
  """
  @spec default_language() :: String.t()
  def default_language do
    if languages_enabled?() do
      case Languages.get_default_language() do
        %{"code" => code} -> code
        _ -> "en-US"
      end
    else
      Settings.get_content_language() || "en-US"
    end
  end

  @doc """
  Returns list of enabled language codes.

  When Languages module is enabled, returns all enabled language codes.
  Otherwise returns only the default language.

  ## Examples

      iex> Translations.enabled_languages()
      ["en-US", "es-ES", "ru-RU"]

      # When Languages module disabled:
      iex> Translations.enabled_languages()
      ["en-US"]
  """
  @spec enabled_languages() :: [String.t()]
  def enabled_languages do
    if languages_enabled?() do
      Languages.get_enabled_language_codes()
    else
      [default_language()]
    end
  end

  @doc """
  Checks if Languages module is enabled.
  """
  @spec languages_enabled?() :: boolean()
  def languages_enabled? do
    Code.ensure_loaded?(Languages) and Languages.enabled?()
  end

  # ============================================================================
  # Reading Translations
  # ============================================================================

  @doc """
  Gets a translated field value with automatic fallback chain.

  Fallback order:
  1. Exact language match
  2. Default language
  3. Canonical field on entity

  ## Parameters

    - `entity` - Product or Category struct
    - `field` - Field atom (e.g., :title, :name, :slug)
    - `language` - Language code (e.g., "es-ES")

  ## Examples

      iex> Translations.get_field(product, :title, "es-ES")
      "Maceta Geométrica"

      iex> Translations.get_field(product, :title, "fr-FR")
      "Geometric Planter"  # Falls back to default or canonical
  """
  @spec get_field(struct(), atom(), String.t()) :: any()
  def get_field(entity, field, language) do
    translations = Map.get(entity, :translations) || %{}
    field_str = to_string(field)

    # Try exact language match
    case get_in(translations, [language, field_str]) do
      nil ->
        # Fallback to default language
        default = default_language()

        case get_in(translations, [default, field_str]) do
          nil ->
            # Final fallback to canonical field
            Map.get(entity, field)

          value ->
            value
        end

      value ->
        value
    end
  end

  @doc """
  Gets the translated slug with fallback.

  Convenience function for URL slug retrieval.

  ## Examples

      iex> Translations.get_slug(product, "es-ES")
      "maceta-geometrica"
  """
  @spec get_slug(struct(), String.t()) :: String.t() | nil
  def get_slug(entity, language) do
    get_field(entity, :slug, language) || Map.get(entity, :slug)
  end

  @doc """
  Gets the full translation map for a specific language.

  Returns empty map if no translation exists.

  ## Examples

      iex> Translations.get_translation(product, "es-ES")
      %{"title" => "...", "slug" => "...", "description" => "..."}

      iex> Translations.get_translation(product, "unknown")
      %{}
  """
  @spec get_translation(struct(), String.t()) :: map()
  def get_translation(entity, language) do
    translations = Map.get(entity, :translations) || %{}
    Map.get(translations, language, %{})
  end

  @doc """
  Gets translated fields for all enabled languages.

  Returns a map of language code => translation map.

  ## Examples

      iex> Translations.get_all_translations(product)
      %{
        "en-US" => %{"title" => "Planter", ...},
        "es-ES" => %{"title" => "Maceta", ...}
      }
  """
  @spec get_all_translations(struct()) :: map()
  def get_all_translations(entity) do
    Map.get(entity, :translations) || %{}
  end

  # ============================================================================
  # Writing Translations
  # ============================================================================

  @doc """
  Sets a single translated field value.

  Returns the updated entity struct (not persisted to database).

  ## Examples

      iex> product = Translations.put_field(product, :title, "es-ES", "Maceta")
      %Product{translations: %{"es-ES" => %{"title" => "Maceta"}}}
  """
  @spec put_field(struct(), atom(), String.t(), any()) :: struct()
  def put_field(entity, field, language, value) do
    translations = Map.get(entity, :translations) || %{}
    lang_data = Map.get(translations, language, %{})
    updated_lang = Map.put(lang_data, to_string(field), value)
    updated_translations = Map.put(translations, language, updated_lang)
    Map.put(entity, :translations, updated_translations)
  end

  @doc """
  Sets the full translation map for a language.

  Atom keys are automatically converted to strings for consistency.
  Returns the updated entity struct (not persisted to database).

  ## Examples

      iex> product = Translations.put_translation(product, "es-ES", %{
      ...>   title: "Maceta Geométrica",
      ...>   slug: "maceta-geometrica"
      ...> })
      %Product{translations: %{"es-ES" => %{"title" => "...", "slug" => "..."}}}
  """
  @spec put_translation(struct(), String.t(), map()) :: struct()
  def put_translation(entity, language, translation_map) do
    translations = Map.get(entity, :translations) || %{}

    # Convert atom keys to strings for consistency
    string_keyed =
      Map.new(translation_map, fn {k, v} ->
        {to_string(k), v}
      end)

    updated = Map.put(translations, language, string_keyed)
    Map.put(entity, :translations, updated)
  end

  @doc """
  Merges translation fields into existing translation for a language.

  Unlike `put_translation/3`, this preserves existing fields and only
  updates the specified ones.

  ## Examples

      iex> product = Translations.merge_translation(product, "es-ES", %{title: "New Title"})
      # Preserves existing slug, description, etc.
  """
  @spec merge_translation(struct(), String.t(), map()) :: struct()
  def merge_translation(entity, language, translation_map) do
    translations = Map.get(entity, :translations) || %{}
    existing = Map.get(translations, language, %{})

    string_keyed =
      Map.new(translation_map, fn {k, v} ->
        {to_string(k), v}
      end)

    merged = Map.merge(existing, string_keyed)
    updated = Map.put(translations, language, merged)
    Map.put(entity, :translations, updated)
  end

  # ============================================================================
  # Changeset Helpers
  # ============================================================================

  @doc """
  Builds changeset attrs for updating translations.

  Use this when building attrs for Ecto changeset updates.

  ## Examples

      iex> attrs = Translations.translation_changeset_attrs(
      ...>   product.translations,
      ...>   "es-ES",
      ...>   %{"title" => "Nueva Maceta"}
      ...> )
      %{"translations" => %{"es-ES" => %{"title" => "Nueva Maceta", ...}}}
  """
  @spec translation_changeset_attrs(map() | nil, String.t(), map()) :: map()
  def translation_changeset_attrs(current_translations, language, params) do
    translations = current_translations || %{}
    lang_data = Map.get(translations, language, %{})
    updated_lang = Map.merge(lang_data, stringify_keys(params))
    %{"translations" => Map.put(translations, language, updated_lang)}
  end

  @doc """
  Extracts translation attrs from form params for a specific language.

  Useful when handling form submissions with language-prefixed fields.

  ## Examples

      iex> params = %{"title_es-ES" => "Maceta", "slug_es-ES" => "maceta"}
      iex> Translations.extract_translation_params(params, "es-ES", [:title, :slug])
      %{"title" => "Maceta", "slug" => "maceta"}
  """
  @spec extract_translation_params(map(), String.t(), [atom()]) :: map()
  def extract_translation_params(params, language, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      key = "#{field}_#{language}"

      case Map.get(params, key) do
        nil -> acc
        value -> Map.put(acc, to_string(field), value)
      end
    end)
  end

  # ============================================================================
  # Inspection Helpers
  # ============================================================================

  @doc """
  Checks if entity has any translation for the specified language.

  ## Examples

      iex> Translations.has_translation?(product, "es-ES")
      true

      iex> Translations.has_translation?(product, "zh-CN")
      false
  """
  @spec has_translation?(struct(), String.t()) :: boolean()
  def has_translation?(entity, language) do
    translations = Map.get(entity, :translations) || %{}

    case Map.get(translations, language) do
      nil -> false
      map when map == %{} -> false
      _ -> true
    end
  end

  @doc """
  Lists all language codes that have translations for this entity.

  Only returns languages with non-empty translation maps.

  ## Examples

      iex> Translations.available_languages(product)
      ["en-US", "es-ES"]
  """
  @spec available_languages(struct()) :: [String.t()]
  def available_languages(entity) do
    translations = Map.get(entity, :translations) || %{}

    translations
    |> Enum.filter(fn {_lang, data} -> data != %{} end)
    |> Enum.map(fn {lang, _data} -> lang end)
  end

  @doc """
  Returns translation completeness status for a language.

  Compares translated fields against required fields.

  ## Examples

      iex> Translations.translation_status(product, "es-ES")
      %{complete: 4, total: 6, missing: [:body_html, :seo_description]}
  """
  @spec translation_status(struct(), String.t(), [atom()] | nil) :: map()
  def translation_status(entity, language, required_fields \\ nil) do
    fields = required_fields || translatable_fields(entity)
    translation = get_translation(entity, language)

    present =
      Enum.filter(fields, fn field ->
        value = Map.get(translation, to_string(field))
        value != nil and value != ""
      end)

    missing = fields -- present
    present_count = Enum.count(present)
    total_count = Enum.count(fields)

    %{
      complete: present_count,
      total: total_count,
      percentage: if(total_count > 0, do: round(present_count / total_count * 100), else: 0),
      missing: missing
    }
  end

  # ============================================================================
  # Field Definitions
  # ============================================================================

  @doc """
  Returns the list of translatable fields for products.
  """
  @spec product_fields() :: [atom()]
  def product_fields, do: @product_fields

  @doc """
  Returns the list of translatable fields for categories.
  """
  @spec category_fields() :: [atom()]
  def category_fields, do: @category_fields

  @doc """
  Returns translatable fields based on entity type.
  """
  @spec translatable_fields(struct()) :: [atom()]
  def translatable_fields(%{__struct__: PhoenixKit.Modules.Shop.Product}), do: @product_fields
  def translatable_fields(%{__struct__: PhoenixKit.Modules.Shop.Category}), do: @category_fields
  def translatable_fields(_), do: []

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
