defmodule PhoenixKit.Modules.Billing.Providers.Razorpay do
  @moduledoc """
  Razorpay payment provider implementation.

  Razorpay is a popular payment gateway in India. Uses their REST API for:
  - Payment Links (hosted checkout)
  - Orders API
  - Customers and Tokens (saved payment methods)
  - Refunds

  ## Configuration

  Required settings in database:
  - `billing_razorpay_enabled` - "true" to enable
  - `billing_razorpay_key_id` - Razorpay Key ID
  - `billing_razorpay_key_secret` - Razorpay Key Secret
  - `billing_razorpay_webhook_secret` - Webhook secret for signature verification

  ## Razorpay Flow

  1. Create Order with amount and currency
  2. Create Payment Link or use Checkout.js
  3. User completes payment on Razorpay
  4. Razorpay sends webhook on payment success
  5. Verify signature and process payment

  ## Webhook Events

  - `payment.authorized` - Payment authorized (for 2-step payments)
  - `payment.captured` - Payment captured successfully
  - `payment.failed` - Payment failed
  - `refund.created` - Refund initiated
  - `refund.processed` - Refund completed

  ## Currency Support

  Primary currency is INR. International payments supported with:
  USD, EUR, GBP, SGD, AED, CAD, CNY, SEK, NZD, MXN, etc.
  """

  @behaviour PhoenixKit.Modules.Billing.Providers.Provider

  alias PhoenixKit.Modules.Billing.Providers.Types.{
    ChargeResult,
    CheckoutSession,
    PaymentMethodInfo,
    RefundResult,
    WebhookEventData
  }

  alias PhoenixKit.Settings

  require Logger

  @base_url "https://api.razorpay.com"

  # ============================================
  # Provider Behaviour Implementation
  # ============================================

  @impl true
  def provider_name, do: :razorpay

  @impl true
  def available? do
    Settings.get_setting("billing_razorpay_enabled", "false") == "true" &&
      has_credentials?()
  end

  @impl true
  def create_checkout_session(invoice, opts) do
    # Merge invoice data with opts
    merged_opts = Keyword.merge(opts, invoice_to_opts(invoice))

    with {:ok, order} <- create_order(merged_opts),
         {:ok, payment_link} <- create_payment_link(order, merged_opts) do
      {:ok,
       %CheckoutSession{
         id: order["id"],
         url: payment_link["short_url"],
         provider: :razorpay,
         expires_at: payment_link["expire_by"] |> datetime_from_unix()
       }}
    end
  end

  @impl true
  def create_setup_session(_user, _opts) do
    # Razorpay doesn't have direct setup sessions like Stripe
    # We create a zero-amount authorization to save the card
    # Or use their emandate/subscription API

    # For now, return an error - implement with emandate if needed
    {:error, :not_supported}
  end

  @impl true
  def charge_payment_method(payment_method, amount, opts) do
    # Razorpay recurring payments use tokens
    token_id = payment_method.provider_payment_method_id
    customer_id = payment_method.provider_customer_id

    with {:ok, order} <- create_order_for_recurring(amount, opts),
         {:ok, payment} <- create_recurring_payment(order, token_id, customer_id, opts) do
      {:ok,
       %ChargeResult{
         id: payment["id"],
         status: payment["status"],
         amount: amount
       }}
    end
  end

  @impl true
  def verify_webhook_signature(payload, signature, secret) do
    # Razorpay uses HMAC SHA256
    expected_signature =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(expected_signature, signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  @impl true
  def handle_webhook_event(payload) do
    event = payload["event"]
    event_payload = payload["payload"]

    case event do
      "payment.captured" ->
        handle_payment_captured(event_payload, payload)

      "payment.authorized" ->
        handle_payment_authorized(event_payload, payload)

      "payment.failed" ->
        handle_payment_failed(event_payload, payload)

      "refund.created" ->
        handle_refund_created(event_payload, payload)

      "refund.processed" ->
        handle_refund_processed(event_payload, payload)

      "order.paid" ->
        handle_order_paid(event_payload, payload)

      _ ->
        {:error, :unknown_event}
    end
  end

  @impl true
  def create_refund(provider_transaction_id, amount, opts) do
    with {:ok, refund} <- do_create_refund(provider_transaction_id, amount, opts) do
      {:ok,
       %RefundResult{
         id: refund["id"],
         provider_refund_id: refund["id"],
         status: refund["status"],
         amount: refund["amount"]
       }}
    end
  end

  @impl true
  def get_payment_method_details(token_id) do
    # Razorpay tokens don't expose card details easily
    # Return minimal structure matching the payment_method type
    {:ok,
     %PaymentMethodInfo{
       id: token_id,
       provider: :razorpay,
       provider_payment_method_id: token_id,
       provider_customer_id: nil,
       type: "card",
       brand: nil,
       last4: nil,
       exp_month: nil,
       exp_year: nil,
       metadata: %{}
     }}
  end

  # ============================================
  # Razorpay API Calls
  # ============================================

  defp create_order(opts) do
    amount = opts[:amount] || opts["amount"]
    currency = opts[:currency] || opts["currency"] || "INR"
    metadata = opts[:metadata] || opts["metadata"] || %{}

    # Razorpay expects amount in smallest currency unit (paise for INR)
    amount_paise =
      if is_integer(amount) do
        amount
      else
        Decimal.to_integer(Decimal.mult(amount, 100))
      end

    body = %{
      amount: amount_paise,
      currency: String.upcase(currency),
      notes: metadata,
      receipt: "receipt_#{System.system_time(:millisecond)}"
    }

    request(:post, "/v1/orders", body)
  end

  defp create_order_for_recurring(amount, opts) do
    currency = Keyword.get(opts, :currency, "INR")
    metadata = Keyword.get(opts, :metadata, %{})

    amount_paise =
      if is_integer(amount) do
        amount
      else
        Decimal.to_integer(Decimal.mult(amount, 100))
      end

    body = %{
      amount: amount_paise,
      currency: String.upcase(currency),
      notes: metadata,
      receipt: "recurring_#{System.system_time(:millisecond)}"
    }

    request(:post, "/v1/orders", body)
  end

  defp create_payment_link(order, opts) do
    description = opts[:description] || opts["description"] || "Payment"
    success_url = opts[:success_url] || opts["success_url"]
    # cancel_url not used in Razorpay payment links - they use callback_url only
    metadata = opts[:metadata] || opts["metadata"] || %{}

    body = %{
      amount: order["amount"],
      currency: order["currency"],
      description: description,
      callback_url: success_url,
      callback_method: "get",
      notes: Map.merge(metadata, %{order_id: order["id"]}),
      # Expire in 30 minutes
      expire_by: System.system_time(:second) + 1800
    }

    request(:post, "/v1/payment_links", body)
  end

  defp create_recurring_payment(order, token_id, customer_id, opts) do
    description = Keyword.get(opts, :description, "Recurring payment")

    body = %{
      email: Keyword.get(opts, :email, "customer@example.com"),
      contact: Keyword.get(opts, :phone, "9999999999"),
      amount: order["amount"],
      currency: order["currency"],
      order_id: order["id"],
      customer_id: customer_id,
      token: token_id,
      recurring: "1",
      description: description
    }

    request(:post, "/v1/payments/create/recurring", body)
  end

  defp do_create_refund(payment_id, amount, opts) do
    notes = Keyword.get(opts, :notes, %{})

    body =
      if amount do
        amount_paise =
          if is_integer(amount) do
            amount
          else
            Decimal.to_integer(Decimal.mult(amount, 100))
          end

        %{amount: amount_paise, notes: notes}
      else
        %{notes: notes}
      end

    request(:post, "/v1/payments/#{payment_id}/refund", body)
  end

  # ============================================
  # Webhook Event Handlers
  # ============================================

  defp handle_payment_captured(event_payload, raw_payload) do
    payment = event_payload["payment"]["entity"]
    order_id = payment["order_id"]
    notes = payment["notes"] || %{}

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || payment["id"],
       type: "payment.succeeded",
       provider: :razorpay,
       data: %{
         charge_id: payment["id"],
         order_id: order_id,
         invoice_uuid: notes["invoice_uuid"] || notes["invoice_id"],
         amount: payment["amount"],
         currency: payment["currency"]
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_payment_authorized(event_payload, raw_payload) do
    payment = event_payload["payment"]["entity"]

    # For 2-step payments, we may need to capture manually
    # Auto-capture is usually enabled, so this is informational
    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || payment["id"],
       type: "payment.authorized",
       provider: :razorpay,
       data: %{
         payment_id: payment["id"],
         order_id: payment["order_id"],
         amount: payment["amount"]
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_payment_failed(event_payload, raw_payload) do
    payment = event_payload["payment"]["entity"]
    error = payment["error_code"] || "unknown"
    error_desc = payment["error_description"] || "Payment failed"
    notes = payment["notes"] || %{}

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || payment["id"],
       type: "payment.failed",
       provider: :razorpay,
       data: %{
         payment_id: payment["id"],
         order_id: payment["order_id"],
         invoice_uuid: notes["invoice_uuid"] || notes["invoice_id"],
         error_code: error,
         error_message: error_desc
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_order_paid(event_payload, raw_payload) do
    order = event_payload["order"]["entity"]
    payment = event_payload["payment"]["entity"]
    notes = order["notes"] || %{}

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || order["id"],
       type: "checkout.completed",
       provider: :razorpay,
       data: %{
         mode: "payment",
         session_id: order["id"],
         payment_intent_id: payment["id"],
         invoice_uuid: notes["invoice_uuid"] || notes["invoice_id"],
         amount_total: order["amount_paid"],
         currency: order["currency"]
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_refund_created(event_payload, raw_payload) do
    refund = event_payload["refund"]["entity"]

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || refund["id"],
       type: "refund.created",
       provider: :razorpay,
       data: %{
         refund_id: refund["id"],
         charge_id: refund["payment_id"],
         amount_refunded: refund["amount"],
         status: refund["status"]
       },
       raw_payload: raw_payload
     }}
  end

  defp handle_refund_processed(event_payload, raw_payload) do
    refund = event_payload["refund"]["entity"]

    {:ok,
     %WebhookEventData{
       event_id: raw_payload["event_id"] || refund["id"],
       type: "refund.completed",
       provider: :razorpay,
       data: %{
         refund_id: refund["id"],
         charge_id: refund["payment_id"],
         amount_refunded: refund["amount"],
         status: "succeeded"
       },
       raw_payload: raw_payload
     }}
  end

  # ============================================
  # HTTP Helpers
  # ============================================

  defp request(method, path, body) do
    with {:ok, credentials} <- get_credentials() do
      execute_request(method, path, body, credentials)
    end
  end

  defp get_credentials do
    key_id = Settings.get_setting("billing_razorpay_key_id", "")
    key_secret = Settings.get_setting("billing_razorpay_key_secret", "")

    if key_id == "" or key_secret == "" do
      {:error, :not_configured}
    else
      {:ok, {key_id, key_secret}}
    end
  end

  defp execute_request(method, path, body, {key_id, key_secret}) do
    url = "#{@base_url}#{path}"
    auth = Base.encode64("#{key_id}:#{key_secret}")

    headers = [
      {"Authorization", "Basic #{auth}"},
      {"Content-Type", "application/json"}
    ]

    opts = build_request_opts(method, headers, body)

    method
    |> do_http_request(url, opts)
    |> handle_response()
  end

  defp build_request_opts(_method, headers, body), do: [headers: headers, json: body]

  defp do_http_request(:post, url, opts), do: Req.post(url, opts)

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    Logger.error("Razorpay API error: #{status} - #{inspect(body)}")
    error_message = body["error"]["description"] || "API error"
    {:error, error_message}
  end

  defp handle_response({:error, reason}) do
    Logger.error("Razorpay request failed: #{inspect(reason)}")
    {:error, :request_failed}
  end

  # ============================================
  # Helpers
  # ============================================

  defp has_credentials? do
    Settings.get_setting("billing_razorpay_key_id", "") != "" &&
      Settings.get_setting("billing_razorpay_key_secret", "") != ""
  end

  defp datetime_from_unix(nil), do: nil

  defp datetime_from_unix(unix_timestamp) when is_integer(unix_timestamp) do
    DateTime.from_unix!(unix_timestamp)
  end

  defp datetime_from_unix(_), do: nil

  defp invoice_to_opts(invoice) when is_map(invoice) do
    amount = invoice[:total] || invoice["total"] || Decimal.new(0)
    # Razorpay expects amount in smallest currency unit (paise for INR, cents for others)
    amount_paise = Decimal.to_integer(Decimal.mult(amount, 100))

    [
      amount: amount_paise,
      currency: invoice[:currency] || invoice["currency"] || "INR",
      description: "Invoice #{invoice[:invoice_number] || invoice["invoice_number"]}",
      metadata: %{
        invoice_uuid: invoice[:uuid] || invoice["uuid"] || invoice[:id] || invoice["id"],
        invoice_number: invoice[:invoice_number] || invoice["invoice_number"]
      }
    ]
  end

  defp invoice_to_opts(_), do: []
end
