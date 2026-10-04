defmodule PhoenixKitWeb.Live.Modules.Storage.LibrariesComponent do
  @moduledoc """
  The Libraries tab of Settings → Media: the system storage libraries
  (`PhoenixKit.Modules.Storage.Libraries`), what each holds, and creating,
  renaming and deleting them.

  The media page itself only switches between libraries (and only once there
  are two); managing them lives here, next to the buckets their files are
  stored in. The default library, Media, can be renamed but never deleted,
  and any other library only once it holds nothing — the database refuses it
  otherwise too. Renaming keeps a library's URL (`/admin/media/library/<slug>`).

  Each system library picks its storage profile (where its files are kept)
  and variant set (which sizes its uploads get), V205. Changing either moves
  or resizes its files in the background.

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

  alias PhoenixKit.Jobs
  alias PhoenixKit.Modules.Storage.Jobs.Reconcile

  alias PhoenixKit.Modules.Storage.{
    AnnotationThumbnail,
    Audit,
    Libraries,
    LibraryState,
    Profiles,
    VariantSets
  }

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]
  import PhoenixKitWeb.Components.Core.SaveButton, only: [save_button: 1]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       creating: false,
       renaming: nil,
       rows: nil,
       scope: nil,
       sync: %{},
       dirty: MapSet.new(),
       saved: MapSet.new()
     )}
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
    {:noreply, assign(socket, creating: true, renaming: nil)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, creating: false, renaming: nil)}
  end

  def handle_event("create", %{"name" => name}, socket) do
    case Libraries.create_system_library(%{name: name}, actor(socket)) do
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
  # Jobs context's (`jobs.manage` and `media.manage`, against the active role);
  # the buttons are only shown to those who pass it, and a hand-made event is
  # refused all the same.
  def handle_event("sync", %{"action" => action, "uuid" => uuid}, socket) do
    with %{} = library <- find(socket, uuid),
         {:ok, _} <- sync_action(action, library, socket) do
      {:noreply, load_sync(socket)}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, socket |> load_sync() |> flash(:error, sync_error(reason))}
    end
  end

  def handle_event("start_rename", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, renaming: uuid, creating: false)}
  end

  def handle_event("rename", %{"uuid" => uuid, "name" => name}, socket) do
    with %{} = library <- find(socket, uuid),
         {:ok, renamed} <- Libraries.rename_library(library, name, actor(socket)) do
      {:noreply,
       socket
       |> assign(:renaming, nil)
       |> load()
       |> flash(:info, gettext("Library renamed to \"%{name}\"", name: renamed.name))}
    else
      nil -> {:noreply, socket}
      {:error, changeset} -> {:noreply, flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with %{} = library <- find(socket, uuid),
         {:ok, _} <- Libraries.delete_library(library, actor(socket)) do
      {:noreply, socket |> load() |> flash(:info, gettext("Library deleted"))}
    else
      nil ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         flash(
           socket,
           :error,
           gettext("Only an empty library can be deleted, and never the default one.")
         )}
    end
  end

  # After a reconnect LiveView replays every form's values as a change, which is
  # not an edit: a recovered form goes to this event, not to "dirty"
  # (`phx-auto-recover`), so nothing shows as unsaved that was never touched.
  def handle_event("recover", _params, socket), do: {:noreply, socket}

  # A library's form changed: its Save button comes alive and says so. Nothing is
  # saved until it is pressed — a different profile or variant set moves and
  # resizes the library's files, which a stray click on a dropdown must not start.
  def handle_event("dirty", %{"key" => key}, socket) when is_binary(key) do
    {:noreply,
     assign(socket,
       dirty: MapSet.put(socket.assigns.dirty, key),
       saved: MapSet.delete(socket.assigns.saved, key)
     )}
  end

  # The library's storage (profile, variant set) and its own settings
  # (annotated thumbnails: on, off, or none — it follows the site setting,
  # Settings → Media → Configuration), saved together.
  def handle_event("save_library", %{"uuid" => uuid} = params, socket) do
    storage = Map.get(params, "storage", %{})

    value =
      case params["annotated"] do
        "on" -> true
        "off" -> false
        _ -> nil
      end

    with %{} = library <- find(socket, uuid),
         storage_changed? = storage_changed?(library, storage),
         {:ok, library} <- set_storage(library, storage, actor(socket)),
         {:ok, _library} <-
           Libraries.put_setting(library, :annotated_thumbnails, value, actor(socket)) do
      {:noreply,
       socket
       |> load()
       |> mark_saved(library_key(uuid))
       |> flash(:info, saved_message(storage_changed?))}
    else
      nil -> {:noreply, socket}
      {:error, _reason} -> {:noreply, flash(socket, :error, gettext("Could not save"))}
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

  # Both or neither.
  defp library_key(uuid), do: "library:#{uuid}"

  defp mark_saved(socket, key) do
    assign(socket,
      dirty: MapSet.delete(socket.assigns.dirty, key),
      saved: MapSet.put(socket.assigns.saved, key)
    )
  end

  defp storage_changed?(library, params) do
    new_profile = params["profile"]
    new_set = params["set"]

    (is_binary(new_profile) and new_profile != "" and
       new_profile != Profiles.profile_uuid_for(library)) or
      (is_binary(new_set) and new_set != "" and new_set != VariantSets.set_uuid_for(library))
  end

  defp saved_message(true) do
    gettext(
      "Library storage saved. Its files are moved and resized in the background; the Health page shows what is left."
    )
  end

  defp saved_message(false), do: gettext("Library setting saved")

  defp set_storage(library, params, actor) do
    Audit.transaction(fn ->
      with {:ok, library} <- maybe_set_profile(library, params["profile"], actor),
           {:ok, library} <- maybe_set_variant_set(library, params["set"], actor) do
        {:ok, library}
      else
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp maybe_set_profile(library, uuid, actor) when is_binary(uuid) and uuid != "" do
    if Profiles.profile_uuid_for(library) == uuid,
      do: {:ok, library},
      else: Profiles.set_library_profile(library, uuid, actor)
  end

  defp maybe_set_profile(library, _uuid, _actor), do: {:ok, library}

  defp maybe_set_variant_set(library, uuid, actor) when is_binary(uuid) and uuid != "" do
    if VariantSets.set_uuid_for(library) == uuid,
      do: {:ok, library},
      else: VariantSets.set_library_variant_set(library, uuid, actor)
  end

  defp maybe_set_variant_set(library, _uuid, _actor), do: {:ok, library}

  # Only a library this tab listed: the uuid arrives from the client.
  defp sync_action("check", library, socket) do
    case Jobs.start(socket.assigns.scope, Reconcile, {"library", to_string(library.uuid)}) do
      {:ok, run, _how} -> {:ok, run}
      error -> error
    end
  end

  defp sync_action("pause", library, socket), do: control(&Jobs.pause/2, library, socket)
  defp sync_action("resume", library, socket), do: control(&Jobs.resume/2, library, socket)
  defp sync_action(_action, _library, _socket), do: {:error, :unknown_action}

  defp control(fun, library, socket) do
    case socket.assigns.sync[to_string(library.uuid)] do
      %{run: %{} = run} -> fun.(socket.assigns.scope, run)
      _ -> {:error, :not_found}
    end
  end

  defp sync_error(:unauthorized), do: gettext("You may not do that.")

  defp sync_error(:draining),
    do: gettext("The current batch is still finishing; try again in a moment.")

  defp sync_error(_reason), do: gettext("That did not work.")

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
    |> assign(:annotated_default, AnnotationThumbnail.enabled?())
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
    |> Map.values()
    |> List.flatten()
    |> Enum.join("; ")
    |> then(&(gettext("Library name") <> ": " <> &1))
  end

  defp media_path(%{is_default: true}), do: Routes.path("/admin/media")
  defp media_path(%{slug: slug}), do: Routes.path("/admin/media/library/#{slug}")

  # Where a user library keeps its files, for the admin's list. The bucket's
  # name and provider only: never its connection, keys or endpoint.
  defp annotated_choice(library) do
    case Libraries.setting(library, :annotated_thumbnails) do
      true -> "on"
      false -> "off"
      nil -> "default"
    end
  end

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
              "A library is a separate space in Media with its own folders. Everything uploaded so far is in the default library. The Media page shows a library switcher once there are two or more."
            )}
          </p>

          <form
            :if={@creating}
            id={"#{@id}-new"}
            phx-submit="create"
            phx-target={@myself}
            class="flex flex-wrap items-center gap-2 mb-4"
          >
            <input
              type="text"
              name="name"
              id={"#{@id}-new-name"}
              class="input input-sm w-64"
              placeholder={gettext("Library name")}
              maxlength="255"
              required
              autofocus
            />
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
                  <th>{gettext("Address")}</th>
                  <th class="text-right">{gettext("Files")}</th>
                  <th class="text-right">{gettext("Folders")}</th>
                  <th class="text-right">{gettext("Size")}</th>
                  <th>{gettext("Storage")}</th>
                  <th>{gettext("Sync")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={%{library: library} = row <- @rows} id={"#{@id}-#{library.uuid}"}>
                  <td>
                    <%= if @renaming == library.uuid do %>
                      <form
                        id={"#{@id}-rename-#{library.uuid}"}
                        phx-submit="rename"
                        phx-target={@myself}
                        class="flex items-center gap-2"
                      >
                        <input type="hidden" name="uuid" value={library.uuid} />
                        <input
                          type="text"
                          name="name"
                          id={"#{@id}-rename-#{library.uuid}-name"}
                          value={library.name}
                          class="input input-sm w-56"
                          maxlength="255"
                          required
                          autofocus
                        />
                        <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
                        <button
                          type="button"
                          class="btn btn-sm btn-ghost"
                          phx-click="cancel"
                          phx-target={@myself}
                        >
                          {gettext("Cancel")}
                        </button>
                      </form>
                    <% else %>
                      <span class="font-medium">{library.name}</span>
                      <span :if={library.is_default} class="badge badge-sm badge-ghost ml-2">
                        {gettext("Default")}
                      </span>
                    <% end %>
                  </td>
                  <td>
                    <.link navigate={media_path(library)} class="link link-hover font-mono text-xs">
                      {media_path(library)}
                    </.link>
                  </td>
                  <td class="text-right">{row.files}</td>
                  <td class="text-right">{row.folders}</td>
                  <td class="text-right">{Format.bytes(row.bytes)}</td>
                  <td>
                    <form
                      id={"#{@id}-storage-#{library.uuid}"}
                      phx-change="dirty"
                      phx-auto-recover="recover"
                      phx-submit="save_library"
                      phx-target={@myself}
                      class="flex flex-col gap-1"
                    >
                      <input type="hidden" name="uuid" value={library.uuid} />
                      <input type="hidden" name="key" value={library_key(library.uuid)} />
                      <div class="flex flex-wrap gap-1">
                        <select
                          name="storage[profile]"
                          class="select select-xs select-bordered"
                          title={gettext("Storage profile")}
                        >
                          <option
                            :for={profile <- @profiles}
                            value={profile.uuid}
                            selected={Profiles.profile_uuid_for(library) == to_string(profile.uuid)}
                          >
                            {profile.name}
                          </option>
                        </select>
                        <select
                          name="storage[set]"
                          class="select select-xs select-bordered"
                          title={gettext("Variant set")}
                        >
                          <option
                            :for={set <- @variant_sets}
                            value={set.uuid}
                            selected={VariantSets.set_uuid_for(library) == to_string(set.uuid)}
                          >
                            {set.name}
                          </option>
                        </select>
                      </div>
                      <select
                        name="annotated"
                        class="select select-xs select-bordered"
                        title={
                          gettext(
                            "Annotated thumbnails: bake annotation shapes into the grid thumbnail"
                          )
                        }
                      >
                        <option value="default" selected={annotated_choice(library) == "default"}>
                          {if @annotated_default,
                            do: gettext("Annotated thumbnails: site setting (on)"),
                            else: gettext("Annotated thumbnails: site setting (off)")}
                        </option>
                        <option value="on" selected={annotated_choice(library) == "on"}>
                          {gettext("Annotated thumbnails: on")}
                        </option>
                        <option value="off" selected={annotated_choice(library) == "off"}>
                          {gettext("Annotated thumbnails: off")}
                        </option>
                      </select>
                      <.save_button
                        dirty={MapSet.member?(@dirty, library_key(library.uuid))}
                        saved={MapSet.member?(@saved, library_key(library.uuid))}
                      />
                    </form>
                  </td>
                  <td id={"#{@id}-sync-#{library.uuid}"} class="whitespace-nowrap">
                    <.sync_cell
                      state={@sync[to_string(library.uuid)]}
                      uuid={library.uuid}
                      scope={@scope}
                      target={@myself}
                    />
                  </td>
                  <td class="text-right whitespace-nowrap">
                    <button
                      :if={@renaming != library.uuid}
                      type="button"
                      class="btn btn-xs btn-ghost"
                      phx-click="start_rename"
                      phx-value-uuid={library.uuid}
                      phx-target={@myself}
                    >
                      <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Rename")}
                    </button>
                    <button
                      :if={not library.is_default}
                      type="button"
                      class="btn btn-xs btn-ghost text-error"
                      disabled={row.holds}
                      title={if row.holds, do: gettext("Only an empty library can be deleted.")}
                      phx-click="delete"
                      phx-value-uuid={library.uuid}
                      phx-target={@myself}
                      data-confirm={gettext("Delete this library?")}
                    >
                      <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
                    </button>
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

  # ---- the sync column --------------------------------------------------------

  attr :state, :map, default: nil
  attr :uuid, :any, required: true
  attr :scope, :any, default: nil
  attr :target, :any, required: true

  defp sync_cell(%{state: nil} = assigns), do: ~H""

  defp sync_cell(assigns) do
    assigns =
      assigns
      |> assign(:controls, run_controls(assigns))
      |> assign(:can_check?, Jobs.can_start?(assigns.scope, Reconcile))

    ~H"""
    <div class="flex flex-col gap-1">
      <div class="flex items-center gap-2">
        <span class={["badge badge-sm", sync_badge(@state.state)]} data-sync-state={@state.state}>
          {sync_label(@state.state)}
        </span>
        <span :if={@state.state in [:syncing, :paused, :waiting]} class="text-xs text-base-content/60">
          {ngettext("%{count} file left", "%{count} files left", @state.out_of_date)}
        </span>
        <span :if={@state.state == :attention and @state.failing > 0} class="text-xs text-warning">
          {ngettext(
            "%{count} file could not be finished",
            "%{count} files could not be finished",
            @state.failing
          )}
        </span>
      </div>
      <div class="flex flex-wrap items-center gap-1">
        <button
          :if={:pause in @controls and @state.state == :syncing}
          type="button"
          class="btn btn-xs"
          phx-click="sync"
          phx-value-action="pause"
          phx-value-uuid={@uuid}
          phx-target={@target}
        >
          <.icon name="hero-pause" class="w-3 h-3" /> {gettext("Pause")}
        </button>
        <button
          :if={:resume in @controls and @state.state == :paused}
          type="button"
          class="btn btn-xs btn-primary"
          phx-click="sync"
          phx-value-action="resume"
          phx-value-uuid={@uuid}
          phx-target={@target}
        >
          <.icon name="hero-play" class="w-3 h-3" /> {gettext("Resume")}
        </button>
        <button
          :if={@can_check? and @state.state in [:up_to_date, :waiting, :attention]}
          type="button"
          class="btn btn-xs btn-ghost"
          phx-click="sync"
          phx-value-action="check"
          phx-value-uuid={@uuid}
          phx-target={@target}
        >
          <.icon name="hero-arrow-path" class="w-3 h-3" /> {gettext("Check now")}
        </button>
        <.link
          :if={@state.run}
          navigate={Routes.path("/admin/jobs") <> "?run=" <> to_string(@state.run.uuid)}
          class="link link-hover text-xs"
        >
          {gettext("Details")}
        </.link>
      </div>
    </div>
    """
  end

  defp run_controls(%{state: %{run: %{state: state} = run}, scope: scope})
       when state in ~w(queued running pausing paused cancelling),
       do: Jobs.controls_for(scope, run)

  defp run_controls(_assigns), do: []

  defp sync_badge(:up_to_date), do: "badge-success"
  defp sync_badge(:syncing), do: "badge-info"
  defp sync_badge(:paused), do: "badge-warning"
  defp sync_badge(:waiting), do: "badge-warning"
  defp sync_badge(:attention), do: "badge-error"

  # "Up to date" says the files carry their library's current revisions; it does not
  # verify that every object is still on its bucket (LibraryState).
  defp sync_label(:up_to_date), do: gettext("Up to date")
  defp sync_label(:syncing), do: gettext("Syncing")
  defp sync_label(:paused), do: gettext("Paused")
  defp sync_label(:waiting), do: gettext("Waiting")
  defp sync_label(:attention), do: gettext("Needs attention")
end
