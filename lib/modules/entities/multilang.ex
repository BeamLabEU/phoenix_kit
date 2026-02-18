defmodule PhoenixKit.Modules.Entities.Multilang do
  @moduledoc """
  Multi-language data transformation helpers for entity data JSONB.

  Multi-language support is driven by the Languages module globally.
  When the Languages module is enabled and has more than one language,
  all entities automatically support multilang data. There is no
  per-entity toggle — languages are configured system-wide.

  The `data` JSONB column stores a nested structure:

      %{
        "_primary_language" => "en-US",
        "en-US" => %{"_title" => "Acme", "name" => "Acme", "tagline" => "Quality products"},
        "es-ES" => %{"_title" => "Acme España", "name" => "Acme España"}
      }

  The primary language always has complete data. Secondary languages
  store only overrides — fields that differ from primary. Display
  merges primary values as defaults with language-specific overrides.

  The `_title` key stores the record title alongside custom fields,
  unifying title translation with the same override-only storage pattern.
  The `title` DB column remains a denormalized copy for queries/sorting.
  """

  alias PhoenixKit.Modules.Languages

  @primary_language_key "_primary_language"

  # ── Global language helpers ─────────────────────────────────────

  @doc """
  Checks if multilang is enabled globally.
  Returns true when the Languages module is enabled and has more than one language.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    if languages_available?() do
      length(enabled_language_codes()) > 1
    else
      false
    end
  end

  @doc """
  Gets the primary (default) language code.
  Returns the Languages module default, falling back to "en-US".
  """
  @spec primary_language() :: String.t()
  def primary_language do
    default_language_code()
  end

  @doc """
  Gets the list of enabled language codes.
  Returns at minimum the primary language.
  """
  @spec enabled_languages() :: [String.t()]
  def enabled_languages do
    if languages_available?() do
      codes = enabled_language_codes()
      primary = primary_language()
      if primary in codes, do: codes, else: [primary | codes]
    else
      [primary_language()]
    end
  end

  # ── Data read helpers ─────────────────────────────────────────

  @doc """
  Extracts the data map for a specific language from a record's data.

  For multilang data: returns merged data (primary as base + overrides).
  For flat data: returns data as-is (backward compat).
  """
  @spec get_language_data(map() | nil, String.t()) :: map()
  def get_language_data(data, lang_code) do
    if multilang_data?(data) do
      primary = primary_language_from_data(data)
      primary_data = Map.get(data, primary, %{})

      if lang_code == primary do
        primary_data
      else
        lang_data = Map.get(data, lang_code, %{})
        Map.merge(primary_data, lang_data)
      end
    else
      data || %{}
    end
  end

  @doc """
  Gets the primary language data from a record (for display in lists etc).
  """
  @spec get_primary_data(map() | nil) :: map()
  def get_primary_data(data) do
    if multilang_data?(data) do
      primary = primary_language_from_data(data)
      Map.get(data, primary, %{})
    else
      data || %{}
    end
  end

  @doc """
  Gets raw (non-merged) language-specific data for a language.
  Used by the form UI to detect which fields are overridden vs inherited.
  """
  @spec get_raw_language_data(map() | nil, String.t()) :: map()
  def get_raw_language_data(data, lang_code) do
    if multilang_data?(data) do
      Map.get(data, lang_code, %{})
    else
      data || %{}
    end
  end

  @doc """
  Checks if a data map uses the multilang structure.
  Presence of `_primary_language` key indicates multilang.
  """
  @spec multilang_data?(map() | nil) :: boolean()
  def multilang_data?(nil), do: false

  def multilang_data?(data) when is_map(data) do
    Map.has_key?(data, @primary_language_key)
  end

  def multilang_data?(_), do: false

  # ── Data write helpers ────────────────────────────────────────

  @doc """
  Merges language-specific form data into the full multilang JSONB.

  For primary language: stores ALL fields.
  For secondary language: stores only fields that differ from primary.
  """
  @spec put_language_data(map() | nil, String.t(), map()) :: map()
  def put_language_data(existing_data, lang_code, new_field_data) do
    existing_data = existing_data || %{}

    # Use embedded primary for existing multilang data, global for new/flat data
    primary =
      if multilang_data?(existing_data) do
        primary_language_from_data(existing_data)
      else
        primary_language()
      end

    # Ensure multilang structure
    base_data =
      if multilang_data?(existing_data) do
        existing_data
      else
        # Convert flat data to multilang (migration path)
        %{@primary_language_key => primary, primary => existing_data}
      end

    if lang_code == primary do
      # Primary language: store all fields
      Map.put(base_data, lang_code, new_field_data)
    else
      # Secondary language: only store overrides
      primary_data = Map.get(base_data, primary, %{})
      overrides = compute_overrides(new_field_data, primary_data)

      if map_size(overrides) == 0 do
        Map.delete(base_data, lang_code)
      else
        Map.put(base_data, lang_code, overrides)
      end
    end
  end

  @doc """
  Converts existing flat data to multilang structure.
  """
  @spec migrate_to_multilang(map() | nil, String.t()) :: map()
  def migrate_to_multilang(flat_data, primary_lang) do
    flat_data = flat_data || %{}

    %{
      @primary_language_key => primary_lang,
      primary_lang => flat_data
    }
  end

  @doc """
  Converts multilang data back to flat structure.
  Returns primary language data.
  """
  @spec flatten_to_primary(map() | nil) :: map()
  def flatten_to_primary(nil), do: %{}

  def flatten_to_primary(data) when is_map(data) do
    primary = data[@primary_language_key]
    if primary, do: Map.get(data, primary, %{}), else: data
  end

  def flatten_to_primary(_), do: %{}

  # ── Primary language re-keying ──────────────────────────────

  @doc """
  Re-keys multilang data to a new primary language.

  Updates `_primary_language` to the new primary and ensures the new
  primary has complete data (fills missing fields from the old primary).
  All secondary languages are recomputed: their overrides are recalculated
  against the new promoted primary, and languages with zero overrides are removed.

  Returns data unchanged if already using the given primary or not multilang.
  """
  @spec rekey_primary(map() | nil, String.t()) :: map()
  def rekey_primary(nil, _new_primary), do: nil

  def rekey_primary(data, new_primary) when is_map(data) do
    cond do
      not multilang_data?(data) ->
        data

      primary_language_from_data(data) == new_primary ->
        data

      true ->
        old_primary = primary_language_from_data(data)
        old_primary_data = Map.get(data, old_primary, %{})
        new_primary_data = Map.get(data, new_primary, %{})

        # Promote: fill missing fields in new primary from old primary
        promoted = Map.merge(old_primary_data, new_primary_data)

        data =
          data
          |> Map.put(@primary_language_key, new_primary)
          |> Map.put(new_primary, promoted)

        # Recompute all secondaries (including old primary) against the new base
        recompute_all_secondaries(data, new_primary, promoted, old_primary_data)
    end
  end

  def rekey_primary(data, _new_primary), do: data

  @doc """
  Checks if data needs re-keying (embedded primary != global primary).
  Returns re-keyed data if needed, original data otherwise.
  """
  @spec maybe_rekey_data(map() | nil) :: map() | nil
  def maybe_rekey_data(data) do
    if multilang_data?(data) do
      global = primary_language()
      embedded = primary_language_from_data(data)

      if embedded != global do
        rekey_primary(data, global)
      else
        data
      end
    else
      data
    end
  end

  # ── Language tab helpers ──────────────────────────────────────

  @doc """
  Builds language tab data for the UI from the Languages module.
  Returns a list of maps with code, name, flag, and is_primary fields.
  """
  @spec build_language_tabs() :: [map()]
  def build_language_tabs do
    if enabled?() do
      primary = primary_language()
      langs = enabled_languages()

      # Ensure primary is always first
      ordered = [primary | Enum.reject(langs, &(&1 == primary))]

      Enum.map(ordered, fn code ->
        info = get_language_info(code)

        %{
          code: code,
          name: info.name,
          flag: info.flag,
          is_primary: code == primary,
          short_code: compute_short_code(code, ordered)
        }
      end)
    else
      []
    end
  end

  # ── Private helpers ───────────────────────────────────────────

  defp compute_short_code(code, all_codes) do
    base = code |> String.split("-") |> List.first() |> String.upcase()

    collision =
      Enum.any?(all_codes, fn other ->
        other != code and
          other |> String.split("-") |> List.first() |> String.upcase() == base
      end)

    if collision, do: String.upcase(code), else: base
  end

  # After rekeying, recompute overrides for every secondary language against the
  # new promoted primary. Removes language keys that have zero overrides.
  defp recompute_all_secondaries(data, new_primary, promoted, old_primary_data) do
    Enum.reduce(data, data, fn
      {@primary_language_key, _}, acc ->
        acc

      {^new_primary, _}, acc ->
        acc

      {lang, lang_data}, acc when is_map(lang_data) ->
        # Reconstruct full data using OLD primary as base (overrides were against old primary)
        full_lang_data = Map.merge(old_primary_data, lang_data)
        # Then diff against the NEW primary to compute new overrides
        overrides = compute_overrides(full_lang_data, promoted)
        put_or_remove_language(acc, lang, overrides)

      {_key, _value}, acc ->
        acc
    end)
  end

  defp put_or_remove_language(data, lang, overrides) do
    if map_size(overrides) == 0 do
      Map.delete(data, lang)
    else
      Map.put(data, lang, overrides)
    end
  end

  defp compute_overrides(lang_data, primary_data) do
    lang_data
    |> Enum.filter(fn {key, value} ->
      value != nil and value != "" and Map.get(primary_data, key) != value
    end)
    |> Map.new()
  end

  defp primary_language_from_data(data) do
    data[@primary_language_key] || primary_language()
  end

  defp languages_available? do
    Code.ensure_loaded?(Languages) and
      function_exported?(Languages, :enabled?, 0) and
      Languages.enabled?()
  end

  defp enabled_language_codes do
    if Code.ensure_loaded?(Languages) and
         function_exported?(Languages, :get_enabled_language_codes, 0) do
      Languages.get_enabled_language_codes()
    else
      [default_language_code()]
    end
  end

  defp default_language_code do
    if Code.ensure_loaded?(Languages) and
         function_exported?(Languages, :get_default_language, 0) do
      case Languages.get_default_language() do
        %{code: code} when is_binary(code) -> code
        _ -> "en-US"
      end
    else
      "en-US"
    end
  end

  defp get_language_info(code) do
    lang =
      if Code.ensure_loaded?(Languages) and
           function_exported?(Languages, :get_language, 1) do
        Languages.get_language(code)
      end

    available =
      if is_nil(lang) and Code.ensure_loaded?(Languages) and
           function_exported?(Languages, :get_available_language_by_code, 1) do
        Languages.get_available_language_by_code(code)
      end

    cond do
      lang != nil ->
        %{name: Map.get(lang, :name, code), flag: Map.get(lang, :flag, nil)}

      available != nil ->
        %{name: Map.get(available, :name, code), flag: Map.get(available, :flag, nil)}

      true ->
        %{name: code, flag: nil}
    end
  end
end
