defmodule PhoenixKit.Modules.Billing.Web.PaymentConfirmationPrint do
  @moduledoc """
  Printable payment confirmation view - displays individual payment in a print-friendly format.

  This page is designed to be printed or saved as PDF directly from the browser.
  Payment confirmations are generated for individual payment transactions.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.CountryData
  alias PhoenixKit.Modules.Billing.Transaction
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => invoice_id, "transaction_id" => transaction_id}, _session, socket) do
    with true <- Billing.enabled?(),
         %{} = invoice <- Billing.get_invoice(invoice_id, preload: [:user, :order]),
         %Transaction{} = transaction <- Billing.get_transaction(transaction_id),
         true <- Transaction.payment?(transaction) do
      mount_payment_confirmation(socket, invoice, transaction)
    else
      false ->
        {:ok,
         socket
         |> put_flash(:error, "Billing module is not enabled")
         |> push_navigate(to: Routes.path("/admin"))}

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
         |> put_flash(:error, "Transaction is not a payment")
         |> push_navigate(to: Routes.path("/admin/billing/invoices/#{invoice_id}"))}
    end
  end

  defp mount_payment_confirmation(socket, invoice, transaction) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    company_info = get_company_info()
    confirmation_number = generate_confirmation_number(transaction)
    all_transactions = Billing.list_invoice_transactions(invoice.id)
    payment_context = calculate_payment_context(invoice, transaction, all_transactions)

    socket =
      socket
      |> assign(:page_title, "Payment Confirmation #{confirmation_number}")
      |> assign(:project_title, project_title)
      |> assign(:invoice, invoice)
      |> assign(:transaction, transaction)
      |> assign(:confirmation_number, confirmation_number)
      |> assign(:company, company_info)
      |> assign(:payment_context, payment_context)

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

  defp generate_confirmation_number(transaction) do
    prefix = Settings.get_setting("billing_payment_confirmation_prefix", "PMT")
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    "#{prefix}-#{suffix}"
  end

  defp calculate_payment_context(invoice, transaction, all_transactions) do
    # Payments up to and including this transaction
    sorted_payments =
      all_transactions
      |> Enum.filter(&Decimal.positive?(&1.amount))
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    # Find position of current payment
    payment_index =
      Enum.find_index(sorted_payments, fn t -> t.id == transaction.id end) || 0

    # Total paid up to and including this payment
    payments_up_to_now = Enum.take(sorted_payments, payment_index + 1)

    total_paid_so_far =
      payments_up_to_now
      |> Enum.map(& &1.amount)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    remaining_balance = Decimal.sub(invoice.total, total_paid_so_far)

    is_final_payment = Decimal.lte?(remaining_balance, Decimal.new(0))

    %{
      payment_number: payment_index + 1,
      total_payments: length(sorted_payments),
      total_paid_so_far: total_paid_so_far,
      remaining_balance: Decimal.max(remaining_balance, Decimal.new(0)),
      is_final_payment: is_final_payment
    }
  end
end
