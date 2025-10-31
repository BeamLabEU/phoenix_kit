defmodule PhoenixKitWeb.Live.Settings.Storage do
  @moduledoc """
  Storage settings management LiveView for PhoenixKit.

  Provides configuration interface for the distributed file storage system.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Settings
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

    # Load storage settings from database (using basic function to avoid cache issues)
    redundancy_copies = Settings.get_setting("storage_redundancy_copies", "2")
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

    # Allow uploads - SUPER SIMPLE!
    socket =
      socket
      |> allow_upload(:files,
        accept: ["image/*", "video/*", "application/pdf"],
        max_entries: 10,
        max_file_size: 100_000_000,
        auto_upload: false  # Manually upload on submit
      )
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Storage Settings")
      |> assign(:project_title, project_title)
      |> assign(:buckets, buckets)
      |> assign(:redundancy_copies, current_redundancy)
      |> assign(:auto_generate_variants, auto_generate_variants == "true")
      |> assign(:default_bucket_id, default_bucket_id)
      |> assign(:current_locale, locale)
      |> assign(:active_buckets_count, active_buckets)
      |> assign(:max_redundancy, max_redundancy)
      |> assign(:form_redundancy, form_redundancy)
      |> assign(:form_auto_generate_variants, form_auto_generate_variants)
      |> assign(:uploaded_files, [])

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
          saved_redundancy = Settings.get_setting("storage_redundancy_copies", "2")
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

  def handle_event("validate", _params, socket) do
    # Handle form validation - files are being validated on change
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    # Check if there are files selected in the browser
    if socket.assigns.uploads.files.entries == [] do
      {:noreply, put_flash(socket, :info, "No files selected")}
    else
      # consume_uploaded_entries will automatically upload the files first, then process them
      uploaded_files =
        consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
          # Get file info
          ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
          mime_type = entry.client_type || MIME.from_path(entry.client_name)
          file_type = determine_file_type(mime_type)

          # Get current user
          current_user = socket.assigns.phoenix_kit_current_user
          user_id = if current_user, do: current_user.id, else: 1

          # Get file size
          {:ok, stat} = File.stat(path)
          file_size = stat.size

          # Calculate hash
          file_hash = calculate_file_hash(path)

          # Store file in storage
          case PhoenixKit.Storage.store_file_in_buckets(path, file_type, user_id, file_hash, ext) do
            {:ok, file} ->
              # Queue background job for processing
              job =
                %{file_id: file.id, user_id: user_id, filename: entry.client_name}
                |> PhoenixKit.Storage.Workers.ProcessFileJob.new()
                |> Oban.insert()

              # Debug logging
              IO.inspect(job, label: "Oban Job Inserted")

              {:ok,
               %{
                 file_id: file.id,
                 filename: entry.client_name,
                 file_type: file_type,
                 mime_type: mime_type,
                 size: file_size,
                 status: file.status,
                 url: nil
               }}

            {:error, reason} ->
              IO.inspect(reason, label: "Storage Error")
              {:error, reason}
          end
        end)

      socket =
        socket
        |> assign(:uploaded_files, uploaded_files)
        |> put_flash(:info, "Upload successful! #{length(uploaded_files)} file(s) processed")

      {:noreply, socket}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  defp calculate_file_hash(file_path) do
    file_path
    |> File.read!()
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
  end

  defp determine_file_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> "image"
      String.starts_with?(mime_type, "video/") -> "video"
      mime_type == "application/pdf" -> "document"
      true -> "other"
    end
  end

  defp get_current_path(_socket, _session) do
    # For Storage settings page
    Routes.path("/admin/settings/storage")
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

  # Helper functions for template
  defp format_bytes(bytes) when is_integer(bytes) do
    if bytes < 1024 do
      "#{bytes} B"
    else
      units = ["KB", "MB", "GB", "TB"]
      {value, unit} = calculate_size(bytes, units)
      "#{Float.round(value, 2)} #{unit}"
    end
  end

  defp calculate_size(bytes, [unit | rest]) when bytes >= 1024 and rest != [] do
    calculate_size(bytes / 1024, rest)
  end

  defp calculate_size(bytes, [unit | _]), do: {bytes, unit}

  defp error_to_string(:too_large), do: "File is too large"
  defp error_to_string(:not_accepted), do: "File type not accepted"
  defp error_to_string({_, reason}), do: to_string(reason)
  defp error_to_string(_), do: "Unknown error"
end
