defmodule PhoenixKit.Modules.Billing.Providers do
  @moduledoc """
  Provider registry and helper functions for payment providers.

  This module serves as the central point for working with payment providers.
  It handles provider lookup, availability checking, and configuration.

  ## Available Providers

  - `:stripe` - Stripe payments (cards, wallets)
  - `:paypal` - PayPal payments
  - `:razorpay` - Razorpay payments (India)

  ## Usage

      # Get a provider module
      provider = Providers.get_provider(:stripe)
      provider.create_checkout_session(invoice, opts)

      # List available providers
      Providers.list_available_providers()
      #=> [:stripe, :paypal]

      # Check if provider is available
      Providers.provider_enabled?(:stripe)
      #=> true
  """

  alias PhoenixKit.Modules.Billing.Providers.Provider
  alias PhoenixKit.Settings

  @providers %{
    stripe: PhoenixKit.Modules.Billing.Providers.Stripe,
    paypal: PhoenixKit.Modules.Billing.Providers.PayPal,
    razorpay: PhoenixKit.Modules.Billing.Providers.Razorpay
  }

  @provider_names Map.keys(@providers)

  @doc """
  Returns the provider module for the given provider name.

  ## Parameters

  - `name` - Provider name as atom or string

  ## Returns

  - Provider module if found
  - `nil` if provider not found

  ## Examples

      iex> Providers.get_provider(:stripe)
      PhoenixKit.Modules.Billing.Providers.Stripe

      iex> Providers.get_provider("paypal")
      PhoenixKit.Modules.Billing.Providers.PayPal

      iex> Providers.get_provider(:unknown)
      nil
  """
  @spec get_provider(atom() | String.t()) :: module() | nil
  def get_provider(name) when is_atom(name), do: @providers[name]
  def get_provider(name) when is_binary(name), do: @providers[String.to_existing_atom(name)]

  @doc """
  Returns a list of all provider names.

  ## Examples

      iex> Providers.all_providers()
      [:stripe, :paypal, :razorpay]
  """
  @spec all_providers() :: [atom()]
  def all_providers, do: @provider_names

  @doc """
  Returns a list of available (enabled and configured) provider names.

  Checks each provider's `available?/0` callback to determine availability.

  ## Examples

      iex> Providers.list_available_providers()
      [:stripe, :paypal]
  """
  @spec list_available_providers() :: [atom()]
  def list_available_providers do
    @providers
    |> Enum.filter(fn {_name, module} ->
      Code.ensure_loaded?(module) && function_exported?(module, :available?, 0) &&
        module.available?()
    end)
    |> Enum.map(fn {name, _module} -> name end)
  end

  @doc """
  Checks if a provider is enabled and available.

  ## Parameters

  - `name` - Provider name as atom or string

  ## Returns

  - `true` if provider is available
  - `false` if provider is not available or not found

  ## Examples

      iex> Providers.provider_enabled?(:stripe)
      true

      iex> Providers.provider_enabled?(:unknown)
      false
  """
  @spec provider_enabled?(atom() | String.t()) :: boolean()
  def provider_enabled?(name) do
    case get_provider(name) do
      nil -> false
      module -> Code.ensure_loaded?(module) && module.available?()
    end
  end

  @doc """
  Checks if a provider exists (regardless of availability).

  ## Examples

      iex> Providers.provider_exists?(:stripe)
      true

      iex> Providers.provider_exists?(:bitcoin)
      false
  """
  @spec provider_exists?(atom() | String.t()) :: boolean()
  def provider_exists?(name) when is_atom(name), do: Map.has_key?(@providers, name)

  def provider_exists?(name) when is_binary(name) do
    provider_exists?(String.to_existing_atom(name))
  rescue
    ArgumentError -> false
  end

  @doc """
  Gets the setting key for a provider's enabled status.

  ## Examples

      iex> Providers.enabled_setting_key(:stripe)
      "billing_stripe_enabled"
  """
  @spec enabled_setting_key(atom()) :: String.t()
  def enabled_setting_key(provider) do
    "billing_#{provider}_enabled"
  end

  @doc """
  Checks if a provider is enabled in settings.

  This is a lower-level check that only looks at the setting,
  not whether the provider is fully configured.

  ## Examples

      iex> Providers.setting_enabled?(:stripe)
      true
  """
  @spec setting_enabled?(atom()) :: boolean()
  def setting_enabled?(provider) do
    Settings.get_setting(enabled_setting_key(provider), "false") == "true"
  end

  @doc """
  Creates a checkout session using the specified provider.

  Convenience function that looks up the provider and calls
  `create_checkout_session/2`.

  ## Parameters

  - `provider` - Provider name
  - `invoice` - Invoice to pay
  - `opts` - Options passed to provider

  ## Returns

  - `{:ok, checkout_session}` - Session created
  - `{:error, :provider_not_found}` - Provider doesn't exist
  - `{:error, :provider_not_available}` - Provider not configured
  - `{:error, reason}` - Provider-specific error
  """
  @spec create_checkout_session(atom() | String.t(), map(), keyword()) ::
          {:ok, Provider.checkout_session()} | {:error, term()}
  def create_checkout_session(provider, invoice, opts \\ []) do
    with {:ok, module} <- get_available_provider(provider) do
      module.create_checkout_session(invoice, opts)
    end
  end

  @doc """
  Creates a setup session using the specified provider.

  ## Parameters

  - `provider` - Provider name
  - `user` - User to save payment method for
  - `opts` - Options passed to provider

  ## Returns

  - `{:ok, setup_session}` - Session created
  - `{:error, reason}` - Failed
  """
  @spec create_setup_session(atom() | String.t(), map(), keyword()) ::
          {:ok, Provider.setup_session()} | {:error, term()}
  def create_setup_session(provider, user, opts \\ []) do
    with {:ok, module} <- get_available_provider(provider) do
      module.create_setup_session(user, opts)
    end
  end

  @doc """
  Charges a saved payment method using the appropriate provider.

  ## Parameters

  - `payment_method` - Saved payment method record (must include :provider)
  - `amount` - Amount to charge
  - `opts` - Options passed to provider

  ## Returns

  - `{:ok, charge_result}` - Charge successful
  - `{:error, reason}` - Charge failed
  """
  @spec charge_payment_method(map(), Decimal.t(), keyword()) ::
          {:ok, Provider.charge_result()} | {:error, term()}
  def charge_payment_method(%{provider: provider} = payment_method, amount, opts \\ []) do
    with {:ok, module} <- get_available_provider(provider) do
      module.charge_payment_method(payment_method, amount, opts)
    end
  end

  @doc """
  Verifies a webhook signature for the specified provider.

  ## Parameters

  - `provider` - Provider name
  - `payload` - Raw request body
  - `signature` - Signature from headers
  - `secret` - Webhook secret

  ## Returns

  - `:ok` - Signature valid
  - `{:error, :invalid_signature}` - Signature invalid
  - `{:error, :provider_not_found}` - Provider doesn't exist
  """
  @spec verify_webhook_signature(atom() | String.t(), binary(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def verify_webhook_signature(provider, payload, signature, secret) do
    case get_provider(provider) do
      nil -> {:error, :provider_not_found}
      module -> module.verify_webhook_signature(payload, signature, secret)
    end
  end

  @doc """
  Handles a webhook event for the specified provider.

  ## Parameters

  - `provider` - Provider name
  - `payload` - Decoded JSON payload

  ## Returns

  - `{:ok, webhook_event}` - Event parsed
  - `{:error, reason}` - Failed to parse
  """
  @spec handle_webhook_event(atom() | String.t(), map()) ::
          {:ok, Provider.webhook_event()} | {:error, term()}
  def handle_webhook_event(provider, payload) do
    case get_provider(provider) do
      nil -> {:error, :provider_not_found}
      module -> module.handle_webhook_event(payload)
    end
  end

  @doc """
  Creates a refund using the appropriate provider.

  ## Parameters

  - `provider` - Provider name
  - `provider_transaction_id` - Provider's transaction ID
  - `amount` - Amount to refund (nil for full refund)
  - `opts` - Options

  ## Returns

  - `{:ok, refund_result}` - Refund created
  - `{:error, reason}` - Refund failed
  """
  @spec create_refund(atom() | String.t(), String.t(), Decimal.t() | nil, keyword()) ::
          {:ok, Provider.refund_result()} | {:error, term()}
  def create_refund(provider, provider_transaction_id, amount, opts \\ []) do
    with {:ok, module} <- get_available_provider(provider) do
      module.create_refund(provider_transaction_id, amount, opts)
    end
  end

  @doc """
  Returns display information for a provider.

  ## Examples

      iex> Providers.provider_info(:stripe)
      %{name: "Stripe", icon: "stripe", color: "#635BFF"}
  """
  @spec provider_info(atom()) :: map()
  def provider_info(:stripe) do
    %{
      name: "Stripe",
      icon: "stripe",
      color: "#635BFF",
      description: "Accept cards, wallets, and more"
    }
  end

  def provider_info(:paypal) do
    %{
      name: "PayPal",
      icon: "paypal",
      color: "#003087",
      description: "PayPal and credit/debit cards"
    }
  end

  def provider_info(:razorpay) do
    %{
      name: "Razorpay",
      icon: "razorpay",
      color: "#072654",
      description: "Popular payment gateway in India"
    }
  end

  def provider_info(_), do: %{name: "Unknown", icon: "credit-card", color: "#6B7280"}

  # Private helpers

  defp get_available_provider(provider) do
    case get_provider(provider) do
      nil ->
        {:error, :provider_not_found}

      module ->
        if Code.ensure_loaded?(module) && function_exported?(module, :available?, 0) &&
             module.available?() do
          {:ok, module}
        else
          {:error, :provider_not_available}
        end
    end
  end
end
