defmodule PhoenixKit.Modules.Entities.Web.DataNavigator do
  @moduledoc """
  LiveView for browsing and managing entity data records.
  Provides table view with pagination, search, filtering, and bulk operations.
  """

  use PhoenixKitWeb, :live_view
  on_mount PhoenixKit.Modules.Entities.Web.Hooks

  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Modules.Entities.EntityData
  alias PhoenixKit.Modules.Entities.Events
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    entities = Entities.list_entities()

    # Get entity from route params using slug (entity_slug or entity_id for backwards compat)
    {entity, entity_id} =
      case params["entity_slug"] || params["entity_id"] do
        nil ->
          {nil, nil}

        slug when is_binary(slug) ->
          # Try to get entity by name (slug)
          case Entities.get_entity_by_name(slug) do
            nil -> {nil, nil}
            entity -> {entity, entity.id}
          end
      end

    # Get stats filtered by entity if one is selected
    stats = EntityData.get_data_stats(entity_id)

    # Set page title based on entity
    page_title =
      if entity do
        entity.display_name
      else
        gettext("Data Navigator")
      end

    socket =
      socket
      |> assign(:page_title, page_title)
      |> assign(:project_title, project_title)
      |> assign(:entities, entities)
      |> assign(:total_records, stats.total_records)
      |> assign(:published_records, stats.published_records)
      |> assign(:draft_records, stats.draft_records)
      |> assign(:archived_records, stats.archived_records)
      |> assign(:selected_entity, entity)
      |> assign(:selected_entity_id, entity_id)
      |> assign(:selected_status, "all")
      |> assign(:search_term, "")
      |> assign(:view_mode, "table")
      |> apply_filters()

    if connected?(socket) && entity_id do
      Events.subscribe_to_entity_data(entity_id)
    end

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    # Get entity from slug in params (entity_slug or entity_id for backwards compat)
    {entity, entity_id} = resolve_entity_from_params(params, socket)

    # Recalculate stats and subscribe if entity changed
    socket = maybe_update_entity_stats(socket, entity_id)

    # Extract filter params with defaults
    status = params["status"] || "all"
    search_term = params["search"] || ""
    view_mode = params["view"] || "table"

    socket =
      socket
      |> assign(:selected_entity, entity)
      |> assign(:selected_entity_id, entity_id)
      |> assign(:selected_status, status)
      |> assign(:search_term, search_term)
      |> assign(:view_mode, view_mode)
      |> apply_filters()

    {:noreply, socket}
  end

  # Resolve entity and entity_id from URL params
  defp resolve_entity_from_params(params, socket) do
    case params["entity_slug"] || params["entity_id"] do
      nil ->
        {socket.assigns.selected_entity, socket.assigns.selected_entity_id}

      "" ->
        {nil, nil}

      slug when is_binary(slug) ->
        resolve_entity_by_slug(slug)
    end
  end

  # Look up entity by slug/name
  defp resolve_entity_by_slug(slug) do
    case Entities.get_entity_by_name(slug) do
      nil -> {nil, nil}
      entity -> {entity, entity.id}
    end
  end

  # Update entity stats and subscribe to events if entity changed
  defp maybe_update_entity_stats(socket, new_entity_id) do
    if new_entity_id != socket.assigns.selected_entity_id do
      maybe_subscribe_to_entity(socket, new_entity_id)
      update_entity_stats(socket, new_entity_id)
    else
      socket
    end
  end

  # Subscribe to entity data events if connected
  defp maybe_subscribe_to_entity(socket, entity_id) do
    if connected?(socket) && entity_id do
      Events.subscribe_to_entity_data(entity_id)
    end
  end

  # Update socket with fresh entity statistics
  defp update_entity_stats(socket, entity_id) do
    stats = EntityData.get_data_stats(entity_id)

    socket
    |> assign(:total_records, stats.total_records)
    |> assign(:published_records, stats.published_records)
    |> assign(:draft_records, stats.draft_records)
    |> assign(:archived_records, stats.archived_records)
  end

  def handle_event("toggle_view_mode", %{"mode" => mode}, socket) do
    params =
      build_url_params(
        socket.assigns.selected_entity_id,
        socket.assigns.selected_status,
        socket.assigns.search_term,
        mode
      )

    path = build_base_path(socket.assigns.selected_entity_id)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      socket
      |> assign(:view_mode, mode)
      |> push_patch(to: Routes.path(full_path, locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("filter_by_entity", %{"entity_id" => ""}, socket) do
    # No entity selected - redirect to entities list since global data view no longer exists
    socket =
      socket
      |> put_flash(:info, gettext("Please select an entity to view its data"))
      |> redirect(to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("filter_by_entity", %{"entity_id" => entity_id}, socket) do
    entity_id = String.to_integer(entity_id)

    params =
      build_url_params(
        entity_id,
        socket.assigns.selected_status,
        socket.assigns.search_term,
        socket.assigns.view_mode
      )

    path = build_base_path(entity_id)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      push_patch(socket, to: Routes.path(full_path, locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("filter_by_status", %{"status" => status}, socket) do
    params =
      build_url_params(
        socket.assigns.selected_entity_id,
        status,
        socket.assigns.search_term,
        socket.assigns.view_mode
      )

    path = build_base_path(socket.assigns.selected_entity_id)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      push_patch(socket, to: Routes.path(full_path, locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("search", %{"search" => %{"term" => term}}, socket) do
    params =
      build_url_params(
        socket.assigns.selected_entity_id,
        socket.assigns.selected_status,
        term,
        socket.assigns.view_mode
      )

    path = build_base_path(socket.assigns.selected_entity_id)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      push_patch(socket, to: Routes.path(full_path, locale: socket.assigns.current_locale_base))

    {:noreply, socket}
  end

  def handle_event("clear_filters", _params, socket) do
    params =
      build_url_params(socket.assigns.selected_entity_id, "all", "", socket.assigns.view_mode)

    path = build_base_path(socket.assigns.selected_entity_id)
    full_path = if params != "", do: "#{path}?#{params}", else: path

    socket =
      push_patch(socket, to: Routes.locale_aware_path(socket.assigns, full_path))

    {:noreply, socket}
  end

  def handle_event("archive_data", %{"id" => id}, socket) do
    data_record = EntityData.get_data!(String.to_integer(id))

    case EntityData.update_data(data_record, %{status: "archived"}) do
      {:ok, _data} ->
        socket =
          socket
          |> apply_filters()
          |> put_flash(:info, gettext("Data record archived successfully"))

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to archive data record"))
        {:noreply, socket}
    end
  end

  def handle_event("restore_data", %{"id" => id}, socket) do
    data_record = EntityData.get_data!(String.to_integer(id))

    case EntityData.update_data(data_record, %{status: "published"}) do
      {:ok, _data} ->
        socket =
          socket
          |> apply_filters()
          |> put_flash(:info, gettext("Data record restored successfully"))

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to restore data record"))
        {:noreply, socket}
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    data_record = EntityData.get_data!(String.to_integer(id))

    new_status =
      case data_record.status do
        "draft" -> "published"
        "published" -> "archived"
        "archived" -> "draft"
      end

    case EntityData.update_data(data_record, %{status: new_status}) do
      {:ok, _updated_data} ->
        socket =
          socket
          |> refresh_data_stats()
          |> apply_filters()
          |> put_flash(
            :info,
            gettext("Status updated to %{status}", status: status_label(new_status))
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to update status"))
        {:noreply, socket}
    end
  end

  ## Live updates

  def handle_info({:entity_created, _entity_id}, socket) do
    {:noreply, refresh_entities_and_data(socket)}
  end

  def handle_info({:entity_updated, entity_id}, socket) do
    # If the currently viewed entity was updated, check if it was archived
    if socket.assigns.selected_entity_id && entity_id == socket.assigns.selected_entity_id do
      entity = Entities.get_entity!(entity_id)

      # If entity was archived or unpublished, redirect to entities list
      if entity.status != "published" do
        {:noreply,
         socket
         |> put_flash(
           :warning,
           gettext("Entity '%{name}' was %{status} in another session.",
             name: entity.display_name,
             status: entity.status
           )
         )
         |> redirect(
           to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base)
         )}
      else
        # Update the selected entity and page title with fresh data
        socket =
          socket
          |> assign(:selected_entity, entity)
          |> assign(:page_title, entity.display_name)
          |> refresh_entities_and_data()

        {:noreply, socket}
      end
    else
      {:noreply, refresh_entities_and_data(socket)}
    end
  end

  def handle_info({:entity_deleted, entity_id}, socket) do
    # If the currently viewed entity was deleted, redirect to entities list
    if socket.assigns.selected_entity_id && entity_id == socket.assigns.selected_entity_id do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Entity was deleted in another session."))
       |> redirect(to: Routes.path("/admin/entities", locale: socket.assigns.current_locale_base))}
    else
      {:noreply, refresh_entities_and_data(socket)}
    end
  end

  def handle_info({event, _entity_id, _data_id}, socket)
      when event in [:data_created, :data_updated, :data_deleted] do
    socket =
      socket
      |> refresh_data_stats()
      |> apply_filters()

    {:noreply, socket}
  end

  # Helper Functions

  defp build_base_path(nil), do: "/admin/entities"

  defp build_base_path(entity_id) when is_integer(entity_id) do
    # Get entity by ID to get its slug
    case Entities.get_entity!(entity_id) do
      nil -> "/admin/entities"
      entity -> "/admin/entities/#{entity.name}/data"
    end
  end

  defp build_url_params(_entity_id, status, search_term, view_mode) do
    params = []

    # Don't include entity_id in query params since it's in the path

    params =
      if status && status != "all" do
        [{"status", status} | params]
      else
        params
      end

    params =
      if search_term && String.trim(search_term) != "" do
        [{"search", search_term} | params]
      else
        params
      end

    params =
      if view_mode && view_mode != "table" do
        [{"view", view_mode} | params]
      else
        params
      end

    URI.encode_query(params)
  end

  defp apply_filters(socket) do
    entity_id = socket.assigns[:selected_entity_id]
    status = socket.assigns[:selected_status] || "all"
    search_term = socket.assigns[:search_term] || ""

    # Start with all data
    entity_data_records = EntityData.list_all_data()

    # Apply entity filter
    entity_data_records =
      if entity_id do
        Enum.filter(entity_data_records, fn record -> record.entity_id == entity_id end)
      else
        entity_data_records
      end

    # Apply status filter
    entity_data_records =
      if status != "all" do
        Enum.filter(entity_data_records, fn record -> record.status == status end)
      else
        entity_data_records
      end

    # Apply search filter
    entity_data_records =
      if String.trim(search_term) != "" do
        search_term_lower = String.downcase(search_term)

        Enum.filter(entity_data_records, fn record ->
          title_match = String.contains?(String.downcase(record.title || ""), search_term_lower)
          slug_match = String.contains?(String.downcase(record.slug || ""), search_term_lower)
          title_match || slug_match
        end)
      else
        entity_data_records
      end

    assign(socket, :entity_data_records, entity_data_records)
  end

  defp refresh_data_stats(socket) do
    stats = EntityData.get_data_stats(socket.assigns.selected_entity_id)

    socket
    |> assign(:total_records, stats.total_records)
    |> assign(:published_records, stats.published_records)
    |> assign(:draft_records, stats.draft_records)
    |> assign(:archived_records, stats.archived_records)
  end

  defp refresh_entities_and_data(socket) do
    socket
    |> assign(:entities, Entities.list_entities())
    |> refresh_data_stats()
    |> apply_filters()
  end

  def status_badge_class(status) do
    case status do
      "published" -> "badge-success"
      "draft" -> "badge-warning"
      "archived" -> "badge-neutral"
      _ -> "badge-outline"
    end
  end

  def status_label(status) do
    case status do
      "published" -> gettext("Published")
      "draft" -> gettext("Draft")
      "archived" -> gettext("Archived")
      _ -> gettext("Unknown")
    end
  end

  def status_icon(status) do
    case status do
      "published" -> "hero-check-circle"
      "draft" -> "hero-pencil"
      "archived" -> "hero-archive-box"
      _ -> "hero-question-mark-circle"
    end
  end

  def get_entity_name(entities, entity_id) do
    case Enum.find(entities, &(&1.id == entity_id)) do
      nil -> gettext("Unknown")
      entity -> entity.display_name
    end
  end

  def get_entity_slug(entities, entity_id) do
    case Enum.find(entities, &(&1.id == entity_id)) do
      nil -> ""
      entity -> entity.name
    end
  end

  def truncate_text(text, length \\ 100)

  def truncate_text(text, length) when is_binary(text) do
    if String.length(text) > length do
      String.slice(text, 0, length) <> "..."
    else
      text
    end
  end

  def truncate_text(_, _), do: ""

  def format_data_preview(data) when is_map(data) do
    # Show first few key-value pairs as preview
    data
    |> Enum.take(3)
    |> Enum.map_join(" • ", fn {key, value} ->
      "#{key}: #{truncate_text(to_string(value), 30)}"
    end)
  end

  def format_data_preview(_), do: ""
end
