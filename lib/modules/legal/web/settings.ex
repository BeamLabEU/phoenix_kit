defmodule PhoenixKitWeb.Live.Modules.Legal.Settings do
  @moduledoc """
  LiveView for Legal module settings and page generation.

  Route: {prefix}/admin/settings/legal

  Sections:
  1. Module enable/disable (with Publishing dependency check)
  2. Compliance framework selection
  3. Company information form
  4. DPO contact form
  5. Page generation controls
  6. Generated pages list
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Legal
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    config = Legal.get_config()
    widget_config = Legal.get_consent_widget_config()

    # Get data for preview and import functionality
    company_info = config.company_info
    site_url = Settings.get_setting("site_url", "")
    from_email = Settings.get_setting("from_email", "")
    company_country_name = get_country_name(company_info["country"])
    company_address_formatted = format_company_address_oneline(company_info)

    socket =
      socket
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("Legal Settings"))
      |> assign(
        :current_path,
        Routes.path("/admin/settings/legal", locale: socket.assigns[:current_locale_base])
      )
      |> assign(:publishing_enabled, config.publishing_enabled)
      |> assign(:legal_enabled, config.enabled)
      |> assign(:available_frameworks, Legal.available_frameworks())
      |> assign(:available_page_types, Legal.available_page_types())
      |> assign(:selected_frameworks, config.frameworks)
      |> assign(:company_info, company_info)
      |> assign(:company_country_name, company_country_name)
      |> assign(:site_url, site_url)
      |> assign(:from_email, from_email)
      |> assign(:company_address_formatted, company_address_formatted)
      |> assign(:dpo_contact, config.dpo_contact)
      |> assign(:generated_pages, config.generated_pages)
      |> assign(:generating, false)
      # Consent widget assigns (Phase 2)
      |> assign(:consent_widget_enabled, widget_config.enabled)
      |> assign(:consent_mode, widget_config.consent_mode)
      |> assign(:hide_for_authenticated, widget_config.hide_for_authenticated)
      |> assign(:icon_position, widget_config.icon_position)
      |> assign(:policy_version, widget_config.policy_version)
      |> assign(:google_consent_mode, widget_config.google_consent_mode)
      |> assign(:show_consent_icon, widget_config.show_icon)
      |> assign(:unpublished_pages, Legal.get_unpublished_required_pages())

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

        {:error, :publishing_required} ->
          {:noreply, put_flash(socket, :error, gettext("Please enable Publishing module first"))}

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
  def handle_event("import_dpo_email", _params, socket) do
    from_email = socket.assigns.from_email
    dpo_contact = Map.put(socket.assigns.dpo_contact, "email", from_email)

    case Legal.update_dpo_contact(dpo_contact) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:dpo_contact, dpo_contact)
         |> put_flash(:info, gettext("Email imported from General Settings"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to import email"))}
    end
  end

  @impl true
  def handle_event("import_dpo_address", _params, socket) do
    company_address = socket.assigns.company_address_formatted
    dpo_contact = Map.put(socket.assigns.dpo_contact, "address", company_address)

    case Legal.update_dpo_contact(dpo_contact) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:dpo_contact, dpo_contact)
         |> put_flash(:info, gettext("Address imported from Organization"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to import address"))}
    end
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
         |> assign(:unpublished_pages, Legal.get_unpublished_required_pages())
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
  def handle_event("publish_page", %{"page_slug" => page_slug}, socket) do
    case Legal.publish_page(page_slug, scope: socket.assigns[:current_scope]) do
      {:ok, _post} ->
        {:noreply,
         socket
         |> assign(:generated_pages, Legal.list_generated_pages())
         |> assign(:unpublished_pages, Legal.get_unpublished_required_pages())
         |> put_flash(:info, gettext("Page published successfully"))}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to publish page: %{reason}", reason: inspect(reason))
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
     |> assign(:unpublished_pages, Legal.get_unpublished_required_pages())
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
    consent_mode = params["consent_mode"] || "strict"
    hide_for_auth = params["hide_for_authenticated"] == "true"

    with {:ok, _} <- Legal.update_consent_mode(consent_mode),
         {:ok, _} <- Legal.update_hide_for_authenticated(hide_for_auth),
         {:ok, _} <- Legal.update_icon_position(params["icon_position"] || "bottom-right"),
         {:ok, _} <- update_google_consent_mode(params["google_consent_mode"]) do
      # Recalculate show_icon based on new settings
      show_icon = Legal.should_show_consent_icon?()

      {:noreply,
       socket
       |> assign(:consent_mode, consent_mode)
       |> assign(:hide_for_authenticated, hide_for_auth)
       |> assign(:icon_position, params["icon_position"] || "bottom-right")
       |> assign(:google_consent_mode, params["google_consent_mode"] == "true")
       |> assign(:show_consent_icon, show_icon)
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
        Routes.path("/admin/publishing/legal")

      page ->
        Routes.path("/admin/publishing/legal/edit?path=#{URI.encode(page.path)}")
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

  # Helper to get country name from code
  defp get_country_name(nil), do: ""
  defp get_country_name(""), do: ""

  defp get_country_name(country_code) do
    case BeamLabCountries.get(country_code) do
      nil -> country_code
      country -> country.name
    end
  end

  # Helper to format company address as one line (for DPO import)
  defp format_company_address_oneline(company) do
    parts =
      [
        company["address_line1"],
        company["address_line2"],
        company["city"],
        company["state"],
        company["postal_code"],
        get_country_name(company["country"])
      ]
      |> Enum.reject(&(&1 == "" or is_nil(&1)))

    Enum.join(parts, ", ")
  end
end
