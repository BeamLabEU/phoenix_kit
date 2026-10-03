defmodule PhoenixKitWeb.Live.Modules.Storage.BucketPage do
  @moduledoc """
  One site bucket on one page (Settings → Media → Buckets → the bucket's name):
  what it is, which storage profiles use it, what it holds, whether it is
  healthy, and who changed it. Editing stays on `BucketForm`; this page links
  to it.

  Nothing is read in `mount/3`. The bucket, the profiles that use it and its
  history load in `handle_params/3`; the contents and the location health scan
  every location row of the bucket, so they run in `start_async`. The
  connection probe writes, reads and deletes a real object, so it runs only
  when someone clicks **Test connection**.

  A user's own bucket (V206) never opens here: it is loaded through
  `Storage.get_site_bucket/1`. A user's storage profile and library are counted,
  never named.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query
  import PhoenixKitWeb.Components.Core.ActivityList, only: [activity_list: 1]
  import PhoenixKitWeb.Live.Modules, only: [format_bytes: 1]

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.BucketCredentials
  alias PhoenixKit.Modules.Storage.Locations
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Live.Modules.Storage.BucketInfo
  alias PhoenixKitWeb.Live.Modules.Storage.BucketUsage

  @history_per_page 15

  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSubManager.subscribe(Activity.pubsub_topic())

    {:ok,
     socket
     |> assign(:project_title, Settings.get_project_title())
     |> assign(:current_path, Routes.path("/admin/settings/media"))
     |> assign(:page_title, gettext("Bucket"))
     |> assign(:bucket, nil)
     |> assign(:connections, %{})
     |> assign(:usage, [])
     |> assign(:libraries_by_profile, %{})
     |> assign(:addable_profiles, [])
     |> assign(:contents, nil)
     |> assign(:contents_failed?, false)
     |> assign(:location_health, nil)
     |> assign(:unchecked_instances, nil)
     |> assign(:free_space_mb, nil)
     |> assign(:probing?, false)
     |> assign(:probe, nil)
     |> assign(:history, nil)
     |> assign(:history_page, 1)}
  end

  def handle_params(%{"id" => id}, _uri, socket) do
    case Storage.get_site_bucket(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Bucket not found"))
         |> push_navigate(to: Routes.path("/admin/settings/media"))}

      bucket ->
        {:noreply,
         socket
         |> assign(:bucket, bucket)
         |> assign(:page_title, bucket.name)
         |> assign(:connections, BucketInfo.connections())
         |> assign(:history_page, 1)
         |> load_usage()
         |> load_history()
         |> load_async()}
    end
  end

  # ---- events ----

  def handle_event("probe", _params, %{assigns: %{probing?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("probe", _params, socket) do
    uuid = socket.assigns.bucket.uuid

    # start_async is unlinked: an HTTP-pool exit inside the probe (an exit, not
    # a raise — the probe only rescues) must not take the page down. The bucket
    # is read again inside the task so no key passes through the assigns.
    {:noreply,
     socket
     |> assign(:probing?, true)
     |> start_async(:probe, fn ->
       started = System.monotonic_time(:millisecond)

       result =
         case Storage.get_site_bucket(uuid) do
           nil -> {:error, "Bucket not found"}
           bucket -> Storage.probe_bucket(bucket)
         end

       {result, System.monotonic_time(:millisecond) - started}
     end)}
  end

  def handle_event("toggle", _params, socket) do
    bucket = socket.assigns.bucket
    enabled = !bucket.enabled

    case Storage.update_bucket(bucket, %{enabled: enabled}, Actor.opts(socket)) do
      {:ok, bucket} ->
        message =
          if enabled,
            do: gettext("Bucket enabled successfully"),
            else: gettext("Bucket disabled successfully")

        {:noreply,
         socket |> assign(:bucket, bucket) |> load_history() |> put_flash(:info, message)}

      {:error, {:in_use, usage}} ->
        {:noreply,
         put_flash(socket, :error, BucketUsage.refusal_message(:disable, bucket, usage))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update bucket"))}
    end
  end

  def handle_event("delete", _params, socket) do
    bucket = socket.assigns.bucket

    case Storage.delete_bucket(bucket, Actor.opts(socket)) do
      {:ok, _bucket} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Bucket deleted successfully"))
         |> push_navigate(to: Routes.path("/admin/settings/media"))}

      {:error, {:in_use, usage}} ->
        {:noreply, put_flash(socket, :error, BucketUsage.refusal_message(:delete, bucket, usage))}

      {:error, %Ecto.Changeset{} = changeset} ->
        message =
          if Keyword.has_key?(changeset.errors, :file_locations),
            do:
              gettext(
                "This bucket still holds files, so it cannot be deleted. Disable it to stop storing new files there."
              ),
            else: gettext("Failed to delete bucket")

        {:noreply, put_flash(socket, :error, message)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete bucket"))}
    end
  end

  def handle_event("add_to_profile", %{"profile_uuid" => profile_uuid}, socket) do
    bucket = socket.assigns.bucket

    case Profiles.add_bucket(profile_uuid, bucket, Actor.opts(socket)) do
      :ok ->
        {:noreply,
         socket
         |> load_usage()
         |> load_history()
         |> put_flash(:info, gettext("Bucket added to the storage profile"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to add the bucket to the profile"))}
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
    do: {:noreply, socket |> load_usage() |> load_history() |> load_async()}

  # ---- async results ----

  def handle_async(:contents, {:ok, {contents, health, unchecked, free_mb}}, socket) do
    {:noreply,
     assign(socket,
       contents: contents,
       contents_failed?: false,
       location_health: health,
       unchecked_instances: unchecked,
       free_space_mb: free_mb
     )}
  end

  def handle_async(:contents, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, :contents_failed?, true)}

  def handle_async(:probe, {:ok, {result, ms}}, socket) do
    {:noreply, assign(socket, probing?: false, probe: probe_result(result, ms))}
  end

  def handle_async(:probe, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       probing?: false,
       probe: probe_result({:error, gettext("The connection test crashed unexpectedly")}, nil)
     )}
  end

  # ---- messages ----

  # A storage entry about this bucket arrived: the history follows it live.
  def handle_info({:activity_logged, %{module: "storage"} = entry}, socket) do
    uuid = socket.assigns.bucket && to_string(socket.assigns.bucket.uuid)

    if uuid && (to_string(entry.resource_uuid) == uuid or entry.metadata["bucket_uuid"] == uuid) do
      {:noreply, socket |> load_bucket() |> load_usage() |> load_history()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ---- loading ----

  # Another admin may have edited or removed the bucket since the page opened.
  defp load_bucket(socket) do
    case Storage.get_site_bucket(socket.assigns.bucket.uuid) do
      nil ->
        socket
        |> put_flash(:error, gettext("Bucket not found"))
        |> push_navigate(to: Routes.path("/admin/settings/media"))

      bucket ->
        assign(socket, bucket: bucket, page_title: bucket.name)
    end
  end

  defp load_usage(socket) do
    uuid = to_string(socket.assigns.bucket.uuid)
    usage = Map.get(Profiles.bucket_usage([uuid]), uuid, [])
    used = MapSet.new(usage, & &1.profile_uuid)

    libraries =
      for row <- usage, is_nil(row.owner_uuid), into: %{} do
        {row.profile_uuid, Profiles.library_names_using(row.profile_uuid)}
      end

    addable =
      Profiles.list_profiles() |> Enum.reject(&MapSet.member?(used, to_string(&1.uuid)))

    assign(socket, usage: usage, libraries_by_profile: libraries, addable_profiles: addable)
  end

  defp load_async(socket) do
    bucket = socket.assigns.bucket

    start_async(socket, :contents, fn ->
      {Storage.bucket_contents(bucket.uuid), Storage.bucket_location_health(bucket.uuid),
       Locations.missing_count(), free_space_mb(bucket)}
    end)
  end

  # A local bucket's free space is the disk's, a cloud bucket's what its
  # configured size has left; neither exists for a cloud bucket with no size.
  defp free_space_mb(%{provider: "local"} = bucket),
    do: Storage.calculate_bucket_free_space(bucket)

  defp free_space_mb(%{max_size_mb: nil}), do: nil
  defp free_space_mb(bucket), do: Storage.calculate_bucket_free_space(bucket)

  defp load_history(socket) do
    uuid = to_string(socket.assigns.bucket.uuid)

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

  # The bucket's own lifecycle entries name it as the resource. The changes to
  # its rows in profiles name the profile as the resource and the bucket in the
  # metadata.
  defp history_query(uuid) do
    from(e in Entry,
      where:
        e.module == ^Audit.module_key() and
          (e.resource_uuid == ^uuid or fragment("?->>'bucket_uuid' = ?", e.metadata, ^uuid))
    )
  end

  defp probe_result(:ok, ms), do: %{ok?: true, error: nil, ms: ms, at: DateTime.utc_now()}

  defp probe_result({:error, reason}, ms),
    do: %{ok?: false, error: error_text(reason), ms: ms, at: DateTime.utc_now()}

  defp probe_result(_other, ms),
    do: %{ok?: false, error: gettext("Unknown result"), ms: ms, at: DateTime.utc_now()}

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)

  # ---- helpers for the template ----

  defp can_manage_integrations?(assigns),
    do: Scope.has_module_access?(assigns[:phoenix_kit_current_scope], "integrations_system")

  defp can_view_activity?(assigns),
    do: Scope.has_module_access?(assigns[:phoenix_kit_current_scope], "dashboard")

  defp connection_name(bucket, connections) do
    case connections[bucket.integration_uuid] do
      %{name: name} -> name
      _ -> nil
    end
  end

  defp legacy?(bucket), do: BucketCredentials.legacy?(bucket)

  defp access_label("public"), do: gettext("Public")
  defp access_label("private"), do: gettext("Private (proxied)")
  defp access_label("signed"), do: gettext("Signed URLs")
  defp access_label(other), do: to_string(other)

  defp role_label("primary"), do: gettext("primary")
  defp role_label("replica"), do: gettext("replica")
  defp role_label("backup"), do: gettext("backup")
  defp role_label(other), do: to_string(other)

  defp status_label("active"), do: gettext("active")
  defp status_label("read_only"), do: gettext("read only")
  defp status_label("draining"), do: gettext("draining")
  defp status_label(other), do: to_string(other)

  defp draining?(usage), do: Enum.any?(usage, &(&1.status == "draining"))

  # Used share of the configured size, 0..100; nil when there is no size.
  defp capacity_percent(%{max_size_mb: max}, %{bytes: bytes}) when is_integer(max) and max > 0,
    do: min(100, round(bytes / (max * 1_048_576) * 100))

  defp capacity_percent(_bucket, _contents), do: nil

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")

  defp format_time(%NaiveDateTime{} = at),
    do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
end
