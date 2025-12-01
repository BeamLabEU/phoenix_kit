defmodule PhoenixKitWeb.Live.Modules.Posts.Details do
  @moduledoc """
  LiveView for displaying a single post with all details, comments, and interactions.

  Displays:
  - Post content (title, subtitle, content, media)
  - Author information
  - Post statistics (views, likes, comments)
  - Tags and groups
  - Comments with unlimited threading
  - Like/unlike functionality
  - Admin actions (edit, delete, status changes)

  ## Route

  This LiveView is mounted at `{prefix}/admin/posts/:id` and requires
  appropriate permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Posts
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"id" => post_id}, _session, socket) do
    # Get current user
    current_user = socket.assigns[:phoenix_kit_current_user]

    # Get project title
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load post with all associations
    case Posts.get_post!(post_id, preload: [:user, :media, :tags, :groups, :mentions]) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Post not found")
         |> push_navigate(to: Routes.path("/admin/posts"))}

      post ->
        # Increment view count
        Posts.increment_view_count(post)

        # Check if current user liked this post
        liked_by_user = Posts.post_liked_by?(post.id, current_user.id)

        # Load settings
        comments_enabled = Settings.get_setting("posts_comments_enabled", "true") == "true"
        likes_enabled = Settings.get_setting("posts_likes_enabled", "true") == "true"
        show_view_count = Settings.get_setting("posts_show_view_count", "true") == "true"

        socket =
          socket
          |> assign(:page_title, post.title)
          |> assign(:project_title, project_title)
          |> assign(:post, post)
          |> assign(:current_user, current_user)
          |> assign(:liked_by_user, liked_by_user)
          |> assign(:comments_enabled, comments_enabled)
          |> assign(:likes_enabled, likes_enabled)
          |> assign(:show_view_count, show_view_count)
          |> assign(:new_comment, "")
          |> assign(:reply_to, nil)
          |> load_comments()

        {:ok, socket}
    end
  end

  @impl true
  def handle_event("like_post", _params, socket) do
    post = socket.assigns.post
    current_user = socket.assigns.current_user

    if socket.assigns.liked_by_user do
      # Unlike
      Posts.unlike_post(post.id, current_user.id)
      updated_post = Posts.get_post!(post.id, preload: [:user, :media, :tags, :groups, :mentions])

      {:noreply,
       socket
       |> assign(:post, updated_post)
       |> assign(:liked_by_user, false)}
    else
      # Like
      Posts.like_post(post.id, current_user.id)
      updated_post = Posts.get_post!(post.id, preload: [:user, :media, :tags, :groups, :mentions])

      {:noreply,
       socket
       |> assign(:post, updated_post)
       |> assign(:liked_by_user, true)}
    end
  end

  @impl true
  def handle_event("add_comment", %{"comment" => comment_text}, socket) do
    if comment_text != "" do
      parent_id = socket.assigns.reply_to

      attrs = %{
        content: comment_text,
        parent_id: parent_id
      }

      case Posts.create_comment(socket.assigns.post.id, socket.assigns.current_user.id, attrs) do
        {:ok, _comment} ->
          updated_post =
            Posts.get_post!(socket.assigns.post.id, preload: [:user, :media, :tags, :groups, :mentions])

          {:noreply,
           socket
           |> assign(:post, updated_post)
           |> assign(:new_comment, "")
           |> assign(:reply_to, nil)
           |> load_comments()
           |> put_flash(:info, "Comment added")}

        {:error, _changeset} ->
          {:noreply, socket |> put_flash(:error, "Failed to add comment")}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reply_to", %{"id" => comment_id}, socket) do
    {:noreply, assign(socket, :reply_to, comment_id)}
  end

  @impl true
  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :reply_to, nil)}
  end

  @impl true
  def handle_event("delete_comment", %{"id" => comment_id}, socket) do
    case Posts.get_comment(comment_id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "Comment not found")}

      comment ->
        # Check if user can delete (owns comment or is admin)
        if can_delete_comment?(socket.assigns.current_user, comment) do
          case Posts.delete_comment(comment) do
            {:ok, _} ->
              updated_post =
                Posts.get_post!(socket.assigns.post.id, preload: [:user, :media, :tags, :groups, :mentions])

              {:noreply,
               socket
               |> assign(:post, updated_post)
               |> load_comments()
               |> put_flash(:info, "Comment deleted")}

            {:error, _} ->
              {:noreply, socket |> put_flash(:error, "Failed to delete comment")}
          end
        else
          {:noreply, socket |> put_flash(:error, "You don't have permission to delete this comment")}
        end
    end
  end

  @impl true
  def handle_event("edit_post", _params, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/posts/#{socket.assigns.post.id}/edit"))}
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

  ## --- Private Helper Functions ---

  defp load_comments(socket) do
    comments = Posts.get_comment_tree(socket.assigns.post.id)
    assign(socket, :comments, comments)
  end

  defp can_delete_comment?(user, comment) do
    user.id == comment.user_id or user_is_admin?(user)
  end

  defp user_is_admin?(user) do
    PhoenixKit.Users.Auth.Scope.has_role?(user, ["owner", "admin"])
  end

  defp can_edit_post?(user, post) do
    user.id == post.user_id or user_is_admin?(user)
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

  defp render_comment(comment, current_user, assigns) do
    assigns = Map.merge(assigns, %{comment: comment, current_user: current_user})

    ~H"""
    <div class={["pl-#{@comment.depth * 4}", if(@comment.depth > 0, do: "ml-4 border-l-2 border-base-300", else: "")]}>
      <div class="bg-base-200 rounded-lg p-4">
        <%!-- Comment Header --%>
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-2 text-sm">
            <.icon name="hero-user-circle" class="w-5 h-5 text-base-content/60" />
            <span class="font-semibold">
              <%= if @comment.user do %>
                <%= @comment.user.email %>
              <% else %>
                Unknown
              <% end %>
            </span>
            <span class="text-base-content/60">•</span>
            <span class="text-base-content/60">
              <%= Calendar.strftime(@comment.inserted_at, "%b %d, %Y %I:%M %p") %>
            </span>
          </div>

          <%!-- Comment Actions --%>
          <div class="flex gap-2">
            <button
              phx-click="reply_to"
              phx-value-id={@comment.id}
              class="btn btn-ghost btn-xs"
            >
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Reply
            </button>

            <%= if can_delete_comment?(@current_user, @comment) do %>
              <button
                phx-click="delete_comment"
                phx-value-id={@comment.id}
                class="btn btn-ghost btn-xs text-error"
                data-confirm="Are you sure you want to delete this comment?"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            <% end %>
          </div>
        </div>

        <%!-- Comment Content --%>
        <div class="text-base-content">
          <%= @comment.content %>
        </div>

        <%!-- Nested Comments (Replies) --%>
        <%= if @comment.children && length(@comment.children) > 0 do %>
          <div class="mt-4 space-y-3">
            <%= for child <- @comment.children do %>
              <%= render_comment(child, @current_user, assigns) %>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
