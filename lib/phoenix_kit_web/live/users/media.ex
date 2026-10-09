defmodule PhoenixKitWeb.Live.Users.Media do
  @moduledoc """
  Media management LiveView — thin wrapper around `MediaBrowser` LiveComponent.

  This LiveView owns the page layout and assigns required by
  `LayoutWrapper.app_layout`. All media browser state and logic live in
  `PhoenixKitWeb.Components.MediaBrowser`.

  URL sync (shareable `…/admin/media?folder=<uuid>` deep links) is provided
  by the `MediaBrowser.Embed` macro's `url_sync` option — it injects the
  `handle_params` / `{:navigate}` → `push_patch` round-trip and parses
  `:initial_params` from the URL in `on_mount`, so this module only owns
  the page-chrome assigns.

  ## Libraries

  The page shows one library at a time, and **what it shows depends on who is
  looking** (`dev_docs/plans/2026-09-30-media-by-viewer.md`):

    * a **site library** (`PhoenixKit.Modules.Storage.Libraries`): the default one
      (Media) at the bare `/admin/media`, any other at `/admin/media/library/<slug>`.
      An Owner/Admin, or a holder of `media.view_all`, sees every file. A holder
      of `media` without it sees only their own stuff: the files they uploaded,
      the folders they created or that hold their files, and those folders'
      ancestors (`MediaBrowser`'s `viewer_uuid`).
    * one of the viewer's **own or shared user libraries** (while user libraries
      are on and the viewer holds `storage`), at `/admin/media/my/<slug or uuid>`,
      with the rights their role gives them there.

  They share one switcher in the admin header (the ▾ beside the page title, the
  title being the library on screen), each row hinted "Site" or "Mine". While
  there is only one library, nothing about libraries is shown. Another user's library is opened, by
  an Owner/Admin, at `/admin/libraries` (audit-logged), not here. Libraries are
  created, renamed and deleted in Settings → Media → Libraries (site) and on the
  profile's Media tab (user).
  """
  use PhoenixKitWeb, :live_view
  use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: [id: "media-browser"]

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Users.Libraries, as: LibrariesPage

  def mount(params, _session, socket) do
    locale = params["locale"] || socket.assigns[:current_locale]

    settings =
      Settings.get_settings_cached(
        ["project_title"],
        %{"project_title" => PhoenixKit.Config.get(:project_title, "PhoenixKit")}
      )

    socket =
      socket
      |> assign(:page_title, gettext("Media"))
      |> assign(:header_title, gettext("Media"))
      |> assign(:header_section, nil)
      |> assign(:header_switcher, nil)
      |> assign(:project_title, settings["project_title"])
      |> assign(:current_locale, locale)
      |> assign(:url_path, Routes.path("/admin/media"))
      |> assign(:libraries, nil)
      |> assign(:my_libraries, [])
      |> assign(:library, nil)
      |> assign(:role, nil)
      |> assign(:viewer_uuid, nil)
      |> assign(:can_manage_storage, Scope.can?(scope(socket), "media.manage"))
      |> assign(:selected_annotation, nil)

    {:ok, socket}
  end

  # The libraries are read once per page, not on every folder navigation
  # (each one is a patch through here).
  def handle_params(params, _uri, socket) do
    socket = if socket.assigns.libraries, do: socket, else: load_libraries(socket)

    case select_library(socket, params) do
      {:ok, socket} ->
        {:noreply, socket |> assign_header() |> select_annotation(params)}

      # A library that is not one the viewer may open is not quietly shown as
      # Media: an upload there would land somewhere the visitor did not ask for.
      :not_found ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Library not found"))
         |> push_patch(to: library_path(nil))}
    end
  end

  # A link to a comment's shape (`?file=<uuid>&annotation=<uuid>`, the old
  # address of a file keeps it) selects that shape once the viewer has the
  # canvas up; the JS bridge retries until it is ready. Once per link, not on
  # every patch that follows.
  defp select_annotation(socket, %{"file" => file, "annotation" => annotation}) do
    with true <- connected?(socket),
         {:ok, file} <- Ecto.UUID.cast(file),
         {:ok, annotation} <- Ecto.UUID.cast(annotation),
         true <- socket.assigns[:selected_annotation] != annotation do
      socket
      |> assign(:selected_annotation, annotation)
      |> push_event("etcher:select-shape", %{fresco_id: "media-zoom-" <> file, uuid: annotation})
    else
      _ -> socket
    end
  end

  defp select_annotation(socket, _params), do: socket

  defp scope(socket), do: socket.assigns[:phoenix_kit_current_scope]

  defp load_libraries(socket) do
    scope = scope(socket)

    mine =
      if Libraries.may_use_libraries?(scope),
        do: Libraries.list_user_libraries(Scope.user_uuid(scope)),
        else: []

    socket
    |> assign(:libraries, Libraries.list_system_libraries())
    |> assign(:my_libraries, mine)
  end

  # A user library of the viewer's own, or shared with them: `/my/<id>`.
  defp select_library(socket, %{"library_id" => id}) do
    case Enum.find(socket.assigns.my_libraries, &(url_id(&1.library, socket) == id)) do
      nil ->
        :not_found

      %{library: library, role: role} ->
        {:ok,
         socket
         |> assign(:library, library)
         |> assign(:role, role)
         |> assign(:viewer_uuid, nil)}
    end
  end

  # The bare page is the default library; `/library/<slug>` another live system
  # library. A slug that names none is `:not_found`.
  defp select_library(socket, %{"library_slug" => slug}) when slug not in [nil, ""] do
    case Enum.find(socket.assigns.libraries, &(&1.slug == slug)) do
      nil -> :not_found
      library -> {:ok, site_library(socket, library)}
    end
  end

  defp select_library(socket, _params) do
    libraries = socket.assigns.libraries
    {:ok, site_library(socket, Enum.find(libraries, & &1.is_default) || List.first(libraries))}
  end

  defp site_library(socket, library) do
    socket
    |> assign(:library, library)
    |> assign(:role, nil)
    |> assign(:viewer_uuid, restricted_viewer(scope(socket)))
  end

  @doc false
  # Who a site library is restricted to: nobody for an Owner/Admin or a holder of
  # `media.view_all`; otherwise the viewer, who sees only their own stuff.
  def restricted_viewer(scope) do
    if Scope.system_role?(scope) or Scope.can?(scope, "media.view_all"),
      do: nil,
      else: Scope.user_uuid(scope)
  end

  # Switching library opens it at its root: no folder, search or page from
  # the other one carries over. The default library is the bare page.
  defp library_path(slug) when slug in [nil, ""], do: Routes.path("/admin/media")
  defp library_path(slug), do: Routes.path("/admin/media/library/#{slug}")

  defp my_library_path(library, socket),
    do: Routes.path("/admin/media/my/#{url_id(library, socket)}")

  defp url_id(library, socket), do: Libraries.url_id(library, Scope.user_uuid(scope(socket)))

  @doc false
  # The library on screen. Nil used to mean "don't filter", which listed every
  # file — the same set as Media while that was the only library, and other
  # people's libraries once user libraries existed.
  def browser_library_uuid(_libraries, %{uuid: uuid}) when is_binary(uuid), do: uuid
  def browser_library_uuid(_libraries, _), do: Libraries.media_uuid()

  @doc false
  # A user library is browsed with the rights of the viewer's role in it; a site
  # library has no role (`nil`): it is governed by `viewer_uuid`.
  def readonly?(role), do: LibrariesPage.readonly?(role)

  @doc false
  def own_files_only(role, user), do: LibrariesPage.own_files_only(role, user)

  @doc false
  def role_label(role), do: LibrariesPage.role_label(role)

  # The header names the library on screen and, once there is more than one,
  # hangs the switcher on that name. With one library the page says nothing
  # about libraries: the plain "Media" title, no switcher. Every item is a
  # `patch` to a path built here from the lists the page loaded, so a value from
  # the client never reaches a path.
  defp assign_header(socket) do
    %{libraries: libraries, my_libraries: mine, library: library, role: role} = socket.assigns

    if length(libraries || []) + length(mine) > 1 and library do
      assign(socket,
        header_title: library.name,
        header_section: unless(default_library?(library, role), do: gettext("Media")),
        header_switcher: library_switcher(socket, libraries, mine, library, role)
      )
    else
      assign(socket, header_title: gettext("Media"), header_section: nil, header_switcher: nil)
    end
  end

  # The default site library is Media itself: "Media / Media" would say it twice.
  defp default_library?(library, role), do: is_nil(role) and library.is_default == true

  defp library_switcher(socket, libraries, mine, library, role) do
    # With none of the viewer's own, the site ones need no hint.
    site_hint = if mine == [], do: nil, else: gettext("Site")

    site =
      for l <- libraries do
        %{
          label: l.name,
          patch: library_path(l.slug),
          hint: site_hint,
          current: is_nil(role) and l.uuid == library.uuid
        }
      end

    own =
      for %{library: l} <- mine do
        %{
          label: l.name,
          patch: my_library_path(l, socket),
          hint: gettext("Mine"),
          current: role != nil and l.uuid == library.uuid
        }
      end

    %{
      title: gettext("Switch library"),
      search_placeholder: gettext("Search libraries…"),
      items: site ++ own
    }
  end
end
