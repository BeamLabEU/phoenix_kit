defmodule PhoenixKit.Modules.Billing.Web.Subscriptions do
  @moduledoc """
  Subscriptions list LiveView for the billing module.

  Displays all subscriptions with filtering and search capabilities.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      if connected?(socket) do
        Events.subscribe_subscriptions()
      end

      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, "Subscriptions")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/billing/subscriptions"))
        |> assign(:status_filter, "all")
        |> assign(:search, "")
        |> load_subscriptions()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    status = params["status"] || "all"
    search = params["search"] || ""

    socket =
      socket
      |> assign(:status_filter, status)
      |> assign(:search, search)
      |> load_subscriptions()

    {:noreply, socket}
  end

  defp load_subscriptions(socket) do
    opts =
      [preload: [:user, :subscription_type, :payment_method]]
      |> add_status_filter(socket.assigns.status_filter)
      |> add_search_filter(socket.assigns.search)

    subscriptions = Billing.list_subscriptions(opts)
    stats = calculate_stats(subscriptions)

    socket
    |> assign(:subscriptions, subscriptions)
    |> assign(:stats, stats)
  end

  defp add_status_filter(opts, "all"), do: opts
  defp add_status_filter(opts, status), do: Keyword.put(opts, :status, status)

  defp add_search_filter(opts, ""), do: opts
  defp add_search_filter(opts, search), do: Keyword.put(opts, :search, search)

  defp calculate_stats(subscriptions) do
    %{
      total: length(subscriptions),
      active: Enum.count(subscriptions, &(&1.status == "active")),
      trialing: Enum.count(subscriptions, &(&1.status == "trialing")),
      past_due: Enum.count(subscriptions, &(&1.status == "past_due")),
      cancelled: Enum.count(subscriptions, &(&1.status == "cancelled"))
    }
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         Routes.path("/admin/billing/subscriptions") <>
           build_query_string(status, socket.assigns.search)
     )}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         Routes.path("/admin/billing/subscriptions") <>
           build_query_string(socket.assigns.status_filter, search)
     )}
  end

  @impl true
  def handle_event("cancel_subscription", %{"uuid" => uuid}, socket) do
    subscription = Enum.find(socket.assigns.subscriptions, &(&1.uuid == uuid))

    if subscription do
      case Billing.cancel_subscription(subscription, immediately: false) do
        {:ok, _subscription} ->
          {:noreply,
           socket
           |> load_subscriptions()
           |> put_flash(:info, "Subscription will be cancelled at period end")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to cancel: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Subscription not found")}
    end
  end

  # PubSub event handlers
  @impl true
  def handle_info({:subscription_created, _subscription}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  @impl true
  def handle_info({:subscription_cancelled, _subscription}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  @impl true
  def handle_info({:subscription_renewed, _subscription}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  @impl true
  def handle_info({:subscription_type_changed, _subscription, _old_type, _new_type}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  @impl true
  def handle_info({:subscription_status_changed, _subscription, _old_status, _new_status}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  defp build_query_string(status, search) do
    params =
      []
      |> then(fn p -> if status != "all", do: [{"status", status} | p], else: p end)
      |> then(fn p -> if search != "", do: [{"search", search} | p], else: p end)

    case params do
      [] -> ""
      _ -> "?" <> URI.encode_query(params)
    end
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
