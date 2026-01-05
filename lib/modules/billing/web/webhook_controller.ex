defmodule PhoenixKit.Modules.Billing.Web.WebhookController do
  @moduledoc """
  Handles webhooks from payment providers (Stripe, PayPal, Razorpay).

  This controller receives webhook events from payment providers,
  verifies their signatures, and processes them through the WebhookProcessor.

  ## Webhook URLs

  Configure these URLs in your payment provider dashboards:

  - Stripe: `https://yourdomain.com/phoenix_kit/webhooks/billing/stripe`
  - PayPal: `https://yourdomain.com/phoenix_kit/webhooks/billing/paypal`
  - Razorpay: `https://yourdomain.com/phoenix_kit/webhooks/billing/razorpay`

  ## Security

  All webhooks verify signatures to ensure they come from legitimate sources.
  Invalid signatures result in 401 Unauthorized responses.

  ## Idempotency

  Events are logged in the `phoenix_kit_webhook_events` table with their
  event IDs. Duplicate events are detected and ignored to prevent
  double-processing.
  """

  use Phoenix.Controller,
    formats: [:json]

  alias PhoenixKit.Modules.Billing.Providers
  alias PhoenixKit.Modules.Billing.WebhookProcessor
  alias PhoenixKit.Settings

  require Logger

  @doc """
  Handles Stripe webhooks.

  Expects the raw body in `conn.assigns.raw_body` (set by a custom Plug).
  Signature is read from the `stripe-signature` header.
  """
  def stripe(conn, _params) do
    handle_webhook(conn, :stripe, "stripe-signature")
  end

  @doc """
  Handles PayPal webhooks.

  PayPal verification requires multiple headers for signature verification.
  """
  def paypal(conn, _params) do
    handle_webhook(conn, :paypal, "paypal-transmission-sig")
  end

  @doc """
  Handles Razorpay webhooks.

  Signature is read from the `x-razorpay-signature` header.
  """
  def razorpay(conn, _params) do
    handle_webhook(conn, :razorpay, "x-razorpay-signature")
  end

  # ===========================================
  # Private Implementation
  # ===========================================

  defp handle_webhook(conn, provider, signature_header) do
    with {:ok, raw_body} <- get_raw_body(conn),
         {:ok, signature} <- get_signature(conn, signature_header),
         {:ok, secret} <- get_webhook_secret(provider),
         :ok <- verify_signature(provider, raw_body, signature, secret),
         {:ok, payload} <- decode_payload(raw_body),
         {:ok, event} <- Providers.handle_webhook_event(provider, payload),
         {:ok, _result} <- WebhookProcessor.process(event) do
      Logger.info("Webhook processed successfully: #{provider} - #{event.type}")

      conn
      |> put_status(200)
      |> json(%{status: "ok"})
    else
      {:error, :invalid_signature} ->
        Logger.warning("Invalid webhook signature from #{provider}")

        conn
        |> put_status(401)
        |> json(%{error: "Invalid signature"})

      {:error, :duplicate_event} ->
        # Duplicate events are OK - return 200 to prevent retries
        Logger.debug("Duplicate webhook event from #{provider}")

        conn
        |> put_status(200)
        |> json(%{status: "duplicate"})

      {:error, :unknown_event} ->
        # Unknown events are OK - return 200 to prevent retries
        Logger.debug("Unknown webhook event type from #{provider}")

        conn
        |> put_status(200)
        |> json(%{status: "ignored"})

      {:error, :not_configured} ->
        Logger.warning("Webhook received for unconfigured provider: #{provider}")

        conn
        |> put_status(400)
        |> json(%{error: "Provider not configured"})

      {:error, reason} ->
        Logger.error("Webhook processing failed for #{provider}: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> json(%{error: "Processing failed"})
    end
  end

  defp get_raw_body(conn) do
    case conn.assigns[:raw_body] do
      nil ->
        # Try to read from body_params if raw_body not set
        # This is a fallback - ideally raw_body should be set by a Plug
        {:error, :no_raw_body}

      raw_body when is_binary(raw_body) ->
        {:ok, raw_body}
    end
  end

  defp get_signature(conn, header_name) do
    case get_req_header(conn, header_name) do
      [signature | _] -> {:ok, signature}
      [] -> {:error, :no_signature}
    end
  end

  defp get_webhook_secret(provider) do
    key = "billing_#{provider}_webhook_secret"

    case Settings.get_setting(key, "") do
      "" -> {:error, :not_configured}
      secret -> {:ok, secret}
    end
  end

  defp verify_signature(provider, raw_body, signature, secret) do
    Providers.verify_webhook_signature(provider, raw_body, signature, secret)
  end

  defp decode_payload(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} -> {:ok, payload}
      {:error, _} -> {:error, :invalid_json}
    end
  end
end
