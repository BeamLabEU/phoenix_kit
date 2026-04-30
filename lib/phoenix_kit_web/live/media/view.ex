defmodule PhoenixKitWeb.Live.Media.View do
  @moduledoc """
  Read-only media viewer for non-admin users.

  Routed at `/media/:file_uuid` under the authenticated `live_session`. Any
  signed-in user can land here — typically by clicking a file inside an
  embedded `MediaBrowser` that was rendered with `view_path="/media/:uuid"`.

  Mirrors `PhoenixKitWeb.Live.Users.MediaDetail` for the file rendering
  (image / video / PDF / icon) and the basic metadata panel, but without
  any admin actions (no delete, restore, edit, regenerate).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]
    file_uuid = params["file_uuid"]

    settings =
      Settings.get_settings_cached(
        ["project_title"],
        %{"project_title" => PhoenixKit.Config.get(:project_title, "PhoenixKit")}
      )

    socket =
      socket
      |> assign(:page_title, "Media")
      |> assign(:project_title, settings["project_title"])
      |> assign(:current_locale, locale)
      |> assign(:file_uuid, file_uuid)
      |> assign(:url_path, Routes.path("/media/#{file_uuid}"))
      |> load_file_data(file_uuid)

    {:ok, socket}
  end

  # ── Data loading ────────────────────────────────────────────────────

  defp load_file_data(socket, file_uuid) do
    repo = PhoenixKit.Config.get_repo()

    case repo.get(File, file_uuid) do
      nil ->
        socket
        |> assign(:file, nil)
        |> assign(:file_data, nil)

      file ->
        instances = load_file_instances(file_uuid, repo)
        urls = generate_urls_from_instances(instances, file_uuid)
        user_name = get_user_name(file.user_uuid, repo)

        file_data = %{
          file_uuid: file.uuid,
          filename: file.original_file_name || file.file_name || "Unknown",
          file_type: file.file_type,
          mime_type: file.mime_type,
          size: file.size || 0,
          status: file.status,
          urls: urls,
          metadata: file.metadata || %{},
          inserted_at: file.inserted_at,
          user_name: user_name
        }

        socket
        |> assign(:file, file)
        |> assign(:file_data, file_data)
    end
  end

  defp load_file_instances(file_uuid, repo) do
    FileInstance
    |> where([fi], fi.file_uuid == ^file_uuid)
    |> repo.all()
  end

  defp generate_urls_from_instances(instances, file_uuid) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      url = URLSigner.signed_url(file_uuid, instance.variant_name)
      Map.put(acc, instance.variant_name, url)
    end)
  end

  defp get_user_name(nil, _repo), do: "Unknown"

  defp get_user_name(user_uuid, repo) do
    user_module = PhoenixKit.Config.get_users_module()

    case repo.get(user_module, user_uuid) do
      nil -> "Unknown"
      user -> user.email
    end
  rescue
    _ -> "Unknown"
  end

  # ── Helpers used in the template ────────────────────────────────────

  @doc false
  def format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 2)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 2)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_file_size(_), do: "0 B"

  @doc false
  def file_icon("image"), do: "hero-photo"
  def file_icon("video"), do: "hero-play-circle"
  def file_icon("pdf"), do: "hero-document-text"
  def file_icon("document"), do: "hero-document"
  def file_icon(_), do: "hero-document-arrow-down"
end
