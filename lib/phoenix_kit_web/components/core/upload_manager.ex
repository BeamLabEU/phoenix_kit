defmodule PhoenixKitWeb.Components.Core.UploadManager do
  @moduledoc """
  An upload manager for any LiveView upload: a queue that sends a few files at
  a time, a live readout, and controls for each file.

  LiveView's uploader starts every picked file at once, so a hundred files is a
  hundred simultaneous transfers. The manager takes the files first and hands
  them over a few at a time:

    * **Auto concurrency.** One file goes first, alone, to measure the
      connection. The manager then adds a transfer at a time while the total
      speed keeps rising, up to `max_concurrent`, and backs off when another
      transfer stops helping.
    * **A panel** with how many files are in flight, the total speed, the time
      left, how many are done, and every file with what it is doing.
    * **Per-file controls:** pause / resume, skip / restore, move to the front,
      cancel, retry a failed one. And pause all / cancel all.

  Pausing a file that is already sending stops it and sends it again from the
  start when resumed (LiveView's upload channel cannot resume); a file still
  waiting is simply held.

  ## Using it

      # mount
      socket
      |> allow_upload(:photos, accept: :any, max_entries: 100, auto_upload: true,
           progress: &handle_progress/3)
      |> PhoenixKitWeb.Components.Core.UploadManager.attach()

      # template
      <.upload_manager id="photo-uploads" upload={@uploads.photos} max_concurrent={5} />

  That renders the drop zone and the panel. Consume the finished entries in
  the `progress:` callback as usual (`consume_uploaded_entry/3`); the manager
  counts an entry as done when it is consumed. `attach/1` handles the cancel
  button for every upload on the page with a hook, so the LiveView needs no
  event of its own.

  Inside a LiveComponent, or anywhere an event must go to a particular
  target, name it: `cancel_target={@myself}` and `cancel_event="cancel_upload"`
  (the event receives `%{"ref" => ref, "name" => upload_name}`, and must call
  `cancel_upload/3`).

  ## Attributes

    * `upload` (required) — the upload config, `@uploads.name`
    * `id` (required) — a unique DOM id
    * `max_concurrent` — the most files sent at once (default 5, at most 20);
      `1` sends strictly one at a time
    * `layout` — `:floating` (a card fixed to the corner of the screen, the
      default) or `:inline` (in place, where the component is rendered)
    * `dropzone` — render a drop zone and the file input (default `true`).
      `false` when the page already has a `<.live_file_input>` for this upload
      and the manager should take the files that arrive there
    * `resumable` — `true` when the upload names
      `external: PhoenixKitWeb.ResumableUpload.external()`. Files then travel in
      chunks the server keeps: pause stops a file where it is and resume goes
      on from there, and a lost connection or a reloaded page carries on instead
      of starting over. See `PhoenixKitWeb.ResumableUpload`.
    * `scope` — where the manager listens for the files that reach the upload
      input: `"self"` (this component's own wrapper, the default when it
      renders the drop zone), `"parent"` (the element the component is placed
      in, the default without a drop zone: for a page whose own input sits
      beside it) or a CSS selector
    * `cancel_event`, `cancel_target` — see above
    * `class` — extra classes for the panel
    * `accept_description`, `max_size_description` — hints under the drop zone

  ## Taking it to another project

  The manager is two files and nothing else: this module (it needs only
  `Phoenix.Component`, a gettext backend and the `icon/1` component) and
  `priv/static/assets/phoenix_kit_upload_manager.js`, which registers the hook
  `UploadManager` in `window.PhoenixKitHooks`. The script knows nothing about
  the page: everything it learns about an upload it reads from the
  `data-pk-upload-entry` rows rendered here.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  alias Phoenix.LiveView

  @default_max_concurrent 5
  @hard_cap 20
  @cancel_event "pk_upload_cancel"

  attr :id, :string, required: true
  attr :upload, :any, required: true
  attr :max_concurrent, :integer, default: @default_max_concurrent
  attr :layout, :atom, default: :floating, values: [:floating, :inline]
  attr :dropzone, :boolean, default: true
  attr :scope, :string, default: nil

  attr :resumable, :boolean,
    default: false,
    doc:
      "the upload names `external: PhoenixKitWeb.ResumableUpload.external()`: pausing keeps a file's place and a lost connection carries on"

  attr :cancel_event, :string, default: @cancel_event
  attr :cancel_target, :any, default: nil
  attr :accept_description, :string, default: nil
  attr :max_size_description, :string, default: nil
  attr :icon, :string, default: "hero-cloud-arrow-up"
  attr :class, :any, default: nil, doc: "extra classes for the panel"

  def upload_manager(assigns) do
    assigns =
      assigns
      |> assign(:max, clamp(assigns.max_concurrent))
      |> assign(:scope, assigns.scope || if(assigns.dropzone, do: "self", else: "parent"))
      |> assign(:labels, labels())
      |> assign(:entries_id, assigns.id <> "-entries")

    ~H"""
    <%!-- One wrapper around the parts, laid out as if it were not there. It is
         what `scope="self"` means: the element the manager listens on when the
         drop zone and the file input are its own. --%>
    <div id={@id <> "-wrap"} class="contents">
      <div :if={@dropzone} class="space-y-3">
        <div
          class="border-2 border-dashed border-base-300 rounded-lg p-8 text-center transition-colors cursor-pointer hover:border-primary hover:bg-primary/5"
          phx-drop-target={@upload.ref}
          id={@id <> "-dropzone"}
        >
          <label for={@upload.ref} class="cursor-pointer block">
            <div class="flex flex-col items-center gap-2">
              <.icon name={@icon} class="w-8 h-8 text-primary" />
              <div>
                <p class="font-semibold text-base-content">
                  {gettext("Drag files here or click to browse")}
                </p>
                <p class="text-sm text-base-content/70 mt-1">
                  {@accept_description || gettext("Drop your files to upload")}
                </p>
              </div>
            </div>
          </label>
          <.live_file_input upload={@upload} class="hidden" />
        </div>
        <p :if={@max_size_description} class="text-sm text-base-content/70 text-center">
          {gettext("Maximum file size: %{size}", size: @max_size_description)}
        </p>
      </div>

      <%!-- What LiveView says about each entry, for the script to read. Patched
         by LiveView like any markup; the panel below is not. --%>
      <div id={@entries_id} class="hidden" aria-hidden="true">
        <span
          :for={entry <- @upload.entries}
          id={"#{@entries_id}-#{entry.ref}"}
          data-pk-upload-entry
          data-ref={entry.ref}
          data-key={client_key(entry)}
          data-size={entry.client_size}
          data-progress={entry.progress}
          data-done={to_string(entry.done?)}
          data-error={entry_errors(@upload, entry)}
        ></span>
      </div>

      <div
        id={@id}
        phx-hook="UploadManager"
        phx-update="ignore"
        hidden
        data-upload-ref={@upload.ref}
        data-upload-name={@upload.name}
        data-max={@max}
        data-resumable={to_string(@resumable)}
        data-entries={@entries_id}
        data-scope={@scope}
        data-cancel-event={@cancel_event}
        data-cancel-target={target_selector(@cancel_target)}
        data-labels={Jason.encode!(@labels)}
        class={[
          @layout == :floating &&
            "fixed bottom-4 right-4 z-[1000] w-[min(26rem,calc(100vw-2rem))] shadow-2xl",
          @layout == :inline && "w-full",
          @class
        ]}
      >
        <div class="rounded-box border border-base-300 bg-base-100">
          <div class="flex items-center gap-2 border-b border-base-200 px-3 py-2">
            <div class="min-w-0 flex-1" role="status" aria-live="polite">
              <p class="truncate text-sm font-semibold" data-role="summary"></p>
              <p class="truncate text-xs tabular-nums text-base-content/60" data-role="detail"></p>
            </div>
            <button
              type="button"
              data-act="collapse"
              aria-expanded="true"
              class="btn btn-ghost btn-xs btn-circle"
              title={gettext("Show or hide the list")}
              aria-label={gettext("Show or hide the list")}
            >
              <.icon name="hero-chevron-up-down" class="h-4 w-4" />
            </button>
          </div>

          <progress
            class="progress progress-primary h-1 w-full rounded-none"
            data-role="total"
            value="0"
            max="1"
          ></progress>

          <div class="flex flex-wrap items-center gap-1 px-3 py-1.5 text-xs">
            <button type="button" data-act="pause-all" hidden class="btn btn-ghost btn-xs gap-1">
              <.icon name="hero-pause" class="h-3.5 w-3.5" /> {gettext("Pause all")}
            </button>
            <button type="button" data-act="resume-all" hidden class="btn btn-ghost btn-xs gap-1">
              <.icon name="hero-play" class="h-3.5 w-3.5" /> {gettext("Resume all")}
            </button>
            <button type="button" data-act="retry-failed" hidden class="btn btn-ghost btn-xs gap-1">
              <.icon name="hero-arrow-path" class="h-3.5 w-3.5" /> {gettext("Retry failed")}
            </button>
            <button
              type="button"
              data-act="cancel-all"
              hidden
              class="btn btn-ghost btn-xs gap-1 text-error"
            >
              <.icon name="hero-x-mark" class="h-3.5 w-3.5" /> {gettext("Cancel all")}
            </button>
            <button type="button" data-act="clear" hidden class="btn btn-ghost btn-xs gap-1">
              {gettext("Clear finished")}
            </button>
          </div>

          <ul data-role="list" class="max-h-64 divide-y divide-base-200 overflow-auto"></ul>

          <template data-role="row">
            <li class="flex items-center gap-2 px-3 py-2 data-[state=done]:opacity-60 data-[state=cancelled]:opacity-50">
              <div
                data-role="thumb"
                class="flex size-10 shrink-0 items-center justify-center overflow-hidden rounded bg-base-200 text-[10px] font-semibold uppercase text-base-content/50"
                aria-hidden="true"
              >
              </div>
              <div class="min-w-0 flex-1">
                <p class="truncate text-sm" data-role="name"></p>
                <progress
                  class="progress progress-primary h-1 w-full"
                  data-role="progress"
                  value="0"
                  max="100"
                ></progress>
                <p class="truncate text-xs tabular-nums text-base-content/60" data-role="status"></p>
              </div>
              <div class="flex shrink-0 items-center">
                <button
                  type="button"
                  data-act="prioritize"
                  class="btn btn-ghost btn-xs btn-circle"
                  title={gettext("Upload this next")}
                  aria-label={gettext("Upload this next")}
                >
                  <.icon name="hero-arrow-up-circle" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-act="pause"
                  class="btn btn-ghost btn-xs btn-circle"
                  title={gettext("Pause")}
                  aria-label={gettext("Pause")}
                >
                  <.icon name="hero-pause" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-act="resume"
                  class="btn btn-ghost btn-xs btn-circle"
                  title={gettext("Resume")}
                  aria-label={gettext("Resume")}
                >
                  <.icon name="hero-play" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-act="skip"
                  class="btn btn-ghost btn-xs btn-circle"
                  title={gettext("Skip")}
                  aria-label={gettext("Skip")}
                >
                  <.icon name="hero-forward" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-act="restore"
                  class="btn btn-ghost btn-xs btn-circle"
                  title={gettext("Add back")}
                  aria-label={gettext("Add back")}
                >
                  <.icon name="hero-arrow-uturn-left" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-act="retry"
                  class="btn btn-ghost btn-xs btn-circle"
                  title={gettext("Retry")}
                  aria-label={gettext("Retry")}
                >
                  <.icon name="hero-arrow-path" class="h-4 w-4" />
                </button>
                <button
                  type="button"
                  data-act="cancel"
                  class="btn btn-ghost btn-xs btn-circle text-error"
                  title={gettext("Cancel")}
                  aria-label={gettext("Cancel")}
                >
                  <.icon name="hero-x-mark" class="h-4 w-4" />
                </button>
              </div>
            </li>
          </template>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Handles the manager's cancel button for every upload of the LiveView, so the
  LiveView needs no event of its own. Call it in `mount/3`.

  The event carries the upload's name and the entry's ref; the name is matched
  against the uploads that are configured, never turned into an atom.
  """
  @spec attach(LiveView.Socket.t()) :: LiveView.Socket.t()
  def attach(socket) do
    LiveView.attach_hook(socket, :pk_upload_manager, :handle_event, &handle_cancel/3)
  end

  @doc false
  # Public so the event can be tested without a running LiveView.
  def __handle_cancel__(event, params, socket), do: handle_cancel(event, params, socket)

  defp handle_cancel(@cancel_event, %{"ref" => ref, "name" => name}, socket)
       when is_binary(ref) and is_binary(name) do
    case upload_key(socket, name) do
      nil -> {:halt, socket}
      key -> {:halt, safe_cancel(socket, key, ref)}
    end
  end

  defp handle_cancel(_event, _params, socket), do: {:cont, socket}

  # `cancel_upload/3` raises when the entry is already gone (it finished, or an
  # earlier cancel took) and EXITS when the entry's upload channel has just
  # ended — which would take the whole LiveView down with it. The manager asks
  # for a cancel on a timer and in bursts, so it meets both. Neither is a
  # reason to do anything: the entry is gone or going.
  defp safe_cancel(socket, key, ref) do
    LiveView.cancel_upload(socket, key, ref)
  rescue
    ArgumentError -> socket
  catch
    :exit, _reason -> socket
  end

  defp upload_key(socket, name) do
    case socket.assigns[:uploads] do
      %{} = uploads ->
        Enum.find(Map.keys(uploads), fn
          key when is_atom(key) -> Atom.to_string(key) == name and configured?(uploads[key])
          _ -> false
        end)

      _ ->
        nil
    end
  end

  defp configured?(%LiveView.UploadConfig{}), do: true
  defp configured?(_), do: false

  # The same three things the browser sends for a file, which is how the
  # script ties an entry back to the file it queued.
  @doc false
  def client_key(entry),
    do: "#{entry.client_name}|#{entry.client_size}|#{entry.client_last_modified}"

  defp entry_errors(upload, entry) do
    upload
    |> Phoenix.Component.upload_errors(entry)
    |> Enum.map_join(",", &to_string/1)
  end

  defp target_selector(nil), do: nil
  defp target_selector(%Phoenix.LiveComponent.CID{cid: cid}), do: to_string(cid)
  defp target_selector(target) when is_integer(target), do: Integer.to_string(target)
  defp target_selector(target) when is_binary(target), do: target
  defp target_selector(_), do: nil

  defp clamp(n) when is_integer(n), do: n |> max(1) |> min(@hard_cap)
  defp clamp(_), do: @default_max_concurrent

  # Every string the script shows, translated here and handed over once. The
  # ones with a `%{name}` in them are given their own placeholder back, so the
  # script can fill them in as the numbers change.
  defp labels do
    %{
      summary_active: gettext("%{done} of %{total} uploaded", done: "%{done}", total: "%{total}"),
      summary_finished:
        gettext("%{done} of %{total} uploaded", done: "%{done}", total: "%{total}"),
      at_once: gettext("%{count} at once", count: "%{count}"),
      eta: gettext("%{time} left", time: "%{time}"),
      measuring: gettext("measuring speed…"),
      auto: gettext("auto, up to %{max}", max: "%{max}"),
      paused_all: gettext("paused"),
      failed_count: gettext("Failed: %{count}", count: "%{count}"),
      st_queued: gettext("Waiting"),
      st_paused: gettext("Paused"),
      st_skipped: gettext("Skipped"),
      st_done: gettext("Uploaded"),
      st_cancelled: gettext("Cancelled"),
      st_failed: gettext("Failed"),
      st_reconnecting: gettext("Reconnecting…"),
      err_too_large: gettext("Larger than the upload limit"),
      err_not_accepted: gettext("Not accepted"),
      err_too_many_files: gettext("Too many files at once"),
      err_no_input: gettext("Nowhere to upload to"),
      err_stalled: gettext("Stopped sending"),
      err_external_client_failure: gettext("Connection lost. Retry to carry on."),
      err_unauthorized: gettext("Not allowed to upload")
    }
  end
end
