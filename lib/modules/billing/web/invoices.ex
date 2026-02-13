defmodule PhoenixKit.Modules.Billing.Web.Invoices do
  @moduledoc """
  Invoices list LiveView for the billing module.

  Provides invoice management interface with filtering, searching, and pagination.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @default_per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      # Subscribe to invoice events for real-time updates
      if connected?(socket), do: Events.subscribe_invoices()

      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, "Invoices")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/billing/invoices"))
        |> assign(:invoices, [])
        |> assign(:total_count, 0)
        |> assign(:loading, true)
        |> assign_filter_defaults()
        |> assign_pagination_defaults()

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
    socket =
      socket
      |> apply_params(params)
      |> load_invoices()

    {:noreply, socket}
  end

  defp assign_filter_defaults(socket) do
    socket
    |> assign(:search, "")
    |> assign(:status_filter, "all")
  end

  defp assign_pagination_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, @default_per_page)
    |> assign(:total_pages, 1)
  end

  defp apply_params(socket, params) do
    page = parse_page(params["page"])
    per_page = parse_per_page(params["per_page"])
    search = params["search"] || ""
    status = params["status"] || "all"

    socket
    |> assign(:page, page)
    |> assign(:per_page, per_page)
    |> assign(:search, search)
    |> assign(:status_filter, status)
  end

  defp parse_page(nil), do: 1
  defp parse_page(page) when is_binary(page), do: max(1, String.to_integer(page))
  defp parse_page(page) when is_integer(page), do: max(1, page)

  defp parse_per_page(nil), do: @default_per_page

  defp parse_per_page(per_page) when is_binary(per_page),
    do: min(100, max(10, String.to_integer(per_page)))

  defp parse_per_page(per_page) when is_integer(per_page), do: min(100, max(10, per_page))

  defp load_invoices(socket) do
    %{
      page: page,
      per_page: per_page,
      search: search,
      status_filter: status
    } = socket.assigns

    opts = [
      page: page,
      per_page: per_page,
      search: search,
      status: if(status == "all", do: nil, else: status),
      preload: [:user, :order]
    ]

    {invoices, total_count} = Billing.list_invoices_with_count(opts)
    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:invoices, invoices)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, max(1, total_pages))
    |> assign(:loading, false)
  end

  @impl true
  def handle_event("filter", params, socket) do
    new_params = build_url_params(socket.assigns, params)
    {:noreply, push_patch(socket, to: Routes.path("/admin/billing/invoices?#{new_params}"))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/admin/billing/invoices"))}
  end

  @impl true
  def handle_event("view_invoice", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/billing/invoices/#{uuid}"))}
  end

  @impl true
  def handle_event("page_change", %{"page" => page}, socket) do
    new_params = build_url_params(socket.assigns, %{"page" => page})
    {:noreply, push_patch(socket, to: Routes.path("/admin/billing/invoices?#{new_params}"))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(:loading, true) |> load_invoices()}
  end

  # PubSub event handlers for real-time updates
  @impl true
  def handle_info({event, _invoice}, socket)
      when event in [:invoice_created, :invoice_sent, :invoice_paid, :invoice_voided] do
    {:noreply, load_invoices(socket)}
  end

  # Catch-all for any other messages (ignore them)
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp build_url_params(assigns, new_params) do
    params = %{
      "page" => Map.get(new_params, "page", assigns.page),
      "per_page" => assigns.per_page,
      "search" => Map.get(new_params, "search", assigns.search),
      "status" => Map.get(new_params, "status", assigns.status_filter)
    }

    params
    |> Enum.reject(fn
      {_k, v} when v in ["", "all", nil] -> true
      {"page", 1} -> true
      {"per_page", @default_per_page} -> true
      _ -> false
    end)
    |> URI.encode_query()
  end
end
