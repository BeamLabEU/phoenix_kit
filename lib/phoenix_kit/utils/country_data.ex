defmodule PhoenixKit.Utils.CountryData do
  @compile {:no_warn_undefined, PhoenixKitBilling.IbanData}
  @moduledoc """
  Wrapper for BeamLabCountries with country data utility functions.

  Provides a convenient API for working with country data:
  country selection, tax rates, EU membership.

  Includes workaround for charlist bug in VAT rates until fixed upstream.

  ## Examples

      # Get list of countries for dropdown
      countries = CountryData.countries_for_select()
      # [{"Andorra 🇦🇩", "AD"}, {"United Arab Emirates 🇦🇪", "AE"}, ...]

      # Get standard VAT rate
      rate = CountryData.get_standard_vat_rate("EE")
      # #Decimal<0.20>

      # Check EU membership
      CountryData.eu_member?("EE")
      # true

      # Get country information
      country = CountryData.get_country("DE")
      # %BeamLabCountries.Country{name: "Germany", ...}

      # Format company address from Settings
      address = CountryData.format_company_address()
      # "123 Business Street\\nTallinn 10115\\nEstonia"
  """

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.IbanData

  @doc """
  Get all countries sorted by name.

  ## Examples

      iex> countries = CountryData.list_countries()
      iex> length(countries)
      250
      iex> hd(countries).name
      "Afghanistan"
  """
  def list_countries do
    BeamLabCountries.all()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Get country by alpha-2 code.

  ## Examples

      iex> country = CountryData.get_country("EE")
      iex> country.name
      "Estonia"

      iex> CountryData.get_country("XX")
      nil
  """
  def get_country(code) when is_binary(code) do
    BeamLabCountries.get(code)
  end

  def get_country(_), do: nil

  @doc """
  Full country name for an alpha-2 code — for display, where storage keeps
  the compact ISO code (e.g. `registration_country`), in the active locale
  (`get_country_name/2`; English where that locale has no name for it). Falls
  back to the code itself when it isn't recognized, rather than showing nothing.

  ## Examples

      iex> CountryData.country_name("EE")
      "Estonia"

      iex> CountryData.country_name("XX")
      "XX"

      iex> CountryData.country_name(nil)
      nil
  """
  def country_name(nil), do: nil
  def country_name(""), do: nil

  def country_name(code) when is_binary(code), do: get_country_name(code) || code

  @doc """
  Get standard VAT rate for a country as Decimal.

  Returns rate in decimal format (0.20 = 20%).
  If country not found or has no VAT rates, returns 0.

  ## Examples

      iex> CountryData.get_standard_vat_rate("EE")
      #Decimal<0.20>

      iex> CountryData.get_standard_vat_rate("DE")
      #Decimal<0.19>

      iex> CountryData.get_standard_vat_rate("US")
      #Decimal<0>
  """
  def get_standard_vat_rate(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{vat_rates: %{standard: rate}} when is_number(rate) ->
        rate
        |> Decimal.new()
        |> Decimal.div(100)

      _ ->
        Decimal.new("0")
    end
  end

  def get_standard_vat_rate(_), do: Decimal.new("0")

  @doc """
  Get standard VAT rate as percentage (integer).

  Returns rate as percentage (20 = 20%).

  ## Examples

      iex> CountryData.get_standard_vat_percent("EE")
      20

      iex> CountryData.get_standard_vat_percent("DE")
      19

      iex> CountryData.get_standard_vat_percent("US")
      0
  """
  def get_standard_vat_percent(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{vat_rates: %{standard: rate}} when is_number(rate) -> rate
      _ -> 0
    end
  end

  def get_standard_vat_percent(_), do: 0

  @doc """
  Get all VAT rates with workaround for charlist bug.

  Returns map with normalized rates:
  - :standard - standard rate (integer)
  - :reduced - reduced rates (list of integers)
  - :super_reduced - super reduced rate (integer or nil)
  - :parking - parking rate (integer or nil)

  ## Examples

      iex> CountryData.get_vat_rates("EE")
      %{standard: 20, reduced: [9], super_reduced: nil, parking: nil}

      iex> CountryData.get_vat_rates("FR")
      %{standard: 20, reduced: [5.5, 10], super_reduced: 2.1, parking: nil}

      iex> CountryData.get_vat_rates("US")
      nil
  """
  def get_vat_rates(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{vat_rates: rates} when is_map(rates) -> normalize_rates(rates)
      _ -> nil
    end
  end

  def get_vat_rates(_), do: nil

  # ============================================================================
  # Tax Configuration (from Organization Settings)
  # ============================================================================

  @doc """
  Get the unified tax configuration from Organization settings.

  Returns a map with:
  - `:enabled` - boolean, whether tax is enabled
  - `:rate` - string percentage (e.g. "20")
  - `:rate_decimal` - Decimal fraction (e.g. Decimal.new("0.20"))

  Tax rate is stored in the `company_info` JSON setting under `"tax_rate"` and
  `"tax_enabled"` keys. Falls back to `billing_default_tax_rate` / `billing_tax_enabled`
  for backward compatibility.
  """
  def get_tax_config do
    company_info = get_company_info()

    tax_enabled = get_tax_enabled(company_info)
    tax_rate = get_tax_rate_percent(company_info)

    rate_decimal =
      case Float.parse(tax_rate) do
        {value, _} -> Decimal.div(Decimal.new("#{value}"), 100)
        :error -> Decimal.new("0")
      end

    %{enabled: tax_enabled, rate: tax_rate, rate_decimal: rate_decimal}
  end

  defp get_tax_enabled(company_info) do
    case company_info["tax_enabled"] do
      nil ->
        Settings.get_setting_cached("billing_tax_enabled", "false") == "true"

      value when is_boolean(value) ->
        value

      "true" ->
        true

      _ ->
        false
    end
  end

  defp get_tax_rate_percent(company_info) do
    case company_info["tax_rate"] do
      nil ->
        Settings.get_setting_cached("billing_default_tax_rate", "0")

      rate when is_binary(rate) ->
        rate

      rate when is_number(rate) ->
        to_string(rate)
    end
  end

  @doc """
  Check if country is an EU member.

  ## Examples

      iex> CountryData.eu_member?("EE")
      true

      iex> CountryData.eu_member?("GB")
      false

      iex> CountryData.eu_member?("US")
      false
  """
  def eu_member?(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{eu_member: true} -> true
      _ -> false
    end
  end

  def eu_member?(_), do: false

  @doc """
  Check if country is an EEA (European Economic Area) member.

  EEA includes EU + Norway, Iceland, Liechtenstein.

  ## Examples

      iex> CountryData.eea_member?("EE")
      true

      iex> CountryData.eea_member?("NO")
      true

      iex> CountryData.eea_member?("CH")
      false
  """
  def eea_member?(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{eea_member: true} -> true
      _ -> false
    end
  end

  def eea_member?(_), do: false

  @doc """
  Get list of EU countries.

  ## Examples

      iex> eu = CountryData.eu_countries()
      iex> length(eu)
      27
      iex> Enum.map(eu, & &1.alpha2) |> Enum.sort() |> Enum.take(5)
      ["AT", "BE", "BG", "CY", "CZ"]
  """
  def eu_countries do
    BeamLabCountries.filter_by(:eu_member, true)
  end

  @doc """
  Get list of EEA countries (EU + Norway, Iceland, Liechtenstein).
  """
  def eea_countries do
    BeamLabCountries.filter_by(:eea_member, true)
  end

  @doc """
  Get list of countries for select dropdown.

  Returns list of tuples {display_name, alpha2_code} for use
  in Phoenix form selects, sorted by the country name in the active locale.

  Names come from `BeamLabCountries.Translations`, not the country struct's
  `:name` field — the two differ even in English, for 20 of the 250
  countries (as of beamlab_countries 1.1.0). For example: GB "United
  Kingdom of Great Britain and Northern Ireland" -> "United Kingdom", US
  "United States of America" -> "United States", CZ "Czech Republic" ->
  "Czechia", TR "Turkey" -> "Türkiye", KP "Korea (Democratic People's
  Republic of)" -> "North Korea" (which also moves its place in the sorted
  list, from the K's to the N's). A host that never passes `:locale` still
  gets different strings, and a different order, than a version of this
  function that read `.name` directly.

  Sorting folds accented letters to their base form before comparing (e.g.
  "ü" sorts with "u"), which is a deliberate approximation, not proper
  collation — the BEAM has no ICU. It is correct for most Latin-script
  locales, but wrong for locales that give diacritics their own place in
  the alphabet: in Estonian, Ü belongs at the very end (after W, Õ, Ä, Ö),
  and in Swedish, Å, Ä, Ö belong after Z; folding moves those names out of
  that position instead of leaving them there. A host that needs strict
  local collation should sort the returned list itself.

  ## Options

    * `:locale` — locale for the country names. Defaults to the active
      `PhoenixKitWeb.Gettext` locale, reduced to its base code (`"ru-RU"`
      normalizes to `"ru"`). `BeamLabCountries` 1.1.0 ships translations for
      `ar`, `de`, `en`, `es`, `fr`, `it`, `ja`, `ko`, `nl`, `pl`, `pt`, `ru`,
      `sv`, `uk`, `zh` (`BeamLabCountries.Translations.supported_locales/0`);
      any other locale falls back to the country's English name, and so
      does an unsupported *value* such as an atom (`locale: :ru`) — a host
      only ever loses the translation, never the entry.

    * `:priority` — alpha-2 codes pinned to the top of the list, in the order
      given; everything else follows alphabetically. A non-list value is
      treated as `[]`. The default is the `country_select_priority` setting
      (Admin → Settings → Organization), and nothing else: **there is no
      compile-time config**, deliberately. A default baked into the library
      would pin whatever countries its author serves, so every other host
      would install it and find the dropdown already reordered before anyone
      chose anything. Until an operator stores a list, nothing is pinned and
      the order is plain alphabetical; `suggested_priority/2` is what the
      settings UI offers them as a starting point, derived from their own
      country rather than from a constant.

  `opts` itself must be a keyword list — a map or a bare string raises
  `FunctionClauseError` naming this function rather than `Keyword`.

  ## Examples

      iex> countries = CountryData.countries_for_select(locale: "en")
      iex> {"Afghanistan 🇦🇫", "AF"} in countries
      true

      iex> CountryData.countries_for_select(locale: "ru", priority: ["EE", "FI"])
      ...> |> Enum.take(2)
      [{"Эстония 🇪🇪", "EE"}, {"Финляндия 🇫🇮", "FI"}]
  """
  def countries_for_select(opts \\ []) when is_list(opts) do
    locale = opts |> fetch_opt(:locale, &active_locale/0) |> normalize_locale()
    priority = opts |> fetch_opt(:priority, &configured_priority/0) |> normalize_priority()

    {pinned, rest} = locale |> sorted_entries(:all) |> split_priority(priority)

    Enum.map(pinned ++ rest, fn {_name, display_name, code} -> {display_name, code} end)
  end

  @doc """
  Get the subdivision label for a country.

  Returns appropriate label like "State", "Province", "Region", etc.
  based on what the country uses for administrative divisions.

  ## Examples

      iex> CountryData.get_subdivision_label("US")
      "State"

      iex> CountryData.get_subdivision_label("CA")
      "Provinces and territories"

      iex> CountryData.get_subdivision_label("EE")
      "County"
  """
  def get_subdivision_label(nil), do: "State/Province"
  def get_subdivision_label(""), do: "State/Province"

  def get_subdivision_label(alpha2) when is_binary(alpha2) do
    case BeamLabCountries.get(alpha2) do
      nil -> "State/Province"
      country -> Map.get(country, :subdivision_type) || "State/Province"
    end
  end

  @doc """
  Subdivisions (states, provinces, counties, …) for a country, as
  `{display_name, id}` pairs sorted alphabetically by display name — the
  same tuple shape `countries_for_select/1` returns, ready for a
  `<.select>`'s `options`. Empty for a country with no subdivision data
  (26 of 250, mostly small territories — check with `subdivisions?/1`
  before deciding whether to render a dropdown at all).

  IDs are the short codes `BeamLabCountries.Subdivisions` ships (e.g. US
  states as their USPS 2-letter code, Canadian provinces/territories as
  their standard 2-letter code) — stable, storage-worthy values, unlike a
  free-typed name.

  ## Examples

      iex> {name, "CA"} = CountryData.subdivisions_for_select("US") |> List.keyfind("CA", 1)
      iex> name
      "California"

      iex> CountryData.subdivisions_for_select("XX")
      []
  """
  @spec subdivisions_for_select(String.t(), keyword()) :: [{String.t(), String.t()}]
  def subdivisions_for_select(country_code, opts \\ [])
      when is_binary(country_code) and is_list(opts) do
    locale = opts |> fetch_opt(:locale, &active_locale/0) |> normalize_locale()

    country_code
    |> BeamLabCountries.Subdivisions.all()
    |> Enum.map(&subdivision_select_entry(&1, locale))
    |> sort_by_name()
    |> Enum.map(fn {_name, display_name, id} -> {display_name, id} end)
  end

  @doc """
  Whether `country_code` has subdivision data at all — the cheap check
  before choosing a `<.select>` (subdivisions) over free text.

  ## Examples

      iex> CountryData.subdivisions?("US")
      true

      iex> CountryData.subdivisions?("XX")
      false
  """
  @spec subdivisions?(String.t()) :: boolean()
  def subdivisions?(country_code) when is_binary(country_code) do
    BeamLabCountries.Subdivisions.all(country_code) != []
  end

  def subdivisions?(_), do: false

  # {sortable_name, display_name, id} — mirrors select_entry/2's shape so
  # both can share sort_by_name/1. Subdivisions have no flag to prefix.
  defp subdivision_select_entry(%{id: id, name: name, translations: translations}, locale) do
    display_name = subdivision_translated_name(name, translations, locale)
    {display_name, display_name, id}
  end

  # String-keyed lookup, not `String.to_existing_atom(locale)` on the
  # struct's atom-keyed `translations` map: `locale` is caller-controlled
  # (a query param on some future embed, not just Gettext's own bounded
  # set), and turning arbitrary input into an atom lookup — existing or
  # not — is the kind of thing that is fine until it isn't.
  defp subdivision_translated_name(name, translations, locale)
       when is_map(translations) and is_binary(locale) do
    translations
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.get(locale, name)
  end

  defp subdivision_translated_name(name, _translations, _locale), do: name

  @doc """
  Label for the tax-identifier field, by country — "VAT Number" is wrong
  outside VAT jurisdictions, so this is not just copy, it is the label
  `validate_tax_id/2`'s format checking actually matches.

  ## Examples

      iex> CountryData.tax_id_label("US")
      "EIN"

      iex> CountryData.tax_id_label("CA")
      "Business Number (BN)"

      iex> CountryData.tax_id_label("DE")
      "VAT Number"

      iex> CountryData.tax_id_label("JP")
      "Tax ID"
  """
  @spec tax_id_label(String.t()) :: String.t()
  def tax_id_label("US"), do: "EIN"
  def tax_id_label("CA"), do: "Business Number (BN)"

  def tax_id_label(country_code) when is_binary(country_code) do
    if eu_member?(country_code), do: "VAT Number", else: "Tax ID"
  end

  def tax_id_label(_), do: "Tax ID"

  @doc """
  Label for the postal-code field, by country. Everyone but the US calls
  it "Postal Code" (Canada's own term, not just a fallback — confirmed,
  not assumed).

  ## Examples

      iex> CountryData.postal_code_label("US")
      "ZIP Code"

      iex> CountryData.postal_code_label("CA")
      "Postal Code"
  """
  @spec postal_code_label(String.t()) :: String.t()
  def postal_code_label("US"), do: "ZIP Code"
  def postal_code_label(_), do: "Postal Code"

  @doc """
  Validates a tax identifier's format for the countries whose format is
  actually known here (US EIN, Canadian BN, EU VAT) — everyone else
  passes unconditionally, same as an unset value. This checks *shape*,
  not a real registry — a well-formed EIN that was never issued still
  passes.

  ## Examples

      iex> CountryData.validate_tax_id("US", "12-3456789")
      :ok

      iex> CountryData.validate_tax_id("US", "not an ein")
      {:error, "must look like an EIN, e.g. 12-3456789"}

      iex> CountryData.validate_tax_id("CA", "123456789RT0001")
      :ok

      iex> CountryData.validate_tax_id("JP", "anything goes here")
      :ok
  """
  @spec validate_tax_id(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_tax_id(_country_code, value) when value in [nil, ""], do: :ok

  def validate_tax_id("US", value) do
    if Regex.match?(~r/^\d{2}-?\d{7}$/, value) do
      :ok
    else
      {:error, "must look like an EIN, e.g. 12-3456789"}
    end
  end

  def validate_tax_id("CA", value) do
    if Regex.match?(~r/^\d{9}([A-Za-z]{2}\d{4})?$/, value) do
      :ok
    else
      {:error, "must look like a Business Number, e.g. 123456789 or 123456789RT0001"}
    end
  end

  def validate_tax_id(country_code, value) when is_binary(country_code) do
    if eu_member?(country_code) do
      if Regex.match?(~r/^[A-Z]{2}[0-9A-Z]{2,12}$/, String.upcase(value)) do
        :ok
      else
        {:error, "must look like an EU VAT number, e.g. #{country_code}123456789"}
      end
    else
      :ok
    end
  end

  def validate_tax_id(_country_code, _value), do: :ok

  @doc """
  Validates a postal/ZIP code's format for the countries whose format is
  known here (US, Canada) — everyone else passes unconditionally.

  ## Examples

      iex> CountryData.validate_postal_code("US", "10001")
      :ok

      iex> CountryData.validate_postal_code("US", "abcde")
      {:error, "must look like a ZIP code, e.g. 10001 or 10001-1234"}

      iex> CountryData.validate_postal_code("CA", "K1A 0B1")
      :ok

      iex> CountryData.validate_postal_code("JP", "whatever")
      :ok
  """
  @spec validate_postal_code(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_postal_code(_country_code, value) when value in [nil, ""], do: :ok

  def validate_postal_code("US", value) do
    if Regex.match?(~r/^\d{5}(-\d{4})?$/, value) do
      :ok
    else
      {:error, "must look like a ZIP code, e.g. 10001 or 10001-1234"}
    end
  end

  def validate_postal_code("CA", value) do
    if Regex.match?(~r/^[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z]\s?\d[ABCEGHJ-NPRSTV-Z]\d$/i, value) do
      :ok
    else
      {:error, "must look like a Canadian postal code, e.g. K1A 0B1"}
    end
  end

  def validate_postal_code(_country_code, _value), do: :ok

  @doc """
  Get list of EU countries for select dropdown.

  Takes the same `:locale` and `:priority` options as
  `countries_for_select/1`, including its fallback, leniency, and sorting
  caveats.
  """
  def eu_countries_for_select(opts \\ []) when is_list(opts) do
    locale = opts |> fetch_opt(:locale, &active_locale/0) |> normalize_locale()
    priority = opts |> fetch_opt(:priority, &configured_priority/0) |> normalize_priority()

    {pinned, rest} = locale |> sorted_entries(:eu) |> split_priority(priority)

    Enum.map(pinned ++ rest, fn {_name, display_name, code} -> {display_name, code} end)
  end

  # {sortable_name, display_name, alpha2} for one country in `locale`. The
  # flag goes AFTER the name: a native <select> jumps to an option by the
  # first characters typed, so a leading flag made typing "Est" find nothing.
  defp select_entry(country, locale) do
    name = translated_name(country, locale)

    display_name =
      case country.flag do
        nil -> name
        "" -> name
        flag -> name <> " " <> flag
      end

    {name, display_name, country.alpha2}
  end

  defp translated_name(country, locale) do
    with true <- is_binary(locale),
         true <- BeamLabCountries.Translations.locale_supported?(locale),
         name when is_binary(name) <-
           BeamLabCountries.Translations.get_name(country.alpha2, locale) do
      name
    else
      _ -> country.name
    end
  end

  # Localized, alphabetically-sorted {sortable_name, display_name, alpha2}
  # entries for `source` (:all or :eu), memoized in :persistent_term per
  # locale — countries_for_select/1 runs in LiveView mount twice per
  # connection, and rebuilding + sort-keying ~250 translated names on every
  # call was measured as the expensive part (the translation lookup itself
  # is cheap). Keyed by locale *and* source so the EU subset can never
  # collide with the full list. A cache miss computes once and stores;
  # realistic callers only ever use the handful of locales this host's
  # Gettext config and BeamLabCountries between them support, so the number
  # of distinct writes is bounded. Priority pinning is deliberately *not*
  # part of the cache key — split_priority/2 below is cheap (one pass over
  # already-sorted input) and runs on every call, so
  # `:country_select_priority` changes take effect immediately without
  # invalidating anything.
  defp sorted_entries(locale, source) do
    key = {__MODULE__, :sorted_entries, source, locale}

    case :persistent_term.get(key, :not_cached) do
      :not_cached ->
        entries =
          source
          |> countries_for_source()
          |> Enum.map(&select_entry(&1, locale))
          |> sort_by_name()

        :persistent_term.put(key, entries)
        entries

      entries ->
        entries
    end
  end

  defp countries_for_source(:all), do: BeamLabCountries.all()
  defp countries_for_source(:eu), do: eu_countries()

  # Pull the priority codes out in the order they were given; the remainder
  # keeps its incoming order. Callers now pass the already-sorted output of
  # sorted_entries/2, so that incoming order is alphabetical — no further
  # sort needed.
  defp split_priority(entries, []), do: {[], entries}

  defp split_priority(entries, priority) do
    index = Map.new(entries, fn {_name, _display, code} = entry -> {code, entry} end)

    pinned_codes = Enum.filter(priority, &Map.has_key?(index, &1))
    pinned = Enum.map(pinned_codes, &Map.fetch!(index, &1))
    rest = Enum.reject(entries, fn {_name, _display, code} -> code in pinned_codes end)

    {pinned, rest}
  end

  # Deliberate approximation, not proper collation: folding diacritics to
  # their base letter before comparing is correct for locales that treat
  # accented letters as variants of the base letter — most Latin-script
  # locales (French, German, Spanish, Italian, Dutch, Polish, Portuguese,
  # ...) — but wrong for locales that give diacritics their own position in
  # the alphabet. Estonian sorts Ü at the very end, after W, Õ, Ä, Ö;
  # Swedish sorts Å, Ä, Ö after Z. Folding pulls "Ühendkuningriik" into the U
  # block and "Åland" between "Azerbajdzjan" and "Bahamas" instead of
  # leaving them at the end, which is where correct collation puts them in
  # those locales. Proper per-locale collation would need ICU, which the
  # BEAM does not ship.
  defp sort_by_name(entries) do
    Enum.sort_by(entries, fn {name, _display, _code} ->
      name |> String.downcase() |> :unicode.characters_to_nfd_binary()
    end)
  end

  defp active_locale do
    Gettext.get_locale(PhoenixKitWeb.Gettext)
  end

  defp normalize_locale(nil), do: nil

  defp normalize_locale(locale) when is_binary(locale) do
    locale |> String.split(["-", "_"]) |> hd() |> String.downcase()
  end

  defp normalize_locale(_), do: nil

  # Keyword.get(opts, key, default) evaluates `default` eagerly even when
  # `opts` already has `key` — cheap when the default is a literal, but here
  # the defaults are a Gettext lookup and a settings-cache read (which can
  # fall through to a database query on a cold key), and the result would be
  # thrown away whenever the caller passed an explicit value. Only compute
  # the default in the :error branch.
  defp fetch_opt(opts, key, default_fun) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> default_fun.()
    end
  end

  # The stored setting is the ONLY source. There is deliberately no
  # compile-time config fallback: a default baked into the library would
  # pin whatever countries its author happens to serve, and every other
  # host installs it to find a list already filtered before anyone chose
  # anything. Nothing is pinned until an operator says so — see
  # `suggested_priority/2` for how the settings UI proposes a starting
  # list from the organization's own country instead of from a constant.
  #
  # Read through the cache: this runs on the hot path, and
  # `get_setting_cached/2` is consulted before the update-mode
  # short-circuit, so a primed key resolves without a database at all.
  # `Settings.get_setting_cached/2` — and the `get_setting/2` it falls back
  # to on a cache error — already rescue AND catch `:exit` internally, so
  # an unreachable database degrades to "nothing pinned" rather than
  # raising, without this function handling anything itself.
  defp configured_priority do
    "country_select_priority"
    |> Settings.get_setting_cached("")
    |> parse_priority()
  end

  @doc """
  Split an operator-entered priority string into alpha-2 codes.

  Accepts the separators a human actually types — commas, spaces, semicolons,
  newlines — so `"EE, FI"`, `"ee fi"` and `"EE;FI"` all parse. Unknown codes
  are kept here, not dropped — `normalize_priority/1` only filters
  non-binaries, upcases, and dedupes. They are dropped later, when
  `split_priority/2` looks each one up against the real country list and
  finds no match; use `known_country_codes/1` to report them to the
  operator before that happens.

  ## Examples

      iex> CountryData.parse_priority("EE, FI ; lv")
      ["EE", "FI", "LV"]

      iex> CountryData.parse_priority("")
      []
  """
  def parse_priority(value) when is_binary(value) do
    value
    |> String.split([",", ";", " ", "\n", "\t"], trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_priority(_), do: []

  @doc """
  Keep only the codes that name a real country, in the order given.

  The counterpart of `parse_priority/1` for a settings form: it tells the
  operator which of the codes they typed will actually pin something.

  ## Examples

      iex> CountryData.known_country_codes(["EE", "ZZ", "FI"])
      ["EE", "FI"]
  """
  def known_country_codes(codes) when is_list(codes) do
    Enum.filter(codes, fn code -> is_binary(code) and get_country(code) != nil end)
  end

  def known_country_codes(_), do: []

  @doc """
  Suggest a starting priority list for a host based in `country_code`.

  Returns that country first, then its nearest neighbours by great-circle
  distance between country centroids — so a host in Estonia is offered
  Latvia, Åland, Finland and Lithuania, one in Germany gets Luxembourg,
  the Netherlands, Czechia and Belgium, and one in Singapore gets Malaysia,
  Indonesia, Cambodia and Brunei. The point is that it is derived from the
  host's own data rather than from a constant baked in by whoever wrote
  the library.

  This is a *suggestion* for the settings UI to offer, never applied on its
  own: nothing is pinned until an operator stores a list. The result can
  include dependent territories (Åland is the second-nearest thing to
  Estonia) — the data has no "sovereign state" flag — so the operator is
  expected to prune it.

  Dissolved countries are excluded. Countries with no coordinates cannot be
  ranked and are skipped.

  ## Options

    * `:limit` — how many neighbours to add after the country itself.
      Defaults to 4.

  ## Examples

      iex> CountryData.suggested_priority("EE", limit: 2)
      ["EE", "LV", "AX"]

      iex> CountryData.suggested_priority("XX")
      []
  """
  def suggested_priority(country_code, opts \\ [])

  def suggested_priority(country_code, opts) when is_binary(country_code) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, 4) |> normalize_limit()

    case get_country(country_code) do
      %{geo: %{latitude: lat, longitude: lon}} = origin when is_number(lat) and is_number(lon) ->
        [origin.alpha2 | nearest_codes(origin, limit)]

      %{} = origin ->
        [origin.alpha2]

      _ ->
        []
    end
  end

  def suggested_priority(_, _), do: []

  # A non-integer `:limit` (nil, a string, a float — Erlang term ordering
  # makes all of those `> 0`, so a guard alone won't stop them) falls back
  # to the same default `suggested_priority/2` uses when `:limit` is
  # omitted, rather than reaching `Enum.take/2` and raising.
  defp normalize_limit(limit) when is_integer(limit), do: limit
  defp normalize_limit(_), do: 4

  defp nearest_codes(origin, limit) when limit > 0 do
    BeamLabCountries.all()
    |> Enum.filter(&rankable_neighbour?(&1, origin))
    |> Enum.sort_by(&distance_km(origin, &1))
    |> Enum.take(limit)
    |> Enum.map(& &1.alpha2)
  end

  defp nearest_codes(_origin, _limit), do: []

  defp rankable_neighbour?(
         %{alpha2: code, dissolved_on: nil, geo: %{latitude: lat, longitude: lon}},
         origin
       )
       when is_number(lat) and is_number(lon),
       do: code != origin.alpha2

  defp rankable_neighbour?(_, _), do: false

  # Haversine over the country centroids the dataset carries. Centroids are a
  # coarse proxy for "neighbouring" — a large country's centroid can sit far
  # from the border it shares with the origin — but the dataset has no border
  # list, and the result only has to be a plausible starting point an operator
  # then edits.
  defp distance_km(a, b) do
    lat1 = deg_to_rad(a.geo.latitude)
    lat2 = deg_to_rad(b.geo.latitude)
    dlat = lat2 - lat1
    dlon = deg_to_rad(b.geo.longitude - a.geo.longitude)

    h =
      :math.pow(:math.sin(dlat / 2), 2) +
        :math.cos(lat1) * :math.cos(lat2) * :math.pow(:math.sin(dlon / 2), 2)

    6371 * 2 * :math.asin(min(1.0, :math.sqrt(h)))
  end

  defp deg_to_rad(degrees), do: degrees * :math.pi() / 180

  defp normalize_priority(codes) when is_list(codes) do
    codes
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.upcase/1)
    |> Enum.uniq()
  end

  defp normalize_priority(_), do: []

  @doc """
  Get country currency code.

  ## Examples

      iex> CountryData.get_currency_code("EE")
      "EUR"

      iex> CountryData.get_currency_code("GB")
      "GBP"

      iex> CountryData.get_currency_code("US")
      "USD"
  """
  def get_currency_code(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{currency_code: code} when is_binary(code) -> code
      _ -> nil
    end
  end

  def get_currency_code(_), do: nil

  @doc """
  Get country name in the active locale.

  Takes the same `:locale` option as `countries_for_select/1` — including
  its supported-locale set and its fallback/leniency rules — and falls back
  to the English name when that locale has no translation for the country.

  `opts` must be a keyword list. `get_country_name("EE", "ru")` is a
  realistic slip (the option is `:locale`), and raises
  `FunctionClauseError` naming this function rather than `Keyword`.

  ## Examples

      iex> CountryData.get_country_name("EE", locale: "en")
      "Estonia"

      iex> CountryData.get_country_name("EE", locale: "ru")
      "Эстония"

      iex> CountryData.get_country_name("XX")
      nil
  """
  def get_country_name(country_code, opts \\ [])

  def get_country_name(country_code, opts) when is_binary(country_code) and is_list(opts) do
    locale = opts |> fetch_opt(:locale, &active_locale/0) |> normalize_locale()

    case get_country(country_code) do
      %{} = country -> translated_name(country, locale)
      _ -> nil
    end
  end

  def get_country_name(country_code, _opts) when not is_binary(country_code), do: nil

  @doc """
  Get country flag (emoji).

  ## Examples

      iex> CountryData.get_flag("EE")
      "🇪🇪"
  """
  def get_flag(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{flag: flag} -> flag
      _ -> nil
    end
  end

  def get_flag(_), do: nil

  @doc """
  Check if country with given code exists.

  ## Examples

      iex> CountryData.exists?("EE")
      true

      iex> CountryData.exists?("XX")
      false
  """
  def exists?(country_code) when is_binary(country_code) do
    get_country(country_code) != nil
  end

  def exists?(_), do: false

  @doc """
  Format company address from Settings for document printing.

  Assembles address from individual fields (address_line1, address_line2, city, state,
  postal_code, country) into a single string with line breaks.

  ## Returns

  Formatted address as string, for example:
  ```
  123 Business Street
  Suite 100
  Tallinn 10115
  Estonia
  ```

  ## Examples

      iex> CountryData.format_company_address()
      "123 Business Street\\nTallinn 10115\\nEstonia"
  """
  def format_company_address do
    company_info = get_company_info()

    address_line1 = company_info["address_line1"] || ""
    address_line2 = company_info["address_line2"] || ""
    city = company_info["city"] || ""
    state = company_info["state"] || ""
    postal_code = company_info["postal_code"] || ""
    country_code = company_info["country"] || ""

    country_name =
      case get_country(country_code) do
        %{name: name} -> name
        _ -> country_code
      end

    city_postal =
      [city, postal_code]
      |> Enum.filter(&(&1 != ""))
      |> Enum.join(" ")

    [address_line1, address_line2, city_postal, state, country_name]
    |> Enum.filter(&(&1 != "" && &1 != " "))
    |> Enum.join("\n")
  end

  @doc """
  Get company information from consolidated Settings.

  Reads from `company_info` JSONB with fallback to legacy `billing_company_*` keys.
  """
  def get_company_info do
    case Settings.get_json_setting("company_info", nil) do
      nil ->
        # Fallback to legacy billing_company_* keys
        %{
          "name" => Settings.get_setting("billing_company_name", ""),
          "address_line1" => Settings.get_setting("billing_company_address_line1", ""),
          "address_line2" => Settings.get_setting("billing_company_address_line2", ""),
          "city" => Settings.get_setting("billing_company_city", ""),
          "state" => Settings.get_setting("billing_company_state", ""),
          "postal_code" => Settings.get_setting("billing_company_postal_code", ""),
          "country" => Settings.get_setting("billing_company_country", ""),
          "vat_number" => Settings.get_setting("billing_company_vat", ""),
          "registration_number" => ""
        }

      info when is_map(info) ->
        info

      _ ->
        %{}
    end
  end

  @doc """
  Get bank details from consolidated Settings.

  Reads from `company_bank_details` JSONB with fallback to legacy `billing_bank_*` keys.
  """
  def get_bank_details do
    case Settings.get_json_setting("company_bank_details", nil) do
      nil ->
        # Fallback to legacy billing_bank_* keys
        %{
          "bank_name" => Settings.get_setting("billing_bank_name", ""),
          "iban" => Settings.get_setting("billing_bank_iban", ""),
          "swift" => Settings.get_setting("billing_bank_swift", "")
        }

      info when is_map(info) ->
        info

      _ ->
        %{}
    end
  end

  # ==========================================================================
  # Banking Validation Functions
  # ==========================================================================

  @doc """
  Validate IBAN format (length based on bank country, not company country).

  Bank can be in a different country than the company - this is legal.
  Validates format and length based on IBAN's country prefix.

  Returns :ok or {:error, reason}.

  ## Examples

      iex> CountryData.validate_iban_format("EE382200221020145685", "EE")
      :ok

      iex> CountryData.validate_iban_format("DE89370400440532013000", "EE")
      :ok  # German bank for Estonian company is valid

      iex> CountryData.validate_iban_format("DE123", "EE")
      {:error, "IBAN must be 22 characters for DE"}
  """
  def validate_iban_format(iban, _country_code)
      when is_binary(iban) do
    iban = String.replace(iban, ~r/\s/, "") |> String.upcase()
    iban_country = String.slice(iban, 0, 2)

    expected_length =
      if Code.ensure_loaded?(IbanData),
        do: IbanData.get_iban_length(iban_country),
        else: nil

    cond do
      iban == "" ->
        :ok

      expected_length == nil ->
        # Unknown IBAN country - just validate basic format
        if Regex.match?(~r/^[A-Z]{2}[0-9]{2}[A-Z0-9]+$/, iban) do
          :ok
        else
          {:error, "Invalid IBAN format"}
        end

      String.length(iban) != expected_length ->
        {:error, "IBAN must be #{expected_length} characters for #{iban_country}"}

      not Regex.match?(~r/^[A-Z]{2}[0-9]{2}[A-Z0-9]+$/, iban) ->
        {:error, "Invalid IBAN format"}

      true ->
        :ok
    end
  end

  def validate_iban_format(_, _), do: :ok

  @doc """
  Validate SWIFT/BIC format (8 or 11 characters).

  SWIFT codes structure:
  - 4 letters: bank code
  - 2 letters: country code (ISO 3166)
  - 2 characters: location code
  - 3 characters (optional): branch code

  ## Examples

      iex> CountryData.validate_swift_format("HABAEE2X")
      :ok

      iex> CountryData.validate_swift_format("HABAEE2XXXX")
      :ok

      iex> CountryData.validate_swift_format("INVALID")
      {:error, "SWIFT/BIC must be 8 or 11 characters"}
  """
  def validate_swift_format(swift) when is_binary(swift) do
    swift = String.replace(swift, ~r/\s/, "") |> String.upcase()

    cond do
      swift == "" ->
        :ok

      String.length(swift) not in [8, 11] ->
        {:error, "SWIFT/BIC must be 8 or 11 characters"}

      not Regex.match?(~r/^[A-Z]{4}[A-Z]{2}[A-Z0-9]{2}([A-Z0-9]{3})?$/, swift) ->
        {:error, "Invalid SWIFT/BIC format"}

      true ->
        :ok
    end
  end

  def validate_swift_format(_), do: :ok

  # ==========================================================================
  # Private Functions - Workaround for charlist bug in BeamLabCountries
  # ==========================================================================
  #
  # YAML parser interprets single-digit numbers in lists as charlists:
  # - [9] → ~c"\t" (tab)
  # - [7] → ~c"\a" (bell)
  # - [10] → ~c"\n" (newline)
  #
  # These functions normalize data until fixed upstream.

  defp normalize_rates(rates) when is_map(rates) do
    Map.new(rates, fn {k, v} -> {k, normalize_rate_value(v)} end)
  end

  defp normalize_rate_value(nil), do: nil

  defp normalize_rate_value(list) when is_list(list) do
    # If charlist of single element (bug), convert back
    if charlist_single_digit?(list) do
      [hd(list)]
    else
      Enum.map(list, &ensure_number/1)
    end
  end

  defp normalize_rate_value(value), do: value

  # Check if list is a charlist of single ASCII digit code
  defp charlist_single_digit?([n]) when is_integer(n) and n >= 0 and n <= 127, do: true
  defp charlist_single_digit?(_), do: false

  defp ensure_number(n) when is_integer(n), do: n
  defp ensure_number(n) when is_float(n), do: n
  defp ensure_number(_), do: nil
end
