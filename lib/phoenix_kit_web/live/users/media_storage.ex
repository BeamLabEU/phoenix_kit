defmodule PhoenixKitWeb.Live.Users.MediaStorage do
  @moduledoc """
  How one media file is stored: `/admin/media/:file_uuid/storage`.

  The picture, its title and its comments live in the media view
  (`/admin/media?file=<uuid>`); this page is for the backend of the same file:
  the checksum of its original, every rendition the file's variant set wants
  and which of them are there, the buckets holding each object, and the actions
  that put it right (verify the copies against their checksums, make the
  missing renditions again, restore or drop the unedited original).

  The report is `PhoenixKit.Modules.Storage.FileReport`. Reading and checking
  copies can take a while (a cloud bucket, a video), so verifying and repairing
  run as async tasks and the page shows their progress.

  Gated by `media.manage`, like the other storage administration screens. A
  holder who is not allowed to see the file (someone else's file in a library
  they are not in, or without `media.view_all`) gets "not found".
  """
  use PhoenixKitWeb, :live_view

  import PhoenixKitWeb.Components.Core.RepairLog, only: [repair_log: 1]

  require Logger

  alias PhoenixKit.AuditLog
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.FileRepair
  alias PhoenixKit.Modules.Storage.FileReport
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Modules.Storage.RepairLog
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.FileController
  alias PhoenixKitWeb.Live.Users.Media
  alias PhoenixKitWeb.Live.Users.MediaDetail

  def mount(params, _session, socket) do
    file_uuid =
      case Ecto.UUID.cast(params["file_uuid"] || "") do
        {:ok, uuid} -> uuid
        :error -> nil
      end

    # An edit or a repair renders in the background; the result arrives as a
    # storage file event.
    if connected?(socket) and file_uuid, do: Storage.subscribe_to_file_events()

    socket =
      socket
      |> assign(:client_ip, IpAddress.extract_from_socket(socket))
      |> assign(:user_agent, connected_user_agent(socket))
      |> assign(:page_title, gettext("Storage"))
      |> assign(
        :project_title,
        Settings.get_settings_cached(["project_title"], %{
          "project_title" => PhoenixKit.Config.get(:project_title, "PhoenixKit")
        })["project_title"]
      )
      |> assign(:current_locale, params["locale"] || socket.assigns[:current_locale])
      |> assign(:file_uuid, file_uuid)
      |> assign(:working, nil)
      |> assign(:verification, nil)
      |> assign(:repair, nil)
      |> load(file_uuid)

    {:ok, socket}
  end

  # ──────────────────────────────────────────────────────────────
  # Loading
  # ──────────────────────────────────────────────────────────────

  defp load(socket, nil), do: not_found(socket)

  defp load(socket, file_uuid) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case PhoenixKit.Config.get_repo().get(StorageFile, file_uuid) do
      %StorageFile{} = file ->
        if visible?(scope, file) do
          socket |> audit_admin_opening(file) |> assign_report(file)
        else
          not_found(socket)
        end

      nil ->
        not_found(socket)
    end
  end

  # The page is gated by a permission, which must not open a user library
  # (the same read check as the file info API), nor a site library's file a
  # restricted viewer did not upload.
  defp visible?(scope, file) do
    if Libraries.private_file?(file),
      do: Libraries.can?(scope, file, :read),
      else: Storage.viewer_can_see_file?(Media.restricted_viewer(scope), file)
  end

  defp not_found(socket) do
    assign(socket,
      file: nil,
      rows: [],
      repair_log: nil,
      problems: [],
      backup: nil,
      can_manage: false,
      header_title: gettext("Storage"),
      header_section: gettext("Media"),
      header_section_path: Routes.path("/admin/media"),
      header_crumbs: []
    )
  end

  defp assign_report(socket, file) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    rows = FileReport.renditions(file)
    {section, section_path, crumbs} = MediaDetail.trail(file, scope)

    socket
    |> assign(:file, file)
    |> assign(:rows, rows)
    |> assign(:problems, FileReport.problems(rows))
    |> assign(:uploader, uploader_name(file.user_uuid))
    |> assign(:repair_log, RepairLog.list(file_uuid: file.uuid, per_page: 10))
    |> assign(:placement, placement(file, rows))
    |> assign(:backup, backup_report(file))
    |> assign(:preview_url, preview_url(file))
    |> assign(:view_path, MediaDetail.view_path(file, scope))
    |> assign(
      :can_manage,
      Scope.can?(scope, "media.manage") and Libraries.can?(scope, file, :edit)
    )
    |> assign(:header_title, gettext("Storage"))
    |> assign(:header_section, section)
    |> assign(:header_section_path, Routes.path(section_path))
    |> assign(
      :header_crumbs,
      crumbs ++ [%{label: filename(file), path: MediaDetail.view_path(file, scope)}]
    )
  end

  @doc false
  def filename(file), do: file.original_file_name || file.file_name || gettext("Unnamed file")

  defp uploader_name(nil), do: nil

  defp uploader_name(user_uuid) do
    case PhoenixKit.Config.get_repo().get(PhoenixKit.Config.get_users_module(), user_uuid) do
      nil -> nil
      user -> user.email
    end
  end

  # Where the file belongs: its library, the storage profile that says where its
  # bytes live and the rendition profile that says which sizes it gets, and
  # whether the file was last placed by the versions those are at now (the
  # reconciler brings a file that was not up to date).
  defp placement(file, rows) do
    library = Libraries.get_library(file.library_uuid)
    profile = Profiles.for_library(library || file.library_uuid)
    set = VariantSets.for_library(library || file.library_uuid)

    %{
      library: library,
      profile: profile && profile_summary(profile),
      profile_current?: profile != nil and placed_by?(file, profile),
      set: set,
      set_current?: set != nil and set_placed_by?(file, set),
      sizes: Enum.count(rows, &(&1.kind == :size)),
      profile_path: Routes.path("/admin/settings/media?tab=profiles"),
      set_path: set_path(set),
      library_path: library_path(library)
    }
  end

  # Names and roles only: nothing of a bucket's connection leaves this function.
  defp profile_summary(profile) do
    %{
      name: profile.name,
      local: Profiles.copies(profile, :local),
      cloud: Profiles.copies(profile, :cloud),
      buckets:
        for row <- profile.buckets do
          %{uuid: row.bucket_uuid, name: row.bucket.name, role: row.role, status: row.status}
        end
    }
  end

  # `nil` stamps mean the Default at revision 1 (see `Reconciler`).
  defp placed_by?(file, profile) do
    to_string(file.placed_profile_uuid || Profiles.default_uuid()) == to_string(profile.uuid) and
      (file.placed_revision || 1) == profile.revision
  end

  defp set_placed_by?(file, set) do
    to_string(file.placed_variant_set_uuid || VariantSets.default_uuid()) == to_string(set.uuid) and
      (file.placed_variant_revision || 1) == set.revision
  end

  defp set_path(nil), do: nil

  defp set_path(set) do
    if VariantSets.default?(set.uuid),
      do: Routes.path("/admin/settings/media?tab=renditions"),
      else: Routes.path("/admin/settings/media?tab=renditions&set=#{set.uuid}")
  end

  # A site library has a settings page; a user's own library does not.
  defp library_path(%{kind: "system", uuid: uuid}),
    do: Routes.path("/admin/settings/media/libraries/#{uuid}")

  defp library_path(_library), do: nil

  # An edited image keeps its unedited original as a hidden child file; what is
  # known of it is shown here, and whether the edit is still rendering.
  defp backup_report(file) do
    with true <- ImageEditing.edited?(file),
         %StorageFile{} = backup <- ImageEditing.backup(file) do
      instance = Storage.get_file_instance_by_name(backup.uuid, "original")
      rows = FileReport.renditions(backup)

      %{file: backup, instance: instance, copies: rows |> List.first() |> Map.get(:copies, [])}
    else
      _ -> nil
    end
  end

  defp preview_url(file) do
    instance =
      Storage.get_file_instance_by_name(file.uuid, "thumbnail") ||
        Storage.get_file_instance_by_name(file.uuid, "original")

    instance &&
      file.file_type == "image" &&
      URLSigner.signed_url(file.uuid, instance.variant_name,
        version: instance,
        private: Libraries.private_file?(file)
      )
  end

  defp connected_user_agent(socket) do
    if connected?(socket), do: get_connect_info(socket, :user_agent)
  rescue
    _ -> nil
  end

  # An Owner/Admin opening a file of someone's user library, as neither its
  # uploader nor one of the library's people: written to the audit log once per
  # page, the same as opening the library at `/admin/libraries/<uuid>`.
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
      Logger.error("MediaStorage: audit entry failed: #{Exception.message(error)}")
      socket
  catch
    # A dead pool exits rather than raises; the page must still show.
    :exit, reason ->
      Logger.error("MediaStorage: audit entry failed: #{inspect(reason)}")
      socket
  end

  # ──────────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────────

  # Every event below changes storage or reads every copy back: refused
  # unless the viewer may manage media storage (the buttons are not drawn for
  # anyone else, but a hidden button is not a boundary).
  def handle_event(_event, _params, %{assigns: %{file: nil}} = socket), do: {:noreply, socket}

  def handle_event(_event, _params, %{assigns: %{can_manage: false}} = socket),
    do: {:noreply, put_flash(socket, :error, gettext("You may not change storage."))}

  def handle_event(_event, _params, %{assigns: %{working: working}} = socket)
      when not is_nil(working),
      do: {:noreply, put_flash(socket, :info, gettext("Something is already running."))}

  def handle_event(event, params, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    file = Storage.get_file(socket.assigns.file.uuid)

    if file && visible?(scope, file) && Libraries.can?(scope, file, :edit) do
      handle_storage_event(event, params, assign(socket, :file, file))
    else
      {:noreply, put_flash(socket, :error, gettext("You may not change storage."))}
    end
  end

  defp handle_storage_event("verify", _params, socket) do
    file = socket.assigns.file
    audit = Keyword.put(Actor.opts(socket), :found_by, "verify")

    {:noreply,
     socket
     |> assign(:working, :verify)
     |> assign(:verification, nil)
     |> start_async(:verify, fn -> FileReport.verify(file, audit: audit) end)}
  end

  # Everything that can be wrong with this file's objects, put right
  # (`FileRepair`): copies read back, bad ones replaced from good ones or made
  # again, what the profile wants made, then read back once more.
  defp handle_storage_event("fix", _params, socket) do
    file = socket.assigns.file
    actor = Actor.opts(socket)

    {:noreply,
     socket
     |> assign(:working, :fix)
     |> assign(:verification, nil)
     |> assign(:repair, nil)
     |> start_async(:fix, fn ->
       # Only the waiter belongs to the page. A supervised repair keeps running
       # if navigation closes the LiveView after it has changed some objects.
       PhoenixKit.TaskSupervisor
       |> Task.Supervisor.async_nolink(fn -> FileRepair.repair(file, actor) end)
       |> Task.await(:infinity)
     end)}
  end

  defp handle_storage_event("make", %{"name" => name}, socket) do
    file = socket.assigns.file

    case Enum.find(VariantGenerator.expected_variants(file), fn {_d, n, _f} -> n == name end) do
      {dimension, name, format} ->
        {:noreply,
         socket
         |> assign(:working, {:make, name})
         |> assign(:verification, nil)
         |> start_async(:make, fn ->
           VariantGenerator.generate_variant(file, dimension, name, format)
         end)}

      nil ->
        {:noreply, socket}
    end
  end

  defp handle_storage_event("regenerate_all", _params, socket) do
    file = socket.assigns.file

    {:noreply,
     socket
     |> assign(:working, :regenerate)
     |> assign(:verification, nil)
     |> start_async(:regenerate, fn -> VariantGenerator.generate_variants(file) end)}
  end

  defp handle_storage_event("revert", _params, socket) do
    {:noreply, after_edit_action(socket, ImageEditing.revert(socket.assigns.file, auth(socket)))}
  end

  defp handle_storage_event("retry_edit", _params, socket) do
    {:noreply, after_edit_action(socket, ImageEditing.retry(socket.assigns.file, auth(socket)))}
  end

  defp handle_storage_event("delete_unedited", _params, socket) do
    result = ImageEditing.delete_unedited_original(socket.assigns.file, auth(socket))
    {:noreply, after_edit_action(socket, result)}
  end

  defp auth(socket), do: [scope: socket.assigns[:phoenix_kit_current_scope]]

  defp after_edit_action(socket, {:ok, _file}), do: reload(socket)

  defp after_edit_action(socket, {:error, reason}),
    do: put_flash(socket, :error, edit_error(reason))

  defp edit_error(:forbidden), do: gettext("You may not change this image.")
  defp edit_error(:not_edited), do: gettext("This image has not been edited.")
  defp edit_error(:edit_in_progress), do: gettext("An edit is being applied. Try again shortly.")
  defp edit_error(:busy), do: gettext("Something is already running.")

  defp edit_error({:annotated, _count}),
    do: gettext("This image has annotations; restoring would move them.")

  defp edit_error(_reason), do: gettext("The change could not be made.")

  # ──────────────────────────────────────────────────────────────
  # Async results and storage events
  # ──────────────────────────────────────────────────────────────

  def handle_async(:verify, {:ok, results}, socket) do
    {:noreply, socket |> assign(:working, nil) |> assign(:verification, results)}
  end

  def handle_async(
        :fix,
        {:ok, {:ok, %{actions: actions, verification: verification} = done}},
        socket
      ) do
    problems = done.problems_left

    flash =
      if problems == 0,
        do: {:info, gettext("Everything is intact now.")},
        else:
          {:error,
           ngettext(
             "%{count} problem is left. See the report.",
             "%{count} problems are left. See the report.",
             problems
           )}

    {:noreply,
     socket
     |> assign(:repair, actions)
     |> assign(:verification, verification)
     |> finish(flash)}
  end

  def handle_async(:fix, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:working, nil)
     |> put_flash(:error, edit_error(reason))}
  end

  def handle_async(:make, {:ok, result}, socket) do
    flash =
      case result do
        {:ok, _} -> {:info, gettext("Rendition made.")}
        _ -> {:error, gettext("The rendition could not be made.")}
      end

    {:noreply, finish(socket, flash)}
  end

  def handle_async(:regenerate, {:ok, result}, socket) do
    flash =
      case result do
        {:ok, instances} ->
          {:info,
           ngettext(
             "Regenerated %{count} rendition.",
             "Regenerated %{count} renditions.",
             length(instances)
           )}

        _ ->
          {:error, gettext("The renditions could not be regenerated.")}
      end

    {:noreply, finish(socket, flash)}
  end

  def handle_async(_task, {:exit, reason}, socket) do
    Logger.warning("MediaStorage: task failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:working, nil)
     |> put_flash(:error, gettext("That did not finish. Try again."))}
  end

  defp finish(socket, {kind, message}) do
    socket |> assign(:working, nil) |> reload() |> put_flash(kind, message)
  end

  def handle_info({:phoenix_kit_file_processed, uuid}, %{assigns: %{file_uuid: uuid}} = socket),
    do: {:noreply, reload(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The file as it is now. A verification belongs to the bytes it read, so an
  # edit that replaced them drops it.
  defp reload(socket) do
    before = socket.assigns[:file] && socket.assigns.file.file_checksum
    socket = load(socket, socket.assigns.file_uuid)

    if socket.assigns.file && socket.assigns.file.file_checksum != before,
      do: assign(socket, :verification, nil),
      else: socket
  end

  # ──────────────────────────────────────────────────────────────
  # Template helpers
  # ──────────────────────────────────────────────────────────────

  @doc false
  def size_label(nil), do: "–"
  def size_label(bytes), do: Format.bytes(bytes, base: 1000, decimals: 2)

  @doc false
  def dimensions_label(%{width: w, height: h}) when is_integer(w) and is_integer(h),
    do: "#{w} × #{h}"

  def dimensions_label(_), do: "–"

  @doc false
  # What a size asks for, as its set states it: the edge it fits and its pixels.
  def spec_label(nil), do: "–"

  def spec_label(%{fit_by: "height", height: h}) when is_integer(h),
    do: gettext("%{px} px tall", px: h)

  def spec_label(%{maintain_aspect_ratio: false, width: w, height: h})
      when is_integer(w) and is_integer(h),
      do: "#{w} × #{h}"

  def spec_label(%{width: w}) when is_integer(w), do: gettext("%{px} px wide", px: w)
  def spec_label(_), do: "–"

  @doc false
  def short(nil), do: "–"
  def short(checksum), do: String.slice(checksum, 0, 12) <> "…"

  @doc false
  def state_badge(:ok), do: {"badge-success", gettext("Stored")}
  def state_badge(:missing), do: {"badge-error", gettext("Missing")}
  def state_badge(:stale), do: {"badge-warning", gettext("Out of date")}
  def state_badge(:processing), do: {"badge-info", gettext("Processing")}
  def state_badge(:failed), do: {"badge-error", gettext("Failed")}
  def state_badge(:no_copy), do: {"badge-error", gettext("No copy")}

  @doc false
  def kind_label(:original), do: gettext("Original")
  def kind_label(:size), do: gettext("Size")
  def kind_label(:alternative), do: gettext("Other format")
  def kind_label(:annotated), do: gettext("With annotations")
  def kind_label(:other), do: gettext("Other")

  @doc false
  def result_badge(:ok), do: {"badge-success", gettext("Matches")}
  def result_badge({:mismatch, _recorded, _actual}), do: {"badge-error", gettext("Differs")}
  def result_badge(:not_found), do: {"badge-error", gettext("Not in bucket")}
  def result_badge(:no_copy), do: {"badge-error", gettext("No copy")}
  def result_badge({:unrecorded, _actual}), do: {"badge-warning", gettext("No checksum recorded")}
  def result_badge({:error, _reason}), do: {"badge-error", gettext("Could not read")}

  @doc false
  def download_url(%FileInstance{} = instance, file) do
    url =
      URLSigner.signed_url(file.uuid, instance.variant_name,
        version: instance,
        private: Libraries.private_file?(file)
      )

    url <> if(String.contains?(url, "?"), do: "&", else: "?") <> "dl=1"
  end

  @doc false
  def download_name(file, instance),
    do: Storage.download_name(filename(file), instance.variant_name, instance.ext)

  @doc false
  def unedited_url(socket, file) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    FileController.unedited_url(socket, file.uuid, scope && Scope.user_uuid(scope))
  end

  @doc false
  def date(nil), do: "–"
  def date(value), do: UtilsDate.format_datetime_with_user_format(value)

  @doc false
  # The results of a verification by place: one group per bucket that held
  # anything of the file, a problems-first order, and a group for each bucket
  # of the file's storage profile that held nothing of it (not an error: a
  # profile wants a number of copies, not every bucket). Renditions with no
  # copy anywhere are their own group.
  def verification_groups(results, profile_buckets) do
    by_bucket = Enum.group_by(results, &(&1.bucket && &1.bucket.uuid))
    {nowhere, held} = Map.pop(by_bucket, nil, [])

    groups =
      for {_uuid, [%{bucket: bucket} | _] = rows} <- held do
        %{bucket: %{name: bucket.name, provider: bucket.provider}, rows: sort_rows(rows)}
        |> put_counts()
      end

    empty =
      for %{uuid: uuid} = bucket <- profile_buckets, not Map.has_key?(held, to_string(uuid)) do
        %{bucket: %{name: bucket.name, provider: nil}, rows: []} |> put_counts()
      end

    lost =
      if nowhere == [],
        do: [],
        else: [put_counts(%{bucket: nil, rows: sort_rows(nowhere)})]

    Enum.sort_by(groups, &{&1.state == :ok, &1.bucket.name}) ++ empty ++ lost
  end

  defp sort_rows(rows), do: Enum.sort_by(rows, &{&1.result == :ok, &1.name})

  defp put_counts(%{rows: rows} = group) do
    ok = Enum.count(rows, &(&1.result == :ok))
    total = length(rows)

    state =
      cond do
        group.bucket == nil -> :problem
        total == 0 -> :empty
        ok == total -> :ok
        true -> :problem
      end

    Map.merge(group, %{ok: ok, total: total, state: state})
  end

  @doc false
  # The fix button is the main action when something is known to be wrong: a
  # rendition missing, out of date or without a copy, or a verification that
  # found a bad copy.
  def needs_fixing?(problems, verification),
    do: problems != [] or (is_list(verification) and not FileReport.all_ok?(verification))

  @doc false
  # One line for each thing the fixer did.
  def action_text(%{kind: :restored, bucket: bucket, from: from}),
    do: gettext("Copied back into %{bucket} from %{from}.", bucket: bucket, from: from)

  def action_text(%{kind: :regenerated}), do: gettext("Made again from the original.")
  def action_text(%{kind: :made}), do: gettext("Made from the original.")

  def action_text(%{kind: :copied, bucket: bucket}),
    do: gettext("Copied into %{bucket}.", bucket: bucket)

  def action_text(%{kind: :removed, bucket: bucket}),
    do: gettext("Removed from %{bucket}, which the profile no longer uses.", bucket: bucket)

  def action_text(%{kind: :recorded, bucket: bucket}),
    do: gettext("Found in %{bucket} and recorded.", bucket: bucket)

  def action_text(%{kind: :unrecoverable}),
    do: gettext("No good copy exists anywhere, and it cannot be made again.")

  def action_text(%{kind: :unreadable, bucket: bucket}),
    do: gettext("Could not be read from %{bucket}; left as it is.", bucket: bucket)

  def action_text(%{kind: :skipped}),
    do: gettext("Not made again: the original is damaged.")

  def action_text(%{kind: :failed, bucket: bucket}) when is_binary(bucket),
    do: gettext("Could not be fixed in %{bucket}.", bucket: bucket)

  def action_text(%{kind: :failed}), do: gettext("Could not be made again.")

  def action_text(%{kind: :reconciled, outcome: :reconciled}),
    do: gettext("Sizes and copies match the library's profiles.")

  def action_text(%{kind: :reconciled, outcome: :skipped}),
    do: gettext("Another pass is working on this file.")

  def action_text(%{kind: :reconciled}),
    do: gettext("Not everything the profiles ask for could be made.")

  @doc false
  def action_tone(%{kind: kind})
      when kind in [:restored, :regenerated, :recorded, :made, :copied, :removed],
      do: "badge-success"

  def action_tone(%{kind: :reconciled, outcome: :reconciled}), do: "badge-success"
  def action_tone(%{kind: kind}) when kind in [:skipped, :reconciled], do: "badge-warning"
  def action_tone(_action), do: "badge-error"

  @doc false
  def verified_summary(results) do
    total = length(results)
    ok = Enum.count(results, &(&1.result == :ok))
    {ok, total}
  end

  @doc false
  def checksum_of(%{instance: %{checksum: sum}}) when is_binary(sum) and sum != "", do: sum
  def checksum_of(_), do: nil
end
