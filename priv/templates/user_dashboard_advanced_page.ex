defmodule <%= @web_module_prefix %>.PhoenixKit.Advanced.Dashboard.<%= @page_name %> do
  @moduledoc """
  User dashboard LiveView for <%= @page_title %>.
  """

  use <%= @web_module_prefix %>, :live_view

  alias PhoenixKit.Utils.Widget
  alias PhoenixKit.Dashboard.Widget.Layout

  import PhoenixKitWeb.LayoutHelpers, only: [dashboard_assigns: 1]
  import PhoenixKitWeb.Components.Core.UserDashboardHeader,
    only: [user_dashboard_header: 1]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.phoenix_kit_current_user

socket =
  assign(socket,
    show_sidebar: true
  )

    socket =
      socket
      |> assign(
        page_title: @page_title,
        widgets: Layout.widgets_for(user),
        available: Widget.load_all_widgets(user),
        selected: MapSet.new()
      )

    {:ok, socket}
  end

  def handle_event("toggle_sidebar", _, socket) do
  new_state = !socket.assigns.show_sidebar

  socket =
    socket
    |> assign(:show_sidebar, new_state)
#    |> put_session(:dashboard_sidebar_open, new_state)

  {:noreply, socket}
end

  def handle_event("remove_widget", %{"uuid" => uuid}, socket) do
    Layout.remove_widget(socket.assigns.phoenix_kit_current_user, uuid)

    {:noreply,
     assign(socket,
       widgets: Layout.widgets_for(socket.assigns.current_user),
       available: Widget.load_all_widgets(socket.assigns.current_user)
     )}
  end

  def handle_event("save_grid", %{"items" => items}, socket) do

   layouts =
    Enum.map(items, fn item ->
      %{
        user_uuid: socket.assigns.phoenix_kit_current_user.uuid,
        uuid: item["uuid"],
        x: parse_int(item["x"]),
        y: parse_int(item["y"]),
        w: parse_int(item["w"], 3),
        h: parse_int(item["h"], 2),
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
    end)

  case Layout.save_grid(socket.assigns.phoenix_kit_current_user, items) do
    :ok ->
      {:noreply, socket}

    {:error, _reason} ->
      {:noreply, put_flash(socket, :error, "Failed to save layout")}
  end

    {:noreply, socket}
  end

def handle_event("toggle_sidebar", _, socket) do
  new_state = !socket.assigns.show_sidebar

  socket =
    socket
    |> assign(:show_sidebar, new_state)

  {:noreply, socket}
end

  def handle_event("drop_widget", %{"uuid" => uuid, "x" => x, "y" => y}, socket) do
    user = socket.assigns.phoenix_kit_current_user

    {:ok, _widget} =
     Layout.add_widget(user, uuid, %{x: x, y: y})

    {:noreply,
     assign(socket,
       widgets: Widget.widgets_for(user),
       available: Widget.load_all_widgets(user)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="flex max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 gap-6">

        <!-- MAIN CONTENT -->
        <div class="flex-1 min-w-0">
          <.user_dashboard_header
            title={@page_title}
            subtitle={@description}
          />

          <!-- GRID -->
          <div id="grid_container" class="grid-stack mt-4" phx-hook="Grid">
            <%= for w <- @widgets do %>
              <div
                id={"widget-#{w.uuid}"}
                class="grid-stack-item"
                data-uuid={w.uuid}
                phx-hook="ContextMenu"
                gs-x={w.x}
                gs-y={w.y}
                gs-w={w.w}
                gs-h={w.h}
              >
                <div class="grid-stack-item-content">
                  <.dashboard_stack item={w} />
                </div>
              </div>
            <% end %>
          </div>
        </div>
    <div :if={Enum.count(@available) > 0}>
        <!-- Toggle Button -->
       <div class={[
          "w-80 shrink-0 transition-all duration-300",
          @show_sidebar && "translate-x-0",
          !@show_sidebar && "translate-x-0 lg:translate-x-0"
        ]} :if={!@show_sidebar}>
     <button class="btn btn-xs btn-ghost" phx-click="toggle_sidebar">
                    ☰
                  </button>
                </div>
        <!-- RIGHT GUTTER -->
        <div class={[
          "w-80 shrink-0 transition-all duration-300",
          @show_sidebar && "translate-x-0",
          !@show_sidebar && "translate-x-0 lg:translate-x-0"
        ]}>

          <div class="sticky top-4">
            <div class="card bg-base-100 shadow-md border border-base-300">
              <div class="card-body p-4">

                <!-- Header -->
                <div class="flex items-center justify-between mb-2">
                  <h3 class="font-semibold text-base">Available Widgets</h3>

                  <button
                    class="btn btn-xs btn-ghost"
                    phx-click="toggle_sidebar"
                  >
                    →
                  </button>
                </div>

                <!-- Widget List (DRAG SOURCE) -->
                <div class="space-y-2 max-h-[500px] overflow-y-auto">

                  <%= for w <- @available do %>
                    <div
                      class="flex items-center justify-between p-2 rounded-lg hover:bg-base-200 transition cursor-grab"
                      data-widget-uuid={w.uuid}
                      data-widget-title={w.title}
                    >
                      <div>
                        <div class="font-medium text-sm">
                          <%= w.title %>
                        </div>
                        <div class="text-xs opacity-60">
                          <%= w.description %>
                        </div>
                      </div>

                      <button
                        class="btn btn-xs btn-primary"
                        phx-click="add_widget"
                        phx-value-widget={w.uuid}
                      >
                        Add
                      </button>
                    </div>
                  <% end %>

                </div>

              </div>
            </div>
          </div>
        </div>

      </div>
      </div>

      <!-- MOBILE FLOAT BUTTON -->
      <button
        class="fixed bottom-6 right-6 btn btn-primary btn-circle shadow-lg lg:hidden"
        phx-click="toggle_sidebar"
      >
        +
      </button>

    </PhoenixKitWeb.Layouts.dashboard>
    """
  end

  defp dashboard_stack(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm border border-base-300 h-full">
      <div class="card-body p-3">
        <div class="flex items-center justify-between">
          <span class="font-semibold text-sm">
            <%= @item.title %>
          </span>

          <button
            class="btn btn-xs btn-ghost"
            phx-click="remove_widget"
            phx-value-uuid={@item.uuid}
          >
            ×
          </button>
        </div>

        <div class="text-xs opacity-60 mt-2">
          <%= @item.description %>
        </div>
      </div>
    </div>
    """
  end
end