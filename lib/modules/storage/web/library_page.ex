defmodule PhoenixKitWeb.Live.Modules.Storage.LibraryPage do
  @moduledoc """
  One system library on one page (Settings → Media → Libraries → the library's
  name): what it holds and where, how it is syncing, its annotated-thumbnail
  choice, who changed it, and renaming or deleting it.

  Where a library keeps its files (its storage profile) and which sizes it gets
  (its variant set) are shown here and **not changed**: they are chosen when the
  library is created. Moving files to other buckets is done on the profile
  (Storage profiles tab), which moves every library on it in the background.

  Nothing slow is read in `mount/3`. The library, its profile and its history
  load in `handle_params/3`; the per-bucket breakdown scans location rows, so it
  runs in `start_async`. A user's library never opens here: it is loaded
  through `Libraries.get_system_library_with_stats/1`.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query
  import PhoenixKitWeb.Components.Core.ActivityList, only: [activity_list: 1]
  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]
  import PhoenixKitWeb.Live.Modules, only: [format_bytes: 1]

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Jobs.Events
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.AnnotationThumbnail
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.LibraryState
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Live.Modules.Storage.BucketInfo
  alias PhoenixKitWeb.Live.Modules.Storage.LibrarySync

  @history_per_page 15

  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSubManager.subscribe(Activity.pubsub_topic())
      Events.subscribe()
    end

    {:ok,
     socket
     |> assign(:project_title, Settings.get_project_title())
     |> assign(:current_path, Routes.path("/admin/settings/media"))
     |> assign(:page_title, gettext("Library"))
     |> assign(:library, nil)
     |> assign(:stats, nil)
     |> assign(:sync, nil)
     |> assign(:profile, nil)
     |> assign(:variant_set_name, nil)
     |> assign(:annotated_choice, "default")
     |> assign(:annotated_default, false)
     |> assign(:deep_zoom?, false)
     |> assign(:bucket_totals, nil)
     |> assign(:buckets_failed?, false)
     |> assign(:bucket_infos, %{})
     |> assign(:connections, %{})
     |> assign(:history, nil)
     |> assign(:history_page, 1)
     |> assign(:renaming?, false)}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case Libraries.get_system_library_with_stats(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Library not found"))
         |> push_navigate(to: libraries_path())}

      %{library: library} = stats ->
        {:noreply,
         socket
         |> assign(bucket_totals: nil, buckets_failed?: false, renaming?: false)
         |> assign_library(stats)
         |> assign(:page_title, library.name)
         |> assign(:history_page, 1)
         |> load_storage()
         |> load_sync()
         |> load_history()
         |> load_async()}
    end
  end

  # ---- events ----

  def handle_event("start_rename", _params, socket),
    do: {:noreply, assign(socket, :renaming?, true)}

  def handle_event("cancel_rename", _params, socket),
    do: {:noreply, assign(socket, :renaming?, false)}

  def handle_event(event, params, socket) when event in ~w(rename delete annotated deep_zoom) do
    case Libraries.get_system_library_with_stats(socket.assigns.library.uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Library not found"))
         |> push_navigate(to: libraries_path())}

      %{library: library} = stats ->
        handle_library_event(event, params, socket, library, stats)
    end
  end

  def handle_event("sync", %{"action" => action}, socket) do
    library = socket.assigns.library
    scope = socket.assigns.phoenix_kit_current_scope

    case LibrarySync.run(action, library.uuid, socket.assigns.sync, scope) do
      {:ok, _run} ->
        {:noreply, load_sync(socket)}

      {:error, reason} ->
        {:noreply, socket |> load_sync() |> put_flash(:error, LibrarySync.error_message(reason))}
    end
  end

  def handle_event("history_page", %{"page" => page}, socket) do
    case Integer.parse(to_string(page)) do
      {page, ""} when page > 0 ->
        {:noreply, socket |> assign(:history_page, page) |> load_history()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket),
    do: {:noreply, socket |> reload() |> load_history() |> load_async()}

  defp handle_library_event("rename", %{"name" => name}, socket, library, _stats) do
    case Libraries.rename_library(library, name, Actor.opts(socket)) do
      {:ok, renamed} ->
        {:noreply,
         socket
         |> assign(:renaming?, false)
         |> assign(:library, renamed)
         |> assign(:page_title, renamed.name)
         |> load_history()
         |> put_flash(:info, gettext("Library renamed to \"%{name}\"", name: renamed.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, rename_error(changeset))}
    end
  end

  defp handle_library_event("delete", _params, socket, library, _stats) do
    case Libraries.delete_library(library, Actor.opts(socket)) do
      {:ok, _library} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Library deleted"))
         |> push_navigate(to: libraries_path())}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Only an empty library can be deleted, and never the default one.")
         )}
    end
  end

  defp handle_library_event("annotated", %{"annotated" => choice}, socket, library, stats),
    do: put_viewing(:annotated_thumbnails, choice, socket, library, stats)

  defp handle_library_event("deep_zoom", %{"deep_zoom" => choice}, socket, library, stats),
    do: put_viewing(:deep_zoom, choice, socket, library, stats)

  defp put_viewing(key, choice, socket, library, stats) do
    value =
      case choice do
        "on" -> true
        "off" -> false
        _ -> nil
      end

    case Libraries.put_setting(library, key, value, Actor.opts(socket)) do
      {:ok, library} ->
        {:noreply,
         socket
         |> assign_library(%{stats | library: library})
         |> load_history()
         |> put_flash(:info, gettext("Library setting saved"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save"))}
    end
  end

  # ---- async results ----

  def handle_async(:buckets, {:ok, {totals, infos}}, socket) do
    {:noreply, assign(socket, bucket_totals: totals, bucket_infos: infos, buckets_failed?: false)}
  end

  def handle_async(:buckets, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :buckets_failed?, true)}

  # ---- messages ----

  # A storage entry about this library arrived: the history follows it live.
  def handle_info({:activity_logged, %{module: "storage"} = entry}, socket) do
    uuid = socket.assigns.library && to_string(socket.assigns.library.uuid)

    if uuid && to_string(entry.resource_uuid) == uuid do
      {:noreply, socket |> reload() |> load_history()}
    else
      {:noreply, socket}
    end
  end

  # Its reconcile run moved: the sync state follows.
  def handle_info({:job_run, _action, %{kind: "storage.reconcile"}}, socket),
    do: {:noreply, if(socket.assigns.library, do: load_sync(socket), else: socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # ---- loading ----

  defp assign_library(socket, %{library: library} = stats) do
    socket
    |> assign(:library, library)
    |> assign(:stats, Map.delete(stats, :library))
    |> assign(:annotated_choice, annotated_choice(library))
    |> assign(:annotated_default, AnnotationThumbnail.enabled?())
    |> assign(:deep_zoom?, VariantSets.deep_zoom_for_library?(library.uuid))
  end

  # Another admin may have changed or removed the library since the page opened.
  defp reload(socket) do
    case Libraries.get_system_library_with_stats(socket.assigns.library.uuid) do
      nil ->
        socket
        |> put_flash(:error, gettext("Library not found"))
        |> push_navigate(to: libraries_path())

      %{library: library} = stats ->
        socket
        |> assign_library(stats)
        |> assign(:page_title, library.name)
        |> load_storage()
        |> load_sync()
    end
  end

  # The library's profile (with its buckets) and variant set, by name.
  defp load_storage(socket) do
    library = socket.assigns.library

    assign(socket,
      profile: library |> Profiles.profile_uuid_for() |> Profiles.get_profile() |> without_keys(),
      connections: BucketInfo.connections(),
      variant_set_name: VariantSets.set_name(VariantSets.set_uuid_for(library))
    )
  end

  defp load_sync(socket) do
    assign(socket, :sync, LibraryState.for_library(socket.assigns.library.uuid))
  end

  defp load_async(socket) do
    uuid = socket.assigns.library.uuid

    start_async(socket, :buckets, fn ->
      connections = BucketInfo.connections()

      infos =
        Map.new(Storage.list_buckets(), &{to_string(&1.uuid), bucket_info(&1, connections)})

      {Storage.library_bucket_totals(uuid), infos}
    end)
  end

  defp load_history(socket) do
    uuid = to_string(socket.assigns.library.uuid)

    result =
      Activity.list(
        query: history_query(uuid),
        page: socket.assigns.history_page,
        per_page: @history_per_page,
        preload: [:actor]
      )

    last = max(1, result.total_pages)

    if socket.assigns.history_page > last,
      do: socket |> assign(:history_page, last) |> load_history(),
      else: assign(socket, :history, result)
  end

  # The library's own lifecycle entries (created, renamed, deleted, setting
  # changed) name it as the resource.
  defp history_query(uuid) do
    from(e in Entry, where: e.module == ^Audit.module_key() and e.resource_uuid == ^uuid)
  end

  # ---- helpers for the template ----

  # A bucket in words, for a list: its name, type, service and where its files
  # go. Never a key: the page's state holds names and paths only.
  defp bucket_info(bucket, connections) do
    %{
      name: bucket.name,
      type: BucketInfo.type(bucket),
      service: BucketInfo.service(bucket, connections),
      location: BucketInfo.location(bucket)
    }
  end

  # A profile's buckets come with any keys a legacy bucket carries; none of them
  # is needed here, so none stays in the assigns.
  defp without_keys(nil), do: nil

  defp without_keys(profile) do
    %{
      profile
      | buckets:
          Enum.map(profile.buckets, fn row ->
            %{row | bucket: %{row.bucket | access_key_id: nil, secret_access_key: nil}}
          end)
    }
  end

  defp libraries_path, do: Routes.path("/admin/settings/media?tab=libraries")
  defp profiles_path, do: Routes.path("/admin/settings/media?tab=profiles")

  # The tab of the library's rendition set.
  defp rendition_set_path(library) do
    uuid = VariantSets.set_uuid_for(library)

    if VariantSets.default?(uuid),
      do: Routes.path("/admin/settings/media?tab=renditions"),
      else: Routes.path("/admin/settings/media?tab=renditions&set=#{uuid}")
  end

  defp media_path(%{is_default: true}), do: Routes.path("/admin/media")
  defp media_path(%{slug: slug}), do: Routes.path("/admin/media/library/#{slug}")

  defp annotated_choice(library) do
    case Libraries.setting(library, :annotated_thumbnails) do
      true -> "on"
      false -> "off"
      nil -> "default"
    end
  end

  defp sync_badge_class(:up_to_date), do: "badge-success"
  defp sync_badge_class(:syncing), do: "badge-info"
  defp sync_badge_class(:attention), do: "badge-error"
  defp sync_badge_class(_state), do: "badge-warning"

  defp sync_state_label(:up_to_date), do: gettext("Up to date")
  defp sync_state_label(:syncing), do: gettext("Syncing")
  defp sync_state_label(:paused), do: gettext("Paused")
  defp sync_state_label(:waiting), do: gettext("Waiting")
  defp sync_state_label(:attention), do: gettext("Needs attention")

  defp can_view_activity?(assigns),
    do: Scope.has_module_access?(assigns[:phoenix_kit_current_scope], "dashboard")

  defp rename_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Map.values()
    |> List.flatten()
    |> Enum.join("; ")
    |> then(&(gettext("Library name") <> ": " <> &1))
  end

  defp role_label("primary"), do: gettext("primary")
  defp role_label("replica"), do: gettext("replica")
  defp role_label("backup"), do: gettext("backup")
  defp role_label(other), do: to_string(other)

  defp status_label("active"), do: gettext("active")
  defp status_label("read_only"), do: gettext("read only")
  defp status_label("draining"), do: gettext("draining")
  defp status_label(other), do: to_string(other)

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp format_time(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
