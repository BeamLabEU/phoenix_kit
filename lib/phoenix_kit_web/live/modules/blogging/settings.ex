defmodule PhoenixKitWeb.Live.Modules.Blogging.Settings do
  @moduledoc """
  Admin configuration for site blogs.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)
    blogs = Blogging.list_blogs()

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, gettext("Manage Blogs"))
      |> assign(:current_path, Routes.path("/admin/settings/blogging", locale: locale))
      |> assign(:module_enabled, Blogging.enabled?())
      |> assign(:blogs, blogs)
      |> assign(:new_blog_form, new_blog_form(%{}))

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("update_new_blog", %{"blog" => params}, socket) do
    {:noreply, assign(socket, :new_blog_form, new_blog_form(params))}
  end

  def handle_event("add_blog", %{"blog" => params}, socket) do
    name = Map.get(params, "name", "")
    mode = Map.get(params, "mode", "timestamp")

    case Blogging.add_blog(name, mode) do
      {:ok, _blog} ->
        {:noreply,
         socket
         |> assign(:blogs, Blogging.list_blogs())
         |> assign(:new_blog_form, new_blog_form(%{}))
         |> put_flash(:info, gettext("Blog added"))}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("That blog already exists"))}

      {:error, :invalid_name} ->
        {:noreply, put_flash(socket, :error, gettext("Please enter a valid blog name"))}

      {:error, :invalid_mode} ->
        {:noreply, put_flash(socket, :error, gettext("Invalid storage mode"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to add blog"))}
    end
  end

  def handle_event("remove_blog", %{"slug" => slug}, socket) do
    case Blogging.remove_blog(slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:blogs, Blogging.list_blogs())
         |> put_flash(:info, gettext("Blog removed"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove blog"))}
    end
  end

  defp new_blog_form(params) when is_map(params) do
    defaults = %{"name" => "", "mode" => "timestamp"}
    values = Map.merge(defaults, params)
    to_form(values, as: :blog)
  end
end
