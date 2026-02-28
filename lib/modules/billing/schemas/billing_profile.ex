defmodule PhoenixKit.Modules.Billing.BillingProfile do
  @moduledoc """
  Billing profile schema for PhoenixKit Billing system.

  Stores user billing information for individuals and companies (EU Standard).
  Used for generating invoices and order billing snapshots.

  ## Schema Fields

  ### Profile Identity
  - `user_id`: Foreign key to the user
  - `type`: Profile type - "individual" or "company"
  - `is_default`: Whether this is the user's default billing profile
  - `name`: Display name for the profile

  ### Individual Fields
  - `first_name`, `last_name`, `middle_name`: Person's name
  - `phone`: Contact phone number
  - `email`: Billing email (can differ from user email)

  ### Company Fields (EU Standard)
  - `company_name`: Legal company name
  - `company_vat_number`: EU VAT Number (e.g., "EE123456789")
  - `company_registration_number`: Company registration number
  - `company_legal_address`: Registered legal address

  ### Billing Address
  - `address_line1`, `address_line2`: Street address
  - `city`, `state`, `postal_code`, `country`: Location

  ## Usage Examples

      # Create individual billing profile
      {:ok, profile} = Billing.create_billing_profile(user, %{
        type: "individual",
        first_name: "John",
        last_name: "Doe",
        email: "john@example.com",
        address_line1: "123 Main St",
        city: "Tallinn",
        country: "EE",
        is_default: true
      })

      # Create company billing profile
      {:ok, profile} = Billing.create_billing_profile(user, %{
        type: "company",
        company_name: "Acme Corp OÜ",
        company_vat_number: "EE123456789",
        company_registration_number: "12345678",
        address_line1: "Business Park 1",
        city: "Tallinn",
        country: "EE"
      })
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Billing.CountryData
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @valid_types ~w(individual company)

  schema "phoenix_kit_billing_profiles" do
    field :type, :string, default: "individual"
    field :is_default, :boolean, default: false
    field :name, :string

    # Individual fields
    field :first_name, :string
    field :last_name, :string
    field :middle_name, :string
    field :phone, :string
    field :email, :string

    # Company fields (EU Standard)
    field :company_name, :string
    field :company_vat_number, :string
    field :company_registration_number, :string
    field :company_legal_address, :string

    # Billing address
    field :address_line1, :string
    field :address_line2, :string
    field :city, :string
    field :state, :string
    field :postal_code, :string
    field :country, :string, default: "EE"

    field :metadata, :map, default: %{}

    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for billing profile creation and updates.
  """
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :user_uuid,
      :type,
      :is_default,
      :name,
      :first_name,
      :last_name,
      :middle_name,
      :phone,
      :email,
      :company_name,
      :company_vat_number,
      :company_registration_number,
      :company_legal_address,
      :address_line1,
      :address_line2,
      :city,
      :state,
      :postal_code,
      :country,
      :metadata
    ])
    |> validate_required([:user_uuid, :type])
    |> validate_inclusion(:type, @valid_types)
    |> validate_length(:country, is: 2)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> validate_type_specific_fields()
    |> validate_vat_number()
    |> maybe_set_display_name()
    |> foreign_key_constraint(:user_uuid)
  end

  defp validate_type_specific_fields(changeset) do
    type = get_field(changeset, :type)

    case type do
      "individual" ->
        changeset
        |> validate_required([:first_name, :last_name], message: "is required for individuals")

      "company" ->
        changeset
        |> validate_required([:company_name], message: "is required for companies")

      _ ->
        changeset
    end
  end

  defp validate_vat_number(changeset) do
    vat = get_field(changeset, :company_vat_number)
    country = get_field(changeset, :country)

    cond do
      is_nil(vat) or vat == "" ->
        changeset

      CountryData.eu_member?(country) ->
        # Basic EU VAT format validation
        if Regex.match?(~r/^[A-Z]{2}[0-9A-Z]{2,12}$/, String.upcase(vat)) do
          put_change(changeset, :company_vat_number, String.upcase(vat))
        else
          add_error(
            changeset,
            :company_vat_number,
            "must be a valid EU VAT number (e.g., #{country}123456789)"
          )
        end

      true ->
        changeset
    end
  end

  defp maybe_set_display_name(changeset) do
    if get_field(changeset, :name) do
      changeset
    else
      type = get_field(changeset, :type)

      name =
        case type do
          "individual" ->
            first = get_field(changeset, :first_name) || ""
            last = get_field(changeset, :last_name) || ""
            String.trim("#{first} #{last}")

          "company" ->
            get_field(changeset, :company_name) || ""

          _ ->
            ""
        end

      if name != "" do
        put_change(changeset, :name, name)
      else
        changeset
      end
    end
  end

  @doc """
  Returns a snapshot of billing profile for order/invoice storage.

  This creates an immutable copy of billing details at a point in time.
  """
  def to_snapshot(%__MODULE__{} = profile) do
    %{
      profile_uuid: profile.uuid,
      type: profile.type,
      name: profile.name,
      # Individual
      first_name: profile.first_name,
      last_name: profile.last_name,
      middle_name: profile.middle_name,
      phone: profile.phone,
      email: profile.email,
      # Company
      company_name: profile.company_name,
      company_vat_number: profile.company_vat_number,
      company_registration_number: profile.company_registration_number,
      company_legal_address: profile.company_legal_address,
      # Address
      address_line1: profile.address_line1,
      address_line2: profile.address_line2,
      city: profile.city,
      state: profile.state,
      postal_code: profile.postal_code,
      country: profile.country,
      # Timestamp
      snapshot_at: UtilsDate.utc_now()
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Returns formatted address as a multi-line string.
  """
  def formatted_address(%__MODULE__{} = profile) do
    [
      profile.address_line1,
      profile.address_line2,
      [profile.postal_code, profile.city] |> Enum.reject(&is_nil/1) |> Enum.join(" "),
      profile.state,
      profile.country
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n")
  end

  @doc """
  Returns the display name for the billing profile.
  """
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name

  def display_name(%__MODULE__{type: "individual", first_name: first, last_name: last}) do
    "#{first} #{last}" |> String.trim()
  end

  def display_name(%__MODULE__{type: "company", company_name: name}), do: name || ""
  def display_name(_), do: ""
end
