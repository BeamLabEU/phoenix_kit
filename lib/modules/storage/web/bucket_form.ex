defmodule PhoenixKitWeb.Live.Modules.Storage.BucketForm do
  @moduledoc """
  Bucket form LiveView for storage bucket management.

  Provides form interface for creating and editing storage buckets.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, session, socket) do
    bucket_id = params["id"]
    mode = if bucket_id, do: :edit, else: :new

    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    bucket = load_bucket_data(mode, bucket_id)

    changeset =
      case mode do
        :new ->
          Storage.change_bucket(%Storage.Bucket{}, %{})

        :edit ->
          Storage.change_bucket(bucket, %{
            name: bucket.name,
            provider: bucket.provider,
            region: bucket.region,
            endpoint: bucket.endpoint,
            bucket_name: bucket.bucket_name,
            access_key_id: bucket.access_key_id,
            secret_access_key: bucket.secret_access_key,
            cdn_url: bucket.cdn_url,
            enabled: bucket.enabled,
            priority: bucket.priority,
            max_size_mb: bucket.max_size_mb
          })
      end

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:bucket_id, bucket_id)
      |> assign(:page_title, page_title(mode))
      |> assign(:project_title, project_title)
      |> assign(:form_action, page_title(mode))
      |> assign(:current_path, current_path)
      |> assign(:bucket, bucket)
      |> assign(:changeset, changeset)
      |> assign(:current_provider, get_current_provider(changeset, bucket))
      |> assign(:pending_bucket_params, nil)
      |> assign(:show_create_path_modal, false)

    {:ok, socket}
  end

  def handle_event("validate", %{"bucket" => bucket_params}, socket) do
    changeset =
      case socket.assigns.mode do
        :new ->
          Storage.change_bucket(%Storage.Bucket{}, bucket_params)

        :edit ->
          bucket = Storage.get_bucket(socket.assigns.bucket_id)
          Storage.change_bucket(bucket, bucket_params)
      end

    # Update current provider if it changed
    current_provider = get_current_provider(changeset, socket.assigns.bucket)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:current_provider, current_provider)

    {:noreply, socket}
  end

  def handle_event("save", %{"bucket" => bucket_params}, socket) do
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

  defp handle_local_bucket_save(socket, bucket_params, endpoint) do
    case Storage.validate_and_normalize_path(endpoint) do
      {:ok, _relative_path} ->
        # Path exists, proceed with save
        save_bucket(socket, bucket_params)

      {:error, :does_not_exist, expanded_path} ->
        # Path doesn't exist, show confirmation modal
        {:noreply, show_path_creation_modal(socket, bucket_params, expanded_path)}

      {:error, :invalid_path} ->
        # Invalid path format, redirect back with error
        socket =
          socket
          |> put_flash(
            :error,
            "Invalid storage path format. Please check the path and try again."
          )
          |> push_navigate(
            to: socket.assigns.current_path || Routes.path("/admin/settings/media")
          )

        {:noreply, socket}
    end
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

  defp create_bucket(socket, bucket_params) do
    case Storage.create_bucket(bucket_params) do
      {:ok, _bucket} ->
        socket =
          socket
          |> put_flash(:info, "Bucket created successfully")
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
    bucket = Storage.get_bucket(socket.assigns.bucket_id)

    case Storage.update_bucket(bucket, bucket_params) do
      {:ok, _bucket} ->
        socket =
          socket
          |> put_flash(:info, "Bucket updated successfully")
          |> push_navigate(to: Routes.path("/admin/settings/media"))

        {:noreply, socket}

      {:error, changeset} ->
        socket =
          socket
          |> assign(:changeset, changeset)
          |> put_flash(:error, "Failed to update bucket")

        {:noreply, socket}
    end
  end

  defp load_bucket_data(:new, _bucket_id), do: nil

  defp load_bucket_data(:edit, bucket_id) do
    Storage.get_bucket(bucket_id)
  end

  defp page_title(:new), do: "Add Storage Bucket"
  defp page_title(:edit), do: "Edit Storage Bucket"

  # Helper function to get current path for navigation
  defp get_current_path(_socket, _session) do
    # For Bucket form page
    Routes.path("/admin/settings/media")
  end

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
end
