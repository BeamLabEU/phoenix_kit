defmodule PhoenixKit.Modules.Billing.Web.Currencies do
  @moduledoc """
  Currencies management LiveView for the billing module.

  Provides currency configuration interface with CRUD operations
  and bulk import from the BeamLabCountries library.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Billing
  alias PhoenixKit.Modules.Billing.Currency
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, "Currencies")
        |> assign(:project_title, project_title)
        |> assign(:url_path, Routes.path("/admin/billing/currencies"))
        |> assign(:currencies, [])
        |> assign(:loading, true)
        |> assign(:show_form, false)
        |> assign(:editing_currency, nil)
        |> assign(:form, nil)
        |> assign(:show_import, false)
        |> assign(:available_currencies, [])
        |> assign(:selected_imports, MapSet.new())

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, load_currencies(socket)}
  end

  defp load_currencies(socket) do
    currencies = Billing.list_currencies(order_by: [asc: :sort_order, asc: :code])

    socket
    |> assign(:currencies, currencies)
    |> assign(:loading, false)
  end

  # --- Toggle / Default / Refresh ---

  @impl true
  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.id == String.to_integer(id)))

    case Billing.update_currency(currency, %{enabled: !currency.enabled}) do
      {:ok, _currency} ->
        {:noreply,
         socket
         |> load_currencies()
         |> put_flash(:info, "Currency updated")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update currency")}
    end
  end

  @impl true
  def handle_event("set_default", %{"id" => id}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.id == String.to_integer(id)))

    case Billing.set_default_currency(currency) do
      {:ok, _currency} ->
        {:noreply,
         socket
         |> load_currencies()
         |> put_flash(:info, "#{currency.code} set as default currency")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to set default currency")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(:loading, true) |> load_currencies()}
  end

  # --- Currency Form (Add / Edit) ---

  @impl true
  def handle_event("show_add_form", _params, socket) do
    changeset = Currency.changeset(%Currency{}, %{})

    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_currency, nil)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("show_edit_form", %{"id" => id}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.id == String.to_integer(id)))
    changeset = Currency.changeset(currency, %{})

    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_currency, currency)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("close_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_currency, nil)
     |> assign(:form, nil)}
  end

  @impl true
  def handle_event("validate", %{"currency" => params}, socket) do
    changeset =
      (socket.assigns.editing_currency || %Currency{})
      |> Currency.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"currency" => params}, socket) do
    result =
      case socket.assigns.editing_currency do
        nil -> Billing.create_currency(params)
        currency -> Billing.update_currency(currency, params)
      end

    case result do
      {:ok, _currency} ->
        action = if socket.assigns.editing_currency, do: "updated", else: "created"

        {:noreply,
         socket
         |> load_currencies()
         |> assign(:show_form, false)
         |> assign(:editing_currency, nil)
         |> assign(:form, nil)
         |> put_flash(:info, "Currency #{action} successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  # --- Delete ---

  @impl true
  def handle_event("delete_currency", %{"id" => id}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.id == String.to_integer(id)))

    case Billing.delete_currency(currency) do
      {:ok, _currency} ->
        {:noreply,
         socket
         |> load_currencies()
         |> put_flash(:info, "#{currency.code} deleted")}

      {:error, :is_default} ->
        {:noreply, put_flash(socket, :error, "Cannot delete the default currency")}

      {:error, :currency_in_use} ->
        {:noreply,
         put_flash(socket, :error, "Cannot delete currency — it is used by existing orders")}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Failed to delete currency")}
    end
  end

  # --- Import from BeamLabCountries ---

  @impl true
  def handle_event("show_import", _params, socket) do
    existing_codes =
      socket.assigns.currencies
      |> Enum.map(& &1.code)
      |> MapSet.new()

    # Get company country's currencies to prioritize them (primary + alternative)
    company_country_code = Settings.get_setting("billing_company_country", "")
    priority_currency_codes = get_country_currency_codes(company_country_code)

    available =
      BeamLabCountries.Currencies.all()
      |> Enum.reject(&MapSet.member?(existing_codes, &1.code))
      |> sort_currencies_with_priority(priority_currency_codes)

    {:noreply,
     socket
     |> assign(:show_import, true)
     |> assign(:available_currencies, available)
     |> assign(:selected_imports, MapSet.new())}
  end

  @impl true
  def handle_event("close_import", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import, false)
     |> assign(:available_currencies, [])
     |> assign(:selected_imports, MapSet.new())}
  end

  @impl true
  def handle_event("toggle_import_selection", %{"code" => code}, socket) do
    selected = socket.assigns.selected_imports

    updated =
      if MapSet.member?(selected, code),
        do: MapSet.delete(selected, code),
        else: MapSet.put(selected, code)

    {:noreply, assign(socket, :selected_imports, updated)}
  end

  @impl true
  def handle_event("select_all_imports", _params, socket) do
    all_codes = MapSet.new(socket.assigns.available_currencies, & &1.code)
    {:noreply, assign(socket, :selected_imports, all_codes)}
  end

  @impl true
  def handle_event("deselect_all_imports", _params, socket) do
    {:noreply, assign(socket, :selected_imports, MapSet.new())}
  end

  @impl true
  def handle_event("import_selected", _params, socket) do
    selected = socket.assigns.selected_imports

    to_import =
      Enum.filter(socket.assigns.available_currencies, &MapSet.member?(selected, &1.code))

    {ok_count, fail_count} =
      Enum.reduce(to_import, {0, 0}, fn cur, {ok, fail} ->
        attrs = %{
          code: cur.code,
          name: cur.name,
          symbol: cur.symbol_native,
          decimal_places: cur.decimal_digits,
          exchange_rate: "1.0",
          enabled: false
        }

        case Billing.create_currency(attrs) do
          {:ok, _} -> {ok + 1, fail}
          {:error, _} -> {ok, fail + 1}
        end
      end)

    message =
      case {ok_count, fail_count} do
        {ok, 0} -> "#{ok} currencies imported"
        {0, fail} -> "Import failed for #{fail} currencies"
        {ok, fail} -> "#{ok} imported, #{fail} failed"
      end

    {:noreply,
     socket
     |> load_currencies()
     |> assign(:show_import, false)
     |> assign(:available_currencies, [])
     |> assign(:selected_imports, MapSet.new())
     |> put_flash(:info, message)}
  end

  # --- Helpers ---

  def error_to_string([]), do: ""

  def error_to_string(errors) when is_list(errors) do
    Enum.map_join(errors, ", ", fn
      {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)

      msg when is_binary(msg) ->
        msg
    end)
  end

  # Gets currency codes for a country from BeamLabCountries (primary + alternative)
  defp get_country_currency_codes(country_code)
       when is_binary(country_code) and country_code != "" do
    case BeamLabCountries.get(country_code) do
      %{currency_code: primary, alt_currency: alt} ->
        [primary, alt]
        |> Enum.reject(&(is_nil(&1) or &1 == ""))

      _ ->
        []
    end
  end

  defp get_country_currency_codes(_), do: []

  # Sorts currencies with priority currencies first, then alphabetically
  defp sort_currencies_with_priority(currencies, []) do
    Enum.sort_by(currencies, & &1.code)
  end

  defp sort_currencies_with_priority(currencies, priority_codes) when is_list(priority_codes) do
    priority_set = MapSet.new(priority_codes)
    {priority, rest} = Enum.split_with(currencies, &MapSet.member?(priority_set, &1.code))

    # Sort priority currencies in the order they appear in priority_codes
    sorted_priority =
      Enum.sort_by(priority, fn cur ->
        Enum.find_index(priority_codes, &(&1 == cur.code)) || 999
      end)

    sorted_priority ++ Enum.sort_by(rest, & &1.code)
  end
end
