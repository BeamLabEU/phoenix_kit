defmodule PhoenixKit.Utils.CountryData do
  @moduledoc """
  Core country data utilities powered by BeamLabCountries.

  Provides country information, tax rates, EU membership, and address formatting
  for use across all PhoenixKit modules. This is the canonical source for
  country-related data and tax configuration.

  ## Tax Configuration

  Tax settings are stored in the `company_info` JSON setting alongside other
  organization data. The `get_tax_config/0` function provides a unified way
  to access tax configuration from any module.

  ## Examples

      # Get list of countries for dropdown
      countries = CountryData.countries_for_select()

      # Get standard VAT rate
      rate = CountryData.get_standard_vat_rate("EE")
      # #Decimal<0.20>

      # Check EU membership
      CountryData.eu_member?("EE")
      # true

      # Get tax configuration
      config = CountryData.get_tax_config()
      # %{enabled: true, rate: "20", rate_decimal: #Decimal<0.20>}
  """

  alias PhoenixKit.Settings

  # ============================================================================
  # Country Lookup
  # ============================================================================

  @doc """
  Get all countries sorted by name.
  """
  def list_countries do
    BeamLabCountries.all()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Get country by alpha-2 code.
  """
  def get_country(code) when is_binary(code), do: BeamLabCountries.get(code)
  def get_country(_), do: nil

  @doc """
  Get country name.
  """
  def get_country_name(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{name: name} -> name
      _ -> nil
    end
  end

  def get_country_name(_), do: nil

  @doc """
  Get country flag (emoji).
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
  """
  def exists?(country_code) when is_binary(country_code), do: get_country(country_code) != nil
  def exists?(_), do: false

  @doc """
  Get country currency code.
  """
  def get_currency_code(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{currency_code: code} when is_binary(code) -> code
      _ -> nil
    end
  end

  def get_currency_code(_), do: nil

  # ============================================================================
  # VAT / Tax Rates
  # ============================================================================

  @doc """
  Get standard VAT rate for a country as Decimal.

  Returns rate in decimal format (0.20 = 20%).
  If country not found or has no VAT rates, returns 0.

  ## Examples

      iex> CountryData.get_standard_vat_rate("EE")
      #Decimal<0.20>

      iex> CountryData.get_standard_vat_rate("US")
      #Decimal<0>
  """
  def get_standard_vat_rate(country_code) when is_binary(country_code) do
    case get_country(country_code) do
      %{vat_rates: %{standard: rate}} when is_number(rate) ->
        rate |> Decimal.new() |> Decimal.div(100)

      _ ->
        Decimal.new("0")
    end
  end

  def get_standard_vat_rate(_), do: Decimal.new("0")

  @doc """
  Get standard VAT rate as percentage (integer).

  Returns rate as percentage (20 = 20%).
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

  This is the canonical source of tax configuration for all modules.
  Billing and Shop modules should use this instead of their own settings keys.

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
        # Fallback to legacy billing key
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
        # Fallback to legacy billing key
        Settings.get_setting_cached("billing_default_tax_rate", "0")

      rate when is_binary(rate) ->
        rate

      rate when is_number(rate) ->
        to_string(rate)
    end
  end

  # ============================================================================
  # EU / EEA Membership
  # ============================================================================

  @doc """
  Check if country is an EU member.
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
  """
  def eu_countries, do: BeamLabCountries.filter_by(:eu_member, true)

  @doc """
  Get list of EEA countries (EU + Norway, Iceland, Liechtenstein).
  """
  def eea_countries, do: BeamLabCountries.filter_by(:eea_member, true)

  # ============================================================================
  # Select Helpers
  # ============================================================================

  @doc """
  Get list of countries for select dropdown.

  Returns list of tuples {display_name, alpha2_code}.
  """
  def countries_for_select do
    list_countries()
    |> Enum.map(fn c ->
      display_name =
        case c.flag do
          nil -> c.name
          "" -> c.name
          flag -> flag <> " " <> c.name
        end

      {display_name, c.alpha2}
    end)
  end

  @doc """
  Get list of EU countries for select dropdown.
  """
  def eu_countries_for_select do
    eu_countries()
    |> Enum.sort_by(& &1.name)
    |> Enum.map(fn c ->
      display_name =
        case c.flag do
          nil -> c.name
          "" -> c.name
          flag -> flag <> " " <> c.name
        end

      {display_name, c.alpha2}
    end)
  end

  @doc """
  Get the subdivision label for a country.
  """
  def get_subdivision_label(nil), do: "State/Province"
  def get_subdivision_label(""), do: "State/Province"

  def get_subdivision_label(alpha2) when is_binary(alpha2) do
    case BeamLabCountries.get(alpha2) do
      nil -> "State/Province"
      country -> Map.get(country, :subdivision_type) || "State/Province"
    end
  end

  # ============================================================================
  # Company Info & Address (from Organization Settings)
  # ============================================================================

  @doc """
  Get company information from consolidated Settings.

  Reads from `company_info` JSONB with fallback to legacy `billing_company_*` keys.
  """
  def get_company_info do
    case Settings.get_json_setting("company_info", nil) do
      nil ->
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

  @doc """
  Format company address from Settings for document printing.
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

  # ============================================================================
  # Private: Charlist bug workaround
  # ============================================================================

  defp normalize_rates(rates) when is_map(rates) do
    Map.new(rates, fn {k, v} -> {k, normalize_rate_value(v)} end)
  end

  defp normalize_rate_value(nil), do: nil

  defp normalize_rate_value(list) when is_list(list) do
    if charlist_single_digit?(list) do
      [hd(list)]
    else
      Enum.map(list, &ensure_number/1)
    end
  end

  defp normalize_rate_value(value), do: value

  defp charlist_single_digit?([n]) when is_integer(n) and n >= 0 and n <= 127, do: true
  defp charlist_single_digit?(_), do: false

  defp ensure_number(n) when is_integer(n), do: n
  defp ensure_number(n) when is_float(n), do: n
  defp ensure_number(_), do: nil
end
