defmodule PhoenixKit.Modules.Billing.Subscription do
  @moduledoc """
  Schema for subscriptions (master record).

  Subscriptions are controlled internally by PhoenixKit, NOT by payment providers.
  This allows using any payment provider (even those without subscription APIs)
  and provides full control over subscription lifecycle.

  ## Status Lifecycle

  ```
  trialing -> active -> [past_due -> active] -> cancelled
                     -> paused -> active
                     -> cancelled
  ```

  - `trialing` - Free trial period active
  - `active` - Subscription is active and paid
  - `past_due` - Payment failed, in grace period
  - `paused` - Subscription temporarily paused by user
  - `cancelled` - Subscription ended

  ## Renewal Process

  Renewals are handled by Oban workers:
  1. `SubscriptionRenewalWorker` runs daily, checks subscriptions near period end
  2. Creates invoice for the subscription
  3. Charges saved payment method via provider
  4. On success: extends `current_period_end`
  5. On failure: sets status to `past_due`, increments `renewal_attempts`

  ## Grace Period (Dunning)

  When payment fails:
  1. Status changes to `past_due`
  2. `grace_period_end` is set (configurable days)
  3. `SubscriptionDunningWorker` retries payment
  4. After max attempts or grace period end: subscription cancelled
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Modules.Billing.{BillingProfile, PaymentMethod, SubscriptionType}
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @statuses ~w(trialing active past_due paused cancelled)

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_subscriptions" do
    field :status, :string, default: "active"

    # Billing period
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime

    # Cancellation
    field :cancel_at_period_end, :boolean, default: false
    field :cancelled_at, :utc_datetime

    # Trial
    field :trial_start, :utc_datetime
    field :trial_end, :utc_datetime

    # Dunning (failed payment handling)
    field :grace_period_end, :utc_datetime
    field :renewal_attempts, :integer, default: 0
    field :last_renewal_attempt_at, :utc_datetime

    # Metadata
    field :metadata, :map, default: %{}

    # Associations
    belongs_to :user, User, foreign_key: :user_uuid, references: :uuid, type: UUIDv7

    belongs_to :billing_profile, BillingProfile,
      foreign_key: :billing_profile_uuid,
      references: :uuid,
      type: UUIDv7

    # legacy
    field :subscription_type_id, :integer

    belongs_to :subscription_type, SubscriptionType,
      foreign_key: :subscription_type_uuid,
      references: :uuid,
      type: UUIDv7

    # legacy
    field :payment_method_id, :integer

    belongs_to :payment_method, PaymentMethod,
      foreign_key: :payment_method_uuid,
      references: :uuid,
      type: UUIDv7

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for creating a new subscription.
  """
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :status,
      :current_period_start,
      :current_period_end,
      :cancel_at_period_end,
      :cancelled_at,
      :trial_start,
      :trial_end,
      :grace_period_end,
      :renewal_attempts,
      :last_renewal_attempt_at,
      :metadata,
      :user_uuid,
      :billing_profile_uuid,
      :subscription_type_uuid,
      :payment_method_uuid
    ])
    |> validate_required([
      :user_uuid,
      :subscription_type_uuid,
      :current_period_start,
      :current_period_end
    ])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_uuid)
    |> foreign_key_constraint(:billing_profile_uuid)
    |> foreign_key_constraint(:subscription_type_uuid)
    |> foreign_key_constraint(:payment_method_uuid)
  end

  @doc """
  Changeset for activating a subscription after successful payment.
  """
  def activate_changeset(subscription, period_end) do
    subscription
    |> change(%{
      status: "active",
      current_period_end: period_end,
      renewal_attempts: 0,
      grace_period_end: nil
    })
  end

  @doc """
  Changeset for marking subscription as past_due.
  """
  def past_due_changeset(subscription, grace_period_end) do
    subscription
    |> change(%{
      status: "past_due",
      grace_period_end: grace_period_end,
      renewal_attempts: subscription.renewal_attempts + 1,
      last_renewal_attempt_at: UtilsDate.utc_now()
    })
  end

  @doc """
  Changeset for pausing a subscription.
  """
  def pause_changeset(subscription) do
    subscription
    |> change(%{status: "paused"})
  end

  @doc """
  Changeset for resuming a paused subscription.
  """
  def resume_changeset(subscription) do
    subscription
    |> change(%{status: "active"})
  end

  @doc """
  Changeset for cancelling a subscription.
  """
  def cancel_changeset(subscription, immediately \\ false) do
    if immediately do
      subscription
      |> change(%{
        status: "cancelled",
        cancelled_at: UtilsDate.utc_now()
      })
    else
      subscription
      |> change(%{
        cancel_at_period_end: true
      })
    end
  end

  @doc """
  Changeset for starting a trial.
  """
  def trial_changeset(subscription, trial_end) do
    subscription
    |> change(%{
      status: "trialing",
      trial_start: UtilsDate.utc_now(),
      trial_end: trial_end
    })
  end

  # ============================================
  # Status Helpers
  # ============================================

  @doc """
  Returns true if the subscription is currently active (can use service).
  """
  def active?(%__MODULE__{status: status}) when status in ["active", "trialing", "past_due"] do
    true
  end

  def active?(_), do: false

  @doc """
  Returns true if the subscription is in trial period.
  """
  def trialing?(%__MODULE__{status: "trialing"}), do: true
  def trialing?(_), do: false

  @doc """
  Returns true if the subscription is past due (payment failed).
  """
  def past_due?(%__MODULE__{status: "past_due"}), do: true
  def past_due?(_), do: false

  @doc """
  Returns true if the subscription is cancelled.
  """
  def cancelled?(%__MODULE__{status: "cancelled"}), do: true
  def cancelled?(_), do: false

  @doc """
  Returns true if the subscription is paused.
  """
  def paused?(%__MODULE__{status: "paused"}), do: true
  def paused?(_), do: false

  @doc """
  Returns true if the subscription will be cancelled at period end.
  """
  def cancelling?(%__MODULE__{cancel_at_period_end: true}), do: true
  def cancelling?(_), do: false

  @doc """
  Returns true if renewal is due (period end is near or past).
  """
  def renewal_due?(%__MODULE__{current_period_end: period_end}) when not is_nil(period_end) do
    DateTime.compare(period_end, DateTime.utc_now()) != :gt
  end

  def renewal_due?(_), do: false

  @doc """
  Returns true if we should attempt renewal (within 24 hours of period end).
  """
  def should_renew?(%__MODULE__{current_period_end: period_end, status: status})
      when status in ["active", "trialing"] and not is_nil(period_end) do
    hours_until_end = DateTime.diff(period_end, DateTime.utc_now(), :hour)
    hours_until_end <= 24
  end

  def should_renew?(_), do: false

  @doc """
  Returns true if grace period has expired.
  """
  def grace_period_expired?(%__MODULE__{grace_period_end: nil}), do: false

  def grace_period_expired?(%__MODULE__{grace_period_end: grace_end}) do
    DateTime.compare(grace_end, DateTime.utc_now()) != :gt
  end

  @doc """
  Returns the number of days remaining in the current period.
  """
  def days_remaining(%__MODULE__{current_period_end: nil}), do: 0

  def days_remaining(%__MODULE__{current_period_end: period_end}) do
    case DateTime.diff(period_end, DateTime.utc_now(), :day) do
      days when days > 0 -> days
      _ -> 0
    end
  end
end
