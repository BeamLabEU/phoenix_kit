defmodule PhoenixKitWeb.Components.Core.ResizableModal do
  @moduledoc """
  `<.modal>` with a box the person can resize: drag any edge or corner to
  make the dialog wider, narrower, taller or shorter.

  It is the same `<dialog>` as `PhoenixKitWeb.Components.Core.Modal.modal/1`
  — the `PkDialog` hook, Escape, the backdrop, `close_guard`, `keep_in_dom`
  and the three slots all behave as they do there. What it adds:

    * eight grips around the box (four edges, four corners), driven by the
      `PkResizable` hook. The dialog stays centred, so a drag moves both
      opposite edges: the edge under the pointer follows the pointer.
    * the size is kept in the browser (`localStorage`, one entry per dialog
      `id`), so the dialog opens next time the way the person left it. A
      double click on a grip forgets it and returns the initial size.
    * the box never gets smaller than `min_width` × `min_height` and never
      larger than the viewport less a small margin; a window made smaller
      afterwards shrinks the box with it.
    * below the `sm` breakpoint there is nothing to resize: the grips are
      hidden, a kept size is not applied and — with `fullscreen_on_mobile`
      (the default) — the box fills the screen.

  The content area scrolls inside the box; `height` is the box's initial
  height (`nil`, the default, lets the content decide, up to the viewport).

  ## Example

      <.resizable_modal id="compose" show={@compose?} on_close="close_compose" max_width="3xl">
        <:title>New message</:title>
        …
        <:actions>
          <button class="btn btn-primary" phx-click="send">Send</button>
        </:actions>
      </.resizable_modal>

  An explicit `id` is required: it names the kept size.
  """

  use Phoenix.Component

  @doc """
  Renders a modal dialog whose box can be resized by its edges and corners.

  See the module documentation; every attribute it shares with `<.modal>`
  means the same here.
  """
  attr :id, :string, required: true, doc: "Page-unique; also the name the size is kept under."
  attr :show, :boolean, required: true
  attr :on_close, :string, required: true

  attr :max_width, :string,
    default: "2xl",
    values: ~w(sm md lg xl 2xl 3xl 4xl 5xl 6xl 7xl full),
    doc: "The initial width, as `<.modal>`'s `max_width`. A resize replaces it."

  attr :height, :string,
    default: nil,
    doc:
      "The initial height of the box, any CSS length (`\"70vh\"`, `\"600px\"`). `nil` lets the content decide."

  attr :min_width, :integer, default: 320, doc: "Pixels the box cannot be dragged below."
  attr :min_height, :integer, default: 240, doc: "Pixels the box cannot be dragged below."

  attr :fullscreen_on_mobile, :boolean,
    default: true,
    doc: "Below `sm` the box fills the screen (no margin, no rounded corners)."

  attr :class, :string, default: ""
  attr :actions_class, :string, default: nil
  attr :closeable, :boolean, default: true
  attr :close_guard, :atom, default: :confirm, values: [nil, :confirm, :input]
  attr :keep_in_dom, :boolean, default: false
  attr :rest, :global

  slot :title
  slot :inner_block, required: true
  slot :actions

  def resizable_modal(assigns) do
    ~H"""
    <%= if @show or @keep_in_dom do %>
      <%!-- No `open` attribute, for the reason `<.modal>` gives: the hook
           opens the dialog with showModal(). --%>
      <dialog
        id={@id}
        class="modal"
        phx-hook="PkDialog"
        data-show={to_string(@show)}
        data-close-event={@on_close}
        data-closeable={to_string(@closeable)}
        data-close-guard={@close_guard}
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        {@rest}
      >
        <%!-- The box carries no `style` from the server once the hook has
             sized it, so every patch strips the inline size and the hook
             puts it back in `updated()` — the same dance `PkDialog` does
             for `open`. `overflow-hidden`: the content area scrolls, the box
             does not, so the grips stay on its edges. --%>
        <div
          id={"#{@id}-box"}
          phx-hook="PkResizable"
          data-size-key={@id}
          data-min-width={@min_width}
          data-min-height={@min_height}
          class={[
            "modal-box relative flex flex-col overflow-hidden",
            @fullscreen_on_mobile &&
              "max-sm:w-full max-sm:max-w-none max-sm:h-full max-sm:max-h-none max-sm:rounded-none",
            max_width_class(@max_width),
            @class
          ]}
          style={@height && "height: #{@height}"}
        >
          <h3
            :if={@title != []}
            id={"#{@id}-title"}
            class="font-bold text-lg mb-4 flex items-center gap-2 flex-shrink-0"
          >
            {render_slot(@title)}
          </h3>

          <div class="flex-1 min-h-0 overflow-y-auto overscroll-contain">
            {render_slot(@inner_block)}
          </div>

          <div
            :if={@actions != []}
            class={["modal-action flex-shrink-0 mt-4", @actions_class]}
          >
            {render_slot(@actions)}
          </div>

          <%!-- The grips: thin strips on the edges, small squares on the
               corners (above the strips). Hidden below `sm`. --%>
          <div
            :for={{dir, class} <- grips()}
            data-pk-resize={dir}
            aria-hidden="true"
            class={["absolute z-10 hidden sm:block touch-none select-none", class]}
          >
          </div>
        </div>
      </dialog>
    <% end %>
    """
  end

  defp grips do
    [
      {"n", "top-0 inset-x-2 h-1.5 cursor-ns-resize"},
      {"s", "bottom-0 inset-x-2 h-1.5 cursor-ns-resize"},
      {"w", "left-0 inset-y-2 w-1.5 cursor-ew-resize"},
      {"e", "right-0 inset-y-2 w-1.5 cursor-ew-resize"},
      {"nw", "top-0 left-0 size-3 cursor-nwse-resize"},
      {"se", "bottom-0 right-0 size-3 cursor-nwse-resize"},
      {"ne", "top-0 right-0 size-3 cursor-nesw-resize"},
      {"sw", "bottom-0 left-0 size-3 cursor-nesw-resize"}
    ]
  end

  defp max_width_class("sm"), do: "max-w-sm"
  defp max_width_class("md"), do: "max-w-md"
  defp max_width_class("lg"), do: "max-w-lg"
  defp max_width_class("xl"), do: "max-w-xl"
  defp max_width_class("2xl"), do: "max-w-2xl"
  defp max_width_class("3xl"), do: "max-w-3xl"
  defp max_width_class("4xl"), do: "max-w-4xl"
  defp max_width_class("5xl"), do: "max-w-5xl"
  defp max_width_class("6xl"), do: "max-w-6xl"
  defp max_width_class("7xl"), do: "max-w-7xl"
  defp max_width_class("full"), do: "max-w-full"
end
