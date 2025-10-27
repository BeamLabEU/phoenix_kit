defmodule PhoenixKitWeb.Live.Modules.Pages.Settings do
  @moduledoc """
  LiveView for configuring public-facing Pages module settings, including the
  custom 404 fallback experience.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Pages
  alias PhoenixKit.Pages.FileOperations
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    current_path = Routes.path("/admin/settings/pages", locale: locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:current_path, current_path)
      |> assign(:url_path, current_path)
      |> assign(:page_title, "Pages Settings")
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:pages_enabled, Pages.enabled?())
      |> refresh_pages_assigns()

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("toggle_pages_handle_404", _params, socket) do
    if socket.assigns.pages_enabled do
      new_state = !socket.assigns.pages_handle_not_found
      Pages.update_handle_not_found(new_state)

      if new_state do
        Pages.ensure_not_found_page_exists()
      end

      message =
        if new_state do
          gettext("Pages module will now serve custom 404 pages")
        else
          gettext("Pages module will defer 404 responses to the parent app")
        end

      socket =
        socket
        |> refresh_pages_assigns()
        |> put_flash(:info, message)

      {:noreply, socket}
    else
      {:noreply,
       put_flash(socket, :error, gettext("Enable the Pages module before configuring 404 handling"))}
    end
  end

  def handle_event("pages_create_default_404", _params, socket) do
    Pages.ensure_not_found_page_exists()

    socket =
      socket
      |> refresh_pages_assigns()
      |> put_flash(:info, gettext("Default 404 page created"))

    {:noreply, socket}
  end

  def handle_event("save_pages_not_found", %{"pages_settings" => params}, socket) do
    slug = Map.get(params, "not_found_slug", "/404")
    normalized = Pages.update_not_found_slug(slug)
    Pages.ensure_not_found_page_exists()

    socket =
      socket
      |> refresh_pages_assigns()
      |> put_flash(:info, gettext("Updated 404 page to %{slug}.md", slug: normalized))

    {:noreply, socket}
  end

  defp refresh_pages_assigns(socket) do
    slug = Pages.not_found_slug()
    file_path = Pages.not_found_file_path()
    file_exists? = FileOperations.file_exists?(file_path)

    form =
      %{"not_found_slug" => slug}
      |> to_form(as: :pages_settings)

    assign(socket,
      pages_handle_not_found: Pages.handle_not_found?(),
      pages_not_found_slug: slug,
      pages_not_found_file_path: file_path,
      pages_not_found_file_exists: file_exists?,
      pages_form: form
    )
  end
end
