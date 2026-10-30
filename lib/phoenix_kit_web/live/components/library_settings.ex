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
    * keep a new library on their own S3-compatible storage instead of the
      site's (V206; `storage.own_storage`, when the site allows it): pick one of
      their Object Storage integrations and a bucket on it (listed from the
      integration when its key may list buckets), only there or with the site's
      storage plus a backup copy there, and optionally copies on further
      integrations. More backup storage can be added afterwards. New rows are
      backups: existing primary storage stays, and files are copied in the
      background.

  The create form is closed until "Create library" is pressed, so the page is
  first of all the list of the user's libraries. What an integration already
  knows (its service, region, endpoint) is not asked again.

  Browsing and uploading are `/admin/libraries`. Every action goes through
  `PhoenixKit.Modules.Storage.Libraries`, which re-checks who may do it;
  what this component hides is a courtesy, not the boundary.

  Messages are shown inside the component: a LiveComponent's `put_flash`
  never reaches the page.
  """
  use PhoenixKitWeb, :live_component

  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.ObjectStorageServices
  alias PhoenixKit.Modules.Storage.{Libraries, Library, LibraryMember, Profiles, VariantSets}
  alias PhoenixKit.Modules.Storage.Reconciler
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Components.LibraryPreferences

  @impl true
  def update(%{reload_preferences: true}, socket), do: {:ok, load(socket)}
  def update(%{refresh_storage_progress: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, assigns.scope)
      |> assign(:probe, assigns[:probe])
      |> assign(:list, assigns[:list])
      |> assign(:url_path, assigns[:url_path])
      |> assign(:preferences_tab, (assigns[:url_params] || %{})["settings_tab"])
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:dialog, fn -> nil end)
      |> assign_new(:form, fn -> new_form() end)
      |> assign_new(:testing, fn -> false end)
      |> assign_new(:adding_storage, fn -> false end)
      |> assign_new(:creating, fn -> false end)
      |> assign_new(:bucket_lists, fn -> %{} end)
      |> assign_new(:test_result, fn -> nil end)
      |> load()
      |> restore_dialog(assigns[:url_params])

    {:ok, socket}
  end

  defp load(socket) do
    scope = socket.assigns.scope
    entries = Libraries.list_user_libraries(Scope.user_uuid(scope))
    {owned, shared} = Enum.split_with(entries, &(&1.role == :owner))

    managed =
      Enum.filter(shared, &Libraries.allows?(&1.role, :members))

    open = members_uuid(socket.assigns.dialog)
    connections = connections(scope)
    own_storage = Profiles.user_storage_for(Enum.map(owned, & &1.library))

    storage_library =
      case socket.assigns.dialog do
        {:storage, uuid} -> library_of(uuid, owned)
        _ -> nil
      end

    storage_profile = storage_library && Profiles.for_library(storage_library)
    storage_rows = if storage_profile, do: storage_profile.buckets, else: []
    usage = bucket_usage(connections, owned, own_storage, storage_library, storage_rows)

    socket
    |> assign(:trashed, Libraries.list_trashed_user_libraries(Scope.user_uuid(scope)))
    |> assign(:owned, owned)
    |> assign(:shared, shared)
    |> assign(:media, media_row(scope))
    |> assign(:can_create, Libraries.may_create_library?(scope))
    |> assign(:can_public, Libraries.may_create_public_library?(scope))
    |> assign(:can_own_storage, Libraries.may_use_own_storage?(scope))
    |> assign(:connections, connections)
    |> assign(:own_storage, own_storage)
    |> assign(:storage_rows, storage_rows)
    |> assign(:bucket_usage, usage)
    |> assign(
      :storage_progress,
      Reconciler.progress_by_library(Enum.map(owned, & &1.library.uuid))
    )
    |> assign(:limit, Libraries.user_library_limit())
    |> assign(:managed_uuids, Enum.map(managed, & &1.library.uuid))
    |> assign(:variant_sets, VariantSets.list_selectable())
    |> assign(
      :members,
      if(open, do: open |> library_of(owned ++ shared) |> members(), else: [])
    )
  end

  # The site's own library, Media, shown read-only beside the user's: they keep
  # files in it too, but it belongs to the site, so nothing here renames, shares
  # or trashes it. It can be opened only where there is a page for it (the media
  # browser needs the `media` permission).
  defp media_row(scope) do
    case Libraries.get_library(Libraries.media_uuid()) do
      %Library{trashed_at: nil} = library ->
        %{
          library: library,
          path: if(Scope.has_module_access?(scope, "media"), do: Routes.path("/admin/media"))
        }

      _ ->
        nil
    end
  end

  defp members_uuid({:members, uuid}), do: uuid
  defp members_uuid(_dialog), do: nil

  defp library_of(uuid, entries) do
    Enum.find_value(entries, fn %{library: library} -> library.uuid == uuid && library end)
  end

  defp members(nil), do: []
  defp members(%Library{} = library), do: Libraries.list_members(library)

  defp entry(socket, uuid),
    do: Enum.find(socket.assigns.owned ++ socket.assigns.shared, &(&1.library.uuid == uuid))

  # Who may open which dialog: the owner all of them, a manager rename and members.
  defp dialog_allowed?("settings", role), do: role in [:owner, :manager]
  defp dialog_allowed?("rename", role), do: Libraries.allows?(role, :rename)
  defp dialog_allowed?("members", role), do: Libraries.allows?(role, :members)
  defp dialog_allowed?("storage", role), do: role == :owner
  defp dialog_allowed?("sizes", role), do: role == :owner
  defp dialog_allowed?(_kind, _role), do: false

  defp reply(socket, kind, text) do
    socket = socket |> assign(:message, {kind, text}) |> load()
    socket = if is_nil(socket.assigns.dialog), do: patch_dialog(socket, nil, nil), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply,
     socket
     |> assign(dialog: :create, form: new_form(), bucket_lists: %{}, test_result: nil)
     |> assign(:message, nil)
     |> preselect_integration()}
  end

  # Rename, members and renditions are asked of one library; the check is made
  # again on the row as it is now, and again by `Libraries` when it is acted on.
  def handle_event("open_dialog", %{"kind" => kind, "uuid" => uuid}, socket) do
    with %{role: role} <- entry(socket, uuid),
         true <- dialog_allowed?(kind, role) do
      {:noreply, socket |> open_dialog(kind, uuid) |> patch_dialog(kind, uuid)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_dialog", _params, socket) do
    {:noreply,
     socket
     |> assign(dialog: nil, form: new_form(), bucket_lists: %{}, test_result: nil)
     |> load()
     |> patch_dialog(nil, nil)}
  end

  def handle_event("form_change", %{"library" => params}, socket) do
    {:noreply,
     socket
     |> merge_form(params)
     |> assign(:test_result, nil)
     |> preselect_integration()}
  end

  # The window gained focus: the user may be back from adding an integration in
  # another tab.
  def handle_event("refresh_connections", _params, socket) do
    {:noreply, socket |> load() |> preselect_integration()}
  end

  def handle_event("add_target", _params, socket) do
    form = socket.assigns.form

    if length(form["targets"]) < Profiles.max_user_buckets() do
      {:noreply, assign(socket, form: %{form | "targets" => form["targets"] ++ [blank_target()]})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_target", %{"index" => index}, socket) do
    form = socket.assigns.form
    index = to_index(index)

    if length(form["targets"]) > 1 and index in 0..(length(form["targets"]) - 1) do
      # The bucket lists are keyed by position: every one after the removed row
      # moves up with it.
      lists =
        socket.assigns.bucket_lists
        |> Map.delete(index)
        |> Map.new(fn {i, list} -> {if(i > index, do: i - 1, else: i), list} end)

      {:noreply,
       assign(socket,
         form: %{form | "targets" => List.delete_at(form["targets"], index)},
         bucket_lists: lists,
         test_result: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("list_buckets", %{"index" => index}, socket) do
    index = to_index(index)
    uuid = socket.assigns.form["targets"] |> Enum.at(index, %{}) |> Map.get("integration_uuid")

    if uuid in [nil, ""] do
      {:noreply,
       put_bucket_list(socket, index, uuid, {:error, gettext("Choose an integration first")})}
    else
      scope = socket.assigns.scope

      case socket.assigns[:list] do
        # `:list` (an assign, unset in production) replaces the network call, and
        # with it the wait.
        list when is_function(list) ->
          {:noreply,
           put_bucket_list(
             socket,
             index,
             uuid,
             list_result(Libraries.list_own_buckets(scope, uuid, list: list))
           )}

        _ ->
          # Off the page's process, and under the integration check's own
          # deadline: a stalled endpoint must not hold the page.
          {:noreply,
           socket
           |> put_bucket_list(index, uuid, :loading)
           |> start_async({:list_buckets, index}, fn ->
             {uuid, Libraries.list_own_buckets(scope, uuid)}
           end)}
      end
    end
  end

  def handle_event("type_bucket", %{"index" => index}, socket) do
    {:noreply,
     assign(socket, bucket_lists: Map.delete(socket.assigns.bucket_lists, to_index(index)))}
  end

  def handle_event("test_storage", _params, socket) do
    scope = socket.assigns.scope
    storage = storage_params(socket.assigns.form)
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
       Libraries.probe_own_storage(scope, storage, probe_opts)
     end)}
  end

  def handle_event("create", %{"library" => params}, socket) do
    socket = merge_form(socket, params)
    form = socket.assigns.form
    attrs = %{"name" => form["name"]}

    # Asked for only by someone who may; `Libraries` refuses it to anyone else.
    attrs =
      if socket.assigns.can_public and form["visibility"] == "public",
        do: Map.put(attrs, "visibility", "public"),
        else: attrs

    if form["kind"] == "own" and socket.assigns.can_own_storage do
      create_on_own_storage(socket, form, attrs)
    else
      finish_create(socket, attrs, probe_opts(socket))
    end
  end

  def handle_event("add_storage", %{"library" => params}, socket) do
    socket = merge_form(socket, params)

    with {:storage, uuid} <- socket.assigns.dialog,
         %{library: library, role: :owner} <- entry(socket, uuid),
         false <- socket.assigns.adding_storage do
      scope = socket.assigns.scope
      storage = storage_params(socket.assigns.form)
      opts = probe_opts(socket)

      if socket.assigns[:probe] do
        storage_added(socket, Libraries.add_user_storage(scope, library, storage, opts))
      else
        {:noreply,
         socket
         |> assign(:adding_storage, true)
         |> start_async(:add_storage, fn ->
           Libraries.add_user_storage(scope, library, storage)
         end)}
      end
    else
      _ -> reply(socket, :error, gettext("You may not change this library's storage"))
    end
  end

  def handle_event("refresh_storage", _params, socket), do: {:noreply, load(socket)}

  def handle_event("rename", %{"uuid" => uuid, "name" => name}, socket) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.rename_user_library(socket.assigns.scope, library, name) do
      reply(assign(socket, :dialog, nil), :success, gettext("Library renamed"))
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
        if match?({_, ^uuid}, socket.assigns.dialog),
          do: assign(socket, :dialog, nil),
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
      {:error, :storage_changed} ->
        reply(
          socket,
          :error,
          gettext("The integration changed during testing. Refresh and try again.")
        )

      {:error, :limit_reached} ->
        reply(socket, :error, gettext("You have reached the number of libraries you may own"))

      {:error, %Ecto.Changeset{} = changeset} ->
        reply(socket, :error, changeset_message(changeset))

      _ ->
        reply(socket, :error, gettext("The library could not be restored"))
    end
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

  defp open_dialog(socket, kind, uuid) do
    socket
    |> assign(
      dialog: {String.to_existing_atom(kind), uuid},
      message: nil,
      form: new_form(),
      bucket_lists: %{},
      test_result: nil
    )
    |> load()
    |> preselect_integration()
  end

  # The URL is authoritative on mount, reconnect, and browser Back/Forward.
  # Unrelated parent updates keep the in-progress form intact.
  defp restore_dialog(socket, nil), do: socket

  defp restore_dialog(socket, params) do
    state = {params["dialog"], params["library"]}

    if socket.assigns[:url_dialog] == state do
      socket
    else
      socket = assign(socket, :url_dialog, state)

      case state do
        {kind, uuid} when is_binary(kind) and is_binary(uuid) ->
          with %{role: role} <- entry(socket, uuid),
               true <- dialog_allowed?(kind, role) do
            open_dialog(socket, kind, uuid)
          else
            _ -> assign(socket, :dialog, nil)
          end

        _ ->
          assign(socket, :dialog, nil)
      end
    end
  end

  defp patch_dialog(%{assigns: %{url_path: path}} = socket, kind, uuid) when is_binary(path) do
    uri = URI.parse(path)
    params = URI.decode_query(uri.query || "") |> Map.drop(~w(library dialog))

    params =
      if kind,
        do: Map.merge(params, %{"library" => uuid, "dialog" => kind}),
        else: Map.delete(params, "settings_tab")

    query = URI.encode_query(params)

    socket
    |> assign(:url_dialog, {kind, uuid})
    |> push_patch(to: uri.path <> if(query == "", do: "", else: "?" <> query))
  end

  defp patch_dialog(socket, _kind, _uuid), do: socket

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

  def handle_async({:list_buckets, index}, {:ok, {uuid, result}}, socket) do
    {:noreply, put_bucket_list(socket, index, uuid, list_result(result))}
  end

  def handle_async({:list_buckets, index}, {:exit, _reason}, socket) do
    uuid = socket.assigns.form["targets"] |> Enum.at(index, %{}) |> Map.get("integration_uuid")

    {:noreply,
     put_bucket_list(
       socket,
       index,
       uuid,
       {:error,
        gettext("Listing the buckets stopped unexpectedly. Type the bucket name instead.")}
     )}
  end

  def handle_async(:create_library, {:ok, result}, socket) do
    create_result(assign(socket, creating: false), result)
  end

  def handle_async(:create_library, {:exit, _reason}, socket) do
    reply(
      assign(socket, creating: false),
      :error,
      gettext("The storage operation stopped unexpectedly. Refresh before trying again.")
    )
  end

  def handle_async(:add_storage, {:ok, result}, socket) do
    storage_added(assign(socket, adding_storage: false), result)
  end

  def handle_async(:add_storage, {:exit, _reason}, socket) do
    reply(
      assign(socket, adding_storage: false),
      :error,
      gettext("The storage operation stopped unexpectedly. Refresh before trying again.")
    )
  end

  defp storage_added(socket, {:ok, _library}) do
    reply(
      assign(socket, form: new_form(), bucket_lists: %{}),
      :success,
      gettext("Backup storage added. Existing files are copied and verified in the background.")
    )
  end

  defp storage_added(socket, {:error, %Ecto.Changeset{} = changeset}),
    do: reply(socket, :error, storage_message(changeset))

  defp storage_added(socket, {:error, message}) when is_binary(message),
    do: reply(socket, :error, message)

  defp storage_added(socket, {:error, :duplicate_bucket}),
    do: reply(socket, :error, gettext("This library already uses that bucket."))

  defp storage_added(socket, {:error, reason}) when reason in [:too_many_buckets, :copy_limit],
    do:
      reply(
        socket,
        :error,
        gettext(
          "This library has reached its storage copy limit. Existing storage has been kept."
        )
      )

  defp storage_added(socket, {:error, :storage_changed}),
    do:
      reply(
        socket,
        :error,
        gettext("The integration changed during testing. Refresh and try again.")
      )

  defp storage_added(socket, {:error, _}),
    do:
      reply(
        socket,
        :error,
        gettext("Storage could not be added. Check your access and the bucket connection.")
      )

  # `:probe` (an assign, unset in production) replaces the bucket check, and with
  # it the wait: the library is created at once.
  defp probe_opts(socket), do: if(probe = socket.assigns[:probe], do: [probe: probe], else: [])

  defp create_on_own_storage(socket, form, attrs) do
    storage = storage_params(form)
    attrs = Map.put(attrs, "storage", storage)

    case socket.assigns[:probe] do
      nil ->
        # The network check runs off the page's process, with a pending state;
        # the library itself is created when it passes.
        scope = socket.assigns.scope

        {:noreply,
         socket
         |> assign(:creating, true)
         |> start_async(:create_library, fn -> Libraries.create_user_library(scope, attrs) end)}

      probe ->
        finish_create(socket, attrs, probe: probe)
    end
  end

  # What `Libraries.create_user_library/3` takes under "storage": the strategy
  # and the buckets, an empty row of the form left out.
  defp storage_params(form) do
    targets =
      form["targets"]
      |> Enum.map(&Map.take(&1, ~w(integration_uuid bucket_name)))
      |> Enum.reject(&(&1["integration_uuid"] in [nil, ""] and &1["bucket_name"] in [nil, ""]))

    %{"mode" => form["mode"], "targets" => targets}
  end

  defp finish_create(socket, attrs, opts) do
    create_result(socket, Libraries.create_user_library(socket.assigns.scope, attrs, opts))
  end

  defp create_result(socket, result) do
    case result do
      {:ok, library} ->
        socket =
          assign(socket,
            form: new_form(),
            test_result: nil,
            dialog: nil,
            bucket_lists: %{}
          )

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

      {:error, :storage_changed} ->
        reply(
          socket,
          :error,
          gettext("The integration changed during testing. Refresh and try again.")
        )

      {:error, _} ->
        reply(
          socket,
          :error,
          gettext("The library could not be created. Refresh and try again.")
        )
    end
  end

  # What the wizard shows for a `Libraries.probe_own_storage/3` result.
  defp probe_message(:ok), do: :ok

  defp probe_message({:error, :not_allowed}),
    do: {:error, gettext("You may not use your own storage")}

  defp probe_message({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, storage_message(changeset)}

  defp probe_message({:error, message}) when is_binary(message), do: {:error, message}

  defp new_form,
    do: %{
      "name" => "",
      "visibility" => "private",
      "kind" => "site",
      "mode" => "only",
      "targets" => [blank_target()]
    }

  defp blank_target, do: %{"integration_uuid" => "", "bucket_name" => ""}

  defp to_index(index) when is_integer(index), do: index

  defp to_index(index) do
    case Integer.parse(to_string(index)) do
      {n, ""} when n >= 0 -> n
      _ -> -1
    end
  end

  # The form as the user has it: what they typed over what was there. The rows
  # of buckets arrive as `targets[0]`, `targets[1]`…; a row whose integration
  # changed loses its bucket (it named a bucket of the other account) and its
  # bucket list.
  defp merge_form(socket, params) do
    storage = params["storage"] || %{}
    old = socket.assigns.form

    {targets, lists} =
      case storage["targets"] do
        %{} = posted -> merge_targets(old["targets"], posted, socket.assigns.bucket_lists)
        _ -> {old["targets"], socket.assigns.bucket_lists}
      end

    form =
      old
      |> Map.put("name", params["name"] || old["name"] || "")
      |> Map.put("visibility", pick(params["visibility"], ~w(private public), old["visibility"]))
      |> Map.put("kind", pick(storage["kind"], ~w(site own), old["kind"]))
      |> Map.put("mode", pick(storage["mode"], ~w(only backup), old["mode"]))
      |> Map.put("targets", targets)

    assign(socket, form: form, bucket_lists: lists)
  end

  defp merge_targets(old_targets, posted, lists) do
    rows =
      posted
      |> Map.keys()
      |> Enum.map(&(to_index(&1) + 1))
      |> Enum.max(fn -> 0 end)
      |> max(length(old_targets))
      |> min(Profiles.max_user_buckets())

    Enum.reduce(0..(rows - 1)//1, {[], lists}, fn index, {acc, lists} ->
      old = Enum.at(old_targets, index, blank_target())
      new = Map.get(posted, to_string(index), %{})
      uuid = new["integration_uuid"] || old["integration_uuid"]
      bucket = new["bucket_name"] || old["bucket_name"] || ""

      # Switching from one integration to another: the bucket still in the form
      # named one of the other account. (A first choice, or a bucket typed in the
      # same change, is kept.)
      switched? = old["integration_uuid"] not in [nil, ""] and uuid != old["integration_uuid"]
      bucket = if switched? and bucket == old["bucket_name"], do: "", else: bucket

      {acc ++ [%{"integration_uuid" => uuid || "", "bucket_name" => bucket}],
       if(switched?, do: Map.delete(lists, index), else: lists)}
    end)
  end

  defp pick(value, allowed, default), do: if(value in allowed, do: value, else: default)

  # With exactly one integration there is nothing to choose: it is already
  # chosen for an empty first row.
  defp preselect_integration(socket) do
    case {socket.assigns.connections, socket.assigns.form["targets"]} do
      {[%{uuid: uuid}], [%{"integration_uuid" => ""} = first | rest]} ->
        form = %{
          socket.assigns.form
          | "targets" => [%{first | "integration_uuid" => uuid} | rest]
        }

        assign(socket, :form, form)

      _ ->
        socket
    end
  end

  # What the row shows for the answer of `Libraries.list_own_buckets/3`.
  defp list_result({:ok, []}) do
    {:error,
     gettext(
       "No buckets found on this integration. Create one at your provider, or type its name."
     )}
  end

  defp list_result({:ok, names}), do: {:ok, names}

  defp list_result({:error, :not_allowed}),
    do: {:error, gettext("You may not use your own storage")}

  defp list_result({:error, message}) when is_binary(message), do: {:error, message}

  # The bucket list of one row, kept with the integration it was asked of: the
  # answer of a request that was overtaken by another choice is not shown.
  defp put_bucket_list(socket, index, uuid, result) do
    assign(socket, :bucket_lists, Map.put(socket.assigns.bucket_lists, index, {uuid, result}))
  end

  defp bucket_list(lists, index, uuid) do
    case lists[index] do
      {^uuid, result} -> result
      _ -> nil
    end
  end

  # The user's own Object Storage integrations, reduced to what the form shows
  # (the list holds decrypted data; none of it is kept in assigns): the name, and
  # which service and endpoint it is, so nobody has to type those again.
  defp connections(scope) do
    if Libraries.may_use_own_storage?(scope) do
      "object_storage"
      |> Integrations.list_connections(owner: {:user, Scope.user_uuid(scope)})
      |> Enum.map(fn %{uuid: uuid, name: name, data: data} ->
        %{
          uuid: uuid,
          name: name,
          service: ObjectStorageServices.label(data),
          endpoint: data["endpoint"],
          region: data["region"],
          where: data["endpoint"] |> blank_to_nil() || data["region"] |> blank_to_nil()
        }
      end)
    else
      []
    end
  end

  # Only this account's library names are used in the picker. Connections can
  # have different keys while addressing the same physical bucket.
  defp bucket_usage(connections, owned, storage, current_library, current_rows) do
    rows =
      Enum.flat_map(owned, fn %{library: library} ->
        Enum.map(
          get_in(storage, [to_string(library.uuid), :buckets]) || [],
          &{library, &1.bucket}
        )
      end)

    rows =
      rows ++
        if(current_library, do: Enum.map(current_rows, &{current_library, &1.bucket}), else: [])

    Map.new(connections, fn connection ->
      usage =
        rows
        |> Enum.filter(fn {_library, bucket} ->
          bucket.integration_uuid == connection.uuid or
            Libraries.same_storage_destination?(bucket, %{
              endpoint: connection.endpoint,
              bucket_name: bucket.bucket_name
            })
        end)
        |> Enum.group_by(fn {_library, bucket} -> bucket.bucket_name end, fn {library, _bucket} ->
          %{uuid: library.uuid, name: library.name}
        end)
        |> Map.new(fn {name, libraries} -> {name, Enum.uniq_by(libraries, & &1.uuid)} end)

      {connection.uuid, usage}
    end)
  end

  defp storage_connection(connections, bucket) do
    Enum.find(connections, &(&1.uuid == bucket.integration_uuid))
  end

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  # "Tigris · t3.storage.dev": what the picked integration is, under its select.
  defp integration_line(connections, uuid) do
    case Enum.find(connections, &(&1.uuid == uuid)) do
      nil -> nil
      c -> Enum.join(Enum.reject([c.service, c.where], &is_nil/1), " · ")
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

  defp site_storage_label do
    gettext("%{project}'s storage", project: PhoenixKit.Settings.get_project_title())
  end

  defp own_storage_label(%{role: "primary", bucket: bucket}),
    do: gettext("Your bucket: %{name}", name: bucket.bucket_name)

  defp own_storage_label(%{bucket: bucket}),
    do: gettext("Backed up to: %{names}", names: bucket.bucket_name)

  defp bucket_integration_label(connections, bucket) do
    case storage_connection(connections, bucket) do
      nil -> bucket.provider
      connection -> Enum.join([connection.name, connection.service], " · ")
    end
  end

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
  def role_label("owner"), do: gettext("Owner")
  def role_label("manager"), do: gettext("Manager")
  def role_label("contributor"), do: gettext("Contributor")
  def role_label("viewer"), do: gettext("Viewer")
  def role_label(role) when is_atom(role), do: role |> to_string() |> role_label()
  def role_label(_role), do: ""

  # The library a rename / members / renditions dialog is about, as the lists
  # hold it now.
  defp dialog_library(%{dialog: {_kind, uuid}} = assigns) do
    Enum.find_value(assigns.owned ++ assigns.shared, fn %{library: library} ->
      library.uuid == uuid && library
    end)
  end

  defp dialog_library(_assigns), do: nil

  # Where a row opens its library. `Libraries.browse_path/2` is the path inside
  # the app; the link components used in a table take it as it is, so the
  # install's URL prefix is added here (`pk_link` used to).
  defp open_href(scope, library), do: Routes.path(Libraries.browse_path(scope, library))

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:roles, LibraryMember.roles())
      |> assign(:dialog_library, dialog_library(assigns))

    ~H"""
    <div id={@id} class="flex flex-col gap-6">
      <div
        :if={@message && not match?({:storage, _}, @dialog)}
        class={[
          "alert text-sm",
          elem(@message, 0) == :success && "alert-success",
          elem(@message, 0) == :error && "alert-error"
        ]}
      >
        {elem(@message, 1)}
      </div>

      <div :if={@owned != [] or @shared != [] or @media}>
        <.table_default id={"#{@id}-table"}>
          <:toolbar_title>
            <div>
              <h2 class="text-lg font-semibold flex items-center gap-2">
                <.icon name="hero-rectangle-stack" class="w-5 h-5 text-primary" />
                {gettext("My libraries")}
              </h2>
              <p class="text-sm text-base-content/60">
                {gettext("%{count} of %{limit} libraries", count: length(@owned), limit: @limit)}
              </p>
            </div>
          </:toolbar_title>
          <:toolbar_primary>
            <button
              :if={@can_create}
              id={"#{@id}-open-create"}
              type="button"
              phx-click="open_create"
              phx-target={@myself}
              disabled={length(@owned) >= @limit}
              title={
                if length(@owned) >= @limit,
                  do:
                    gettext("You have reached the number of libraries you may own (%{limit}).",
                      limit: @limit
                    )
              }
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Create library")}
            </button>
          </:toolbar_primary>

          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Stored in")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Visibility")}</.table_default_header_cell>
              <.table_default_header_cell>{gettext("Actions")}</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>

          <.table_default_body>
            <.table_default_row
              :for={%{library: library} <- @owned}
              id={"library-row-#{library.uuid}"}
              class="relative transform-gpu cursor-pointer"
            >
              <.table_default_cell>
                <.row_link navigate={open_href(@scope, library)} label={library.name} />
                <div class="flex items-center gap-2">
                  <.icon name="hero-rectangle-stack" class="w-4 h-4 text-base-content/60" />
                  <span class="font-medium">{library.name}</span>
                  <span :if={library.is_default} class="badge badge-primary badge-sm">
                    {gettext("Default")}
                  </span>
                </div>
                <.link
                  href={LibraryPreferences.library_url(library, @scope)}
                  class="relative z-10 mt-1 block max-w-sm break-all text-xs text-base-content/60 hover:underline"
                >{LibraryPreferences.library_url(library, @scope)}</.link>
              </.table_default_cell>
              <.table_default_cell>
                <div
                  :if={storage = @own_storage[to_string(library.uuid)]}
                  class="flex flex-col gap-2"
                >
                  <div :for={target <- storage.buckets} class="text-sm">
                    <div class="flex items-start gap-1.5">
                      <.icon
                        name={
                          if target.role == "primary",
                            do: "hero-circle-stack",
                            else: "hero-shield-check"
                        }
                        class="size-3.5 shrink-0 mt-0.5 text-base-content/60"
                      />
                      <span class="break-all">{own_storage_label(target)}</span>
                    </div>
                    <div class="flex items-start gap-1.5 text-xs text-base-content/60 mt-0.5">
                      <.icon name="hero-cloud" class="size-3 shrink-0 mt-0.5" />
                      <span class="break-all">{bucket_integration_label(@connections, target.bucket)}</span>
                    </div>
                  </div>
                </div>
                <span
                  :if={!@own_storage[to_string(library.uuid)]}
                  class="inline-flex items-center gap-1.5 text-sm text-base-content/60"
                >
                  <.icon name="hero-server-stack" class="size-3.5 shrink-0" />
                  {site_storage_label()}
                </span>
                <div :if={progress = @storage_progress[to_string(library.uuid)]} class="mt-2 max-w-xs">
                  <button
                    :if={progress.pending > 0 and @own_storage[to_string(library.uuid)]}
                    type="button"
                    phx-click="open_dialog"
                    phx-target={@myself}
                    phx-value-kind="storage"
                    phx-value-uuid={library.uuid}
                    class="relative z-10 flex items-center gap-2 text-xs text-primary hover:underline"
                  >
                    <.icon name="hero-arrow-path" class="size-3" />
                    {gettext("%{done} of %{total} files up to date",
                      done: progress.completed,
                      total: progress.total
                    )}
                  </button>
                  <progress
                    :if={progress.pending > 0}
                    class="progress progress-primary mt-1 h-1 w-full"
                    value={progress.completed}
                    max={max(progress.total, 1)}
                    aria-label={gettext("Library storage progress")}
                  ></progress>
                </div>
              </.table_default_cell>
              <.table_default_cell>
                <.visibility_badge library={library} />
              </.table_default_cell>
              <.table_default_cell class="relative z-10">
                <.table_row_menu id={"library-menu-#{library.uuid}"} label={gettext("Actions")}>
                  <.table_row_menu_link
                    navigate={open_href(@scope, library)}
                    icon="hero-photo"
                    label={gettext("Open")}
                  />
                  <.table_row_menu_button
                    phx-click="open_dialog"
                    phx-target={@myself}
                    phx-value-kind="settings"
                    phx-value-uuid={library.uuid}
                    icon="hero-cog-6-tooth"
                    label={gettext("Settings")}
                  />
                  <.table_row_menu_button
                    phx-click="open_dialog"
                    phx-target={@myself}
                    phx-value-kind="rename"
                    phx-value-uuid={library.uuid}
                    icon="hero-pencil"
                    label={gettext("Rename")}
                  />
                  <.table_row_menu_button
                    :if={not library.is_default}
                    phx-click="make_default"
                    phx-target={@myself}
                    phx-value-uuid={library.uuid}
                    icon="hero-star"
                    label={gettext("Make default")}
                  />
                  <.table_row_menu_button
                    phx-click="open_dialog"
                    phx-target={@myself}
                    phx-value-kind="members"
                    phx-value-uuid={library.uuid}
                    icon="hero-users"
                    label={gettext("Members")}
                  />
                  <.table_row_menu_button
                    :if={length(set_options(library, @variant_sets)) > 1}
                    phx-click="open_dialog"
                    phx-target={@myself}
                    phx-value-kind="sizes"
                    phx-value-uuid={library.uuid}
                    icon="hero-adjustments-horizontal"
                    label={gettext("Renditions")}
                  />
                  <.table_row_menu_button
                    :if={@can_own_storage and @own_storage[to_string(library.uuid)]}
                    phx-click="open_dialog"
                    phx-target={@myself}
                    phx-value-kind="storage"
                    phx-value-uuid={library.uuid}
                    icon="hero-cloud-arrow-up"
                    label={gettext("Storage and backups")}
                  />
                  <.table_row_menu_divider />
                  <.table_row_menu_button
                    phx-click="trash"
                    phx-target={@myself}
                    phx-value-uuid={library.uuid}
                    data-confirm={trash_confirm(library, @own_storage)}
                    icon="hero-trash"
                    label={gettext("Trash")}
                    variant="error"
                  />
                </.table_row_menu>
              </.table_default_cell>
            </.table_default_row>

            <.table_default_row
              :for={%{library: library, role: role} <- @shared}
              id={"library-row-#{library.uuid}"}
              class="relative transform-gpu cursor-pointer"
            >
              <.table_default_cell>
                <.row_link navigate={open_href(@scope, library)} label={library.name} />
                <div class="flex items-center gap-2">
                  <.icon name="hero-users" class="w-4 h-4 text-base-content/60" />
                  <span class="font-medium">{library.name}</span>
                  <span class="badge badge-ghost badge-sm">{role_label(role)}</span>
                </div>
                <.link
                  href={LibraryPreferences.library_url(library, @scope)}
                  class="relative z-10 mt-1 block max-w-sm break-all text-xs text-base-content/60 hover:underline"
                >{LibraryPreferences.library_url(library, @scope)}</.link>
              </.table_default_cell>
              <.table_default_cell>
                <span class="text-sm text-base-content/60">{gettext("Shared with me")}</span>
              </.table_default_cell>
              <.table_default_cell>
                <.visibility_badge library={library} />
              </.table_default_cell>
              <.table_default_cell class="relative z-10">
                <.table_row_menu id={"library-menu-#{library.uuid}"} label={gettext("Actions")}>
                  <.table_row_menu_link
                    navigate={open_href(@scope, library)}
                    icon="hero-photo"
                    label={gettext("Open")}
                  />
                  <.table_row_menu_button
                    :if={library.uuid in @managed_uuids}
                    phx-click="open_dialog"
                    phx-target={@myself}
                    phx-value-kind="settings"
                    phx-value-uuid={library.uuid}
                    icon="hero-cog-6-tooth"
                    label={gettext("Settings")}
                  />
                  <.table_row_menu_button
                    :if={library.uuid in @managed_uuids}
                    phx-click="open_dialog"
                    phx-target={@myself}
                    phx-value-kind="members"
                    phx-value-uuid={library.uuid}
                    icon="hero-users"
                    label={gettext("Members")}
                  />
                  <.table_row_menu_divider />
                  <.table_row_menu_button
                    phx-click="leave"
                    phx-target={@myself}
                    phx-value-uuid={library.uuid}
                    data-confirm={gettext("Leave “%{name}”?", name: library.name)}
                    icon="hero-arrow-right-on-rectangle"
                    label={gettext("Leave")}
                    variant="error"
                  />
                </.table_row_menu>
              </.table_default_cell>
            </.table_default_row>
            <.table_default_row
              :if={@media}
              id={"library-row-#{@media.library.uuid}"}
              class="relative transform-gpu"
            >
              <.table_default_cell>
                <.row_link
                  :if={@media.path}
                  navigate={@media.path}
                  label={@media.library.name}
                />
                <div class="flex items-center gap-2">
                  <.icon name="hero-globe-alt" class="w-4 h-4 text-base-content/60" />
                  <span class="font-medium">{@media.library.name}</span>
                  <span
                    class="badge badge-ghost badge-sm"
                    title={gettext("The site's own library, managed by the site's administrators")}
                  >
                    {gettext("System")}
                  </span>
                </div>
              </.table_default_cell>
              <.table_default_cell>
                <span class="text-sm text-base-content/60">{site_storage_label()}</span>
              </.table_default_cell>
              <.table_default_cell>
                <.visibility_badge library={@media.library} />
              </.table_default_cell>
              <.table_default_cell class="relative z-10">
                <.table_row_menu
                  :if={@media.path}
                  id={"library-menu-#{@media.library.uuid}"}
                  label={gettext("Actions")}
                >
                  <.table_row_menu_link
                    navigate={@media.path}
                    icon="hero-photo"
                    label={gettext("Open")}
                  />
                </.table_row_menu>
              </.table_default_cell>
            </.table_default_row>
          </.table_default_body>
        </.table_default>

        <p
          :if={@owned == [] and @shared == []}
          class="mt-3 text-sm text-base-content/60"
        >
          {gettext(
            "You have no libraries of your own yet. Create one to keep your files apart from the site's media."
          )}
        </p>
      </div>

      <div :if={@trashed != []} id={"#{@id}-trash"} class="flex flex-col gap-2">
        <.section_header icon="hero-trash" title={gettext("Trash")} />
        <p class="text-sm text-base-content/60">
          {gettext(
            "A library in the trash is deleted for good, with its files, after the trash period."
          )}
        </p>
        <.table_default id={"#{@id}-trash-table"} size="sm">
          <.table_default_body>
            <.table_default_row :for={library <- @trashed} id={"trashed-library-#{library.uuid}"}>
              <.table_default_cell class="text-base-content/70">{library.name}</.table_default_cell>
              <.table_default_cell class="text-right">
                <button
                  type="button"
                  phx-click="restore"
                  phx-value-uuid={library.uuid}
                  phx-target={@myself}
                  class="btn btn-ghost btn-xs"
                >
                  <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> {gettext("Restore")}
                </button>
              </.table_default_cell>
            </.table_default_row>
          </.table_default_body>
        </.table_default>
      </div>

      <.modal
        :if={match?({:settings, _}, @dialog) and @dialog_library}
        id={"#{@id}-preferences"}
        show
        on_close="close_dialog"
        phx-target={@myself}
        max_width="3xl"
      >
        <:title>{gettext("Library settings")} · {@dialog_library.name}</:title>
        <.live_component
          module={PhoenixKitWeb.Live.Components.LibraryPreferences}
          id={"#{@id}-preferences-#{@dialog_library.uuid}"}
          library_uuid={@dialog_library.uuid}
          scope={@scope}
          management_target={@myself}
          backup_management_target={@myself}
          notify={%{module: __MODULE__, id: @id}}
          url_path={@url_path}
          selected_tab={@preferences_tab}
        />
        <:actions>
          <button type="button" class="btn btn-ghost" phx-click="close_dialog" phx-target={@myself}>{gettext(
            "Close"
          )}</button>
        </:actions>
      </.modal>

      <.modal
        :if={match?({:storage, _}, @dialog) and @dialog_library}
        show
        id={"#{@id}-storage-modal"}
        phx-target={@myself}
        on_close="close_dialog"
        max_width="2xl"
      >
        <:title>{gettext("Storage and backups")} · {@dialog_library.name}</:title>
        <div class="space-y-4">
          <p>
            {gettext(
              "Add another integration as backup storage. Your current storage stays in place. Existing files, including renditions, are copied and verified in the background."
            )}
          </p>
          <.storage_work
            progress={@storage_progress[to_string(@dialog_library.uuid)]}
            id={"#{@id}-storage-progress"}
          />
          <div class="space-y-3" aria-label={gettext("Connected storage")}>
            <article
              :for={row <- @storage_rows}
              id={"#{@id}-storage-bucket-#{row.bucket.uuid}"}
              class="rounded-2xl border border-base-300 bg-gradient-to-br from-base-200 to-base-100 p-4 sm:p-5"
            >
              <% connection = storage_connection(@connections, row.bucket) %>
              <div class="flex items-start gap-3">
                <div class="flex size-12 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary">
                  <.icon name="hero-cloud" class="size-7" />
                </div>
                <div class="min-w-0 flex-1">
                  <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">
                    {gettext("Integration")}
                  </p>
                  <p class="break-words text-base font-semibold">
                    {if connection,
                      do: connection.name,
                      else:
                        if(row.bucket.owner_uuid,
                          do: gettext("Integration unavailable"),
                          else: gettext("Site storage")
                        )}
                  </p>
                  <p class="break-all text-xs text-base-content/60">
                    {if connection,
                      do: integration_line(@connections, connection.uuid),
                      else: row.bucket.provider}
                  </p>
                </div>
                <span class={[
                  "badge badge-sm shrink-0",
                  if(row.role == "primary", do: "badge-primary", else: "badge-outline")
                ]}>
                  {if row.role == "primary", do: gettext("Primary"), else: gettext("Backup")}
                </span>
              </div>
              <div class="mt-4 flex items-center gap-3 rounded-xl border border-base-300/60 bg-base-100/80 px-3 py-3">
                <.icon name="hero-circle-stack" class="size-5 shrink-0 text-primary" />
                <div class="min-w-0">
                  <p class="text-xs text-base-content/50">{gettext("Bucket")}</p>
                  <p class="break-all font-mono text-sm font-medium">
                    {row.bucket.bucket_name || row.bucket.name}
                  </p>
                </div>
                <.icon name="hero-link" class="ml-auto size-5 shrink-0 text-base-content/40" />
              </div>
              <% counts =
                get_in(@storage_progress, [
                  to_string(@dialog_library.uuid),
                  :buckets,
                  to_string(row.bucket.uuid)
                ]) || %{stored: 0, bytes: 0, unavailable: 0, verified: 0, syncing: 0} %>
              <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/60">
                <span>{gettext("%{count} stored copies", count: counts.stored)}</span>
                <span>{PhoenixKit.Utils.Format.bytes(counts.bytes || 0)}</span>
                <span>{gettext("%{count} verified", count: counts.verified)}</span>
                <span :if={counts.syncing > 0} class="text-primary">{gettext("%{count} copying",
                  count: counts.syncing
                )}</span>
                <span :if={counts.unavailable > 0} class="text-warning">{gettext(
                  "%{count} unavailable",
                  count: counts.unavailable
                )}</span>
              </div>
            </article>
          </div>
          <button
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="refresh_storage"
            phx-target={@myself}
          >{gettext("Refresh status")}</button>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Buckets already connected to this library are hidden. Buckets used by your other libraries are labelled; each library keeps its files separate."
            )}
          </p>
          <form
            id={"#{@id}-add-storage"}
            phx-change="form_change"
            phx-submit="add_storage"
            phx-target={@myself}
          >
            <.target_row
              :for={{target, index} <- Enum.with_index(@form["targets"])}
              id={"#{@id}-backup"}
              index={index}
              count={length(@form["targets"])}
              target={target}
              connections={@connections}
              usage={@bucket_usage[target["integration_uuid"]] || %{}}
              library_uuid={@dialog_library.uuid}
              list={bucket_list(@bucket_lists, index, target["integration_uuid"])}
              myself={@myself}
            />
            <div
              :if={@message}
              id={"#{@id}-storage-message"}
              role="alert"
              aria-live="assertive"
              class={[
                "alert text-sm break-words",
                elem(@message, 0) == :error && "alert-error",
                elem(@message, 0) == :success && "alert-success"
              ]}
            >
              <.icon
                name={
                  if elem(@message, 0) == :success,
                    do: "hero-check-circle",
                    else: "hero-exclamation-circle"
                }
                class="size-5 shrink-0"
              />
              <span>{elem(@message, 1)}</span>
            </div>
            <a
              href={Routes.path("/profile/settings/integrations/new?provider=object_storage")}
              target="_blank"
              rel="noopener"
              class="btn btn-sm btn-ghost"
            >{gettext("Add an integration")}</a>
            <button
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="refresh_connections"
              phx-target={@myself}
            >{gettext("Refresh integrations")}</button>
            <button
              type="submit"
              class="btn btn-primary"
              disabled={@adding_storage or @connections == []}
              phx-disable-with={gettext("Testing and adding...")}
            >{gettext("Add backup storage")}</button>
          </form>
        </div>
        <:actions>
          <button type="button" class="btn btn-ghost" phx-click="close_dialog" phx-target={@myself}>{gettext(
            "Close"
          )}</button>
        </:actions>
      </.modal>

      <.create_dialog :if={@dialog == :create} {assigns} />

      <.modal
        :if={match?({:rename, _}, @dialog) and @dialog_library}
        show
        on_close="close_dialog"
        id={"#{@id}-rename-modal"}
        max_width="md"
      >
        <:title>
          <.icon name="hero-pencil" class="w-5 h-5 text-primary" /> {gettext("Rename library")}
        </:title>
        <form
          id={"#{@id}-rename-#{@dialog_library.uuid}"}
          phx-submit="rename"
          phx-target={@myself}
        >
          <input type="hidden" name="uuid" value={@dialog_library.uuid} />
          <.input
            type="text"
            name="name"
            id={"#{@id}-rename-name"}
            value={@dialog_library.name}
            label={gettext("Name")}
            required
            maxlength="255"
            autocomplete="off"
          />
        </form>
        <:actions>
          <button type="button" class="btn btn-ghost" phx-click="close_dialog" phx-target={@myself}>
            {gettext("Cancel")}
          </button>
          <button
            type="submit"
            form={"#{@id}-rename-#{@dialog_library.uuid}"}
            class="btn btn-primary"
            phx-disable-with={gettext("Saving…")}
          >
            {gettext("Rename")}
          </button>
        </:actions>
      </.modal>

      <.modal
        :if={match?({:sizes, _}, @dialog) and @dialog_library}
        show
        on_close="close_dialog"
        id={"#{@id}-sizes-modal"}
        max_width="md"
      >
        <:title>
          <.icon name="hero-adjustments-horizontal" class="w-5 h-5 text-primary" />
          {gettext("Renditions")}
        </:title>
        <form
          id={"#{@id}-sizes-#{@dialog_library.uuid}"}
          phx-change="set_variant_set"
          phx-target={@myself}
          class="flex flex-col gap-2"
        >
          <input type="hidden" name="uuid" value={@dialog_library.uuid} />
          <.select
            id={"#{@id}-sizes-set"}
            name="set"
            label={@dialog_library.name}
            value={VariantSets.set_uuid_for(@dialog_library)}
            options={
              for set <- set_options(@dialog_library, @variant_sets),
                  do: {set.name, set.uuid}
            }
          />
          <p class="text-sm text-base-content/60">
            {gettext(
              "Which sizes this library's uploads get. Existing files are updated in the background."
            )}
          </p>
        </form>
        <:actions>
          <button type="button" class="btn btn-primary" phx-click="close_dialog" phx-target={@myself}>
            {gettext("Done")}
          </button>
        </:actions>
      </.modal>

      <.modal
        :if={match?({:members, _}, @dialog) and @dialog_library}
        show
        on_close="close_dialog"
        id={"#{@id}-members-modal"}
        max_width="lg"
      >
        <:title>
          <.icon name="hero-users" class="w-5 h-5 text-primary" />
          {gettext("Members of “%{name}”", name: @dialog_library.name)}
        </:title>
        <.members_panel
          id={@id}
          library={@dialog_library}
          members={@members}
          roles={@roles}
          myself={@myself}
        />
        <:actions>
          <button type="button" class="btn btn-primary" phx-click="close_dialog" phx-target={@myself}>
            {gettext("Done")}
          </button>
        </:actions>
      </.modal>
    </div>
    """
  end

  attr :library, :map, required: true

  # Who a library's files are open to, from its `visibility`: a `site` library
  # (Media) is served like the site's media, with ordinary links; a `private` one
  # only to its owner and members, through links that expire.
  defp visibility_badge(%{library: %{settings: %{"suspended" => true}}} = assigns) do
    ~H"""
    <span
      class="badge badge-warning badge-soft badge-sm gap-1"
      title={
        gettext(
          "The site's administrators have taken this library offline. Only you and its members can open it."
        )
      }
    >
      <.icon name="hero-no-symbol" class="w-3 h-3" /> {gettext("Suspended")}
    </span>
    """
  end

  defp visibility_badge(
         %{library: %{visibility: "site", settings: %{"public_audience" => "authenticated"}}} =
           assigns
       ) do
    ~H"""
    <span class="badge badge-info badge-sm">{gettext("Signed-in users")}</span>
    """
  end

  defp visibility_badge(%{library: %{visibility: "private"}} = assigns) do
    ~H"""
    <span
      class="badge badge-ghost badge-sm gap-1"
      title={gettext("Only you and the members you add can open the files; their links expire.")}
    >
      <.icon name="hero-lock-closed" class="w-3 h-3" /> {gettext("Private")}
    </span>
    """
  end

  defp visibility_badge(assigns) do
    ~H"""
    <span
      class="badge badge-info badge-soft badge-sm gap-1"
      title={gettext("Served like the site's media, with ordinary links.")}
    >
      <.icon name="hero-globe-alt" class="w-3 h-3" /> {gettext("Public")}
    </span>
    """
  end

  # The create form, in a dialog: a name, where the files are kept and, for
  # their own storage, which integration and bucket.
  defp create_dialog(assigns) do
    ~H"""
    <.modal show on_close="close_dialog" id={"#{@id}-create-modal"} max_width="2xl">
      <:title>
        <.icon name="hero-plus" class="w-5 h-5 text-primary" /> {gettext("New library")}
      </:title>

      <form
        id={"#{@id}-create"}
        phx-change="form_change"
        phx-submit="create"
        phx-target={@myself}
        class="flex flex-col gap-5"
      >
        <.input
          type="text"
          name="library[name]"
          id={"#{@id}-name"}
          value={@form["name"]}
          label={gettext("Name")}
          required
          maxlength="255"
          autofocus
          autocomplete="off"
          placeholder={gettext("Family photos")}
        />

        <fieldset :if={@can_public} class="flex flex-col gap-2">
          <legend class="font-semibold mb-1">{gettext("Who can see it")}</legend>
          <label class={[
            "flex items-start gap-3 rounded-lg border p-3 cursor-pointer",
            (@form["visibility"] != "public" && "border-primary bg-primary/5") || "border-base-300"
          ]}>
            <input
              type="radio"
              name="library[visibility]"
              value="private"
              checked={@form["visibility"] != "public"}
              class="radio radio-sm radio-primary mt-0.5"
            />
            <span class="text-sm">
              <.icon name="hero-lock-closed" class="w-4 h-4 inline" /> {gettext("Private")}
              <span class="block text-xs text-base-content/60">
                {gettext("Only you and the members you add.")}
              </span>
            </span>
          </label>
          <label class={[
            "flex items-start gap-3 rounded-lg border p-3 cursor-pointer",
            (@form["visibility"] == "public" && "border-primary bg-primary/5") || "border-base-300"
          ]}>
            <input
              type="radio"
              name="library[visibility]"
              value="public"
              checked={@form["visibility"] == "public"}
              class="radio radio-sm radio-primary mt-0.5"
            />
            <span class="text-sm">
              <.icon name="hero-globe-alt" class="w-4 h-4 inline" /> {gettext("Public")}
              <span class="block text-xs text-base-content/60">
                {gettext("Anyone in the world can browse everything in it, without signing in.")}
              </span>
            </span>
          </label>
          <p :if={@form["visibility"] == "public"} class="text-xs text-warning">
            {gettext(
              "Whatever you add to a public library is public at once. This cannot be changed once the library is created."
            )}
          </p>
        </fieldset>

        <fieldset :if={@can_own_storage} class="flex flex-col gap-2">
          <legend class="font-semibold mb-1">{gettext("Where its files are kept")}</legend>
          <label class={[
            "flex items-start gap-3 rounded-lg border p-3 cursor-pointer",
            (@form["kind"] != "own" && "border-primary bg-primary/5") || "border-base-300"
          ]}>
            <input
              type="radio"
              name="library[storage][kind]"
              value="site"
              checked={@form["kind"] != "own"}
              class="radio radio-sm radio-primary mt-0.5"
            />
            <span class="text-sm">
              {site_storage_label()}
              <span class="block text-xs text-base-content/60">
                {gettext("Nothing to set up.")}
              </span>
            </span>
          </label>
          <label class={[
            "flex items-start gap-3 rounded-lg border p-3 cursor-pointer",
            (@form["kind"] == "own" && "border-primary bg-primary/5") || "border-base-300"
          ]}>
            <input
              type="radio"
              name="library[storage][kind]"
              value="own"
              checked={@form["kind"] == "own"}
              class="radio radio-sm radio-primary mt-0.5"
            />
            <span class="text-sm">
              {gettext("My own storage")}
              <span class="block text-xs text-base-content/60">
                {gettext(
                  "A bucket of yours on AWS S3, Cloudflare R2, Backblaze B2, Tigris or another S3-compatible service, through one of your integrations."
                )}
              </span>
            </span>
          </label>
        </fieldset>

        <div
          :if={@can_own_storage and @form["kind"] == "own"}
          id={"#{@id}-own-storage"}
          phx-window-focus="refresh_connections"
          phx-target={@myself}
          class="flex flex-col gap-4"
        >
          <div :if={@connections == []} class="rounded-lg bg-info/10 p-4 flex flex-col gap-2">
            <p class="text-sm font-medium">{gettext("Connect your storage first")}</p>
            <p class="text-sm text-base-content/70">
              {gettext(
                "Add your S3-compatible storage as an integration. You do it once: the access keys stay in the integration, and every library can use it."
              )}
            </p>
            <div class="flex flex-wrap items-center gap-3">
              <a
                href={Routes.path("/profile/settings/integrations/new?provider=object_storage")}
                target="_blank"
                rel="noopener"
                class="btn btn-sm btn-primary"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add an integration")}
              </a>
              <span class="text-xs text-base-content/60">
                {gettext("It opens in a new tab. Come back here and it will be in the list.")}
              </span>
            </div>
          </div>

          <div :if={@connections != []} class="flex flex-col gap-3">
            <.target_row
              :for={{target, index} <- Enum.with_index(@form["targets"])}
              id={@id}
              index={index}
              count={length(@form["targets"])}
              target={target}
              connections={@connections}
              usage={@bucket_usage[target["integration_uuid"]] || %{}}
              list={bucket_list(@bucket_lists, index, target["integration_uuid"])}
              myself={@myself}
            />

            <div class="flex flex-wrap items-center gap-2">
              <button
                :if={length(@form["targets"]) < Profiles.max_user_buckets()}
                type="button"
                phx-click="add_target"
                phx-target={@myself}
                class="btn btn-sm btn-ghost"
              >
                <.icon name="hero-plus" class="w-4 h-4" />
                {gettext("Also keep a copy on another integration")}
              </button>
              <a
                href={Routes.path("/profile/settings/integrations/new?provider=object_storage")}
                target="_blank"
                rel="noopener"
                class="btn btn-sm btn-ghost"
              >
                {gettext("Add an integration")}
              </a>
            </div>
          </div>

          <fieldset :if={@connections != []} class="flex flex-col gap-2">
            <legend class="font-semibold mb-1">{gettext("How it is used")}</legend>
            <label class="flex items-start gap-3 cursor-pointer">
              <input
                type="radio"
                name="library[storage][mode]"
                value="only"
                checked={@form["mode"] != "backup"}
                class="radio radio-sm radio-primary mt-0.5"
              />
              <span class="text-sm">
                {gettext("Only here")}
                <span class="block text-xs text-base-content/60">
                  <%= if length(@form["targets"]) > 1 do %>
                    {gettext(
                      "Everything lives on the main integration, and the others keep a copy of every file."
                    )}
                  <% else %>
                    {gettext("Everything this library stores lives in your bucket.")}
                  <% end %>
                </span>
              </span>
            </label>
            <label class="flex items-start gap-3 cursor-pointer">
              <input
                type="radio"
                name="library[storage][mode]"
                value="backup"
                checked={@form["mode"] == "backup"}
                class="radio radio-sm radio-primary mt-0.5"
              />
              <span class="text-sm">
                {gettext("%{project}'s storage, backed up here",
                  project: PhoenixKit.Settings.get_project_title()
                )}
                <span class="block text-xs text-base-content/60">
                  <%= if length(@form["targets"]) > 1 do %>
                    {gettext(
                      "Files are kept by the site as usual, and the originals are copied to each of your buckets."
                    )}
                  <% else %>
                    {gettext(
                      "Files are kept by the site as usual, and the originals are copied to your bucket."
                    )}
                  <% end %>
                </span>
              </span>
            </label>
          </fieldset>

          <div :if={@connections != []} class="flex flex-col gap-2">
            <div class="flex flex-wrap items-center gap-2">
              <button
                type="button"
                phx-click="test_storage"
                phx-target={@myself}
                disabled={@testing}
                class="btn btn-sm btn-outline"
              >
                <span :if={@testing} class="loading loading-spinner loading-xs"></span>
                {if @testing, do: gettext("Testing..."), else: gettext("Test")}
              </button>
              <span :if={@test_result == :ok} class="text-sm text-success">
                {gettext("Works: a file can be written, read and deleted.")}
              </span>
              <span :if={match?({:error, _}, @test_result)} class="text-sm text-error">
                {elem(@test_result, 1)}
              </span>
            </div>
            <p class="text-xs text-base-content/60">
              {gettext(
                "The place a library keeps its files stays as it is. More backup storage can be added later, and existing files are copied in the background. It is tested again when you create it. Deleting the library deletes the files it stored in your buckets."
              )}
            </p>
          </div>
        </div>
      </form>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_dialog" phx-target={@myself}>
          {gettext("Cancel")}
        </button>
        <button
          type="submit"
          form={"#{@id}-create"}
          class="btn btn-primary"
          disabled={@creating or (@form["kind"] == "own" and @connections == [])}
          phx-disable-with={gettext("Creating…")}
        >
          <span :if={@creating} class="loading loading-spinner loading-xs"></span>
          {gettext("Create library")}
        </button>
      </:actions>
    </.modal>
    """
  end

  attr :id, :string, required: true
  attr :progress, :map, required: true

  defp storage_work(assigns) do
    ~H"""
    <section
      id={@id}
      class="rounded-2xl border border-primary/20 bg-primary/5 p-4"
      aria-label={gettext("Storage activity")}
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h3 class="flex items-center gap-2 font-semibold">
          <.icon
            name={if @progress.pending == 0, do: "hero-check-circle", else: "hero-arrow-path"}
            class="size-5 text-primary"
          />
          {storage_state(@progress)}
        </h3>
        <span class="text-xs text-base-content/60">{gettext("Updates automatically")}</span>
      </div>
      <div :if={@progress.total > 0} class="mt-3">
        <div class="mb-2 flex items-center justify-between gap-2 text-sm">
          <span>{gettext("%{done} of %{total} files up to date",
            done: @progress.completed,
            total: @progress.total
          )}</span>
          <span class="font-semibold tabular-nums">{@progress.percent}%</span>
        </div>
        <progress
          class="progress progress-primary h-2 w-full"
          value={@progress.completed}
          max={max(@progress.total, 1)}
          aria-label={gettext("Library storage progress")}
        ></progress>
      </div>
      <p :if={@progress.total == 0} class="mt-2 text-sm text-base-content/70">
        {gettext("No files to copy yet. New uploads will use this storage.")}
      </p>
      <div :if={@progress.pending > 0} class="mt-3 flex flex-wrap gap-2 text-xs">
        <span class="badge badge-outline badge-sm">{gettext("%{count} pending",
          count: @progress.pending
        )}</span>
        <span :if={@progress.failing > 0} class="badge badge-warning badge-sm">{gettext(
          "%{count} waiting to retry",
          count: @progress.failing
        )}</span>
        <span :if={@progress.processing > 0} class="badge badge-outline badge-sm">{gettext(
          "%{count} processing uploads",
          count: @progress.processing
        )}</span>
      </div>
      <p :if={@progress.failing > 0} class="mt-2 text-xs text-base-content/70">
        {gettext(
          "Some files could not be updated. Failed files become eligible for another attempt after a 10-minute cooldown. Check storage access if failures persist."
        )}
      </p>
      <p class="mt-2 text-xs text-base-content/60">
        {gettext(
          "Tracks copying, verification, cleanup and rendition updates. Stored copies include originals and renditions."
        )}
      </p>
    </section>
    """
  end

  defp storage_state(%{total: 0}), do: gettext("Storage ready")
  defp storage_state(%{pending: 0}), do: gettext("Up to date")
  defp storage_state(%{run_state: "running"}), do: gettext("Updating storage")

  defp storage_state(%{run_state: state}) when state in ["paused", "pausing"],
    do: gettext("Storage work paused")

  defp storage_state(%{run_state: state}) when state in ["failed", "cancelled", "cancelling"],
    do: gettext("Storage work needs attention")

  defp storage_state(%{failing: failing}) when failing > 0, do: gettext("Waiting to retry")
  defp storage_state(_progress), do: gettext("Waiting for background work")

  attr :id, :string, required: true
  attr :index, :integer, required: true
  attr :count, :integer, required: true
  attr :target, :map, required: true
  attr :connections, :list, required: true
  attr :list, :any, default: nil
  attr :myself, :any, required: true
  attr :usage, :map, default: %{}
  attr :library_uuid, :string, default: nil

  # One bucket of the new library: an integration of the user's, and a bucket on
  # it. What the integration already knows is shown under it, not asked again.
  defp target_row(assigns) do
    assigns =
      assigns
      |> assign(:uuid, assigns.target["integration_uuid"])
      |> assign(:bucket, assigns.target["bucket_name"])
      |> assign(:line, integration_line(assigns.connections, assigns.target["integration_uuid"]))
      |> assign(
        :bucket_options,
        if(match?({:ok, _}, assigns.list),
          do:
            bucket_choices(
              assigns.list,
              assigns.target["bucket_name"],
              assigns.usage,
              assigns.library_uuid
            ),
          else: []
        )
      )

    ~H"""
    <div
      id={"#{@id}-target-#{@index}"}
      class="rounded-lg border border-base-300 p-3 flex flex-col gap-3"
    >
      <div class="flex items-center justify-between gap-2">
        <span class="text-sm font-semibold">{target_title(@index, @count)}</span>
        <button
          :if={@count > 1}
          type="button"
          phx-click="remove_target"
          phx-value-index={@index}
          phx-target={@myself}
          class="btn btn-ghost btn-xs"
        >
          {gettext("Remove")}
        </button>
      </div>

      <div class="flex flex-col gap-1">
        <.select
          id={"#{@id}-integration-#{@index}"}
          name={"library[storage][targets][#{@index}][integration_uuid]"}
          label={gettext("Integration")}
          value={@uuid}
          prompt={gettext("Select an integration...")}
          options={for connection <- @connections, do: {connection.name, connection.uuid}}
        />
        <span :if={@line} class="text-xs text-base-content/60">{@line}</span>
      </div>

      <div class="flex flex-col gap-1">
        <div :if={match?({:ok, _}, @list)} class="flex items-end gap-2">
          <div class="grow">
            <.select
              id={"#{@id}-bucket-#{@index}"}
              name={"library[storage][targets][#{@index}][bucket_name]"}
              label={gettext("Bucket")}
              value={@bucket}
              prompt={gettext("Choose a bucket...")}
              options={@bucket_options}
            />
          </div>
          <button
            type="button"
            phx-click="type_bucket"
            phx-value-index={@index}
            phx-target={@myself}
            class="btn btn-ghost mb-px"
          >
            {gettext("Type a name")}
          </button>
        </div>
        <div :if={not match?({:ok, _}, @list)} class="flex items-end gap-2">
          <div class="grow">
            <.input
              type="text"
              id={"#{@id}-bucket-#{@index}"}
              name={"library[storage][targets][#{@index}][bucket_name]"}
              label={gettext("Bucket")}
              value={@bucket}
              placeholder="my-photos"
              autocomplete="off"
            />
          </div>
          <button
            type="button"
            phx-click="list_buckets"
            phx-value-index={@index}
            phx-target={@myself}
            disabled={@uuid == "" or @list == :loading}
            class="btn btn-outline mb-px"
          >
            <span :if={@list == :loading} class="loading loading-spinner loading-xs"></span>
            {gettext("List buckets")}
          </button>
        </div>
        <span :if={match?({:error, _}, @list)} class="text-xs text-warning">
          {elem(@list, 1)}
        </span>
        <span
          :if={match?({:ok, _}, @list) and @bucket_options == []}
          class="text-xs text-base-content/60"
        >
          {gettext(
            "No available buckets on this integration. Choose another integration or create a new bucket at your provider."
          )}
        </span>
        <span
          :if={match?({:ok, _}, @list) and @bucket_options != []}
          class="text-xs text-base-content/60"
        >
          {ngettext("%{count} bucket found.", "%{count} buckets found.", length(@bucket_options))}
        </span>
      </div>
    </div>
    """
  end

  defp target_title(0, 1), do: gettext("Storage")
  defp target_title(0, _count), do: gettext("Main storage")
  defp target_title(index, _count), do: gettext("Copy %{n}", n: index)

  # The listed buckets, and the one already typed or chosen when the list does
  # not hold it (a key that lists fewer buckets than it can use).
  defp bucket_choices({:ok, names}, current, usage, library_uuid) do
    names = if current in [nil, ""] or current in names, do: names, else: names ++ [current]

    names
    |> Enum.reject(fn name -> Enum.any?(usage[name] || [], &(&1.uuid == library_uuid)) end)
    |> Enum.map(fn name ->
      case usage[name] || [] do
        [] ->
          {name, name}

        libraries ->
          {gettext("%{bucket} — used by %{libraries}",
             bucket: name,
             libraries: Enum.map_join(libraries, ", ", & &1.name)
           ), name}
      end
    end)
  end

  attr :id, :string, required: true
  attr :library, :map, required: true
  attr :members, :list, required: true
  attr :roles, :list, required: true
  attr :myself, :any, required: true

  defp members_panel(assigns) do
    ~H"""
    <div id={"#{@id}-members-#{@library.uuid}"} class="flex flex-col gap-4">
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
          <.select
            id={"#{@id}-role-select-#{@library.uuid}-#{member.user_uuid}"}
            name="role"
            value={member.role}
            options={for role <- @roles, do: {role_label(role), role}}
            aria-label={gettext("Role")}
          />
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

      <.section_header icon="hero-user-plus" title={gettext("Add a member")} />
      <form
        id={"#{@id}-add-member-#{@library.uuid}"}
        phx-submit="add_member"
        phx-target={@myself}
        class="flex flex-wrap items-end gap-2"
      >
        <input type="hidden" name="uuid" value={@library.uuid} />
        <div class="grow">
          <.input
            type="email"
            id={"#{@id}-member-email-#{@library.uuid}"}
            name="member[email]"
            value=""
            label={gettext("Email")}
            required
          />
        </div>
        <div>
          <.select
            id={"#{@id}-member-role-#{@library.uuid}"}
            name="member[role]"
            label={gettext("Role")}
            value="viewer"
            options={for role <- @roles, do: {role_label(role), role}}
          />
        </div>
        <button type="submit" class="btn btn-primary mb-px">{gettext("Add")}</button>
      </form>
    </div>
    """
  end
end
