defmodule PhoenixKit.Billing.SubscriptionPlan do
  @moduledoc """
  Schema for subscription plans (pricing tiers).

  Subscription plans define the pricing, billing interval, and features
  available at each tier. Plans are managed internally and used to
  create subscriptions.

  ## Fields

  - `name` - Display name (e.g., "Basic", "Pro", "Enterprise")
  - `code` - Unique identifier code (e.g., "basic", "pro")
  - `description` - Marketing description
  - `price` - Price per billing period (Decimal)
  - `currency` - Three-letter currency code (default: "EUR")
  - `interval` - Billing interval: "day", "week", "month", "year"
  - `interval_count` - Number of intervals (e.g., 3 months)
  - `trial_days` - Free trial period in days (default: 0)
  - `features` - JSON map of features included in this plan
  - `active` - Whether this plan is available for new subscriptions
  - `sort_order` - Display order in plan listings

  ## Examples

      %SubscriptionPlan{
        name: "Professional",
        code: "pro",
        price: Decimal.new("29.99"),
        currency: "EUR",
        interval: "month",
        interval_count: 1,
        trial_days: 14,
        features: %{"api_calls" => 10000, "storage_gb" => 50},
        active: true
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.RepoHelper

  @intervals ~w(day week month year)

  schema "phoenix_kit_subscription_plans" do
    field :uuid, Ecto.UUID
    field :name, :string
    field :slug, :string
    field :description, :string
    field :price, :decimal
    field :currency, :string, default: "EUR"
    field :interval, :string, default: "month"
    field :interval_count, :integer, default: 1
    field :trial_days, :integer, default: 0
    field :features, {:array, :string}, default: []
    field :active, :boolean, default: true
    field :sort_order, :integer, default: 0
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a subscription plan.

  ## Required fields
  - `name` - Plan display name
  - `slug` - Unique plan identifier (URL-friendly)
  - `price` - Price per period

  ## Optional fields
  - `description`, `currency`, `interval`, `interval_count`
  - `trial_days`, `features`, `active`, `sort_order`, `metadata`
  """
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :price,
      :currency,
      :interval,
      :interval_count,
      :trial_days,
      :features,
      :active,
      :sort_order,
      :metadata
    ])
    |> validate_required([:name, :slug, :price])
    |> validate_inclusion(:interval, @intervals)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> validate_number(:interval_count, greater_than: 0)
    |> validate_number(:trial_days, greater_than_or_equal_to: 0)
    |> validate_length(:slug, min: 1, max: 50)
    |> validate_length(:currency, is: 3)
    |> unique_constraint(:slug)
    |> maybe_generate_uuid()
  end

  defp maybe_generate_uuid(changeset) do
    case get_field(changeset, :uuid) do
      nil -> put_change(changeset, :uuid, UUIDv7.generate())
      _ -> changeset
    end
  end

  @doc """
  Returns the billing period in days for this plan.
  """
  def billing_period_days(%__MODULE__{interval: interval, interval_count: count}) do
    base_days =
      case interval do
        "day" -> 1
        "week" -> 7
        "month" -> 30
        "year" -> 365
      end

    base_days * count
  end

  @doc """
  Calculates the next billing date from a given start date.
  """
  def next_billing_date(%__MODULE__{interval: interval, interval_count: count}, from_date) do
    case interval do
      "day" ->
        Date.add(from_date, count)

      "week" ->
        Date.add(from_date, count * 7)

      "month" ->
        # Use Elixir's Date.shift for proper month handling
        Date.shift(from_date, month: count)

      "year" ->
        Date.shift(from_date, year: count)
    end
  end

  @doc """
  Returns the formatted price string with currency.
  """
  def formatted_price(%__MODULE__{price: price, currency: currency}) do
    "#{Decimal.round(price, 2)} #{currency}"
  end

  @doc """
  Returns the billing interval description (e.g., "monthly", "every 3 months").
  """
  def interval_description(%__MODULE__{interval: interval, interval_count: 1}) do
    case interval do
      "day" -> "daily"
      "week" -> "weekly"
      "month" -> "monthly"
      "year" -> "yearly"
    end
  end

  def interval_description(%__MODULE__{interval: interval, interval_count: count}) do
    "every #{count} #{interval}s"
  end

  @doc """
  Lists all active subscription plans ordered by sort_order.
  """
  def list_active do
    import Ecto.Query

    from(p in __MODULE__,
      where: p.active == true,
      order_by: [asc: p.sort_order, asc: p.name]
    )
    |> RepoHelper.repo().all()
  end

  @doc """
  Gets a plan by its code.
  """
  def get_by_code(code) do
    RepoHelper.repo().get_by(__MODULE__, code: code)
  end
end
