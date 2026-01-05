defmodule PhoenixKitWeb.Live.Modules.Billing.Settings do
  @moduledoc """
  Billing settings LiveView for the billing module.

  Provides configuration interface for billing module settings.
  Company and bank information is now managed in Organization Settings.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Billing
  alias PhoenixKit.Billing.CountryData
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    billing_enabled = Billing.enabled?()

    socket =
      socket
      |> assign(:page_title, "Billing Settings")
      |> assign(:project_title, project_title)
      |> assign(:url_path, Routes.path("/admin/billing/settings"))
      |> assign(:billing_enabled, billing_enabled)
      |> load_settings()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_settings(socket) do
    # Get company info from consolidated Settings (with fallback to legacy keys)
    company_info = CountryData.get_company_info()
    bank_details = CountryData.get_bank_details()
    company_country = company_info["country"] || ""

    socket
    # General settings
    |> assign(:default_currency, Settings.get_setting("billing_default_currency", "EUR"))
    |> assign(:invoice_prefix, Settings.get_setting("billing_invoice_prefix", "INV"))
    |> assign(:order_prefix, Settings.get_setting("billing_order_prefix", "ORD"))
    |> assign(:receipt_prefix, Settings.get_setting("billing_receipt_prefix", "RCP"))
    |> assign(:invoice_due_days, Settings.get_setting("billing_invoice_due_days", "14"))
    |> assign(:tax_enabled, Settings.get_setting("billing_tax_enabled", "false") == "true")
    |> assign(:tax_rate, Settings.get_setting("billing_default_tax_rate", "0"))
    # Company info (from consolidated source)
    |> assign(:company_info, company_info)
    |> assign(:company_address_formatted, CountryData.format_company_address())
    |> assign(:company_country_name, get_country_name(company_country))
    |> assign(:company_country, company_country)
    # For suggested tax rate
    |> assign_suggested_tax_rate()
    # Bank details (from consolidated source)
    |> assign(:bank_details, bank_details)
  end

  # Helper to get country name from code
  defp get_country_name(""), do: ""
  defp get_country_name(nil), do: ""

  defp get_country_name(country_code) do
    case BeamLabCountries.get(country_code) do
      nil -> country_code
      country -> country.name
    end
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
    # Convert checkbox value to "true"/"false" string
    tax_enabled = if params["tax_enabled"] == "true", do: "true", else: "false"

    settings = [
      {"billing_default_currency", params["default_currency"]},
      {"billing_invoice_prefix", params["invoice_prefix"]},
      {"billing_order_prefix", params["order_prefix"]},
      {"billing_receipt_prefix", params["receipt_prefix"]},
      {"billing_invoice_due_days", params["invoice_due_days"]},
      {"billing_tax_enabled", tax_enabled},
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
  def handle_event("tax_rate_changed", %{"tax_rate" => tax_rate}, socket) do
    current_rate = parse_tax_rate(tax_rate)
    country_code = socket.assigns.company_country

    suggested_rate =
      if country_code != "" do
        rate = CountryData.get_standard_vat_percent(country_code)
        if rate == current_rate, do: nil, else: rate
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:tax_rate, tax_rate)
     |> assign(:suggested_tax_rate, suggested_rate)}
  end

  @impl true
  def handle_event("apply_suggested_tax", _params, socket) do
    case socket.assigns.suggested_tax_rate do
      nil ->
        {:noreply, socket}

      rate ->
        {:noreply,
         socket
         |> assign(:tax_rate, to_string(rate))
         |> assign(:suggested_tax_rate, nil)}
    end
  end

  # Suggested tax rate helper

  defp assign_suggested_tax_rate(socket) do
    country_code = socket.assigns.company_country
    current_rate = parse_tax_rate(socket.assigns.tax_rate)

    suggested_rate =
      if country_code != "" do
        rate = CountryData.get_standard_vat_percent(country_code)
        # Hide suggestion if it matches current rate
        if rate == current_rate, do: nil, else: rate
      else
        nil
      end

    assign(socket, :suggested_tax_rate, suggested_rate)
  end

  defp parse_tax_rate(rate) when is_binary(rate) do
    case Float.parse(rate) do
      {value, _} -> if value == trunc(value), do: trunc(value), else: value
      :error -> 0
    end
  end

  defp parse_tax_rate(rate) when is_number(rate), do: rate
  defp parse_tax_rate(_), do: 0
end
