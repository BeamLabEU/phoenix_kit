defmodule PhoenixKit.Modules.Comments.Web.Index do
  @moduledoc """
  LiveView for comment moderation admin page.

  Provides cross-resource comment management with filtering, search,
  pagination, and bulk actions.

  ## Route

  Mounted at `{prefix}/admin/comments`.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Comments
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    if Comments.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, "Comments")
        |> assign(:project_title, project_title)
        |> assign(:comments, [])
        |> assign(:total, 0)
        |> assign(:total_pages, 1)
        |> assign(:resource_context, %{})
        |> assign(:stats, Comments.comment_stats())
        |> assign(:selected_ids, [])
        |> assign_filter_defaults()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, "Comments module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> apply_params(params)
      |> load_comments()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    combined_params = %{"page" => "1"}

    combined_params =
      case Map.get(params, "search") do
        %{"query" => query} -> Map.put(combined_params, "search", String.trim(query || ""))
        _ -> combined_params
      end

    combined_params =
      case Map.get(params, "filter") do
        filter_params when is_map(filter_params) -> Map.merge(combined_params, filter_params)
        _ -> combined_params
      end

    new_params = build_url_params(socket.assigns, combined_params)
    {:noreply, push_patch(socket, to: Routes.path("/admin/comments?#{new_params}"))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/admin/comments"))}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    case Comments.get_comment(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Comment not found")}

      comment ->
        Comments.approve_comment(comment)

        {:noreply,
         socket |> load_comments() |> reload_stats() |> put_flash(:info, "Comment approved")}
    end
  end

  @impl true
  def handle_event("hide", %{"id" => id}, socket) do
    case Comments.get_comment(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Comment not found")}

      comment ->
        Comments.hide_comment(comment)

        {:noreply,
         socket |> load_comments() |> reload_stats() |> put_flash(:info, "Comment hidden")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Comments.get_comment(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Comment not found")}

      comment ->
        Comments.delete_comment(comment)

        {:noreply,
         socket |> load_comments() |> reload_stats() |> put_flash(:info, "Comment deleted")}
    end
  end

  @impl true
  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    selected =
      if id in selected,
        do: List.delete(selected, id),
        else: [id | selected]

    {:noreply, assign(socket, :selected_ids, selected)}
  end

  @impl true
  def handle_event("bulk_action", %{"action" => action}, socket) do
    ids = socket.assigns.selected_ids

    if ids == [] do
      {:noreply, put_flash(socket, :error, "No comments selected")}
    else
      case action do
        "approve" ->
          Comments.bulk_update_status(ids, "published")

          {:noreply,
           socket
           |> assign(:selected_ids, [])
           |> load_comments()
           |> reload_stats()
           |> put_flash(:info, "Comments approved")}

        "hide" ->
          Comments.bulk_update_status(ids, "hidden")

          {:noreply,
           socket
           |> assign(:selected_ids, [])
           |> load_comments()
           |> reload_stats()
           |> put_flash(:info, "Comments hidden")}

        "delete" ->
          Comments.bulk_update_status(ids, "deleted")

          {:noreply,
           socket
           |> assign(:selected_ids, [])
           |> load_comments()
           |> reload_stats()
           |> put_flash(:info, "Comments deleted")}

        _ ->
          {:noreply, socket}
      end
    end
  end

  ## --- Private ---

  defp assign_filter_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, 20)
    |> assign(:search, "")
    |> assign(:filter_resource_type, nil)
    |> assign(:filter_status, nil)
  end

  defp apply_params(socket, params) do
    socket
    |> assign(:page, parse_int(params["page"], 1))
    |> assign(:search, params["search"] || "")
    |> assign(:filter_resource_type, blank_to_nil(params["resource_type"]))
    |> assign(:filter_status, blank_to_nil(params["status"]))
  end

  defp load_comments(socket) do
    result =
      Comments.list_all_comments(
        page: socket.assigns.page,
        per_page: socket.assigns.per_page,
        search: socket.assigns.search,
        resource_type: socket.assigns.filter_resource_type,
        status: socket.assigns.filter_status
      )

    resource_context = Comments.resolve_resource_context(result.comments)

    socket
    |> assign(:comments, result.comments)
    |> assign(:total, result.total)
    |> assign(:total_pages, result.total_pages)
    |> assign(:resource_context, resource_context)
  end

  defp reload_stats(socket) do
    assign(socket, :stats, Comments.comment_stats())
  end

  defp build_url_params(assigns, overrides) do
    params =
      %{}
      |> maybe_put("page", Map.get(overrides, "page", to_string(assigns.page)))
      |> maybe_put("search", Map.get(overrides, "search", assigns.search))
      |> maybe_put(
        "resource_type",
        Map.get(overrides, "resource_type", assigns.filter_resource_type)
      )
      |> maybe_put("status", Map.get(overrides, "status", assigns.filter_status))

    URI.encode_query(params)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> max(n, 1)
      :error -> default
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  defp resource_info(resource_context, comment) do
    Map.get(resource_context, {comment.resource_type, comment.resource_uuid})
  end

  defp status_badge_class("published"), do: "badge badge-success badge-sm"
  defp status_badge_class("pending"), do: "badge badge-warning badge-sm"
  defp status_badge_class("hidden"), do: "badge badge-info badge-sm"
  defp status_badge_class("deleted"), do: "badge badge-error badge-sm"
  defp status_badge_class(_), do: "badge badge-ghost badge-sm"
end
