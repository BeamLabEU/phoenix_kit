defmodule PhoenixKitWeb.Live.Modules.Billing.InvoicePrint do
  @moduledoc """
  Printable invoice view - displays invoice in a print-friendly format.

  This page is designed to be printed or saved as PDF directly from the browser.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Billing.CountryData
  alias PhoenixKit.Billing.Transaction
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Billing.enabled?() do
      case Billing.get_invoice(id, preload: [:user, :order, :transactions]) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Invoice not found")
           |> push_navigate(to: Routes.path("/admin/billing/invoices"))}

        invoice ->
          project_title = Settings.get_setting("project_title", "PhoenixKit")
          company_info = get_company_info()

          # Calculate refund info from transactions
          refund_info = calculate_refund_info(invoice.transactions)

          socket =
            socket
            |> assign(:page_title, "Invoice #{invoice.invoice_number}")
            |> assign(:project_title, project_title)
            |> assign(:invoice, invoice)
            |> assign(:company, company_info)
            |> assign(:refund_info, refund_info)

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
      address: CountryData.format_company_address(),
      vat: Settings.get_setting("billing_company_vat", ""),
      bank_name: Settings.get_setting("billing_bank_name", ""),
      bank_iban: Settings.get_setting("billing_bank_iban", ""),
      bank_swift: Settings.get_setting("billing_bank_swift", "")
    }
  end

  defp calculate_refund_info(transactions) when is_list(transactions) do
    refund_txns =
      transactions
      |> Enum.filter(&Transaction.refund?/1)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    if Enum.empty?(refund_txns) do
      nil
    else
      total_refunded =
        refund_txns
        |> Enum.map(& &1.amount)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
        |> Decimal.abs()

      latest_refund = List.first(refund_txns)

      %{
        total: total_refunded,
        count: length(refund_txns),
        latest_date: latest_refund.inserted_at,
        transactions: refund_txns
      }
    end
  end

  defp calculate_refund_info(_), do: nil
end
