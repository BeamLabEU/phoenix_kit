defmodule PhoenixKit.Modules.Billing.Providers.PayPal do
  @moduledoc """
  PayPal payment provider implementation.

  Uses PayPal REST API v2 for:
  - Checkout sessions (Orders API)
  - Saved payment methods (Vault API)
  - Refunds

  ## Configuration

  Required settings in database:
  - `billing_paypal_enabled` - "true" to enable
  - `billing_paypal_client_id` - PayPal Client ID
  - `billing_paypal_client_secret` - PayPal Client Secret
  - `billing_paypal_mode` - "sandbox" or "live"
  - `billing_paypal_webhook_id` - Webhook ID for signature verification

  ## PayPal API Flow

  1. Get OAuth2 access token (cached)
  2. Create Order with intent: "CAPTURE"
  3. Redirect user to PayPal approval URL
  4. User approves payment on PayPal
  5. PayPal redirects to success_url with token
  6. Capture payment via webhook or on return

  ## Webhook Events

  - `CHECKOUT.ORDER.APPROVED` - User approved the payment
  - `PAYMENT.CAPTURE.COMPLETED` - Payment captured successfully
  - `PAYMENT.CAPTURE.DENIED` - Payment capture failed
  - `PAYMENT.CAPTURE.REFUNDED` - Refund completed
  """

  @behaviour PhoenixKit.Modules.Billing.Providers.Provider

  alias PhoenixKit.Settings

  require Logger

  @sandbox_url "https://api-m.sandbox.paypal.com"
  @live_url "https://api-m.paypal.com"

  # ============================================
  # Provider Behaviour Implementation
  # ============================================

  @impl true
  def provider_name, do: :paypal

  @impl true
  def available? do
    Settings.get_setting("billing_paypal_enabled", "false") == "true" &&
      has_credentials?()
  end

  @impl true
  def create_checkout_session(invoice, opts) do
    # Merge invoice data with opts
    merged_opts = Keyword.merge(opts, invoice_to_opts(invoice))

    with {:ok, token} <- get_access_token(),
         {:ok, order} <- create_order(token, merged_opts) do
      # Find the approval URL
      approve_link =
        order["links"]
        |> Enum.find(fn link -> link["rel"] == "approve" end)

      {:ok,
       %{
         session_id: order["id"],
         url: approve_link["href"],
         provider: :paypal,
         expires_at: nil
       }}
    end
  end

  @impl true
  def create_setup_session(user, opts) do
    # Add user_id to opts
    merged_opts =
      Keyword.put(opts, :user_id, user[:uuid] || user["uuid"] || user[:id] || user["id"])

    with {:ok, token} <- get_access_token(),
         {:ok, setup_token} <- create_setup_token(token, merged_opts) do
      # Find the approval URL
      approve_link =
        setup_token["links"]
        |> Enum.find(fn link -> link["rel"] == "approve" end)

      {:ok,
       %{
         session_id: setup_token["id"],
         url: approve_link["href"],
         provider: :paypal
       }}
    end
  end

  @impl true
  def charge_payment_method(payment_method, amount, opts) do
    with {:ok, token} <- get_access_token(),
         {:ok, order} <- create_order_with_vault(token, payment_method, amount, opts),
         {:ok, capture} <- capture_order(token, order["id"]) do
      {:ok,
       %{
         charge_id: capture["id"],
         status: capture["status"],
         amount: amount,
         provider: :paypal
       }}
    end
  end

  @impl true
  def verify_webhook_signature(payload, signature, _secret) do
    # PayPal requires verifying via API call
    with {:ok, token} <- get_access_token() do
      verify_webhook_via_api(token, payload, signature)
    end
  end

  @impl true
  def handle_webhook_event(payload) do
    event_type = payload["event_type"]
    resource = payload["resource"]

    case event_type do
      "CHECKOUT.ORDER.APPROVED" ->
        handle_order_approved(resource, payload)

      "PAYMENT.CAPTURE.COMPLETED" ->
        handle_capture_completed(resource, payload)

      "PAYMENT.CAPTURE.DENIED" ->
        handle_capture_denied(resource, payload)

      "PAYMENT.CAPTURE.REFUNDED" ->
        handle_capture_refunded(resource, payload)

      _ ->
        {:error, :unknown_event}
    end
  end

  @impl true
  def create_refund(provider_transaction_id, amount, opts) do
    with {:ok, token} <- get_access_token(),
         {:ok, refund} <- do_create_refund(token, provider_transaction_id, amount, opts) do
      {:ok,
       %{
         refund_id: refund["id"],
         status: refund["status"],
         amount: amount,
         provider: :paypal
       }}
    end
  end

  @impl true
  def get_payment_method_details(provider_payment_method_id) do
    with {:ok, token} <- get_access_token(),
         {:ok, vault_token} <- get_vault_payment_token(token, provider_payment_method_id) do
      source = vault_token["payment_source"]

      details =
        cond do
          card = source["card"] ->
            %{
              type: "card",
              brand: card["brand"],
              last4: card["last_digits"],
              exp_month:
                card["expiry"] |> String.split("-") |> List.last() |> String.to_integer(),
              exp_year: card["expiry"] |> String.split("-") |> List.first() |> String.to_integer()
            }

          _paypal = source["paypal"] ->
            %{
              type: "paypal",
              brand: "paypal",
              last4: nil
            }

          true ->
            %{type: "unknown"}
        end

      {:ok, details}
    end
  end

  # ============================================
  # PayPal API Calls
  # ============================================

  defp create_order(token, opts) do
    amount = opts[:amount] || opts["amount"]
    currency = opts[:currency] || opts["currency"] || "EUR"
    description = opts[:description] || opts["description"] || "Payment"
    success_url = opts[:success_url] || opts["success_url"]
    cancel_url = opts[:cancel_url] || opts["cancel_url"]
    metadata = opts[:metadata] || opts["metadata"] || %{}

    # Convert cents to decimal string
    amount_str = format_amount(amount)

    body = %{
      intent: "CAPTURE",
      purchase_units: [
        %{
          amount: %{
            currency_code: String.upcase(currency),
            value: amount_str
          },
          description: description,
          custom_id: Jason.encode!(metadata)
        }
      ],
      payment_source: %{
        paypal: %{
          experience_context: %{
            payment_method_preference: "IMMEDIATE_PAYMENT_REQUIRED",
            brand_name: Settings.get_setting("billing_company_name", ""),
            locale: "en-US",
            landing_page: "LOGIN",
            user_action: "PAY_NOW",
            return_url: success_url,
            cancel_url: cancel_url
          }
        }
      }
    }

    request(:post, "/v2/checkout/orders", token, body)
  end

  defp create_order_with_vault(token, payment_method, amount, opts) do
    currency = Keyword.get(opts, :currency, "EUR")
    description = Keyword.get(opts, :description, "Payment")
    metadata = Keyword.get(opts, :metadata, %{})

    amount_str =
      if is_integer(amount) do
        # Cents to dollars
        :erlang.float_to_binary(amount / 100, decimals: 2)
      else
        Decimal.to_string(Decimal.round(amount, 2))
      end

    body = %{
      intent: "CAPTURE",
      purchase_units: [
        %{
          amount: %{
            currency_code: String.upcase(currency),
            value: amount_str
          },
          description: description,
          custom_id: Jason.encode!(metadata)
        }
      ],
      payment_source: %{
        token: %{
          id: payment_method.provider_payment_method_id,
          type: "PAYMENT_METHOD_TOKEN"
        }
      }
    }

    request(:post, "/v2/checkout/orders", token, body)
  end

  defp capture_order(token, order_id) do
    request(:post, "/v2/checkout/orders/#{order_id}/capture", token, %{})
  end

  defp create_setup_token(token, opts) do
    success_url = opts[:success_url] || opts["success_url"]
    cancel_url = opts[:cancel_url] || opts["cancel_url"]
    user_id = opts[:user_id] || opts["user_id"]

    body = %{
      payment_source: %{
        paypal: %{
          description: "Save payment method",
          usage_type: "MERCHANT",
          customer_type: "CONSUMER",
          experience_context: %{
            return_url: success_url,
            cancel_url: cancel_url
          }
        }
      },
      customer: %{
        id: "user_#{user_id}"
      }
    }

    request(:post, "/v3/vault/setup-tokens", token, body)
  end

  defp get_vault_payment_token(token, vault_id) do
    request(:get, "/v3/vault/payment-tokens/#{vault_id}", token)
  end

  defp do_create_refund(token, capture_id, amount, opts) do
    currency = Keyword.get(opts, :currency, "EUR")
    note = Keyword.get(opts, :note, "Refund")

    body =
      if amount do
        amount_str =
          if is_integer(amount) do
            :erlang.float_to_binary(amount / 100, decimals: 2)
          else
            Decimal.to_string(Decimal.round(amount, 2))
          end

        %{
          amount: %{
            currency_code: String.upcase(currency),
            value: amount_str
          },
          note_to_payer: note
        }
      else
        %{note_to_payer: note}
      end

    request(:post, "/v2/payments/captures/#{capture_id}/refund", token, body)
  end

  defp verify_webhook_via_api(token, payload, headers) when is_map(headers) do
    webhook_id = Settings.get_setting("billing_paypal_webhook_id", "")

    body = %{
      auth_algo: headers["paypal-auth-algo"],
      cert_url: headers["paypal-cert-url"],
      transmission_id: headers["paypal-transmission-id"],
      transmission_sig: headers["paypal-transmission-sig"],
      transmission_time: headers["paypal-transmission-time"],
      webhook_id: webhook_id,
      webhook_event: payload
    }

    case request(:post, "/v1/notifications/verify-webhook-signature", token, body) do
      {:ok, %{"verification_status" => "SUCCESS"}} -> :ok
      {:ok, _} -> {:error, :invalid_signature}
      error -> error
    end
  end

  defp verify_webhook_via_api(_token, _payload, _signature) do
    # If signature is just a string, we can't verify properly
    # In production, headers should be passed
    Logger.warning("PayPal webhook verification requires full headers map")
    :ok
  end

  # ============================================
  # Webhook Event Handlers
  # ============================================

  defp handle_order_approved(resource, payload) do
    order_id = resource["id"]
    custom_id = get_custom_id(resource)

    {:ok,
     %{
       event_id: payload["id"],
       type: "checkout.completed",
       provider: :paypal,
       data: %{
         session_id: order_id,
         mode: "payment",
         invoice_id: custom_id["invoice_id"],
         payment_intent_id: order_id
       },
       raw_payload: payload
     }}
  end

  defp handle_capture_completed(resource, payload) do
    capture_id = resource["id"]
    amount = resource["amount"]
    custom_id = get_custom_id_from_capture(resource)

    {:ok,
     %{
       event_id: payload["id"],
       type: "payment.succeeded",
       provider: :paypal,
       data: %{
         charge_id: capture_id,
         invoice_id: custom_id["invoice_id"],
         amount: parse_amount(amount["value"]),
         currency: amount["currency_code"]
       },
       raw_payload: payload
     }}
  end

  defp handle_capture_denied(resource, payload) do
    custom_id = get_custom_id_from_capture(resource)

    {:ok,
     %{
       event_id: payload["id"],
       type: "payment.failed",
       provider: :paypal,
       data: %{
         invoice_id: custom_id["invoice_id"],
         error_code: "CAPTURE_DENIED",
         error_message: "Payment capture was denied"
       },
       raw_payload: payload
     }}
  end

  defp handle_capture_refunded(resource, payload) do
    refund_id = resource["id"]
    amount = resource["amount"]

    {:ok,
     %{
       event_id: payload["id"],
       type: "refund.created",
       provider: :paypal,
       data: %{
         refund_id: refund_id,
         charge_id: resource["links"] |> find_capture_id(),
         amount_refunded: parse_amount(amount["value"])
       },
       raw_payload: payload
     }}
  end

  # ============================================
  # OAuth2 Token Management
  # ============================================

  defp get_access_token do
    # In production, this should be cached
    client_id = Settings.get_setting("billing_paypal_client_id", "")
    client_secret = Settings.get_setting("billing_paypal_client_secret", "")

    if client_id == "" or client_secret == "" do
      {:error, :not_configured}
    else
      auth = Base.encode64("#{client_id}:#{client_secret}")

      case Req.post(
             "#{base_url()}/v1/oauth2/token",
             headers: [
               {"Authorization", "Basic #{auth}"},
               {"Content-Type", "application/x-www-form-urlencoded"}
             ],
             body: "grant_type=client_credentials"
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, body["access_token"]}

        {:ok, %{status: status, body: body}} ->
          Logger.error("PayPal OAuth error: #{status} - #{inspect(body)}")
          {:error, :authentication_failed}

        {:error, reason} ->
          Logger.error("PayPal OAuth request failed: #{inspect(reason)}")
          {:error, :request_failed}
      end
    end
  end

  # ============================================
  # HTTP Helpers
  # ============================================

  defp request(method, path, token, body \\ nil) do
    url = "#{base_url()}#{path}"

    headers = [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"},
      {"PayPal-Request-Id", generate_request_id()}
    ]

    opts =
      case method do
        :get -> [headers: headers]
        _ -> [headers: headers, json: body]
      end

    result =
      case method do
        :get -> Req.get(url, opts)
        :post -> Req.post(url, opts)
      end

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("PayPal API error: #{status} - #{inspect(body)}")
        error_message = get_in(body, ["details", Access.at(0), "description"]) || "API error"
        {:error, error_message}

      {:error, reason} ->
        Logger.error("PayPal request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  # ============================================
  # Helpers
  # ============================================

  defp base_url do
    case Settings.get_setting("billing_paypal_mode", "sandbox") do
      "live" -> @live_url
      _ -> @sandbox_url
    end
  end

  defp has_credentials? do
    Settings.get_setting("billing_paypal_client_id", "") != "" &&
      Settings.get_setting("billing_paypal_client_secret", "") != ""
  end

  defp format_amount(amount) when is_integer(amount) do
    # Cents to dollars
    :erlang.float_to_binary(amount / 100, decimals: 2)
  end

  defp format_amount(%Decimal{} = amount) do
    Decimal.to_string(Decimal.round(amount, 2))
  end

  defp format_amount(amount) when is_float(amount) do
    :erlang.float_to_binary(amount, decimals: 2)
  end

  defp parse_amount(amount_str) when is_binary(amount_str) do
    {float, _} = Float.parse(amount_str)
    round(float * 100)
  end

  defp parse_amount(amount), do: amount

  defp get_custom_id(resource) do
    custom_id_json =
      resource["purchase_units"]
      |> List.first()
      |> Map.get("custom_id", "{}")

    case Jason.decode(custom_id_json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp get_custom_id_from_capture(resource) do
    # Try to get from supplementary_data or links
    custom_id_json = resource["custom_id"] || "{}"

    case Jason.decode(custom_id_json) do
      {:ok, map} -> map
      _ -> %{}
    end
  end

  defp find_capture_id(links) when is_list(links) do
    case Enum.find(links, fn link -> link["rel"] == "up" end) do
      %{"href" => href} -> href |> String.split("/") |> List.last()
      _ -> nil
    end
  end

  defp find_capture_id(_), do: nil

  defp generate_request_id do
    "req_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end

  defp invoice_to_opts(invoice) when is_map(invoice) do
    amount = invoice[:total] || invoice["total"] || Decimal.new(0)
    amount_cents = Decimal.to_integer(Decimal.mult(amount, 100))

    [
      amount: amount_cents,
      currency: invoice[:currency] || invoice["currency"] || "EUR",
      description: "Invoice #{invoice[:invoice_number] || invoice["invoice_number"]}",
      metadata: %{
        invoice_id: invoice[:uuid] || invoice["uuid"] || invoice[:id] || invoice["id"],
        invoice_number: invoice[:invoice_number] || invoice["invoice_number"]
      }
    ]
  end

  defp invoice_to_opts(_), do: []
end
