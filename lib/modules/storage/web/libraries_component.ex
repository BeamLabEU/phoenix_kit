defmodule PhoenixKitWeb.Live.Modules.Storage.LibrariesComponent do
  @moduledoc """
  The Libraries tab of Settings → Media: the system storage libraries
  (`PhoenixKit.Modules.Storage.Libraries`) at a glance, and creating them.

  A library is a short row: its name (a link to its own page,
  `LibraryPage`, where it is renamed, deleted, its files and sync are
  watched and its history read), what it holds, where its files are kept and
  how it is syncing. The media page itself only switches between libraries
  (and only once there are two); managing them lives here, next to the buckets
  their files are stored in.

  Where a library keeps its files (its **storage profile**) and which
  renditions its uploads get (its **rendition set**, `VariantSet`), V205, are
  chosen **once, when it is created**, and shown read-only afterwards: moving a library to another
  profile is a bulk move of its files, so it is not a dropdown. To move where
  the files of every library on a profile live, change the profile's buckets
  (Storage profiles tab). The choice is offered only when there is something to
  choose between.

  ## User libraries (V203)

  A second card turns user libraries on for the install
  (`storage_user_libraries_enabled`, off by default), whether they may keep a
  library on their own bucket (`storage_user_buckets_enabled`, off by
  default), sets how many each
  user may own (`storage_user_library_limit`) and how long a private file
  URL stays valid (`storage_private_url_window_hours`), and lists every
  user library as **metadata only**: owner, members, files, size and trash
  state. Their files are the users' own. Opening one goes through
  `/admin/libraries/<uuid>`, which admits only an Owner or Admin and writes
  every opening to the audit log.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Modules.Storage.{
    Libraries,
    LibraryState,
    Profiles,
    VariantSets
  }

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Modules.Storage.LibrarySync

  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, creating: false, rows: nil, scope: nil, sync: %{})}
  end

  @impl true
  # `reload_sync` comes from the settings page when a reconcile run moves.
  def update(%{reload_sync: true}, socket) do
    {:ok, if(socket.assigns.rows, do: load_sync(socket), else: socket)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(socket.assigns.rows, do: socket, else: load(socket))}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, :creating, true)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, :creating, false)}
  end

  def handle_event("create", %{"name" => name} = params, socket) do
    attrs = %{
      name: name,
      storage_profile_uuid: params["profile"],
      variant_set_uuid: params["set"]
    }

    case Libraries.create_system_library(attrs, actor(socket)) do
      {:ok, library} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> load()
         |> flash(:info, gettext("Library \"%{name}\" created", name: library.name))}

      {:error, changeset} ->
        {:noreply, flash(socket, :error, error_message(changeset))}
    end
  end

  # Check now / Pause / Resume on a library's sync. The permission check is the
  # Jobs context's; the buttons are only shown to those who pass it, and a
  # hand-made event is refused all the same.
  def handle_event("sync", %{"action" => action, "uuid" => uuid}, socket) do
    with %{} = library <- find(socket, uuid),
         {:ok, _} <-
           LibrarySync.run(
             action,
             library.uuid,
             socket.assigns.sync[to_string(library.uuid)],
             socket.assigns.scope
           ) do
      {:noreply, load_sync(socket)}
    else
      nil ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, socket |> load_sync() |> flash(:error, LibrarySync.error_message(reason))}
    end
  end

  def handle_event("save_user_libraries", %{"user_libraries" => params}, socket) do
    enabled? = params["enabled"] == "true"
    buckets? = params["own_buckets"] == "true"

    limit =
      case Integer.parse(to_string(params["limit"])) do
        {n, ""} when n >= 0 and n <= 1000 -> n
        _ -> Libraries.user_library_limit()
      end

    hours =
      case Integer.parse(to_string(params["window_hours"])) do
        {n, ""} when n >= 1 and n <= 720 -> n
        _ -> div(URLSigner.private_url_window_seconds(), 3600)
      end

    opts = actor(socket) ++ [source: "settings"]

    with {:ok, _} <-
           Settings.update_boolean_setting("storage_user_libraries_enabled", enabled?, opts),
         {:ok, _} <-
           Settings.update_boolean_setting("storage_user_buckets_enabled", buckets?, opts),
         {:ok, _} <- Settings.update_setting("storage_user_library_limit", to_string(limit), opts),
         {:ok, _} <-
           Settings.update_setting("storage_private_url_window_hours", to_string(hours), opts) do
      {:noreply, socket |> load() |> flash(:info, gettext("User library settings saved"))}
    else
      _ -> {:noreply, flash(socket, :error, gettext("User library settings could not be saved"))}
    end
  end

  # Who is acting, for the history (`Storage.Audit`).
  defp actor(socket), do: PhoenixKitWeb.Actor.opts(socket.assigns.scope)

  defp find(socket, uuid) do
    Enum.find_value(socket.assigns.rows, fn %{library: library} ->
      if library.uuid == uuid, do: library
    end)
  end

  # The state of every library's sync (three queries however many libraries).
  defp load_sync(socket) do
    uuids = Enum.map(socket.assigns.rows, fn %{library: library} -> library.uuid end)
    assign(socket, :sync, LibraryState.for_libraries(uuids))
  end

  defp load(socket) do
    socket
    |> assign(:rows, Libraries.list_system_libraries_with_stats())
    |> load_sync()
    |> assign(:user_rows, Libraries.list_user_libraries_for_admin())
    |> assign(:user_libraries_enabled, Libraries.user_libraries_enabled?())
    |> assign(:user_buckets_enabled, Libraries.user_buckets_enabled?())
    |> assign(:user_library_limit, Libraries.user_library_limit())
    |> assign(:window_hours, div(URLSigner.private_url_window_seconds(), 3600))
    |> assign(:profiles, Profiles.list_profiles())
    |> assign(:variant_sets, VariantSets.list_variant_sets())
  end

  # A component's own `put_flash` reaches the page only when it also
  # navigates, which this tab does not: the settings page puts it
  # (`handle_info({LibrariesComponent, {:flash, …}})`).
  defp flash(socket, kind, message) do
    send(self(), {__MODULE__, {:flash, kind, message}})
    socket
  end

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{field_label(field)}: #{&1}")
    end)
    |> Enum.join("; ")
  end

  defp field_label(:storage_profile_uuid), do: gettext("Storage profile")
  defp field_label(:variant_set_uuid), do: gettext("Rendition set")
  defp field_label(_field), do: gettext("Library name")

  # Where a library keeps its files and which sizes it gets: names only, and
  # nothing to choose when there is only the Default of each.
  defp storage_text(library) do
    gettext("%{profile} · %{set}",
      profile: Profiles.profile_name(Profiles.profile_uuid_for(library)),
      set: VariantSets.set_name(VariantSets.set_uuid_for(library))
    )
  end

  defp choice?(profiles, sets), do: length(profiles) > 1 or length(sets) > 1

  # Where a user library keeps its files, for the admin's list. The bucket's
  # name and provider only: never its connection, keys or endpoint.
  defp storage_label(nil), do: gettext("Site storage")

  defp storage_label(%{mode: :only, bucket: bucket}),
    do: gettext("Own %{provider} bucket", provider: String.upcase(bucket.provider))

  defp storage_label(%{mode: :backup, bucket: bucket}),
    do: gettext("Site storage + own %{provider} backup", provider: String.upcase(bucket.provider))

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div id={"#{@id}-system"} class="card bg-base-100 shadow-xl mb-6 mt-6">
        <div class="card-body">
          <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
            <h2 class="card-title text-lg">
              <.icon name="hero-rectangle-stack" class="w-6 h-6 mr-2" /> {gettext("Libraries")}
            </h2>
            <button
              :if={not @creating}
              type="button"
              class="btn btn-primary"
              phx-click="new"
              phx-target={@myself}
            >
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("New library")}
            </button>
          </div>

          <p class="text-sm text-base-content/70 mb-4">
            {gettext(
              "A library is a separate space in Media with its own folders. Everything uploaded so far is in the default library. The Media page shows a library switcher once there are two or more. Open a library to rename it or see where its files are."
            )}
          </p>

          <form
            :if={@creating}
            id={"#{@id}-new"}
            phx-submit="create"
            phx-target={@myself}
            class="flex flex-wrap items-end gap-2 mb-4"
          >
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Library name")}</span>
              <input
                type="text"
                name="name"
                id={"#{@id}-new-name"}
                class="input input-sm input-bordered w-64"
                placeholder={gettext("Library name")}
                maxlength="255"
                required
                autofocus
              />
            </label>
            <label :if={choice?(@profiles, @variant_sets)} class="form-control">
              <span
                class="label-text text-sm tooltip tooltip-bottom text-left"
                data-tip={
                  gettext(
                    "Which buckets keep this library's files. Chosen now; it does not change afterwards."
                  )
                }
              >
                {gettext("Storage profile")}
              </span>
              <select name="profile" class="select select-sm select-bordered">
                <option :for={profile <- @profiles} value={profile.uuid}>{profile.name}</option>
              </select>
            </label>
            <label :if={choice?(@profiles, @variant_sets)} class="form-control">
              <span
                class="label-text text-sm tooltip tooltip-bottom text-left"
                data-tip={
                  gettext(
                    "Which renditions its uploads get: smaller copies such as thumbnails and video resolutions. Chosen now; it does not change afterwards."
                  )
                }
              >
                {gettext("Rendition set")}
              </span>
              <select name="set" class="select select-sm select-bordered">
                <option :for={set <- @variant_sets} value={set.uuid}>{set.name}</option>
              </select>
            </label>
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Create")}</button>
            <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel" phx-target={@myself}>
              {gettext("Cancel")}
            </button>
          </form>

          <div class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>{gettext("Name")}</th>
                  <th class="text-right">{gettext("Files")}</th>
                  <th class="text-right">{gettext("Size")}</th>
                  <th>{gettext("Storage")}</th>
                  <th>{gettext("Sync")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={%{library: library} = row <- @rows} id={"#{@id}-#{library.uuid}"}>
                  <td>
                    <.link
                      navigate={Routes.path("/admin/settings/media/libraries/#{library.uuid}")}
                      class="link link-hover font-medium"
                    >
                      {library.name}
                    </.link>
                    <span :if={library.is_default} class="badge badge-sm badge-ghost ml-2">
                      {gettext("Default")}
                    </span>
                  </td>
                  <td class="text-right tabular-nums">{row.files}</td>
                  <td class="text-right tabular-nums whitespace-nowrap">{Format.bytes(row.bytes)}</td>
                  <td class="text-sm">{storage_text(library)}</td>
                  <td id={"#{@id}-sync-#{library.uuid}"}>
                    <LibrarySync.sync_cell
                      state={@sync[to_string(library.uuid)]}
                      uuid={library.uuid}
                      scope={@scope}
                      target={@myself}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <div id={"#{@id}-user"} class="card bg-base-100 shadow-xl mb-6">
        <div class="card-body">
          <h2 class="card-title text-lg">
            <.icon name="hero-users" class="w-6 h-6 mr-2" /> {gettext("User libraries")}
          </h2>
          <p class="text-sm text-base-content/70 mb-2">
            {gettext(
              "Users with the Storage permission can keep libraries of their own, private to them and the members they add. Their files are served only through links that expire."
            )}
          </p>

          <form
            id={"#{@id}-user-settings"}
            phx-submit="save_user_libraries"
            phx-target={@myself}
            class="flex flex-wrap items-end gap-4 mb-4"
          >
            <label class="label cursor-pointer gap-2">
              <input type="hidden" name="user_libraries[enabled]" value="false" />
              <input
                type="checkbox"
                name="user_libraries[enabled]"
                value="true"
                checked={@user_libraries_enabled}
                class="toggle toggle-primary"
              />
              <span class="label-text">{gettext("Allow user libraries")}</span>
            </label>
            <label
              class="label cursor-pointer gap-2"
              title={
                gettext(
                  "Users who also hold the Storage own-storage and Integrations permissions may keep a library on their own S3-compatible bucket. Their files then live outside the site's storage."
                )
              }
            >
              <input type="hidden" name="user_libraries[own_buckets]" value="false" />
              <input
                type="checkbox"
                name="user_libraries[own_buckets]"
                value="true"
                checked={@user_buckets_enabled}
                class="toggle toggle-primary"
              />
              <span class="label-text">{gettext("Allow their own buckets")}</span>
            </label>
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Libraries per user")}</span>
              <input
                type="number"
                name="user_libraries[limit]"
                min="0"
                max="1000"
                value={@user_library_limit}
                class="input input-sm input-bordered w-28"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Private links last (hours)")}</span>
              <input
                type="number"
                name="user_libraries[window_hours]"
                min="1"
                max="720"
                value={@window_hours}
                class="input input-sm input-bordered w-28"
              />
            </label>
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
          </form>

          <div :if={@user_rows == []} class="text-sm text-base-content/60">
            {gettext("No user libraries yet.")}
          </div>

          <div :if={@user_rows != []} class="overflow-x-auto">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>{gettext("Name")}</th>
                  <th>{gettext("Owner")}</th>
                  <th>{gettext("Storage")}</th>
                  <th class="text-right">{gettext("Members")}</th>
                  <th class="text-right">{gettext("Files")}</th>
                  <th class="text-right">{gettext("Size")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={%{library: library} = row <- @user_rows} id={"#{@id}-user-#{library.uuid}"}>
                  <td>
                    <span class="font-medium">{library.name}</span>
                    <span :if={library.trashed_at} class="badge badge-sm badge-warning ml-2">
                      {gettext("Trashed")}
                    </span>
                  </td>
                  <td class="text-sm">{(library.owner && library.owner.email) || "—"}</td>
                  <td class="text-sm">{storage_label(row.own_storage)}</td>
                  <td class="text-right">{row.members}</td>
                  <td class="text-right">{row.files}</td>
                  <td class="text-right">{Format.bytes(row.bytes)}</td>
                  <td class="text-right">
                    <.link
                      :if={is_nil(library.trashed_at)}
                      navigate={Routes.path("/admin/libraries/#{library.uuid}")}
                      class="btn btn-xs btn-ghost"
                      title={gettext("Opening a user's library is recorded in the audit log.")}
                    >
                      <.icon name="hero-eye" class="w-4 h-4" /> {gettext("Open")}
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
