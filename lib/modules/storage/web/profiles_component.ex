defmodule PhoenixKitWeb.Live.Modules.Storage.ProfilesComponent do
  @moduledoc """
  The Storage profiles tab of Settings → Media (V205): where each library's
  bytes live.

  A profile lists buckets and says, for each, its role (`primary` is
  written and served, `replica` is served when no primary has the copy,
  `backup` is written but never served), a fixed write priority (empty is
  the shuffled pool), a serve order and a status (`read_only` keeps
  serving and gets no new files, `draining` has its files moved to the
  profile's other buckets). The profile also says how many copies every
  file gets on local buckets and on cloud ones (the cloud count can be set only
  where the profile has a cloud bucket), and how many copies an upload needs to
  succeed. A bucket holds everything the profile sends it, an original and what
  is made from it.

  Every library without its own profile uses the Default, which every
  bucket joins when it is created. Any change bumps the profile's revision,
  and the reconciler moves its files by itself (the Health page shows what
  is left). A library picks its profile on the Libraries tab.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Bucket, ProfileBucket, Profiles, StorageProfile}
  alias PhoenixKitWeb.Live.Modules.Storage.BucketUsage

  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]
  import PhoenixKitWeb.Components.Core.SaveButton, only: [save_button: 1]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       profiles: nil,
       scope: nil,
       creating: false,
       dirty: MapSet.new(),
       saved: MapSet.new()
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(socket.assigns.profiles, do: socket, else: load(socket))}
  end

  defp load(socket) do
    profiles = Profiles.list_profiles()
    buckets = Storage.list_buckets()

    socket
    |> assign(:profiles, profiles)
    |> assign(:buckets, buckets)
    |> assign(:bucket_usage, Profiles.bucket_usage(Enum.map(buckets, & &1.uuid)))
    |> assign(:in_use, Map.new(profiles, &{&1.uuid, Profiles.libraries_using(&1.uuid)}))
  end

  # A form changed (`phx-change`): its Save button comes alive and says so. The
  # key names the form — `profile_key/1`, `row_key/2` — and arrives from the
  # client, so it is only ever a member of a set.
  @impl true
  def handle_event("dirty", %{"key" => key}, socket) when is_binary(key) do
    {:noreply,
     assign(socket,
       dirty: MapSet.put(socket.assigns.dirty, key),
       saved: MapSet.delete(socket.assigns.saved, key)
     )}
  end

  # After a reconnect LiveView replays every form's values as a change, which is
  # not an edit: the forms come back as stored and nothing is unsaved. A
  # recovered form goes to this event, not to "dirty" (`phx-auto-recover`).
  def handle_event("recover", _params, socket), do: {:noreply, socket}

  def handle_event("new", _params, socket), do: {:noreply, assign(socket, :creating, true)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :creating, false)}

  def handle_event("create", %{"profile" => params}, socket) do
    case Profiles.create_profile(params, actor(socket)) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> load()
         |> flash(:info, gettext("Storage profile \"%{name}\" created", name: profile.name))}

      {:error, changeset} ->
        {:noreply, flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("save_profile", %{"uuid" => uuid, "profile" => params}, socket) do
    with %StorageProfile{} = profile <- find(socket, uuid),
         {:ok, _} <- Profiles.update_profile(profile, params, actor(socket)) do
      {:noreply,
       socket
       |> load()
       |> mark_saved(profile_key(uuid))
       |> flash(:info, gettext("Storage profile saved"))}
    else
      nil -> {:noreply, socket}
      {:error, changeset} -> {:noreply, flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("delete_profile", %{"uuid" => uuid}, socket) do
    with %StorageProfile{} = profile <- find(socket, uuid),
         {:ok, _} <- Profiles.delete_profile(profile, actor(socket)) do
      {:noreply, socket |> load() |> flash(:info, gettext("Storage profile deleted"))}
    else
      nil ->
        {:noreply, socket}

      {:error, :default} ->
        {:noreply, flash(socket, :error, gettext("The Default profile cannot be deleted."))}

      {:error, :in_use} ->
        {:noreply, flash(socket, :error, in_use_message(find(socket, uuid)))}

      {:error, _changeset} ->
        {:noreply, flash(socket, :error, gettext("The storage profile could not be deleted."))}
    end
  end

  def handle_event("add_bucket", %{"uuid" => uuid, "bucket_uuid" => bucket_uuid}, socket) do
    with %StorageProfile{} = profile <- find(socket, uuid),
         true <- Enum.any?(socket.assigns.buckets, &(to_string(&1.uuid) == bucket_uuid)),
         {:ok, _} <-
           Profiles.put_bucket(
             profile,
             bucket_uuid,
             %{serve_order: next_serve_order(profile)},
             actor(socket)
           ) do
      {:noreply, socket |> load() |> flash(:info, added_message(socket, profile, bucket_uuid))}
    else
      {:error, changeset} -> {:noreply, flash(socket, :error, error_message(changeset))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_row", %{"uuid" => uuid, "bucket_uuid" => bucket_uuid} = params, socket) do
    attrs = Map.get(params, "row", %{})

    with %StorageProfile{} = profile <- find(socket, uuid),
         true <- Enum.any?(profile.buckets, &(to_string(&1.bucket_uuid) == bucket_uuid)),
         {:ok, _} <- Profiles.put_bucket(profile, bucket_uuid, attrs, actor(socket)) do
      {:noreply,
       socket
       |> load()
       |> mark_saved(row_key(uuid, bucket_uuid))
       |> flash(:info, gettext("Bucket settings saved"))}
    else
      {:error, changeset} ->
        {:noreply, socket |> load() |> flash(:error, error_message(changeset))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_bucket", %{"uuid" => uuid, "bucket_uuid" => bucket_uuid}, socket) do
    case find(socket, uuid) do
      %StorageProfile{} = profile ->
        case Profiles.remove_bucket(profile, bucket_uuid, actor(socket)) do
          :ok ->
            {:noreply,
             socket
             |> load()
             |> flash(
               :info,
               gettext(
                 "Bucket taken out of the profile. Its files are copied to the profile's other buckets, then removed from it."
               )
             )}

          {:error, reason} ->
            {:noreply, flash(socket, :error, error_message(reason))}
        end

      nil ->
        {:noreply, socket}
    end
  end

  defp profile_key(profile_uuid), do: "profile:#{profile_uuid}"
  defp row_key(profile_uuid, bucket_uuid), do: "row:#{profile_uuid}:#{bucket_uuid}"

  defp mark_saved(socket, key) do
    assign(socket,
      dirty: MapSet.delete(socket.assigns.dirty, key),
      saved: MapSet.put(socket.assigns.saved, key)
    )
  end

  # Only a profile this tab listed: the uuid arrives from the client.
  # Who is acting, for the history (`Storage.Audit`).
  defp actor(socket), do: PhoenixKitWeb.Actor.opts(socket.assigns.scope)

  # Names the site libraries that stand in the way; a user's library is private
  # to its owner, so those are only counted.
  defp in_use_message(%StorageProfile{} = profile) do
    %{names: names, user_libraries: users} = Profiles.library_names_using(profile.uuid)

    libraries =
      names ++
        if users > 0,
          do: [ngettext("%{count} personal library", "%{count} personal libraries", users)],
          else: []

    gettext(
      "\"%{profile}\" cannot be deleted: it is used by %{libraries}. Move them to another storage profile first (Libraries tab).",
      profile: profile.name,
      libraries: Enum.join(libraries, ", ")
    )
  end

  defp find(socket, uuid), do: Enum.find(socket.assigns.profiles, &(to_string(&1.uuid) == uuid))

  defp next_serve_order(profile),
    do: (profile.buckets |> Enum.map(& &1.serve_order) |> Enum.max(fn -> 0 end)) + 1

  defp flash(socket, kind, message) do
    send(self(), {__MODULE__, {:flash, kind, message}})
    socket
  end

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{Phoenix.Naming.humanize(field)}: #{Enum.join(messages, ", ")}"
    end)
  end

  defp role_label("primary"), do: gettext("Primary")
  defp role_label("replica"), do: gettext("Replica")
  defp role_label("backup"), do: gettext("Backup")

  defp status_label("active"), do: gettext("Active")
  defp status_label("read_only"), do: gettext("Read-only (no new files)")
  defp status_label("draining"), do: gettext("Draining (moving files out)")

  # The columns of the bucket rows. The header and every row share it, so each
  # control sits under its own heading. Every row is a grid of its own, so the
  # widths are fixed, not `auto`: the last column (Save and remove) is as wide as
  # its two controls need, and its note wraps under the button instead of
  # widening it.
  defp columns,
    do: "grid grid-cols-[minmax(9rem,2fr)_6.5rem_5.5rem_5rem_12rem_9.5rem] gap-2"

  # Save and remove stay in view when the table is wider than the page: the
  # scrolling part is the settings, not the way to act on them.
  defp actions_cell, do: "sticky right-0 flex items-center justify-end gap-1 bg-base-100"

  # What the copy counts mean with the buckets the profile has now: the numbers
  # alone read the same with one bucket and with five. The arithmetic is
  # `Profiles.copies_advice/1`'s, which the bucket form shares. A list of
  # `{severity, text}`, the worst first.
  defp copies_hints(profile) do
    %{writable: writable, local: local, cloud: cloud} = Profiles.copies_advice(profile)

    if writable == 0 do
      [{:error, gettext("No bucket can take new files now, so uploads fail.")}]
    else
      Enum.reject(
        [
          shortfall(:local, local),
          shortfall(:cloud, cloud),
          cloud_unused(cloud),
          spread(:local, local),
          spread(:cloud, cloud)
        ],
        &is_nil/1
      )
    end
  end

  # More copies wanted of a kind than there are buckets of it to hold them.
  defp shortfall(:local, %{copies: copies, buckets: buckets}) when copies > buckets do
    {:warning,
     ngettext(
       "%{copies} local copies are wanted, but only %{count} local bucket takes new files, so each file gets %{count}.",
       "%{copies} local copies are wanted, but only %{count} local buckets take new files, so each file gets %{count}.",
       buckets,
       copies: copies
     )}
  end

  defp shortfall(:cloud, %{copies: copies, buckets: buckets}) when copies > buckets do
    {:warning,
     ngettext(
       "%{copies} cloud copies are wanted, but only %{count} cloud bucket takes new files, so each file gets %{count}.",
       "%{copies} cloud copies are wanted, but only %{count} cloud buckets take new files, so each file gets %{count}.",
       buckets,
       copies: copies
     )}
  end

  defp shortfall(_kind, _advice), do: nil

  # A cloud bucket that nothing is sent to: the usual reason is a count never set.
  defp cloud_unused(%{buckets: buckets, copies: 0}) when buckets > 0 do
    {:info,
     gettext(
       "The cloud buckets hold nothing at 0 cloud copies. Set Cloud copies to keep a copy off this server."
     )}
  end

  defp cloud_unused(_advice), do: nil

  # Fewer copies than primaries: each file goes to some of them, picked by
  # upload order, otherwise at random: spread, not mirrored. Replicas and
  # backups take part only when the count passes the primaries.
  defp spread(:local, %{copies: copies, primaries: primaries})
       when copies > 0 and primaries > copies do
    {:info,
     gettext(
       "%{count} local buckets take new files and each file is stored on %{copies} of them, picked by upload order, otherwise at random: files are spread across them, not mirrored.",
       count: primaries,
       copies: copies
     )}
  end

  defp spread(:cloud, %{copies: copies, primaries: primaries})
       when copies > 0 and primaries > copies do
    {:info,
     gettext(
       "%{count} cloud buckets take new files and each file is stored on %{copies} of them, picked by upload order, otherwise at random: files are spread across them, not mirrored.",
       count: primaries,
       copies: copies
     )}
  end

  defp spread(_kind, _advice), do: nil

  # The replicas and backups no count reaches, of either kind.
  defp idle_buckets(profile) do
    %{local: local, cloud: cloud} = Profiles.copies_advice(profile)
    local.idle ++ cloud.idle
  end

  # The cloud count can be set only where there is a cloud bucket to hold it.
  defp cloud_available?(profile) do
    Enum.any?(profile.buckets, fn row ->
      row.status == "active" and row.bucket.enabled and Bucket.group(row.bucket) == :cloud
    end)
  end

  defp hint_class(:error), do: "text-error"
  defp hint_class(:warning), do: "text-warning"
  defp hint_class(:info), do: "text-base-content/60"

  # The other profiles that list a bucket: what sharing it means. A bucket is
  # one physical place with one on/off switch, size limit and set of keys, so
  # a profile that lists it is tied to every other one that does.
  defp used_elsewhere(usage, bucket_uuid, profile_uuid) do
    usage
    |> Map.get(to_string(bucket_uuid), [])
    |> Enum.reject(&(&1.profile_uuid == to_string(profile_uuid)))
  end

  # "Default, Archive, 2 personal storage profiles": a user's own profile is
  # counted, never named.
  defp profile_names(others) do
    {personal, site} = Enum.split_with(others, &is_binary(&1.owner_uuid))

    personal_text =
      case length(personal) do
        0 ->
          []

        count ->
          [
            ngettext(
              "%{count} personal storage profile",
              "%{count} personal storage profiles",
              count
            )
          ]
      end

    Enum.join(Enum.map(site, & &1.name) ++ personal_text, ", ")
  end

  defp shared_note(others) do
    gettext(
      "Also used by %{used_by}. A bucket's on/off switch, size limit and keys belong to the bucket, so they apply to every profile that lists it.",
      used_by: BucketUsage.used_by_text(others)
    )
  end

  defp added_message(socket, profile, bucket_uuid) do
    case used_elsewhere(socket.assigns.bucket_usage, bucket_uuid, profile.uuid) do
      [] ->
        gettext("Bucket added to the profile")

      others ->
        gettext(
          "Bucket added to the profile. It is shared with %{profiles}: its on/off switch, size limit and keys apply to all of them.",
          profiles: profile_names(others)
        )
    end
  end

  # The buckets a profile can still take, those no other profile uses first,
  # each one that is used elsewhere saying where.
  defp add_options(profile, buckets, usage) do
    profile
    |> not_in(buckets)
    |> Enum.map(fn bucket ->
      case used_elsewhere(usage, bucket.uuid, profile.uuid) do
        [] ->
          {0, bucket.name, bucket.uuid, bucket.name}

        others ->
          label =
            gettext("%{bucket} (also in %{profiles})",
              bucket: bucket.name,
              profiles: profile_names(others)
            )

          {1, bucket.name, bucket.uuid, label}
      end
    end)
    |> Enum.sort()
    |> Enum.map(fn {_shared, _name, uuid, label} -> {uuid, label} end)
  end

  defp not_in(profile, buckets) do
    used = MapSet.new(profile.buckets, &to_string(&1.bucket_uuid))
    Enum.reject(buckets, &MapSet.member?(used, to_string(&1.uuid)))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div class="card bg-base-100 shadow-xl mb-6 mt-6">
        <div class="card-body">
          <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
            <h2 class="card-title text-lg">
              <.icon name="hero-server-stack" class="w-6 h-6 mr-2" /> {gettext("Storage profiles")}
            </h2>
            <button
              :if={not @creating}
              type="button"
              class="btn btn-primary"
              phx-click="new"
              phx-target={@myself}
            >
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("New profile")}
            </button>
          </div>
          <p class="text-sm text-base-content/70">
            {gettext(
              "A storage profile says where a library's files are kept: which buckets, how many copies of each file, and which copy is served. A library without a profile of its own uses the Default. When the buckets, their roles or the copy counts change, files are copied or moved in the background; the Health page shows what is left."
            )}
          </p>

          <form
            :if={@creating}
            id={"#{@id}-new"}
            phx-submit="create"
            phx-target={@myself}
            class="flex flex-wrap items-center gap-2 mt-4"
          >
            <input
              type="text"
              name="profile[name]"
              id={"#{@id}-new-name"}
              class="input input-sm w-64"
              placeholder={gettext("Profile name")}
              maxlength="255"
              required
              autofocus
            />
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Create")}</button>
            <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel" phx-target={@myself}>
              {gettext("Cancel")}
            </button>
          </form>
        </div>
      </div>

      <div
        :for={profile <- @profiles}
        id={"#{@id}-#{profile.uuid}"}
        class="card bg-base-100 shadow-xl mb-6"
      >
        <div class="card-body">
          <form
            id={"#{@id}-form-#{profile.uuid}"}
            phx-change="dirty"
            phx-auto-recover="recover"
            phx-submit="save_profile"
            phx-target={@myself}
            class="flex flex-wrap items-end gap-4"
          >
            <input type="hidden" name="uuid" value={profile.uuid} />
            <input type="hidden" name="key" value={profile_key(profile.uuid)} />
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Name")}</span>
              <input
                type="text"
                name="profile[name]"
                value={profile.name}
                maxlength="255"
                required
                class="input input-sm input-bordered w-56"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Local copies")}</span>
              <input
                type="number"
                name="profile[copies_local]"
                min="0"
                max="5"
                value={profile.copies_local}
                title={gettext("How many copies of each file are kept on this server's own disks.")}
                class="input input-sm input-bordered w-24"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Cloud copies")}</span>
              <input
                type="number"
                name="profile[copies_cloud]"
                min="0"
                max="5"
                value={profile.copies_cloud}
                disabled={profile.copies_cloud == 0 and not cloud_available?(profile)}
                title={
                  if cloud_available?(profile),
                    do:
                      gettext(
                        "How many copies of each file are kept in the cloud, so a file survives the server."
                      ),
                    else: gettext("Add a cloud bucket to this profile to keep copies in the cloud.")
                }
                class="input input-sm input-bordered w-24"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Copies needed to accept an upload")}</span>
              <input
                type="number"
                name="profile[min_copies_on_write]"
                min="1"
                max="5"
                value={profile.min_copies_on_write}
                class="input input-sm input-bordered w-24"
              />
            </label>
            <.save_button
              dirty={MapSet.member?(@dirty, profile_key(profile.uuid))}
              saved={MapSet.member?(@saved, profile_key(profile.uuid))}
            />
            <span :if={profile.is_default} class="badge badge-ghost">{gettext("Default")}</span>
            <span class="text-sm text-base-content/60">
              {ngettext(
                "Used by %{count} library.",
                "Used by %{count} libraries.",
                Map.get(@in_use, profile.uuid, 0)
              )}
            </span>
            <button
              :if={not profile.is_default}
              type="button"
              class="btn btn-sm btn-ghost text-error ml-auto"
              disabled={Map.get(@in_use, profile.uuid, 0) > 0}
              phx-click="delete_profile"
              phx-value-uuid={profile.uuid}
              phx-target={@myself}
              data-confirm={gettext("Delete this storage profile?")}
            >
              <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
            </button>
          </form>

          <p
            :for={{severity, text} <- copies_hints(profile)}
            :if={profile.buckets != []}
            class={["text-sm mt-3", hint_class(severity)]}
          >
            {text}
          </p>

          <% idle = idle_buckets(profile) %>
          <div
            :if={idle != []}
            id={"#{@id}-advice-#{profile.uuid}"}
            class="mt-2 rounded-box bg-base-200 px-3 py-2 text-sm"
          >
            {gettext("Not used at this copy count: %{names}.", names: Enum.join(idle, ", "))}
          </div>

          <div class="overflow-x-auto mt-4">
            <div class="min-w-[52rem]">
              <div class={[
                columns(),
                "items-end px-2 pb-2 text-xs font-semibold text-base-content/60"
              ]}>
                <span>{gettext("Bucket")}</span>
                <span
                  class="tooltip tooltip-bottom text-left"
                  data-tip={
                    gettext(
                      "Primary: written and served. Replica: written when more copies are wanted than there are primaries; served only if no primary has the file. Backup: written, never served."
                    )
                  }
                >
                  {gettext("Role")}
                </span>
                <span
                  class="tooltip tooltip-bottom text-left"
                  data-tip={
                    gettext(
                      "Lower numbers get new files first. Leave it empty to share them: buckets with no number take turns at random."
                    )
                  }
                >
                  {gettext("Upload order")}
                </span>
                <span
                  class="tooltip tooltip-bottom text-left"
                  data-tip={
                    gettext(
                      "When a file is on several buckets, the one with the lowest number serves it."
                    )
                  }
                >
                  {gettext("Serve order")}
                </span>
                <span>{gettext("Status")}</span>
                <span></span>
              </div>

              <p
                :if={profile.buckets == []}
                class="border-t border-base-200 py-3 px-2 text-sm text-base-content/60"
              >
                {gettext("No buckets yet: uploads to a library on this profile fail.")}
              </p>

              <form
                :for={row <- profile.buckets}
                id={"#{@id}-row-#{profile.uuid}-#{row.bucket_uuid}"}
                phx-change="dirty"
                phx-auto-recover="recover"
                phx-submit="save_row"
                phx-target={@myself}
                class={[columns(), "items-center border-t border-base-200 px-2 py-2"]}
              >
                <input type="hidden" name="uuid" value={profile.uuid} />
                <input type="hidden" name="bucket_uuid" value={row.bucket_uuid} />
                <input type="hidden" name="key" value={row_key(profile.uuid, row.bucket_uuid)} />

                <div id={"#{@id}-#{profile.uuid}-#{row.bucket_uuid}"} class="min-w-0">
                  <span class="font-medium break-words">{row.bucket.name}</span>
                  <span class="badge badge-ghost badge-sm ml-1">{row.bucket.provider}</span>
                  <span :if={not row.bucket.enabled} class="badge badge-error badge-sm ml-1">
                    {gettext("Disabled")}
                  </span>
                  <% others = used_elsewhere(@bucket_usage, row.bucket_uuid, profile.uuid) %>
                  <div :if={others != []} class="mt-1">
                    <span
                      id={"#{@id}-shared-#{profile.uuid}-#{row.bucket_uuid}"}
                      class="badge badge-warning badge-sm h-auto gap-1 whitespace-normal text-left"
                      title={shared_note(others)}
                    >
                      <.icon name="hero-link" class="w-3 h-3 shrink-0" />
                      {gettext("Also in %{profiles}", profiles: profile_names(others))}
                    </span>
                  </div>
                </div>

                <select name="row[role]" class="select select-sm select-bordered w-full">
                  <option
                    :for={role <- ProfileBucket.roles()}
                    value={role}
                    selected={row.role == role}
                  >
                    {role_label(role)}
                  </option>
                </select>
                <input
                  type="number"
                  name="row[write_priority]"
                  min="1"
                  value={row.write_priority}
                  placeholder={gettext("Any")}
                  class="input input-sm input-bordered w-full"
                />
                <input
                  type="number"
                  name="row[serve_order]"
                  min="0"
                  value={row.serve_order}
                  class="input input-sm input-bordered w-full"
                />
                <select name="row[status]" class="select select-sm select-bordered w-full">
                  <option
                    :for={status <- ProfileBucket.statuses()}
                    value={status}
                    selected={row.status == status}
                  >
                    {status_label(status)}
                  </option>
                </select>
                <div class={actions_cell()}>
                  <.save_button
                    dirty={MapSet.member?(@dirty, row_key(profile.uuid, row.bucket_uuid))}
                    saved={MapSet.member?(@saved, row_key(profile.uuid, row.bucket_uuid))}
                  />
                  <button
                    type="button"
                    class="btn btn-xs btn-ghost text-error"
                    title={gettext("Remove from profile")}
                    aria-label={gettext("Remove from profile")}
                    phx-click="remove_bucket"
                    phx-value-uuid={profile.uuid}
                    phx-value-bucket_uuid={row.bucket_uuid}
                    phx-target={@myself}
                    data-confirm={
                      gettext(
                        "Take this bucket out of the profile? Its files are copied to the profile's other buckets first, then deleted from this bucket. The bucket itself stays, and this profile no longer sends it files."
                      )
                    }
                  >
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </div>
              </form>
            </div>
          </div>

          <form
            :if={not_in(profile, @buckets) != []}
            id={"#{@id}-add-#{profile.uuid}"}
            phx-submit="add_bucket"
            phx-target={@myself}
            class="flex flex-wrap items-center gap-2 mt-2"
          >
            <input type="hidden" name="uuid" value={profile.uuid} />
            <select name="bucket_uuid" class="select select-sm select-bordered">
              <option
                :for={{uuid, label} <- add_options(profile, @buckets, @bucket_usage)}
                value={uuid}
              >
                {label}
              </option>
            </select>
            <button type="submit" class="btn btn-sm btn-outline">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add bucket")}
            </button>
            <p
              :if={
                Enum.any?(
                  not_in(profile, @buckets),
                  &(used_elsewhere(@bucket_usage, &1.uuid, profile.uuid) != [])
                )
              }
              class="basis-full text-xs text-warning"
            >
              {gettext(
                "A bucket marked \"also in\" is already used by another profile. Adding it shares it: its on/off switch, size limit and keys apply to every profile that lists it."
              )}
            </p>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
