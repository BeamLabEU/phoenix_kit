defmodule PhoenixKitWeb.Live.Modules.Billing.ProviderSettings do
  @moduledoc """
  Payment provider settings LiveView for the billing module.

  Provides configuration interface for Stripe, PayPal, and Razorpay payment providers.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Billing.Providers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      socket =
        socket
        |> assign(:page_title, "Payment Providers")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/settings/billing/providers"))
        |> load_provider_settings()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin/billing/settings"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_provider_settings(socket) do
    # Generate webhook URLs
    base_url = PhoenixKitWeb.Endpoint.url()

    socket
    # Stripe settings
    |> assign(:stripe_enabled, Settings.get_setting("billing_stripe_enabled", "false") == "true")
    |> assign(:stripe_secret_key, Settings.get_setting("billing_stripe_secret_key", ""))
    |> assign(:stripe_publishable_key, Settings.get_setting("billing_stripe_publishable_key", ""))
    |> assign(:stripe_webhook_secret, Settings.get_setting("billing_stripe_webhook_secret", ""))
    |> assign(:stripe_webhook_url, "#{base_url}#{Routes.path("/webhooks/billing/stripe")}")
    # PayPal settings
    |> assign(:paypal_enabled, Settings.get_setting("billing_paypal_enabled", "false") == "true")
    |> assign(:paypal_client_id, Settings.get_setting("billing_paypal_client_id", ""))
    |> assign(:paypal_client_secret, Settings.get_setting("billing_paypal_client_secret", ""))
    |> assign(:paypal_webhook_id, Settings.get_setting("billing_paypal_webhook_id", ""))
    |> assign(:paypal_mode, Settings.get_setting("billing_paypal_mode", "sandbox"))
    |> assign(:paypal_webhook_url, "#{base_url}#{Routes.path("/webhooks/billing/paypal")}")
    # Razorpay settings
    |> assign(
      :razorpay_enabled,
      Settings.get_setting("billing_razorpay_enabled", "false") == "true"
    )
    |> assign(:razorpay_key_id, Settings.get_setting("billing_razorpay_key_id", ""))
    |> assign(:razorpay_key_secret, Settings.get_setting("billing_razorpay_key_secret", ""))
    |> assign(
      :razorpay_webhook_secret,
      Settings.get_setting("billing_razorpay_webhook_secret", "")
    )
    |> assign(:razorpay_webhook_url, "#{base_url}#{Routes.path("/webhooks/billing/razorpay")}")
    # Provider availability
    |> assign(:available_providers, Providers.list_available_providers())
  end

  @impl true
  def handle_event("toggle_stripe", _params, socket) do
    new_enabled = !socket.assigns.stripe_enabled
    Settings.update_setting("billing_stripe_enabled", to_string(new_enabled))

    {:noreply,
     socket
     |> assign(:stripe_enabled, new_enabled)
     |> assign(:available_providers, Providers.list_available_providers())
     |> put_flash(:info, if(new_enabled, do: "Stripe enabled", else: "Stripe disabled"))}
  end

  @impl true
  def handle_event("save_stripe", params, socket) do
    settings = [
      {"billing_stripe_secret_key", params["secret_key"] || ""},
      {"billing_stripe_publishable_key", params["publishable_key"] || ""},
      {"billing_stripe_webhook_secret", params["webhook_secret"] || ""}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_provider_settings()
     |> put_flash(:info, "Stripe settings saved")}
  end

  @impl true
  def handle_event("toggle_paypal", _params, socket) do
    new_enabled = !socket.assigns.paypal_enabled
    Settings.update_setting("billing_paypal_enabled", to_string(new_enabled))

    {:noreply,
     socket
     |> assign(:paypal_enabled, new_enabled)
     |> assign(:available_providers, Providers.list_available_providers())
     |> put_flash(:info, if(new_enabled, do: "PayPal enabled", else: "PayPal disabled"))}
  end

  @impl true
  def handle_event("save_paypal", params, socket) do
    settings = [
      {"billing_paypal_client_id", params["client_id"] || ""},
      {"billing_paypal_client_secret", params["client_secret"] || ""},
      {"billing_paypal_webhook_id", params["webhook_id"] || ""},
      {"billing_paypal_mode", params["mode"] || "sandbox"}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_provider_settings()
     |> put_flash(:info, "PayPal settings saved")}
  end

  @impl true
  def handle_event("toggle_razorpay", _params, socket) do
    new_enabled = !socket.assigns.razorpay_enabled
    Settings.update_setting("billing_razorpay_enabled", to_string(new_enabled))

    {:noreply,
     socket
     |> assign(:razorpay_enabled, new_enabled)
     |> assign(:available_providers, Providers.list_available_providers())
     |> put_flash(:info, if(new_enabled, do: "Razorpay enabled", else: "Razorpay disabled"))}
  end

  @impl true
  def handle_event("save_razorpay", params, socket) do
    settings = [
      {"billing_razorpay_key_id", params["key_id"] || ""},
      {"billing_razorpay_key_secret", params["key_secret"] || ""},
      {"billing_razorpay_webhook_secret", params["webhook_secret"] || ""}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_provider_settings()
     |> put_flash(:info, "Razorpay settings saved")}
  end

  # Helper to mask sensitive keys
  def mask_key(nil), do: ""
  def mask_key(""), do: ""

  def mask_key(key) when is_binary(key) do
    len = String.length(key)

    if len > 8 do
      String.slice(key, 0, 4) <> String.duplicate("•", len - 8) <> String.slice(key, -4, 4)
    else
      String.duplicate("•", len)
    end
  end

  def has_credentials?(key) when is_binary(key), do: key != ""
  def has_credentials?(_), do: false
end
