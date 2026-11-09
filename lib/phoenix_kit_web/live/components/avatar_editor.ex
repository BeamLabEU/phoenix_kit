defmodule PhoenixKitWeb.Live.Components.AvatarEditor do
  @moduledoc """
  A person's avatar and the controls to change it. "Browse" picks a
  picture and opens the crop editor on it straight away; "Adjust Crop" and
  "Reset" change the framing later. The profile settings (`UserSettings`) and
  the admin's user form both render this component, so the person and an
  admin get the same controls.

  The crop is data, never pixels (`PhoenixKit.Users.AvatarCrop`). Every save
  is written at once through `Auth.update_user_fields/2`, which also drops the
  old picture's crop when the file changes. Everything is drawn in the site's
  avatar shape (`PhoenixKit.Users.AvatarShape`), and the zoom goes from where
  the whole picture fits inside that shape (a wide logo shown whole, on white)
  up to 8×.

  ## Usage

      <.live_component
        module={PhoenixKitWeb.Live.Components.AvatarEditor}
        id="user-avatar"
        user={@user}
        actor={@phoenix_kit_current_user}
        picker={:media}
      />

      def handle_info({PhoenixKitWeb.Live.Components.AvatarEditor, "user-avatar", result}, socket) do
        case result do
          {:saved, user, message} -> {:noreply, socket |> assign(:user, user) |> put_flash(:info, message)}
          {:failed, message} -> {:noreply, put_flash(socket, :error, message)}
        end
      end

  ## Attrs

    * `id` — required. The DOM ids inside are derived from it.
    * `user` — required. Whose avatar it is. The component draws the `user` it
      is handed, so the host passes the saved user back after each save.
    * `actor` — who makes the change; defaults to `user`. When it is someone
      else, the activity entry names them and the person is notified.
    * `picker` — `:own` (default) picks from the actor's own uploads
      (`UserMediaSelectorModal`). `:media` picks from the site's media
      library, with new uploads placed by the `PhoenixKit.UploadsParentFolder`
      hook: for an admin choosing for someone else.
    * `notify` — `{module, id}` of a LiveComponent to tell about each save,
      with `send_update(module, id: id, avatar_editor: result)`. Without it the
      LiveView gets `{PhoenixKitWeb.Live.Components.AvatarEditor, id, result}`.
    * `class` — extra classes for the root element.

  `result` is `{:saved, user, message}` or `{:failed, message}`, where
  `message` is translated text for the page to show.

  ## Inside a form

  The component may sit inside the host's `<form>`. The picker carries a form
  of its own, so it is teleported to `<body>` while open. The crop dialog stays
  inside the component (its close events go to the component that holds it),
  and its zoom slider is detached from the surrounding form, so moving it
  sends the host form no change events.

  ## Staff

  Someone acting for a company through a link that does not manage it
  (`ActingLink.staff?/1`) does not change the company's avatar: every event
  is refused for them, read from the link each time.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.ActingLink
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.AvatarCrop
  alias PhoenixKit.Users.AvatarShape
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal
  alias PhoenixKitWeb.Live.Components.UserMediaSelectorModal

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       show_picker: false,
       show_crop: false,
       pending_crop: nil,
       pending_uuid: nil,
       scope_folder: nil
     )}
  end

  # A pick does not set the avatar on the spot: the crop editor opens on the
  # picked image first, so the picture is framed once instead of
  # set-then-crop. Save without touching anything accepts the default fit;
  # Cancel discards the pick and the old avatar never changed.
  @impl true
  def update(%{action: :set_avatar, file_uuid: file_uuid}, socket),
    do: {:ok, open_crop_on_pick(socket, file_uuid)}

  def update(%{action: :avatar_selector_closed}, socket),
    do: {:ok, assign(socket, :show_picker, false)}

  def update(%{media_selected: [file_uuid | _]}, socket) when is_binary(file_uuid),
    do: {:ok, open_crop_on_pick(socket, file_uuid)}

  def update(%{media_selected: _}, socket), do: {:ok, assign(socket, :show_picker, false)}

  def update(%{media_selector_closed: true}, socket),
    do: {:ok, assign(socket, :show_picker, false)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(:id, assigns.id)
     |> assign(:user, assigns.user)
     |> assign(:actor, Map.get(assigns, :actor) || assigns.user)
     |> assign(:picker, Map.get(assigns, :picker, :own))
     |> assign(:notify, Map.get(assigns, :notify))
     |> assign(:class, Map.get(assigns, :class))
     |> assign(:shape, AvatarShape.current())}
  end

  defp open_crop_on_pick(socket, file_uuid) do
    assign(socket,
      show_picker: false,
      pending_uuid: file_uuid,
      pending_crop: nil,
      show_crop: true
    )
  end

  @impl true
  def handle_event(event, params, socket) do
    if ActingLink.staff?(socket.assigns.user),
      do: {:noreply, socket},
      else: handle(event, params, socket)
  end

  defp handle("open_avatar_selector", _params, socket) do
    {:noreply, socket |> assign_scope_folder() |> assign(:show_picker, true)}
  end

  defp handle("open_avatar_crop", _params, socket) do
    # A stale click can arrive after the avatar was removed. With no file
    # there is nothing to crop, and the dialog would sign a nil uuid.
    if avatar_uuid(socket.assigns.user) do
      {:noreply,
       assign(socket,
         show_crop: true,
         pending_uuid: nil,
         pending_crop: AvatarCrop.from_user(socket.assigns.user)
       )}
    else
      {:noreply, socket}
    end
  end

  defp handle("close_avatar_crop", _params, socket), do: {:noreply, close_crop(socket)}

  # Pushed by the AvatarCrop hook at the end of every gesture (drag release,
  # zoom change), so Save keeps what the person is looking at.
  defp handle("avatar_crop_changed", params, socket) do
    {:noreply, assign(socket, :pending_crop, AvatarCrop.normalize(params))}
  end

  defp handle("save_avatar_crop", _params, socket) do
    # An untouched editor saves no crop at all: the default fit is the
    # uncropped avatar (AvatarCrop.drop_identity/1), on both paths.
    crop = socket.assigns.pending_crop && AvatarCrop.drop_identity(socket.assigns.pending_crop)

    cond do
      uuid = socket.assigns.pending_uuid ->
        {:noreply, save_new_avatar(socket, uuid, crop)}

      socket.assigns.pending_crop ->
        {:noreply, save_crop(socket, crop, gettext("Avatar crop updated!"))}

      true ->
        {:noreply, close_crop(socket)}
    end
  end

  # Back to the uncropped avatar. A nil, not a removed key: custom fields are
  # merged, and a merged nil reads as "no crop" everywhere.
  defp handle("reset_avatar_crop", _params, socket) do
    {:noreply, save_crop(socket, nil, gettext("Avatar crop reset."))}
  end

  # Resolved when the picker opens: the host's hook may create a folder.
  defp assign_scope_folder(%{assigns: %{picker: :media}} = socket) do
    %{actor: actor, user: user} = socket.assigns

    assign(
      socket,
      :scope_folder,
      PhoenixKit.UploadsParentFolder.resolve(:avatar, actor.uuid, user)
    )
  end

  defp assign_scope_folder(socket), do: socket

  defp save_new_avatar(socket, file_uuid, crop) do
    user = socket.assigns.user

    save(
      socket,
      %{"avatar_file_uuid" => file_uuid, "avatar_crop" => crop},
      "user.avatar_changed",
      %{
        "avatar_from" => avatar_uuid(user) || "",
        "avatar_to" => file_uuid,
        "cropped" => crop != nil
      },
      gettext("Avatar updated successfully!"),
      gettext("Failed to update avatar")
    )
  end

  defp save_crop(socket, crop, message) do
    save(
      socket,
      %{"avatar_crop" => crop},
      "user.avatar_crop_changed",
      %{"cropped" => crop != nil},
      message,
      gettext("Failed to update avatar crop")
    )
  end

  defp save(socket, attrs, action, metadata, message, failure) do
    %{user: user, actor: actor} = socket.assigns

    case Auth.update_user_fields(user, attrs) do
      {:ok, updated_user} ->
        log(action, updated_user, actor, metadata)

        socket
        |> assign(:user, updated_user)
        |> close_crop()
        |> report({:saved, updated_user, message})

      {:error, _changeset} ->
        socket
        |> close_crop()
        |> report({:failed, failure})
    end
  end

  # Someone else's change names them and tells the person (a target is what
  # sends a notification); the person's own change has no target.
  defp log(action, user, actor, metadata) do
    by_other? = actor.uuid != user.uuid

    PhoenixKit.Activity.log(%{
      action: action,
      module: "users",
      mode: "manual",
      actor_uuid: actor.uuid,
      acting_user_uuid: Map.get(actor, :acting_user_uuid),
      resource_type: "user",
      resource_uuid: user.uuid,
      target_uuid: if(by_other?, do: user.uuid),
      metadata: Map.put(metadata, "actor_role", if(by_other?, do: "admin", else: "user"))
    })
  end

  defp report(socket, result) do
    case socket.assigns.notify do
      {module, id} -> send_update(module, id: id, avatar_editor: result)
      _ -> send(self(), {__MODULE__, socket.assigns.id, result})
    end

    socket
  end

  defp close_crop(socket) do
    assign(socket, show_crop: false, pending_crop: nil, pending_uuid: nil)
  end

  defp avatar_uuid(%{custom_fields: %{"avatar_file_uuid" => uuid}}) when is_binary(uuid),
    do: uuid

  defp avatar_uuid(_user), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :avatar_uuid, avatar_uuid(assigns.user))

    ~H"""
    <div id={@id} class={["flex flex-col items-center gap-2", @class]}>
      <%!-- The "xl" size loads the medium (800px) variant into the 160px
           circle, and applies the stored crop. --%>
      <.user_avatar
        user={@user}
        size="xl"
        shape={@shape}
        class={if AvatarShape.masked?(@shape), do: "", else: "border-2 border-primary"}
      />
      <button
        type="button"
        id={"#{@id}-browse"}
        phx-click="open_avatar_selector"
        phx-target={@myself}
        class="btn btn-primary w-40"
        title={gettext("Browse Media")}
      >
        <.icon name="hero-photo" class="w-5 h-5" /> {gettext("Browse")}
      </button>
      <button
        :if={@avatar_uuid}
        type="button"
        id={"#{@id}-crop-open"}
        phx-click="open_avatar_crop"
        phx-target={@myself}
        class="btn btn-ghost btn-sm w-40"
      >
        <.icon name="hero-viewfinder-circle" class="w-4 h-4" /> {gettext("Adjust Crop")}
      </button>

      <%!-- The picker carries a <form> of its own and this component may sit
           in the host's form: nested forms are invalid, so the picker is
           teleported to <body>, mounted only while open. --%>
      <.portal :if={@show_picker} id={"#{@id}-portal"} target="body">
        <.live_component
          :if={@picker == :media}
          module={MediaSelectorModal}
          id={"#{@id}-media-selector"}
          show={true}
          mode={:single}
          file_type_filter={:image}
          lock_file_type
          title={gettext("Select Avatar")}
          selected_uuids={List.wrap(@avatar_uuid)}
          phoenix_kit_current_user={@actor}
          scope_folder_id={@scope_folder}
          notify={{__MODULE__, @id}}
        />
        <.live_component
          :if={@picker != :media}
          module={UserMediaSelectorModal}
          id={"#{@id}-media-selector"}
          show={true}
          mode={:single}
          file_type_filter={:image}
          lock_file_type
          title={gettext("Select Avatar")}
          selected_uuids={[]}
          phoenix_kit_current_user={@actor}
          on_select={{__MODULE__, @id, :set_avatar}}
        />
      </.portal>

      <%!-- Non-destructive crop editor. Drag to position, slider or wheel to
           zoom: the AvatarCrop hook previews with the same math the avatar
           component renders with, and the original image is never touched. --%>
      <.modal
        :if={@show_crop}
        show={@show_crop}
        on_close="close_avatar_crop"
        id={"#{@id}-crop-modal"}
        max_width="md"
      >
        <:title>{gettext("Adjust Avatar Crop")}</:title>
        <div
          id={"#{@id}-crop-editor"}
          phx-hook="AvatarCrop"
          phx-target={@myself}
          phx-update="ignore"
          data-crop={Phoenix.json_library().encode!(@pending_crop || %{})}
          data-max-zoom={AvatarCrop.max_zoom()}
          data-fit={AvatarShape.fit(@shape)}
          class="flex flex-col items-center gap-4 py-2"
        >
          <%!-- Framed in the site's shape. The outline is the same shape a
               little larger behind it: a ring would be masked away. --%>
          <div class="relative w-64 h-64">
            <div class={["absolute -inset-1 bg-primary", AvatarShape.class(@shape)]}></div>
            <div
              data-crop-frame
              class={[
                "relative w-64 h-64 overflow-hidden bg-white cursor-grab touch-none select-none",
                AvatarShape.class(@shape)
              ]}
            >
              <img
                data-crop-img
                src={URLSigner.signed_url(@pending_uuid || @avatar_uuid, "large")}
                alt=""
                draggable="false"
                class="absolute max-w-none pointer-events-none"
              />
            </div>
          </div>
          <div class="flex items-center gap-3 w-64">
            <.icon name="hero-magnifying-glass-minus" class="w-4 h-4 opacity-60" />
            <%!-- `form` names no form, so a host form around this component
                 gets no change events from the slider. --%>
            <input
              data-crop-zoom
              form={"#{@id}-crop-no-form"}
              type="range"
              min={
                AvatarCrop.min_zoom(
                  (@pending_crop && @pending_crop["ar"]) || 1.0,
                  AvatarShape.fit(@shape)
                )
              }
              max={AvatarCrop.max_zoom()}
              step="0.01"
              value="1"
              class="range range-primary range-xs flex-1"
              aria-label={gettext("Zoom")}
            />
            <.icon name="hero-magnifying-glass-plus" class="w-4 h-4 opacity-60" />
          </div>
        </div>
        <:actions>
          <%!-- Nothing to reset on a fresh pick: the default fit already is
               the uncropped image. --%>
          <button
            :if={is_nil(@pending_uuid)}
            type="button"
            id={"#{@id}-crop-reset"}
            phx-click="reset_avatar_crop"
            phx-target={@myself}
            class="btn btn-ghost btn-sm mr-auto"
          >
            {gettext("Reset")}
          </button>
          <button
            type="button"
            id={"#{@id}-crop-cancel"}
            phx-click="close_avatar_crop"
            phx-target={@myself}
            class="btn btn-sm"
          >
            {gettext("Cancel")}
          </button>
          <%!-- data-crop-save-btn: the AvatarCrop hook flushes its pending
               state on this click (capture phase, so the flush is pushed
               before the phx-click), so a debounced wheel-zoom is not lost. --%>
          <button
            type="button"
            id={"#{@id}-crop-save"}
            data-crop-save-btn
            phx-click="save_avatar_crop"
            phx-target={@myself}
            class="btn btn-primary btn-sm"
          >
            {gettext("Save Crop")}
          </button>
        </:actions>
      </.modal>
    </div>
    """
  end
end
