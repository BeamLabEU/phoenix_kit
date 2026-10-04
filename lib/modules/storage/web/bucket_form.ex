defmodule PhoenixKitWeb.Live.Modules.Storage.BucketForm do
  @moduledoc """
  Bucket form LiveView for storage bucket management.

  Provides form interface for creating and editing storage buckets.

  A cloud bucket takes its keys from an `object_storage` connection under
  **Settings → Integrations**; the form has no key fields. A bucket saved
  before that, which still carries its own keys, keeps working and offers to
  move them (`Storage.BucketCredentials`).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Events, as: IntegrationEvents
  alias PhoenixKit.Integrations.ObjectStorageServices, as: Services
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.BucketCredentials
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Live.Modules.Storage.BucketUsage

  @cloud_providers ~w(s3 b2 r2 tigris)

  def mount(_params, _session, socket) do
    if connected?(socket), do: IntegrationEvents.subscribe()

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:current_path, Routes.path("/admin/settings/media"))
      |> assign(:pending_bucket_params, nil)
      |> assign(:show_create_path_modal, false)
      |> assign(:missing_path, nil)
      |> assign(:path_status, nil)
      |> assign(:connection_status, nil)
      |> assign(:connection_error, nil)
      |> assign(:testing_connection, false)
      |> assign(:connections, [])
      |> assign(:selected_connection_uuid, nil)
      |> assign(:usage, [])
      |> assign(:profiles, [])
      |> assign(:profile_uuid, "")

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    bucket_uuid = params["id"]
    mode = if bucket_uuid, do: :edit, else: :new
    bucket = if mode == :edit, do: Storage.get_site_bucket(bucket_uuid)

    if mode == :edit and is_nil(bucket) do
      {:noreply,
       socket
       |> put_flash(:error, gettext("Bucket not found"))
       |> push_navigate(to: Routes.path("/admin/settings/media"))}
    else
      # No attrs: an edit form starts from the stored bucket as it is. Passing
      # the stored fields back in put the encrypted secret into the page.
      changeset = Storage.change_bucket(bucket || %Bucket{}, %{})

      {:noreply,
       socket
       |> assign(:mode, mode)
       |> assign(:bucket_uuid, bucket_uuid)
       |> assign(:page_title, page_title(mode))
       |> assign(:bucket, bucket)
       |> assign(:usage, bucket_usage(bucket))
       |> assign(:profiles, if(mode == :new, do: Profiles.list_profiles(), else: []))
       |> assign(:changeset, changeset)
       |> assign(:current_provider, get_current_provider(changeset, bucket))
       |> assign(:selected_connection_uuid, bucket && bucket.integration_uuid)
       |> assign_path_status()
       |> assign_connections()}
    end
  end

  def handle_event("validate", %{"bucket" => bucket_params}, socket) do
    # The profile choice is not a bucket field: it is kept apart from the changeset.
    {profile_uuid, bucket_params} = Map.pop(bucket_params, "profile_uuid")
    bucket_params = normalize_params(bucket_params, socket)
    changeset = Storage.change_bucket(socket.assigns.bucket || %Bucket{}, bucket_params)

    # A changed form is no longer what the last test ran against.
    socket =
      socket
      |> assign(:profile_uuid, profile_uuid || socket.assigns.profile_uuid)
      |> assign(:changeset, changeset)
      |> assign(:current_provider, get_current_provider(changeset, socket.assigns.bucket))
      |> assign_path_status()
      |> assign(
        :selected_connection_uuid,
        Ecto.Changeset.get_field(changeset, :integration_uuid)
      )
      |> assign(:connection_status, nil)
      |> assign(:connection_error, nil)

    {:noreply, socket}
  end

  def handle_event("test_connection", _params, socket) do
    changeset = socket.assigns.changeset

    bucket_params =
      Map.new(
        ~w(name provider region endpoint bucket_name access_key_id secret_access_key integration_uuid),
        &{&1, Ecto.Changeset.get_field(changeset, String.to_existing_atom(&1))}
      )

    # start_async is unlinked: an HTTP-pool exit inside the probe (an exit,
    # not a raise — test_connection only rescues) must not take the form down.
    socket =
      socket
      |> assign(:testing_connection, true)
      |> start_async(:test_connection, fn -> Storage.test_connection(bucket_params) end)

    {:noreply, socket}
  end

  def handle_event("save", %{"bucket" => bucket_params}, socket) do
    bucket_params = normalize_params(bucket_params, socket)
    provider = Map.get(bucket_params, "provider")
    endpoint = Map.get(bucket_params, "endpoint")

    cond do
      provider != "local" ->
        # Not a local bucket, proceed with save
        save_bucket(socket, bucket_params)

      is_nil(endpoint) ->
        # No endpoint provided, will be handled by changeset validation
        save_bucket(socket, bucket_params)

      true ->
        # Local bucket with endpoint - validate path first
        handle_local_bucket_save(socket, bucket_params, endpoint)
    end
  end

  def handle_event("move_credentials", _params, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    if Scope.has_module_access?(scope, "integrations_system") do
      do_move_credentials(socket)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Moving keys creates an integration, which needs access to Integrations.")
       )}
    end
  end

  def handle_event("confirm_create_path", %{"path" => expanded_path}, socket) do
    # User confirmed, create the directory and save
    case Storage.create_directory(expanded_path) do
      {:ok, _} ->
        # Directory created, proceed with save
        bucket_params = socket.assigns.pending_bucket_params

        flash_socket =
          socket
          |> put_flash(:info, "Storage path created: #{expanded_path}")

        socket =
          flash_socket
          |> assign(:pending_bucket_params, nil)
          |> assign(:show_create_path_modal, false)
          |> assign(:missing_path, nil)

        case socket.assigns.mode do
          :new -> create_bucket(socket, bucket_params)
          :edit -> update_bucket(socket, bucket_params)
        end

      {:error, reason} ->
        # Failed to create, redirect back with error
        socket =
          socket
          |> put_flash(
            :error,
            "Storage path could not be created: #{inspect(reason)}. Please create it manually."
          )
          |> assign(:show_create_path_modal, false)
          |> push_navigate(
            to: socket.assigns.current_path || Routes.path("/admin/settings/media")
          )

        {:noreply, socket}
    end
  end

  def handle_event("cancel_create_path", _params, socket) do
    # User cancelled, close modal
    socket =
      socket
      |> assign(:pending_bucket_params, nil)
      |> assign(:show_create_path_modal, false)
      |> assign(:missing_path, nil)

    {:noreply, socket}
  end

  def handle_async(:test_connection, {:ok, result}, socket) do
    {status, error} =
      case result do
        :ok -> {:success, nil}
        {:error, reason} -> {:failed, reason}
      end

    socket =
      socket
      |> assign(:connection_status, status)
      |> assign(:connection_error, error)
      |> assign(:testing_connection, false)

    {:noreply, socket}
  end

  def handle_async(:test_connection, {:exit, _reason}, socket) do
    socket =
      socket
      |> assign(:connection_status, :failed)
      |> assign(:connection_error, "Connection test crashed unexpectedly")
      |> assign(:testing_connection, false)

    {:noreply, socket}
  end

  # A connection added, changed or removed on another tab (the "Add a
  # connection" link opens Integrations there) shows up in the picker at once.
  def handle_info({event, "object_storage", _}, socket)
      when event in [
             :integration_setup_saved,
             :integration_connection_added,
             :integration_connection_removed,
             :integration_validated
           ],
      do: {:noreply, assign_connections(socket)}

  def handle_info({:integration_connection_renamed, "object_storage", _old, _new}, socket),
    do: {:noreply, assign_connections(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp do_move_credentials(socket) do
    case BucketCredentials.move_to_integration(socket.assigns.bucket,
           actor_uuid: Actor.uuid(socket)
         ) do
      {:ok, moved} ->
        changeset = Storage.change_bucket(moved, %{})

        {:noreply,
         socket
         |> assign(:bucket, moved)
         |> assign(:changeset, changeset)
         |> assign(:selected_connection_uuid, moved.integration_uuid)
         |> assign(:connection_status, nil)
         |> assign_connections()
         |> put_flash(:info, gettext("The keys now live in an integration."))}

      {:error, :unreadable_credentials} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "The saved keys could not be read, so they were not moved. Pick a connection with working keys instead."
           )
         )}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("The keys could not be moved. Nothing was changed."))}
    end
  end

  defp handle_local_bucket_save(socket, bucket_params, endpoint) when is_binary(endpoint) do
    case Storage.local_path_status(endpoint) do
      {:ok, _path} ->
        # Path exists, proceed with save
        save_bucket(socket, bucket_params)

      {:missing, expanded_path} ->
        # Path doesn't exist, show confirmation modal
        {:noreply, show_path_creation_modal(socket, bucket_params, expanded_path)}

      {:not_directory, path} ->
        {:noreply,
         put_flash(socket, :error, gettext("%{path} is a file, not a folder.", path: path))}

      {:not_writable, path} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("The application cannot write to %{path}.", path: path)
         )}
    end
  end

  defp handle_local_bucket_save(socket, _bucket_params, _endpoint) do
    # Invalid path format, redirect back with error
    socket =
      socket
      |> put_flash(
        :error,
        "Invalid storage path format. Please check the path and try again."
      )
      |> push_navigate(to: socket.assigns.current_path || Routes.path("/admin/settings/media"))

    {:noreply, socket}
  end

  # What the typed storage path comes to on disk, for the line under the input.
  # Only a local bucket has one; a blank field has nothing to resolve yet.
  defp assign_path_status(socket) do
    endpoint = Ecto.Changeset.get_field(socket.assigns.changeset, :endpoint)

    status =
      if socket.assigns.current_provider == "local" and is_binary(endpoint) and
           String.trim(endpoint) != "",
         do: Storage.local_path_status(endpoint)

    assign(socket, :path_status, status)
  end

  defp save_bucket(socket, bucket_params) do
    case socket.assigns.mode do
      :new -> create_bucket(socket, bucket_params)
      :edit -> update_bucket(socket, bucket_params)
    end
  end

  defp show_path_creation_modal(socket, bucket_params, expanded_path) do
    socket
    |> assign(:pending_bucket_params, bucket_params)
    |> assign(:show_create_path_modal, true)
    |> assign(:missing_path, expanded_path)
  end

  # The profile is the form's choice: none (the default) leaves the bucket in no
  # profile, a profile's uuid puts it there as a primary.
  defp create_bucket(socket, bucket_params) do
    {profile_uuid, bucket_params} = Map.pop(bucket_params, "profile_uuid")
    opts = [profile: blank_to_nil(profile_uuid)] ++ Actor.opts(socket)

    case Storage.create_bucket(bucket_params, opts) do
      {:ok, bucket} ->
        socket =
          socket
          |> put_flash(:info, created_message(opts[:profile], bucket))
          |> push_navigate(to: Routes.path("/admin/settings/media"))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> put_flash(:error, "Failed to create bucket")

        {:noreply, socket}
    end
  end

  defp update_bucket(socket, bucket_params) do
    bucket = Storage.get_site_bucket(socket.assigns.bucket_uuid)

    case Storage.update_bucket(bucket, bucket_params, Actor.opts(socket)) do
      {:ok, _bucket} ->
        socket =
          socket
          |> put_flash(:info, "Bucket updated successfully")
          |> push_navigate(to: Routes.path("/admin/settings/media"))

        {:noreply, socket}

      {:error, {:in_use, usage}} ->
        {:noreply,
         put_flash(socket, :error, BucketUsage.refusal_message(:disable, bucket, usage))}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> put_flash(:error, "Failed to update bucket")

        {:noreply, socket}
    end
  end

  # The profiles that use the bucket being edited (none for a new one).
  defp bucket_usage(nil), do: []

  defp bucket_usage(%Bucket{uuid: uuid}),
    do: Map.get(Profiles.bucket_usage([uuid]), to_string(uuid), [])

  # What the params need before they reach the changeset:
  #
  #   * the Type select (`storage_type`: local or cloud) decides the provider —
  #     local, or a provisional S3 until an integration says which service it is —
  #     and changing it drops what the other type had filled in (a storage path is
  #     not an endpoint);
  #   * picking a connection on a bucket that still carries its own keys clears
  #     those keys in the same change (the changeset allows one source only);
  #   * a newly picked connection sets the provider of its service and brings its
  #     region and endpoint (the bucket keeps its own copies: they are not
  #     secrets, and every public URL reads them).
  defp normalize_params(params, socket) do
    params = apply_storage_type(params, socket)

    case blank_to_nil(params["integration_uuid"]) do
      nil ->
        params

      uuid ->
        params
        |> Map.put("integration_uuid", uuid)
        |> Map.merge(%{"access_key_id" => nil, "secret_access_key" => nil})
        |> prefill_from_connection(uuid, socket)
    end
  end

  @type_fields ~w(endpoint region bucket_name integration_uuid cdn_url)

  defp apply_storage_type(%{"storage_type" => type} = params, socket) do
    params = Map.delete(params, "storage_type")
    changed? = type != storage_type(socket.assigns.current_provider)
    params = if changed?, do: Map.drop(params, @type_fields), else: params

    case type do
      "local" -> Map.put(params, "provider", "local")
      "cloud" when changed? -> Map.put(params, "provider", "s3")
      "cloud" -> params
      _unset -> Map.put(params, "provider", "")
    end
  end

  defp apply_storage_type(params, _socket), do: params

  defp prefill_from_connection(params, uuid, socket) do
    with true <- uuid != socket.assigns.selected_connection_uuid,
         %{} = connection <- Enum.find(socket.assigns.connections, &(&1.uuid == uuid)) do
      switching? = socket.assigns.selected_connection_uuid != nil

      params
      |> put_provider_of(connection)
      |> fill("region", default_region(connection), switching?)
      |> fill("endpoint", connection.endpoint, switching?)
    else
      _ -> params
    end
  end

  # The connection knows which service it is for (Cloudflare R2, Tigris, …), and
  # the bucket's provider decides how files are addressed, so a newly picked
  # connection brings its provider with it instead of leaving the two to disagree.
  defp put_provider_of(params, %{service: nil}), do: params

  defp put_provider_of(params, %{service: service}),
    do: Map.put(params, "provider", Services.bucket_provider(service))

  # Tigris is one global endpoint: where data lives is a setting of the bucket in
  # Tigris's console, and the signing region is "auto".
  defp default_region(%{service: "tigris"}), do: "auto"
  defp default_region(%{region: region}), do: region

  # A connection's value goes onto the bucket when it has one. Moving to another
  # connection clears what the old one had set rather than leaving it behind.
  defp fill(params, key, value, switching?) do
    cond do
      blank_to_nil(value) != nil -> Map.put(params, key, value)
      switching? -> Map.put(params, key, "")
      true -> params
    end
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(value), do: value

  # The picker's connections, reduced to what the form shows. `list_connections/2`
  # returns each connection's decrypted data, secrets included; none of it is
  # kept in assigns.
  defp assign_connections(socket) do
    connections =
      BucketCredentials.provider_key()
      |> Integrations.list_connections()
      |> Enum.map(fn %{uuid: uuid, name: name, data: data} ->
        %{
          uuid: uuid,
          name: name,
          region: data["region"],
          endpoint: data["endpoint"],
          service: Services.current(data),
          configured: is_binary(data["access_key"]) and data["access_key"] != ""
        }
      end)

    assign(socket, :connections, connections)
  end

  # What the admin is told once the bucket exists. In no profile it receives
  # nothing yet, which is worth saying where it was just created. In a profile,
  # as a primary: when that leaves the profile spreading files across its
  # primaries rather than mirroring them, say so now, since adding the second
  # bucket is when it begins.
  defp created_message(nil, _bucket) do
    gettext("Bucket created successfully") <>
      ". " <>
      gettext(
        "It is in no storage profile yet, so nothing is written to it: add it to one on the Storage profiles tab."
      )
  end

  defp created_message(profile_uuid, bucket) do
    base = gettext("Bucket created successfully")
    group = Bucket.group(bucket)

    with %{} = profile <- Profiles.get_profile(profile_uuid),
         %{} = advice <- Map.fetch!(Profiles.copies_advice(profile), group) do
      case advice do
        # The profile asks for none of this kind of copy: the bucket is in it and
        # holds nothing until a count is set.
        %{copies: 0} ->
          base <> ". " <> no_copies_message(group)

        %{primaries: primaries, copies: copies} when primaries > copies ->
          base <>
            ". " <>
            gettext(
              "Each file is stored on %{copies} of the %{count} primary buckets of its kind, so files are spread across them, not mirrored. Change the copies on the Storage profiles tab.",
              copies: copies,
              count: primaries
            )

        _ ->
          base
      end
    else
      _ -> base
    end
  end

  defp no_copies_message(:local) do
    gettext(
      "The profile keeps no local copies, so nothing is written to this bucket yet: set Local copies on the Storage profiles tab."
    )
  end

  defp no_copies_message(:cloud) do
    gettext(
      "The profile keeps no cloud copies, so nothing is written to this bucket yet: set Cloud copies on the Storage profiles tab."
    )
  end

  # The Default is marked: a bucket added to it is written to by every library
  # that names no profile of its own.
  defp profile_label(%{is_default: true, name: name}),
    do: gettext("%{name} (Default)", name: name)

  defp profile_label(%{name: name}), do: name

  defp page_title(:new), do: gettext("Add Storage Bucket")
  defp page_title(:edit), do: gettext("Edit Storage Bucket")

  # Helper function for input validation styling
  defp input_class(changeset, field) do
    if Keyword.has_key?(changeset.errors, field) do
      "input-error"
    else
      ""
    end
  end

  # Helper function to get currently selected provider from changeset
  defp get_current_provider(changeset, bucket) do
    case changeset do
      %Ecto.Changeset{changes: %{provider: provider}} -> provider
      %Ecto.Changeset{} -> if bucket, do: bucket.provider, else: nil
    end
  end

  defp cloud_provider?(provider), do: provider in @cloud_providers

  defp storage_type("local"), do: "local"
  defp storage_type(provider) when provider in @cloud_providers, do: "cloud"
  defp storage_type(_provider), do: nil

  # The service of the integration picked, nil when none is (or it has none).
  defp selected_service(_connections, nil), do: nil

  defp selected_service(connections, uuid) do
    case Enum.find(connections, &(&1.uuid == uuid)) do
      %{service: service} -> service
      nil -> nil
    end
  end

  defp provider_label("local", _service), do: gettext("Local Filesystem")
  defp provider_label(_provider, service) when is_binary(service), do: Services.name(service)
  defp provider_label("s3", _service), do: "AWS S3"
  defp provider_label("b2", _service), do: "Backblaze B2"
  defp provider_label("r2", _service), do: "Cloudflare R2"
  defp provider_label("tigris", _service), do: "Tigris"
  defp provider_label(provider, _service), do: String.upcase(provider || "Unknown")

  # What is asked after the integration: shown once one is picked, or for a bucket
  # that still carries its own keys and so has none.
  defp cloud_details?(assigns),
    do: not is_nil(assigns.selected_connection_uuid) or legacy_bucket?(assigns.bucket)

  # Only Amazon has a region to choose here; every other service's region is its
  # integration's own (and Tigris has none to choose).
  defp region_select?("s3", service), do: service in [nil, "aws_s3"]
  defp region_select?(_provider, _service), do: false

  # Only "other" — a self-hosted service, or a bucket with no integration — has
  # an endpoint to type; the rest come from the integration.
  defp endpoint_input?(service), do: service in [nil, "other"]

  # A cloud bucket needs a connection, unless it is an existing one that still
  # carries its own keys (legacy): that one keeps working as it is.
  defp connection_missing?(changeset, bucket) do
    cloud_provider?(Ecto.Changeset.get_field(changeset, :provider)) and
      is_nil(Ecto.Changeset.get_field(changeset, :integration_uuid)) and
      not legacy_bucket?(bucket)
  end

  defp legacy_bucket?(nil), do: false
  defp legacy_bucket?(%Bucket{} = bucket), do: BucketCredentials.legacy?(bucket)

  defp can_manage_integrations?(assigns),
    do: Scope.has_module_access?(assigns[:phoenix_kit_current_scope], "integrations_system")
end
