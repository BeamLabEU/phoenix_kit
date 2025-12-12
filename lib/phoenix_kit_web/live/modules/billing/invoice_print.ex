defmodule PhoenixKitWeb.Live.Modules.Billing.InvoicePrint do
  @moduledoc """
  Printable invoice view - displays invoice in a print-friendly format.

  This page is designed to be printed or saved as PDF directly from the browser.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Billing.enabled?() do
      case Billing.get_invoice(id, preload: [:user, :order]) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Invoice not found")
           |> push_navigate(to: Routes.path("/admin/billing/invoices"))}

        invoice ->
          project_title = Settings.get_setting("project_title", "PhoenixKit")
          company_info = get_company_info()

          socket =
            socket
            |> assign(:page_title, "Invoice #{invoice.invoice_number}")
            |> assign(:project_title, project_title)
            |> assign(:invoice, invoice)
            |> assign(:company, company_info)

          {:ok, socket, layout: false}
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

  defp get_company_info do
    %{
      name: Settings.get_setting("billing_company_name", ""),
      address: Settings.get_setting("billing_company_address", ""),
      vat: Settings.get_setting("billing_company_vat", ""),
      bank_name: Settings.get_setting("billing_bank_name", ""),
      bank_iban: Settings.get_setting("billing_bank_iban", ""),
      bank_swift: Settings.get_setting("billing_bank_swift", "")
    }
  end
end
