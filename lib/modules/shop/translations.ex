defmodule PhoenixKit.Modules.Shop.Translations do
  @moduledoc """
  Localized fields helper for Shop module.

  All translatable fields are stored as JSONB maps directly in the field:

      %Product{
        title: %{"en" => "Planter", "ru" => "Кашпо"},
        slug: %{"en" => "planter", "ru" => "kashpo"},
        description: %{"en" => "Modern pot", "ru" => "Современное кашпо"}
      }

  ## Fallback Chain

  When retrieving a translated field, the fallback chain is:
  1. Exact language match (e.g., "ru")
  2. Default language from Languages module
  3. First available value in the map

  ## Usage Examples

      # Get translated field with automatic fallback
      Translations.get(product, :title, "ru")
      #=> "Кашпо"

      Translations.get(product, :title, "fr")
      #=> "Planter" (fallback to default or first available)

      # Set a single translated field
      product = Translations.put(product, :title, "es", "Maceta")

      # Build changeset attrs for localized field update
      attrs = Translations.changeset_attrs(product, :title, "ru", "Новое кашпо")
      #=> %{title: %{"en" => "Planter", "ru" => "Новое кашпо"}}
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
  then defaults to "en".

  ## Examples

      iex> Translations.default_language()
      "en"
  """
  @spec default_language() :: String.t()
  def default_language do
    if languages_enabled?() do
      case Languages.get_default_language() do
        %{"code" => code} -> code
        _ -> "en"
      end
    else
      Settings.get_content_language() || "en"
    end
  end

  @doc """
  Returns list of enabled language codes.

  When Languages module is enabled, returns all enabled language codes.
  Otherwise returns only the default language.

  ## Examples

      iex> Translations.enabled_languages()
      ["en", "es", "ru"]

      # When Languages module disabled:
      iex> Translations.enabled_languages()
      ["en"]
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
    Code.ensure_loaded?(Languages) and function_exported?(Languages, :enabled?, 0) and
      Languages.enabled?()
  end

  # ============================================================================
  # Reading Translations (New Localized Fields Approach)
  # ============================================================================

  @doc """
  Gets a localized value with automatic fallback chain.

  Fallback order:
  1. Exact language match
  2. Default language
  3. First available value

  ## Parameters

    - `entity` - Product or Category struct
    - `field` - Field atom (e.g., :title, :name, :slug)
    - `language` - Language code (e.g., "ru", "en")

  ## Examples

      iex> product = %Product{title: %{"en" => "Planter", "ru" => "Кашпо"}}
      iex> Translations.get(product, :title, "ru")
      "Кашпо"

      iex> Translations.get(product, :title, "fr")
      "Planter"  # Falls back to default or first available
  """
  @spec get(struct(), atom(), String.t()) :: any()
  def get(entity, field, language) do
    field_map = Map.get(entity, field) || %{}

    field_map[language] ||
      field_map[default_language()] ||
      first_available(field_map)
  end

  @doc """
  Gets the localized slug with fallback.

  Convenience function for URL slug retrieval.

  ## Examples

      iex> Translations.get_slug(product, "es")
      "maceta-geometrica"
  """
  @spec get_slug(struct(), String.t()) :: String.t() | nil
  def get_slug(entity, language) do
    get(entity, :slug, language)
  end

  @doc """
  Gets all values for a specific language from the entity's localized fields.

  Returns a map of field => value for the given language.

  ## Examples

      iex> Translations.get_all_for_language(product, "ru", [:title, :slug, :description])
      %{title: "Кашпо", slug: "kashpo", description: "Описание"}
  """
  @spec get_all_for_language(struct(), String.t(), [atom()]) :: map()
  def get_all_for_language(entity, language, fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      value = get(entity, field, language)
      Map.put(acc, field, value)
    end)
  end

  # ============================================================================
  # Writing Translations
  # ============================================================================

  @doc """
  Sets a localized value for a language.

  Returns the updated entity struct (not persisted to database).

  ## Examples

      iex> product = Translations.put(product, :title, "ru", "Новое кашпо")
      %Product{title: %{"en" => "Planter", "ru" => "Новое кашпо"}}
  """
  @spec put(struct(), atom(), String.t(), any()) :: struct()
  def put(entity, field, language, value) do
    current = Map.get(entity, field) || %{}
    updated = Map.put(current, language, value)
    Map.put(entity, field, updated)
  end

  @doc """
  Builds changeset attrs for localized field update.

  Merges the new value into the existing field map for the given language.

  ## Examples

      iex> Translations.changeset_attrs(product, :title, "ru", "Новое кашпо")
      %{title: %{"en" => "Planter", "ru" => "Новое кашпо"}}
  """
  @spec changeset_attrs(struct(), atom(), String.t(), any()) :: map()
  def changeset_attrs(entity, field, language, value) do
    current = Map.get(entity, field) || %{}
    updated = Map.put(current, language, value)
    %{field => updated}
  end

  @doc """
  Builds changeset attrs for multiple localized fields at once.

  ## Examples

      iex> Translations.changeset_attrs_multi(product, "ru", %{title: "Кашпо", slug: "kashpo"})
      %{title: %{"en" => "Planter", "ru" => "Кашпо"}, slug: %{"en" => "planter", "ru" => "kashpo"}}
  """
  @spec changeset_attrs_multi(struct(), String.t(), map()) :: map()
  def changeset_attrs_multi(entity, language, field_values) do
    Enum.reduce(field_values, %{}, fn {field, value}, acc ->
      Map.merge(acc, changeset_attrs(entity, field, language, value))
    end)
  end

  @doc """
  Sets multiple translated fields for a language.

  Returns the updated entity struct (not persisted to database).

  ## Examples

      iex> product = Translations.put_all(product, "es", %{title: "Maceta", slug: "maceta"})
      %Product{title: %{"en" => "Planter", "es" => "Maceta"}, ...}
  """
  @spec put_all(struct(), String.t(), map()) :: struct()
  def put_all(entity, language, field_values) do
    Enum.reduce(field_values, entity, fn {field, value}, acc ->
      put(acc, field, language, value)
    end)
  end

  # ============================================================================
  # Inspection Helpers
  # ============================================================================

  @doc """
  Gets all languages that have a value for a field.

  ## Examples

      iex> Translations.available_languages(product, :title)
      ["en", "ru"]
  """
  @spec available_languages(struct(), atom()) :: [String.t()]
  def available_languages(entity, field) do
    field_map = Map.get(entity, field) || %{}

    field_map
    |> Map.keys()
    |> Enum.filter(fn lang ->
      value = Map.get(field_map, lang)
      value != nil and value != ""
    end)
  end

  @doc """
  Checks if translation exists for language in a specific field.

  ## Examples

      iex> Translations.has_translation?(product, :title, "ru")
      true

      iex> Translations.has_translation?(product, :title, "zh")
      false
  """
  @spec has_translation?(struct(), atom(), String.t()) :: boolean()
  def has_translation?(entity, field, language) do
    field_map = Map.get(entity, field) || %{}
    value = Map.get(field_map, language)
    value != nil and value != ""
  end

  @doc """
  Gets translation completeness for a language across all translatable fields.

  ## Examples

      iex> Translations.translation_status(product, "ru")
      %{complete: 4, total: 6, percentage: 67, missing: [:body_html, :seo_description]}
  """
  @spec translation_status(struct(), String.t(), [atom()] | nil) :: map()
  def translation_status(entity, language, required_fields \\ nil) do
    fields = required_fields || translatable_fields(entity)

    present =
      Enum.filter(fields, fn field ->
        has_translation?(entity, field, language)
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
  # Legacy Compatibility (Deprecated)
  # ============================================================================

  @doc """
  DEPRECATED: Use `get/3` instead.

  This function exists for backward compatibility during migration.
  """
  @spec get_field(struct(), atom(), String.t()) :: any()
  def get_field(entity, field, language) do
    get(entity, field, language)
  end

  @doc """
  DEPRECATED: Use `put/4` instead.

  This function exists for backward compatibility during migration.
  """
  @spec put_field(struct(), atom(), String.t(), any()) :: struct()
  def put_field(entity, field, language, value) do
    put(entity, field, language, value)
  end

  @doc """
  DEPRECATED: Use `changeset_attrs_multi/3` instead.

  Builds changeset attrs for updating translations.
  This function adapts the old API to the new localized fields approach.
  """
  @spec translation_changeset_attrs(map() | nil, String.t(), map()) :: map()
  def translation_changeset_attrs(_current_translations, _language, _params) do
    # This function is no longer applicable in the new approach
    # where each field is its own map.
    # Kept for compilation but should not be used.
    %{}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp first_available(map) when map == %{}, do: nil

  defp first_available(map) do
    case Enum.at(map, 0) do
      {_key, value} -> value
      nil -> nil
    end
  end
end
