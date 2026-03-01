defmodule PhoenixKit.Modules.Billing.Providers.Stripe do
  @moduledoc """
  Stripe payment provider implementation.

  This module implements the `PhoenixKit.Modules.Billing.Providers.Provider` behaviour
  for Stripe payments. It supports:

  - Hosted Checkout for one-time payments
  - Setup sessions for saving payment methods
  - Charging saved payment methods (for subscription renewals)
  - Webhook signature verification
  - Refunds

  ## Configuration

  Configure Stripe in your provider settings:

      # Via Admin UI: /admin/settings/billing/providers
      # Or via Settings API:
      PhoenixKit.Modules.Billing.update_provider_config(:stripe, %{
        enabled: true,
        mode: "test",
        api_key: "sk_test_...",
        webhook_secret: "whsec_..."
      })

  ## Webhook Events

  Configure your Stripe webhook to send these events:
  - `checkout.session.completed` - Payment completed
  - `checkout.session.expired` - Session expired
  - `payment_intent.succeeded` - Payment succeeded (for saved cards)
  - `payment_intent.payment_failed` - Payment failed
  - `charge.refunded` - Refund processed
  - `setup_intent.succeeded` - Card saved successfully

  ## Dependencies

  Requires the `stripe` hex package:

      {:stripe, "~> 1.1"}
  """

  @behaviour PhoenixKit.Modules.Billing.Providers.Provider

  alias PhoenixKit.Modules.Billing.Providers.Types.{
    ChargeResult,
    CheckoutSession,
    PaymentMethodInfo,
    RefundResult,
    SetupSession,
    WebhookEventData
  }

  alias PhoenixKit.Settings

  require Logger

  @stripe_api_version "2023-10-16"

  # Provider identification
  @impl true
  def provider_name, do: :stripe

  @impl true
  def available? do
    config = get_config()
    config[:enabled] && config[:api_key] && config[:api_key] != ""
  end

  @doc """
  Creates a Stripe Checkout Session for one-time payment.

  ## Options

  - `:success_url` - URL to redirect after successful payment (required)
  - `:cancel_url` - URL to redirect if user cancels (required)
  - `:save_payment_method` - Whether to save card for future use (default: false)
  - `:customer_email` - Pre-fill customer email
  - `:metadata` - Additional metadata to attach

  ## Examples

      iex> create_checkout_session(invoice, success_url: "https://...", cancel_url: "https://...")
      {:ok, %{id: "cs_test_...", url: "https://checkout.stripe.com/..."}}
  """
  @impl true
  def create_checkout_session(invoice, opts) do
    with {:ok, config} <- ensure_configured() do
      line_items = build_line_items(invoice)

      params = %{
        mode: "payment",
        line_items: line_items,
        success_url: Keyword.fetch!(opts, :success_url),
        cancel_url: Keyword.fetch!(opts, :cancel_url),
        client_reference_id: to_string(invoice.uuid),
        metadata: %{
          invoice_uuid: to_string(invoice.uuid),
          invoice_number: invoice.invoice_number
        }
      }

      params =
        params
        |> maybe_add_customer_email(invoice, opts)
        |> maybe_add_save_payment_method(opts)
        |> maybe_add_custom_metadata(opts)

      case stripe_request(:post, "/checkout/sessions", params, config) do
        {:ok, %{"id" => id, "url" => url, "expires_at" => expires_at}} ->
          {:ok,
           %CheckoutSession{
             id: id,
             url: url,
             provider: :stripe,
             expires_at: DateTime.from_unix!(expires_at),
             metadata: %{invoice_uuid: invoice.uuid}
           }}

        {:error, reason} ->
          Logger.error("Stripe checkout session creation failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Creates a Stripe Setup Session to save a payment method.

  ## Options

  - `:success_url` - URL to redirect after success (required)
  - `:cancel_url` - URL to redirect if user cancels (required)
  - `:customer_email` - Customer email

  ## Examples

      iex> create_setup_session(user, success_url: "https://...", cancel_url: "https://...")
      {:ok, %{id: "seti_...", url: "https://checkout.stripe.com/..."}}
  """
  @impl true
  def create_setup_session(user, opts) do
    with {:ok, config} <- ensure_configured(),
         {:ok, customer_id} <- ensure_customer(user, config) do
      params = %{
        mode: "setup",
        customer: customer_id,
        success_url: Keyword.fetch!(opts, :success_url),
        cancel_url: Keyword.fetch!(opts, :cancel_url),
        payment_method_types: ["card"],
        metadata: %{
          user_uuid: to_string(user.uuid)
        }
      }

      case stripe_request(:post, "/checkout/sessions", params, config) do
        {:ok, %{"id" => id, "url" => url}} ->
          {:ok,
           %SetupSession{
             id: id,
             url: url,
             provider: :stripe,
             metadata: %{user_uuid: user.uuid, customer_id: customer_id}
           }}

        {:error, reason} ->
          Logger.error("Stripe setup session creation failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Charges a saved payment method.

  Used for subscription renewals where the payment method was previously saved.

  ## Options

  - `:currency` - Currency code (default: EUR)
  - `:description` - Description for the charge
  - `:invoice_uuid` - Associated invoice UUID
  - `:metadata` - Additional metadata

  ## Examples

      iex> charge_payment_method(payment_method, Decimal.new("99.00"), currency: "EUR")
      {:ok, %{id: "pi_...", provider_transaction_id: "ch_...", status: "succeeded"}}
  """
  @impl true
  def charge_payment_method(payment_method, amount, opts) do
    with {:ok, config} <- ensure_configured() do
      currency = Keyword.get(opts, :currency, "EUR") |> String.downcase()
      amount_cents = Decimal.mult(amount, 100) |> Decimal.round() |> Decimal.to_integer()

      params = %{
        amount: amount_cents,
        currency: currency,
        customer: payment_method.provider_customer_id,
        payment_method: payment_method.provider_payment_method_id,
        off_session: true,
        confirm: true,
        description: Keyword.get(opts, :description, "PhoenixKit subscription payment"),
        metadata:
          %{
            payment_method_uuid: to_string(payment_method.uuid)
          }
          |> maybe_merge_invoice_metadata(opts)
      }

      case stripe_request(:post, "/payment_intents", params, config) do
        {:ok, %{"id" => id, "status" => "succeeded", "latest_charge" => charge_id}} ->
          {:ok,
           %ChargeResult{
             id: id,
             provider_transaction_id: charge_id,
             amount: amount,
             currency: String.upcase(currency),
             status: "succeeded",
             metadata: %{payment_intent_id: id}
           }}

        {:ok, %{"status" => "requires_action"}} ->
          {:error, :requires_action}

        {:ok, %{"status" => "requires_payment_method"}} ->
          {:error, :card_declined}

        {:error, %{"code" => "card_declined"}} ->
          {:error, :card_declined}

        {:error, %{"code" => "expired_card"}} ->
          {:error, :payment_method_expired}

        {:error, reason} ->
          Logger.error("Stripe charge failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Verifies Stripe webhook signature.

  Uses Stripe's signature verification to ensure the webhook came from Stripe.

  ## Examples

      iex> verify_webhook_signature(raw_body, signature_header, webhook_secret)
      :ok

      iex> verify_webhook_signature(raw_body, "invalid", webhook_secret)
      {:error, :invalid_signature}
  """
  @impl true
  def verify_webhook_signature(payload, signature, secret) do
    # Stripe signature format: t=timestamp,v1=signature
    with {:ok, parts} <- parse_signature(signature),
         {:ok, timestamp} <- Map.fetch(parts, "t"),
         {:ok, expected_sig} <- Map.fetch(parts, "v1"),
         :ok <- verify_timestamp(timestamp),
         :ok <- verify_signature(payload, timestamp, expected_sig, secret) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @doc """
  Handles and normalizes Stripe webhook events.

  ## Supported Events

  - `checkout.session.completed` - Checkout payment completed
  - `checkout.session.expired` - Checkout session expired
  - `payment_intent.succeeded` - Payment intent succeeded
  - `payment_intent.payment_failed` - Payment failed
  - `charge.refunded` - Charge refunded
  - `setup_intent.succeeded` - Setup intent completed (card saved)

  ## Examples

      iex> handle_webhook_event(%{"type" => "checkout.session.completed", ...})
      {:ok, %{type: "checkout.completed", event_id: "evt_...", data: %{...}}}
  """
  @impl true
  def handle_webhook_event(%{"type" => type, "id" => event_id, "data" => %{"object" => object}}) do
    case normalize_event(type, object) do
      {:ok, normalized} ->
        {:ok,
         %WebhookEventData{
           type: normalized.type,
           event_id: event_id,
           data: normalized.data,
           provider: :stripe,
           raw_payload: object
         }}

      {:error, :unknown_event} ->
        Logger.debug("Unknown Stripe event type: #{type}")
        {:error, :unknown_event}
    end
  end

  def handle_webhook_event(_payload) do
    {:error, :invalid_payload}
  end

  @doc """
  Creates a refund for a Stripe charge.

  ## Options

  - `:reason` - Reason for refund ("duplicate", "fraudulent", "requested_by_customer")
  - `:metadata` - Additional metadata

  ## Examples

      iex> create_refund("ch_xxx", Decimal.new("50.00"), reason: "requested_by_customer")
      {:ok, %{id: "re_...", provider_refund_id: "re_...", amount: #Decimal<50.00>}}
  """
  @impl true
  def create_refund(provider_transaction_id, amount, opts) do
    with {:ok, config} <- ensure_configured() do
      params = %{
        charge: provider_transaction_id
      }

      params =
        if amount do
          amount_cents = Decimal.mult(amount, 100) |> Decimal.round() |> Decimal.to_integer()
          Map.put(params, :amount, amount_cents)
        else
          params
        end

      params =
        case Keyword.get(opts, :reason) do
          nil -> params
          reason -> Map.put(params, :reason, reason)
        end

      case stripe_request(:post, "/refunds", params, config) do
        {:ok, %{"id" => id, "amount" => amount_cents, "status" => status}} ->
          {:ok,
           %RefundResult{
             id: id,
             provider_refund_id: id,
             amount: Decimal.div(Decimal.new(amount_cents), 100),
             status: status,
             metadata: %{}
           }}

        {:error, %{"code" => "charge_already_refunded"}} ->
          {:error, :already_refunded}

        {:error, reason} ->
          Logger.error("Stripe refund failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Gets details of a saved payment method from Stripe.

  ## Examples

      iex> get_payment_method_details("pm_xxx")
      {:ok, %{id: "pm_xxx", type: "card", brand: "visa", last4: "4242", ...}}
  """
  @impl true
  def get_payment_method_details(provider_payment_method_id) do
    with {:ok, config} <- ensure_configured() do
      case stripe_request(:get, "/payment_methods/#{provider_payment_method_id}", nil, config) do
        {:ok,
         %{
           "id" => id,
           "type" => type,
           "card" => %{
             "brand" => brand,
             "last4" => last4,
             "exp_month" => exp_month,
             "exp_year" => exp_year
           }
         }} ->
          {:ok,
           %PaymentMethodInfo{
             id: id,
             provider: :stripe,
             provider_payment_method_id: id,
             provider_customer_id: nil,
             type: type,
             brand: brand,
             last4: last4,
             exp_month: exp_month,
             exp_year: exp_year,
             metadata: %{}
           }}

        {:ok, %{"id" => id, "type" => type}} ->
          {:ok,
           %PaymentMethodInfo{
             id: id,
             provider: :stripe,
             provider_payment_method_id: id,
             provider_customer_id: nil,
             type: type,
             brand: nil,
             last4: nil,
             exp_month: nil,
             exp_year: nil,
             metadata: %{}
           }}

        {:error, %{"code" => "resource_missing"}} ->
          {:error, :not_found}

        {:error, reason} ->
          Logger.error("Stripe get payment method failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Detaches a payment method from its customer.

  ## Examples

      iex> detach_payment_method("pm_xxx")
      :ok
  """
  @impl true
  def detach_payment_method(provider_payment_method_id) do
    with {:ok, config} <- ensure_configured() do
      case stripe_request(
             :post,
             "/payment_methods/#{provider_payment_method_id}/detach",
             %{},
             config
           ) do
        {:ok, _} -> :ok
        {:error, %{"code" => "resource_missing"}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ===========================================
  # Private Helpers
  # ===========================================

  defp get_config do
    %{
      enabled: Settings.get_setting("billing_stripe_enabled", "false") == "true",
      api_key: Settings.get_setting("billing_stripe_api_key", ""),
      webhook_secret: Settings.get_setting("billing_stripe_webhook_secret", "")
    }
  end

  defp ensure_configured do
    config = get_config()

    if config[:enabled] && config[:api_key] && config[:api_key] != "" do
      {:ok, config}
    else
      {:error, :not_configured}
    end
  end

  defp stripe_request(method, path, body, config) do
    url = "https://api.stripe.com/v1#{path}"

    headers = [
      {"Authorization", "Bearer #{config[:api_key]}"},
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Stripe-Version", @stripe_api_version}
    ]

    body_encoded = if body, do: encode_body(body), else: ""

    request =
      case method do
        :get -> Req.new(method: :get, url: url, headers: headers)
        :post -> Req.new(method: :post, url: url, headers: headers, body: body_encoded)
      end

    case Req.request(request) do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: _status, body: %{"error" => error}}} ->
        {:error, error}

      {:ok, %{status: status, body: body}} ->
        {:error, %{"status" => status, "body" => body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encode_body(map) when is_map(map) do
    map
    |> flatten_map()
    |> URI.encode_query()
  end

  defp flatten_map(map, prefix \\ "") do
    Enum.flat_map(map, fn {key, value} ->
      new_key = if prefix == "", do: to_string(key), else: "#{prefix}[#{key}]"
      flatten_value(new_key, value)
    end)
  end

  defp flatten_value(key, %{} = nested), do: flatten_map(nested, key)

  defp flatten_value(key, list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} -> flatten_list_item(key, item, idx) end)
  end

  defp flatten_value(key, value), do: [{key, to_string(value)}]

  defp flatten_list_item(key, item, idx) when is_map(item) do
    flatten_map(item, "#{key}[#{idx}]")
  end

  defp flatten_list_item(key, item, idx) do
    [{"#{key}[#{idx}]", to_string(item)}]
  end

  defp build_line_items(invoice) do
    (invoice.line_items || [])
    |> Enum.map(fn item ->
      %{
        price_data: %{
          currency: String.downcase(invoice.currency || "EUR"),
          product_data: %{
            name: item["name"] || "Item"
          },
          unit_amount: parse_amount_cents(item["unit_price"])
        },
        quantity: item["quantity"] || 1
      }
    end)
  end

  defp parse_amount_cents(nil), do: 0

  defp parse_amount_cents(amount) when is_binary(amount) do
    amount
    |> Decimal.new()
    |> Decimal.mult(100)
    |> Decimal.round()
    |> Decimal.to_integer()
  end

  defp parse_amount_cents(%Decimal{} = amount) do
    amount
    |> Decimal.mult(100)
    |> Decimal.round()
    |> Decimal.to_integer()
  end

  defp parse_amount_cents(amount) when is_number(amount) do
    round(amount * 100)
  end

  defp maybe_add_customer_email(params, invoice, opts) do
    email = Keyword.get(opts, :customer_email) || get_invoice_email(invoice)

    if email do
      Map.put(params, :customer_email, email)
    else
      params
    end
  end

  defp get_invoice_email(invoice) do
    case invoice do
      %{billing_details: %{"email" => email}} when is_binary(email) -> email
      %{user: %{email: email}} when is_binary(email) -> email
      _ -> nil
    end
  end

  defp maybe_add_save_payment_method(params, opts) do
    if Keyword.get(opts, :save_payment_method, false) do
      Map.merge(params, %{
        payment_intent_data: %{
          setup_future_usage: "off_session"
        }
      })
    else
      params
    end
  end

  defp maybe_add_custom_metadata(params, opts) do
    case Keyword.get(opts, :metadata) do
      nil -> params
      custom -> Map.update!(params, :metadata, &Map.merge(&1, custom))
    end
  end

  defp maybe_merge_invoice_metadata(metadata, opts) do
    case Keyword.get(opts, :invoice_uuid) do
      nil -> metadata
      invoice_uuid -> Map.put(metadata, :invoice_uuid, to_string(invoice_uuid))
    end
  end

  defp ensure_customer(user, config) do
    # Check if user already has a Stripe customer ID from saved payment methods
    case get_stripe_customer_id_for_user(user.uuid) do
      nil ->
        # Create new customer
        params = %{
          email: user.email,
          metadata: %{
            user_uuid: to_string(user.uuid)
          }
        }

        case stripe_request(:post, "/customers", params, config) do
          {:ok, %{"id" => customer_id}} ->
            {:ok, customer_id}

          {:error, reason} ->
            {:error, reason}
        end

      customer_id ->
        {:ok, customer_id}
    end
  end

  defp get_stripe_customer_id_for_user(user_uuid) do
    import Ecto.Query

    query =
      from pm in PhoenixKit.Modules.Billing.PaymentMethod,
        where: pm.user_uuid == ^user_uuid,
        where: pm.provider == "stripe",
        where: not is_nil(pm.provider_customer_id),
        where: pm.status == "active",
        select: pm.provider_customer_id,
        limit: 1

    PhoenixKit.RepoHelper.repo().one(query)
  end

  defp parse_signature(signature) do
    parts =
      signature
      |> String.split(",")
      |> Enum.map(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> {key, value}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    {:ok, parts}
  rescue
    _ -> {:error, :invalid_format}
  end

  defp verify_timestamp(timestamp) do
    # Stripe recommends rejecting webhooks older than 5 minutes
    timestamp_int = String.to_integer(timestamp)
    now = System.system_time(:second)
    tolerance = 300

    if abs(now - timestamp_int) <= tolerance do
      :ok
    else
      {:error, :timestamp_too_old}
    end
  rescue
    _ -> {:error, :invalid_timestamp}
  end

  defp verify_signature(payload, timestamp, expected_sig, secret) do
    signed_payload = "#{timestamp}.#{payload}"

    computed_sig =
      :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)

    if Plug.Crypto.secure_compare(computed_sig, expected_sig) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end

  defp normalize_event("checkout.session.completed", object) do
    {:ok,
     %{
       type: "checkout.completed",
       data: %{
         session_id: object["id"],
         payment_status: object["payment_status"],
         customer_id: object["customer"],
         customer_email: object["customer_email"],
         payment_intent_id: object["payment_intent"],
         setup_intent_id: object["setup_intent"],
         invoice_uuid:
           get_in(object, ["metadata", "invoice_uuid"]) ||
             get_in(object, ["metadata", "invoice_id"]),
         mode: object["mode"],
         amount_total: object["amount_total"],
         currency: object["currency"]
       }
     }}
  end

  defp normalize_event("checkout.session.expired", object) do
    {:ok,
     %{
       type: "checkout.expired",
       data: %{
         session_id: object["id"],
         invoice_uuid:
           get_in(object, ["metadata", "invoice_uuid"]) ||
             get_in(object, ["metadata", "invoice_id"])
       }
     }}
  end

  defp normalize_event("payment_intent.succeeded", object) do
    {:ok,
     %{
       type: "payment.succeeded",
       data: %{
         payment_intent_id: object["id"],
         charge_id: object["latest_charge"],
         amount: object["amount"],
         currency: object["currency"],
         customer_id: object["customer"],
         payment_method_id: object["payment_method"],
         invoice_uuid:
           get_in(object, ["metadata", "invoice_uuid"]) ||
             get_in(object, ["metadata", "invoice_id"])
       }
     }}
  end

  defp normalize_event("payment_intent.payment_failed", object) do
    {:ok,
     %{
       type: "payment.failed",
       data: %{
         payment_intent_id: object["id"],
         error_code: get_in(object, ["last_payment_error", "code"]),
         error_message: get_in(object, ["last_payment_error", "message"]),
         customer_id: object["customer"],
         invoice_uuid:
           get_in(object, ["metadata", "invoice_uuid"]) ||
             get_in(object, ["metadata", "invoice_id"])
       }
     }}
  end

  defp normalize_event("charge.refunded", object) do
    {:ok,
     %{
       type: "refund.created",
       data: %{
         charge_id: object["id"],
         amount_refunded: object["amount_refunded"],
         currency: object["currency"],
         refund_id: List.first(object["refunds"]["data"] || [])["id"]
       }
     }}
  end

  defp normalize_event("setup_intent.succeeded", object) do
    {:ok,
     %{
       type: "setup.completed",
       data: %{
         setup_intent_id: object["id"],
         payment_method_id: object["payment_method"],
         customer_id: object["customer"],
         user_uuid:
           get_in(object, ["metadata", "user_uuid"]) ||
             get_in(object, ["metadata", "user_id"])
       }
     }}
  end

  defp normalize_event(_type, _object) do
    {:error, :unknown_event}
  end
end
