defmodule PhoenixKitWeb.Live.Components.UserMediaSelectorModal do
  @moduledoc """
  User-scoped media selector modal.

  A thin wrapper around `MediaSelectorModal` that automatically filters to only
  show media files owned by the current user. Use this for user-facing pages
  where users should only see and select their own uploads.

  ## Usage

      <.live_component
        module={PhoenixKitWeb.Live.Components.UserMediaSelectorModal}
        id="user-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        selected_uuids={@media_selected_uuids}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />

  ## Optional assigns

    * `on_select` — `{module, id, action}` tuple. When provided, selection results
      are sent via `send_update(module, %{id: id, action: action, file_uuid: uuid})`
      instead of `send(self(), {:media_selected, uuids})`. This allows embedding
      inside LiveComponents without requiring the parent LiveView to forward messages.

  All other assigns are passed through to `MediaSelectorModal`, with `user_uuid`
  automatically injected from `phoenix_kit_current_user`.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  @impl true
  def update(assigns, socket) do
    user_uuid =
      case assigns[:phoenix_kit_current_user] do
        %{uuid: uuid} -> uuid
        _ -> nil
      end

    # Store on_select callback before delegating (MediaSelectorModal won't touch it)
    socket =
      if assigns[:on_select] do
        assign(socket, :on_select, assigns[:on_select])
      else
        assign_new(socket, :on_select, fn -> nil end)
      end

    assigns = Map.put(assigns, :user_uuid, user_uuid)

    MediaSelectorModal.update(assigns, socket)
  end

  @impl true
  def render(assigns) do
    MediaSelectorModal.render(assigns)
  end

  @impl true
  def handle_event("confirm_selection", _params, socket) do
    selected_uuids = socket.assigns.selected_uuids |> MapSet.to_list()

    case socket.assigns[:on_select] do
      {module, id, action} ->
        file_uuid = List.first(selected_uuids)

        if file_uuid do
          send_update(module, %{id: id, action: action, file_uuid: file_uuid})
        end

      _ ->
        send(self(), {:media_selected, selected_uuids})
    end

    {:noreply, assign(socket, :show, false)}
  end

  def handle_event("close_modal", _params, socket) do
    case socket.assigns[:on_select] do
      {module, id, _action} ->
        send_update(module, %{id: id, action: :avatar_selector_closed})

      _ ->
        send(self(), {:media_selector_closed})
    end

    {:noreply, assign(socket, :show, false)}
  end

  def handle_event(event, params, socket) do
    MediaSelectorModal.handle_event(event, params, socket)
  end
end
