defmodule PhoenixKitWeb.Live.Components.LibraryActivity do
  @moduledoc "The personal Media Activity tab: library jobs, read-only verification and durable logs."
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Modules.Storage.{Libraries, LibraryOperations, Profiles, VerificationPolicy}
  alias PhoenixKit.Utils.Format

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, assigns.scope)
      |> assign(:url_path, assigns[:url_path])
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:show_verify, fn -> false end)
      |> assign_new(:selected_library, fn -> "" end)
      |> assign_new(:mode, fn -> "presence" end)
      |> assign_new(:include_previews, fn -> false end)
      |> assign_new(:page, fn -> 1 end)
      |> assign_new(:log_page, fn -> 1 end)
      |> assign_new(:run_uuid, fn -> nil end)
      |> restore(assigns[:url_params] || %{})
      |> load()

    {:ok, socket}
  end

  defp restore(socket, params) do
    state = Map.take(params, ~w(run verify activity_page log_page))

    if socket.assigns[:url_state] == state do
      socket
    else
      socket
      |> assign(:url_state, state)
      |> assign(:page, page(params["activity_page"]))
      |> assign(:log_page, page(params["log_page"]))
      |> assign(:run_uuid, params["run"])
      |> assign(:show_verify, is_binary(params["verify"]))
      |> assign(:selected_library, params["verify"] || "")
    end
  end

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp page(_value), do: 1

  defp load(socket) do
    activity = LibraryOperations.list(socket.assigns.scope, socket.assigns.page)

    logs =
      if socket.assigns.run_uuid,
        do:
          LibraryOperations.logs(
            socket.assigns.scope,
            socket.assigns.run_uuid,
            socket.assigns.log_page
          )

    owned = Enum.filter(activity.libraries, &(&1.role == :owner))
    libraries = Enum.map(owned, & &1.library)
    stats = Libraries.content_stats(Enum.map(libraries, & &1.uuid))
    storage = Profiles.user_storage_for(libraries)
    project_title = PhoenixKit.Settings.get_project_title()
    limits = VerificationPolicy.status(libraries)

    choices =
      Enum.map(libraries, fn library ->
        summary = stats[library.uuid]

        label =
          Enum.join(
            [
              library.name,
              ngettext("%{count} file", "%{count} files", summary.files),
              Format.bytes(summary.bytes),
              storage_summary(storage[library.uuid], project_title)
            ],
            " · "
          )

        {label, library.uuid}
      end)

    socket
    |> assign(:activity, activity)
    |> assign(:logs, logs)
    |> assign(:owned, owned)
    |> assign(:library_choices, choices)
    |> assign(:verification_limits, limits)
    |> assign(:library_names, Map.new(activity.libraries, &{&1.library.uuid, &1.library.name}))
  end

  defp storage_summary(nil, project_title),
    do: gettext("%{project}'s storage", project: project_title)

  defp storage_summary(storage, project_title) do
    buckets =
      Enum.map(storage.buckets, fn target ->
        if target.role == "primary",
          do: target.bucket.bucket_name,
          else: gettext("Backup: %{bucket}", bucket: target.bucket.bucket_name)
      end)

    places =
      if storage.mode == :backup,
        do: [storage_summary(nil, project_title) | buckets],
        else: buckets

    Enum.join(places, ", ")
  end

  @impl true
  def handle_event("open_verify", _params, socket) do
    uuid =
      case socket.assigns.owned do
        [%{library: library} | _] -> library.uuid
        _ -> ""
      end

    {:noreply,
     socket
     |> assign(:show_verify, true)
     |> assign(:selected_library, uuid)
     |> patch(%{"verify" => uuid, "run" => nil})}
  end

  def handle_event("verification_change", %{"verification" => params}, socket) do
    {:noreply,
     socket
     |> assign(:selected_library, params["library_uuid"] || "")
     |> assign(:mode, params["mode"] || "presence")
     |> assign(:include_previews, params["include_previews"] == "true")}
  end

  def handle_event("start_verification", %{"verification" => params}, socket) do
    case LibraryOperations.verify(socket.assigns.scope, params["library_uuid"], params) do
      {:ok, run, how} ->
        message =
          if how == :existing,
            do: gettext("A verification is already in progress. Showing that operation."),
            else: gettext("Verification queued. Files will be checked without making changes.")

        {:noreply,
         socket
         |> assign(:message, {:success, message})
         |> assign(:show_verify, false)
         |> assign(:run_uuid, run.uuid)
         |> assign(:log_page, 1)
         |> load()
         |> patch(%{"run" => run.uuid, "verify" => nil, "log_page" => nil})}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(
           :message,
           {:error,
            verification_error(
              reason,
              gettext(
                "Verification could not be started. Check that you still own this library and have access to Media."
              )
            )}
         )
         |> load()}
    end
  end

  def handle_event("run_details", %{"uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:run_uuid, uuid)
     |> assign(:log_page, 1)
     |> load()
     |> patch(%{"run" => uuid, "log_page" => nil, "verify" => nil})}
  end

  def handle_event("close_run", _params, socket) do
    {:noreply,
     socket
     |> assign(:run_uuid, nil)
     |> assign(:show_verify, false)
     |> load()
     |> patch(%{"run" => nil, "verify" => nil, "log_page" => nil})}
  end

  def handle_event("activity_page", %{"page" => value}, socket) do
    {:noreply,
     socket |> assign(:page, page(value)) |> load() |> patch(%{"activity_page" => value})}
  end

  def handle_event("log_page", %{"page" => value}, socket) do
    {:noreply,
     socket |> assign(:log_page, page(value)) |> load() |> patch(%{"log_page" => value})}
  end

  def handle_event("run_control", %{"uuid" => uuid, "action" => action}, socket) do
    case LibraryOperations.control(socket.assigns.scope, uuid, action) do
      {:ok, run, _how} ->
        {:noreply,
         socket
         |> assign(:message, {:success, gettext("Operation queued.")})
         |> assign(:run_uuid, run.uuid)
         |> load()
         |> patch(%{"run" => run.uuid, "log_page" => nil})}

      {:ok, _run} ->
        {:noreply,
         socket
         |> assign(
           :message,
           {:success,
            gettext("Operation updated. An executing batch finishes before pausing or stopping.")}
         )
         |> load()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(
           :message,
           {:error,
            verification_error(
              reason,
              gettext("This action is no longer available, or you no longer have access.")
            )}
         )
         |> load()}
    end
  end

  defp verification_error(:verification_busy, _fallback),
    do:
      gettext(
        "Another verification is active. Only one verification can be active across all libraries; try again after it finishes."
      )

  defp verification_error({:verification_cooldown, next}, _fallback),
    do:
      gettext(
        "This library can be checked again on %{date}. Each library can be checked once every 30 days.",
        date: time(next)
      )

  defp verification_error(_reason, fallback), do: fallback

  defp patch(%{assigns: %{url_path: path}} = socket, changes) when is_binary(path) do
    uri = URI.parse(path)

    params =
      URI.decode_query(uri.query || "")
      |> Map.merge(changes)
      |> Map.put("media_view", "activity")
      |> Map.drop(~w(dialog library settings_tab))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    socket
    |> assign(:url_state, Map.take(params, ~w(run verify activity_page log_page)))
    |> push_patch(to: uri.path <> "?" <> URI.encode_query(params))
  end

  defp patch(socket, _changes), do: socket

  defp operation("storage.verify_library"), do: gettext("Verification")
  defp operation("storage.reconcile"), do: gettext("Copying and updating")

  defp state(%{state: "completed", failed_count: n}) when n > 0,
    do: gettext("Completed with findings")

  defp state(%{state: value}), do: state_label(value)
  defp state_label("queued"), do: gettext("Queued")
  defp state_label("running"), do: gettext("Running")
  defp state_label("pausing"), do: gettext("Pausing")
  defp state_label("paused"), do: gettext("Paused")
  defp state_label("cancelling"), do: gettext("Stopping")
  defp state_label("cancelled"), do: gettext("Cancelled")
  defp state_label("failed"), do: gettext("Failed")
  defp state_label("completed"), do: gettext("Completed")
  defp state_label(_state), do: gettext("Unknown")

  defp control_label("pause"), do: gettext("Pause")
  defp control_label("resume"), do: gettext("Resume")
  defp control_label("cancel"), do: gettext("Cancel")
  defp control_label("retry"), do: gettext("Retry")
  defp badge(%{state: state}) when state in ~w(failed paused pausing), do: "badge-warning"
  defp badge(%{state: "completed", failed_count: n}) when n > 0, do: "badge-warning"
  defp badge(%{state: "completed"}), do: "badge-success"
  defp badge(_run), do: "badge-ghost"
  defp time(nil), do: "—"
  defp time(value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M:%S UTC")

  defp event_label("job.started"), do: gettext("Operation started")
  defp event_label("job.batch"), do: gettext("Batch finished")
  defp event_label("job.completed"), do: gettext("Operation completed")
  defp event_label("job.failed"), do: gettext("Operation failed; check storage access and retry")
  defp event_label("job.paused"), do: gettext("Operation paused")
  defp event_label("job.pause_requested"), do: gettext("Pause requested")
  defp event_label("job.resumed"), do: gettext("Operation resumed")
  defp event_label("job.cancelled"), do: gettext("Operation cancelled")
  defp event_label("job.cancel_requested"), do: gettext("Cancellation requested")

  defp event_label("job.interrupted"),
    do:
      gettext("Batch interrupted; unfinished work will be retried when the operation runs again")

  defp event_label("job.restarted"), do: gettext("Operation restarted after a storage change")
  defp event_label("job.rescued"), do: gettext("Interrupted operation recovered")
  defp event_label(_action), do: gettext("Operation updated")

  defp problem_label("missing_or_inaccessible"),
    do: gettext("Object is missing or storage could not be reached")

  defp problem_label("checksum_mismatch"), do: gettext("Checksum does not match")
  defp problem_label("size_mismatch"), do: gettext("Size does not match")

  defp problem_label("unrecorded_checksum"),
    do: gettext("No checksum recorded; integrity could not be verified")

  defp problem_label("unsupported_checksum"),
    do: gettext("Recorded checksum needs updating before integrity can be verified")

  defp problem_label("read_failed"), do: gettext("Could not read this copy")
  defp problem_label("bucket_disabled"), do: gettext("Storage bucket is disabled")
  defp problem_label("copy_pending"), do: gettext("Copy is not ready")

  defp problem_label("insufficient_copies"),
    do: gettext("Fewer copies recorded than the library requires")

  defp problem_label("no_serving_copy"),
    do: gettext("No ready copy in the library's serving storage")

  defp problem_label("profile_missing"), do: gettext("Storage configuration is missing")

  defp problem_label("changed_during_check"),
    do: gettext("File changed during verification; check it again")

  defp problem_label("copy_incomplete"),
    do: gettext("Copying or preview generation could not finish; waiting to retry")

  defp problem_label("missing"), do: gettext("Expected rendition is missing")
  defp problem_label("no_copy"), do: gettext("No stored copy is recorded")
  defp problem_label("stale"), do: gettext("Preview needs updating")
  defp problem_label("processing"), do: gettext("File is still processing")
  defp problem_label("failed"), do: gettext("Rendition processing failed")
  defp problem_label(_problem), do: gettext("Needs attention")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col gap-5">
      <div
        :if={@message}
        role="status"
        class={[
          "alert text-sm",
          if(elem(@message, 0) == :error, do: "alert-error", else: "alert-success")
        ]}
      >
        {elem(@message, 1)}
      </div>
      <div class="flex items-start justify-between gap-3">
        <div>
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-queue-list" class="size-5 text-primary" />{gettext("Library activity")}
          </h2>
          <p class="text-sm text-base-content/60">
            {gettext(
              "Follow verification, copying and storage updates. Open an operation to see its saved log."
            )}
          </p>
        </div>
        <button
          :if={@owned != []}
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="open_verify"
          phx-target={@myself}
        ><.icon name="hero-shield-check" class="size-4" />{gettext("Verify a library")}</button>
      </div>

      <.form
        :if={@show_verify and @owned != []}
        for={%{}}
        id={"#{@id}-verify"}
        phx-change="verification_change"
        phx-submit="start_verification"
        phx-target={@myself}
        class="rounded-lg border border-base-300 p-4 flex flex-col gap-4"
      >
        <h3 class="font-semibold">{gettext("Verify library")}</h3>
        <.select
          name="verification[library_uuid]"
          id={"#{@id}-library"}
          label={gettext("Library")}
          value={@selected_library}
          options={@library_choices}
          prompt={gettext("Choose a library")}
          required
        />
        <.select
          name="verification[mode]"
          id={"#{@id}-mode"}
          label={gettext("Check")}
          value={@mode}
          options={[
            {gettext("Availability — check that objects exist"), "presence"},
            {gettext("Deep verification — read copies and compare checksums"), "checksum"}
          ]}
        />
        <.checkbox
          name="verification[include_previews]"
          id={"#{@id}-previews"}
          label={gettext("Include generated previews")}
          checked={@include_previews}
        />
        <p class="text-sm text-base-content/60">
          {gettext(
            "Originals are checked by default. Deep verification downloads each stored copy and uses storage bandwidth. Verification reports problems without changing files or repairing copies. Uploads added after the check starts are included next time."
          )}
        </p>
        <p class="text-sm text-base-content/60">
          {gettext(
            "Only one verification can be active across all libraries, including paused checks. Each library can be checked once every 30 days. Cancelled and failed checks count toward this limit."
          )}
        </p>
        <p :if={@verification_limits.busy} role="status" class="text-sm text-warning">
          {verification_error(:verification_busy, nil)}
        </p>
        <p
          :if={next = @verification_limits.next_allowed[@selected_library]}
          role="status"
          class="text-sm text-warning"
        >
          {verification_error({:verification_cooldown, next}, nil)}
        </p>
        <div class="flex gap-2">
          <button
            class="btn btn-primary btn-sm"
            disabled={
              @verification_limits.busy or
                not is_nil(@verification_limits.next_allowed[@selected_library])
            }
            phx-disable-with={gettext("Starting…")}
          >{gettext("Start verification")}</button><button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="close_run"
            phx-target={@myself}
          >{gettext("Cancel")}</button>
        </div>
      </.form>

      <p
        :if={@activity.runs == []}
        class="rounded-lg border border-base-300 p-6 text-sm text-base-content/60"
      >
        {gettext(
          "No library operations yet. Verification and storage copy operations will appear here."
        )}
      </p>
      <.table_default :if={@activity.runs != []} id={"#{@id}-runs"}>
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{gettext("Library / operation")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Progress")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Started")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={run <- @activity.runs} id={"library-operation-#{run.uuid}"}>
            <.table_default_cell>
              <div class="font-medium">{@library_names[run.scope_uuid]}</div><div class="text-xs text-base-content/60">
                {operation(run.kind)}
              </div>
            </.table_default_cell>
            <.table_default_cell>
              <span class={["badge badge-sm", badge(run)]}>{state(run)}</span>
            </.table_default_cell>
            <.table_default_cell>
              <div class="text-sm">
                {gettext("%{done} of %{total} files",
                  done: run.done + run.failed_count,
                  total: run.total || "—"
                )}
              </div>
              <progress
                :if={run.total && run.total > 0}
                class="progress progress-primary h-1 w-28"
                value={min(run.done + run.failed_count, run.total)}
                max={run.total}
                aria-label={gettext("Operation progress")}
              />
              <div :if={run.failed_count > 0} class="text-xs text-warning">
                {gettext("%{count} need attention", count: run.failed_count)}
              </div>
            </.table_default_cell>
            <.table_default_cell class="text-xs text-base-content/60">
              {time(run.started_at || run.inserted_at)}
            </.table_default_cell>
            <.table_default_cell>
              <button
                type="button"
                class="btn btn-xs btn-ghost"
                phx-click="run_details"
                phx-value-uuid={run.uuid}
                phx-target={@myself}
              >{gettext("View log")}</button>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
      </.table_default>
      <div :if={@activity.pages > 1} class="flex items-center justify-end gap-3 text-sm">
        <button
          type="button"
          class="btn btn-xs"
          disabled={@activity.page <= 1}
          phx-click="activity_page"
          phx-value-page={@activity.page - 1}
          phx-target={@myself}
        >{gettext("Previous")}</button>
        <span>{gettext("Page %{page} of %{pages}", page: @activity.page, pages: @activity.pages)}</span>
        <button
          type="button"
          class="btn btn-xs"
          disabled={@activity.page >= @activity.pages}
          phx-click="activity_page"
          phx-value-page={@activity.page + 1}
          phx-target={@myself}
        >{gettext("Next")}</button>
      </div>

      <div :if={@run_uuid && !@logs} role="status" class="alert text-sm">
        {gettext(
          "This operation is no longer available, or you no longer have access to its library."
        )}
      </div>
      <.modal
        :if={@logs}
        id={"#{@id}-log"}
        show
        on_close="close_run"
        phx-target={@myself}
        max_width="3xl"
      >
        <:title><.icon name="hero-queue-list" class="size-5" />{gettext("Operation log")}</:title>
        <div class="flex flex-col gap-4">
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div>
              <h3 class="font-semibold">
                {@library_names[@logs.run.scope_uuid]} · {operation(@logs.run.kind)}
              </h3><span class={["badge badge-sm mt-1", badge(@logs.run)]}>{state(@logs.run)}</span>
            </div>
            <div class="flex flex-wrap gap-1">
              <button
                :for={action <- LibraryOperations.controls(@scope, @logs.run)}
                type="button"
                class="btn btn-xs btn-outline"
                phx-click="run_control"
                phx-value-uuid={@logs.run.uuid}
                phx-value-action={action}
                phx-target={@myself}
                data-confirm={
                  if action == "cancel",
                    do:
                      gettext("Stop this operation after its current batch? Completed work is kept."),
                    else: nil
                }
              >{control_label(action)}</button>
              <button
                type="button"
                class="btn btn-xs btn-ghost"
                phx-click="close_run"
                phx-target={@myself}
              >{gettext("Close")}</button>
            </div>
          </div>
          <p :if={@logs.run.kind == "storage.verify_library"} class="text-sm text-base-content/60">
            {if @logs.run.args["mode"] == "checksum",
              do: gettext("Deep checksum verification"),
              else: gettext("Availability verification")} · {if @logs.run.args["include_previews"],
              do: gettext("Originals and previews"),
              else: gettext("Originals only")}
          </p>
          <button
            :if={@logs.run.args["retry_of"]}
            type="button"
            class="link link-hover text-xs text-left"
            phx-click="run_details"
            phx-value-uuid={@logs.run.args["retry_of"]}
            phx-target={@myself}
          >{gettext("View the previous attempt")}</button>
          <p class="text-xs text-base-content/60">
            {gettext(
              "Logs are saved across reloads and restarts and follow the site's activity retention policy. Newest entries appear first."
            )}
          </p>
          <div
            :for={entry <- @logs.entries}
            id={"operation-log-#{entry.uuid}"}
            class="border-t border-base-300 pt-3 text-sm"
          >
            <div class="flex flex-wrap justify-between gap-2">
              <span class="font-medium">{event_label(entry.action)}</span><time class="text-xs text-base-content/60">{time(
                entry.inserted_at
              )}</time>
            </div>
            <div class="text-xs text-base-content/60">
              {if entry.actor, do: entry.actor.email, else: gettext("Automatic")}
            </div>
            <p :if={entry.action == "job.batch"} class="mt-1 text-base-content/70">
              {gettext("%{checked} checked · %{healthy} up to date · %{attention} need attention",
                checked: entry.metadata["checked"] || 0,
                healthy: entry.metadata["healthy"] || 0,
                attention: entry.metadata["needs_attention"] || 0
              )}
            </p>
            <ul :if={(entry.metadata["problems"] || []) != []} class="mt-2 space-y-2">
              <li :for={problem <- entry.metadata["problems"]} class="flex items-start gap-2 text-xs">
                <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0 mt-0.5 text-warning" />
                <div>
                  <span class="font-medium break-all">{@logs.names.files[problem["file_uuid"]] ||
                    gettext("File no longer available")}</span><span :if={problem["rendition"]}> · {problem[
                    "rendition"
                  ]}</span><span :if={problem["bucket_uuid"]}> · {@logs.names.buckets[
                    problem["bucket_uuid"]
                  ] || gettext("Bucket no longer available")}</span><div class="text-base-content/70">
                    {problem_label(problem["problem"])}
                  </div>
                </div>
              </li>
            </ul>
          </div>
          <div :if={@logs.pages > 1} class="flex items-center justify-end gap-3 text-sm">
            <button
              type="button"
              class="btn btn-xs"
              disabled={@logs.page <= 1}
              phx-click="log_page"
              phx-value-page={@logs.page - 1}
              phx-target={@myself}
            >{gettext("Newer")}</button>
            <span>{gettext("Page %{page} of %{pages}", page: @logs.page, pages: @logs.pages)}</span>
            <button
              type="button"
              class="btn btn-xs"
              disabled={@logs.page >= @logs.pages}
              phx-click="log_page"
              phx-value-page={@logs.page + 1}
              phx-target={@myself}
            >{gettext("Older")}</button>
          </div>
        </div>
      </.modal>
    </div>
    """
  end
end
