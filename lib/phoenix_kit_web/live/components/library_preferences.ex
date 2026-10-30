defmodule PhoenixKitWeb.Live.Components.LibraryPreferences do
  @moduledoc """
  A library's expandable settings workspace, shared by the profile and admin lists.
  Hosts add module settings through :library_settings_components, a list of
  %{id: string, title: string, component: LiveComponent} entries.
  """
  use PhoenixKitWeb, :live_component
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Libraries.Preferences
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def update(assigns, socket) do
    library = Libraries.get_library(assigns.library_uuid)
    profile = Profiles.get_profile(Profiles.profile_uuid_for(library))
    set = VariantSets.for_library(library)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       library: library,
       allowed: Preferences.can_manage?(assigns.scope, library),
       publish_allowed: Preferences.can_publish?(assigns.scope, library),
       access_options: access_options(assigns.scope, library),
       public_path: library_url(library, assigns.scope),
       profile_name:
         if(profile && profile.owner_uuid,
           do: gettext("Personal storage"),
           else: (profile && profile.name) || gettext("Default")
         ),
       backup_management_target: assigns[:backup_management_target],
       can_add_storage:
         library && library.owner_uuid == Scope.user_uuid(assigns.scope) && profile &&
           profile.owner_uuid != nil && Libraries.may_use_own_storage?(assigns.scope),
       rendition_set: set,
       rendition_options: VariantSets.list_selectable(),
       members: Libraries.list_members(library),
       management_target: assigns[:management_target],
       extensions: Application.get_env(:phoenix_kit, :library_settings_components, [])
     )
     |> assign_new(:active_tab, fn -> "general" end)
     |> select_url_tab(assigns[:selected_tab])
     |> assign_new(:form, fn -> preferences_form(library) end)
     |> assign_new(:message, fn -> nil end)
     |> assign_new(:error, fn -> nil end)}
  end

  defp select_url_tab(socket, tab) do
    if socket.assigns[:url_path] do
      assign(
        socket,
        :active_tab,
        if(Enum.any?(tabs(socket.assigns.extensions), &(&1.id == tab)), do: tab, else: "general")
      )
    else
      socket
    end
  end

  defp tabs(extensions) do
    [%{id: "general", label: gettext("General")}, %{id: "access", label: gettext("Access")}]
    |> Kernel.++(Enum.map(extensions, &%{id: &1.id, label: &1.title}))
    |> Kernel.++([
      %{id: "members", label: gettext("Members")},
      %{id: "storage", label: gettext("Storage and renditions")}
    ])
  end

  defp access_options(scope, library) do
    options = [
      {gettext("Private — owner and invited members"), "private"},
      {gettext("Signed-in users — account required"), "authenticated"},
      {gettext("Anyone — no account required"), "anonymous"}
    ]

    if Preferences.can_publish?(scope, library) do
      options
    else
      Enum.take(
        options,
        case Preferences.access_mode(library) do
          "private" -> 1
          "authenticated" -> 2
          _ -> 3
        end
      )
    end
  end

  @doc "The full, host-configured browsing URL for a library."
  def library_url(library, scope) do
    path = public_path(library) || Routes.path(Libraries.browse_path(scope, library))
    Routes.base_url() <> path
  end

  defp public_path(library) do
    case Application.get_env(:phoenix_kit, :library_public_path) do
      {module, function} -> apply(module, function, [library])
      _ -> nil
    end
  end

  defp preferences_form(library) do
    to_form(
      %{
        "name" => library.name,
        "slug" => library.slug,
        "access" => Preferences.access_mode(library),
        "confirm" => "false"
      },
      as: :library
    )
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    if Enum.any?(tabs(socket.assigns.extensions), &(&1.id == tab)) do
      socket = assign(socket, :active_tab, tab)

      socket =
        if path = socket.assigns[:url_path] do
          uri = URI.parse(path)
          params = URI.decode_query(uri.query || "") |> Map.put("settings_tab", tab)
          push_patch(socket, to: uri.path <> "?" <> URI.encode_query(params), replace: true)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate", %{"library" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: :library), error: nil, message: nil)}
  end

  def handle_event("save", %{"library" => params}, socket) do
    case Preferences.update(socket.assigns.scope, socket.assigns.library_uuid, params) do
      {:ok, library} ->
        if target = socket.assigns[:notify] do
          Phoenix.LiveView.send_update(target.module, id: target.id, reload_preferences: true)
        end

        {:noreply,
         assign(socket,
           library: library,
           public_path: library_url(library, socket.assigns.scope),
           access_options: access_options(socket.assigns.scope, library),
           form: preferences_form(library),
           message: gettext("Library settings saved"),
           error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: save_error(reason), form: to_form(params, as: :library))}
    end
  end

  def handle_event("renditions", %{"set" => uuid}, socket) do
    scope = Preferences.fresh_scope(socket.assigns.scope)
    library = Libraries.get_library(socket.assigns.library_uuid)
    choices = VariantSets.list_selectable()

    with true <- Preferences.can_manage?(scope, library),
         true <- Enum.any?(choices, &(&1.uuid == uuid)),
         {:ok, _} <-
           VariantSets.set_library_variant_set(library, uuid, actor_uuid: Scope.user_uuid(scope)) do
      Manager.broadcast(
        "storage:library_settings",
        {:library_settings_changed, library.uuid}
      )

      {:noreply,
       assign(socket,
         rendition_set: VariantSets.for_library(library),
         message: gettext("Renditions saved. Existing files are updated in the background."),
         error: nil
       )}
    else
      _ -> {:noreply, assign(socket, error: gettext("Could not change renditions."))}
    end
  end

  defp save_error(:publishing_not_allowed),
    do: gettext("Publishing libraries is not enabled for your account.")

  defp save_error(:confirmation_required),
    do: gettext("Confirm the access or address change before saving.")

  defp save_error(:not_allowed),
    do: gettext("Only the library owner or a site administrator can change these settings.")

  defp save_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _} -> message end)
    |> Enum.map_join(" ", fn {field, messages} ->
      "#{Phoenix.Naming.humanize(field)} #{Enum.join(messages, ", ")}."
    end)
  end

  defp save_error(_), do: gettext("Could not save library settings.")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="space-y-6">
      <.nav_tabs
        active_tab={@active_tab}
        tabs={tabs(@extensions)}
        on_change="switch_tab"
        target={@myself}
        variant={:border}
      />
      <p :if={@message} class="alert alert-success text-sm" role="status">{@message}</p>
      <p :if={@error} class="alert alert-error text-sm" role="alert">{@error}</p>
      <.form
        :if={@allowed}
        for={@form}
        id={"#{@id}-form"}
        phx-change="validate"
        phx-submit="save"
        phx-target={@myself}
        class="space-y-6"
        hidden={@active_tab not in ["general", "access"]}
      >
        <section
          aria-labelledby={"#{@id}-general"}
          class="space-y-3"
          hidden={@active_tab != "general"}
        >
          <h3 id={"#{@id}-general"} class="font-semibold">{gettext("General")}</h3>
          <.input
            field={@form[:name]}
            id={"#{@id}-name"}
            label={gettext("Library name")}
            required
            maxlength="255"
            class="w-full"
          />
          <.input
            field={@form[:slug]}
            id={"#{@id}-slug"}
            label={gettext("Address (slug)")}
            required
            maxlength="64"
            pattern="[a-z0-9]+(-[a-z0-9]+)*"
            class="w-full font-mono"
          />
          <p :if={@public_path} class="text-sm">
            <a href={@public_path} target="_blank" rel="noopener" class="link break-all">{@public_path}</a>
          </p>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Lowercase letters, numbers and hyphens. The address is separate from the library name."
            )}
          </p>
          <p :if={@form[:slug].value != @library.slug} class="alert alert-warning text-sm">
            {gettext(
              "Changing the address may affect bookmarks and connected apps. Files stay in this library."
            )}
          </p>
        </section>
        <section aria-labelledby={"#{@id}-access"} class="space-y-3" hidden={@active_tab != "access"}>
          <h3 id={"#{@id}-access"} class="font-semibold">{gettext("Access")}</h3>
          <.select
            name="library[access]"
            id={"#{@id}-access-choice"}
            value={@form[:access].value}
            label={gettext("Who can view this library?")}
            class="w-full"
            options={@access_options}
          />
          <p :if={!@publish_allowed} class="text-sm text-base-content/60">
            {gettext(
              "Publishing libraries is not enabled for your account. You can still restrict access."
            )}
          </p>
          <div class="rounded-lg bg-base-200 p-3 text-sm space-y-2" role="note">
            <p :if={@form[:access].value == "private"}>
              {gettext(
                "Only you, invited members and site administrators can browse. Previously downloaded or cached copies cannot be recalled. Storage links already issued may remain valid until they expire."
              )}
            </p>
            <p :if={@form[:access].value == "authenticated"}>
              {gettext(
                "Every active account on this site can browse; they do not need an invitation. Visitors must sign in. This includes existing photos and future uploads from connected phones."
              )}
            </p>
            <p :if={@form[:access].value == "anonymous"}>
              {gettext(
                "Anyone with the address can browse existing photos and future uploads from connected phones, without signing in. Links can be shared or indexed by search engines. Original files may contain location and other metadata."
              )}
            </p>
            <p>
              {gettext(
                "Viewing access never grants permission to upload, edit or delete. Changing access does not move files or change the WebDAV destination."
              )}
            </p>
          </div>
          <p :if={Libraries.suspended?(@library)} class="alert alert-warning text-sm">
            {gettext(
              "This library is suspended by an administrator. Changing access does not lift the suspension."
            )}
          </p>
        </section>
        <label
          :if={
            @form[:access].value != Preferences.access_mode(@library) or
              @form[:slug].value != @library.slug
          }
          class="flex items-start gap-3"
        >
          <input type="hidden" name="library[confirm]" value="false" />
          <input
            type="checkbox"
            name="library[confirm]"
            value="true"
            checked={@form[:confirm].value == "true"}
            required
            class="checkbox checkbox-sm mt-1"
          />
          <span class="text-sm">{gettext(
            "I understand and confirm the access or address change for this library and its existing files."
          )}</span>
        </label>
        <button type="submit" class="btn btn-primary btn-sm">{gettext("Save library settings")}</button>
      </.form>
      <p :if={!@allowed} class="text-sm text-base-content/60">
        {gettext("General and access settings are managed by the owner or a site administrator.")}
      </p>
      <section
        :for={extension <- @extensions}
        hidden={@active_tab != extension.id}
        aria-labelledby={"#{@id}-#{extension.id}"}
        class="space-y-3"
      >
        <h3 id={"#{@id}-#{extension.id}"} class="font-semibold">{extension.title}</h3>
        <.live_component
          module={extension.component}
          id={"#{@id}-extension-#{extension.id}"}
          library_uuid={@library_uuid}
          auth={@scope}
          notify={false}
        />
      </section>
      <section
        class="space-y-3"
        hidden={@active_tab != "members"}
        id={"#{@id}-members"}
        aria-label={gettext("Members")}
      >
        <h3 class="font-semibold">{gettext("Members")}</h3>
        <p class="text-sm text-base-content/60">
          {gettext(
            "Invited members keep their assigned roles in every access mode. Public readers do not become members."
          )}
        </p>
        <p :if={@members == []} class="text-sm">{gettext("No invited members.")}</p>
        <ul class="divide-y divide-base-300">
          <li :for={member <- @members} class="flex flex-wrap justify-between gap-2 py-2 text-sm">
            <span>{member.user.email}</span><span class="badge badge-outline">{member.role}</span>
          </li>
        </ul>
        <button
          :if={@management_target}
          type="button"
          phx-click="open_dialog"
          phx-target={@management_target}
          phx-value-kind="members"
          phx-value-uuid={@library_uuid}
          class="btn btn-outline btn-sm"
        >{gettext("Manage members")}</button>
      </section>
      <section
        class="space-y-3"
        hidden={@active_tab != "storage"}
        id={"#{@id}-storage"}
        aria-label={gettext("Storage and renditions")}
      >
        <h3 class="font-semibold">{gettext("Storage and renditions")}</h3>
        <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
          <dt>{gettext("Storage")}</dt><dd>{@profile_name}</dd>
          <dt>{gettext("Renditions")}</dt><dd>{@rendition_set && @rendition_set.name}</dd>
        </dl>
        <p class="text-xs text-base-content/60">
          {gettext(
            "Access and address changes keep all files on their current storage. Renditions control the smaller copies generated for viewing."
          )}
        </p>
        <button
          :if={@can_add_storage and @backup_management_target}
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="open_dialog"
          phx-target={@backup_management_target}
          phx-value-kind="storage"
          phx-value-uuid={@library_uuid}
        >
          {gettext("Storage and backups")}
        </button>
        <form
          :if={@allowed and length(@rendition_options) > 1}
          id={"#{@id}-renditions-form"}
          phx-submit="renditions"
          phx-target={@myself}
          class="flex flex-wrap items-end gap-2"
        >
          <.select
            name="set"
            id={"#{@id}-rendition-set"}
            label={gettext("Rendition profile")}
            value={@rendition_set && @rendition_set.uuid}
            options={Enum.map(@rendition_options, &{&1.name, &1.uuid})}
          />
          <button type="submit" class="btn btn-outline btn-sm">{gettext("Save renditions")}</button>
        </form>
      </section>
    </div>
    """
  end
end
