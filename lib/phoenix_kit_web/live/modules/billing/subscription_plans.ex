defmodule PhoenixKitWeb.Live.Modules.Billing.SubscriptionPlans do
  @moduledoc """
  Subscription plans list LiveView for the billing module.

  Displays all subscription plans with management actions.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      socket =
        socket
        |> assign(:page_title, "Subscription Plans")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/billing/plans"))
        |> load_plans()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_plans(socket) do
    plans = Billing.list_subscription_plans()
    assign(socket, :plans, plans)
  end

  @impl true
  def handle_event("toggle_active", %{"id" => id}, socket) do
    plan = Enum.find(socket.assigns.plans, &(to_string(&1.id) == id))

    if plan do
      case Billing.update_subscription_plan(plan, %{active: !plan.active}) do
        {:ok, _plan} ->
          {:noreply,
           socket
           |> load_plans()
           |> put_flash(:info, if(plan.active, do: "Plan deactivated", else: "Plan activated"))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to update plan: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Plan not found")}
    end
  end

  @impl true
  def handle_event("delete_plan", %{"id" => id}, socket) do
    plan = Enum.find(socket.assigns.plans, &(to_string(&1.id) == id))

    if plan do
      case Billing.delete_subscription_plan(plan) do
        {:ok, _plan} ->
          {:noreply,
           socket
           |> load_plans()
           |> put_flash(:info, "Plan deleted")}

        {:error, :has_subscriptions} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Cannot delete plan with active subscriptions. Deactivate it instead."
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to delete plan: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Plan not found")}
    end
  end

  # Helper functions for template

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
end
