defmodule PhoenixKit.Modules.Entities.Web.Entities do
  @moduledoc """
  LiveView for listing and managing all entities.
  Provides interface for viewing, publishing, and deleting entity schemas.
  """

  use PhoenixKitWeb, :live_view
  on_mount PhoenixKit.Modules.Entities.Web.Hooks

  alias PhoenixKit.Modules.Entities
  alias PhoenixKit.Settings

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, gettext("Entities"))
      |> assign(:project_title, project_title)
      |> assign(:view_mode, "table")
      |> assign(:entities, Entities.list_entities())

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    view_mode = Map.get(params, "view", "table")

    socket =
      socket
      |> assign(:view_mode, view_mode)

    {:noreply, socket}
  end

  def handle_event("toggle_view_mode", %{"mode" => mode}, socket) do
    base_path = current_base_path(socket)
    query = if mode != "table", do: "?view=#{mode}", else: ""

    {:noreply, push_patch(socket, to: "#{base_path}#{query}")}
  end

  def handle_event("archive_entity", %{"uuid" => uuid}, socket) do
    entity = Entities.get_entity!(uuid)

    case Entities.update_entity(entity, %{status: "archived"}) do
      {:ok, _entity} ->
        socket =
          socket
          |> assign(:entities, Entities.list_entities())
          |> put_flash(
            :info,
            gettext("Entity '%{name}' archived successfully", name: entity.display_name)
          )

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to archive entity"))}
    end
  end

  def handle_event("restore_entity", %{"uuid" => uuid}, socket) do
    entity = Entities.get_entity!(uuid)

    case Entities.update_entity(entity, %{status: "published"}) do
      {:ok, _entity} ->
        socket =
          socket
          |> assign(:entities, Entities.list_entities())
          |> put_flash(
            :info,
            gettext("Entity '%{name}' restored successfully", name: entity.display_name)
          )

        {:noreply, socket}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to restore entity"))}
    end
  end

  ## Live updates

  def handle_info({event, _entity_id}, socket)
      when event in [:entity_created, :entity_updated, :entity_deleted] do
    {:noreply, assign(socket, :entities, Entities.list_entities())}
  end

  # Helper Functions

  # Extracts the base path (without query string) from the current URL,
  # which already includes the correct locale and prefix segments.
  defp current_base_path(socket) do
    (socket.assigns[:url_path] || "") |> URI.parse() |> Map.get(:path) || "/"
  end
end
