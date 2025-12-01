defmodule PhoenixKitWeb.Live.Modules.Posts.Edit do
  @moduledoc """
  LiveView for creating and editing posts.

  Provides a comprehensive post editor with:
  - Basic post fields (title, subtitle, content, type, status)
  - Tag and mention management
  - Group assignment
  - Scheduled publishing
  - SEO slug generation

  ## Route

  - New post: `{prefix}/admin/posts/new`
  - Edit post: `{prefix}/admin/posts/:id/edit`

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).
  """

  use PhoenixKitWeb, :live_view

  alias Phoenix.Component
  alias PhoenixKit.Posts
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(params, _session, socket) do
    # Get current user
    current_user = socket.assigns[:phoenix_kit_current_user]

    # Get project title
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Determine if this is a new post or editing existing
    post_id = Map.get(params, "id")

    socket =
      if post_id do
        # Editing existing post
        case Posts.get_post!(post_id, preload: [:user, :media, :tags, :groups, :mentions]) do
          nil ->
            socket
            |> put_flash(:error, "Post not found")
            |> push_navigate(to: Routes.path("/admin/posts"))

          post ->
            # Check if user owns this post or is admin
            if can_edit_post?(current_user, post) do
              form_data = %{
                "title" => post.title || "",
                "sub_title" => post.sub_title || "",
                "content" => post.content || "",
                "type" => post.type || "post",
                "status" => post.status || "draft",
                "slug" => post.slug || ""
              }

              form = Component.to_form(form_data, as: :post)

              socket
              |> assign(:page_title, "Edit Post")
              |> assign(:project_title, project_title)
              |> assign(:post, post)
              |> assign(:form, form)
              |> assign(:current_user, current_user)
              |> load_form_data()
            else
              socket
              |> put_flash(:error, "You don't have permission to edit this post")
              |> push_navigate(to: Routes.path("/admin/posts"))
            end
        end
      else
        # Creating new post
        form_data = %{
          "title" => "",
          "sub_title" => "",
          "content" => "",
          "type" => "post",
          "status" => Settings.get_setting("posts_default_status", "draft"),
          "slug" => ""
        }

        form = Component.to_form(form_data, as: :post)

        socket
        |> assign(:page_title, "New Post")
        |> assign(:project_title, project_title)
        |> assign(:post, %{id: nil, user_id: current_user.id})
        |> assign(:form, form)
        |> assign(:current_user, current_user)
        |> load_form_data()
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"post" => post_params}, socket) do
    form = Component.to_form(post_params, as: :post)
    {:noreply, assign(socket, :form, form)}
  end

  @impl true
  def handle_event("save", %{"post" => post_params}, socket) do
    # Parse tags from content if auto-tagging is enabled
    tags = Posts.parse_hashtags(post_params["content"] || "")

    # Generate slug if auto-slug is enabled and slug is empty
    post_params = maybe_generate_slug(post_params)

    save_post(socket, socket.assigns.post[:id] || socket.assigns.post.id, post_params, tags)
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/posts"))}
  end

  @impl true
  def handle_event("add_tag", %{"tag" => tag_name}, socket) do
    if tag_name != "" do
      current_tags = socket.assigns.selected_tags
      max_tags = String.to_integer(Settings.get_setting("posts_max_tags", "20"))

      if length(current_tags) < max_tags and tag_name not in current_tags do
        {:noreply, assign(socket, :selected_tags, [tag_name | current_tags])}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_tag", %{"tag" => tag_name}, socket) do
    current_tags = Enum.reject(socket.assigns.selected_tags, &(&1 == tag_name))
    {:noreply, assign(socket, :selected_tags, current_tags)}
  end

  ## --- Private Helper Functions ---

  defp save_post(socket, nil, post_params, tags) do
    # Creating new post
    case Posts.create_post(socket.assigns.current_user.id, post_params) do
      {:ok, post} ->
        # Handle tags
        if tags != [] do
          Posts.add_tags_to_post(post, tags)
        end

        {:noreply,
         socket
         |> put_flash(:info, "Post created successfully")
         |> push_navigate(to: Routes.path("/admin/posts/#{post.id}"))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create post")
         |> assign(:form, Component.to_form(post_params, as: :post))}
    end
  end

  defp save_post(socket, _post_id, post_params, tags) do
    # Updating existing post
    case Posts.update_post(socket.assigns.post, post_params) do
      {:ok, post} ->
        # Handle tags
        if tags != [] do
          Posts.add_tags_to_post(post, tags)
        end

        {:noreply,
         socket
         |> put_flash(:info, "Post updated successfully")
         |> push_navigate(to: Routes.path("/admin/posts/#{post.id}"))}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update post")
         |> assign(:form, Component.to_form(post_params, as: :post))}
    end
  end

  defp load_form_data(socket) do
    # Load user's groups for selection
    user_groups = Posts.list_user_groups(socket.assigns.current_user.id)

    # Load existing tags if editing
    selected_tags =
      if Map.get(socket.assigns.post, :id) do
        Enum.map(Map.get(socket.assigns.post, :tags, []) || [], & &1.name)
      else
        []
      end

    # Load existing groups if editing
    selected_groups =
      if Map.get(socket.assigns.post, :id) do
        Enum.map(Map.get(socket.assigns.post, :groups, []) || [], & &1.id)
      else
        []
      end

    # Load settings
    max_media = String.to_integer(Settings.get_setting("posts_max_media", "10"))
    max_title_length = String.to_integer(Settings.get_setting("posts_max_title_length", "255"))
    max_subtitle_length = String.to_integer(Settings.get_setting("posts_max_subtitle_length", "500"))
    max_content_length = String.to_integer(Settings.get_setting("posts_max_content_length", "50000"))
    max_tags = String.to_integer(Settings.get_setting("posts_max_tags", "20"))
    default_status = Settings.get_setting("posts_default_status", "draft")
    allow_scheduling = Settings.get_setting("posts_allow_scheduling", "true") == "true"
    allow_groups = Settings.get_setting("posts_allow_groups", "true") == "true"
    seo_auto_slug = Settings.get_setting("posts_seo_auto_slug", "true") == "true"

    socket
    |> assign(:user_groups, user_groups)
    |> assign(:selected_tags, selected_tags)
    |> assign(:selected_groups, selected_groups)
    |> assign(:max_media, max_media)
    |> assign(:max_title_length, max_title_length)
    |> assign(:max_subtitle_length, max_subtitle_length)
    |> assign(:max_content_length, max_content_length)
    |> assign(:max_tags, max_tags)
    |> assign(:default_status, default_status)
    |> assign(:allow_scheduling, allow_scheduling)
    |> assign(:allow_groups, allow_groups)
    |> assign(:seo_auto_slug, seo_auto_slug)
  end

  defp can_edit_post?(user, post) do
    # User can edit if they own the post or are admin/owner
    Map.get(post, :user_id) == user.id or user_is_admin?(user)
  end

  defp user_is_admin?(user) do
    # Check if user has admin or owner role
    PhoenixKit.Users.Auth.Scope.has_role?(user, ["owner", "admin"])
  end

  defp maybe_generate_slug(post_params) do
    seo_auto_slug = Settings.get_setting("posts_seo_auto_slug", "true") == "true"
    slug = Map.get(post_params, "slug", "")
    title = Map.get(post_params, "title", "")

    if seo_auto_slug and (slug == "" or is_nil(slug)) and title != "" do
      # Generate slug from title
      generated_slug =
        title
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9\s-]/, "")
        |> String.replace(~r/\s+/, "-")
        |> String.replace(~r/-+/, "-")
        |> String.trim("-")

      Map.put(post_params, "slug", generated_slug)
    else
      post_params
    end
  end
end
