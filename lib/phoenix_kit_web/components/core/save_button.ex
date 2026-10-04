defmodule PhoenixKitWeb.Components.Core.SaveButton do
  @moduledoc ~S"""
  A form's Save button that says where the form stands: nothing changed,
  changed and not saved, or just saved.

  A form that saves on every change gives no sign that anything happened and no
  chance to look before it does; a form with a bare Save button gives no sign
  that there is anything to save. This is the middle: the button is live only
  once something changed, and a short note beside it says "Unsaved changes" or
  "Saved".

  The component only draws; the form tracks the state. Send a change event from
  the form (`phx-change`), keep a key per form in two sets, and pass the
  booleans:

      <form phx-change="dirty" phx-auto-recover="recover" phx-submit="save_row" id={id}>
        <input type="hidden" name="key" value={key} />
        ...
        <.save_button dirty={MapSet.member?(@dirty, key)} saved={MapSet.member?(@saved, key)} />
      </form>

      def handle_event("dirty", %{"key" => key}, socket) do
        {:noreply, assign(socket, dirty: MapSet.put(socket.assigns.dirty, key),
                                  saved: MapSet.delete(socket.assigns.saved, key))}
      end

  Saving moves the key from `dirty` to `saved`; the next change moves it back.

  `phx-auto-recover="recover"` is not optional. When the socket reconnects (a
  tablet that slept, a dropped network) LiveView replays every form's values to
  its `phx-change` event, so without it every form on the page shows "Unsaved
  changes" though nobody touched it. Point recovery at an event that does
  nothing:

      def handle_event("recover", _params, socket), do: {:noreply, socket}

  Opt-in (not in the global import list): `import
  PhoenixKitWeb.Components.Core.SaveButton, only: [save_button: 1]`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  attr :dirty, :boolean, default: false, doc: "something changed since the last save"
  attr :saved, :boolean, default: false, doc: "the last thing that happened was a save"
  attr :label, :string, default: nil, doc: "the button's text; defaults to “Save”"
  attr :class, :any, default: nil

  def save_button(assigns) do
    ~H"""
    <span class={["inline-flex flex-wrap items-center gap-x-2", @class]}>
      <button
        type="submit"
        class={["btn btn-sm", if(@dirty, do: "btn-primary", else: "btn-ghost")]}
        disabled={not @dirty}
        phx-disable-with={gettext("Saving…")}
      >
        {@label || gettext("Save")}
      </button>
      <span :if={@dirty} class="text-xs text-warning" role="status">
        {gettext("Unsaved changes")}
      </span>
      <span :if={@saved and not @dirty} class="text-xs text-success" role="status">
        {gettext("Saved")}
      </span>
    </span>
    """
  end
end
