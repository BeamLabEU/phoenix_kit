defmodule PhoenixKitWeb.Live.Settings.Storage do
  @moduledoc """
  Storage settings management LiveView for PhoenixKit.

  Provides configuration interface for the distributed file storage system.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Storage
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

    # Load storage configuration
    storage_config = Storage.get_config()
    absolute_path = Storage.get_absolute_path()

    # Load storage settings from database
    redundancy_copies = Settings.get_setting("storage_redundancy_copies", "2")
    auto_generate_variants = Settings.get_setting("storage_auto_generate_variants", "true")
    default_bucket_id = Settings.get_setting("storage_default_bucket_id", nil)

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, "Storage Settings")
      |> assign(:project_title, project_title)
      |> assign(:storage_default_path, absolute_path)
      |> assign(:storage_relative_path, storage_config.default_path)
      |> assign(:path_input, absolute_path)
      |> assign(:path_error, nil)
      |> assign(:confirm_create_path, nil)
      |> assign(:redundancy_copies, String.to_integer(redundancy_copies))
      |> assign(:auto_generate_variants, auto_generate_variants == "true")
      |> assign(:default_bucket_id, default_bucket_id)
      |> assign(:current_locale, locale)

    {:ok, socket}
  end

  def handle_event("update_path_input", %{"path" => path}, socket) do
    {:noreply, assign(socket, :path_input, path)}
  end

  def handle_event("save_path", %{"path" => path}, socket) do
    case Storage.validate_and_normalize_path(path) do
      {:error, :does_not_exist, absolute_path} ->
        # Directory doesn't exist - ask user if they want to create it
        socket =
          socket
          |> assign(:confirm_create_path, absolute_path)
          |> assign(:path_error, "Directory does not exist: #{absolute_path}")

        {:noreply, socket}

      {:ok, relative_path} ->
        # Save the relative path to database
        case Storage.update_default_path(relative_path) do
          {:ok, _setting} ->
            # Get the new absolute path for display
            absolute_path = Storage.get_absolute_path()

            socket =
              socket
              |> assign(:storage_default_path, absolute_path)
              |> assign(:storage_relative_path, relative_path)
              |> assign(:path_input, absolute_path)
              |> assign(:path_error, nil)
              |> assign(:confirm_create_path, nil)
              |> put_flash(:info, "Storage path updated successfully")

            {:noreply, socket}

          {:error, _changeset} ->
            socket =
              socket
              |> assign(:path_error, "Failed to save path to database")
              |> assign(:confirm_create_path, nil)
              |> put_flash(:error, "Failed to update storage path")

            {:noreply, socket}
        end

      {:error, reason} ->
        socket =
          socket
          |> assign(:path_error, reason)
          |> assign(:confirm_create_path, nil)

        {:noreply, socket}
    end
  end

  def handle_event("create_and_save_path", _params, socket) do
    path_to_create = socket.assigns.confirm_create_path

    case Storage.create_directory(path_to_create) do
      {:ok, _absolute_path} ->
        # Directory created successfully, now validate and save
        case Storage.validate_and_normalize_path(path_to_create) do
          {:ok, relative_path} ->
            # Save the relative path to database
            case Storage.update_default_path(relative_path) do
              {:ok, _setting} ->
                absolute_path = Storage.get_absolute_path()

                socket =
                  socket
                  |> assign(:storage_default_path, absolute_path)
                  |> assign(:storage_relative_path, relative_path)
                  |> assign(:path_input, absolute_path)
                  |> assign(:path_error, nil)
                  |> assign(:confirm_create_path, nil)
                  |> put_flash(:info, "Directory created and storage path updated successfully")

                {:noreply, socket}

              {:error, _changeset} ->
                socket =
                  socket
                  |> assign(:path_error, "Failed to save path to database")
                  |> assign(:confirm_create_path, nil)
                  |> put_flash(:error, "Failed to update storage path")

                {:noreply, socket}
            end

          {:error, reason} ->
            socket =
              socket
              |> assign(:path_error, reason)
              |> assign(:confirm_create_path, nil)

            {:noreply, socket}
        end

      {:error, reason} ->
        socket =
          socket
          |> assign(:path_error, reason)
          |> assign(:confirm_create_path, nil)
          |> put_flash(:error, reason)

        {:noreply, socket}
    end
  end

  def handle_event("cancel_create", _params, socket) do
    socket =
      socket
      |> assign(:confirm_create_path, nil)
      |> assign(:path_error, nil)

    {:noreply, socket}
  end

  def handle_event("reset_to_default", _params, socket) do
    default_path = "priv/uploads"

    case Storage.update_default_path(default_path) do
      {:ok, _setting} ->
        absolute_path = Storage.get_absolute_path()

        socket =
          socket
          |> assign(:storage_default_path, absolute_path)
          |> assign(:storage_relative_path, default_path)
          |> assign(:path_input, absolute_path)
          |> assign(:path_error, nil)
          |> assign(:confirm_create_path, nil)
          |> put_flash(:info, "Storage path reset to default")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to reset storage path")
        {:noreply, socket}
    end
  end

  def handle_event("update_redundancy", %{"redundancy_copies" => copies}, socket) do
    case Settings.update_setting("storage_redundancy_copies", copies) do
      {:ok, _setting} ->
        socket =
          socket
          |> assign(:redundancy_copies, String.to_integer(copies))
          |> put_flash(:info, "Redundancy settings updated")

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, "Failed to update redundancy settings")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_variants", _params, socket) do
    new_value = if socket.assigns.auto_generate_variants, do: "false", else: "true"

    case Settings.update_setting("storage_auto_generate_variants", new_value) do
      {:ok, _setting} ->
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
