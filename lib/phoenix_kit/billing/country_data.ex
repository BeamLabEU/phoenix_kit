defmodule PhoenixKit.Billing.CountryData do
  @moduledoc """
  Wrapper for BeamLabCountries with billing-specific functions.

  Provides a convenient API for working with country data in a billing context:
  country selection, tax rates, EU membership.

  Includes workaround for charlist bug in VAT rates until fixed upstream.

  ## Examples

      # Get list of countries for dropdown
      countries = CountryData.countries_for_select()
      # [{"🇦🇩 Andorra", "AD"}, {"🇦🇪 United Arab Emirates", "AE"}, ...]

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
  in Phoenix form selects.

  ## Examples

      iex> countries = CountryData.countries_for_select()
      iex> {"🇦🇫 Afghanistan", "AF"} in countries
      true
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
  Get the subdivision label for a country.

  Returns appropriate label like "State", "Province", "Region", etc.
  based on what the country uses for administrative divisions.

  ## Examples

      iex> CountryData.get_subdivision_label("US")
      "State"

      iex> CountryData.get_subdivision_label("CA")
      "Province"

      iex> CountryData.get_subdivision_label("EE")
      "County"
  """
  def get_subdivision_label(nil), do: "State/Province"
  def get_subdivision_label(""), do: "State/Province"

  def get_subdivision_label(alpha2) when is_binary(alpha2) do
    case BeamLabCountries.get(alpha2) do
      nil -> "State/Province"
      country -> country.subdivision_type || "State/Province"
    end
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
  Get country name.

  ## Examples

      iex> CountryData.get_country_name("EE")
      "Estonia"

      iex> CountryData.get_country_name("XX")
      nil
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

  alias PhoenixKit.Billing.IbanData

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
    expected_length = IbanData.get_iban_length(iban_country)

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
