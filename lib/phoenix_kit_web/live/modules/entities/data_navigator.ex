defmodule PhoenixKitWeb.Live.Modules.Entities.DataNavigator do
  @moduledoc """
  LiveView for browsing and managing entity data records.
  Provides table view with pagination, search, filtering, and bulk operations.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.EntityData
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

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
      |> assign(:current_locale, locale)
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

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    # Get entity from slug in params (entity_slug or entity_id for backwards compat)
    {entity, entity_id} =
      case params["entity_slug"] || params["entity_id"] do
        nil ->
          {socket.assigns.selected_entity, socket.assigns.selected_entity_id}

        "" ->
          {nil, nil}

        slug when is_binary(slug) ->
          case Entities.get_entity_by_name(slug) do
            nil -> {nil, nil}
            entity -> {entity, entity.id}
          end
      end

    # Recalculate stats if entity changed
    socket =
      if entity_id != socket.assigns.selected_entity_id do
        stats = EntityData.get_data_stats(entity_id)

        socket
        |> assign(:total_records, stats.total_records)
        |> assign(:published_records, stats.published_records)
        |> assign(:draft_records, stats.draft_records)
        |> assign(:archived_records, stats.archived_records)
      else
        socket
      end

    status = params["status"] || "all"
    search_term = params["search"] || ""
    view_mode = params["view"] || socket.assigns.view_mode

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

  def handle_event("toggle_view_mode", %{"mode" => mode}, socket) do
    params =
      build_url_params(
        socket.assigns.selected_entity_id,
        socket.assigns.selected_status,
        socket.assigns.search_term,
        mode
      )

    path = build_base_path(socket.assigns.selected_entity_id)
    locale = socket.assigns[:current_locale] || "en"

    socket =
      push_patch(socket, to: Routes.path("#{path}?#{params}", locale: locale))

    {:noreply, socket}
  end

  def handle_event("filter_by_entity", %{"entity_id" => ""}, socket) do
    params =
      build_url_params(
        nil,
        socket.assigns.selected_status,
        socket.assigns.search_term,
        socket.assigns.view_mode
      )

    path = build_base_path(nil)
    locale = socket.assigns[:current_locale] || "en"

    socket =
      push_patch(socket, to: Routes.path("#{path}?#{params}", locale: locale))

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
    locale = socket.assigns[:current_locale] || "en"

    socket =
      push_patch(socket, to: Routes.path("#{path}?#{params}", locale: locale))

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
    locale = socket.assigns[:current_locale] || "en"

    socket =
      push_patch(socket, to: Routes.path("#{path}?#{params}", locale: locale))

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
    locale = socket.assigns[:current_locale] || "en"

    socket =
      push_patch(socket, to: Routes.path("#{path}?#{params}", locale: locale))

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
        # Refresh data list
        entity_data_records = EntityData.list_all_data()
        stats = EntityData.get_data_stats()

        socket =
          socket
          |> assign(:entity_data_records, entity_data_records)
          |> assign(:published_records, stats.published_records)
          |> assign(:draft_records, stats.draft_records)
          |> assign(:archived_records, stats.archived_records)
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

  # Helper Functions

  defp build_base_path(nil), do: "/admin/entities/data"

  defp build_base_path(entity_id) when is_integer(entity_id) do
    # Get entity by ID to get its slug
    case Entities.get_entity!(entity_id) do
      nil -> "/admin/entities/data"
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
