defmodule PhoenixKit.Modules.Billing.Workers.SubscriptionDunningWorker do
  @moduledoc """
  Oban worker for dunning (failed payment recovery).

  When a subscription payment fails, the subscription enters `past_due` status
  and this worker handles retry attempts during the grace period.

  ## Dunning Process

  1. Initial payment fails → subscription status = `past_due`
  2. Grace period starts (configurable, default 3 days)
  3. This worker retries payment at intervals
  4. If payment succeeds → status = `active`
  5. If max attempts reached or grace period ends → status = `cancelled`

  ## Retry Schedule

  Default retry schedule (can be configured):
  - Attempt 1: Immediate (handled by RenewalWorker)
  - Attempt 2: 24 hours later
  - Attempt 3: 48 hours later (2 days)
  - Attempt 4: 72 hours later (3 days, grace period ends)

  ## Configuration

  ```elixir
  # Settings (stored in database)
  billing_subscription_grace_days: 3
  billing_dunning_max_attempts: 3
  ```

  ## Manual Trigger

  ```elixir
  %{subscription_id: 123}
  |> SubscriptionDunningWorker.new()
  |> Oban.insert()
  ```
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 5,
    unique: [period: 3600, keys: [:subscription_id]]

  alias PhoenixKit.Modules.Billing.{PaymentMethod, Providers, Subscription, SubscriptionPlan}
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_id" => subscription_id}}) do
    case get_subscription_with_preloads(subscription_id) do
      nil ->
        Logger.warning("Subscription #{subscription_id} not found for dunning")
        :ok

      subscription ->
        process_dunning(subscription)
    end
  end

  # ============================================
  # Dunning Processing
  # ============================================

  defp process_dunning(%Subscription{status: "cancelled"}) do
    # Already cancelled, nothing to do
    :ok
  end

  defp process_dunning(%Subscription{status: status}) when status not in ["past_due"] do
    # Not in past_due status, skip
    :ok
  end

  defp process_dunning(%Subscription{} = subscription) do
    max_attempts = get_max_attempts()

    cond do
      subscription.renewal_attempts >= max_attempts ->
        Logger.info("Subscription #{subscription.uuid} exceeded max dunning attempts, cancelling")
        cancel_subscription(subscription, "Max payment retry attempts exceeded")

      Subscription.grace_period_expired?(subscription) ->
        Logger.info("Subscription #{subscription.uuid} grace period expired, cancelling")
        cancel_subscription(subscription, "Grace period expired")

      true ->
        attempt_payment_retry(subscription)
    end
  end

  defp attempt_payment_retry(%Subscription{payment_method: nil} = subscription) do
    Logger.warning("Subscription #{subscription.uuid} has no payment method for retry")
    # Still schedule next retry in case user adds payment method
    schedule_next_retry(subscription)
    {:ok, :no_payment_method}
  end

  defp attempt_payment_retry(%Subscription{} = subscription) do
    pm = subscription.payment_method

    if PaymentMethod.usable?(pm) do
      Logger.info(
        "Attempting payment retry ##{subscription.renewal_attempts + 1} for subscription #{subscription.uuid}"
      )

      case charge_subscription(subscription) do
        {:ok, _result} ->
          Logger.info("Dunning payment successful for subscription #{subscription.uuid}")
          reactivate_subscription(subscription)

        {:error, reason} ->
          Logger.warning(
            "Dunning payment failed for subscription #{subscription.uuid}: #{inspect(reason)}"
          )

          update_retry_count(subscription)
          schedule_next_retry(subscription)
          {:error, reason}
      end
    else
      Logger.warning(
        "Payment method not usable for subscription #{subscription.uuid}: #{inspect(pm.status)}"
      )

      schedule_next_retry(subscription)
      {:error, :payment_method_not_usable}
    end
  end

  defp charge_subscription(%Subscription{} = subscription) do
    plan = subscription.plan
    pm = subscription.payment_method

    # Providers.charge_payment_method expects the payment_method map with :provider key
    Providers.charge_payment_method(pm, plan.price,
      currency: plan.currency,
      description: "Subscription renewal (dunning retry)",
      metadata: %{
        subscription_id: subscription.uuid,
        retry_attempt: subscription.renewal_attempts + 1
      }
    )
  end

  defp reactivate_subscription(%Subscription{} = subscription) do
    plan = subscription.plan
    new_period_start = subscription.current_period_end
    new_period_end = SubscriptionPlan.next_billing_date(plan, DateTime.to_date(new_period_start))

    subscription
    |> Subscription.activate_changeset(datetime_from_date(new_period_end))
    |> RepoHelper.repo().update()
  end

  defp update_retry_count(%Subscription{} = subscription) do
    subscription
    |> Ecto.Changeset.change(%{
      renewal_attempts: subscription.renewal_attempts + 1,
      last_renewal_attempt_at: UtilsDate.utc_now()
    })
    |> RepoHelper.repo().update()
  end

  defp cancel_subscription(%Subscription{} = subscription, reason) do
    Logger.info("Cancelling subscription #{subscription.uuid}: #{reason}")

    subscription
    |> Subscription.cancel_changeset(true)
    |> RepoHelper.repo().update()
  end

  defp schedule_next_retry(%Subscription{} = subscription) do
    max_attempts = get_max_attempts()

    if subscription.renewal_attempts < max_attempts do
      # Schedule next retry in 24 hours
      %{subscription_id: subscription.uuid}
      |> __MODULE__.new(schedule_in: 86_400)
      |> Oban.insert()
    end
  end

  # ============================================
  # Queries & Helpers
  # ============================================

  defp get_subscription_with_preloads(uuid) when is_binary(uuid) do
    import Ecto.Query

    from(s in Subscription,
      where: s.uuid == ^uuid,
      preload: [:plan, :payment_method]
    )
    |> RepoHelper.repo().one()
  end

  defp get_max_attempts do
    Settings.get_setting("billing_dunning_max_attempts", "3")
    |> String.to_integer()
  end

  defp datetime_from_date(date) do
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end
end
