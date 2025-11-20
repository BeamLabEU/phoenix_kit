defmodule PhoenixKitWeb.Live.Settings.Storage do
  @moduledoc """
  Storage settings management LiveView for PhoenixKit.

  Provides configuration interface for the distributed file storage system.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import Ecto.Query

  alias PhoenixKit.Settings
  alias PhoenixKit.System.Dependencies
  alias PhoenixKit.Utils.Routes

  def mount(params, session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, session)

    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Load buckets
    buckets = PhoenixKit.Storage.list_buckets()

    # Load file counts per bucket (unique files, not instances)
    bucket_file_counts = get_bucket_file_counts(buckets)

    # Load storage settings from database (using basic function to avoid cache issues)
    redundancy_copies = Settings.get_setting("storage_redundancy_copies", "1")
    auto_generate_variants = Settings.get_setting("storage_auto_generate_variants", "true")
    default_bucket_id = Settings.get_setting("storage_default_bucket_id", nil)

    # Calculate maximum redundancy based on available buckets
    active_buckets = Enum.count(buckets, & &1.enabled)
    max_redundancy = if active_buckets > 0, do: active_buckets, else: 1

    # Keep user's current redundancy setting unchanged
    current_redundancy = String.to_integer(redundancy_copies)

    # Store form values for batch updates
    form_redundancy = current_redundancy
    form_auto_generate_variants = auto_generate_variants == "true"

    # Check system dependencies
    imagemagick_status = Dependencies.check_imagemagick_cached()
    ffmpeg_status = Dependencies.check_ffmpeg_cached()

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Storage Settings")
      |> assign(:project_title, project_title)
      |> assign(:buckets, buckets)
      |> assign(:bucket_file_counts, bucket_file_counts)
      |> assign(:redundancy_copies, current_redundancy)
      |> assign(:auto_generate_variants, auto_generate_variants == "true")
      |> assign(:default_bucket_id, default_bucket_id)
      |> assign(:current_locale, locale)
      |> assign(:active_buckets_count, active_buckets)
      |> assign(:max_redundancy, max_redundancy)
      |> assign(:form_redundancy, form_redundancy)
      |> assign(:form_auto_generate_variants, form_auto_generate_variants)
      |> assign(:imagemagick_status, imagemagick_status)
      |> assign(:ffmpeg_status, ffmpeg_status)

    {:ok, socket}
  end

  def handle_event("update_redundancy", %{"redundancy_copies" => copies}, socket) do
    requested_copies = String.to_integer(copies)
    max_redundancy = socket.assigns.max_redundancy

    if requested_copies > max_redundancy do
      socket =
        socket
        |> put_flash(
          :error,
          "Cannot set redundancy to #{requested_copies} copies. Only #{max_redundancy} active bucket(s) available."
        )

      {:noreply, socket}
    else
      case Settings.update_setting("storage_redundancy_copies", copies) do
        {:ok, _setting} ->
          # Settings.update_setting already handles cache invalidation
          socket =
            socket
            |> assign(:redundancy_copies, requested_copies)
            |> put_flash(
              :info,
              "Redundancy settings updated to #{requested_copies} #{if requested_copies == 1, do: "copy", else: "copies"}"
            )

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, "Failed to update redundancy settings")
          {:noreply, socket}
      end
    end
  end

  def handle_event("update_form_redundancy", %{"form_redundancy" => copies}, socket) do
    # Handle both string and integer inputs
    form_redundancy =
      cond do
        is_integer(copies) -> copies
        is_binary(copies) -> String.to_integer(copies)
        # fallback
        true -> 1
      end

    socket =
      socket
      |> assign(:form_redundancy, form_redundancy)

    {:noreply, socket}
  end

  def handle_event("update_form_variants", %{"form_auto_generate_variants" => value}, socket) do
    form_auto_generate_variants = value == "true"

    socket =
      socket
      |> assign(:form_auto_generate_variants, form_auto_generate_variants)

    {:noreply, socket}
  end

  def handle_event("toggle_form_variants", _params, socket) do
    new_value = not socket.assigns.form_auto_generate_variants

    socket =
      socket
      |> assign(:form_auto_generate_variants, new_value)

    {:noreply, socket}
  end

  def handle_event("update_storage_form", %{"form_redundancy" => redundancy}, socket) do
    # Handle both string and integer inputs
    form_redundancy =
      cond do
        is_integer(redundancy) -> redundancy
        is_binary(redundancy) -> String.to_integer(redundancy)
        # fallback
        true -> 1
      end

    socket =
      socket
      |> assign(:form_redundancy, form_redundancy)

    {:noreply, socket}
  end

  def handle_event("update_storage_form", _params, socket) do
    # Handle cases where form doesn't include redundancy field
    {:noreply, socket}
  end

  def handle_event("apply_storage_settings", _params, socket) do
    # Get current form values
    new_redundancy = socket.assigns.form_redundancy
    new_variants = if socket.assigns.form_auto_generate_variants, do: "true", else: "false"

    # Validate redundancy doesn't exceed available buckets
    max_redundancy = socket.assigns.max_redundancy

    if new_redundancy > max_redundancy do
      socket =
        socket
        |> put_flash(
          :error,
          "Cannot set redundancy to #{new_redundancy} copies. Only #{max_redundancy} active bucket(s) available."
        )

      {:noreply, socket}
    else
      # Update both settings
      redundancy_result =
        Settings.update_setting("storage_redundancy_copies", to_string(new_redundancy))

      variants_result = Settings.update_setting("storage_auto_generate_variants", new_variants)

      case {redundancy_result, variants_result} do
        {{:ok, _}, {:ok, _}} ->
          # Verify the settings were saved correctly by reading them back
          saved_redundancy = Settings.get_setting("storage_redundancy_copies", "1")
          saved_variants = Settings.get_setting("storage_auto_generate_variants", "true")

          socket =
            socket
            |> assign(:redundancy_copies, String.to_integer(saved_redundancy))
            |> assign(:auto_generate_variants, saved_variants == "true")
            |> assign(:form_redundancy, String.to_integer(saved_redundancy))
            |> assign(:form_auto_generate_variants, saved_variants == "true")
            |> put_flash(:info, "Storage settings updated successfully")

          {:noreply, socket}

        {{:error, _}, {:ok, _}} ->
          socket = put_flash(socket, :error, "Failed to update redundancy settings")
          {:noreply, socket}

        {{:ok, _}, {:error, _}} ->
          socket = put_flash(socket, :error, "Failed to update variant settings")
          {:noreply, socket}

        {{:error, _}, {:error, _}} ->
          socket = put_flash(socket, :error, "Failed to update storage settings")
          {:noreply, socket}
      end
    end
  end

  def handle_event("toggle_variants", _params, socket) do
    new_value = if socket.assigns.auto_generate_variants, do: "false", else: "true"

    case Settings.update_setting("storage_auto_generate_variants", new_value) do
      {:ok, _setting} ->
        # Settings.update_setting already handles cache invalidation
        socket =
          socket
          |> assign(:auto_generate_variants, new_value == "true")
          |> put_flash(
            :info,
            "Auto-variant generation #{if new_value == "true", do: "enabled", else: "disabled"}"
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update variant settings")
        {:noreply, socket}
    end
  end

  def handle_event("update_default_bucket", %{"bucket_id" => bucket_id}, socket) do
    new_value = if bucket_id == "", do: nil, else: bucket_id

    case Settings.update_setting("storage_default_bucket_id", new_value) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:default_bucket_id, new_value)
          |> put_flash(:info, "Default bucket updated")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update default bucket")
        {:noreply, socket}
    end
  end

  def handle_event("delete_bucket", %{"id" => bucket_id}, socket) do
    bucket = PhoenixKit.Storage.get_bucket(bucket_id)

    case PhoenixKit.Storage.delete_bucket(bucket) do
      {:ok, _bucket} ->
        # Reload buckets and recalculate max redundancy
        buckets = PhoenixKit.Storage.list_buckets()
        active_buckets_count = Enum.count(buckets, & &1.enabled)
        max_redundancy = max(1, active_buckets_count)

        socket =
          socket
          |> assign(:buckets, buckets)
          |> assign(:active_buckets_count, active_buckets_count)
          |> assign(:max_redundancy, max_redundancy)
          |> put_flash(:info, "Bucket deleted successfully")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to delete bucket")
        {:noreply, socket}
    end
  end

  defp get_current_path(_socket, _session) do
    # For Storage settings page
    Routes.path("/admin/settings/media")
  end

  # Helper function to get full path for a bucket
  defp get_bucket_full_path(bucket) do
    case bucket.provider do
      "local" ->
        bucket.endpoint || "No path configured"

      provider when provider in ["s3", "b2", "r2"] ->
        path_parts = [
          provider <> ":",
          if(bucket.bucket_name, do: bucket.bucket_name, else: "no-bucket"),
          if(bucket.endpoint, do: bucket.endpoint, else: "/")
        ]

        Enum.join(path_parts, "")

      _ ->
        "#{bucket.provider}: unknown configuration"
    end
  end

  # Get count of unique files stored on each bucket
  defp get_bucket_file_counts(buckets) do
    repo = PhoenixKit.Config.get_repo()

    Enum.reduce(buckets, %{}, fn bucket, acc ->
      # Count distinct files that have at least one instance located on this bucket
      # We count files, not instances or locations
      count =
        repo.one(
          from f in PhoenixKit.Storage.File,
            join: fi in PhoenixKit.Storage.FileInstance,
            on: fi.file_id == f.id,
            join: fl in PhoenixKit.Storage.FileLocation,
            on: fl.file_instance_id == fi.id,
            where: fl.bucket_id == ^bucket.id and fl.status == "active",
            select: count(f.id, :distinct)
        )

      Map.put(acc, bucket.id, count || 0)
    end)
  rescue
    _ -> %{}
  end
end
