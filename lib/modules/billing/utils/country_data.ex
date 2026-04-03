defmodule PhoenixKit.Modules.Billing.CountryData do
  @moduledoc """
  Billing-specific country data utilities.

  Delegates core country/tax functions to `PhoenixKit.Utils.CountryData`
  and provides billing-specific banking validation (IBAN, SWIFT).
  """

  alias PhoenixKit.Utils.CountryData, as: CoreCountryData

  # ============================================================================
  # Delegated core functions
  # ============================================================================

  defdelegate list_countries(), to: CoreCountryData
  defdelegate get_country(code), to: CoreCountryData
  defdelegate get_country_name(code), to: CoreCountryData
  defdelegate get_flag(code), to: CoreCountryData
  defdelegate exists?(code), to: CoreCountryData
  defdelegate get_currency_code(code), to: CoreCountryData

  defdelegate get_standard_vat_rate(code), to: CoreCountryData
  defdelegate get_standard_vat_percent(code), to: CoreCountryData
  defdelegate get_vat_rates(code), to: CoreCountryData

  defdelegate get_tax_config(), to: CoreCountryData

  defdelegate eu_member?(code), to: CoreCountryData
  defdelegate eea_member?(code), to: CoreCountryData
  defdelegate eu_countries(), to: CoreCountryData
  defdelegate eea_countries(), to: CoreCountryData

  defdelegate countries_for_select(), to: CoreCountryData
  defdelegate eu_countries_for_select(), to: CoreCountryData
  defdelegate get_subdivision_label(code), to: CoreCountryData

  defdelegate get_company_info(), to: CoreCountryData
  defdelegate get_bank_details(), to: CoreCountryData
  defdelegate format_company_address(), to: CoreCountryData

  # ============================================================================
  # Banking Validation (billing-specific, stays here)
  # ============================================================================

  alias PhoenixKit.Modules.Billing.IbanData

  @doc """
  Validate IBAN format (length based on bank country, not company country).
  """
  def validate_iban_format(iban, _country_code) when is_binary(iban) do
    iban = String.replace(iban, ~r/\s/, "") |> String.upcase()
    iban_country = String.slice(iban, 0, 2)
    expected_length = IbanData.get_iban_length(iban_country)

    cond do
      iban == "" ->
        :ok

      expected_length == nil ->
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
end
