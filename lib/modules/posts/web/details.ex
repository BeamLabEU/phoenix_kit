defmodule PhoenixKitWeb.Live.Modules.Posts.Details do
  @moduledoc """
  LiveView for displaying a single post with all details and interactions.

  Displays:
  - Post content (title, subtitle, content, media)
  - Author information
  - Post statistics (views, likes, comments)
  - Tags and groups
  - Comments via standalone CommentsComponent
  - Like/unlike functionality
  - Admin actions (edit, delete, status changes)

  ## Route

  This LiveView is mounted at `{prefix}/admin/posts/:id` and requires
  appropriate permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Modules.Comments
  alias PhoenixKit.Modules.Posts
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => post_uuid}, _session, socket) do
    # Get current user
    current_user = socket.assigns[:phoenix_kit_current_user]

    # Get project title
    project_title = Settings.get_project_title()

    # Load post with all associations
    case Posts.get_post!(post_uuid, preload: [:user, [media: :file], :tags, :groups, :mentions]) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Post not found")
         |> push_navigate(to: Routes.path("/admin/posts"))}

      post ->
        # Increment view count
        Posts.increment_view_count(post)

        # Check if current user liked this post
        liked_by_user = Posts.post_liked_by?(post.uuid, current_user.uuid)

        # Load settings
        comments_enabled = Comments.enabled?()
        likes_enabled = Settings.get_setting("posts_likes_enabled", "true") == "true"
        show_view_count = Settings.get_setting("posts_show_view_count", "true") == "true"

        socket =
          socket
          |> assign(:page_title, post.title)
          |> assign(:project_title, project_title)
          |> assign(:post, post)
          |> assign(:rendered_content, render_markdown_content(post.content))
          |> assign(:current_user, current_user)
          |> assign(:liked_by_user, liked_by_user)
          |> assign(:comments_enabled, comments_enabled)
          |> assign(:likes_enabled, likes_enabled)
          |> assign(:show_view_count, show_view_count)

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("like_post", _params, socket) do
    post = socket.assigns.post
    current_user = socket.assigns.current_user

    if socket.assigns.liked_by_user do
      # Unlike
      Posts.unlike_post(post.uuid, current_user.uuid)

      updated_post =
        Posts.get_post!(post.uuid, preload: [:user, [media: :file], :tags, :groups, :mentions])

      {:noreply,
       socket
       |> assign(:post, updated_post)
       |> assign(:liked_by_user, false)}
    else
      # Like
      Posts.like_post(post.uuid, current_user.uuid)

      updated_post =
        Posts.get_post!(post.uuid, preload: [:user, [media: :file], :tags, :groups, :mentions])

      {:noreply,
       socket
       |> assign(:post, updated_post)
       |> assign(:liked_by_user, true)}
    end
  end

  @impl true
  def handle_event("edit_post", _params, socket) do
    {:noreply,
     push_navigate(socket, to: Routes.path("/admin/posts/#{socket.assigns.post.uuid}/edit"))}
  end

  @impl true
  def handle_event("delete_post", _params, socket) do
    case Posts.delete_post(socket.assigns.post) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Post deleted successfully")
         |> push_navigate(to: Routes.path("/admin/posts"))}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Failed to delete post")}
    end
  end

  @impl true
  def handle_event("change_status", %{"status" => status}, socket) do
    case Posts.update_post(socket.assigns.post, %{status: status}) do
      {:ok, updated_post} ->
        {:noreply,
         socket
         |> assign(:post, updated_post)
         |> put_flash(:info, "Post status updated to #{status}")}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Failed to update post status")}
    end
  end

  # Handle comment count updates from CommentsComponent
  @impl true
  def handle_info({:comments_updated, _info}, socket) do
    updated_post =
      Posts.get_post!(socket.assigns.post.uuid,
        preload: [:user, [media: :file], :tags, :groups, :mentions]
      )

    {:noreply, assign(socket, :post, updated_post)}
  end

  ## --- Private Helper Functions ---

  defp user_is_admin?(user) do
    Roles.user_has_role_owner?(user) or Roles.user_has_role_admin?(user)
  end

  defp can_edit_post?(user, post) do
    user.uuid == post.user_uuid or user_is_admin?(user)
  end

  defp format_post_type("post"), do: "Post"
  defp format_post_type("snippet"), do: "Snippet"
  defp format_post_type("repost"), do: "Repost"
  defp format_post_type(_), do: "Unknown"

  defp format_status("draft"), do: "Draft"
  defp format_status("public"), do: "Public"
  defp format_status("unlisted"), do: "Unlisted"
  defp format_status("scheduled"), do: "Scheduled"
  defp format_status(_), do: "Unknown"

  defp format_type_badge_class("post"), do: "badge badge-primary"
  defp format_type_badge_class("snippet"), do: "badge badge-secondary"
  defp format_type_badge_class("repost"), do: "badge badge-accent"
  defp format_type_badge_class(_), do: "badge badge-ghost"

  defp format_status_badge_class("draft"), do: "badge badge-neutral"
  defp format_status_badge_class("public"), do: "badge badge-success"
  defp format_status_badge_class("unlisted"), do: "badge badge-warning"
  defp format_status_badge_class("scheduled"), do: "badge badge-info"
  defp format_status_badge_class(_), do: "badge badge-ghost"

  defp render_markdown_content(content) when is_binary(content) and content != "" do
    Renderer.render_markdown(content)
  end

  defp render_markdown_content(_), do: ""
end
