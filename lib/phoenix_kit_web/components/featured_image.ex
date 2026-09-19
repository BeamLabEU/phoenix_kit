defmodule PhoenixKitWeb.Components.FeaturedImage do
  @moduledoc """
  One entity's "main image" control: a thumbnail, an always-visible actions
  menu (Change / Remove, plus View when a preview is wired up) and the whole
  media-picker protocol behind it.

  The component owns the picker — it mounts `MediaSelectorModal` itself, resets
  its own open flag on both of the modal's replies, refuses anything that is
  not a live image — and leaves the host exactly one required message. It
  writes nothing: where the pointer lives (a `data` key, a `metadata` field, a
  setting, a column) and when it is saved (at once, or with the surrounding
  form) are the host's business.

  ## Usage

      <.live_component
        module={PhoenixKitWeb.Components.FeaturedImage}
        id="order-featured"
        uuid={@order.featured_image_uuid}
        picker_scope={@order.storage_folder_uuid && {:folder, @order.storage_folder_uuid}}
        phoenix_kit_current_user={@current_user}
        readonly={@order.deleted?}
        on_preview={{"show_order_card", %{uuid: @order.uuid}}}
      />

      def handle_info({PhoenixKitWeb.Components.FeaturedImage, "order-featured", {:set_featured, uuid}}, socket) do
        # `uuid` is a file uuid, or `nil` when the user removed the image.
        # Authorize, persist, then assign the new value back — the component
        # draws whatever `uuid` it is handed and nothing else.
        {:noreply, socket}
      end

  The payload has the same shape as `MediaBrowser`'s `:featured` relay, so one
  host function can write both.

  ## Attrs

  There are no required attrs beyond `id`.

    * `id` — required. Every DOM id and `data-role` is derived from it, and it
      travels in every message the component sends.
    * `uuid` — the current pointer, or `nil`. The component is *controlled*: it
      draws exactly what the host passes and never updates it optimistically.
      Anything that is not a live image (a uuid with no row, a trashed file, a
      non-image, a failed upload, a string that is not a UUID at all) is drawn
      as a "missing" placeholder whose menu still offers Remove, so a dangling
      pointer can always be cleared. A `readonly` viewer sees nothing for it
      (or the `:empty` slot), never a warning they cannot act on. `""` counts as
      `nil`.
    * `picker_scope` — where the picker looks and where uploads land:
        * `{:folder, folder_uuid}` — the entity's folder. The picker is narrowed
          to it (and its subfolders) and files uploaded from it are filed there.
        * `:lazy` — the entity has no folder yet; the host creates one on demand
          (see "Lazy scope" below).
        * `nil` (default) — choosing is unavailable. The modal is never mounted:
          with no scope it would browse the whole library.

      Not named `scope`: that is `@phoenix_kit_current_scope` everywhere else in
      PhoenixKit. There is deliberately no whole-library value — an upload made
      outside any folder is an orphan candidate for storage's cleanup.
    * `phoenix_kit_current_user` — required by the picker for uploads.
    * `readonly` — `false`. `true` draws the thumbnail only: no menu, no
      picker, no empty placeholder. Also enforced on every event and message
      the component handles, since an event can be sent around the UI.
    * `size` — `:md`. `:sm` 48px, `:md` 64px, `:lg` 96px (the `:lg` thumbnail
      uses the `small` variant, the others `thumbnail`).
    * `shape` — `:square` (`rounded-lg`, default) or `:circle` (avatars).
    * `label` — the picker's title and the control's accessible name; defaults
      to a translated "Featured image".
    * `on_preview` — what a click on the thumbnail does (and adds a "View" item
      to the menu). One of `"event"`, `{"event", %{key: value}}` or a
      `%Phoenix.LiveView.JS{}`. There is no `phx-target`, so the event goes to
      the host LiveView. The component only knows the *file's* uuid, whereas a
      host usually needs its entity's, so the map is sent as `phx-value-*`
      params: `{"show_card", %{uuid: @order.uuid}}` arrives as
      `%{"uuid" => order_uuid}`. Values must be strings or numbers. Left `nil`,
      a click on the thumbnail opens the picker instead (when choosing is
      possible).
    * `confirm_remove` — a `data-confirm` text for Remove, for hosts that write
      the change at once and want to ask first.
    * `report_close` — `false`. `true` sends `:picker_closed` (below).

  ## Slots

    * `:empty` — replaces the empty placeholder, e.g. an avatar's initials. It
      keeps the control's size and shape, still opens the picker when choosing
      is possible, and is drawn for a `readonly` viewer as well (they should
      still see the initials). It also stands in for a *dangling* pointer: the
      frame is marked "Image missing" (title and screen-reader text) and the
      menu still offers Remove, but the host's placeholder is what is seen.
    * `:empty_hint` — drawn instead of the placeholder when `picker_scope` is
      `nil`, e.g. an "Upload files first" button that switches to the Files tab.
      Not drawn for `readonly` (read-only wins).

  ## Required host wiring — silent failure otherwise

  This is a `LiveComponent`, so it has no `handle_info` of its own: it reports
  to the **host LiveView process** with `send/2`, and the host MUST handle

      {PhoenixKitWeb.Components.FeaturedImage, id, {:set_featured, uuid | nil}}

  Forget it and the user's choice is silently dropped (no crash, no warning).
  A host that funnels every message into a catch-all `handle_info` must match
  this one before it.

  The other two messages are opt-in, so a host that does not use them needs no
  clause for them:

    * `{FeaturedImage, id, :scope_requested}` — only with `picker_scope: :lazy`.
    * `{FeaturedImage, id, :picker_closed}` — only with `report_close: true`.
      Sent whenever the picker goes away, however it ended (chosen, cancelled,
      rejected), always *after* `:set_featured` — except for a `readonly`
      component, which sends nothing at all. A host with a file list of its
      own refreshes it here: uploads made inside the picker land in the folder
      even when nothing was chosen.

  Also needed by the app, not the component: the `RowMenu` hook (from
  `PhoenixKitHooks`) registered in the host's `app.js`, or the actions menu is
  dead markup; and Phoenix LiveView 1.1 or newer — **1.2.12 or newer is
  recommended**, portals were still being fixed until then (see "The modal
  lives in a portal").

  ## Lazy scope

  Most hosts create the entity's folder on the first click, not on page load.
  With `picker_scope: :lazy` a click on Choose/Change opens nothing; it sends the
  host `{FeaturedImage, id, :scope_requested}`, and the host answers:

      def handle_info({FeaturedImage, id, :scope_requested}, socket) do
        case ensure_folder(socket) do
          {:ok, socket} ->
            # `socket` now carries the folder, so the next render passes
            # `picker_scope={{:folder, uuid}}`; then ask the component to open.
            send_update(FeaturedImage, id: id, open_picker: true)
            {:noreply, socket}

          :refused ->
            # The host explains itself (its own flash); nothing opens.
            send_update(FeaturedImage, id: id, open_picker: false)
            {:noreply, put_flash(socket, :error, "Restore this contact first")}

          {:error, message} ->
            # ...or let the component show the message under the control.
            send_update(FeaturedImage, id: id, error: message)
            {:noreply, socket}
        end
      end

  The reply does not carry the folder: the component takes its scope from the
  `picker_scope` attr only, so the host must have updated its assign *before*
  replying. If `open_picker: true` arrives while the scope is still not a
  folder, nothing opens (and a warning is logged). While an answer is pending,
  further clicks do nothing. **A `:lazy` host that never answers leaves the
  control inert** — every branch above must reply.

  ## Nested LiveViews (not verified)

  The actions menu is a `RowMenu` whose `<ul>` is moved to `<body>` while open,
  and the picker is a `<.portal>`. Both work in a host's main LiveView; neither
  has been exercised inside a `live_render`-ed child LiveView (an embedded
  project view, say), where a portaled `phx-target={@myself}` click might not
  find its component. From LiveView's sources this looks fine, but no test can
  run the client — check it in a browser before relying on it, and fall back to
  `table_row_menu mode="inline"` if it misbehaves.

  ## The modal lives in a portal

  The picker is rendered through `<.portal target="body">`. `MediaSelectorModal`
  has a `<form>` and a file input of its own, while most hosts place this
  control inside their own `<.form>`; nested forms are invalid HTML and the
  upload would post to the wrong form. The portal lifts the modal out of the
  form (and out of any card or `overflow` clipping). In tests, content inside a
  portal is invisible to `has_element?/2` and `render_click/2`: assert on the
  portal element instead (`render(element(view, "#<id>-portal"))`) and drive the
  modal's reply with `send_update(FeaturedImage, id: id, media_selected: [uuid])`.

  All the component's own buttons are `type="button"`, so it is safe inside a
  host form.

  ## The component does not authorize

  It draws Change/Remove for anyone it is not `readonly` for, and it relays what
  the user picked. Whether this user may change this entity's image, whether the
  chosen file belongs in this entity's folder, and whether the write goes
  through are all the host's to decide, in the `:set_featured` handler. The
  component checks only that a chosen file exists, is an image and is not in
  the trash. The same goes for a staged form: a dangling pointer is only
  *drawn* as missing; it stays in the host's state and will be saved as it was
  unless the host validates on write.

  ## Not for lists

  Each instance makes one `Storage` query when its `uuid` changes (memoized per
  uuid). For a table of rows draw the thumbnails from data the host already has
  instead.

  ## Actions and their `data-role`s

  Everything is addressed as `"<name>-<id>"`: `featured-image`, `row`, `thumb`,
  `thumb-img`, `open-picker`, `empty`, `empty-hint`, `dangling`, `processing`,
  `menu`, `change`, `view`, `remove`, `error`. The root also carries
  `data-state` (`empty`, `ok`, `processing` or `dangling`). The portal is
  `#<id>-portal` and the modal inside it `#<id>-selector`.
  """

  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  # A `processing` file gets its variants generated in the background; nothing
  # tells this component when that ends, so it looks again a few times.
  @recheck_after_ms 3_000
  @max_rechecks 10

  # Service messages (`send_update` from the modal, the host, or the component
  # itself) come first: a `send_update` with one key would otherwise fall
  # through to the general clause and be treated as a host re-render.
  @impl true
  def update(%{media_selector_closed: true}, socket) do
    socket = assign(socket, :show_picker, false)
    {:ok, if(readonly?(socket), do: socket, else: notify_closed(socket))}
  end

  def update(%{media_selected: uuids}, socket) do
    socket = assign(socket, :show_picker, false)

    if readonly?(socket) do
      {:ok, socket}
    else
      {:ok, socket |> apply_selection(uuids) |> notify_closed()}
    end
  end

  def update(%{open_picker: open?}, socket) do
    socket = assign(socket, :pending_scope, false)

    cond do
      readonly?(socket) ->
        {:ok, socket}

      open? == true and folder_scope?(socket.assigns[:picker_scope]) ->
        {:ok, socket |> assign(:show_picker, true) |> assign(:error, nil)}

      open? == true ->
        Logger.warning(
          "FeaturedImage #{inspect(socket.assigns[:id])}: open_picker: true arrived while " <>
            "picker_scope is #{inspect(socket.assigns[:picker_scope])}, not {:folder, uuid} — " <>
            "assign the folder before replying to :scope_requested"
        )

        {:ok, socket}

      true ->
        {:ok, socket}
    end
  end

  def update(%{error: message}, socket) do
    socket = assign(socket, :pending_scope, false)
    {:ok, if(readonly?(socket), do: socket, else: assign(socket, :error, message))}
  end

  def update(%{recheck: true}, socket) do
    socket = assign(socket, :recheck_scheduled, false)

    if socket.assigns[:display] == :processing do
      {:ok, recheck(socket)}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    previous_uuid = socket.assigns[:uuid]

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:uuid, fn -> nil end)
      |> assign_new(:picker_scope, fn -> nil end)
      |> assign_new(:phoenix_kit_current_user, fn -> nil end)
      |> assign_new(:readonly, fn -> false end)
      |> assign_new(:size, fn -> :md end)
      |> assign_new(:shape, fn -> :square end)
      |> assign_new(:label, fn -> nil end)
      |> assign_new(:on_preview, fn -> nil end)
      |> assign_new(:confirm_remove, fn -> nil end)
      |> assign_new(:report_close, fn -> false end)
      |> assign_new(:show_picker, fn -> false end)
      |> assign_new(:pending_scope, fn -> false end)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:recheck_count, fn -> 0 end)
      |> assign_new(:recheck_scheduled, fn -> false end)
      # Slots are absent from `assigns` when the host stops passing them, and
      # `assign/2` merges — reset them so a removed slot does not linger.
      |> assign(:empty, Map.get(assigns, :empty, []))
      |> assign(:empty_hint, Map.get(assigns, :empty_hint, []))
      |> normalize()
      |> reset_on_uuid_change(previous_uuid)
      |> load_display()

    {:ok, socket}
  end

  @impl true
  def handle_event("open_picker", _params, socket) do
    cond do
      readonly?(socket) ->
        {:noreply, socket}

      folder_scope?(socket.assigns.picker_scope) ->
        {:noreply, socket |> assign(:show_picker, true) |> assign(:error, nil)}

      socket.assigns.picker_scope == :lazy ->
        {:noreply, request_scope(socket)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("clear", _params, socket) do
    if readonly?(socket) or is_nil(socket.assigns.uuid) do
      {:noreply, socket}
    else
      send_to_host(socket, {:set_featured, nil})
      {:noreply, assign(socket, :error, nil)}
    end
  end

  # ── Picker protocol ────────────────────────────────────────────────────

  # First click with a `:lazy` scope: ask the host to make the folder. A second
  # click while the answer is pending would ask twice.
  defp request_scope(%{assigns: %{pending_scope: true}} = socket), do: socket

  defp request_scope(socket) do
    send_to_host(socket, :scope_requested)
    socket |> assign(:pending_scope, true) |> assign(:error, nil)
  end

  # The modal is `mode: :single`, so it sends at most one uuid; `[]` (nothing
  # confirmed) just closes. The uuid comes from the client, so it is checked
  # here before the host hears of it — but only for being a live image: whether
  # it belongs in the entity's folder is the host's call.
  defp apply_selection(socket, uuids) do
    case List.wrap(uuids) do
      [uuid | _] -> apply_choice(socket, uuid)
      [] -> socket
    end
  end

  defp apply_choice(socket, uuid) do
    case resolve(uuid) do
      {display, file} when display in [:ok, :processing] ->
        # Re-choosing what is already set is not a change worth a host write.
        if file.uuid != socket.assigns[:uuid],
          do: send_to_host(socket, {:set_featured, file.uuid})

        assign(socket, :error, nil)

      _rejected ->
        assign(socket, :error, gettext("The selected file is not an available image"))
    end
  end

  defp notify_closed(socket) do
    if socket.assigns[:report_close] == true, do: send_to_host(socket, :picker_closed)
    socket
  end

  defp send_to_host(socket, payload) do
    send(self(), {__MODULE__, socket.assigns.id, payload})
  end

  # ── Display guard ──────────────────────────────────────────────────────

  # Bad values from the host would otherwise crash the render, so they are
  # clamped here rather than pattern-matched in every helper.
  defp normalize(socket) do
    assigns = socket.assigns

    socket
    |> assign(:size, if(assigns.size in [:sm, :md, :lg], do: assigns.size, else: :md))
    |> assign(:shape, if(assigns.shape == :circle, do: :circle, else: :square))
    |> assign(:readonly, assigns.readonly == true)
    # The wait ends when the host answers, or when it hands over a real folder
    # without answering — the spinner must not outlive the scope it waited for.
    |> assign(:pending_scope, assigns.pending_scope == true and assigns.picker_scope == :lazy)
    |> assign(:preview_click, preview_click(assigns.on_preview))
    |> assign(:preview_values, preview_values(assigns.on_preview))
    # A picker left open when readonly flips on, or when its scope goes away,
    # must not come back to life when they flip back.
    |> assign(
      :show_picker,
      assigns.show_picker == true and assigns.readonly != true and
        folder_scope?(assigns.picker_scope)
    )
  end

  defp reset_on_uuid_change(socket, previous_uuid) do
    if socket.assigns.uuid == previous_uuid do
      socket
    else
      socket |> assign(:error, nil) |> assign(:recheck_count, 0)
    end
  end

  # One `Storage` lookup per uuid. `processing` is deliberately left out of the
  # memo (`display_for`) so the next look is a fresh one.
  defp load_display(socket) do
    uuid = socket.assigns.uuid

    if socket.assigns[:display_for] == {:memo, uuid} do
      socket
    else
      {display, file} = resolve(uuid)
      socket = assign(socket, display: display, file: file)

      case display do
        :processing -> socket |> assign(:display_for, nil) |> schedule_recheck()
        :unavailable -> socket |> assign(:display, :dangling) |> assign(:display_for, nil)
        _settled -> assign(socket, :display_for, {:memo, uuid})
      end
    end
  end

  defp recheck(socket) do
    count = socket.assigns.recheck_count + 1
    {display, file} = resolve(socket.assigns.uuid)
    socket = assign(socket, recheck_count: count, display: display, file: file)

    cond do
      display == :processing and count >= @max_rechecks ->
        # Never settled: stop spinning and let the user remove it.
        assign(socket, display: :dangling, display_for: {:memo, socket.assigns.uuid})

      display == :processing ->
        schedule_recheck(socket)

      display == :unavailable ->
        assign(socket, display: :dangling)

      true ->
        assign(socket, :display_for, {:memo, socket.assigns.uuid})
    end
  end

  defp schedule_recheck(%{assigns: %{recheck_scheduled: true}} = socket), do: socket

  # If the component is gone by the time this fires, LiveView logs that the
  # update had no target — once, within 3 seconds of removing a `processing` one.
  defp schedule_recheck(socket) do
    send_update_after(__MODULE__, [id: socket.assigns.id, recheck: true], @recheck_after_ms)
    assign(socket, :recheck_scheduled, true)
  end

  # → {display, file}. `display` is `:empty | :ok | :processing | :dangling`,
  # or `:unavailable` when Storage could not be asked (drawn as dangling but
  # not remembered, so the next render tries again).
  defp resolve(nil), do: {:empty, nil}
  # A host that stores "" for "cleared" means the same as nil.
  defp resolve(""), do: {:empty, nil}

  defp resolve(uuid) when is_binary(uuid) do
    with {:ok, cast} <- Ecto.UUID.cast(uuid),
         %{} = file <- Storage.get_file(cast) do
      {classify(file), file}
    else
      _ -> {:dangling, nil}
    end
  rescue
    # Same boundary as `MediaGallery.load_files`: a DB hiccup must not take the
    # host LiveView down with it.
    e in [DBConnection.ConnectionError, DBConnection.OwnershipError, Ecto.Query.CastError] ->
      Logger.warning("FeaturedImage: could not load file — #{Exception.message(e)}")
      {:unavailable, nil}
  end

  defp resolve(_not_a_uuid), do: {:dangling, nil}

  defp classify(%{status: "trashed"}), do: :dangling
  defp classify(%{file_type: type}) when type != "image", do: :dangling
  defp classify(%{status: "active"}), do: :ok
  defp classify(%{status: "processing"}), do: :processing
  defp classify(_failed_or_unknown), do: :dangling

  # ── Render helpers ─────────────────────────────────────────────────────

  defp readonly?(socket), do: socket.assigns[:readonly] == true

  defp folder_scope?({:folder, uuid}) when is_binary(uuid) and uuid != "", do: true
  defp folder_scope?(_scope), do: false

  # Choosing is possible now or after the host has made the folder.
  defp choosable?(assigns),
    do: folder_scope?(assigns.picker_scope) or assigns.picker_scope == :lazy

  defp folder_uuid({:folder, uuid}), do: uuid
  defp folder_uuid(_scope), do: nil

  # A pointer the guard rejected is never pre-selected: the modal would enable
  # Confirm on a choice the user cannot see.
  defp selected_uuids(%{display: :ok, file: file}), do: [file.uuid]
  defp selected_uuids(_assigns), do: []

  # Nothing to draw and nothing to act on (a viewer, an empty or missing image,
  # no host placeholder): the root is then an empty box, not a labelled group.
  defp blank?(assigns) do
    assigns.readonly and assigns.display in [:empty, :dangling] and assigns.empty == []
  end

  defp label_text(nil), do: gettext("Featured image")
  defp label_text(label), do: label

  defp role(id, name), do: "#{name}-#{id}"

  defp thumb_variant(:lg), do: "small"
  defp thumb_variant(_size), do: "thumbnail"

  defp thumb_url(uuid, size), do: URLSigner.signed_url(uuid, thumb_variant(size))

  # Whole literal class strings, never assembled from the size or shape:
  # Tailwind's scanner only emits classes it can read verbatim in the source.
  defp box_class(:sm), do: "size-12"
  defp box_class(:md), do: "size-16"
  defp box_class(:lg), do: "size-24"

  defp shape_class(:circle), do: "rounded-full"
  defp shape_class(:square), do: "rounded-lg"

  defp trigger_size(:lg), do: "md"
  defp trigger_size(_size), do: "sm"

  defp icon_class(:lg), do: "w-7 h-7"
  defp icon_class(_size), do: "w-5 h-5"

  # A 48px box has no room for a caption; the button keeps an accessible name.
  defp caption_class(:md), do: "text-[0.65rem] leading-tight"
  defp caption_class(:lg), do: "text-xs leading-tight"
  defp caption_class(:sm), do: "sr-only"

  defp rotation(%{metadata: %{} = metadata}),
    do: rotation_class(%{rotation: metadata["rotation"]})

  defp rotation(_file), do: nil

  # `on_preview` in its three accepted shapes → the `phx-click` value.
  defp preview_click(event) when is_binary(event), do: event
  defp preview_click({event, _values}) when is_binary(event), do: event
  defp preview_click(%Phoenix.LiveView.JS{} = js), do: js
  defp preview_click(_none), do: nil

  # `{event, %{uuid: x}}` → `%{"phx-value-uuid" => x}` for the `phx-click` element.
  # Only scalars can be an attribute value; a map or struct would raise
  # `Protocol.UndefinedError` at render and take the host LiveView down.
  defp preview_values({_event, values}) when is_map(values) or is_list(values) do
    for {key, value} <- values,
        is_binary(value) or is_number(value) or is_atom(value),
        into: %{},
        do: {"phx-value-#{key}", value}
  end

  defp preview_values(_other), do: %{}

  # ── Private function components ────────────────────────────────────────

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :size, :atom, required: true
  attr :shape, :atom, required: true
  attr :tone, :atom, required: true, values: [:image, :dashed, :solid, :warning]
  attr :as, :atom, default: :div, values: [:div, :button]
  attr :rest, :global
  slot :inner_block, required: true

  # The thumbnail-sized box every state is drawn in. A button when it does
  # something, a plain div when it does not — never a button that does nothing.
  defp frame(%{as: :button} = assigns) do
    ~H"""
    <button
      type="button"
      data-role={role(@id, @name)}
      class={frame_class(@size, @shape, @tone, true)}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp frame(assigns) do
    ~H"""
    <div data-role={role(@id, @name)} class={frame_class(@size, @shape, @tone, false)} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :file, :any, required: true
  attr :size, :atom, required: true

  defp thumb_img(assigns) do
    ~H"""
    <img
      data-role={role(@id, "thumb-img")}
      src={thumb_url(@file.uuid, @size)}
      alt={@file.original_file_name || ""}
      loading="lazy"
      draggable="false"
      class={["size-full object-cover", rotation(@file)]}
    />
    """
  end

  defp frame_class(size, shape, tone, interactive?) do
    [
      "relative flex shrink-0 flex-col items-center justify-center gap-0.5 overflow-hidden text-center",
      box_class(size),
      shape_class(shape),
      tone_class(tone),
      interactive? &&
        "cursor-pointer transition-colors hover:border-primary hover:text-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
    ]
  end

  defp tone_class(:image), do: "border border-base-300 bg-base-200"

  defp tone_class(:dashed),
    do:
      "border-2 border-dashed border-base-300 bg-base-100 text-base-content/60 hover:bg-base-200"

  defp tone_class(:solid), do: "border border-base-300 bg-base-200 text-base-content/50"
  defp tone_class(:warning), do: "border border-dashed border-warning/60 bg-base-200 text-warning"
end
