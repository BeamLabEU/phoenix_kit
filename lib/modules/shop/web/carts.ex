defmodule PhoenixKit.Modules.Shop.Web.Carts do
  @moduledoc """
  Carts admin list LiveView for E-Commerce module.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Modules.Shop
  alias PhoenixKit.Utils.Routes

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {carts, total} = Shop.list_carts_with_count(per_page: @per_page)
    currency = Shop.get_default_currency()

    socket =
      socket
      |> assign(:page_title, "Shopping Carts")
      |> assign(:carts, carts)
      |> assign(:total, total)
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:status_filter, nil)
      |> assign(:search, "")
      |> assign(:currency, currency)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = String.to_integer(params["page"] || "1")
    status = params["status"]
    search = params["search"] || ""

    {carts, total} =
      Shop.list_carts_with_count(
        page: page,
        per_page: @per_page,
        status: status,
        search: search
      )

    socket =
      socket
      |> assign(:carts, carts)
      |> assign(:total, total)
      |> assign(:page, page)
      |> assign(:status_filter, status)
      |> assign(:search, search)

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status
    {:noreply, push_patch(socket, to: build_url(socket.assigns, status: status, page: 1))}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket.assigns, search: search, page: 1))}
  end

  defp build_url(assigns, overrides) do
    params =
      %{
        status: Keyword.get(overrides, :status, assigns.status_filter),
        search: Keyword.get(overrides, :search, assigns.search),
        page: Keyword.get(overrides, :page, assigns.page)
      }
      |> Enum.filter(fn {_k, v} -> v && v != "" end)
      |> URI.encode_query()

    if params == "" do
      Routes.path("/admin/shop/carts")
    else
      Routes.path("/admin/shop/carts?#{params}")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      current_path={@url_path}
      current_locale={@current_locale}
      page_title={@page_title}
    >
      <div class="container flex-col mx-auto px-4 py-6 max-w-7xl">
        <%!-- Header --%>
        <header class="mb-6">
          <div class="flex items-start gap-4">
            <.link
              navigate={Routes.path("/admin/shop")}
              class="btn btn-outline btn-primary btn-sm shrink-0"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> Back
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">Shopping Carts</h1>
              <p class="text-base-content/70 mt-1">{@total} carts total</p>
            </div>
          </div>
        </header>

        <%!-- Controls Bar --%>
        <div class="bg-base-200 rounded-lg p-6 mb-6">
          <div class="flex flex-col lg:flex-row gap-4">
            <%!-- Search --%>
            <div class="flex-1">
              <label class="label"><span class="label-text">Search</span></label>
              <form phx-submit="search" phx-change="search">
                <input
                  type="text"
                  name="search"
                  value={@search}
                  placeholder="Search by email or session ID..."
                  class="input input-bordered w-full focus:input-primary"
                  phx-debounce="300"
                />
              </form>
            </div>

            <%!-- Status Filter --%>
            <div class="w-full lg:w-48">
              <label class="label"><span class="label-text">Status</span></label>
              <select
                class="select select-bordered w-full focus:select-primary"
                phx-change="filter_status"
                name="status"
              >
                <option value="" selected={is_nil(@status_filter)}>All Status</option>
                <option value="active" selected={@status_filter == "active"}>Active</option>
                <option value="converted" selected={@status_filter == "converted"}>Converted</option>
                <option value="abandoned" selected={@status_filter == "abandoned"}>Abandoned</option>
                <option value="expired" selected={@status_filter == "expired"}>Expired</option>
                <option value="merged" selected={@status_filter == "merged"}>Merged</option>
              </select>
            </div>
          </div>
        </div>

        <%!-- Carts Table --%>
        <div class="card bg-base-100 shadow-xl overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Customer</th>
                  <th>Items</th>
                  <th class="text-right">Total</th>
                  <th>Status</th>
                  <th>Updated</th>
                </tr>
              </thead>
              <tbody>
                <%= if @carts == [] do %>
                  <tr>
                    <td colspan="5" class="text-center py-12 text-base-content/50">
                      <.icon name="hero-shopping-cart" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                      <p class="text-lg">No carts found</p>
                      <p class="text-sm">Carts will appear here when customers add items</p>
                    </td>
                  </tr>
                <% else %>
                  <%= for cart <- @carts do %>
                    <tr class="hover">
                      <td>
                        <%= if cart.user do %>
                          <div class="font-medium">{cart.user.email}</div>
                          <div class="text-xs text-base-content/50">User ID: {cart.user.id}</div>
                        <% else %>
                          <div class="text-base-content/60">Guest</div>
                          <div class="text-xs text-base-content/40 font-mono">
                            {String.slice(cart.session_id || "", 0, 16)}...
                          </div>
                        <% end %>
                      </td>
                      <td>
                        <span class="badge badge-neutral">{cart.items_count || 0} items</span>
                        <%= if cart.total_weight_grams && cart.total_weight_grams > 0 do %>
                          <span class="text-xs text-base-content/50 ml-2">
                            {format_weight(cart.total_weight_grams)}
                          </span>
                        <% end %>
                      </td>
                      <td class="text-right">
                        <div class="font-semibold">{format_price(cart.total, @currency)}</div>
                        <%= if Decimal.compare(cart.subtotal || Decimal.new("0"), cart.total || Decimal.new("0")) != :eq do %>
                          <div class="text-xs text-base-content/50">
                            Subtotal: {format_price(cart.subtotal, @currency)}
                          </div>
                        <% end %>
                      </td>
                      <td>
                        <span class={status_badge_class(cart.status)}>{cart.status}</span>
                      </td>
                      <td>
                        <div class="text-sm">{format_datetime(cart.updated_at)}</div>
                        <%= if cart.expires_at do %>
                          <div class="text-xs text-base-content/50">
                            Expires: {format_datetime(cart.expires_at)}
                          </div>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Pagination --%>
        <%= if @total > @per_page do %>
          <div class="flex justify-center mt-6">
            <div class="join">
              <%= for page_num <- 1..ceil(@total / @per_page) do %>
                <.link
                  patch={build_url(assigns, page: page_num)}
                  class={["join-item btn btn-sm", if(@page == page_num, do: "btn-active")]}
                >
                  {page_num}
                </.link>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  defp status_badge_class("active"), do: "badge badge-success"
  defp status_badge_class("converted"), do: "badge badge-info"
  defp status_badge_class("abandoned"), do: "badge badge-warning"
  defp status_badge_class("expired"), do: "badge badge-neutral"
  defp status_badge_class("merged"), do: "badge badge-secondary"
  defp status_badge_class(_), do: "badge"

  defp format_price(nil, _currency), do: "-"

  defp format_price(amount, %Currency{} = currency) do
    Currency.format_amount(amount, currency)
  end

  defp format_price(amount, nil) do
    "$#{Decimal.round(amount, 2)}"
  end

  defp format_weight(grams) when grams >= 1000, do: "#{Float.round(grams / 1000, 1)} kg"
  defp format_weight(grams), do: "#{grams} g"

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end
end
