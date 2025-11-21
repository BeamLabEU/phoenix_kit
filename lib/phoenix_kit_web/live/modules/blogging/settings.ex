defmodule PhoenixKitWeb.Live.Modules.Blogging.Settings do
  @moduledoc """
  Admin configuration for site blogs.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Modules.Blogging

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)
    blogs = Blogging.list_blogs()
    languages_enabled = Languages.enabled?()

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("Manage Blogging"))
      |> assign(:current_path, Routes.path("/admin/settings/blogging", locale: locale))
      |> assign(:module_enabled, Blogging.enabled?())
      |> assign(:blogs, blogs)
      |> assign(:languages_enabled, languages_enabled)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("remove_blog", %{"slug" => slug}, socket) do
    case Blogging.trash_blog(slug) do
      {:ok, trashed_name} ->
        {:noreply,
         socket
         |> assign(:blogs, Blogging.list_blogs())
         |> put_flash(
           :info,
           gettext("Blog moved to trash as: %{name}", name: trashed_name)
         )}

      {:error, :not_found} ->
        # Blog directory doesn't exist, just remove from config
        case Blogging.remove_blog(slug) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:blogs, Blogging.list_blogs())
             |> put_flash(:info, gettext("Blog removed from configuration"))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to remove blog"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to move blog to trash"))}
    end
  end
end
