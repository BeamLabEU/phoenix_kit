defmodule PhoenixKitWeb.Live.Modules.Posts.Posts do
  @moduledoc """
  LiveView for displaying and managing posts in PhoenixKit admin panel.

  Provides comprehensive post management interface with filtering, searching,
  and quick actions for social posts system.

  ## Features

  - **Real-time Post List**: Live updates of posts
  - **Advanced Filtering**: By type, status, group, tag, date range
  - **Search Functionality**: Search across titles and content
  - **Pagination**: Handle large volumes of posts
  - **Bulk Actions**: Publish, delete multiple posts
  - **Quick Actions**: Edit, delete, change status
  - **Statistics Summary**: Key metrics (total, drafts, scheduled, public)

  ## Route

  This LiveView is mounted at `{prefix}/admin/posts` and requires
  appropriate admin permissions.

  Note: `{prefix}` is your configured PhoenixKit URL prefix (default: `/phoenix_kit`).

  ## Usage

      # In your Phoenix router
      live "/admin/posts", PhoenixKitWeb.Live.Modules.Posts.Posts, :index

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  require Logger

  alias PhoenixKit.Posts
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @max_per_page 100

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Check if posts module is enabled
    if posts_enabled?() do
      # Get project title from settings
      project_title = Settings.get_setting("project_title", "PhoenixKit")

      # Get current user
      current_user = socket.assigns[:phoenix_kit_current_user]

      socket =
        socket
        |> assign(:page_title, "Posts")
        |> assign(:project_title, project_title)
        |> assign(:current_user, current_user)
        |> assign(:posts, [])
        |> assign(:total_count, 0)
        |> assign(:stats, %{total: 0, drafts: 0, public: 0, scheduled: 0})
        |> assign(:loading, true)
        |> assign(:selected_posts, [])
        |> assign_filter_defaults()
        |> assign_pagination_defaults()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Posts module is not enabled")
       |> push_navigate(to: Routes.path("/admin/dashboard"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_posts()
      |> load_stats()

    {:noreply, socket}
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("filter", params, socket) do
    # Handle search and filter parameters
    combined_params = %{}

    # Extract search parameters
    combined_params =
      case Map.get(params, "search") do
        %{"query" => query} -> Map.put(combined_params, "search", String.trim(query || ""))
        _ -> combined_params
      end

    # Extract filter parameters
    combined_params =
      case Map.get(params, "filter") do
        filter_params when is_map(filter_params) -> Map.merge(combined_params, filter_params)
        _ -> combined_params
      end

    # Reset to first page when filtering
    combined_params = Map.put(combined_params, "page", "1")

    # Build new URL parameters
    new_params = build_url_params(socket.assigns, combined_params)

    {:noreply, socket |> push_patch(to: Routes.path("/admin/posts?#{new_params}"))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, socket |> push_patch(to: Routes.path("/admin/posts"))}
  end

  @impl true
  def handle_event("view_post", %{"id" => post_id}, socket) do
    {:noreply, socket |> push_navigate(to: Routes.path("/admin/posts/#{post_id}"))}
  end

  @impl true
  def handle_event("edit_post", %{"id" => post_id}, socket) do
    {:noreply, socket |> push_navigate(to: Routes.path("/admin/posts/#{post_id}/edit"))}
  end

  @impl true
  def handle_event("delete_post", %{"id" => post_id}, socket) do
    case Posts.get_post!(post_id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "Post not found")}

      post ->
        case Posts.delete_post(post) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Post deleted successfully")
             |> load_posts()
             |> load_stats()}

          {:error, _changeset} ->
            {:noreply, socket |> put_flash(:error, "Failed to delete post")}
        end
    end
  end

  @impl true
  def handle_event("publish_post", %{"id" => post_id}, socket) do
    case Posts.get_post!(post_id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "Post not found")}

      post ->
        case Posts.publish_post(post) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Post published successfully")
             |> load_posts()
             |> load_stats()}

          {:error, _changeset} ->
            {:noreply, socket |> put_flash(:error, "Failed to publish post")}
        end
    end
  end

  @impl true
  def handle_event("draft_post", %{"id" => post_id}, socket) do
    case Posts.get_post!(post_id) do
      nil ->
        {:noreply, socket |> put_flash(:error, "Post not found")}

      post ->
        case Posts.draft_post(post) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Post moved to drafts")
             |> load_posts()
             |> load_stats()}

          {:error, _changeset} ->
            {:noreply, socket |> put_flash(:error, "Failed to update post")}
        end
    end
  end

  @impl true
  def handle_event("select_post", %{"id" => post_id, "value" => value}, socket) do
    selected_posts =
      if value == "on" do
        [post_id | socket.assigns.selected_posts] |> Enum.uniq()
      else
        Enum.reject(socket.assigns.selected_posts, &(&1 == post_id))
      end

    {:noreply, assign(socket, :selected_posts, selected_posts)}
  end

  @impl true
  def handle_event("select_all", %{"value" => value}, socket) do
    selected_posts =
      if value == "on" do
        Enum.map(socket.assigns.posts, & &1.id)
      else
        []
      end

    {:noreply, assign(socket, :selected_posts, selected_posts)}
  end

  @impl true
  def handle_event("bulk_publish", _params, socket) do
    count =
      Enum.reduce(socket.assigns.selected_posts, 0, fn post_id, acc ->
        case Posts.get_post!(post_id) do
          nil ->
            acc

          post ->
            case Posts.publish_post(post) do
              {:ok, _} -> acc + 1
              _ -> acc
            end
        end
      end)

    {:noreply,
     socket
     |> put_flash(:info, "Published #{count} post(s)")
     |> assign(:selected_posts, [])
     |> load_posts()
     |> load_stats()}
  end

  @impl true
  def handle_event("bulk_delete", _params, socket) do
    count =
      Enum.reduce(socket.assigns.selected_posts, 0, fn post_id, acc ->
        case Posts.get_post!(post_id) do
          nil ->
            acc

          post ->
            case Posts.delete_post(post) do
              {:ok, _} -> acc + 1
              _ -> acc
            end
        end
      end)

    {:noreply,
     socket
     |> put_flash(:info, "Deleted #{count} post(s)")
     |> assign(:selected_posts, [])
     |> load_posts()
     |> load_stats()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:loading, true)
     |> load_posts()
     |> load_stats()
     |> put_flash(:info, "Posts refreshed")}
  end

  ## --- Private Helper Functions ---

  defp posts_enabled? do
    Settings.get_setting("posts_enabled", "true") == "true"
  end

  defp assign_filter_defaults(socket) do
    socket
    |> assign(:filter_type, "all")
    |> assign(:filter_status, "all")
    |> assign(:filter_group, "all")
    |> assign(:filter_tag, "all")
    |> assign(:search_query, "")
  end

  defp assign_pagination_defaults(socket) do
    per_page =
      Settings.get_setting("posts_per_page", "20")
      |> String.to_integer()
      |> min(@max_per_page)

    socket
    |> assign(:page, 1)
    |> assign(:per_page, per_page)
  end

  defp apply_params(socket, params) do
    socket
    |> assign(:filter_type, Map.get(params, "type", "all"))
    |> assign(:filter_status, Map.get(params, "status", "all"))
    |> assign(:filter_group, Map.get(params, "group", "all"))
    |> assign(:filter_tag, Map.get(params, "tag", "all"))
    |> assign(:search_query, Map.get(params, "search", ""))
    |> assign(:page, String.to_integer(Map.get(params, "page", "1")))
  end

  defp load_posts(socket) do
    opts = [
      page: socket.assigns.page,
      per_page: socket.assigns.per_page,
      preload: [:user, :media, :tags, :groups]
    ]

    # Add filters
    opts =
      opts
      |> maybe_add_filter(:type, socket.assigns.filter_type)
      |> maybe_add_filter(:status, socket.assigns.filter_status)
      |> maybe_add_search(socket.assigns.search_query)

    posts = Posts.list_posts(opts)
    total_count = length(posts)

    socket
    |> assign(:posts, posts)
    |> assign(:total_count, total_count)
    |> assign(:loading, false)
  end

  defp load_stats(socket) do
    # Load post statistics
    stats = %{
      total: count_posts([]),
      drafts: count_posts(status: "draft"),
      public: count_posts(status: "public"),
      scheduled: count_posts(status: "scheduled"),
      unlisted: count_posts(status: "unlisted")
    }

    assign(socket, :stats, stats)
  end

  defp count_posts(opts) do
    Posts.list_posts(opts) |> length()
  end

  defp maybe_add_filter(opts, _key, "all"), do: opts

  defp maybe_add_filter(opts, key, value) when value != "" and value != nil do
    Keyword.put(opts, key, value)
  end

  defp maybe_add_filter(opts, _key, _value), do: opts

  defp maybe_add_search(opts, "") do
    opts
  end

  defp maybe_add_search(opts, query) when is_binary(query) and query != "" do
    Keyword.put(opts, :search, query)
  end

  defp maybe_add_search(opts, _), do: opts

  defp build_url_params(assigns, new_params) do
    params = %{
      "type" => new_params["type"] || assigns.filter_type,
      "status" => new_params["status"] || assigns.filter_status,
      "group" => new_params["group"] || assigns.filter_group,
      "tag" => new_params["tag"] || assigns.filter_tag,
      "search" => new_params["search"] || assigns.search_query,
      "page" => new_params["page"] || to_string(assigns.page)
    }

    # Remove default values to keep URL clean
    params
    |> Enum.reject(fn {_k, v} -> v == "all" or v == "" end)
    |> URI.encode_query()
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

  defp status_badge_class("draft"), do: "badge-neutral"
  defp status_badge_class("public"), do: "badge-success"
  defp status_badge_class("unlisted"), do: "badge-warning"
  defp status_badge_class("scheduled"), do: "badge-info"
  defp status_badge_class(_), do: "badge-ghost"

  defp type_badge_class("post"), do: "badge-primary"
  defp type_badge_class("snippet"), do: "badge-secondary"
  defp type_badge_class("repost"), do: "badge-accent"
  defp type_badge_class(_), do: "badge-ghost"
end
