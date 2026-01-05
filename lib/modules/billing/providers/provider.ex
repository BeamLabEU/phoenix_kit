defmodule PhoenixKit.Modules.Billing.Providers.Provider do
  @moduledoc """
  Behaviour for payment providers.

  Defines a unified interface for all payment systems (Stripe, PayPal, Razorpay).
  Each provider implements this behaviour to handle payments, refunds, and webhooks.

  ## Provider Architecture

  PhoenixKit uses Internal Subscription Control - subscriptions are managed
  in our database, not by providers. Providers only handle:
  - One-time payments (checkout sessions)
  - Saving payment methods for recurring billing
  - Charging saved payment methods
  - Processing refunds

  ## Hosted Checkout Flow

      1. User clicks "Pay with Stripe" on invoice
      2. Backend calls create_checkout_session/2
      3. User redirected to provider's checkout page
      4. Provider processes payment
      5. Provider sends webhook
      6. WebhookProcessor updates invoice status

  ## Implementation Example

      defmodule PhoenixKit.Modules.Billing.Providers.Stripe do
        @behaviour PhoenixKit.Modules.Billing.Providers.Provider

        @impl true
        def provider_name, do: :stripe

        @impl true
        def available? do
          config = get_config()
          config && config.enabled && config.api_key
        end

        @impl true
        def create_checkout_session(invoice, opts) do
          # Implementation
        end
        # ... other callbacks
      end
  """

  @type checkout_session :: %{
          id: String.t(),
          url: String.t(),
          provider: atom(),
          expires_at: DateTime.t() | nil,
          metadata: map()
        }

  @type setup_session :: %{
          id: String.t(),
          url: String.t(),
          provider: atom(),
          metadata: map()
        }

  @type webhook_event :: %{
          type: String.t(),
          event_id: String.t(),
          data: map(),
          provider: atom(),
          raw_payload: map()
        }

  @type payment_method :: %{
          id: String.t(),
          provider: atom(),
          provider_payment_method_id: String.t(),
          provider_customer_id: String.t() | nil,
          type: String.t(),
          brand: String.t() | nil,
          last4: String.t() | nil,
          exp_month: integer() | nil,
          exp_year: integer() | nil,
          metadata: map()
        }

  @type charge_result :: %{
          id: String.t(),
          provider_transaction_id: String.t(),
          amount: Decimal.t(),
          currency: String.t(),
          status: String.t(),
          metadata: map()
        }

  @type refund_result :: %{
          id: String.t(),
          provider_refund_id: String.t(),
          amount: Decimal.t(),
          status: String.t(),
          metadata: map()
        }

  @doc """
  Returns the provider name as an atom.

  ## Examples

      iex> Stripe.provider_name()
      :stripe

      iex> PayPal.provider_name()
      :paypal
  """
  @callback provider_name() :: atom()

  @doc """
  Checks if the provider is configured and available for use.

  Returns `true` if:
  - Provider is enabled in settings
  - API credentials are configured
  - Provider passed verification (if applicable)

  ## Examples

      iex> Stripe.available?()
      true
  """
  @callback available?() :: boolean()

  @doc """
  Creates a checkout session for one-time payment.

  This is used for paying invoices. The user is redirected to the
  provider's hosted checkout page where they enter payment details.

  ## Parameters

  - `invoice` - The invoice to pay (must include amount, currency, line_items)
  - `opts` - Options:
    - `:success_url` - URL to redirect after successful payment
    - `:cancel_url` - URL to redirect if user cancels
    - `:save_payment_method` - Whether to save card for future use (default: false)

  ## Returns

  - `{:ok, checkout_session}` - Session created, redirect user to `session.url`
  - `{:error, reason}` - Failed to create session
  """
  @callback create_checkout_session(invoice :: map(), opts :: keyword()) ::
              {:ok, checkout_session()} | {:error, term()}

  @doc """
  Creates a setup session to save a payment method without charging.

  Used when a user wants to add a payment method for future subscriptions
  without making an immediate payment.

  ## Parameters

  - `user` - The user to save payment method for
  - `opts` - Options:
    - `:success_url` - URL to redirect after success
    - `:cancel_url` - URL to redirect if user cancels

  ## Returns

  - `{:ok, setup_session}` - Session created
  - `{:error, reason}` - Failed to create session
  """
  @callback create_setup_session(user :: map(), opts :: keyword()) ::
              {:ok, setup_session()} | {:error, term()}

  @doc """
  Charges a saved payment method.

  Used for subscription renewals. The payment method was previously
  saved during checkout or setup session.

  ## Parameters

  - `payment_method` - The saved payment method record
  - `amount` - Amount to charge (Decimal)
  - `opts` - Options:
    - `:currency` - Currency code (default: from payment method)
    - `:description` - Description for the charge
    - `:invoice_id` - Associated invoice ID
    - `:metadata` - Additional metadata

  ## Returns

  - `{:ok, charge_result}` - Charge successful
  - `{:error, :card_declined}` - Card was declined
  - `{:error, :payment_method_expired}` - Payment method expired
  - `{:error, reason}` - Other error
  """
  @callback charge_payment_method(
              payment_method :: map(),
              amount :: Decimal.t(),
              opts :: keyword()
            ) :: {:ok, charge_result()} | {:error, term()}

  @doc """
  Verifies webhook signature to ensure request is from the provider.

  ## Parameters

  - `payload` - Raw request body as binary
  - `signature` - Signature from request headers
  - `secret` - Webhook secret for this provider

  ## Returns

  - `:ok` - Signature is valid
  - `{:error, :invalid_signature}` - Signature verification failed
  """
  @callback verify_webhook_signature(
              payload :: binary(),
              signature :: String.t(),
              secret :: String.t()
            ) :: :ok | {:error, :invalid_signature}

  @doc """
  Handles and normalizes a webhook event payload.

  Converts provider-specific event format to a normalized format
  that can be processed by WebhookProcessor.

  ## Parameters

  - `payload` - Decoded JSON payload from webhook

  ## Returns

  - `{:ok, webhook_event}` - Event parsed successfully
  - `{:error, :unknown_event}` - Event type not recognized
  - `{:error, reason}` - Failed to parse event
  """
  @callback handle_webhook_event(payload :: map()) ::
              {:ok, webhook_event()} | {:error, term()}

  @doc """
  Creates a refund for a transaction.

  ## Parameters

  - `provider_transaction_id` - The provider's transaction/charge ID
  - `amount` - Amount to refund (Decimal, nil for full refund)
  - `opts` - Options:
    - `:reason` - Reason for refund
    - `:metadata` - Additional metadata

  ## Returns

  - `{:ok, refund_result}` - Refund created
  - `{:error, :already_refunded}` - Transaction already refunded
  - `{:error, reason}` - Refund failed
  """
  @callback create_refund(
              provider_transaction_id :: String.t(),
              amount :: Decimal.t() | nil,
              opts :: keyword()
            ) :: {:ok, refund_result()} | {:error, term()}

  @doc """
  Gets details of a saved payment method.

  ## Parameters

  - `provider_payment_method_id` - The provider's payment method ID

  ## Returns

  - `{:ok, payment_method}` - Payment method details
  - `{:error, :not_found}` - Payment method not found
  - `{:error, reason}` - Failed to get details
  """
  @callback get_payment_method_details(provider_payment_method_id :: String.t()) ::
              {:ok, payment_method()} | {:error, term()}

  @doc """
  Detaches/removes a saved payment method from the provider.

  ## Parameters

  - `provider_payment_method_id` - The provider's payment method ID

  ## Returns

  - `:ok` - Payment method removed
  - `{:error, :not_found}` - Payment method not found
  - `{:error, reason}` - Failed to remove
  """
  @callback detach_payment_method(provider_payment_method_id :: String.t()) ::
              :ok | {:error, term()}

  @optional_callbacks detach_payment_method: 1
end
