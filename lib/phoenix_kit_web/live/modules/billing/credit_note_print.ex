defmodule PhoenixKitWeb.Live.Modules.Billing.CreditNotePrint do
  @moduledoc """
  Printable credit note view - displays refund/credit note in a print-friendly format.

  This page is designed to be printed or saved as PDF directly from the browser.
  Credit notes are generated for refund transactions.

  IMPORTANT: In a credit note, the roles are reversed compared to invoice:
  - The company (seller) is now the PAYER (issuing the refund)
  - The customer is now the PAYEE (receiving the refund)
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Billing.CountryData
  alias PhoenixKit.Billing.Transaction
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => invoice_id, "transaction_id" => transaction_id}, _session, socket) do
    with true <- Billing.enabled?(),
         %{} = invoice <- Billing.get_invoice(invoice_id, preload: [:user, :order]),
         %Transaction{} = transaction <- Billing.get_transaction(transaction_id),
         true <- Transaction.refund?(transaction) do
      mount_credit_note(socket, invoice, transaction)
    else
      false ->
        {:ok,
         socket
         |> put_flash(:error, "Billing module is not enabled")
         |> push_navigate(to: Routes.path("/admin/dashboard"))}

      nil ->
        error_msg =
          if Billing.get_invoice(invoice_id) == nil,
            do: "Invoice not found",
            else: "Transaction not found"

        redirect_path =
          if Billing.get_invoice(invoice_id) == nil,
            do: Routes.path("/admin/billing/invoices"),
            else: Routes.path("/admin/billing/invoices/#{invoice_id}")

        {:ok,
         socket
         |> put_flash(:error, error_msg)
         |> push_navigate(to: redirect_path)}

      %Transaction{} ->
        {:ok,
         socket
         |> put_flash(:error, "Transaction is not a refund")
         |> push_navigate(to: Routes.path("/admin/billing/invoices/#{invoice_id}"))}
    end
  end

  defp mount_credit_note(socket, invoice, transaction) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    company_info = get_company_info()
    credit_note_number = generate_credit_note_number(transaction)

    socket =
      socket
      |> assign(:page_title, "Credit Note #{credit_note_number}")
      |> assign(:project_title, project_title)
      |> assign(:invoice, invoice)
      |> assign(:transaction, transaction)
      |> assign(:credit_note_number, credit_note_number)
      |> assign(:company, company_info)

    {:ok, socket, layout: false}
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

  defp generate_credit_note_number(transaction) do
    prefix = Settings.get_setting("billing_credit_note_prefix", "CN")
    # Use transaction number suffix for credit note
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    "#{prefix}-#{suffix}"
  end
end
