defmodule PhoenixKitWeb.Live.Components.MediaSelectorModal do
  @moduledoc """
  Media selector modal component.

  A reusable modal component for selecting media files from anywhere in the admin panel.
  Supports both single and multiple selection modes.

  ## Usage

      # In parent LiveView, add to socket assigns
      socket
      |> assign(:show_media_selector, false)
      |> assign(:media_selection_mode, :single)
      |> assign(:media_selected_uuids, [])

      # In template (IMPORTANT: Must pass phoenix_kit_current_user for uploads to work)
      <.live_component
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="media-selector-modal"
        show={@show_media_selector}
        mode={@media_selection_mode}
        selected_uuids={@media_selected_uuids}
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />

      # To open the modal
      def handle_event("open_media_selector", _params, socket) do
        {:noreply, assign(socket, :show_media_selector, true)}
      end

      # To receive selected media
      def handle_info({:media_selected, file_uuids}, socket) do
        # Handle the selected file UUIDs
        {:noreply, socket |> assign(:gallery_uuids, file_uuids)}
      end

  ## Required host wiring (do not skip — silent failure otherwise)

  This is a `LiveComponent`, so it has no `handle_info` of its own; it
  reports the user's choice by sending a **process message to the host
  LiveView**. The host MUST handle it, or the selection is silently
  dropped (the modal closes, nothing happens — no crash, no warning):

    * `handle_info({:media_selected, file_uuids}, socket)` — **required.**
      Fired when the user confirms; `file_uuids` is the chosen list.
    * `handle_info({:media_selector_closed}, socket)` — recommended (fired
      on cancel/close) so the host can reset its own open-state assign.

  Each host does something different with the files (avatar, gallery,
  product images…), so there is intentionally no `use ...Embed` macro to
  inject this — the handling is yours to write.

  Alternative — `:notify`: pass `notify: {SomeComponent, id}` and the
  result is delivered to that **component** via `send_update` instead
  (`update(%{media_selected: uuids}, socket)` /
  `update(%{media_selector_closed: true}, socket)`), for when the
  consumer is itself a LiveComponent.

  ## Attrs

    * `show` — boolean, controls modal visibility
    * `mode` — `:single` or `:multiple`
    * `selected_uuids` — list of already-selected file UUIDs
    * `phoenix_kit_current_user` — required for uploads to attribute the file
    * `file_type_filter` — `:all` (default), `:image`, or `:video`
    * `browse` — `true` (default) shows the library grid + search + type filter;
      `false` is upload-only (dropzone + Confirm; uploaded files auto-select)
    * `user_uuid` — when set, restricts the library to files owned by
      that user; nil (default) shows the full library
    * `scope_folder_id` — when set, restricts both the browse query
      and the post-upload home folder to this folder UUID. Plugins
      scoping the picker to a single domain object (e.g. a catalogue
      item) pass this after lazy-creating their folder; files already
      living elsewhere get a `FolderLink` into the scope folder on
      re-upload rather than being moved out from under their original
      owner. `nil` (default) = no scope, legacy full-library behaviour.
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, FileInstance, FolderLink, URLSigner}
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Format

  import Ecto.Query

  # Import core components
  import PhoenixKitWeb.Components.Core.Icon

  @per_page 30

  def update(assigns, socket) do
    # Check if any enabled buckets exist
    enabled_buckets = Storage.list_enabled_buckets()
    has_buckets = not Enum.empty?(enabled_buckets)

    # Save previous state BEFORE assigning new values
    was_shown = socket.assigns[:show] || false
    previous_selected_uuids = socket.assigns[:selected_uuids]

    socket =
      socket
      |> assign(assigns)
      |> assign(:has_buckets, has_buckets)
      |> assign_new(:user_uuid, fn -> nil end)
      # When set, restricts both the browse query and the post-upload
      # home folder to this folder UUID. Plugins scoping the picker to
      # a single domain object (e.g. a catalogue item) pass this
      # after lazy-creating their folder.
      |> assign_new(:scope_folder_id, fn -> nil end)
      |> assign_new(:notify, fn -> nil end)
      # `browse: false` → upload-only mode: hide the library grid, search,
      # type filter, pagination, and the accepted-types hint, leaving just the
      # dropzone + Confirm. Uploaded files auto-select, so Confirm still works.
      |> assign_new(:browse, fn -> true end)
      |> assign_new(:file_type_filter, fn -> :all end)
      |> assign_new(:search_query, fn -> "" end)
      |> assign_new(:current_page, fn -> 1 end)
      |> assign_new(:per_page, fn -> @per_page end)
      |> assign_new(:uploaded_files, fn -> [] end)
      |> assign_new(:total_count, fn -> 0 end)
      |> assign_new(:total_pages, fn -> 0 end)
      |> maybe_allow_upload(has_buckets)

    # Handle selected_uuids - only reset when modal is opening, otherwise preserve selection
    socket =
      cond do
        # Modal is opening (show transitions from false to true) - initialize from incoming assigns
        assigns[:show] && !was_shown ->
          selected_uuids_list = assigns[:selected_uuids] || []
          assign(socket, :selected_uuids, MapSet.new(selected_uuids_list))

        # Modal already open and has selection state - preserve it
        is_struct(previous_selected_uuids, MapSet) ->
          assign(socket, :selected_uuids, previous_selected_uuids)

        # First mount or no previous state - initialize empty
        true ->
          assign(socket, :selected_uuids, MapSet.new([]))
      end

    # Load files if modal is shown
    socket =
      if assigns[:show] do
        {files, total_count} = load_files(socket, socket.assigns.current_page)
        total_pages = ceil(total_count / socket.assigns.per_page)

        socket
        |> assign(:uploaded_files, files)
        |> assign(:total_count, total_count)
        |> assign(:total_pages, total_pages)
      else
        socket
      end

    {:ok, socket}
  end

  defp maybe_allow_upload(socket, has_buckets) do
    cond do
      socket.assigns[:uploads] ->
        socket

      has_buckets ->
        allow_upload(socket, :media_files,
          accept: accept_for(socket.assigns[:file_type_filter]),
          max_entries: 10,
          auto_upload: true,
          progress: &handle_progress/3
        )

      true ->
        # No buckets - don't allow upload
        socket
    end
  end

  # Constrain the upload picker to the filtered type. The browse list is already
  # scoped by `scope_files_by_type/2`; without this the upload accepted any file
  # (`:any`), so an image/video picker would still let arbitrary files in. `:all`
  # keeps `:any`.
  defp accept_for(:image), do: ~w(.jpg .jpeg .png .gif .webp .svg .bmp .avif .heic .heif)
  defp accept_for(:video), do: ~w(.mp4 .mov .webm .mkv .avi .m4v .ogv .ogg)
  defp accept_for(_), do: :any

  # Modal copy that reflects the active type filter, so an all/video picker
  # doesn't always say "images". Referenced from the template.
  defp selection_hint(:single, :image), do: gettext("Click on an image to select it")
  defp selection_hint(:single, :video), do: gettext("Click on a video to select it")
  defp selection_hint(:single, _), do: gettext("Click on a file to select it")
  defp selection_hint(_multiple, :image), do: gettext("Select one or more images")
  defp selection_hint(_multiple, :video), do: gettext("Select one or more videos")
  defp selection_hint(_multiple, _), do: gettext("Select one or more files")

  defp accepted_types_hint(:image), do: gettext("Images")
  defp accepted_types_hint(:video), do: gettext("Videos")
  defp accepted_types_hint(_), do: gettext("Images, videos, or documents")

  # Authoritative server-side type gate for uploads. The client `accept` list is
  # fixed when the upload is first allowed and can't track the in-modal type
  # dropdown, so an off-type file can still reach the server — reject it here.
  defp upload_type_allowed?(:image, entry), do: entry_file_type(entry) == "image"
  defp upload_type_allowed?(:video, entry), do: entry_file_type(entry) == "video"
  defp upload_type_allowed?(_all, _entry), do: true

  defp entry_file_type(entry) do
    (entry.client_type || MIME.from_path(entry.client_name)) |> determine_file_type()
  end

  defp off_type_upload_error(:image), do: gettext("Only image files can be added here.")
  defp off_type_upload_error(:video), do: gettext("Only video files can be added here.")
  defp off_type_upload_error(_), do: gettext("Only the allowed file types can be added here.")

  def handle_event("noop", _params, socket) do
    # No-op event to prevent click propagation
    {:noreply, socket}
  end

  def handle_event("toggle_selection", %{"file-uuid" => file_uuid}, socket) do
    selected_uuids = socket.assigns.selected_uuids
    mode = socket.assigns.mode

    Logger.debug(
      "MediaSelectorModal toggle_selection: mode=#{inspect(mode)}, file_uuid=#{file_uuid}"
    )

    new_selected_uuids =
      case mode do
        :single ->
          MapSet.new([file_uuid])

        :multiple ->
          if MapSet.member?(selected_uuids, file_uuid) do
            MapSet.delete(selected_uuids, file_uuid)
          else
            MapSet.put(selected_uuids, file_uuid)
          end

        # Handle string versions in case they come through as strings
        "single" ->
          MapSet.new([file_uuid])

        "multiple" ->
          if MapSet.member?(selected_uuids, file_uuid) do
            MapSet.delete(selected_uuids, file_uuid)
          else
            MapSet.put(selected_uuids, file_uuid)
          end

        # Default to single select for any unexpected value
        _ ->
          MapSet.new([file_uuid])
      end

    {:noreply, assign(socket, :selected_uuids, new_selected_uuids)}
  end

  def handle_event("confirm_selection", _params, socket) do
    selected_uuids = socket.assigns.selected_uuids |> MapSet.to_list()

    case socket.assigns[:notify] do
      {module, id} ->
        send_update(module, id: id, media_selected: selected_uuids)

      _ ->
        # Default: send to parent LiveView process
        send(self(), {:media_selected, selected_uuids})
    end

    {:noreply, assign(socket, :show, false)}
  end

  def handle_event("close_modal", _params, socket) do
    case socket.assigns[:notify] do
      {module, id} ->
        send_update(module, id: id, media_selector_closed: true)

      _ ->
        send(self(), {:media_selector_closed})
    end

    {:noreply, assign(socket, :show, false)}
  end

  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:current_page, 1)

    {files, total_count} = load_files(socket, 1)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  def handle_event("filter_type", %{"filter" => filter}, socket) do
    parsed_filter = parse_filter(filter)

    socket =
      socket
      |> assign(:file_type_filter, parsed_filter)
      |> assign(:current_page, 1)

    {files, total_count} = load_files(socket, 1)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    {files, total_count} = load_files(socket, page)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:current_page, page)
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media_files, ref)}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    {files, total_count} = load_files(socket, 1)
    total_pages = ceil(total_count / socket.assigns.per_page)

    socket =
      socket
      |> assign(:current_page, 1)
      |> assign(:uploaded_files, files)
      |> assign(:total_count, total_count)
      |> assign(:total_pages, total_pages)

    {:noreply, socket}
  end

  defp handle_progress(:media_files, entry, socket) do
    cond do
      entry.done? and not upload_type_allowed?(socket.assigns.file_type_filter, entry) ->
        # The in-modal type filter can change after the upload was allowed (the
        # `accept` constraint is fixed at allow_upload time), so re-check the
        # type here and reject an off-type file rather than storing it.
        {:noreply,
         socket
         |> cancel_upload(:media_files, entry.ref)
         |> put_flash(:error, off_type_upload_error(socket.assigns.file_type_filter))}

      entry.done? ->
        # Consume the uploaded entry and capture the file ID
        uploaded_results =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            process_upload(socket, path, entry)
          end)

        # Check if upload failed and handle error
        socket =
          case uploaded_results do
            file_uuid when is_binary(file_uuid) ->
              # Success - reload files and auto-select
              {files, total_count} = load_files(socket, socket.assigns.current_page)
              total_pages = ceil(total_count / socket.assigns.per_page)

              selected_uuids =
                case socket.assigns.mode do
                  :single -> MapSet.new([file_uuid])
                  :multiple -> MapSet.put(socket.assigns.selected_uuids, file_uuid)
                end

              socket
              |> assign(:uploaded_files, files)
              |> assign(:total_count, total_count)
              |> assign(:total_pages, total_pages)
              |> assign(:selected_uuids, selected_uuids)

            _ ->
              # Upload failed - show error message
              put_flash(
                socket,
                :error,
                gettext(
                  "Upload failed: No storage buckets configured. Please configure at least one storage bucket before uploading files."
                )
              )
          end

        {:noreply, socket}

      true ->
        {:noreply, socket}
    end
  end

  defp process_upload(socket, path, entry) do
    ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
    mime_type = entry.client_type || MIME.from_path(entry.client_name)
    file_type = determine_file_type(mime_type)

    current_user = socket.assigns[:phoenix_kit_current_user]

    if current_user do
      user_uuid = current_user.uuid
      file_hash = Auth.calculate_file_hash(path)

      case Storage.store_file_in_buckets(
             path,
             file_type,
             user_uuid,
             file_hash,
             ext,
             entry.client_name
           ) do
        {:ok, file, :duplicate} ->
          Logger.info("Duplicate file uploaded: #{file.uuid}")
          _ = maybe_set_folder(file, socket.assigns[:scope_folder_id])
          {:ok, file.uuid}

        {:ok, file} ->
          Logger.info("New file uploaded: #{file.uuid}")
          _ = maybe_set_folder(file, socket.assigns[:scope_folder_id])
          {:ok, file.uuid}

        {:error, reason} ->
          Logger.error("Upload failed: #{inspect(reason)}")
          {:postpone, :error}
      end
    else
      Logger.error("Upload failed: No authenticated user")
      {:postpone, :error}
    end
  end

  # When the picker is scoped to a folder, ensure the file is visible
  # in that folder. Three cases:
  # - Same folder (or already linked): no-op.
  # - File has no home yet: adopt as home (set folder_uuid).
  # - File has a different home: add a `FolderLink` so the file
  #   appears in both folders without being yanked from its current
  #   owner. Callers doing per-object isolation (catalogue items)
  #   rely on this so uploading the same file to two items leaves
  #   both with their own reference.
  defp maybe_set_folder(_file, nil), do: :noop

  defp maybe_set_folder(%File{folder_uuid: current}, new) when current == new,
    do: :already_in_folder

  defp maybe_set_folder(%File{folder_uuid: nil} = file, folder_uuid) do
    repo = PhoenixKit.Config.get_repo()

    file
    |> Ecto.Changeset.change(%{folder_uuid: folder_uuid})
    |> repo.update()
    |> warn_on_folder_error(file.uuid, folder_uuid)
  end

  defp maybe_set_folder(%File{uuid: file_uuid}, folder_uuid) do
    repo = PhoenixKit.Config.get_repo()

    # `:nothing` + the (folder_uuid, file_uuid) unique index makes this
    # idempotent — re-uploading the same file to the same linked folder
    # is a no-op rather than an error.
    %FolderLink{}
    |> FolderLink.changeset(%{folder_uuid: folder_uuid, file_uuid: file_uuid})
    |> repo.insert(on_conflict: :nothing, conflict_target: [:folder_uuid, :file_uuid])
    |> warn_on_folder_error(file_uuid, folder_uuid)
  end

  defp warn_on_folder_error({:ok, _} = result, _file_uuid, _folder_uuid), do: result

  defp warn_on_folder_error({:error, reason} = result, file_uuid, folder_uuid) do
    Logger.warning(
      "MediaSelectorModal: could not scope file #{file_uuid} to folder #{folder_uuid}: #{inspect(reason)}"
    )

    result
  end

  defp load_files(socket, page) do
    repo = PhoenixKit.Config.get_repo()
    per_page = socket.assigns.per_page

    query =
      from(f in File, order_by: [desc: f.inserted_at])
      # Don't suggest trashed or system-managed files in the picker.
      |> where([f], f.status != "trashed" and f.system_managed == false)
      |> scope_files_by_user(socket.assigns[:user_uuid])
      |> scope_files_by_folder(socket.assigns[:scope_folder_id])
      |> scope_files_by_type(socket.assigns.file_type_filter)
      |> scope_files_by_search(socket.assigns.search_query)

    total_count = repo.aggregate(query, :count, :uuid)
    offset = (page - 1) * per_page

    files =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> repo.all()

    file_uuids = Enum.map(files, & &1.uuid)

    instances_by_file =
      if Enum.any?(file_uuids) do
        from(fi in FileInstance, where: fi.file_uuid in ^file_uuids)
        |> repo.all()
        |> Enum.group_by(& &1.file_uuid)
      else
        %{}
      end

    files_with_urls =
      Enum.map(files, fn file ->
        instances = Map.get(instances_by_file, file.uuid, [])
        urls = generate_urls_from_instances(instances, file.uuid)

        %{
          file_uuid: file.uuid,
          filename: file.original_file_name || file.file_name || "Unknown",
          file_type: file.file_type,
          mime_type: file.mime_type,
          size: file.size || 0,
          urls: urls,
          # Saved orientation — thumbnails apply it as a CSS transform, so
          # the picker shows images the same way up as the media grid.
          rotation: Map.get(file.metadata || %{}, "rotation"),
          width: get_dimension_from_instances(instances, :width),
          height: get_dimension_from_instances(instances, :height)
        }
      end)

    {files_with_urls, total_count}
  end

  # Scope helpers for load_files/2. Each one returns the query
  # unchanged when the scope isn't set, otherwise narrows it. Keeps
  # load_files readable and lets credo stop yelling about cyclomatic
  # complexity on the combined set of scope branches.

  defp scope_files_by_user(query, nil), do: query

  defp scope_files_by_user(query, user_uuid),
    do: where(query, [f], f.user_uuid == ^user_uuid)

  # Scope to a specific folder when the caller provides one. Without
  # a scope, the picker shows the full user library (legacy behavior).
  # Files that are `FolderLink`-attached to the scope folder are
  # included too, so per-object pickers still see files that live in
  # another object's folder but are also shared with this one.
  defp scope_files_by_folder(query, nil), do: query

  # Scopes to the folder AND every nested folder beneath it, so a picker
  # scoped to (e.g.) an order's folder also surfaces images uploaded into
  # its sub-order subfolders.
  defp scope_files_by_folder(query, folder_uuid) do
    folder_uuids = Storage.folder_subtree_uuids(folder_uuid)

    linked_subq =
      from(fl in FolderLink,
        where: fl.folder_uuid in ^folder_uuids,
        select: fl.file_uuid
      )

    where(query, [f], f.folder_uuid in ^folder_uuids or f.uuid in subquery(linked_subq))
  end

  defp scope_files_by_type(query, :image), do: where(query, [f], f.file_type == "image")
  defp scope_files_by_type(query, :video), do: where(query, [f], f.file_type == "video")
  defp scope_files_by_type(query, _), do: query

  defp scope_files_by_search(query, ""), do: query

  defp scope_files_by_search(query, search) when is_binary(search) do
    where(query, [f], ilike(f.original_file_name, ^"%#{search}%"))
  end

  defp scope_files_by_search(query, _), do: query

  defp generate_urls_from_instances(instances, file_uuid) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      url = URLSigner.signed_url(file_uuid, instance.variant_name)
      Map.put(acc, instance.variant_name, url)
    end)
  end

  defp get_dimension_from_instances(instances, field) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> nil
      instance -> Map.get(instance, field)
    end
  end

  defp determine_file_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> "image"
      String.starts_with?(mime_type, "video/") -> "video"
      true -> "other"
    end
  end

  defp parse_filter(nil), do: :all
  defp parse_filter("image"), do: :image
  defp parse_filter("video"), do: :video
  defp parse_filter("all"), do: :all
  defp parse_filter(_), do: :all

  defp format_file_size(bytes), do: Format.bytes(bytes, decimals: 2, unknown: "0 B")

  defp pagination_range(current_page, total_pages) do
    cond do
      total_pages <= 7 ->
        Enum.to_list(1..total_pages)

      current_page <= 4 ->
        [1, 2, 3, 4, 5, :ellipsis, total_pages]

      current_page >= total_pages - 3 ->
        [1, :ellipsis | Enum.to_list((total_pages - 4)..total_pages)]

      true ->
        [1, :ellipsis, current_page - 1, current_page, current_page + 1, :ellipsis, total_pages]
    end
  end
end
