defmodule PhoenixKitWeb.Components.MediaViewer do
  @moduledoc """
  Standalone media lightbox ("slide box") LiveComponent.

  Renders a `<dialog>` modal showing one file from an ordered set, with
  prev/next navigation (chevrons + ←/→ keys) and Escape/backdrop close.
  Per-file content (the pan/zoom canvas with annotations + comments
  thread for images, video/PDF/icon fallback otherwise) is delegated to
  the shared `PhoenixKitWeb.Components.MediaCanvasViewer` child
  LiveComponent — the same one MediaBrowser uses, so admins get the
  full annotation experience here too.

  Reusable on its own or embedded by `MediaGallery`.

  ## Attrs
  - `id` — required
  - `files` — ordered list of file UUIDs (the navigable set)
  - `current` — initial UUID to show (must be in `files`). Treated as
    a seed: once mounted, internal navigation state takes precedence
    over subsequent `current` attr changes. This is intentional when
    the component is mount-gated (`:if={...}`) so it remounts fresh
    on each open. A standalone consumer that keeps the component
    mounted and wants to jump to a different image programmatically
    must unmount and remount it.
  - `current_user` — required for the composer / comments thread to
    render. nil-tolerant (lightbox falls back to view-only).
  - `notify` — optional `{module, id}`; see Close below
  - `can_annotate` — default `true`. `false` makes the drawings read-only for
    everyone: shapes arrive locked, the drawing tools are gone, and the server
    refuses every drawing write (see `MediaCanvasViewer`).
  - `own_files_only` — default `nil`; a user uuid. On a file someone else
    uploaded the viewer is read-only: shapes locked, tools gone, and the server
    refuses drawing, changing, deleting, Reply and a shape's title, and any
    write to the file's own row. On a file that user uploaded everything the
    viewer offers stays. The comments thread under the picture is not a write
    to the file and is switched off by `comments`, not by this.
  - `write_scope` — default `nil`; a folder uuid. A write to the file's own row
    needs the file's HOME folder inside it (`Storage.within_scope?/2`); a file
    merely linked into the folder is not written.
  - `comments` — default `true`. `false` takes the discussion out of the
    lightbox: no comments thread, no reply popup, no comment count, preview or
    badge on the shapes, and the server refuses Reply.
  - `annotate_only` — default `nil`: `can_annotate` applies to every file. A
    list or `MapSet` of file uuids: a file in it gets `can_annotate` as the
    host passed it, any other file is read-only (shapes locked, tools gone, and
    the server refuses drawing, changing, deleting, Reply and a shape's title).
    `can_annotate={false}` still wins over the set; an empty set means no file
    may be drawn on; a value that is neither nil, a list nor a `MapSet` is
    treated as empty. `own_files_only` lets the uploader draw on his own upload
    wherever it lies and `write_scope` does not reach drawings, so this is how a
    host says "draw only on these files". The canvas viewer's id carries the
    file uuid, so stepping to another file asks the question again.
  - `details` — default `true`. `false` cuts the sidebar down to the file's name
    and its Download controls: no title, description, alt text or tags, no type,
    MIME type, size, dimensions or dates, no status, uploader or uuid, no EXIF
    panel, no link to a details page. The name is the file's translated title
    when it has one, else the name it was uploaded under. A display rule, not a
    boundary for the bytes: the host chose the files, and Download hands over the
    file itself (under the name it was uploaded with).
  - `authors` — default `true`. `false` keeps every name that says who drew a
    shape or wrote a comment out of the browser: the marker byline is dropped
    from the shapes' payload and from every patch pushed to them, so the tooltip
    header is the shape's label or its kind. The drawings and their labels stay.
    The comments thread names each commenter, so it is not rendered under
    `authors={false}` (with `comments` on, a shape's tooltip still previews the
    first comment's text and offers Reply — pass `comments={false}` as well to
    take the discussion out altogether).

  The lightbox never offers the viewer's other writes: no title/description
  editor, no persisted rotation, no "Edit image", no trash buttons, no
  featured or pick buttons — it passes none of `details_path`, `edit_target`,
  `persist_rotation`, `can_trash`, `featured` or `pick` — and Download stays as
  it is.

  ## Embedding for an outside person
  To show a few files to someone who is not staff, pass
  `own_files_only={user.uuid} write_scope={folder.uuid}
  annotate_only={their_own_file_uuids} comments={false} details={false}
  authors={false}`: they see each file and its name, with Download, and the
  drawings on it with their labels but not who made them or any discussion;
  on the files in `annotate_only` they keep the drawing tools, on every other
  file they only look. It does not decide WHAT they see. `files` is trusted host data: the lightbox shows a uuid
  from that list and nothing else (a seed or a step outside it, or a uuid
  carried by a client event, is never opened), skipping a file that is gone,
  in the trash or system-managed, but it does not check that the person may
  read each file in the list. Build the list from what that person may see.
  A file of a private library is signed with a time-window token, like
  `Storage.authorized_url/4` does, never with the permanent one the file route
  refuses.

  Two things the options do not reach, said plainly:

    * The burn route `POST /api/files/:uuid/burn` is an HTTP route that follows
      the user's own rights, not the host's options: an uploader may re-render
      his own file's thumbnails there whatever the lightbox offered.
    * The drawing toolbar's "Insert image" stores the picture as a `data:` URL
      inside the annotation, with no size cap, so someone who may draw on a file
      can store bytes in the annotations of that file. Limit `annotate_only` to
      files where that is acceptable.

  ## Close
  On close, if `notify: {module, id}` is set:
  `send_update(module, id: id, media_viewer_closed: true)`.
  Otherwise: `send(self(), {__MODULE__, id, :closed})`.
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.URLSigner

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:files, assigns[:files] || [])
      |> assign_new(:current_uuid, fn -> assigns[:current] end)
      |> assign(:notify, assigns[:notify])
      |> assign(:current_user, assigns[:current_user])
      |> assign(:can_annotate, assigns[:can_annotate] != false)
      |> assign(:own_files_only, assigns[:own_files_only])
      |> assign(:write_scope, assigns[:write_scope])
      |> assign(:comments, assigns[:comments] != false)
      |> assign(:annotate_only, annotate_only(assigns[:annotate_only]))
      |> assign(:details, assigns[:details] != false)
      |> assign(:authors, assigns[:authors] != false)

    {:ok,
     assign(
       socket,
       :current_file,
       curate_file(socket.assigns.current_uuid, socket.assigns.files)
     )}
  end

  @impl true
  def handle_event("close_viewer", _params, socket) do
    close(socket)
    {:noreply, socket}
  end

  def handle_event("step_viewer", %{"dir" => "prev"}, socket),
    do: {:noreply, step_viewer(socket, :prev)}

  def handle_event("step_viewer", %{"dir" => "next"}, socket),
    do: {:noreply, step_viewer(socket, :next)}

  def handle_event("viewer_keydown", %{"key" => "Escape"}, socket) do
    close(socket)
    {:noreply, socket}
  end

  def handle_event("viewer_keydown", %{"key" => "ArrowLeft"}, socket),
    do: {:noreply, step_viewer(socket, :prev)}

  def handle_event("viewer_keydown", %{"key" => "ArrowRight"}, socket),
    do: {:noreply, step_viewer(socket, :next)}

  def handle_event("viewer_keydown", _params, socket), do: {:noreply, socket}

  # The only events the lightbox owns are the three above. The canvas viewer
  # also posts `viewer_pick`, `trash_file`, `restore_file`, `delete_file` and
  # `set_featured` / `unset_featured` to its parent, but only for a host that
  # asked for those buttons, and the lightbox asks for none. A client can push
  # any event at a component, so anything else is ignored, not a crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── private ──────────────────────────────────────────────────────────

  # `annotate_only`: nil (every file), or the uuids that may be drawn on. Anything
  # that is not a list or a MapSet closes the gate rather than opening it.
  defp annotate_only(nil), do: nil
  defp annotate_only(%MapSet{} = uuids), do: uuids
  defp annotate_only(uuids) when is_list(uuids), do: MapSet.new(uuids)
  defp annotate_only(_other), do: MapSet.new()

  # What `can_annotate` the canvas viewer gets for the file it shows: the
  # host's own flag, and the set when there is one. The child's id carries the
  # file uuid, so stepping to another file mounts a new child and this is
  # worked out again; the child refuses every drawing write when it is false.
  defp can_annotate_here?(false, _annotate_only, _file), do: false
  defp can_annotate_here?(true, nil, _file), do: true
  defp can_annotate_here?(true, %MapSet{} = uuids, %{file_uuid: uuid}), do: uuid in uuids

  defp close(socket) do
    case socket.assigns.notify do
      {module, id} -> send_update(module, id: id, media_viewer_closed: true)
      _ -> send(self(), {__MODULE__, socket.assigns.id, :closed})
    end
  end

  # One step in `direction`, over any file that cannot be shown (gone, trashed,
  # system-managed) to the next one that can. Stays put at either end.
  defp step_viewer(socket, direction) do
    list = socket.assigns.files

    with idx when is_integer(idx) <-
           Enum.find_index(list, &(&1 == socket.assigns.current_uuid)),
         {uuid, file} <- next_showable(list, idx, direction) do
      socket
      |> assign(:current_uuid, uuid)
      |> assign(:current_file, file)
    else
      _ -> socket
    end
  end

  defp next_showable(list, idx, direction) do
    next_idx = if direction == :prev, do: idx - 1, else: idx + 1

    with true <- next_idx >= 0 and next_idx < length(list),
         uuid when is_binary(uuid) <- Enum.at(list, next_idx) do
      case curate_file(uuid, list) do
        nil -> next_showable(list, next_idx, direction)
        file -> {uuid, file}
      end
    else
      _ -> nil
    end
  end

  @doc false
  # Whether a file may be shown by a lightbox at all: a system-managed file
  # (a tile chunk, an edited image's hidden original) is never served, and the
  # file route refuses a trashed one to all but a `media` holder.
  def servable?(%Storage.File{system_managed: true}), do: false
  def servable?(%Storage.File{status: "trashed"}), do: false
  def servable?(%Storage.File{}), do: true

  # Build the curated file map MediaCanvasViewer expects. Slim version
  # of MediaBrowser's `enrich_files/1` — same shape minus the
  # folder_path (lightbox doesn't show folder breadcrumbs). One File
  # row + one FileInstance query per current file open; the prev/next
  # navigation re-resolves on each step. Only a uuid the host put in `files`
  # is ever opened: `current` is a seed and a step comes from the list, but
  # nothing is trusted to stay in it.
  defp curate_file(nil, _files), do: nil

  defp curate_file(file_uuid, files) when is_binary(file_uuid) do
    with true <- file_uuid in files,
         %Storage.File{} = file <- safe(fn -> Storage.get_file(file_uuid) end, nil),
         true <- servable?(file) do
      curate(file)
    else
      _ -> nil
    end
  end

  defp curate_file(_file_uuid, _files), do: nil

  defp curate(%Storage.File{} = file) do
    file_uuid = file.uuid
    instances = safe(fn -> Storage.list_file_instances(file_uuid) end, [])
    original = Enum.find(instances, &(&1.variant_name == "original"))

    private? = Libraries.private_file?(file)

    urls =
      file_uuid
      |> signed_urls(instances, private?)
      |> URLSigner.put_dzi_url(file_uuid, file.mime_type,
        version: original,
        private: private?
      )

    %{
      file_uuid: file.uuid,
      filename: file.original_file_name || file.file_name || "Unknown",
      file_type: file.file_type,
      mime_type: file.mime_type,
      size: file.size || 0,
      inserted_at: file.inserted_at,
      width: file.width,
      height: file.height,
      urls: urls
    }
  end

  defp signed_urls(file_uuid, instances, private?) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      case safe(
             fn ->
               URLSigner.signed_url(file_uuid, instance.variant_name,
                 version: instance,
                 private: private?
               )
             end,
             nil
           ) do
        nil -> acc
        url -> Map.put(acc, instance.variant_name, url)
      end
    end)
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    e in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Ecto.Query.CastError,
      ArgumentError,
      FunctionClauseError,
      KeyError
    ] ->
      Logger.warning("MediaViewer: data resolve failed — #{Exception.message(e)}")
      fallback
  end
end
