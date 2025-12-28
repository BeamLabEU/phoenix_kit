defmodule PhoenixKitWeb.Live.Modules.Billing.Currencies do
  @moduledoc """
  Currencies management LiveView for the billing module.

  Provides currency configuration interface.
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
        |> assign(:page_title, "Currencies")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/billing/currencies"))
        |> assign(:currencies, [])
        |> assign(:loading, true)
        |> assign(:show_form, false)
        |> assign(:editing_currency, nil)
        |> assign(:form, nil)

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
    {:noreply, load_currencies(socket)}
  end

  defp load_currencies(socket) do
    currencies = Billing.list_currencies(order_by: [asc: :sort_order, asc: :code])

    socket
    |> assign(:currencies, currencies)
    |> assign(:loading, false)
  end

  @impl true
  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.id == String.to_integer(id)))

    case Billing.update_currency(currency, %{enabled: !currency.enabled}) do
      {:ok, _currency} ->
        {:noreply,
         socket
         |> load_currencies()
         |> put_flash(:info, "Currency updated")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update currency")}
    end
  end

  @impl true
  def handle_event("set_default", %{"id" => id}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.id == String.to_integer(id)))

    case Billing.set_default_currency(currency) do
      {:ok, _currency} ->
        {:noreply,
         socket
         |> load_currencies()
         |> put_flash(:info, "#{currency.code} set as default currency")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to set default currency")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(:loading, true) |> load_currencies()}
  end
end
