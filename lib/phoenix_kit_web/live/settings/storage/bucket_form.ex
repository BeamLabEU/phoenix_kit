defmodule PhoenixKitWeb.Live.Settings.Storage.BucketForm do
  @moduledoc """
  Bucket form LiveView for storage bucket management.

  Provides form interface for creating and editing storage buckets.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Storage
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    bucket_id = params["id"]
    mode = if bucket_id, do: :edit, else: :new

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:mode, mode)
      |> assign(:bucket_id, bucket_id)
      |> assign(:page_title, page_title(mode))
      |> assign(:project_title, project_title)
      |> assign(:form_action, page_title(mode))
      |> assign(:current_locale, "en")
      |> assign(:bucket, load_bucket_data(mode, bucket_id))
      |> assign_form()

    {:ok, socket}
  end

  def handle_event("validate", %{"bucket" => bucket_params}, socket) do
    changeset =
      case socket.assigns.mode do
        :new ->
          Storage.create_bucket(bucket_params)

        :edit ->
          bucket = Storage.get_bucket(socket.assigns.bucket_id)
          Storage.update_bucket(bucket, bucket_params)
      end
      |> case do
        {:ok, bucket} ->
          # For successful save, create a valid changeset for display
          Storage.create_bucket(bucket_params)

        {:error, changeset} ->
          changeset
      end

    socket =
      socket
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  def handle_event("save", %{"bucket" => bucket_params}, socket) do
    case socket.assigns.mode do
      :new -> create_bucket(socket, bucket_params)
      :edit -> update_bucket(socket, bucket_params)
    end
  end

  defp create_bucket(socket, bucket_params) do
    case Storage.create_bucket(bucket_params) do
      {:ok, _bucket} ->
        socket =
          socket
          |> put_flash(:info, "Bucket created successfully")
          |> push_navigate(to: Routes.path("/admin/settings/storage/buckets"))

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
          |> push_navigate(to: Routes.path("/admin/settings/storage/buckets"))

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

  defp assign_form(%{assigns: %{mode: :new}} = socket) do
    changeset = Storage.create_bucket(%{})
    assign(socket, :changeset, changeset)
  end

  defp assign_form(%{assigns: %{mode: :edit, bucket: bucket}} = socket) do
    changeset =
      Storage.create_bucket(%{
        name: bucket.name,
        provider: bucket.provider,
        region: bucket.region,
        endpoint: bucket.endpoint,
        bucket_name: bucket.bucket_name,
        access_key_id: bucket.access_key_id,
        secret_access_key: bucket.secret_access_key,
        cdn_url: bucket.cdn_url,
        path_prefix: bucket.path_prefix,
        enabled: bucket.enabled,
        priority: bucket.priority,
        max_size_mb: bucket.max_size_mb
      })

    assign(socket, :changeset, changeset)
  end

  defp page_title(:new), do: "Add Storage Bucket"
  defp page_title(:edit), do: "Edit Storage Bucket"

  # Helper function for input validation styling
  defp input_class(changeset, field) do
    if Keyword.has_key?(changeset.errors, field) do
      "input-error"
    else
      ""
    end
  end
end
