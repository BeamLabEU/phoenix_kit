defmodule PhoenixKitWeb.Components.AnnotationComposer do
  # PhoenixKitComments is an optional sibling package — silence undefined
  # warnings for parent apps that don't install it. The MediaBrowser
  # template only mounts this composer when comments are installed.
  # `PhoenixKit.Modules.Storage` is core, not optional, so it's not on
  # the suppression list — a rename or arity change there should surface
  # as a compile error here, not be silently shadowed.
  @compile {:no_warn_undefined, [PhoenixKitComments]}

  @moduledoc """
  Focused composer LiveComponent for attaching the *first* comment to a
  newly-drawn Etcher annotation in the MediaBrowser modal sidebar.

  ## Why a separate component

  `PhoenixKitComments.Web.CommentsComponent` is a monolithic bundle of
  thread rendering + composer + edit/delete/likes. We want only the
  composer slice, with explicit Post / Cancel control flow that owns the
  annotation lifecycle: clicking Post commits the comment AND
  "solidifies" the annotation, clicking Cancel rolls the annotation
  back. Extracting that out of `CommentsComponent` is harder than
  building a thin wrapper that calls the same context functions
  underneath (`PhoenixKitComments.create_comment/4`,
  `PhoenixKitComments.search_giphy/2`,
  `PhoenixKit.Modules.Storage.store_file/2`).

  ## Required assigns

    * `:annotation_uuid` — UUID of the annotation being annotated
    * `:file_uuid` — UUID of the *file* the annotation lives on. The
      created comment is tied to the file (`resource_type: "file"`,
      `resource_uuid: file_uuid`) so it appears in the file's comments
      thread alongside non-annotated discussion. The annotation linkage
      lives in `metadata.annotation_uuid` — the tooltip preview filters
      on this key.
    * `:current_user` — the user composing the comment (must be present)
    * `:parent_module` — the LiveComponent module that handles the
      composer's lifecycle actions (typically `MediaCanvasViewer`).
      Required.
    * `:parent_id` — DOM id of that parent LC so we can `send_update/2`
      lifecycle notifications back to it.

  ## Lifecycle notifications

  On submit success or explicit cancel the composer calls
  `Phoenix.LiveView.send_update(parent_module, id: parent_id, action: ...)`.
  The parent's `update/2` translates the action into either a rollback
  (cancel) or a "solidify" (post). No host-LV plumbing needed —
  `send_update/2` works LC-to-LC inside the same LiveView process.

  ## Scope

  Text + file uploads (image / video / audio / pdf / archive) + Giphy
  picker. Audio recording (which the full `CommentsComponent` supports
  via a JS hook) is intentionally skipped for v1; falling back to the
  existing thread UI on an existing annotation is the path for replies
  with audio.
  """

  use PhoenixKitWeb, :live_component

  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]

  alias PhoenixKit.Modules.Storage

  @impl true
  def mount(socket) do
    max_size_mb = PhoenixKitComments.get_max_attachment_size_mb()
    max_entries = PhoenixKitComments.get_max_attachments()

    {:ok,
     socket
     |> assign(:new_comment, "")
     |> assign(:new_title, "")
     |> assign(:giphy_open?, false)
     |> assign(:giphy_query, "")
     |> assign(:giphy_results, [])
     |> assign(:giphy_selected, nil)
     |> assign(:attach_menu_open?, false)
     |> assign(:max_attachments, max_entries)
     |> assign(:max_attachment_size_mb, max_size_mb)
     |> allow_upload(:attachment,
       accept: ~w(image/* video/* audio/* .pdf .doc .docx .txt .md .zip .rar .7z),
       max_entries: max_entries,
       max_file_size: max_size_mb * 1024 * 1024
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     # :reply mode is the tooltip's Reply flow: the shape's label already
     # IS the title, so the title input is hidden and the post threads
     # under `parent_uuid` (the shape's master comment) as pure body.
     |> assign_new(:mode, fn -> :full end)
     |> assign_new(:parent_uuid, fn -> nil end)
     |> apply_initial_title()
     |> assign(:giphy_enabled?, PhoenixKitComments.giphy_enabled?())
     |> assign(:attachments_enabled?, PhoenixKitComments.attachments_enabled?())
     |> assign(:max_length, PhoenixKitComments.get_max_length())}
  end

  # `initial_title` (optional) pre-fills the title field — the
  # label-first flow opens this composer AFTER the user typed the shape's
  # label inline, so the title they already wrote shouldn't be asked for
  # twice. Applied exactly once per initial_title value: re-renders (and
  # the user clearing the field on purpose) never re-stamp it.
  defp apply_initial_title(socket) do
    initial = socket.assigns[:initial_title]

    if is_binary(initial) and initial != "" and
         socket.assigns[:initial_title_applied] != initial do
      socket
      |> assign(:new_title, initial)
      |> assign(:initial_title_applied, initial)
    else
      socket
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Post / Cancel
  # ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("post", params, socket) do
    comment_text = params |> Map.get("comment", "") |> String.trim()
    title = params |> Map.get("title", "") |> String.trim()

    has_comment_payload =
      comment_text != "" or
        socket.assigns.giphy_selected != nil or
        not Enum.empty?(socket.assigns.uploads.attachment.entries)

    cond do
      title == "" and not has_comment_payload ->
        {:noreply,
         put_flash(socket, :error, gettext("Add a title, a note, a GIF, or an attachment"))}

      not has_comment_payload ->
        # Title-only annotation — skip the comment-thread create
        # entirely. The annotation row gets its `title` field set by
        # the parent's `finalize_annotation_compose/3` on the
        # `:annotation_composer_posted` action.
        Phoenix.LiveView.send_update(socket.assigns.parent_module,
          id: socket.assigns.parent_id,
          action: :annotation_composer_posted,
          annotation_uuid: socket.assigns.annotation_uuid,
          title: title,
          comment: nil
        )

        {:noreply, socket}

      true ->
        post_with_comment(socket, comment_text, title)
    end
  end

  def handle_event("cancel", _params, socket) do
    Phoenix.LiveView.send_update(socket.assigns.parent_module,
      id: socket.assigns.parent_id,
      action: :annotation_composer_cancelled,
      annotation_uuid: socket.assigns.annotation_uuid
    )

    {:noreply, socket}
  end

  # ──────────────────────────────────────────────────────────────
  # Text + attachments + Giphy event plumbing — copied near-verbatim
  # from PhoenixKitComments.Web.CommentsComponent so behavior matches
  # the user's expectations elsewhere in the app.
  # ──────────────────────────────────────────────────────────────

  def handle_event("update_draft", params, socket) do
    socket =
      socket
      |> assign_if(params, "comment", :new_comment)
      |> assign_if(params, "title", :new_title)

    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachment, ref)}
  end

  def handle_event("toggle_attach_menu", _params, socket) do
    {:noreply, assign(socket, :attach_menu_open?, not socket.assigns.attach_menu_open?)}
  end

  def handle_event("close_attach_menu", _params, socket) do
    {:noreply, assign(socket, :attach_menu_open?, false)}
  end

  def handle_event("open_giphy", _params, socket) do
    {:noreply,
     socket
     |> assign(:attach_menu_open?, false)
     |> assign(:giphy_open?, true)}
  end

  def handle_event("close_giphy", _params, socket) do
    {:noreply, assign(socket, :giphy_open?, false)}
  end

  def handle_event("giphy_search", %{"value" => query}, socket) do
    case PhoenixKitComments.search_giphy(query) do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:giphy_query, query)
         |> assign(:giphy_results, results)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:giphy_query, query)
         |> assign(:giphy_results, [])
         |> put_flash(:error, gettext("Giphy search failed"))}
    end
  end

  def handle_event("giphy_search", _params, socket), do: {:noreply, socket}

  def handle_event("select_giphy", %{"id" => gif_id}, socket) do
    case Enum.find(socket.assigns.giphy_results, &(&1["id"] == gif_id)) do
      nil ->
        {:noreply, socket}

      gif ->
        {:noreply,
         socket
         |> assign(:giphy_selected, gif)
         |> assign(:giphy_open?, false)}
    end
  end

  def handle_event("remove_giphy", _params, socket) do
    {:noreply, assign(socket, :giphy_selected, nil)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # ──────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────

  defp assign_if(socket, params, key, assign_key) do
    case Map.fetch(params, key) do
      {:ok, value} -> assign(socket, assign_key, value)
      :error -> socket
    end
  end

  defp post_with_comment(socket, comment_text, title) do
    # Anchor the comment to the file (not the annotation) so it joins
    # the file's main comments thread. In :full mode the annotation
    # linkage rides `metadata.annotation_uuid` (the tooltip preview
    # filters on it). In :reply mode the comment is a CHILD of the
    # shape's master comment instead — the master carries the linkage,
    # and the load side walks the subtree, so stamping the reply too
    # would double-count it as its own root.
    metadata =
      case socket.assigns.mode do
        :reply -> %{}
        _ -> %{"annotation_uuid" => socket.assigns.annotation_uuid}
      end
      |> maybe_put_giphy(socket.assigns.giphy_selected)

    attrs = %{
      content: comment_text,
      metadata: metadata,
      attachment_file_uuids: nil
    }

    with {:ok, file_uuids} <- consume_attachments(socket),
         {:ok, comment} <-
           PhoenixKitComments.create_comment(
             "file",
             socket.assigns.file_uuid,
             socket.assigns.current_user.uuid,
             attrs
             |> Map.put(:attachment_file_uuids, file_uuids)
             |> maybe_put_parent(socket.assigns.parent_uuid)
           ) do
      Phoenix.LiveView.send_update(socket.assigns.parent_module,
        id: socket.assigns.parent_id,
        action: :annotation_composer_posted,
        annotation_uuid: socket.assigns.annotation_uuid,
        title: if(title == "", do: nil, else: title),
        comment: comment
      )

      {:noreply, socket}
    else
      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         put_flash(socket, :error, first_error(cs) || gettext("Could not post comment"))}

      {:error, :empty_comment} ->
        {:noreply, put_flash(socket, :error, gettext("Add some text, a GIF, or an attachment"))}

      {:error, :attachments_disabled} ->
        {:noreply, put_flash(socket, :error, gettext("Attachments are disabled"))}

      {:error, :too_many_attachments} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Up to %{max} attachments", max: socket.assigns.max_attachments)
         )}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, gettext("Could not post comment"))}
    end
  end

  defp consume_attachments(socket) do
    if Enum.empty?(socket.assigns.uploads.attachment.entries) do
      {:ok, []}
    else
      user_uuid = socket.assigns.current_user.uuid

      results =
        consume_uploaded_entries(socket, :attachment, fn meta, entry ->
          opts = [
            filename: entry.client_name,
            content_type: entry.client_type,
            size_bytes: entry.client_size,
            user_uuid: user_uuid
          ]

          case Storage.store_file(meta.path, opts) do
            {:ok, %{uuid: uuid} = file} ->
              place_stored_file(file, socket, user_uuid)
              {:ok, {:ok, uuid}}

            {:error, reason} ->
              {:ok, {:error, reason}}
          end
        end)

      case Enum.split_with(results, &match?({:ok, _}, &1)) do
        {oks, []} ->
          {:ok, Enum.map(oks, fn {:ok, uuid} -> uuid end)}

        {_, [{:error, reason} | _]} ->
          {:error, gettext("Upload failed: %{reason}", reason: inspect(reason))}
      end
    end
  end

  # Host placement of annotation-comment uploads. The comments feature's
  # attachment hook key, per the Storage moduledoc's module folder convention,
  # so a host configures one hook for both.
  @doc false
  # public only for the unit test
  def place_stored_file(file, socket, user_uuid) do
    # The composer always comments on a FILE (create_comment("file", file_uuid, …)).
    subject = %{resource_type: "file", resource_uuid: socket.assigns.file_uuid}

    PhoenixKit.UploadsParentFolder.place_with(
      Application.get_env(:phoenix_kit_comments, :attachments_parent_folder),
      file,
      :annotation_attachment,
      user_uuid,
      subject
    )
  end

  defp maybe_put_giphy(metadata, nil), do: metadata
  defp maybe_put_giphy(metadata, gif), do: Map.put(metadata, "giphy", gif)

  defp maybe_put_parent(attrs, parent_uuid) when is_binary(parent_uuid),
    do: Map.put(attrs, :parent_uuid, parent_uuid)

  defp maybe_put_parent(attrs, _), do: attrs

  # Translates the first changeset error using the project's gettext-aware
  # helper, so the flash respects the user's locale and interpolates count
  # / opts properly (e.g. "must be at most 500 characters" with %{count}).
  defp first_error(%Ecto.Changeset{errors: errors}) do
    case errors do
      [{_field, {_msg, _opts} = error} | _] -> translate_error(error)
      _ -> nil
    end
  end

  defp attachment_icon("image/" <> _), do: "hero-photo"
  defp attachment_icon("video/" <> _), do: "hero-film"
  defp attachment_icon("audio/" <> _), do: "hero-musical-note"
  defp attachment_icon(_), do: "hero-document"

  defp upload_error_label(:too_large), do: gettext("File too large")
  defp upload_error_label(:too_many_files), do: gettext("Too many files")
  defp upload_error_label(:not_accepted), do: gettext("File type not allowed")
  defp upload_error_label(other), do: gettext("Upload error: %{reason}", reason: inspect(other))

  # ──────────────────────────────────────────────────────────────
  # Render
  # ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <.form
        for={%{}}
        id={"#{@id}-form"}
        phx-submit="post"
        phx-change="update_draft"
        phx-target={@myself}
        class="space-y-2"
      >
        <%!-- Optional title — when non-empty, renders inline on the     --%>
        <%!-- annotation. Above the bounding box for rect/circle/poly,   --%>
        <%!-- at the leader endpoint for callout. Position is draggable  --%>
        <%!-- in edit mode (saved as metadata.title_offset). Hidden in   --%>
        <%!-- :reply mode — the shape's label already is the title, and  --%>
        <%!-- the reply is body only.                                     --%>
        <input
          :if={@mode != :reply}
          type="text"
          name="title"
          value={@new_title}
          placeholder="Optional title (shows on the shape)"
          maxlength="200"
          class="input input-sm w-full text-sm"
          phx-mounted={Phoenix.LiveView.JS.focus()}
          phx-debounce="500"
        />

        <textarea
          name="comment"
          placeholder={gettext("Write a note about this annotation...")}
          rows="3"
          class="textarea w-full text-sm"
          phx-mounted={@mode == :reply && Phoenix.LiveView.JS.focus()}
          phx-debounce="500"
        ><%= @new_comment %></textarea>

        <div class={[
          "text-xs text-right",
          if(String.length(@new_comment) > @max_length,
            do: "text-error font-semibold",
            else: "text-base-content/60"
          )
        ]}>
          {String.length(@new_comment)} / {@max_length}
        </div>

        <%!-- Hidden file input — kept persistent so the upload state
             survives menu open/close and entry cancels. --%>
        <%= if @attachments_enabled? do %>
          <.live_file_input upload={@uploads.attachment} class="sr-only" />
        <% end %>

        <%!-- Staged previews: selected GIF + queued uploads --%>
        <%= if (@attachments_enabled? and (@uploads.attachment.entries != [] or @uploads.attachment.errors != [])) or @giphy_selected do %>
          <div class="space-y-2">
            <%= if @giphy_selected do %>
              <div class="flex items-center gap-3 bg-base-200 rounded p-2">
                <img
                  src={@giphy_selected["preview_url"]}
                  class="w-10 h-10 object-cover rounded shrink-0"
                  alt=""
                />
                <div class="flex-1 min-w-0 text-sm font-medium truncate">{gettext("GIF")}</div>
                <button
                  type="button"
                  phx-click="remove_giphy"
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                  aria-label={gettext("Remove GIF")}
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            <% end %>

            <%= for entry <- @uploads.attachment.entries do %>
              <div class="flex items-center gap-3 bg-base-200 rounded p-2">
                <.icon
                  name={attachment_icon(entry.client_type)}
                  class="w-5 h-5 shrink-0 text-base-content/60"
                />
                <div class="flex-1 min-w-0">
                  <div class="text-sm font-medium truncate">{entry.client_name}</div>
                  <%= if entry.progress > 0 and entry.progress < 100 do %>
                    <progress
                      class="progress progress-primary w-full h-1"
                      value={entry.progress}
                      max="100"
                    ></progress>
                  <% end %>
                </div>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  phx-target={@myself}
                  aria-label={gettext("Remove %{name}", name: entry.client_name)}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            <% end %>

            <%= for err <- upload_errors(@uploads.attachment) do %>
              <p class="text-xs text-error">{upload_error_label(err)}</p>
            <% end %>
            <%= for entry <- @uploads.attachment.entries, err <- upload_errors(@uploads.attachment, entry) do %>
              <p class="text-xs text-error">
                {entry.client_name}: {upload_error_label(err)}
              </p>
            <% end %>
          </div>
        <% end %>

        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="flex items-center gap-2">
            <%= if @attachments_enabled? or @giphy_enabled? do %>
              <div class="relative inline-block">
                <button
                  type="button"
                  phx-click="toggle_attach_menu"
                  phx-target={@myself}
                  class={[
                    "btn btn-sm",
                    if(@attach_menu_open?, do: "btn-primary", else: "btn-ghost")
                  ]}
                  aria-haspopup="menu"
                  aria-expanded={to_string(@attach_menu_open?)}
                  aria-label={gettext("Attach media")}
                >
                  <.icon name="hero-paper-clip" class="w-4 h-4" />
                </button>

                <%= if @attach_menu_open? do %>
                  <ul
                    phx-click-away="close_attach_menu"
                    phx-window-keydown="close_attach_menu"
                    phx-key="escape"
                    phx-target={@myself}
                    role="menu"
                    class="absolute top-full left-0 mt-1 z-50 menu menu-sm bg-base-100 rounded-box shadow-lg border border-base-300 w-44 p-1"
                  >
                    <%= if @giphy_enabled? do %>
                      <li role="none">
                        <button
                          type="button"
                          role="menuitem"
                          phx-click="open_giphy"
                          phx-target={@myself}
                          class="flex items-center gap-2"
                        >
                          <.icon name="hero-film" class="w-4 h-4" /> {gettext("GIF")}
                        </button>
                      </li>
                    <% end %>
                    <%= if @attachments_enabled? do %>
                      <li role="none">
                        <label
                          for={@uploads.attachment.ref}
                          role="menuitem"
                          phx-click="close_attach_menu"
                          phx-target={@myself}
                          class="flex items-center gap-2 cursor-pointer"
                          title={
                            gettext("Up to %{max} files, max %{size}MB each",
                              max: @max_attachments,
                              size: @max_attachment_size_mb
                            )
                          }
                        >
                          <.icon name="hero-photo" class="w-4 h-4" /> {gettext("File / Image")}
                        </label>
                      </li>
                    <% end %>
                  </ul>
                <% end %>

                <%= if @giphy_open? do %>
                  <div
                    class="absolute top-full left-0 mt-2 z-50 w-72 p-3 shadow-lg bg-base-100 rounded-box border border-base-300"
                    phx-click-away="close_giphy"
                    phx-window-keydown="close_giphy"
                    phx-key="escape"
                    phx-target={@myself}
                  >
                    <input
                      type="text"
                      name="q"
                      value={@giphy_query}
                      placeholder={gettext("Search GIFs...")}
                      class="input input-sm w-full"
                      phx-keyup="giphy_search"
                      phx-target={@myself}
                      phx-debounce="300"
                      data-pk-no-enter
                      autocomplete="off"
                    />
                    <div class="mt-2 max-h-72 overflow-y-auto">
                      <%= cond do %>
                        <% @giphy_results != [] -> %>
                          <div
                            class="grid gap-2"
                            style="grid-template-columns: repeat(3, minmax(0, 1fr));"
                          >
                            <%= for gif <- @giphy_results do %>
                              <button
                                type="button"
                                phx-click="select_giphy"
                                phx-value-id={gif["id"]}
                                phx-target={@myself}
                                class="border border-base-300 rounded hover:border-primary overflow-hidden bg-base-200"
                              >
                                <img
                                  src={gif["preview_url"]}
                                  loading="lazy"
                                  alt=""
                                  class="w-full object-cover"
                                  style="height: 5rem;"
                                />
                              </button>
                            <% end %>
                          </div>
                        <% String.trim(@giphy_query) == "" -> %>
                          <p class="text-xs text-base-content/60 text-center py-4">
                            {gettext("Type to search GIFs.")}
                          </p>
                        <% true -> %>
                          <p class="text-xs text-base-content/60 text-center py-4">
                            {gettext("No results.")}
                          </p>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <div class="flex items-center gap-2">
            <button
              type="button"
              phx-click="cancel"
              phx-target={@myself}
              class="btn btn-ghost btn-sm"
            >
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              <.icon name="hero-paper-airplane" class="w-4 h-4 mr-1" /> {gettext("Post")}
            </button>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
