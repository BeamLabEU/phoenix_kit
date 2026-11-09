defmodule PhoenixKit.Utils.Multilang do
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
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

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

  @doc """
  The language the page being rendered is in, for reading and storing
  per-language content: the full dialect the request resolved to, else the
  process's Gettext locale.

  Read it from the process, not from an assign: a LiveComponent has no
  `@current_locale` unless every host threads one through, and shares its
  LiveView's process either way. Not the Gettext locale alone — that is
  downgraded to a base code (`"en"` for both `"en-US"` and `"en-GB"`).
  """
  @spec current_locale() :: String.t()
  def current_locale do
    if Code.ensure_loaded?(Languages) and function_exported?(Languages, :request_locale, 0) do
      Languages.request_locale() || Gettext.get_locale(PhoenixKitWeb.Gettext)
    else
      Gettext.get_locale(PhoenixKitWeb.Gettext)
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

      # Always merge primary ⊕ override. A lang that IS the primary (or
      # a dialect sibling with no own entry) resolves to the primary
      # entry, and merging it onto itself is a no-op — while a sibling
      # WITH its own entry ("en" override under primary "en-US") still
      # wins, which a same-language short-circuit would wrongly skip.
      Map.merge(primary_data, language_entry(data, lang_code, primary))
    else
      data || %{}
    end
  end

  # Language codes differ per host: the Languages module may register
  # bare base codes ("en") while the locale pipeline resolves URLs to
  # full dialects ("en-US") — or the reverse. An exact-key miss
  # therefore falls back to the base code, then to any stored language
  # entry sharing the base, so a record translated under "en" still
  # resolves for a viewer whose `current_locale` is "en-US" (the
  # sticky-primary-language bug: English UI showing Estonian names).
  defp language_entry(data, lang_code, primary) do
    with :error <- fetch_lang_map(data, lang_code),
         base = DialectMapper.extract_base(lang_code),
         :error <- fetch_lang_map(data, base),
         :error <- fetch_same_base(data, base, primary) do
      %{}
    else
      {:ok, entry} -> entry
    end
  end

  defp fetch_lang_map(data, key) do
    case Map.get(data, key) do
      %{} = entry -> {:ok, entry}
      _ -> :error
    end
  end

  # Deterministic sibling pick: prefer the record's PRIMARY entry (the
  # complete field set), else the lexicographically first sibling — map
  # iteration order must never decide which translation a viewer sees.
  defp fetch_same_base(data, base, primary) do
    same_base_keys =
      data
      |> Enum.filter(fn
        {key, %{}} when is_binary(key) and key != @primary_language_key ->
          DialectMapper.extract_base(key) == base

        _ ->
          false
      end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    cond do
      same_base_keys == [] -> :error
      is_binary(primary) and primary in same_base_keys -> {:ok, Map.fetch!(data, primary)}
      true -> {:ok, Map.fetch!(data, hd(same_base_keys))}
    end
  end

  @doc """
  Gets the primary language data from a record (for display in lists etc).
  """
  @spec get_primary_data(map() | nil) :: map()
  def get_primary_data(data) do
    if multilang_data?(data) do
      primary = primary_language_from_data(data)

      # Base fallback: hand-written or migrated data whose entry key's
      # shape drifted from `_primary_language` ("en" entry, "en-US"
      # marker) must not read as empty.
      case Map.get(data, primary) do
        %{} = entry -> entry
        _ -> language_entry(data, primary, primary)
      end
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
      # Same base-code fallback as `get_language_data/2`: an editor tab
      # for "en" must find an entry stored under "en-US" (or vice
      # versa) instead of rendering blank — the next save then migrates
      # it to the tab's code via `put_language_data/3`'s normalization.
      language_entry(data, lang_code, primary_language_from_data(data))
    else
      data || %{}
    end
  end

  @doc """
  The text of a short translated `field` ("name", "description"), in `lang` or
  the primary language, with blanks read as absent.

  Reads the multilang form's `"_name"` first, then a bare `"name"` from data written
  by hand. A language with no text inherits the primary language's. `nil` when
  there is none, so the caller can fall back to something of its own.
  """
  @spec text_field(term(), String.t(), String.t() | nil) :: String.t() | nil
  def text_field(data, field, lang \\ nil)

  def text_field(%{} = data, field, lang) when is_binary(field) do
    primary = get_primary_data(data)
    entry = if lang, do: get_raw_language_data(data, lang), else: primary

    entry_text(entry, field) || entry_text(primary, field)
  end

  def text_field(_data, _field, _lang), do: nil

  defp entry_text(entry, field) do
    case Map.get(entry, "_" <> field) || Map.get(entry, field) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _ ->
        nil
    end
  end

  @doc """
  Whether `data` is a map `text_field/3` can read: flat text fields, or the multilang
  shape with text fields under each language. For a castable `data` field, where a
  string or a list would crash every reader.
  """
  @spec valid_text_data?(term()) :: boolean()
  def valid_text_data?(%{@primary_language_key => primary} = data) do
    is_binary(primary) and String.trim(primary) != "" and is_map(data[primary]) and
      data
      |> Map.delete(@primary_language_key)
      |> Enum.all?(fn {_lang, entry} -> valid_text_fields?(entry) end)
  end

  def valid_text_data?(%{} = data), do: valid_text_fields?(data)
  def valid_text_data?(_data), do: false

  defp valid_text_fields?(%{} = entry) do
    Enum.all?(entry, fn {key, value} -> is_binary(key) and is_binary(value) end)
  end

  defp valid_text_fields?(_entry), do: false

  @doc """
  Builds multilang `data` from short text fields, as a host passes them at boot:

      build_text_data(%{"_name" => %{"en" => "Buyer", "de" => "Käufer"}})

  A string goes under the primary language, a `%{lang => text}` map language by
  language, and blanks are dropped. The primary entry is one that exists, because
  every other language overrides it: the site's primary language or its base code,
  else the first language given.
  """
  @spec build_text_data(map()) :: map()
  def build_text_data(fields) when is_map(fields) do
    site_primary = primary_language()

    entries =
      for {key, value} <- fields,
          {lang, text} <- texts_by_language(value, site_primary),
          reduce: %{} do
        acc -> Map.update(acc, lang, %{key => text}, &Map.put(&1, key, text))
      end

    if entries == %{} do
      %{}
    else
      Map.put(entries, @primary_language_key, primary_among(Map.keys(entries), site_primary))
    end
  end

  defp texts_by_language(text, primary) when is_binary(text),
    do: texts_by_language(%{primary => text}, primary)

  defp texts_by_language(%{} = texts, _primary) do
    for {lang, text} <- texts, is_binary(text), String.trim(text) != "", into: %{} do
      {to_string(lang), String.trim(text)}
    end
  end

  defp texts_by_language(_value, _primary), do: %{}

  defp primary_among(langs, site_primary) do
    base = DialectMapper.extract_base(site_primary)

    Enum.find(langs, &(&1 == site_primary)) ||
      Enum.find(langs, &(DialectMapper.extract_base(&1) == base)) ||
      hd(Enum.sort(langs))
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

    if same_base?(lang_code, primary) do
      # Primary language: store all fields — under the record's OWN
      # primary key. A dialect-sibling code (form sends "en", record
      # embeds "en-US" from an earlier host config) must not fork a
      # bogus override; it IS the primary.
      Map.put(base_data, primary, new_field_data)
    else
      # Secondary language: only store overrides. Any entry that is the
      # same conceptual language under a different precision (a bare
      # "en" vs "en-US" naming-drift ghost of the code being written) is
      # dropped so it can't shadow the fresh write. A genuinely distinct
      # sibling dialect ("en-GB" while writing "en-CA") is NOT dropped —
      # see `same_base?/2`.
      primary_data = Map.get(base_data, primary, %{})
      overrides = compute_overrides(new_field_data, primary_data)
      base_data = drop_base_siblings(base_data, lang_code, primary)

      if map_size(overrides) == 0 do
        Map.delete(base_data, lang_code)
      else
        Map.put(base_data, lang_code, overrides)
      end
    end
  end

  # Narrow equivalence: true only when `a` and `b` name the SAME
  # conceptual language under different precision — identical codes, or
  # one is literally the bare base-code form of the other ("en" /
  # "en-US"). Deliberately NOT "any two codes sharing a base", which
  # would also match two genuinely distinct, independently co-enabled
  # sibling dialects ("en-US" primary + "en-GB" secondary — a supported
  # configuration per `compute_short_code/2`'s tab-collision handling).
  # Collapsing those would let editing one dialect's tab silently
  # overwrite or delete the other's stored content.
  defp same_base?(a, b) when is_binary(a) and is_binary(b) do
    a == b or a == DialectMapper.extract_base(b) or b == DialectMapper.extract_base(a)
  end

  defp same_base?(_, _), do: false

  defp drop_base_siblings(data, lang_code, primary) do
    Enum.reduce(data, data, fn
      {key, %{}}, acc
      when is_binary(key) and key != lang_code and key != primary and
             key != @primary_language_key ->
        if same_base?(key, lang_code), do: Map.delete(acc, key), else: acc

      _, acc ->
        acc
    end)
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

      # Same-BASE drift ("en" vs "en-US") is not a primary change:
      # reads fall back across siblings and writes normalize onto the
      # embedded key, so rekeying would only churn data (and, for
      # override-only new-primary entries, risk promoting a partial
      # field set). Only a genuinely different language rekeys.
      if embedded != global and not same_base?(embedded, global) do
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

  `name` drops the country qualifier when only one dialect of its base
  language is enabled ("German (Germany)" → "German"); enabling a sibling
  dialect (en-US + en-GB) brings the qualifier back. Same rule as the
  navigation dropdowns — see `PhoenixKitWeb.Components.Core.LanguageSwitcher.dedupe_names/1`.
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
      |> LanguageSwitcher.dedupe_names()
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
        if same_base?(lang, new_primary) do
          # A dialect sibling of the NEW primary (typically the old
          # primary itself after an en → en-US style rekey) must not
          # survive as an override: its content was already promoted,
          # and a stale ghost would hijack the base-code fallback for
          # every other dialect of that language.
          Map.delete(acc, lang)
        else
          # Reconstruct full data using OLD primary as base (overrides
          # were against old primary), then diff against the NEW primary.
          full_lang_data = Map.merge(old_primary_data, lang_data)
          overrides = compute_overrides(full_lang_data, promoted)
          put_or_remove_language(acc, lang, overrides)
        end

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
  rescue
    _ -> false
  end

  defp enabled_language_codes do
    if Code.ensure_loaded?(Languages) and
         function_exported?(Languages, :get_enabled_language_codes, 0) do
      Languages.get_enabled_language_codes()
    else
      [default_language_code()]
    end
  rescue
    _ -> [default_language_code()]
  end

  defp default_language_code do
    Languages.primary_language_code()
  rescue
    _ -> PhoenixKit.Config.default_locale()
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
