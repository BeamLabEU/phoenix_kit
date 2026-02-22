defmodule PhoenixKit.Modules.Comments.Web.CommentsComponent do
  @moduledoc """
  Reusable LiveComponent for displaying and managing comments on any resource.

  ## Usage

      <.live_component
        module={PhoenixKit.Modules.Comments.Web.CommentsComponent}
        id={"comments-\#{@post.uuid}"}
        resource_type="post"
        resource_id={@post.uuid}
        current_user={@current_user}
      />

  ## Required Attrs

  - `resource_type` - String identifying the resource type (e.g., "post")
  - `resource_id` - UUID of the resource
  - `current_user` - Current authenticated user struct
  - `id` - Unique component ID

  ## Optional Attrs

  - `enabled` - Whether comments are enabled (default: true)
  - `show_likes` - Show like/dislike buttons (default: false)
  - `title` - Section title (default: "Comments")

  ## Parent Notifications

  After create/delete, sends to the parent LiveView:

      {:comments_updated, %{resource_type: "post", resource_id: uuid, action: :created | :deleted}}
  """

  use PhoenixKitWeb, :live_component

  import PhoenixKitWeb.Components.Core.Icon

  alias PhoenixKit.Modules.Comments
  alias PhoenixKit.Users.Roles

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:comments, [])
     |> assign(:reply_to, nil)
     |> assign(:new_comment, "")}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:enabled, fn -> true end)
      |> assign_new(:show_likes, fn -> false end)
      |> assign_new(:title, fn -> "Comments" end)

    socket =
      if changed?(socket, :resource_id) or socket.assigns.comments == [] do
        load_comments(socket)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("add_comment", %{"comment" => comment_text}, socket) do
    if comment_text != "" do
      parent_id = socket.assigns.reply_to

      attrs = %{
        content: comment_text,
        parent_id: parent_id
      }

      case Comments.create_comment(
             socket.assigns.resource_type,
             socket.assigns.resource_id,
             socket.assigns.current_user.id,
             attrs
           ) do
        {:ok, _comment} ->
          send(
            self(),
            {:comments_updated,
             %{
               resource_type: socket.assigns.resource_type,
               resource_id: socket.assigns.resource_id,
               action: :created
             }}
          )

          {:noreply,
           socket
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
    case Comments.get_comment(comment_id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "Comment not found")}

      comment ->
        if can_delete_comment?(socket.assigns.current_user, comment) do
          case Comments.delete_comment(comment) do
            {:ok, _} ->
              send(
                self(),
                {:comments_updated,
                 %{
                   resource_type: socket.assigns.resource_type,
                   resource_id: socket.assigns.resource_id,
                   action: :deleted
                 }}
              )

              {:noreply,
               socket
               |> load_comments()
               |> put_flash(:info, "Comment deleted")}

            {:error, _} ->
              {:noreply, socket |> put_flash(:error, "Failed to delete comment")}
          end
        else
          {:noreply,
           socket |> put_flash(:error, "You don't have permission to delete this comment")}
        end
    end
  end

  defp load_comments(socket) do
    comments =
      Comments.get_comment_tree(socket.assigns.resource_type, socket.assigns.resource_id)

    comment_count =
      Comments.count_comments(
        socket.assigns.resource_type,
        socket.assigns.resource_id,
        status: "published"
      )

    socket
    |> assign(:comments, comments)
    |> assign(:comment_count, comment_count)
  end

  attr :comment, :map, required: true
  attr :current_user, :map, required: true
  attr :myself, :any, required: true

  def render_comment(assigns) do
    ~H"""
    <div class={[
      if(@comment.depth > 0, do: "ml-4 border-l-2 border-base-300", else: "")
    ]}>
      <div class="bg-base-200 rounded-lg p-4">
        <%!-- Comment Header --%>
        <div class="flex items-center justify-between mb-2">
          <div class="flex items-center gap-2 text-sm">
            <.icon name="hero-user-circle" class="w-5 h-5 text-base-content/60" />
            <span class="font-semibold">
              <%= if @comment.user do %>
                {@comment.user.email}
              <% else %>
                Unknown
              <% end %>
            </span>
            <span class="text-base-content/60">&bull;</span>
            <span class="text-base-content/60">
              {Calendar.strftime(@comment.inserted_at, "%b %d, %Y %I:%M %p")}
            </span>
          </div>

          <%!-- Comment Actions --%>
          <div class="flex gap-2">
            <button
              phx-click="reply_to"
              phx-value-id={@comment.uuid}
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
            >
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Reply
            </button>

            <%= if can_delete_comment?(@current_user, @comment) do %>
              <button
                phx-click="delete_comment"
                phx-value-id={@comment.uuid}
                phx-target={@myself}
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
          {@comment.content}
        </div>

        <%!-- Nested Comments (Replies) --%>
        <%= if @comment.children && length(@comment.children) > 0 do %>
          <div class="mt-4 space-y-3">
            <%= for child <- @comment.children do %>
              <.render_comment
                comment={child}
                current_user={@current_user}
                myself={@myself}
              />
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp can_delete_comment?(user, comment) do
    user.uuid == comment.user_uuid or user_is_admin?(user)
  end

  defp user_is_admin?(user) do
    Roles.user_has_role_owner?(user) or Roles.user_has_role_admin?(user)
  end
end
