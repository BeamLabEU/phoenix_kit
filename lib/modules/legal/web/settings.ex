defmodule PhoenixKitWeb.Live.Modules.Legal.Settings do
  @moduledoc """
  LiveView for Legal module settings and page generation.

  Route: {prefix}/admin/settings/legal

  Sections:
  1. Module enable/disable (with Blogging dependency check)
  2. Compliance framework selection
  3. Company information form
  4. DPO contact form
  5. Page generation controls
  6. Generated pages list
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Billing.CountryData
  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    config = Legal.get_config()
    widget_config = Legal.get_consent_widget_config()

    socket =
      socket
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("Legal Settings"))
      |> assign(
        :current_path,
        Routes.path("/admin/settings/legal", locale: socket.assigns[:current_locale_base])
      )
      |> assign(:blogging_enabled, config.blogging_enabled)
      |> assign(:legal_enabled, config.enabled)
      |> assign(:available_frameworks, Legal.available_frameworks())
      |> assign(:available_page_types, Legal.available_page_types())
      |> assign(:selected_frameworks, config.frameworks)
      |> assign(:company_info, config.company_info)
      |> assign(:countries, CountryData.countries_for_select())
      |> assign(
        :subdivision_label,
        CountryData.get_subdivision_label(config.company_info["country"])
      )
      |> assign(:dpo_contact, config.dpo_contact)
      |> assign(:generated_pages, config.generated_pages)
      |> assign(:generating, false)
      # Consent widget assigns (Phase 2)
      |> assign(:consent_widget_enabled, widget_config.enabled)
      |> assign(:icon_position, widget_config.icon_position)
      |> assign(:policy_version, widget_config.policy_version)
      |> assign(:google_consent_mode, widget_config.google_consent_mode)
      |> assign(:show_consent_icon, widget_config.show_icon)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_legal", _params, socket) do
    if socket.assigns.legal_enabled do
      case Legal.disable_system() do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:legal_enabled, false)
           |> put_flash(:info, gettext("Legal module disabled"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to disable Legal module"))}
      end
    else
      case Legal.enable_system() do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:legal_enabled, true)
           |> put_flash(:info, gettext("Legal module enabled"))}

        {:error, :blogging_required} ->
          {:noreply, put_flash(socket, :error, gettext("Please enable Blogging module first"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to enable Legal module"))}
      end
    end
  end

  @impl true
  def handle_event("toggle_framework", %{"id" => framework_id}, socket) do
    current = socket.assigns.selected_frameworks

    updated =
      if framework_id in current do
        List.delete(current, framework_id)
      else
        [framework_id | current]
      end

    case Legal.set_frameworks(updated) do
      {:ok, _} ->
        {:noreply, assign(socket, :selected_frameworks, updated)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save frameworks"))}
    end
  end

  @impl true
  def handle_event("save_company_info", params, socket) do
    company_info = build_company_info(params)

    case Legal.update_company_info(company_info) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:company_info, company_info)
         |> assign(:subdivision_label, CountryData.get_subdivision_label(company_info["country"]))
         |> put_flash(:info, gettext("Company information saved"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save company information"))}
    end
  end

  @impl true
  def handle_event("update_country", %{"company_country" => country_code}, socket) do
    {:noreply,
     assign(socket, :subdivision_label, CountryData.get_subdivision_label(country_code))}
  end

  @impl true
  def handle_event("save_dpo_contact", params, socket) do
    dpo_contact = %{
      "name" => params["dpo_name"] || "",
      "email" => params["dpo_email"] || "",
      "phone" => params["dpo_phone"] || "",
      "address" => params["dpo_address"] || ""
    }

    case Legal.update_dpo_contact(dpo_contact) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:dpo_contact, dpo_contact)
         |> put_flash(:info, gettext("DPO contact saved"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save DPO contact"))}
    end
  end

  @impl true
  def handle_event("generate_page", %{"page_type" => page_type}, socket) do
    socket = assign(socket, :generating, true)

    case Legal.generate_page(page_type, scope: socket.assigns[:current_scope]) do
      {:ok, _post} ->
        {:noreply,
         socket
         |> assign(:generating, false)
         |> assign(:generated_pages, Legal.list_generated_pages())
         |> put_flash(:info, gettext("Page generated successfully"))}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:generating, false)
         |> put_flash(
           :error,
           gettext("Failed to generate page: %{reason}", reason: inspect(reason))
         )}
    end
  end

  @impl true
  def handle_event("generate_all_pages", _params, socket) do
    socket = assign(socket, :generating, true)

    {:ok, results} = Legal.generate_all_pages(scope: socket.assigns[:current_scope])

    success_count =
      results
      |> Enum.count(fn {_, result} -> match?({:ok, _}, result) end)

    {:noreply,
     socket
     |> assign(:generating, false)
     |> assign(:generated_pages, Legal.list_generated_pages())
     |> put_flash(:info, gettext("Generated %{count} pages", count: success_count))}
  end

  # ===================================
  # CONSENT WIDGET EVENTS (Phase 2)
  # ===================================

  @impl true
  def handle_event("toggle_consent_widget", _params, socket) do
    if socket.assigns.consent_widget_enabled do
      case Legal.disable_consent_widget() do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:consent_widget_enabled, false)
           |> assign(:show_consent_icon, false)
           |> put_flash(:info, gettext("Cookie consent widget disabled"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update setting"))}
      end
    else
      case Legal.enable_consent_widget() do
        {:ok, _} ->
          show_icon = Legal.has_opt_in_framework?()

          {:noreply,
           socket
           |> assign(:consent_widget_enabled, true)
           |> assign(:show_consent_icon, show_icon)
           |> put_flash(:info, gettext("Cookie consent widget enabled"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update setting"))}
      end
    end
  end

  @impl true
  def handle_event("save_consent_settings", params, socket) do
    with {:ok, _} <- Legal.update_icon_position(params["icon_position"] || "bottom-right"),
         {:ok, _} <- Legal.update_policy_version(params["policy_version"] || "1.0"),
         {:ok, _} <- update_google_consent_mode(params["google_consent_mode"]) do
      {:noreply,
       socket
       |> assign(:icon_position, params["icon_position"] || "bottom-right")
       |> assign(:policy_version, params["policy_version"] || "1.0")
       |> assign(:google_consent_mode, params["google_consent_mode"] == "true")
       |> put_flash(:info, gettext("Consent widget settings saved"))}
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save settings"))}
    end
  end

  defp update_google_consent_mode("true"), do: Legal.enable_google_consent_mode()
  defp update_google_consent_mode(_), do: Legal.disable_google_consent_mode()

  # Helper to get edit URL for a legal page
  defp get_edit_url(page_slug, generated_pages) do
    case Enum.find(generated_pages, fn p -> p.slug == page_slug end) do
      nil ->
        Routes.path("/admin/blogging/legal")

      page ->
        Routes.path("/admin/blogging/legal/edit?path=#{URI.encode(page.path)}")
    end
  end

  # Helper to check if a page is generated
  defp page_generated?(page_slug, generated_pages) do
    Enum.any?(generated_pages, fn p -> p.slug == page_slug end)
  end

  # Helper to get page status
  defp get_page_status(page_slug, generated_pages) do
    case Enum.find(generated_pages, fn p -> p.slug == page_slug end) do
      nil -> nil
      page -> page.status
    end
  end

  # Helper to build company info map from params
  defp build_company_info(params) do
    %{
      "name" => params["company_name"] || "",
      "address_line1" => params["company_address_line1"] || "",
      "address_line2" => params["company_address_line2"] || "",
      "city" => params["company_city"] || "",
      "state" => params["company_state"] || "",
      "postal_code" => params["company_postal_code"] || "",
      "country" => params["company_country"] || "",
      "website_url" => params["company_website"] || "",
      "registration_number" => params["registration_number"] || "",
      "vat_number" => params["vat_number"] || ""
    }
  end
end
