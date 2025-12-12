defmodule PhoenixKitWeb.Live.Modules.Billing.Index do
  @moduledoc """
  Billing module dashboard LiveView.

  Provides an overview of billing activity including:
  - Key metrics (orders, invoices, revenue)
  - Recent orders and invoices
  - Quick actions
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
        |> assign(:page_title, "Billing Dashboard")
        |> assign(:project_title, project_title)
        |> load_dashboard_data()

      {:ok, socket}
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

  defp load_dashboard_data(socket) do
    stats = Billing.get_dashboard_stats()
    recent_orders = Billing.list_orders(limit: 5, sort_by: :inserted_at, sort_order: :desc)
    recent_invoices = Billing.list_invoices(limit: 5, sort_by: :inserted_at, sort_order: :desc)
    currencies = Billing.list_currencies(enabled: true)

    socket
    |> assign(:stats, stats)
    |> assign(:recent_orders, recent_orders)
    |> assign(:recent_invoices, recent_invoices)
    |> assign(:currencies, currencies)
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_dashboard_data(socket)}
  end

  @impl true
  def handle_event("view_order", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/billing/orders/#{id}"))}
  end

  @impl true
  def handle_event("view_invoice", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/billing/invoices/#{id}"))}
  end
end
