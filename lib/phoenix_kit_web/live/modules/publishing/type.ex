defmodule PhoenixKitWeb.Live.Modules.Publishing.Type do
  @moduledoc """
  Lists entries for a publishing type and provides creation actions.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitWeb.Live.Modules.Publishing
  alias PhoenixKitWeb.Live.Modules.Publishing.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(%{"type" => type_slug} = params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    types = Publishing.list_types()
    current_type = Enum.find(types, fn type -> type["slug"] == type_slug end)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Publishing")
      |> assign(:current_path, Routes.path("/admin/publishing/#{type_slug}", locale: locale))
      |> assign(:types, types)
      |> assign(:current_type, current_type)
      |> assign(:type_slug, type_slug)
      |> assign(:enabled_languages, Storage.enabled_language_codes())
      |> assign(:entries, Publishing.list_entries(type_slug, locale))

    {:ok, redirect_if_missing(socket)}
  end

  def handle_params(_params, _uri, socket) do
    socket =
      assign(
        socket,
        :entries,
        Publishing.list_entries(socket.assigns.type_slug, socket.assigns.current_locale)
      )

    {:noreply, redirect_if_missing(socket)}
  end

  def handle_event("create_entry", _params, %{assigns: %{type_slug: type_slug}} = socket) do
    # Navigate to editor with "new" flag instead of creating files immediately
    {:noreply,
     push_navigate(socket,
       to:
         Routes.path(
           "/admin/publishing/#{type_slug}/edit?new=true",
           locale: socket.assigns.current_locale
         )
     )}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     assign(
       socket,
       :entries,
       Publishing.list_entries(socket.assigns.type_slug, socket.assigns.current_locale)
     )}
  end

  def handle_event("add_language", %{"path" => entry_path, "language" => lang_code}, socket) do
    # Navigate to editor with entry path and language - file will be created on save
    {:noreply,
     socket
     |> push_navigate(
       to:
         Routes.path(
           "/admin/publishing/#{socket.assigns.type_slug}/edit?path=#{URI.encode(entry_path)}&switch_to=#{lang_code}",
           locale: socket.assigns.current_locale
         )
     )}
  end

  def handle_event(
        "toggle_status",
        %{"path" => entry_path, "current-status" => current_status},
        socket
      ) do
    # Cycle through statuses: draft -> published -> archived -> draft
    new_status =
      case current_status do
        "draft" -> "published"
        "published" -> "archived"
        "archived" -> "draft"
        _ -> "draft"
      end

    case Publishing.read_entry(socket.assigns.type_slug, entry_path) do
      {:ok, entry} ->
        case Publishing.update_entry(socket.assigns.type_slug, entry, %{"status" => new_status}) do
          {:ok, _updated_entry} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Status updated to %{status}", status: new_status))
             |> assign(
               :entries,
               Publishing.list_entries(socket.assigns.type_slug, socket.assigns.current_locale)
             )}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update status"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Entry not found"))}
    end
  end

  defp redirect_if_missing(%{assigns: %{current_type: nil}} = socket) do
    case socket.assigns.types do
      [%{"slug" => slug} | _] ->
        push_navigate(socket,
          to: Routes.path("/admin/publishing/#{slug}", locale: socket.assigns.current_locale)
        )

      [] ->
        push_navigate(socket,
          to: Routes.path("/admin/settings/publishing", locale: socket.assigns.current_locale)
        )
    end
  end

  defp redirect_if_missing(socket), do: socket
end
