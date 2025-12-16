defmodule PhoenixKitWeb.Live.Modules.Billing.SubscriptionDetail do
  @moduledoc """
  Subscription detail LiveView for the billing module.

  Displays complete subscription information and provides management actions.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Billing.Subscription
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Billing.enabled?() do
      case Billing.get_subscription(id, preload: [:user, :plan, :payment_method]) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Subscription not found")
           |> push_navigate(to: Routes.path("/admin/billing/subscriptions"))}

        subscription ->
          project_title = Settings.get_setting("project_title", "PhoenixKit")

          socket =
            socket
            |> assign(:page_title, "Subscription ##{subscription.id}")
            |> assign(:project_title, project_title)
            |> assign(:subscription, subscription)

          {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin/dashboard"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_now", _params, socket) do
    case Billing.cancel_subscription(socket.assigns.subscription, immediately: true) do
      {:ok, subscription} ->
        {:noreply,
         socket
         |> assign(:subscription, reload_subscription(subscription.id))
         |> put_flash(:info, "Subscription cancelled immediately")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("cancel_at_period_end", _params, socket) do
    case Billing.cancel_subscription(socket.assigns.subscription, immediately: false) do
      {:ok, subscription} ->
        {:noreply,
         socket
         |> assign(:subscription, reload_subscription(subscription.id))
         |> put_flash(:info, "Subscription will cancel at period end")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("resume", _params, socket) do
    case Billing.resume_subscription(socket.assigns.subscription) do
      {:ok, subscription} ->
        {:noreply,
         socket
         |> assign(:subscription, reload_subscription(subscription.id))
         |> put_flash(:info, "Subscription resumed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resume: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("pause", _params, socket) do
    case Billing.pause_subscription(socket.assigns.subscription) do
      {:ok, subscription} ->
        {:noreply,
         socket
         |> assign(:subscription, reload_subscription(subscription.id))
         |> put_flash(:info, "Subscription paused")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to pause: #{inspect(reason)}")}
    end
  end

  defp reload_subscription(id) do
    Billing.get_subscription(id, preload: [:user, :plan, :payment_method])
  end

  # Helper functions for template

  def status_badge_class(status) do
    case status do
      "active" -> "badge-success"
      "trialing" -> "badge-info"
      "past_due" -> "badge-warning"
      "paused" -> "badge-neutral"
      "cancelled" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  def format_interval(nil, _), do: "-"
  def format_interval(_, nil), do: "-"

  def format_interval(interval, interval_count) do
    case {interval, interval_count} do
      {"month", 1} -> "Monthly"
      {"month", n} -> "Every #{n} months"
      {"year", 1} -> "Yearly"
      {"year", n} -> "Every #{n} years"
      {"week", 1} -> "Weekly"
      {"week", n} -> "Every #{n} weeks"
      {"day", 1} -> "Daily"
      {"day", n} -> "Every #{n} days"
      _ -> "#{interval_count} #{interval}(s)"
    end
  end

  def days_until_renewal(%Subscription{current_period_end: nil}), do: nil

  def days_until_renewal(%Subscription{current_period_end: period_end}) do
    Date.diff(DateTime.to_date(period_end), Date.utc_today())
  end

  def grace_period_remaining(%Subscription{grace_period_end: nil}), do: nil

  def grace_period_remaining(%Subscription{grace_period_end: grace_end}) do
    Date.diff(DateTime.to_date(grace_end), Date.utc_today())
  end
end
