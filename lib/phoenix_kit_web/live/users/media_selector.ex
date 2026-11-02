defmodule PhoenixKitWeb.Live.Users.MediaSelector do
  @moduledoc """
  Generic media selector LiveView.

  Provides a reusable interface for selecting media files from anywhere in the admin panel.
  Supports both single and multiple selection modes.

  ## Usage

      # Navigate to selector with query params
      /admin/media/selector?return_to=/admin/publishing/edit&mode=single&filter=image

  ## Query Parameters

  - `return_to` - URL to navigate back to (required)
  - `mode` - "single" or "multiple" (default: "single")
  - `selected` - Comma-separated pre-selected file IDs (optional)
  - `filter` - "image", "video", "all" (default: "all")
  - `page` - Page number for pagination (default: "1")
  """
  use PhoenixKitWeb, :live_view

  # Search, file-type filter and page live in the query string, so a filtered
  # list is a real URL: shareable, reload-proof, and Back returns to the
  # previous query instead of leaving the page. `file_type_filter` defaults to
  # :all, which is therefore what gets omitted from the URL.
  use PhoenixKitWeb.Live.UrlState,
    params: [
      search_query: [default: "", url_key: "q"],
      file_type_filter: [
        default: :all,
        cast: :atom,
        in: [:all, :image, :video],
        url_key: "type",
        alias: "filter"
      ],
      current_page: [default: 1, cast: :integer, min: 1, url_key: "page"],
      # Tiles per page, picked with <.page_size_selector>. Allowlisted so a
      # hand-edited URL cannot ask for a million-row page.
      per_page: [default: 30, cast: :integer, in: [10, 25, 30, 50, 100]]
    ],
    page_param: :current_page

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, FileInstance, Folder, Libraries, URLSigner}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.Pagination
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.MediaThumbnail
  alias PhoenixKitWeb.Components.Core.UploadManager

  import Ecto.Query

  def mount(params, _session, socket) do
    # Handle locale
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Get project title
    project_title = Settings.get_project_title()

    # Parse mount-only query parameters (not URL state — these are fixed for
    # the lifetime of the session and are not list filters).
    return_to = parse_return_to(params["return_to"])
    mode = parse_mode(params["mode"])
    selected_uuids = parse_selected_uuids(params["selected"])
    scope_folder = parse_scope_folder(params["scope_folder"])

    # `scope_folder` is not declared to `use PhoenixKitWeb.Live.UrlState`
    # above — an undeclared query param survives every `push_url_state`
    # round-trip (search, filter, paging) on its own, so it needs no
    # handling beyond this one read.
    #
    # :search_query, :file_type_filter, :current_page and :per_page are
    # assigned from the query string by UrlState before mount/3 runs —
    # re-assigning them here would overwrite a shared link's state with the
    # defaults.
    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:current_path, Routes.path("/admin/media/selector"))
      |> assign(:project_title, project_title)
      |> assign(:page_title, gettext("Select Media"))
      |> assign(:return_to, return_to)
      |> assign(:selection_mode, mode)
      |> assign(:selected_uuids, selected_uuids)
      |> assign(:scope_folder, scope_folder)
      |> allow_upload(:media_files,
        accept: :any,
        max_entries: Storage.max_upload_files(),
        auto_upload: true,
        progress: &handle_progress/3
      )
      |> UploadManager.attach()

    {:ok, socket}
  end

  # The list is loaded here rather than in mount/3: UrlState calls this after
  # mount and on every change to the query string, so one code path serves the
  # first render, a shared link, and the Back button alike.
  #
  # Deliberately not annotated with @impl — a single @impl anywhere in a module
  # makes Elixir demand it on every other callback too, and this LiveView's
  # mount/handle_event/handle_params/handle_info carry none.
  def handle_url_state(_state, socket), do: reload_files(socket)

  def handle_event("toggle_selection", %{"file-uuid" => file_uuid}, socket) do
    selected_uuids = socket.assigns.selected_uuids
    mode = socket.assigns.selection_mode

    new_selected_uuids =
      case mode do
        :single ->
          # Single mode: replace selection
          [file_uuid]

        :multiple ->
          # Multiple mode: toggle selection. Selection is an ordered list —
          # append keeps the user's pick order, which consumers receive
          # through `selected_media`.
          if file_uuid in selected_uuids do
            List.delete(selected_uuids, file_uuid)
          else
            selected_uuids ++ [file_uuid]
          end
      end

    {:noreply, assign(socket, :selected_uuids, new_selected_uuids)}
  end

  def handle_event("confirm_selection", _params, socket) do
    return_to = socket.assigns.return_to
    selected_uuids = socket.assigns.selected_uuids

    # Build return URL with selected_media param
    selected_media_param = Enum.join(selected_uuids, ",")

    return_url =
      if String.contains?(return_to, "?") do
        "#{return_to}&selected_media=#{selected_media_param}"
      else
        "#{return_to}?selected_media=#{selected_media_param}"
      end

    {:noreply, push_navigate(socket, to: return_url)}
  end

  def handle_event("cancel_selection", _params, socket) do
    {:noreply, push_navigate(socket, to: socket.assigns.return_to)}
  end

  # `replace: true` — the box is debounced, so a typed-out query would otherwise
  # leave one history entry per pause and Back would walk the search string
  # backwards instead of leaving the page.
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply, push_url_state(socket, [search_query: query], replace: true)}
  end

  def handle_event("filter_type", %{"filter" => filter}, socket) do
    {:noreply, push_url_state(socket, file_type_filter: parse_filter(filter))}
  end

  # `push_url_state` resets the page along with the size: page 7 of 30 tiles
  # is not page 7 of 100. The in-memory selection survives, as with any patch.
  def handle_event("change_per_page", %{"per_page" => per_page}, socket) do
    case Integer.parse(per_page) do
      {per_page, ""} -> {:noreply, push_url_state(socket, per_page: per_page)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    # Files are auto-uploaded via handle_progress; this only refreshes the grid.
    # The reload cannot be left to the patch: on page 1 the URL does not change,
    # so handle_url_state would never fire and the new file would not appear.
    socket = put_flash(socket, :info, "Files uploaded successfully")

    {:noreply, reset_to_first_page(socket)}
  end

  # Data changed underneath the current query: reload in place when already on
  # page 1, otherwise patch back to it and let handle_url_state do the loading.
  defp reset_to_first_page(socket) do
    if socket.assigns.current_page == 1 do
      reload_files(socket)
    else
      push_url_state(socket, current_page: 1)
    end
  end

  defp reload_files(socket) do
    {files, total_count} = load_files(socket, socket.assigns.current_page)

    socket
    |> assign(:uploaded_files, files)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, Pagination.total_pages(total_count, socket.assigns.per_page))
  end

  defp handle_progress(:media_files, entry, socket) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          process_upload(socket, path, entry)
        end)

      socket =
        case result do
          file_uuid when is_binary(file_uuid) ->
            # Refresh the grid so the new file is visible, and auto-select it —
            # uploading into a picker means "I want this one".
            selected =
              case socket.assigns.selection_mode do
                :single -> [file_uuid]
                :multiple -> Enum.uniq(socket.assigns.selected_uuids ++ [file_uuid])
              end

            socket
            |> assign(:selected_uuids, selected)
            |> reset_to_first_page()

          _ ->
            put_flash(
              socket,
              :error,
              gettext("Upload failed. Check that at least one storage bucket is configured.")
            )
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp process_upload(socket, path, entry) do
    # Get file info
    ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
    mime_type = entry.client_type || MIME.from_path(entry.client_name)
    # Shared classifier — see `Storage.determine_file_type/2`. The copy that
    # lived here classified every audio upload as "other".
    file_type = Storage.determine_file_type(mime_type, entry.client_name)

    # Get current user
    current_user = socket.assigns[:phoenix_kit_current_user]
    user_uuid = if current_user, do: current_user.uuid, else: nil

    # Calculate hash
    file_hash = Auth.calculate_file_hash(path)

    # Store file in storage
    case Storage.store_file_in_buckets(
           path,
           file_type,
           user_uuid,
           file_hash,
           ext,
           entry.client_name,
           mime_type: mime_type
         ) do
      {:ok, file, :duplicate} ->
        Logger.info("Duplicate file uploaded: #{file.uuid}")
        maybe_attach_to_scope_folder(file, socket.assigns.scope_folder)
        {:ok, file.uuid}

      {:ok, file} ->
        Logger.info("New file uploaded: #{file.uuid}")
        maybe_attach_to_scope_folder(file, socket.assigns.scope_folder)
        {:ok, file.uuid}

      {:error, reason} ->
        # consume_uploaded_entry only accepts {:ok, _} | {:postpone, _} —
        # returning {:error, _} here raised and crashed the LiveView.
        Logger.error("Upload failed: #{inspect(reason)}")
        {:postpone, :error}
    end
  end

  defp maybe_attach_to_scope_folder(_file, nil), do: :ok

  defp maybe_attach_to_scope_folder(file, scope_folder) do
    case Storage.attach_file_to_folder(file, scope_folder) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning(
          "MediaSelector: could not place #{file.uuid} in #{scope_folder}: #{inspect(other)}"
        )

        :ok
    end
  end

  defp load_files(socket, page) do
    repo = PhoenixKit.Config.get_repo()
    per_page = socket.assigns.per_page
    filter = socket.assigns.file_type_filter
    search = socket.assigns.search_query

    # Build query. Same exclusions as MediaSelectorModal: a picker must not
    # offer trashed or system-managed files.
    query =
      from(f in File, order_by: [desc: f.inserted_at])
      |> where([f], f.status != "trashed" and f.system_managed == false)
      |> Libraries.exclude_user_libraries()

    # Apply file type filter
    query =
      case filter do
        :image -> where(query, [f], f.file_type == "image")
        :video -> where(query, [f], f.file_type == "video")
        :all -> query
      end

    # Apply search filter
    query =
      if search != "" do
        search_pattern = "%#{search}%"
        where(query, [f], ilike(f.original_file_name, ^search_pattern))
      else
        query
      end

    # Get total count
    total_count = repo.aggregate(query, :count, :uuid)

    # Get paginated files
    offset = (page - 1) * per_page

    files =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> repo.all()

    # Batch load instances to avoid N+1
    file_uuids = Enum.map(files, & &1.uuid)

    instances_by_file =
      if Enum.any?(file_uuids) do
        from(fi in FileInstance,
          where: fi.file_uuid in ^file_uuids
        )
        |> repo.all()
        |> Enum.group_by(& &1.file_uuid)
      else
        %{}
      end

    # Convert to file data maps
    # The language and the site's primary language, read once for the batch.
    alt_opts = MediaThumbnail.alt_opts()

    # Files in a private library get time-window URLs; one query for all.
    private = files |> Enum.map(& &1.library_uuid) |> Libraries.private_among()

    files_with_urls =
      Enum.map(files, fn file ->
        instances = Map.get(instances_by_file, file.uuid, [])

        urls =
          generate_urls_from_instances(
            instances,
            file.uuid,
            to_string(file.library_uuid) in private
          )

        %{
          file_uuid: file.uuid,
          filename: file.original_file_name || file.file_name || "Unknown",
          # The file's own alt text in the page's language; without one the
          # thumbnail keeps the file name, which is what this grid lists files by.
          alt: MediaThumbnail.alt_text(file, alt_opts),
          original_filename: file.original_file_name,
          # Reconciled against the row's own evidence — see
          # `Storage.display_file_type/1`.
          file_type: Storage.display_file_type(file),
          mime_type: file.mime_type,
          size: file.size,
          status: file.status,
          urls: urls,
          # Saved orientation — thumbnails apply it as a CSS transform, so
          # the picker shows images the same way up as the media grid.
          rotation: Map.get(file.metadata || %{}, "rotation"),
          width: get_width_from_instances(instances),
          height: get_height_from_instances(instances)
        }
      end)

    {files_with_urls, total_count}
  end

  defp generate_urls_from_instances(instances, file_uuid, private?) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      url =
        URLSigner.signed_url(file_uuid, instance.variant_name,
          version: instance,
          private: private?
        )

      Map.put(acc, instance.variant_name, url)
    end)
  end

  defp get_width_from_instances(instances) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> nil
      instance -> instance.width
    end
  end

  defp get_height_from_instances(instances) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> nil
      instance -> instance.height
    end
  end

  defp parse_mode(nil), do: :single
  defp parse_mode("single"), do: :single
  defp parse_mode("multiple"), do: :multiple
  defp parse_mode(_), do: :single

  # `return_to` is user-controlled (query param) and fed to `push_navigate` —
  # accept only local paths so a crafted link can't bounce through the selector
  # to an external site (or crash navigation with a full URL).
  # `Routes.local_path?/1` is the one redirect guard — it also rejects the
  # control characters browsers strip.
  defp parse_return_to(path), do: if(Routes.local_path?(path), do: path, else: "/")

  defp parse_selected_uuids(nil), do: []

  defp parse_selected_uuids(selected_string) when is_binary(selected_string) do
    selected_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_selected_uuids(_), do: []

  # Uploads made from the selector are placed under this folder (H3) — a
  # deleted or trashed folder is treated the same as no scope at all rather
  # than silently attaching new uploads to a dead folder.
  defp parse_scope_folder(value) when is_binary(value) do
    with {:ok, uuid} <- Ecto.UUID.cast(value),
         %Folder{trashed_at: nil} <- Storage.get_folder(uuid) do
      uuid
    else
      _ -> nil
    end
  end

  defp parse_scope_folder(_), do: nil

  defp parse_filter(nil), do: :all
  defp parse_filter("image"), do: :image
  defp parse_filter("video"), do: :video
  defp parse_filter("all"), do: :all
  defp parse_filter(_), do: :all

  defp format_file_size(bytes), do: Format.bytes(bytes, decimals: 2, unknown: "0 B")

  # Folds the old in-body subtitle text + selection-count badge into a single
  # string for `page_subtitle` (string-only attr, can't carry a colored pill).
  defp selection_subtitle(:single, _count), do: gettext("Click on an image to select it")

  defp selection_subtitle(:multiple, 0), do: gettext("Select one or more images")

  defp selection_subtitle(:multiple, count) do
    gettext("Select one or more images") <>
      " — " <> ngettext("%{count} selected", "%{count} selected", count, count: count)
  end
end
