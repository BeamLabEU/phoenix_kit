defmodule PhoenixKitWeb.Live.Components.LibrarySettings do
  @moduledoc """
  The profile's Media tab (`/profile/settings/media`): the signed-in user's
  storage libraries (V203).

    * create one (with `storage.create_library`, up to the per-user limit)
    * rename, make the default, trash (the owner; a manager may rename)
    * members: add by email, change a role, remove (the owner or a manager)
    * leave a library someone else shared
    * pick the variant set of a library they own, among the ones an admin
      made selectable (V205): which sizes its uploads get
    * keep a new library on their own S3-compatible bucket instead of the
      site's storage (V206; `storage.own_storage`, when the site allows it):
      only there, or the site's storage plus a backup copy there. The choice is
      made here, once, and cannot be changed afterwards.

  Browsing and uploading are `/admin/libraries`. Every action goes through
  `PhoenixKit.Modules.Storage.Libraries`, which re-checks who may do it;
  what this component hides is a courtesy, not the boundary.

  Messages are shown inside the component: a LiveComponent's `put_flash`
  never reaches the page.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage.{Libraries, Library, LibraryMember, Profiles, VariantSets}
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, assigns.scope)
      |> assign(:probe, assigns[:probe])
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:open_members, fn -> nil end)
      |> assign_new(:form, fn -> new_form() end)
      |> assign_new(:testing, fn -> false end)
      |> assign_new(:creating, fn -> false end)
      |> assign_new(:pending_create, fn -> nil end)
      |> assign_new(:test_result, fn -> nil end)
      |> load()

    {:ok, socket}
  end

  defp load(socket) do
    scope = socket.assigns.scope
    entries = Libraries.list_user_libraries(Scope.user_uuid(scope))
    {owned, shared} = Enum.split_with(entries, &(&1.role == :owner))

    managed =
      Enum.filter(shared, &Libraries.allows?(&1.role, :members))

    open = socket.assigns.open_members

    socket
    |> assign(:trashed, Libraries.list_trashed_user_libraries(Scope.user_uuid(scope)))
    |> assign(:owned, owned)
    |> assign(:shared, shared)
    |> assign(:can_create, Libraries.may_create_library?(scope))
    |> assign(:can_own_storage, Libraries.may_use_own_storage?(scope))
    |> assign(:connections, connections(scope))
    |> assign(:own_storage, Profiles.user_storage_for(Enum.map(owned, & &1.library)))
    |> assign(:limit, Libraries.user_library_limit())
    |> assign(:managed_uuids, Enum.map(managed, & &1.library.uuid))
    |> assign(:variant_sets, VariantSets.list_selectable())
    |> assign(
      :members,
      if(open, do: open |> library_of(owned ++ shared) |> members(), else: [])
    )
  end

  defp library_of(uuid, entries) do
    Enum.find_value(entries, fn %{library: library} -> library.uuid == uuid && library end)
  end

  defp members(nil), do: []
  defp members(%Library{} = library), do: Libraries.list_members(library)

  defp entry(socket, uuid),
    do: Enum.find(socket.assigns.owned ++ socket.assigns.shared, &(&1.library.uuid == uuid))

  defp reply(socket, kind, text),
    do: {:noreply, socket |> assign(:message, {kind, text}) |> load()}

  @impl true
  def handle_event("form_change", %{"library" => params}, socket) do
    {:noreply, assign(socket, form: merge_form(socket, params), test_result: nil)}
  end

  def handle_event("refresh_connections", _params, socket), do: {:noreply, load(socket)}

  def handle_event("test_storage", _params, socket) do
    scope = socket.assigns.scope
    params = socket.assigns.form
    probe_opts = probe_opts(socket)

    # Through `Libraries.probe_own_storage/3`, which asks again whether this user
    # may use their own storage and validates the bucket fields as a real one
    # would be: the events of this component come from the client, and what the
    # page hides is a courtesy. Unlinked, so a stalled endpoint cannot hold the
    # page.
    {:noreply,
     socket
     |> assign(:testing, true)
     |> assign(:test_result, nil)
     |> start_async(:test_storage, fn ->
       Libraries.probe_own_storage(scope, params, probe_opts)
     end)}
  end

  def handle_event("create", %{"library" => params}, socket) do
    form = merge_form(socket, params)
    attrs = %{"name" => form["name"]}

    if form["kind"] == "own" and socket.assigns.can_own_storage do
      create_on_own_storage(socket, form, attrs)
    else
      finish_create(socket, attrs, probe_opts(socket))
    end
  end

  def handle_event("rename", %{"uuid" => uuid, "name" => name}, socket) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.rename_user_library(socket.assigns.scope, library, name) do
      reply(socket, :success, gettext("Library renamed"))
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        reply(socket, :error, changeset_message(changeset))

      _ ->
        reply(socket, :error, gettext("You may not rename this library"))
    end
  end

  def handle_event("set_variant_set", %{"uuid" => uuid, "set" => set_uuid}, socket) do
    # The owner check is made again on the row as it is now, not on the
    # list this tab loaded (it may have been trashed in another tab).
    with %{library: listed, role: :owner} <- entry(socket, uuid),
         %Library{trashed_at: nil} = library <- Libraries.get_library(listed.uuid),
         :owner <- Libraries.role(library, Scope.user_uuid(socket.assigns.scope)),
         {:ok, _} <- VariantSets.set_library_variant_set(library, set_uuid) do
      reply(
        socket,
        :success,
        gettext("Renditions changed. Existing files are updated in the background.")
      )
    else
      _ -> reply(socket, :error, gettext("You may not change this library"))
    end
  end

  def handle_event("make_default", %{"uuid" => uuid}, socket) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.set_default_library(socket.assigns.scope, library) do
      reply(socket, :success, gettext("Default library changed"))
    else
      _ -> reply(socket, :error, gettext("You may not change this library"))
    end
  end

  def handle_event("trash", %{"uuid" => uuid}, socket) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.trash_library(socket.assigns.scope, library) do
      socket =
        if socket.assigns.open_members == uuid,
          do: assign(socket, :open_members, nil),
          else: socket

      reply(socket, :success, gettext("Library moved to the trash"))
    else
      _ -> reply(socket, :error, gettext("You may not trash this library"))
    end
  end

  def handle_event("restore", %{"uuid" => uuid}, socket) do
    with %Library{} = library <- Enum.find(socket.assigns.trashed, &(&1.uuid == uuid)),
         {:ok, restored} <- Libraries.restore_library(socket.assigns.scope, library) do
      reply(socket, :success, gettext("Library “%{name}” restored", name: restored.name))
    else
      {:error, :limit_reached} ->
        reply(socket, :error, gettext("You have reached the number of libraries you may own"))

      {:error, %Ecto.Changeset{} = changeset} ->
        reply(socket, :error, changeset_message(changeset))

      _ ->
        reply(socket, :error, gettext("The library could not be restored"))
    end
  end

  def handle_event("toggle_members", %{"uuid" => uuid}, socket) do
    allowed? =
      Enum.any?(socket.assigns.owned, &(&1.library.uuid == uuid)) or
        uuid in socket.assigns.managed_uuids

    open =
      cond do
        not allowed? -> nil
        socket.assigns.open_members == uuid -> nil
        true -> uuid
      end

    {:noreply, socket |> assign(:open_members, open) |> load()}
  end

  def handle_event(
        "add_member",
        %{"uuid" => uuid, "member" => %{"email" => email, "role" => role}},
        socket
      ) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.add_member(socket.assigns.scope, library, email, role) do
      reply(socket, :success, gettext("Member added"))
    else
      {:error, :no_such_user} ->
        reply(socket, :error, gettext("No user has that email"))

      {:error, :owner} ->
        reply(socket, :error, gettext("The owner is always in the library"))

      {:error, %Ecto.Changeset{} = changeset} ->
        reply(socket, :error, changeset_message(changeset))

      _ ->
        reply(socket, :error, gettext("You may not manage this library's members"))
    end
  end

  def handle_event("member_role", %{"uuid" => uuid, "user" => user_uuid, "role" => role}, socket) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.update_member_role(socket.assigns.scope, library, user_uuid, role) do
      reply(socket, :success, gettext("Role changed"))
    else
      _ -> reply(socket, :error, gettext("You may not manage this library's members"))
    end
  end

  def handle_event("remove_member", %{"uuid" => uuid, "user" => user_uuid}, socket) do
    with %{library: library} <- entry(socket, uuid),
         :ok <- Libraries.remove_member(socket.assigns.scope, library, user_uuid) do
      reply(socket, :success, gettext("Member removed"))
    else
      _ -> reply(socket, :error, gettext("You may not manage this library's members"))
    end
  end

  def handle_event("leave", %{"uuid" => uuid}, socket) do
    with %{library: library} <- entry(socket, uuid),
         :ok <-
           Libraries.remove_member(
             socket.assigns.scope,
             library,
             Scope.user_uuid(socket.assigns.scope)
           ) do
      reply(socket, :success, gettext("You left “%{name}”", name: library.name))
    else
      _ -> reply(socket, :error, gettext("Could not leave the library"))
    end
  end

  @impl true
  def handle_async(:test_storage, {:ok, result}, socket) do
    {:noreply, assign(socket, testing: false, test_result: probe_message(result))}
  end

  def handle_async(:test_storage, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       testing: false,
       test_result: {:error, gettext("The test stopped unexpectedly")}
     )}
  end

  # The bucket was checked off the page's process; now the library is created
  # (database only) without checking it again.
  def handle_async(:probe_storage, {:ok, :ok}, socket) do
    attrs = socket.assigns.pending_create
    socket = assign(socket, creating: false, pending_create: nil)
    finish_create(socket, attrs, probe: fn _params -> :ok end)
  end

  def handle_async(:probe_storage, {:ok, result}, socket) do
    socket = assign(socket, creating: false, pending_create: nil)

    case probe_message(result) do
      {:error, message} ->
        reply(
          socket,
          :error,
          gettext("Your storage could not be used: %{reason}", reason: message)
        )
    end
  end

  def handle_async(:probe_storage, {:exit, _reason}, socket) do
    socket = assign(socket, creating: false, pending_create: nil)
    reply(socket, :error, gettext("The test stopped unexpectedly"))
  end

  # `:probe` (an assign, unset in production) replaces the bucket check, and with
  # it the wait: the library is created at once.
  defp probe_opts(socket), do: if(probe = socket.assigns[:probe], do: [probe: probe], else: [])

  defp create_on_own_storage(socket, form, attrs) do
    attrs =
      Map.put(
        attrs,
        "storage",
        Map.take(form, ~w(mode integration_uuid provider bucket_name region endpoint))
      )

    case socket.assigns[:probe] do
      nil ->
        # The network check runs off the page's process, with a pending state;
        # the library itself is created when it passes.
        scope = socket.assigns.scope

        {:noreply,
         socket
         |> assign(:creating, true)
         |> assign(:pending_create, attrs)
         |> start_async(:probe_storage, fn -> Libraries.probe_own_storage(scope, form) end)}

      probe ->
        finish_create(socket, attrs, probe: probe)
    end
  end

  defp finish_create(socket, attrs, opts) do
    case Libraries.create_user_library(socket.assigns.scope, attrs, opts) do
      {:ok, library} ->
        socket = assign(socket, form: new_form(), test_result: nil)
        reply(socket, :success, gettext("Library “%{name}” created", name: library.name))

      {:error, :limit_reached} ->
        reply(socket, :error, gettext("You have reached the number of libraries you may own"))

      {:error, :not_allowed} ->
        reply(socket, :error, gettext("You may not create libraries"))

      {:error, :no_site_storage} ->
        reply(
          socket,
          :error,
          gettext(
            "The site has no storage of its own to keep the originals on, so a backup is not possible."
          )
        )

      {:error, {:storage, message}} when is_binary(message) ->
        reply(
          socket,
          :error,
          gettext("Your storage could not be used: %{reason}", reason: message)
        )

      {:error, {:storage, %Ecto.Changeset{} = changeset}} ->
        reply(socket, :error, storage_message(changeset))

      {:error, %Ecto.Changeset{} = changeset} ->
        reply(socket, :error, changeset_message(changeset))
    end
  end

  # What the wizard shows for a `Libraries.probe_own_storage/3` result.
  defp probe_message(:ok), do: :ok

  defp probe_message({:error, :not_allowed}),
    do: {:error, gettext("You may not use your own storage")}

  defp probe_message({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, storage_message(changeset)}

  defp probe_message({:error, message}) when is_binary(message), do: {:error, message}

  @storage_fields ~w(kind mode integration_uuid provider bucket_name region endpoint)

  defp new_form,
    do: %{"name" => "", "kind" => "site", "mode" => "only", "provider" => "s3"}

  # The form as the user has it: what they typed over what was there. A newly
  # picked connection fills a blank region and endpoint from its own settings.
  defp merge_form(socket, params) do
    storage = params["storage"] || %{}
    old = socket.assigns.form

    form =
      old
      |> Map.put("name", params["name"] || old["name"] || "")
      |> Map.merge(Map.take(storage, @storage_fields))

    if form["integration_uuid"] in [nil, "", old["integration_uuid"]],
      do: form,
      else: prefill_from_connection(form, socket.assigns.connections)
  end

  defp prefill_from_connection(form, connections) do
    case Enum.find(connections, &(&1.uuid == form["integration_uuid"])) do
      nil ->
        form

      connection ->
        form
        |> put_if_blank("region", connection.region)
        |> put_if_blank("endpoint", connection.endpoint)
    end
  end

  defp put_if_blank(form, key, value) do
    if form[key] in [nil, ""] and value not in [nil, ""],
      do: Map.put(form, key, value),
      else: form
  end

  # The user's own Object Storage connections, reduced to what the form shows
  # (the list holds decrypted data; none of it is kept in assigns).
  defp connections(scope) do
    if Libraries.may_use_own_storage?(scope) do
      "object_storage"
      |> Integrations.list_connections(owner: {:user, Scope.user_uuid(scope)})
      |> Enum.map(fn %{uuid: uuid, name: name, data: data} ->
        %{uuid: uuid, name: name, region: data["region"], endpoint: data["endpoint"]}
      end)
    else
      []
    end
  end

  defp storage_message(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
        translate_error({message, opts})
      end)
      |> Enum.map_join("; ", fn {field, messages} ->
        "#{field |> to_string() |> String.replace("_", " ")} #{Enum.join(List.wrap(messages), ", ")}"
      end)

    gettext("Your storage could not be used: %{reason}", reason: details)
  end

  defp changeset_message(%Ecto.Changeset{errors: errors}) do
    case errors[:name] do
      {message, opts} -> gettext("Name %{error}", error: translate_error({message, opts}))
      nil -> gettext("The library could not be saved")
    end
  end

  # The sets offered for `library`: the selectable ones, and its own when
  # an admin has since made that one not selectable (shown, not choosable),
  # so the list says what the library uses.
  defp set_options(library, sets) do
    current = VariantSets.set_uuid_for(library)

    if Enum.any?(sets, &(to_string(&1.uuid) == current)),
      do: sets,
      else: sets ++ List.wrap(VariantSets.get_variant_set(current))
  end

  defp provider_options do
    [
      {"AWS S3", "s3"},
      {"Backblaze B2", "b2"},
      {"Cloudflare R2", "r2"},
      {"Tigris", "tigris"}
    ]
  end

  defp own_storage_label(%{mode: :only, bucket: bucket}),
    do: gettext("Your bucket: %{name}", name: bucket.bucket_name)

  defp own_storage_label(%{mode: :backup, bucket: bucket}),
    do: gettext("Backed up to: %{name}", name: bucket.bucket_name)

  defp trash_confirm(library, own_storage) do
    if Map.has_key?(own_storage, to_string(library.uuid)) do
      gettext(
        "Move “%{name}” to the trash? Its files are deleted for good after the trash period, including the copies in your own bucket, and its members lose it now.",
        name: library.name
      )
    else
      gettext(
        "Move “%{name}” to the trash? Its files are deleted for good after the trash period, and its members lose it now.",
        name: library.name
      )
    end
  end

  @doc false
  def role_label("manager"), do: gettext("Manager")
  def role_label("contributor"), do: gettext("Contributor")
  def role_label("viewer"), do: gettext("Viewer")
  def role_label(role) when is_atom(role), do: role |> to_string() |> role_label()
  def role_label(_role), do: ""

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :roles, LibraryMember.roles())

    ~H"""
    <div id={@id} class="flex flex-col gap-6">
      <div
        :if={@message}
        class={[
          "alert",
          elem(@message, 0) == :success && "alert-success",
          elem(@message, 0) == :error && "alert-error"
        ]}
      >
        {elem(@message, 1)}
      </div>

      <div class="flex items-center justify-between gap-3">
        <div>
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-rectangle-stack" class="w-5 h-5 text-primary" /> {gettext(
              "My libraries"
            )}
          </h2>
          <p class="text-sm text-base-content/60">
            {gettext(
              "Libraries keep your files apart from the site's media. Only you and the members you add can see them."
            )}
          </p>
        </div>
        <.pk_link navigate={Libraries.browse_index_path(@scope)} class="btn btn-sm btn-outline">
          {gettext("Open libraries")}
        </.pk_link>
      </div>

      <form
        :if={@can_create}
        id={"#{@id}-create"}
        phx-change="form_change"
        phx-submit="create"
        phx-target={@myself}
        class="flex flex-col gap-3"
      >
        <div class="flex flex-wrap items-end gap-2">
          <label class="form-control grow">
            <span class="label-text text-sm">{gettext("New library")}</span>
            <input
              type="text"
              name="library[name]"
              value={@form["name"]}
              required
              maxlength="255"
              placeholder={gettext("Name")}
              class="input input-sm input-bordered w-full"
            />
          </label>
          <button
            type="submit"
            class="btn btn-sm btn-primary"
            disabled={@creating}
            phx-disable-with={gettext("Creating…")}
          >
            <span :if={@creating} class="loading loading-spinner loading-xs"></span>
            {gettext("Create")}
          </button>
        </div>

        <fieldset :if={@can_own_storage} class="flex flex-col gap-2">
          <legend class="label-text text-sm">{gettext("Where its files are kept")}</legend>
          <label class="flex items-start gap-2 cursor-pointer">
            <input
              type="radio"
              name="library[storage][kind]"
              value="site"
              checked={@form["kind"] != "own"}
              class="radio radio-sm mt-0.5"
            />
            <span class="text-sm">
              {gettext("The site's storage")}
              <span class="block text-xs text-base-content/60">
                {gettext("Nothing to set up.")}
              </span>
            </span>
          </label>
          <label class="flex items-start gap-2 cursor-pointer">
            <input
              type="radio"
              name="library[storage][kind]"
              value="own"
              checked={@form["kind"] == "own"}
              class="radio radio-sm mt-0.5"
            />
            <span class="text-sm">
              {gettext("My own storage")}
              <span class="block text-xs text-base-content/60">
                {gettext(
                  "An S3-compatible bucket you own: AWS S3, Backblaze B2, Cloudflare R2 or Tigris."
                )}
              </span>
            </span>
          </label>

          <div
            :if={@form["kind"] == "own"}
            id={"#{@id}-own-storage"}
            class="rounded-lg border border-base-300 p-3 flex flex-col gap-3"
          >
            <div class="flex flex-col gap-1">
              <label class="label-text text-sm" for={"#{@id}-connection"}>
                {gettext("Connection")}
              </label>
              <div class="flex flex-wrap items-center gap-2">
                <select
                  id={"#{@id}-connection"}
                  name="library[storage][integration_uuid]"
                  class="select select-sm select-bordered grow"
                >
                  <option value="">{gettext("Select a connection...")}</option>
                  <option
                    :for={connection <- @connections}
                    value={connection.uuid}
                    selected={@form["integration_uuid"] == connection.uuid}
                  >
                    {connection.name}
                  </option>
                </select>
                <a
                  href={Routes.path("/profile/settings/integrations/new?provider=object_storage")}
                  target="_blank"
                  rel="noopener"
                  class="btn btn-sm btn-ghost"
                >
                  {gettext("Add a connection")}
                </a>
                <button
                  type="button"
                  phx-click="refresh_connections"
                  phx-target={@myself}
                  class="btn btn-sm btn-ghost"
                >
                  {gettext("Refresh")}
                </button>
              </div>
              <span class="text-xs text-base-content/60">
                {gettext("The access keys stay in your connection; the library only uses them.")}
              </span>
              <span :if={@connections == []} class="text-xs text-warning">
                {gettext("You have no Object Storage connection yet.")}
              </span>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label class="form-control">
                <span class="label-text text-sm">{gettext("Provider")}</span>
                <select name="library[storage][provider]" class="select select-sm select-bordered">
                  <option
                    :for={{label, value} <- provider_options()}
                    value={value}
                    selected={@form["provider"] == value}
                  >
                    {label}
                  </option>
                </select>
              </label>
              <label class="form-control">
                <span class="label-text text-sm">{gettext("Bucket name")}</span>
                <input
                  type="text"
                  name="library[storage][bucket_name]"
                  value={@form["bucket_name"]}
                  placeholder="my-photos"
                  class="input input-sm input-bordered"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-sm">{gettext("Region")}</span>
                <input
                  type="text"
                  name="library[storage][region]"
                  value={@form["region"]}
                  placeholder="eu-central-1"
                  class="input input-sm input-bordered"
                />
              </label>
              <label class="form-control">
                <span class="label-text text-sm">
                  {gettext("Endpoint")}
                  <span :if={@form["provider"] in ["b2", "r2", "tigris"]}>*</span>
                </span>
                <input
                  type="text"
                  name="library[storage][endpoint]"
                  value={@form["endpoint"]}
                  placeholder="https://s3.example.com"
                  class="input input-sm input-bordered"
                />
              </label>
            </div>

            <fieldset class="flex flex-col gap-2">
              <legend class="label-text text-sm">{gettext("How it is used")}</legend>
              <label class="flex items-start gap-2 cursor-pointer">
                <input
                  type="radio"
                  name="library[storage][mode]"
                  value="only"
                  checked={@form["mode"] != "backup"}
                  class="radio radio-sm mt-0.5"
                />
                <span class="text-sm">
                  {gettext("Only here")}
                  <span class="block text-xs text-base-content/60">
                    {gettext("Everything this library stores lives in your bucket.")}
                  </span>
                </span>
              </label>
              <label class="flex items-start gap-2 cursor-pointer">
                <input
                  type="radio"
                  name="library[storage][mode]"
                  value="backup"
                  checked={@form["mode"] == "backup"}
                  class="radio radio-sm mt-0.5"
                />
                <span class="text-sm">
                  {gettext("The site's storage, backed up here")}
                  <span class="block text-xs text-base-content/60">
                    {gettext(
                      "Files are kept by the site as usual, and the originals are copied to your bucket."
                    )}
                  </span>
                </span>
              </label>
            </fieldset>

            <div class="flex flex-wrap items-center gap-2">
              <button
                type="button"
                phx-click="test_storage"
                phx-target={@myself}
                disabled={@testing}
                class="btn btn-sm btn-outline"
              >
                <span :if={@testing} class="loading loading-spinner loading-xs"></span>
                {if @testing, do: gettext("Testing..."), else: gettext("Test the bucket")}
              </button>
              <span :if={@test_result == :ok} class="text-sm text-success">
                {gettext("The bucket can be read, written to and deleted from")}
              </span>
              <span :if={match?({:error, _}, @test_result)} class="text-sm text-error">
                {elem(@test_result, 1)}
              </span>
            </div>

            <p class="text-xs text-base-content/60">
              {gettext(
                "This cannot be changed once the library is created. The bucket is tested when you create the library. Deleting the library deletes the files it stored in your bucket."
              )}
            </p>
          </div>
        </fieldset>

        <span class="text-xs text-base-content/60">
          {gettext("%{count} of %{limit} libraries", count: length(@owned), limit: @limit)}
        </span>
      </form>

      <div :if={@owned == [] and @shared == []} class="text-sm text-base-content/60">
        {gettext("You have no libraries yet.")}
      </div>

      <div
        :for={%{library: library} <- @owned}
        id={"library-row-#{library.uuid}"}
        class="rounded-lg border border-base-300 p-3 flex flex-col gap-3"
      >
        <div class="flex flex-wrap items-center gap-2">
          <form
            id={"#{@id}-rename-#{library.uuid}"}
            phx-submit="rename"
            phx-target={@myself}
            class="flex items-center gap-2 grow"
          >
            <input type="hidden" name="uuid" value={library.uuid} />
            <input
              type="text"
              name="name"
              value={library.name}
              required
              maxlength="255"
              aria-label={gettext("Name")}
              class="input input-sm input-bordered grow"
            />
            <button type="submit" class="btn btn-sm btn-ghost">{gettext("Rename")}</button>
          </form>
          <span :if={library.is_default} class="badge badge-primary badge-sm">{gettext("Default")}</span>
          <span
            :if={storage = @own_storage[to_string(library.uuid)]}
            class="badge badge-outline badge-sm"
            title={gettext("Where this library keeps its files")}
          >
            {own_storage_label(storage)}
          </span>
          <form
            :if={length(set_options(library, @variant_sets)) > 1}
            id={"#{@id}-sizes-#{library.uuid}"}
            phx-change="set_variant_set"
            phx-target={@myself}
          >
            <input type="hidden" name="uuid" value={library.uuid} />
            <select
              name="set"
              class="select select-sm select-bordered"
              aria-label={gettext("Renditions")}
              title={gettext("Which renditions this library's uploads get")}
            >
              <option
                :for={set <- set_options(library, @variant_sets)}
                value={set.uuid}
                selected={VariantSets.set_uuid_for(library) == to_string(set.uuid)}
                disabled={not set.selectable and not set.is_default}
              >
                {set.name}
              </option>
            </select>
          </form>
          <button
            :if={not library.is_default}
            type="button"
            phx-click="make_default"
            phx-value-uuid={library.uuid}
            phx-target={@myself}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Make default")}
          </button>
          <.pk_link navigate={Libraries.browse_path(@scope, library)} class="btn btn-sm btn-ghost">
            <.icon name="hero-photo" class="w-4 h-4" /> {gettext("Open")}
          </.pk_link>
          <button
            type="button"
            phx-click="toggle_members"
            phx-value-uuid={library.uuid}
            phx-target={@myself}
            class="btn btn-sm btn-ghost"
          >
            <.icon name="hero-users" class="w-4 h-4" /> {gettext("Members")}
          </button>
          <button
            type="button"
            phx-click="trash"
            phx-value-uuid={library.uuid}
            phx-target={@myself}
            data-confirm={trash_confirm(library, @own_storage)}
            class="btn btn-sm btn-ghost text-error"
          >
            <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Trash")}
          </button>
        </div>
        <.members_panel
          :if={@open_members == library.uuid}
          id={@id}
          library={library}
          members={@members}
          roles={@roles}
          myself={@myself}
        />
      </div>

      <div :if={@shared != []} class="flex flex-col gap-2">
        <h3 class="font-semibold">{gettext("Shared with me")}</h3>
        <div
          :for={%{library: library, role: role} <- @shared}
          id={"library-row-#{library.uuid}"}
          class="rounded-lg border border-base-300 p-3 flex flex-col gap-3"
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-medium grow">{library.name}</span>
            <span class="badge badge-ghost badge-sm">{role_label(role)}</span>
            <.pk_link navigate={Libraries.browse_path(@scope, library)} class="btn btn-sm btn-ghost">
              <.icon name="hero-photo" class="w-4 h-4" /> {gettext("Open")}
            </.pk_link>
            <button
              :if={library.uuid in @managed_uuids}
              type="button"
              phx-click="toggle_members"
              phx-value-uuid={library.uuid}
              phx-target={@myself}
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-users" class="w-4 h-4" /> {gettext("Members")}
            </button>
            <button
              type="button"
              phx-click="leave"
              phx-value-uuid={library.uuid}
              phx-target={@myself}
              data-confirm={gettext("Leave “%{name}”?", name: library.name)}
              class="btn btn-sm btn-ghost"
            >
              {gettext("Leave")}
            </button>
          </div>
          <.members_panel
            :if={@open_members == library.uuid and library.uuid in @managed_uuids}
            id={@id}
            library={library}
            members={@members}
            roles={@roles}
            myself={@myself}
          />
        </div>
      </div>

      <div :if={@trashed != []} id={"#{@id}-trash"} class="flex flex-col gap-2">
        <h3 class="font-semibold">{gettext("Trash")}</h3>
        <p class="text-sm text-base-content/60">
          {gettext(
            "A library in the trash is deleted for good, with its files, after the trash period."
          )}
        </p>
        <div
          :for={library <- @trashed}
          id={"trashed-library-#{library.uuid}"}
          class="rounded-lg border border-base-300 p-3 flex flex-wrap items-center gap-2"
        >
          <span class="grow truncate text-base-content/70">{library.name}</span>
          <button
            type="button"
            phx-click="restore"
            phx-value-uuid={library.uuid}
            phx-target={@myself}
            class="btn btn-sm btn-ghost"
          >
            <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Restore")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :library, :map, required: true
  attr :members, :list, required: true
  attr :roles, :list, required: true
  attr :myself, :any, required: true

  defp members_panel(assigns) do
    ~H"""
    <div
      id={"#{@id}-members-#{@library.uuid}"}
      class="flex flex-col gap-2 border-t border-base-300 pt-3"
    >
      <div :if={@members == []} class="text-sm text-base-content/60">
        {gettext("No members yet: only the owner can see this library.")}
      </div>
      <div :for={member <- @members} class="flex flex-wrap items-center gap-2">
        <span class="grow truncate text-sm">{member.user.email}</span>
        <form
          id={"#{@id}-role-#{@library.uuid}-#{member.user_uuid}"}
          phx-change="member_role"
          phx-target={@myself}
        >
          <input type="hidden" name="uuid" value={@library.uuid} />
          <input type="hidden" name="user" value={member.user_uuid} />
          <select name="role" class="select select-sm" aria-label={gettext("Role")}>
            <option :for={role <- @roles} value={role} selected={role == member.role}>
              {role_label(role)}
            </option>
          </select>
        </form>
        <button
          type="button"
          phx-click="remove_member"
          phx-value-uuid={@library.uuid}
          phx-value-user={member.user_uuid}
          phx-target={@myself}
          class="btn btn-sm btn-ghost"
          aria-label={gettext("Remove")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
      <form
        id={"#{@id}-add-member-#{@library.uuid}"}
        phx-submit="add_member"
        phx-target={@myself}
        class="flex flex-wrap items-center gap-2"
      >
        <input type="hidden" name="uuid" value={@library.uuid} />
        <input
          type="email"
          name="member[email]"
          required
          placeholder={gettext("Email")}
          aria-label={gettext("Email")}
          class="input input-sm input-bordered grow"
        />
        <select name="member[role]" class="select select-sm" aria-label={gettext("Role")}>
          <option :for={role <- @roles} value={role} selected={role == "viewer"}>
            {role_label(role)}
          </option>
        </select>
        <button type="submit" class="btn btn-sm">{gettext("Add")}</button>
      </form>
    </div>
    """
  end
end
