defmodule PhoenixKit.Modules.Billing.Workers.SubscriptionRenewalWorker do
  @moduledoc """
  Oban worker for processing subscription renewals.

  This worker runs daily and handles:
  - Finding subscriptions due for renewal (within 24 hours of period end)
  - Creating invoices for the renewal
  - Charging saved payment methods via providers
  - Updating subscription periods on success
  - Moving to past_due status on failure

  ## Scheduling

  The worker should be scheduled to run daily via Oban crontab:

  ```elixir
  config :my_app, Oban,
    queues: [default: 10, billing: 5],
    plugins: [
      {Oban.Plugins.Cron,
       crontab: [
         {"0 6 * * *", PhoenixKit.Modules.Billing.Workers.SubscriptionRenewalWorker}
       ]}
    ]
  ```

  ## Process Flow

  1. Query subscriptions where `current_period_end` is within 24 hours
  2. For each subscription:
     a. Skip if cancel_at_period_end is true
     b. Create renewal invoice
     c. Charge saved payment method
     d. On success: extend period_end, update invoice as paid
     e. On failure: set past_due, schedule dunning

  ## Manual Trigger

  Can be triggered manually for a specific subscription:

  ```elixir
  %{subscription_id: 123}
  |> SubscriptionRenewalWorker.new()
  |> Oban.insert()
  ```
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 3,
    unique: [period: 3600]

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.{PaymentMethod, Providers, Subscription, SubscriptionPlan}
  alias PhoenixKit.Modules.Billing.Workers.SubscriptionDunningWorker
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => subscription_id}}) do
    # Process single subscription
    case get_subscription(subscription_id) do
      nil ->
        Logger.warning("Subscription #{subscription_id} not found for renewal")
        :ok

      subscription ->
        process_subscription_renewal(subscription)
    end
  end

  def perform(%Oban.Job{args: _args}) do
    # Process all due subscriptions (daily batch)
    subscriptions = find_subscriptions_due_for_renewal()
    Logger.info("Found #{length(subscriptions)} subscriptions due for renewal")

    Enum.each(subscriptions, fn subscription ->
      case process_subscription_renewal(subscription) do
        {:ok, _} ->
          Logger.info("Renewed subscription #{subscription.id}")

        {:error, reason} ->
          Logger.warning("Failed to renew subscription #{subscription.id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # ============================================
  # Renewal Processing
  # ============================================

  defp process_subscription_renewal(%Subscription{cancel_at_period_end: true} = subscription) do
    # Subscription marked for cancellation - don't renew, cancel now
    Logger.info("Subscription #{subscription.id} marked for cancellation, cancelling now")

    subscription
    |> Subscription.cancel_changeset(true)
    |> RepoHelper.repo().update()
  end

  defp process_subscription_renewal(%Subscription{} = subscription) do
    repo = RepoHelper.repo()

    with {:ok, subscription} <- repo.preload(subscription, [:plan, :payment_method]),
         {:ok, invoice} <- create_renewal_invoice(subscription),
         {:ok, _} <- charge_payment_method(subscription, invoice) do
      # Payment successful - extend period
      plan = subscription.plan
      new_period_start = subscription.current_period_end

      new_period_end =
        SubscriptionPlan.next_billing_date(plan, DateTime.to_date(new_period_start))

      subscription
      |> Subscription.activate_changeset(datetime_from_date(new_period_end))
      |> repo.update()
    else
      {:error, :no_payment_method} ->
        Logger.warning("Subscription #{subscription.id} has no payment method")
        handle_payment_failure(subscription, "No payment method configured")

      {:error, reason} ->
        handle_payment_failure(subscription, inspect(reason))
    end
  end

  defp create_renewal_invoice(%Subscription{plan: nil}) do
    {:error, :no_plan}
  end

  defp create_renewal_invoice(%Subscription{} = subscription) do
    plan = subscription.plan

    line_items = [
      %{
        "name" => "#{plan.name} subscription",
        "description" => "#{SubscriptionPlan.interval_description(plan)}",
        "quantity" => 1,
        "unit_price" => plan.price,
        "total" => plan.price
      }
    ]

    invoice_attrs = %{
      billing_profile_id: subscription.billing_profile_id,
      billing_profile_uuid: subscription.billing_profile_uuid,
      currency: plan.currency,
      status: "sent",
      due_date: Date.utc_today(),
      notes: "Subscription renewal: #{plan.name}",
      line_items: line_items,
      subtotal: plan.price,
      total: plan.price
    }

    case Billing.create_invoice(subscription.user_id, invoice_attrs) do
      {:ok, invoice} -> {:ok, invoice}
      error -> error
    end
  end

  defp charge_payment_method(%Subscription{payment_method: nil}, _invoice) do
    {:error, :no_payment_method}
  end

  defp charge_payment_method(%Subscription{payment_method: pm} = subscription, invoice) do
    if PaymentMethod.usable?(pm) do
      # Providers.charge_payment_method expects the payment_method map with :provider key
      case Providers.charge_payment_method(pm, invoice.total,
             currency: invoice.currency,
             description: "Subscription renewal",
             metadata: %{
               invoice_id: invoice.id,
               subscription_id: subscription.id
             }
           ) do
        {:ok, charge_result} ->
          # Record payment on invoice
          payment_attrs = %{
            amount: invoice.total,
            payment_method: pm.provider,
            description: "Subscription renewal payment",
            provider_transaction_id: charge_result[:charge_id],
            provider_data: charge_result
          }

          Billing.record_payment(invoice, payment_attrs, nil)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :payment_method_not_usable}
    end
  end

  defp handle_payment_failure(%Subscription{} = subscription, error_message) do
    grace_days =
      Settings.get_setting("billing_subscription_grace_days", "3") |> String.to_integer()

    grace_period_end = DateTime.add(DateTime.utc_now(), grace_days, :day)

    Logger.warning(
      "Subscription #{subscription.id} renewal failed: #{error_message}. Grace period until #{grace_period_end}"
    )

    result =
      subscription
      |> Subscription.past_due_changeset(grace_period_end)
      |> RepoHelper.repo().update()

    # Schedule dunning job
    schedule_dunning(subscription.uuid)

    result
  end

  defp schedule_dunning(subscription_id) do
    # Schedule dunning worker to retry in 24 hours
    %{subscription_id: subscription_id}
    |> SubscriptionDunningWorker.new(schedule_in: 86_400)
    |> Oban.insert()
  end

  # ============================================
  # Queries
  # ============================================

  defp find_subscriptions_due_for_renewal do
    import Ecto.Query

    # Find subscriptions where:
    # - Status is active or trialing
    # - Period end is within next 24 hours
    # - Not already marked for cancellation
    cutoff = DateTime.add(DateTime.utc_now(), 24, :hour)

    from(s in Subscription,
      where: s.status in ["active", "trialing"],
      where: s.current_period_end <= ^cutoff,
      where: s.cancel_at_period_end == false
    )
    |> RepoHelper.repo().all()
  end

  defp get_subscription(id) when is_binary(id) do
    RepoHelper.repo().get_by(Subscription, uuid: id)
  end

  defp get_subscription(id) when is_integer(id) do
    RepoHelper.repo().get_by(Subscription, id: id)
  end

  defp datetime_from_date(date) do
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end
end
