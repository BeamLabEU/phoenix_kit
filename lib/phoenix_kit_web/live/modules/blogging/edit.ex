defmodule PhoenixKitWeb.Live.Modules.Blogging.Edit do
  @moduledoc """
  LiveView for editing blog metadata such as display name and slug.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias Phoenix.Component
  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(%{"blog" => blog_slug} = params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    case find_blog(blog_slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("The requested blog could not be found."))
         |> push_navigate(to: Routes.path("/admin/settings/blogging", locale: locale))}

      blog ->
        form =
          Component.to_form(%{"name" => blog["name"], "slug" => blog["slug"]}, as: :blog)

        {:ok,
         socket
         |> assign(:current_locale, locale)
         |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
         |> assign(:page_title, gettext("Edit Blog"))
         |> assign(
           :current_path,
           Routes.path("/admin/settings/blogging/#{blog_slug}/edit", locale: locale)
         )
         |> assign(:blog, blog)
         |> assign(:form, form)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def handle_event("validate", %{"blog" => params}, socket) do
    {:noreply, assign(socket, :form, Component.to_form(params, as: :blog))}
  end

  def handle_event("save", %{"blog" => params}, socket) do
    case Blogging.update_blog(socket.assigns.blog["slug"], params) do
      {:ok, updated_blog} ->
        updated_form =
          Component.to_form(
            %{"name" => updated_blog["name"], "slug" => updated_blog["slug"]},
            as: :blog
          )

        {:noreply,
         socket
         |> assign(:blog, updated_blog)
         |> assign(:form, updated_form)
         |> put_flash(:info, gettext("Blog updated"))
         |> push_navigate(
           to: Routes.path("/admin/settings/blogging", locale: socket.assigns.current_locale)
         )}

      {:error, :already_exists} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Another blog already uses that slug."))
         |> assign(:form, Component.to_form(params, as: :blog))}

      {:error, :invalid_name} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Please provide a valid blog name."))
         |> assign(:form, Component.to_form(params, as: :blog))}

      {:error, :invalid_slug} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Please provide a valid slug."))
         |> assign(:form, Component.to_form(params, as: :blog))}

      {:error, :destination_exists} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("A directory already exists for that slug."))
         |> assign(:form, Component.to_form(params, as: :blog))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Failed to update blog: %{reason}", reason: inspect(reason))
         )
         |> assign(:form, Component.to_form(params, as: :blog))}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     push_navigate(socket,
       to: Routes.path("/admin/settings/blogging", locale: socket.assigns.current_locale)
     )}
  end

  defp find_blog(slug) do
    Blogging.list_blogs()
    |> Enum.find(&(&1["slug"] == slug))
  end
end
