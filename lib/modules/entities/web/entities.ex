defmodule PhoenixKit.Modules.Entities.Web.Entities do
  @moduledoc """
  LiveView for listing and managing all entities.
  Provides interface for viewing, publishing, and deleting entity schemas.
  """

  use PhoenixKitWeb, :live_view
  on_mount PhoenixKit.Modules.Entities.Web.Hooks

  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    project_title = Settings.get_project_title()

    stats = Entities.get_system_stats()

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, gettext("Entities"))
      |> assign(:project_title, project_title)
      |> assign(:total_entities, stats.total_entities)
      |> assign(:active_entities, stats.active_entities)
      |> assign(:total_data_records, stats.total_data_records)
      |> assign(:selected_status, "all")
      |> assign(:search_term, "")
      |> assign(:view_mode, "table")
      |> apply_filters()

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    status = Map.get(params, "status", "all")
    search_term = Map.get(params, "search", "")
    view_mode = Map.get(params, "view", "table")

    socket =
      socket
      |> assign(:selected_status, status)
      |> assign(:search_term, search_term)
      |> assign(:view_mode, view_mode)
      |> apply_filters()

    {:noreply, socket}
  end

  def handle_event("toggle_view_mode", %{"mode" => mode}, socket) do
    params = build_url_params(socket.assigns.selected_status, socket.assigns.search_term, mode)

    socket =
      socket
      |> push_patch(
        to: Routes.path("/admin/entities#{params}", locale: socket.assigns.current_locale_base)
      )

    {:noreply, socket}
  end

  def handle_event("filter_by_status", %{"status" => status}, socket) do
    params = build_url_params(status, socket.assigns.search_term, socket.assigns.view_mode)

    socket =
      socket
      |> push_patch(
        to: Routes.path("/admin/entities#{params}", locale: socket.assigns.current_locale_base)
      )

    {:noreply, socket}
  end

  def handle_event("search", %{"search" => %{"term" => term}}, socket) do
    params = build_url_params(socket.assigns.selected_status, term, socket.assigns.view_mode)

    socket =
      socket
      |> push_patch(
        to: Routes.path("/admin/entities#{params}", locale: socket.assigns.current_locale_base)
      )

    {:noreply, socket}
  end

  def handle_event("clear_filters", _params, socket) do
    params = build_url_params("all", "", socket.assigns.view_mode)

    socket =
      socket
      |> push_patch(
        to: Routes.path("/admin/entities#{params}", locale: socket.assigns.current_locale_base)
      )

    {:noreply, socket}
  end

  def handle_event("archive_entity", %{"uuid" => uuid}, socket) do
    entity = Entities.get_entity!(uuid)

    # Update entity status to archived
    case Entities.update_entity(entity, %{status: "archived"}) do
      {:ok, _entity} ->
        entities = Entities.list_entities()
        stats = Entities.get_system_stats()

        socket =
          socket
          |> assign(:entities, entities)
          |> assign(:total_entities, stats.total_entities)
          |> assign(:active_entities, stats.active_entities)
          |> assign(:total_data_records, stats.total_data_records)
          |> put_flash(
            :info,
            gettext("Entity '%{name}' archived successfully", name: entity.display_name)
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to archive entity"))
        {:noreply, socket}
    end
  end

  def handle_event("restore_entity", %{"uuid" => uuid}, socket) do
    entity = Entities.get_entity!(uuid)

    # Restore entity status to published
    case Entities.update_entity(entity, %{status: "published"}) do
      {:ok, _entity} ->
        entities = Entities.list_entities()
        stats = Entities.get_system_stats()

        socket =
          socket
          |> assign(:entities, entities)
          |> assign(:total_entities, stats.total_entities)
          |> assign(:active_entities, stats.active_entities)
          |> assign(:total_data_records, stats.total_data_records)
          |> put_flash(
            :info,
            gettext("Entity '%{name}' restored successfully", name: entity.display_name)
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to restore entity"))
        {:noreply, socket}
    end
  end

  ## Live updates

  def handle_info({event, _entity_id}, socket)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    socket =
      socket
      |> refresh_entity_stats()
      |> apply_filters()

    {:noreply, socket}
  end

  # Helper Functions

  defp build_url_params(status, search_term, view_mode) do
    params = []

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

    case URI.encode_query(params) do
      "" -> ""
      query -> "?#{query}"
    end
  end

  defp apply_filters(socket) do
    status = socket.assigns[:selected_status] || "all"
    search_term = socket.assigns[:search_term] || ""

    # Start with all entities
    entities = Entities.list_entities()

    # Apply status filter
    entities =
      if status != "all" do
        Enum.filter(entities, fn entity -> entity.status == status end)
      else
        entities
      end

    # Apply search filter
    entities =
      if String.trim(search_term) != "" do
        search_term_lower = String.downcase(search_term)

        Enum.filter(entities, fn entity ->
          name_match = String.contains?(String.downcase(entity.name || ""), search_term_lower)

          display_name_match =
            String.contains?(String.downcase(entity.display_name || ""), search_term_lower)

          name_match || display_name_match
        end)
      else
        entities
      end

    assign(socket, :entities, entities)
  end

  defp refresh_entity_stats(socket) do
    stats = Entities.get_system_stats()

    socket
    |> assign(:total_entities, stats.total_entities)
    |> assign(:active_entities, stats.active_entities)
    |> assign(:total_data_records, stats.total_data_records)
  end
end
