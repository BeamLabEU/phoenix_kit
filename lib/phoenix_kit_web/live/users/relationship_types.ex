defmodule PhoenixKitWeb.Live.Users.RelationshipTypes do
  @moduledoc """
  The kinds of link a person can have with an organization (Users -> Relationship types).

  A type says how far someone can go; roles say what they can do there. So this page
  shows what each type allows in words, and how many people have it, rather than the
  flags underneath. Those are fixed once a type exists: see
  `PhoenixKit.Users.RelationshipType`.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.RelationshipType
  alias PhoenixKit.Users.RelationshipTypes
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Relationship types"))
     |> assign(:page_section, gettext("Users"))
     |> assign(:page_section_path, Routes.path("/admin/users"))
     |> assign(:types, [])
     |> assign(:counts, %{})}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    assign(socket,
      types: RelationshipTypes.list_types(),
      counts: RelationshipTypes.link_counts()
    )
  end

  @impl true
  def handle_event("archive", %{"uuid" => uuid}, socket) do
    with_type(socket, uuid, fn type ->
      RelationshipTypes.archive_type(type, actor_uuid: Actor.uuid(socket))
    end)
  end

  def handle_event("restore", %{"uuid" => uuid}, socket) do
    with_type(socket, uuid, fn type ->
      RelationshipTypes.restore_type(type, actor_uuid: Actor.uuid(socket))
    end)
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with_type(socket, uuid, fn type ->
      RelationshipTypes.delete_type(type, actor_uuid: Actor.uuid(socket))
    end)
  end

  def handle_event("move", %{"uuid" => uuid, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    uuids = Enum.map(socket.assigns.types, & &1.uuid)

    case Enum.find_index(uuids, &(&1 == uuid)) do
      nil ->
        {:noreply, socket}

      index ->
        other = if direction == "up", do: index - 1, else: index + 1
        RelationshipTypes.reorder(swap(uuids, index, other))
        {:noreply, load(socket)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp swap(list, index, other) when other < 0 or other >= length(list) or index == other,
    do: list

  defp swap(list, index, other) do
    list
    |> List.replace_at(index, Enum.at(list, other))
    |> List.replace_at(other, Enum.at(list, index))
  end

  defp with_type(socket, uuid, fun) do
    case RelationshipTypes.get_type(uuid) do
      %RelationshipType{} = type ->
        case fun.(type) do
          {:ok, _} -> {:noreply, load(socket)}
          {:error, reason} -> {:noreply, socket |> put_flash(:error, message(reason)) |> load()}
        end

      nil ->
        {:noreply, load(socket)}
    end
  end

  defp message(:in_use),
    do: gettext("This type is in use, so it can only be archived.")

  defp message(:builtin), do: gettext("A built-in type cannot be deleted.")
  defp message(_reason), do: gettext("That change is not available.")

  defp ability(%RelationshipType{can_manage: true}),
    do: gettext("Act for an organization and manage its people and profile")

  defp ability(%RelationshipType{}),
    do: gettext("Act for an organization, but not manage it")

  # `manager` is what every grant has been; a site cannot do without it.
  defp archivable?(%RelationshipType{key: "manager"}), do: false
  defp archivable?(%RelationshipType{status: status}), do: status == "active"

  defp deletable?(%RelationshipType{builtin: true}, _count), do: false
  defp deletable?(%RelationshipType{}, count), do: count == 0

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      page_title={@page_title}
      page_section={@page_section}
      page_section_path={@page_section_path}
      current_path={Routes.path("/admin/users/relationship-types")}
    >
      <div class="max-w-3xl mx-auto px-4 py-6 space-y-5">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <p class="text-base-content/70 max-w-xl">
            {gettext(
              "How a person can be connected to an organization. A type says how far they can go; the roles on their link say what they can do there."
            )}
          </p>
          <.pk_link_button
            navigate="/admin/users/relationship-types/new"
            variant="primary"
            class="btn-sm"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("New type")}
          </.pk_link_button>
        </div>

        <div class="card bg-base-100 shadow-sm">
          <div class="card-body py-2">
            <div
              :for={{type, index} <- Enum.with_index(@types)}
              id={"relationship-type-#{type.uuid}"}
              class="border-b border-base-300 py-3 last:border-b-0 flex flex-wrap items-start justify-between gap-3"
            >
              <div class="min-w-0 space-y-1">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-medium">{RelationshipTypes.name(type)}</span>
                  <span :if={type.status == "archived"} class="badge badge-sm badge-ghost">
                    {gettext("Archived")}
                  </span>
                </div>
                <div class="text-sm text-base-content/70">{ability(type)}</div>
                <div class="text-xs opacity-60">
                  {ngettext("%{count} person", "%{count} people", Map.get(@counts, type.uuid, 0),
                    count: Map.get(@counts, type.uuid, 0)
                  )}
                </div>
              </div>
              <div class="flex flex-wrap items-center gap-1">
                <button
                  type="button"
                  class="btn btn-sm btn-ghost btn-square"
                  phx-click="move"
                  phx-value-uuid={type.uuid}
                  phx-value-direction="up"
                  disabled={index == 0}
                  aria-label={gettext("Move up")}
                >
                  <.icon name="hero-arrow-up" class="w-4 h-4" />
                </button>
                <button
                  type="button"
                  class="btn btn-sm btn-ghost btn-square"
                  phx-click="move"
                  phx-value-uuid={type.uuid}
                  phx-value-direction="down"
                  disabled={index == length(@types) - 1}
                  aria-label={gettext("Move down")}
                >
                  <.icon name="hero-arrow-down" class="w-4 h-4" />
                </button>
                <.pk_link_button
                  navigate={"/admin/users/relationship-types/#{type.uuid}/edit"}
                  variant="outline"
                  class="btn-sm"
                >
                  {gettext("Edit")}
                </.pk_link_button>
                <button
                  :if={archivable?(type)}
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="archive"
                  phx-value-uuid={type.uuid}
                  data-confirm={
                    gettext("Archive this type? People who have it keep it; nobody new can get it.")
                  }
                >
                  {gettext("Archive")}
                </button>
                <button
                  :if={type.status == "archived"}
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="restore"
                  phx-value-uuid={type.uuid}
                >
                  {gettext("Restore")}
                </button>
                <button
                  :if={deletable?(type, Map.get(@counts, type.uuid, 0))}
                  type="button"
                  class="btn btn-sm btn-ghost text-error"
                  phx-click="delete"
                  phx-value-uuid={type.uuid}
                  data-confirm={gettext("Delete this type?")}
                >
                  {gettext("Delete")}
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
