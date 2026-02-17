defmodule PhoenixKit.Modules.Billing.IbanData do
  @moduledoc """
  IBAN specifications by country.

  Provides IBAN length and SEPA membership data for banking validation.
  Data sourced from IBAN.com/structure.

  ## Examples

      iex> IbanData.get_iban_length("EE")
      20

      iex> IbanData.sepa_member?("EE")
      true

      iex> IbanData.country_uses_iban?("US")
      false
  """

  @enforce_keys [:length, :sepa]
  defstruct [:length, :sepa]

  @type t :: %__MODULE__{
          length: pos_integer(),
          sepa: boolean()
        }

  @iban_specs %{
    # EU/EEA SEPA Countries
    "AD" => %{length: 24, sepa: true},
    "AT" => %{length: 20, sepa: true},
    "BE" => %{length: 16, sepa: true},
    "BG" => %{length: 22, sepa: true},
    "CH" => %{length: 21, sepa: true},
    "CY" => %{length: 28, sepa: true},
    "CZ" => %{length: 24, sepa: true},
    "DE" => %{length: 22, sepa: true},
    "DK" => %{length: 18, sepa: true},
    "EE" => %{length: 20, sepa: true},
    "ES" => %{length: 24, sepa: true},
    "FI" => %{length: 18, sepa: true},
    "FR" => %{length: 27, sepa: true},
    "GB" => %{length: 22, sepa: true},
    "GI" => %{length: 23, sepa: true},
    "GR" => %{length: 27, sepa: true},
    "HR" => %{length: 21, sepa: true},
    "HU" => %{length: 28, sepa: true},
    "IE" => %{length: 22, sepa: true},
    "IS" => %{length: 26, sepa: true},
    "IT" => %{length: 27, sepa: true},
    "LI" => %{length: 21, sepa: true},
    "LT" => %{length: 20, sepa: true},
    "LU" => %{length: 20, sepa: true},
    "LV" => %{length: 21, sepa: true},
    "MC" => %{length: 27, sepa: true},
    "MD" => %{length: 24, sepa: true},
    "ME" => %{length: 22, sepa: true},
    "MK" => %{length: 19, sepa: true},
    "MT" => %{length: 31, sepa: true},
    "NL" => %{length: 18, sepa: true},
    "NO" => %{length: 15, sepa: true},
    "PL" => %{length: 28, sepa: true},
    "PT" => %{length: 25, sepa: true},
    "RO" => %{length: 24, sepa: true},
    "RS" => %{length: 22, sepa: true},
    "SE" => %{length: 24, sepa: true},
    "SI" => %{length: 19, sepa: true},
    "SK" => %{length: 24, sepa: true},
    "SM" => %{length: 27, sepa: true},
    "VA" => %{length: 22, sepa: true},
    "XK" => %{length: 20, sepa: true},
    # Non-SEPA Countries with IBAN
    "AE" => %{length: 23, sepa: false},
    "AL" => %{length: 28, sepa: false},
    "AZ" => %{length: 28, sepa: false},
    "BA" => %{length: 20, sepa: false},
    "BH" => %{length: 22, sepa: false},
    "BR" => %{length: 29, sepa: false},
    "BY" => %{length: 28, sepa: false},
    "CR" => %{length: 22, sepa: false},
    "DO" => %{length: 28, sepa: false},
    "EG" => %{length: 29, sepa: false},
    "FO" => %{length: 18, sepa: false},
    "GE" => %{length: 22, sepa: false},
    "GL" => %{length: 18, sepa: false},
    "GT" => %{length: 28, sepa: false},
    "IL" => %{length: 23, sepa: false},
    "IQ" => %{length: 23, sepa: false},
    "JO" => %{length: 30, sepa: false},
    "KW" => %{length: 30, sepa: false},
    "KZ" => %{length: 20, sepa: false},
    "LB" => %{length: 28, sepa: false},
    "LC" => %{length: 32, sepa: false},
    "MR" => %{length: 27, sepa: false},
    "MU" => %{length: 30, sepa: false},
    "PK" => %{length: 24, sepa: false},
    "PS" => %{length: 29, sepa: false},
    "QA" => %{length: 29, sepa: false},
    "RU" => %{length: 33, sepa: false},
    "SA" => %{length: 24, sepa: false},
    "SC" => %{length: 31, sepa: false},
    "TL" => %{length: 23, sepa: false},
    "TN" => %{length: 24, sepa: false},
    "TR" => %{length: 26, sepa: false},
    "UA" => %{length: 29, sepa: false},
    "VG" => %{length: 24, sepa: false}
  }

  @doc """
  Get IBAN length for a country.

  Returns the expected IBAN length for the country code, or nil if the country
  does not use IBAN.

  ## Examples

      iex> IbanData.get_iban_length("EE")
      20

      iex> IbanData.get_iban_length("DE")
      22

      iex> IbanData.get_iban_length("US")
      nil
  """
  def get_iban_length(country_code) when is_binary(country_code) do
    case Map.get(@iban_specs, String.upcase(country_code)) do
      %{length: length} -> length
      _ -> nil
    end
  end

  def get_iban_length(_), do: nil

  @doc """
  Check if a country is a SEPA member.

  ## Examples

      iex> IbanData.sepa_member?("EE")
      true

      iex> IbanData.sepa_member?("TR")
      false

      iex> IbanData.sepa_member?("US")
      false
  """
  def sepa_member?(country_code) when is_binary(country_code) do
    case Map.get(@iban_specs, String.upcase(country_code)) do
      %{sepa: true} -> true
      _ -> false
    end
  end

  def sepa_member?(_), do: false

  @doc """
  Check if a country uses IBAN.

  ## Examples

      iex> IbanData.country_uses_iban?("EE")
      true

      iex> IbanData.country_uses_iban?("US")
      false
  """
  def country_uses_iban?(country_code) when is_binary(country_code) do
    Map.has_key?(@iban_specs, String.upcase(country_code))
  end

  def country_uses_iban?(_), do: false

  @doc """
  Get the IBAN specification for a country.

  Returns a `%IbanData{}` struct or nil if the country does not use IBAN.
  """
  def get_spec(country_code) when is_binary(country_code) do
    case Map.get(@iban_specs, String.upcase(country_code)) do
      %{length: length, sepa: sepa} -> %__MODULE__{length: length, sepa: sepa}
      _ -> nil
    end
  end

  def get_spec(_), do: nil

  @doc """
  Get all IBAN specifications.

  Returns a map of country codes to `%IbanData{}` structs.
  """
  def all_specs do
    Map.new(@iban_specs, fn {code, %{length: length, sepa: sepa}} ->
      {code, %__MODULE__{length: length, sepa: sepa}}
    end)
  end
end
