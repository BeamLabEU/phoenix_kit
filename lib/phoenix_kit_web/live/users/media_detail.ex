defmodule PhoenixKitWeb.Live.Users.MediaDetail do
  @moduledoc """
  Single media file detail view for PhoenixKit admin panel.

  Provides a shareable view for a specific uploaded media file by file_uuid.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import Ecto.Query

  alias Phoenix.LiveView.JS
  alias PhoenixKit.AuditLog
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Modules.Storage.FileDetails
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.FileLocation
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.ImageEditor
  alias PhoenixKitWeb.Components.MediaBrowser
  alias PhoenixKitWeb.Components.MediaCanvasViewer
  alias PhoenixKitWeb.Live.Users.Media

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale =
      params["locale"] || socket.assigns[:current_locale]

    # Get file_uuid from params. A non-UUID segment (truncated link, typo)
    # must land on the "file not found" state, not raise Ecto.Query.CastError.
    file_uuid =
      case Ecto.UUID.cast(params["file_uuid"] || "") do
        {:ok, uuid} -> uuid
        :error -> nil
      end

    # Batch load all settings needed for this page
    settings =
      Settings.get_settings_cached(
        ["project_title"],
        %{"project_title" => PhoenixKit.Config.get(:project_title, "PhoenixKit")}
      )

    # An edit renders in the background; its progress and result arrive as
    # storage file events.
    if connected?(socket) and file_uuid, do: Storage.subscribe_to_file_events()

    socket =
      socket
      # For the audit entry of an Owner/Admin opening a user-library file:
      # connect info is only readable while mounting.
      |> assign(:client_ip, IpAddress.extract_from_socket(socket))
      |> assign(:user_agent, connected_user_agent(socket))
      |> assign(:page_title, "Media Detail")
      |> assign(:project_title, settings["project_title"])
      |> assign(:current_locale, locale)
      |> assign(:file_uuid, file_uuid)
      |> assign(:show_delete_modal, false)
      |> assign(:image_editor_open, params["edit"] == "image")
      |> assign(:exif_tags, nil)
      |> assign(:exif_status, nil)
      |> load_file_data(file_uuid)
      |> assign(
        :viewer_annotations,
        if(file_uuid, do: MediaCanvasViewer.load_annotations_for(file_uuid), else: [])
      )
      |> maybe_select_annotation(file_uuid, params["annotation"])

    {:ok, socket}
  end

  # Deep-link from a comment's "file" resource (e.g. the comments moderation
  # admin) can carry `?annotation=<uuid>` to focus the Etcher shape the comment
  # is anchored to. Push the select-shape event; the JS bridge retries until the
  # canvas layer is ready (the event is a no-op on the static mount).
  defp maybe_select_annotation(socket, file_uuid, annotation_uuid)
       when is_binary(file_uuid) and is_binary(annotation_uuid) and annotation_uuid != "" do
    Phoenix.LiveView.push_event(socket, "etcher:select-shape", %{
      fresco_id: "media-zoom-" <> file_uuid,
      uuid: annotation_uuid
    })
  end

  defp maybe_select_annotation(socket, _file_uuid, _annotation_uuid), do: socket

  def handle_event("confirm_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  def handle_event("delete_file", _params, socket) do
    file = socket.assigns.file

    case Storage.trash_file(file) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "File moved to trash")
         |> push_navigate(to: Routes.path("/admin/media"))}

      {:error, reason} ->
        Logger.error("Failed to trash file #{file.uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> put_flash(:error, "Failed to delete file")}
    end
  end

  def handle_event("restore_file", _params, socket) do
    case Storage.restore_file(socket.assigns.file) do
      {:ok, _file} ->
        {:noreply,
         socket
         |> load_file_data(socket.assigns.file_uuid)
         |> put_flash(:info, "File restored")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restore file")}
    end
  end

  def handle_event("permanently_delete_file", _params, socket) do
    case Storage.delete_file_completely(socket.assigns.file) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "File permanently deleted")
         |> push_navigate(to: Routes.path("/admin/media"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete file")}
    end
  end

  def handle_event("open_image_editor", _params, socket) do
    {:noreply, assign(socket, :image_editor_open, true)}
  end

  def handle_event("close_image_editor", _params, socket) do
    {:noreply, assign(socket, :image_editor_open, false)}
  end

  def handle_event("toggle_edit", _params, socket) do
    {:noreply, assign(socket, :edit_mode, !socket.assigns.edit_mode)}
  end

  # The title, alt text and description are saved for every language the form
  # has a block for (`details[<language>][title]`): one tab per language, one
  # Save. A flat `details[title]` (the form from before the tabs) is the page's
  # language. Tags are not text to translate; they stay in `metadata`, set in
  # the same held write as the text.
  def handle_event("save_metadata", params, socket) do
    tags =
      params
      |> Map.get("tags", "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) > 0))

    by_lang =
      FileDetails.by_language(
        params["details"],
        socket.assigns.details_lang,
        Enum.map(socket.assigns.details_langs, & &1.code)
      )

    case Storage.update_file_details_languages(socket.assigns.file, by_lang,
           metadata: %{"tags" => tags}
         ) do
      {:ok, file} ->
        {:noreply,
         socket
         |> assign(:file, file)
         |> assign(:file_data, %{socket.assigns.file_data | tags: tags, metadata: file.metadata})
         |> assign_details(file)
         |> assign(:edit_mode, false)
         |> put_flash(:info, gettext("Details saved"))}

      # What was typed stays in the form, in the language that failed.
      {:error, {lang, %Ecto.Changeset{data: %FileDetails{}} = changeset}} ->
        {:noreply,
         socket
         |> assign(:details_values, typed_values(socket.assigns.details_values, by_lang))
         |> put_flash(:error, invalid_details_message(lang, changeset, socket))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save details"))}
    end
  end

  # A photo's EXIF: read it into the row (what a photo uploaded before it was
  # kept needs), look at every tag of the original, or put that away. Nothing
  # but the first writes, and it only fills `metadata["exif"]` and the position.
  def handle_event("read_exif", _params, %{assigns: %{file: %{} = file}} = socket) do
    case Storage.read_exif(file) do
      {:ok, row} ->
        {:noreply,
         socket
         |> assign(:file, row)
         |> assign(:file_data, %{socket.assigns.file_data | metadata: row.metadata || %{}})
         |> assign(:exif_tags, nil)
         |> assign(:exif_status, nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, :exif_status, :error)}
    end
  end

  def handle_event("show_exif", _params, %{assigns: %{file: %{} = file}} = socket) do
    case Storage.exif_tags(file) do
      {:ok, tags} -> {:noreply, socket |> assign(:exif_tags, tags) |> assign(:exif_status, nil)}
      {:error, _reason} -> {:noreply, assign(socket, :exif_status, :error)}
    end
  end

  def handle_event("hide_exif", _params, socket) do
    {:noreply, assign(socket, :exif_tags, nil)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign_details(socket.assigns.file) |> assign(:edit_mode, false)}
  end

  def handle_event("regenerate_variants", _params, socket) do
    file = socket.assigns.file

    case VariantGenerator.generate_variants(file) do
      {:ok, instances} ->
        # instances is a list of successfully created FileInstance structs
        count = length(instances)

        socket =
          socket
          |> load_file_data(file.uuid)
          |> put_flash(:info, "Regenerated #{count} variants")

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to regenerate: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # The embedded CommentsComponent's Leaf editor reports its content via a
  # {:leaf_changed, ...} process message to this host LV; without forwarding
  # it to the component, "Post Comment" silently no-ops. phoenix_kit_comments
  # is optional from core, so resolve it at runtime (safe no-op if absent).
  # NOTE: defining handle_info means unmatched messages no longer hit
  # LiveView's default — hence the catch-all below.
  def handle_info({:leaf_changed, _} = msg, socket) do
    PhoenixKitWeb.CommentsForwarding.forward_leaf_changed(msg, socket)
  end

  # Comment activity on this file (sidebar create/delete — the comments
  # component reports to the host process): poke the canvas component so
  # the tooltip counts and on-shape badges refresh in place.
  def handle_info({:comments_updated, %{resource_type: "file", resource_uuid: uuid}}, socket) do
    case socket.assigns[:file_data] do
      %{file_uuid: ^uuid} ->
        Phoenix.LiveView.send_update(PhoenixKitWeb.Components.MediaCanvasViewer,
          id: socket.assigns.canvas_id,
          action: :refresh_annotations
        )

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  # This file was processed (an image edit rendered, variants regenerated):
  # show the new state, and tell the open editor.
  def handle_info({:phoenix_kit_file_processed, uuid}, %{assigns: %{file_uuid: uuid}} = socket) do
    if socket.assigns.image_editor_open do
      send_update(ImageEditor, id: image_editor_id(uuid), file_processed: uuid)
    end

    {:noreply, load_file_data(socket, uuid)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp image_editor_id(uuid), do: "media-detail-image-editor-" <> uuid

  defp load_file_data(socket, nil) do
    socket
    |> assign(:file, nil)
    |> assign(:file_data, nil)
  end

  defp load_file_data(socket, file_uuid) do
    repo = PhoenixKit.Config.get_repo()

    case repo.get(File, file_uuid) do
      nil ->
        socket
        |> assign(:file, nil)
        |> assign(:file_data, nil)

      file ->
        # The page is gated by the "media" permission. That must not open a
        # user library: the same read check as the file info API. Owner/Admin
        # and the library's members still pass (`Libraries.can?/3`).
        scope = socket.assigns[:phoenix_kit_current_scope]

        # A file of a site library is also not shown to a holder of `media`
        # alone unless they uploaded it (`media.view_all` sees everyone's).
        if (Libraries.private_file?(file) and not Libraries.can?(scope, file, :read)) or
             (not Libraries.private_file?(file) and
                not Storage.viewer_can_see_file?(
                  Media.restricted_viewer(scope),
                  file
                )) do
          socket
          |> assign(:file, nil)
          |> assign(:file_data, nil)
        else
          socket
          |> audit_admin_opening(file)
          |> load_file_details(file, file_uuid, repo)
        end
    end
  end

  defp connected_user_agent(socket) do
    if connected?(socket), do: get_connect_info(socket, :user_agent)
  rescue
    _ -> nil
  end

  # An Owner/Admin opening a file of someone's user library, as neither its
  # uploader nor one of the library's people: written to the audit log once
  # per page, the same as opening the library at `/admin/libraries/<uuid>`.
  defp audit_admin_opening(%{assigns: %{audited_opening: true}} = socket, _file), do: socket

  defp audit_admin_opening(socket, file) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    user_uuid = Scope.user_uuid(scope)

    with true <- connected?(socket) and Libraries.private_file?(file),
         true <- to_string(file.user_uuid) != user_uuid,
         %{} = library <- Libraries.get_library(file.library_uuid),
         nil <- Libraries.role(library, user_uuid) do
      AuditLog.create_log_entry(%{
        admin_user_uuid: user_uuid,
        target_user_uuid: library.owner_uuid,
        action: "storage.library_opened",
        ip_address: socket.assigns[:client_ip] || IpAddress.extract_from_socket(socket),
        user_agent: socket.assigns[:user_agent],
        metadata: %{
          "library_uuid" => library.uuid,
          "library_name" => library.name,
          "file_uuid" => file.uuid
        }
      })

      assign(socket, :audited_opening, true)
    else
      _ -> socket
    end
  rescue
    error ->
      Logger.error("MediaDetail: audit entry failed: #{Exception.message(error)}")
      socket
  catch
    # A dead pool exits rather than raises; the page must still show.
    :exit, reason ->
      Logger.error("MediaDetail: audit entry failed: #{inspect(reason)}")
      socket
  end

  defp load_file_details(socket, file, file_uuid, repo) do
    instances = load_file_instances(file_uuid, repo)

    urls =
      generate_urls_from_instances(
        instances,
        file_uuid,
        file.mime_type,
        Libraries.private_file?(file)
      )

    variant_dimensions = build_variant_dimensions(instances)
    locations = load_original_locations(instances, repo)
    tags = (file.metadata || %{})["tags"] || []
    user_name = get_user_name(file.user_uuid, repo)

    variant_dimensions = put_original_fallbacks(variant_dimensions, file)

    file_data =
      build_file_data(
        file,
        urls,
        variant_dimensions,
        locations,
        tags,
        user_name,
        instances
      )

    socket
    |> assign(:file, file)
    |> assign(:file_data, file_data)
    |> assign_details(file)
    |> assign(:edit_mode, socket.assigns[:edit_mode] || false)
    |> assign(:image_editable, ImageEditing.editable?(file))
    # The canvas keeps its own state; a new original (an edit) must
    # remount it with the new image and dimensions — and so must a newer
    # burned copy, now that this page opens on one: same file, same original,
    # different picture in front of you.
    |> assign(
      :canvas_id,
      "media-detail-canvas-#{file_uuid}-#{canvas_version(instances)}-" <>
        burn_version(file, instances)
    )
  end

  defp burn_version(file, instances) do
    case MediaBrowser.burn_fingerprint(file, instances) do
      fingerprint when is_binary(fingerprint) -> String.slice(fingerprint, 0, 12)
      _ -> "none"
    end
  end

  defp canvas_version(instances) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> "none"
      original -> URLSigner.version(original) || "none"
    end
  end

  defp load_file_instances(file_uuid, repo) do
    FileInstance
    |> where([fi], fi.file_uuid == ^file_uuid)
    |> repo.all()
  end

  defp load_original_locations(instances, repo) do
    case Enum.find(instances, &(&1.variant_name == "original")) do
      nil -> []
      original_instance -> load_file_locations(original_instance.uuid, repo)
    end
  end

  # `@details` is what the page shows (the current language, falling back
  # like any reader); the form holds each language's OWN text, and the
  # primary language's goes in as placeholders — never as values, or an
  # untouched save would store it as the translation.
  defp assign_details(socket, file) do
    opts = [primary: Multilang.primary_language()]
    lang = FileDetails.content_language(socket.assigns[:current_locale], opts)
    tabs = Multilang.build_language_tabs()
    codes = if tabs == [], do: [lang], else: Enum.map(tabs, & &1.code)

    values =
      Map.new(codes, fn code ->
        {code, file |> FileDetails.from_file(code, opts) |> Map.from_struct() |> blank_values()}
      end)

    socket
    |> assign(:details_lang, lang)
    |> assign(:details_lang_name, FileDetails.language_name(lang))
    |> assign(:details_langs, tabs)
    |> assign(:details_values, values)
    |> assign(:details, FileDetails.for_locale(file, lang, opts))
    |> assign(
      :details_placeholders,
      file |> FileDetails.for_locale(nil, opts) |> blank_values()
    )
  end

  defp blank_values(details),
    do: Map.new(details, fn {key, value} -> {key, value || ""} end)

  # The values the form was submitted with, over the ones it showed.
  defp typed_values(values, by_lang) do
    Enum.reduce(by_lang, values, fn {lang, attrs}, acc ->
      typed =
        Map.new(attrs, fn {field, value} -> {String.to_existing_atom(field), value || ""} end)

      Map.update(acc, lang, typed, &Map.merge(&1, typed))
    end)
  end

  defp invalid_details_message(lang, changeset, socket) do
    reason =
      case Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
             Enum.reduce(opts, msg, fn {key, value}, acc ->
               String.replace(acc, "%{#{key}}", to_string(value))
             end)
           end) do
        errors when map_size(errors) > 0 ->
          {field, [message | _]} = Enum.at(errors, 0)
          "#{Phoenix.Naming.humanize(field)} #{message}"

        _ ->
          gettext("Failed to save details")
      end

    name =
      Enum.find_value(socket.assigns.details_langs, lang, fn tab ->
        if tab.code == lang, do: tab.name
      end)

    "#{name}: #{reason}"
  end

  defp get_user_name(nil, _repo), do: "Unknown"

  defp get_user_name(user_uuid, repo) do
    alias_module = PhoenixKit.Config.get_users_module()

    case repo.get(alias_module, user_uuid) do
      nil -> "Unknown"
      user -> user.email
    end
  end

  defp build_file_data(
         file,
         urls,
         variant_dimensions,
         locations,
         tags,
         user_name,
         instances
       ) do
    %{
      file_uuid: file.uuid,
      filename: file.original_file_name || file.file_name || "Unknown",
      original_filename: file.original_file_name,
      file_type: file.file_type,
      mime_type: file.mime_type,
      size: file.size || 0,
      status: file.status,
      # Source intrinsic dimensions — drive the Fresco canvas aspect so
      # the embedded MediaCanvasViewer renders the image at its real
      # ratio (instead of `build_viewer_canvas/2`'s 1000×1000 fallback,
      # which fits a square canvas in a wide container with dotted
      # background on the sides).
      width: file.width,
      height: file.height,
      # The two fields that decide whether the embedded viewer opens on the
      # burned copy — the picture with its markup already in it — or on the
      # live layer with Etcher drawing over the top. Without them
      # `MediaCanvasViewer.burned?/1` says no and this page showed the live
      # layer while the popup showed the burn, for the same file.
      #
      # `burn_size` carries the burned copy's OWN extent, which is not the
      # picture's: a burn takes in ink drawn past the edges. `burn_fingerprint`
      # is what it was rendered from, so the viewer can tell an already-burned
      # drawing from one still to do.
      burn_fingerprint: MediaBrowser.burn_fingerprint(file, instances),
      burn_size: MediaBrowser.burn_size(instances),
      urls: urls,
      variant_dimensions: variant_dimensions,
      tags: tags,
      metadata: file.metadata || %{},
      inserted_at: file.inserted_at,
      updated_at: file.updated_at,
      locations: locations,
      user_name: user_name
    }
  end

  defp build_variant_dimensions(instances) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      dims =
        if instance.width && instance.height, do: {instance.width, instance.height}, else: nil

      Map.put(acc, instance.variant_name, %{
        dimensions: dims,
        size: instance.size,
        # What the stored bytes ARE. A signed URL has no extension in its
        # path — it ends in a token — so a download named from the URL
        # arrives with none, and the picture a browser saves is a file the
        # desktop cannot open by double-clicking.
        ext: instance.ext
      })
    end)
  end

  @doc false
  # The download list, in two groups: the picture at its sizes, and the
  # copies with the annotations drawn in.
  #
  # The slot names are internal — `burned`, `burned_large`,
  # `thumbnail_annotated` — and listed raw they were indistinguishable from
  # the picture's own rungs, which is what made "download in a different
  # quality" untrustworthy: nothing on the row said whether the markup was
  # in it. The names are not changed anywhere; only what a reader is shown.
  #
  # Left out on purpose: `dzi` is a tile manifest, not a picture, and
  # `thumbnail_annotated` is the square crop the grid's cards use — a
  # download nobody asked for, and cropped, which no one would expect from
  # a list of sizes. `annotated` is a slot this feature no longer writes;
  # the rows that still hold one are a rendering frozen at whatever the
  # drawing was when the naming changed, so offering it would hand someone
  # a stale picture.
  #
  # Every other variant — a size an admin added under Settings → Media →
  # Dimensions, a video's — follows the standard sizes in the picture's
  # group, by name, as the page listed them before the grouping.
  @picture_order ~w(original large medium small thumbnail)
  @burn_order ~w(burned_large burned)
  @not_downloads ~w(dzi thumbnail_annotated annotated)

  def download_groups(urls, dims) do
    others =
      urls
      |> Map.keys()
      |> Enum.reject(&(&1 in @picture_order or &1 in @burn_order or &1 in @not_downloads))
      |> Enum.sort()

    [
      {:picture, gettext("The picture"), collect(urls, dims, @picture_order ++ others)},
      {:annotated, gettext("Annotated"), collect(urls, dims, @burn_order)}
    ]
    |> Enum.reject(fn {_key, _title, rows} -> rows == [] end)
  end

  defp collect(urls, dims, order) do
    order
    |> Enum.filter(&Map.has_key?(urls, &1))
    |> Enum.map(fn name ->
      info = Map.get(dims, name, %{dimensions: nil, size: nil, ext: nil})

      %{
        variant: name,
        url: urls[name],
        label: variant_label(name),
        dimensions: info.dimensions,
        size: info.size,
        ext: Map.get(info, :ext),
        primary: name == "original"
      }
    end)
  end

  # What a row is called: the size, and nothing else. The heading above the
  # group says whether the markup is in it, so repeating that on every row
  # only made the label long enough to wrap onto a second line in a sidebar
  # this narrow — which is how a list of sizes stops being readable at a
  # glance, the thing the grouping was for.
  defp variant_label("original"), do: gettext("Original")
  defp variant_label("large"), do: gettext("Large")
  defp variant_label("medium"), do: gettext("Medium")
  defp variant_label("small"), do: gettext("Small")
  defp variant_label("thumbnail"), do: gettext("Thumbnail")
  defp variant_label("burned_large"), do: gettext("Large")
  defp variant_label("burned"), do: gettext("Medium")

  defp variant_label(name),
    do: name |> String.replace("_", " ") |> String.capitalize()

  @doc false
  # The numbers beside a row. `:compact` is what always fits — the pixel
  # size, which is what a download is chosen by; `:full` is both, for the
  # title, so the weight is a hover away at any width.
  def row_meta(row, :compact) do
    case row.dimensions do
      {w, h} -> "#{w}x#{h}"
      _ -> if row.size, do: format_file_size(row.size), else: ""
    end
  end

  def row_meta(row, :full) do
    [
      case row.dimensions do
        {w, h} -> "#{w}x#{h}"
        _ -> nil
      end,
      if(row.size, do: format_file_size(row.size))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc false
  # `?dl=1` asks the file controller to answer `attachment` rather than the
  # `inline` every <img> on the site wants. It is what makes the click a
  # download on an install that serves through a bucket, where the response
  # is a redirect and the link's own `download` attribute is dropped.
  def download_url(url) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> "dl=1"
  end

  @doc false
  # What the browser saves it as — the same rule the server answers with, so
  # a link and the bytes behind it agree on the name. See
  # `Storage.download_name/3`: the attribute alone cannot be trusted,
  # because a response that redirects to a bucket drops it.
  defdelegate download_name(file_name, variant, ext), to: Storage

  # Fill in original variant info from the main file record when the instance lacks it
  defp put_original_fallbacks(variant_dimensions, file) do
    original = Map.get(variant_dimensions, "original", %{dimensions: nil, size: nil, ext: nil})

    dims = original.dimensions || if(file.width && file.height, do: {file.width, file.height})
    size = original.size || file.size

    Map.put(variant_dimensions, "original", %{
      original
      | dimensions: dims,
        size: size,
        ext: Map.get(original, :ext) || Path.extname(file.file_name || "")
    })
  end

  # Generate URLs from pre-loaded instances (no database query needed)
  defp generate_urls_from_instances(instances, file_uuid, mime_type, private?) do
    instances
    |> Enum.reduce(%{}, fn instance, acc ->
      url =
        URLSigner.signed_url(file_uuid, instance.variant_name,
          version: instance,
          private: private?
        )

      Map.put(acc, instance.variant_name, url)
    end)
    |> URLSigner.put_dzi_url(file_uuid, mime_type,
      version: Enum.find(instances, &(&1.variant_name == "original")),
      private: private?
    )
  end

  # Load file locations with bucket information
  defp load_file_locations(file_instance_uuid, repo) do
    FileLocation
    |> where([fl], fl.file_instance_uuid == ^file_instance_uuid and fl.status == "active")
    |> preload(:bucket)
    |> repo.all()
    |> Enum.map(fn location ->
      %{
        bucket_name: location.bucket.name,
        bucket_provider: location.bucket.provider,
        path: location.path
      }
    end)
  end

  defp format_file_size(bytes), do: Format.bytes(bytes, base: 1000, decimals: 2)
end
