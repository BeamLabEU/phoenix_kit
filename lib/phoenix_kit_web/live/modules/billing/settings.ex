defmodule PhoenixKitWeb.Live.Modules.Billing.Settings do
  @moduledoc """
  Billing settings LiveView for the billing module.

  Provides configuration interface for billing module settings.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Settings

  @impl true
  def mount(_params, _session, socket) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    billing_enabled = Billing.enabled?()

    socket =
      socket
      |> assign(:page_title, "Billing Settings")
      |> assign(:project_title, project_title)
      |> assign(:billing_enabled, billing_enabled)
      |> load_settings()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_settings(socket) do
    socket
    |> assign(:default_currency, Settings.get_setting("billing_default_currency", "EUR"))
    |> assign(:invoice_prefix, Settings.get_setting("billing_invoice_prefix", "INV"))
    |> assign(:order_prefix, Settings.get_setting("billing_order_prefix", "ORD"))
    |> assign(:receipt_prefix, Settings.get_setting("billing_receipt_prefix", "RCP"))
    |> assign(:invoice_due_days, Settings.get_setting("billing_invoice_due_days", "14"))
    |> assign(:tax_rate, Settings.get_setting("billing_default_tax_rate", "0"))
    |> assign(:company_name, Settings.get_setting("billing_company_name", ""))
    |> assign(:company_address, Settings.get_setting("billing_company_address", ""))
    |> assign(:company_vat, Settings.get_setting("billing_company_vat", ""))
    |> assign(:bank_name, Settings.get_setting("billing_bank_name", ""))
    |> assign(:bank_iban, Settings.get_setting("billing_bank_iban", ""))
    |> assign(:bank_swift, Settings.get_setting("billing_bank_swift", ""))
  end

  @impl true
  def handle_event("toggle_billing", _params, socket) do
    new_enabled = !socket.assigns.billing_enabled

    result =
      if new_enabled do
        Billing.enable_system()
      else
        Billing.disable_system()
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:billing_enabled, new_enabled)
         |> put_flash(:info, if(new_enabled, do: "Billing enabled", else: "Billing disabled"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update billing status")}
    end
  end

  @impl true
  def handle_event("save_general", params, socket) do
    settings = [
      {"billing_default_currency", params["default_currency"]},
      {"billing_invoice_prefix", params["invoice_prefix"]},
      {"billing_order_prefix", params["order_prefix"]},
      {"billing_receipt_prefix", params["receipt_prefix"]},
      {"billing_invoice_due_days", params["invoice_due_days"]},
      {"billing_default_tax_rate", params["tax_rate"]}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_settings()
     |> put_flash(:info, "General settings saved")}
  end

  @impl true
  def handle_event("save_company", params, socket) do
    settings = [
      {"billing_company_name", params["company_name"]},
      {"billing_company_address", params["company_address"]},
      {"billing_company_vat", params["company_vat"]}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_settings()
     |> put_flash(:info, "Company information saved")}
  end

  @impl true
  def handle_event("save_bank", params, socket) do
    settings = [
      {"billing_bank_name", params["bank_name"]},
      {"billing_bank_iban", params["bank_iban"]},
      {"billing_bank_swift", params["bank_swift"]}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_settings()
     |> put_flash(:info, "Bank details saved")}
  end
end
