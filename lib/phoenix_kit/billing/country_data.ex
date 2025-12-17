defmodule PhoenixKit.Billing.CountryData do
  @moduledoc """
  Wrapper для BeamLabCountries с функциями для биллинга.

  Предоставляет удобный API для работы с данными о странах в контексте
  биллинга: выбор страны, налоговые ставки, EU membership.

  Включает workaround для бага charlist в VAT rates до исправления в upstream.

  ## Examples

      # Получить список стран для dropdown
      countries = CountryData.countries_for_select()
      # [{"🇦🇩 Andorra", "AD"}, {"🇦🇪 United Arab Emirates", "AE"}, ...]

      # Получить стандартную VAT ставку
      rate = CountryData.get_standard_vat_rate("EE")
      # #Decimal<0.20>

      # Проверить EU membership
      CountryData.eu_member?("EE")
      # true

      # Получить информацию о стране
      country = CountryData.get_country("DE")
      # %BeamLabCountries.Country{name: "Germany", ...}

      # Форматировать адрес компании из Settings
      address = CountryData.format_company_address()
      # "123 Business Street\\nTallinn 10115\\nEstonia"
  """

  alias PhoenixKit.Settings

  @doc """
  Получить все страны отсортированные по имени.

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
  Получить страну по alpha2 коду.

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
  Получить стандартную VAT ставку для страны как Decimal.

  Возвращает ставку в десятичном формате (0.20 = 20%).
  Если страна не найдена или не имеет VAT rates, возвращает 0.

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
  Получить стандартную VAT ставку как процент (integer).

  Возвращает ставку в процентах (20 = 20%).

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
  Получить все VAT ставки с workaround для charlist бага.

  Возвращает map с нормализованными ставками:
  - :standard - стандартная ставка (integer)
  - :reduced - пониженные ставки (list of integers)
  - :super_reduced - сверхпониженная ставка (integer or nil)
  - :parking - парковочная ставка (integer or nil)

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
  Проверить является ли страна членом EU.

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
  Проверить является ли страна членом EEA (European Economic Area).

  EEA включает EU + Норвегия, Исландия, Лихтенштейн.

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
  Получить список EU стран.

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
  Получить список EEA стран (EU + Норвегия, Исландия, Лихтенштейн).
  """
  def eea_countries do
    BeamLabCountries.filter_by(:eea_member, true)
  end

  @doc """
  Получить список стран для select dropdown.

  Возвращает список кортежей {display_name, alpha2_code} для использования
  в Phoenix form selects.

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
  Получить список EU стран для select dropdown.
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
  Получить валюту страны.

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
  Получить название страны.

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
  Получить флаг страны (emoji).

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
  Проверить существует ли страна с данным кодом.

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
  Форматирует адрес компании из Settings для печати документов.

  Собирает адрес из отдельных полей (address_line1, address_line2, city, state,
  postal_code, country) в единую строку с переносами строк.

  ## Returns

  Отформатированный адрес в виде строки, например:
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
    address_line1 = Settings.get_setting("billing_company_address_line1", "")
    address_line2 = Settings.get_setting("billing_company_address_line2", "")
    city = Settings.get_setting("billing_company_city", "")
    state = Settings.get_setting("billing_company_state", "")
    postal_code = Settings.get_setting("billing_company_postal_code", "")
    country_code = Settings.get_setting("billing_company_country", "")

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
  # YAML парсер интерпретирует однозначные числа в списках как charlist:
  # - [9] → ~c"\t" (tab)
  # - [7] → ~c"\a" (bell)
  # - [10] → ~c"\n" (newline)
  #
  # Эти функции нормализуют данные до исправления в upstream.

  defp normalize_rates(rates) when is_map(rates) do
    Map.new(rates, fn {k, v} -> {k, normalize_rate_value(v)} end)
  end

  defp normalize_rate_value(nil), do: nil

  defp normalize_rate_value(list) when is_list(list) do
    # Если это charlist из одного элемента (баг), конвертируем обратно
    if charlist_single_digit?(list) do
      [hd(list)]
    else
      Enum.map(list, &ensure_number/1)
    end
  end

  defp normalize_rate_value(value), do: value

  # Проверяем является ли список charlist-ом из одного ASCII кода цифры
  defp charlist_single_digit?([n]) when is_integer(n) and n >= 0 and n <= 127, do: true
  defp charlist_single_digit?(_), do: false

  defp ensure_number(n) when is_integer(n), do: n
  defp ensure_number(n) when is_float(n), do: n
  defp ensure_number(_), do: nil
end
