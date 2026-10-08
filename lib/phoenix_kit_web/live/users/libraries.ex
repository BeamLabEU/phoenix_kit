defmodule PhoenixKitWeb.Live.Users.Libraries do
  @moduledoc """
  A user's storage libraries (V203): `/admin/libraries` lists the ones they
  own or are a member of, and `/admin/libraries/<slug or uuid>` browses one
  with `PhoenixKitWeb.Components.MediaBrowser`.

  Gated by the `"storage"` permission, and only while user libraries are on
  (`Storage.Libraries.may_use_libraries?/1`). A library is named in the URL
  by its slug when it is the viewer's own and by its uuid when it is shared
  with them (`Libraries.url_id/2`). A viewer gets the browser read-only.
  Creating, renaming, members and the default library are managed on the
  profile's Media tab (`/profile/settings/media`).

  ## Owner and Admin

  An Owner or Admin sees every other user's libraries on `/admin/libraries`
  too, below their own (metadata only: owner, files, size), and can open one
  by its uuid. Every such opening is written to the
  audit log (`"storage.library_opened"`: who, which library, when, the IP
  address and the user agent). The `"storage"` permission alone never opens
  someone else's library.
  """
  use PhoenixKitWeb, :live_view
  use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: [id: "library-browser"]

  require Logger

  alias PhoenixKit.AuditLog
  alias PhoenixKit.Modules.Storage.{Libraries, Library}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.IpAddress
  alias PhoenixKit.Utils.Routes

  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Libraries"))
     |> assign(:project_title, Settings.get_project_title())
     |> assign(:current_locale, params["locale"] || socket.assigns[:current_locale])
     |> assign(:url_path, Routes.path("/admin/libraries"))
     |> assign(:libraries, nil)
     |> assign(:others, [])
     |> assign(:library, nil)
     |> assign(:role, nil)
     |> assign(:header_section, nil)
     |> assign(:header_switcher, nil)
     # Read here: connect info is only available while mounting.
     |> assign(:client_ip, IpAddress.extract_from_socket(socket))
     |> assign(:user_agent, user_agent(socket))}
  end

  def handle_params(params, _uri, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    cond do
      # A holder of `media` browses their libraries in Media (one switcher over
      # the site's libraries and their own); old links and bookmarks land there.
      Libraries.browse_in_media?(scope) ->
        {:noreply,
         push_navigate(socket, to: Routes.path(media_destination(scope, params["library_id"])))}

      Libraries.may_use_libraries?(scope) or Scope.system_role?(scope) ->
        browse(socket, scope, params)

      true ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Libraries are not available"))
         # Not /admin: a user whose only permission is "storage" is sent from
         # there to here, so while libraries are off that would loop.
         |> push_navigate(to: Routes.path("/profile/settings"))}
    end
  end

  defp media_destination(_scope, id) when is_binary(id), do: "/admin/media/my/#{id}"

  defp media_destination(scope, nil) do
    case Libraries.default_user_library(Scope.user_uuid(scope)) do
      %Library{} = library ->
        "/admin/media/my/#{Libraries.url_id(library, Scope.user_uuid(scope))}"

      _ ->
        "/admin/media"
    end
  end

  defp browse(socket, scope, params) do
    socket =
      if socket.assigns.libraries,
        do: socket,
        else: assign(socket, :libraries, Libraries.list_user_libraries(Scope.user_uuid(scope)))

    {:noreply, open(socket, scope, params["library_id"])}
  end

  # The list, read afresh on every visit: a library created or shared in
  # the meantime shows up. An Owner/Admin also sees every other user's
  # libraries (metadata only; opening one is audit-logged).
  defp open(socket, scope, nil) do
    mine = Libraries.list_user_libraries(Scope.user_uuid(scope))

    socket
    |> assign(:libraries, mine)
    |> assign(:others, others(scope, mine))
    |> assign(:library, nil)
    |> assign(:role, nil)
    |> assign(:header_section, nil)
    |> assign(:header_switcher, nil)
    |> assign(:page_title, gettext("Libraries"))
    |> assign(:url_path, Routes.path("/admin/libraries"))
  end

  # The same library again (a folder patch inside it): nothing to reload,
  # nothing to log again. A slug names a library only among its owner's, so it
  # counts only for the viewer's own: a shared library with the same slug is
  # another one.
  defp open(%{assigns: %{library: %Library{} = library}} = socket, scope, id)
       when is_binary(id) do
    if id == library.uuid or id == Libraries.url_id(library, Scope.user_uuid(scope)),
      do: socket,
      else: open_other(socket, scope, id)
  end

  defp open(socket, scope, id), do: open_other(socket, scope, id)

  defp open_other(socket, scope, id) do
    case Libraries.get_user_library(scope, id) do
      %{library: library, role: role} ->
        shown(socket, library, role)

      nil ->
        case admin_opening(scope, id) do
          %Library{} = library ->
            log_admin_opening(socket, scope, library)
            shown(socket, library, :admin)

          nil ->
            socket
            |> put_flash(:error, gettext("Library not found"))
            |> push_patch(to: Routes.path("/admin/libraries"))
        end
    end
  end

  defp shown(socket, library, role) do
    socket
    |> assign(:library, library)
    |> assign(:role, role)
    |> assign(:page_title, library.name)
    |> assign(:url_path, library_path(library, socket))
    |> assign(:header_section, gettext("Libraries"))
    |> assign(:header_switcher, library_switcher(socket, library, role))
  end

  # The ▾ beside the library's name lists the viewer's own and shared libraries.
  # Every row is a `patch` to a path built here from that list. An Owner/Admin
  # looking at someone else's library (`:admin`) has nothing to switch between.
  defp library_switcher(socket, library, role) do
    libraries = socket.assigns.libraries || []

    if role != :admin and length(libraries) > 1 do
      %{
        title: gettext("Switch library"),
        search_placeholder: gettext("Search libraries…"),
        items:
          for %{library: l} <- libraries do
            %{label: l.name, patch: library_path(l, socket), current: l.uuid == library.uuid}
          end
      }
    end
  end

  defp others(scope, mine) do
    if Scope.system_role?(scope) do
      listed = Enum.map(mine, & &1.library.uuid)
      Enum.reject(Libraries.list_user_libraries_for_admin(), &(&1.library.uuid in listed))
    else
      []
    end
  end

  # An Owner/Admin opening someone else's live user library, by uuid only.
  defp admin_opening(scope, id) do
    with true <- Scope.system_role?(scope),
         {:ok, uuid} <- Ecto.UUID.cast(id),
         %Library{kind: "user", trashed_at: nil} = library <- Libraries.get_library(uuid) do
      library
    else
      _ -> nil
    end
  end

  defp log_admin_opening(socket, scope, library) do
    if connected?(socket) do
      AuditLog.create_log_entry(%{
        admin_user_uuid: Scope.user_uuid(scope),
        target_user_uuid: library.owner_uuid,
        action: "storage.library_opened",
        ip_address: socket.assigns.client_ip,
        user_agent: socket.assigns.user_agent,
        metadata: %{"library_uuid" => library.uuid, "library_name" => library.name}
      })
    end
  rescue
    error -> Logger.error("Libraries: audit entry failed: #{Exception.message(error)}")
  catch
    # A dead pool exits rather than raises; the library must still open.
    :exit, reason -> Logger.error("Libraries: audit entry failed: #{inspect(reason)}")
  end

  defp user_agent(socket) do
    if connected?(socket), do: get_connect_info(socket, :user_agent)
  rescue
    _ -> nil
  end

  defp url_id(library, socket),
    do: Libraries.url_id(library, Scope.user_uuid(socket.assigns[:phoenix_kit_current_scope]))

  @doc false
  # The path of a library for the viewer (`user_uuid`, or a socket carrying
  # the scope).
  def library_path(library, %Phoenix.LiveView.Socket{} = socket),
    do: Routes.path("/admin/libraries/#{url_id(library, socket)}")

  def library_path(library, user_uuid),
    do: Routes.path("/admin/libraries/#{Libraries.url_id(library, user_uuid)}")

  @doc false
  def role_label(:owner), do: gettext("Owner")
  def role_label(:manager), do: gettext("Manager")
  def role_label(:contributor), do: gettext("Contributor")
  def role_label(:viewer), do: gettext("Viewer")
  def role_label(:admin), do: gettext("Opened as admin")
  def role_label(_role), do: ""

  @doc false
  # Only a viewer looks without touching; an Owner/Admin who opened it can
  # act on it (a takedown is the reason to open one).
  def readonly?(role), do: role == :viewer

  @doc false
  # A contributor changes only the files they uploaded; everyone else who
  # may write changes any file of the library.
  def own_files_only(:contributor, %{uuid: uuid}), do: uuid
  def own_files_only(_role, _user), do: nil
end
