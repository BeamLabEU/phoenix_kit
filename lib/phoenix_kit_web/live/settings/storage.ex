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

    socket =
      socket
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

    {:ok, socket}
  end

  
  def handle_event("update_redundancy", %{"redundancy_copies" => copies}, socket) do
    requested_copies = String.to_integer(copies)
    max_redundancy = socket.assigns.max_redundancy

    if requested_copies > max_redundancy do
      socket =
        socket
        |> put_flash(:error, "Cannot set redundancy to #{requested_copies} copies. Only #{max_redundancy} active bucket(s) available.")

      {:noreply, socket}
    else
      case Settings.update_setting("storage_redundancy_copies", copies) do
        {:ok, _setting} ->
          # Settings.update_setting already handles cache invalidation
          socket =
            socket
            |> assign(:redundancy_copies, requested_copies)
            |> put_flash(:info, "Redundancy settings updated to #{requested_copies} #{if requested_copies == 1, do: "copy", else: "copies"}")

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, "Failed to update redundancy settings")
          {:noreply, socket}
      end
    end
  end

  def handle_event("update_form_redundancy", %{"form_redundancy" => copies}, socket) do
    # Handle both string and integer inputs
    form_redundancy = cond do
      is_integer(copies) -> copies
      is_binary(copies) -> String.to_integer(copies)
      true -> 1  # fallback
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
    form_redundancy = cond do
      is_integer(redundancy) -> redundancy
      is_binary(redundancy) -> String.to_integer(redundancy)
      true -> 1  # fallback
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
        |> put_flash(:error, "Cannot set redundancy to #{new_redundancy} copies. Only #{max_redundancy} active bucket(s) available.")

      {:noreply, socket}
    else
      # Update both settings
      redundancy_result = Settings.update_setting("storage_redundancy_copies", to_string(new_redundancy))
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

  defp get_current_path(_socket, _session) do
    # For Storage settings page
    Routes.path("/admin/settings/storage")
  end
end
