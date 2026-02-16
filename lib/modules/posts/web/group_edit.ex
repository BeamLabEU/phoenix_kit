defmodule PhoenixKitWeb.Live.Modules.Posts.GroupEdit do
  @moduledoc """
  LiveView for creating and editing post groups (collections).

  Groups are user-specific collections for organizing posts. Each user can
  create groups with unique slugs within their own collection (Pinterest-style).

  ## Features

  - **Group Creation**: Create new groups with name, description, slug
  - **Group Editing**: Update existing group details
  - **Slug Management**: Auto-generate or manually set URL-friendly slugs
  - **Visibility Control**: Public or private group settings
  - **Validation**: Ensure slug uniqueness within user's groups

  ## Route

  - New group: `{prefix}/admin/posts/groups/new`
  - Edit group: `{prefix}/admin/posts/groups/:id/edit`

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).
  """

  use PhoenixKitWeb, :live_view

  alias Phoenix.Component
  alias PhoenixKit.Modules.Posts
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    current_user = socket.assigns[:phoenix_kit_current_user]
    project_title = Settings.get_project_title()
    allow_groups = Settings.get_setting("posts_allow_groups", "true") == "true"

    if allow_groups do
      group_id = Map.get(params, "id")
      socket = load_group_form(socket, group_id, current_user, project_title)
      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Groups feature is not enabled")
       |> push_navigate(to: Routes.path("/admin/posts"))}
    end
  end

  defp load_group_form(socket, nil, current_user, project_title) do
    form_data = %{
      "name" => "",
      "description" => "",
      "slug" => "",
      "visibility" => "public"
    }

    form = Component.to_form(form_data, as: :post_group)

    socket
    |> assign(:page_title, "New Group")
    |> assign(:project_title, project_title)
    |> assign(:group, %{uuid: nil, user_id: current_user.id})
    |> assign(:form, form)
    |> assign(:current_user, current_user)
  end

  defp load_group_form(socket, group_id, current_user, project_title) do
    case Posts.get_group(group_id) do
      nil ->
        socket
        |> put_flash(:error, "Group not found")
        |> push_navigate(to: Routes.path("/admin/posts/groups"))

      group ->
        load_existing_group(socket, group, current_user, project_title)
    end
  end

  defp load_existing_group(socket, group, current_user, project_title) do
    if group.user_id == current_user.id do
      form_data = %{
        "name" => group.name || "",
        "description" => group.description || "",
        "slug" => group.slug || "",
        "visibility" => group.visibility || "public"
      }

      form = Component.to_form(form_data, as: :post_group)

      socket
      |> assign(:page_title, "Edit Group")
      |> assign(:project_title, project_title)
      |> assign(:group, group)
      |> assign(:form, form)
      |> assign(:current_user, current_user)
    else
      socket
      |> put_flash(:error, "You don't have permission to edit this group")
      |> push_navigate(to: Routes.path("/admin/posts/groups"))
    end
  end

  @impl true
  def handle_event("validate", %{"post_group" => group_params}, socket) do
    # Auto-generate slug from name if slug is empty
    group_params = maybe_generate_slug(group_params)
    form = Component.to_form(group_params, as: :post_group)

    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"post_group" => group_params}, socket) do
    # Auto-generate slug from name if slug is empty
    group_params = maybe_generate_slug(group_params)

    save_group(
      socket,
      Map.get(socket.assigns.group, :uuid) || socket.assigns.group[:uuid],
      group_params
    )
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/posts/groups"))}
  end

  ## --- Private Helper Functions ---

  defp save_group(socket, nil, group_params) do
    # Creating new group
    case Posts.create_group(socket.assigns.current_user.uuid, group_params) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Group created successfully")
         |> push_navigate(to: Routes.path("/admin/posts/groups/#{group.uuid}"))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create group")
         |> assign(:form, Component.to_form(group_params, as: :post_group))}
    end
  end

  defp save_group(socket, _group_id, group_params) do
    # Updating existing group
    case Posts.update_group(socket.assigns.group, group_params) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Group updated successfully")
         |> push_navigate(to: Routes.path("/admin/posts/groups/#{group.uuid}"))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update group")
         |> assign(:form, Component.to_form(group_params, as: :post_group))}
    end
  end

  defp maybe_generate_slug(group_params) do
    slug = Map.get(group_params, "slug", "")
    name = Map.get(group_params, "name", "")

    if (slug == "" or is_nil(slug)) and name != "" do
      # Generate slug from name
      generated_slug =
        name
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9\s-]/, "")
        |> String.replace(~r/\s+/, "-")
        |> String.replace(~r/-+/, "-")
        |> String.trim("-")

      Map.put(group_params, "slug", generated_slug)
    else
      group_params
    end
  end
end
