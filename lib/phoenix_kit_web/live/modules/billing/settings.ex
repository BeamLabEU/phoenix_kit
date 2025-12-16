defmodule PhoenixKitWeb.Live.Modules.Billing.Settings do
  @moduledoc """
  Billing settings LiveView for the billing module.

  Provides configuration interface for billing module settings.
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
    socket
    # General settings
    |> assign(:default_currency, Settings.get_setting("billing_default_currency", "EUR"))
    |> assign(:invoice_prefix, Settings.get_setting("billing_invoice_prefix", "INV"))
    |> assign(:order_prefix, Settings.get_setting("billing_order_prefix", "ORD"))
    |> assign(:receipt_prefix, Settings.get_setting("billing_receipt_prefix", "RCP"))
    |> assign(:invoice_due_days, Settings.get_setting("billing_invoice_due_days", "14"))
    |> assign(:tax_enabled, Settings.get_setting("billing_tax_enabled", "false") == "true")
    |> assign(:tax_rate, Settings.get_setting("billing_default_tax_rate", "0"))
    # Company information with address breakdown
    |> assign(:company_name, Settings.get_setting("billing_company_name", ""))
    |> assign(:company_vat, Settings.get_setting("billing_company_vat", ""))
    |> assign(:company_address_line1, Settings.get_setting("billing_company_address_line1", ""))
    |> assign(:company_address_line2, Settings.get_setting("billing_company_address_line2", ""))
    |> assign(:company_city, Settings.get_setting("billing_company_city", ""))
    |> assign(:company_state, Settings.get_setting("billing_company_state", ""))
    |> assign(:company_postal_code, Settings.get_setting("billing_company_postal_code", ""))
    |> assign(:company_country, Settings.get_setting("billing_company_country", ""))
    # Country dropdown data
    |> assign(:countries, CountryData.countries_for_select())
    |> assign_suggested_tax_rate()
    # Bank details
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
  def handle_event("country_changed", %{"company_country" => country_code}, socket) do
    suggested_rate =
      if country_code != "" do
        CountryData.get_standard_vat_percent(country_code)
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:company_country, country_code)
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

  @impl true
  def handle_event("save_company", params, socket) do
    data = extract_company_data(params)

    case validate_company_data(data) do
      [] ->
        save_company_settings(data, params)

        {:noreply,
         socket
         |> load_settings()
         |> put_flash(:info, "Company information saved")}

      errors ->
        {:noreply, put_flash(socket, :error, Enum.join(errors, ". "))}
    end
  end

  @impl true
  def handle_event("save_bank", params, socket) do
    iban = (params["bank_iban"] || "") |> String.trim()
    swift = (params["bank_swift"] || "") |> String.trim()
    country_code = socket.assigns.company_country

    errors =
      []
      |> validate_bank_iban(iban, country_code)
      |> validate_bank_swift(swift)

    case errors do
      [] ->
        settings = [
          {"billing_bank_name", params["bank_name"]},
          {"billing_bank_iban", normalize_iban(iban)},
          {"billing_bank_swift", String.upcase(swift)}
        ]

        Enum.each(settings, fn {key, value} ->
          Settings.update_setting(key, value)
        end)

        {:noreply,
         socket
         |> load_settings()
         |> put_flash(:info, "Bank details saved")}

      errors ->
        {:noreply, put_flash(socket, :error, Enum.join(Enum.reverse(errors), ". "))}
    end
  end

  # Company data validation helpers

  defp extract_company_data(params) do
    %{
      name: (params["company_name"] || "") |> String.trim(),
      country: params["company_country"] || "",
      vat: (params["company_vat"] || "") |> String.trim(),
      address_line1: (params["company_address_line1"] || "") |> String.trim(),
      city: (params["company_city"] || "") |> String.trim()
    }
  end

  defp validate_company_data(data) do
    []
    |> validate_required(data.name, "Company name is required")
    |> validate_required(data.country, "Country is required")
    |> validate_required(data.vat, "VAT number is required")
    |> validate_required(data.address_line1, "Street address is required")
    |> validate_required(data.city, "City is required")
    |> validate_eu_vat(data.vat, data.country)
    |> Enum.reverse()
  end

  defp validate_required(errors, "", message), do: [message | errors]
  defp validate_required(errors, _value, _message), do: errors

  defp validate_eu_vat(errors, vat, country) when vat != "" and country != "" do
    if CountryData.eu_member?(country) do
      if Regex.match?(~r/^[A-Z]{2}[0-9A-Z]{2,12}$/, String.upcase(vat)) do
        errors
      else
        ["VAT number must be in EU format (e.g., #{country}123456789)" | errors]
      end
    else
      errors
    end
  end

  defp validate_eu_vat(errors, _vat, _country), do: errors

  defp save_company_settings(data, params) do
    settings = [
      {"billing_company_name", data.name},
      {"billing_company_vat", String.upcase(data.vat)},
      {"billing_company_address_line1", data.address_line1},
      {"billing_company_address_line2", params["company_address_line2"] || ""},
      {"billing_company_city", data.city},
      {"billing_company_state", params["company_state"] || ""},
      {"billing_company_postal_code", params["company_postal_code"] || ""},
      {"billing_company_country", data.country}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)
  end

  # Suggested tax rate helper

  defp assign_suggested_tax_rate(socket) do
    country_code = socket.assigns.company_country

    suggested_rate =
      if country_code != "" do
        CountryData.get_standard_vat_percent(country_code)
      else
        nil
      end

    assign(socket, :suggested_tax_rate, suggested_rate)
  end

  # Bank validation helpers

  defp validate_bank_iban(errors, iban, country_code) do
    case CountryData.validate_iban_format(iban, country_code) do
      :ok -> errors
      {:error, msg} -> [msg | errors]
    end
  end

  defp validate_bank_swift(errors, swift) do
    case CountryData.validate_swift_format(swift) do
      :ok -> errors
      {:error, msg} -> [msg | errors]
    end
  end

  defp normalize_iban(iban) do
    iban |> String.replace(~r/\s/, "") |> String.upcase()
  end
end
