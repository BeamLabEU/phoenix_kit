defmodule PhoenixKitWeb.Live.Users.MediaDetail do
  @moduledoc """
  The old address of a media file, `/admin/media/:file_uuid`.

  A file's page is now the media view: `/admin/media?file=<uuid>` (or the
  browsing page of the library the file is in), where the picture, its details
  and its comments are. How it is stored is at `/admin/media/:file_uuid/storage`
  (`PhoenixKitWeb.Live.Users.MediaStorage`). Links already in the world — a
  comment's file link, a notification, a bookmark — keep working: this LiveView
  sends them to the media view and renders nothing of its own.

  The helpers are the shared reading of "where does this file live":
  `view_path/2` is the page that browses it, `trail/2` the header trail above it.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    target =
      with {:ok, uuid} <- Ecto.UUID.cast(params["file_uuid"] || ""),
           %StorageFile{} = file <- PhoenixKit.Config.get_repo().get(StorageFile, uuid) do
        query =
          case params["annotation"] do
            annotation when is_binary(annotation) and annotation != "" ->
              [file: uuid, annotation: annotation]

            _ ->
              [file: uuid]
          end

        Routes.path(browse_path(file, scope)) <> "?" <> URI.encode_query(query)
      else
        _ -> Routes.path("/admin/media")
      end

    {:ok, push_navigate(socket, to: target)}
  end

  def render(assigns), do: ~H""

  @doc """
  The (canonical, unprefixed) path of the page that browses the library `file`
  is in: Media for the default library, `/admin/media/library/<slug>` for
  another site library, and for a user's library the page `scope` browses it
  in (`Libraries.browse_path/2`).
  """
  @spec browse_path(StorageFile.t(), term()) :: String.t()
  def browse_path(%StorageFile{} = file, scope) do
    case Libraries.get_library(file.library_uuid) do
      %{kind: "user"} = library ->
        Libraries.browse_path(scope, library)

      %{kind: "system", is_default: false, slug: slug} when is_binary(slug) ->
        "/admin/media/library/#{slug}"

      _ ->
        "/admin/media"
    end
  end

  @doc "The prefixed path that opens `file` in the media view."
  @spec view_path(StorageFile.t(), term()) :: String.t()
  def view_path(%StorageFile{} = file, scope),
    do: Routes.path(browse_path(file, scope)) <> "?" <> URI.encode_query(file: file.uuid)

  @doc """
  The start of the header trail over a page about `file`, as `{section,
  section_path, crumbs}`: `Media` in the default library, `Media / <library>`
  in another site library, and a user's library under the page that browses it
  (`Media` or `Libraries`). `section_path` is canonical, unprefixed.
  """
  @spec trail(StorageFile.t(), term()) :: {String.t(), String.t(), [map()]}
  def trail(%StorageFile{} = file, scope) do
    case Libraries.get_library(file.library_uuid) do
      %{kind: "user"} = library ->
        index = Libraries.browse_index_path(scope)
        section = if index == "/admin/media", do: gettext("Media"), else: gettext("Libraries")
        {section, index, [crumb(library.name, Libraries.browse_path(scope, library))]}

      %{kind: "system", is_default: false, slug: slug, name: name} when is_binary(slug) ->
        {gettext("Media"), "/admin/media", [crumb(name, "/admin/media/library/#{slug}")]}

      _ ->
        {gettext("Media"), "/admin/media", []}
    end
  end

  defp crumb(label, path), do: %{label: label, path: Routes.path(path)}
end
