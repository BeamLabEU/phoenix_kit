defmodule PhoenixKit.Modules.Publishing.Web.Edit do
  @moduledoc """
  LiveView for editing blog metadata such as display name and slug.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias Phoenix.Component
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(%{"blog" => blog_slug} = _params, _session, socket) do
    case find_blog(blog_slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("The requested blog could not be found."))
         |> push_navigate(to: Routes.path("/admin/settings/publishing"))}

      blog ->
        form =
          Component.to_form(%{"name" => blog["name"], "slug" => blog["slug"]}, as: :blog)

        {:ok,
         socket
         |> assign(:project_title, Settings.get_project_title())
         |> assign(:page_title, gettext("Edit Blog"))
         |> assign(
           :current_path,
           Routes.path("/admin/settings/publishing/#{blog_slug}/edit")
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
    case Publishing.update_group(socket.assigns.blog["slug"], params) do
      {:ok, updated_group} ->
        # Broadcast group updated for live dashboard updates
        PublishingPubSub.broadcast_group_updated(updated_group)

        updated_form =
          Component.to_form(
            %{"name" => updated_group["name"], "slug" => updated_group["slug"]},
            as: :blog
          )

        {:noreply,
         socket
         |> assign(:blog, updated_group)
         |> assign(:form, updated_form)
         |> put_flash(:info, gettext("Group updated"))
         |> push_navigate(to: Routes.path("/admin/settings/publishing"))}

      {:error, :already_exists} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Another group already uses that slug."))
         |> assign(:form, Component.to_form(params, as: :blog))}

      {:error, :invalid_name} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Please provide a valid group name."))
         |> assign(:form, Component.to_form(params, as: :blog))}

      {:error, :invalid_slug} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-group-name)"
           )
         )
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
           gettext("Failed to update group: %{reason}", reason: inspect(reason))
         )
         |> assign(:form, Component.to_form(params, as: :blog))}
    end
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/settings/publishing"))}
  end

  defp find_blog(slug) do
    Publishing.list_groups()
    |> Enum.find(&(&1["slug"] == slug))
  end
end
