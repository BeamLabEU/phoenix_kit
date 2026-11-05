defmodule PhoenixKitWeb.Components.Core.AudioRecorder do
  @moduledoc """
  Records from the microphone and gives the page the audio: a button, a timer,
  Send and Cancel, with the upload handled inside. The page needs no JavaScript,
  no hidden form and no `allow_upload`.

      <.audio_recorder
        id="inquiry-voice"
        format={:wav_16k}
        max_seconds={180}
        label={gettext("Say it instead")}
        busy={@transcribing}
      />

      def handle_info({:audio_recorded, "inquiry-voice", clip}, socket) do
        %{data: bytes, format: "wav", duration: 12.4} = clip
        ...
      end

  It only records. What happens to the audio is the page's business: nothing is
  stored, and there is no text area and no AI here.

  ## The clip

    * `:data`: the bytes.
    * `:format`: `"wav"`, `"webm"`, `"ogg"` or `"mp4"`, read from the bytes.
    * `:content_type`: `"audio/wav"` and so on, from the same reading.
    * `:duration`: seconds, to one decimal. For a WAV it comes from the bytes.
      For `:native` it is what the browser reports, capped at `max_seconds`, or
      `nil` without one: fine to show, not to bill by.

  The format comes from the file itself, not from what the browser said it was.
  A file that is not what the recorder asked for ends as `:unreadable`. A WAV is
  read whole. For `:native` that reading is the container's opening bytes, which
  name the format and prove nothing about what is inside: store such a clip the way
  you store any upload.

  ## Formats

    * `:wav_16k`: mono, 16 kHz, 16-bit PCM, made in the browser, about 32 kB a
      second. For speech-to-text: every speech model takes WAV, while WebM, which
      Chrome records, is often refused.
    * `:native`: whatever the browser's `MediaRecorder` makes, unconverted. For
      storing and playing back.

  `format` and `max_seconds` set the upload's limits the first time the component
  renders, so changing them later does not change those limits.

  ## Errors

  By default a problem is shown under the button, translated, until the next
  recording. With `errors={:notify}` nothing is shown and the page gets a message
  instead, so a page should only ask for it with a clause to take it:

      def handle_info({:audio_recorder_error, "inquiry-voice", reason}, socket)

  `error_message/1` gives the same translated text. The reasons:

    * `:denied`: the browser refused the microphone.
    * `:unavailable`: no microphone, or it could not be started.
    * `:unreadable`: the clip was empty, or could not be decoded or recognised.
    * `:too_large`: over the upload limit.
    * `:failed`: the clip never reached the server (the connection dropped).

  ## Inside a LiveComponent

  A LiveComponent has no `handle_info/2`, so pass `target={@myself}` and take the
  same payloads in `update/2`:

      def update(%{audio_recorded: {"inquiry-voice", clip}}, socket)
      def update(%{audio_recorder_error: {"inquiry-voice", reason}}, socket)

  ## Inside a form

  It can sit inside a page's `<form>`, under a text area for example. The upload
  needs a form of its own, and a browser drops a form nested in another, so that
  form goes through a `<.portal>` to the end of `body`. Two recorders on a page are
  fine too, sending at the same moment included. Each has an upload name of its own,
  because a LiveView raises when two components use one at once, and the hook uploads
  to its own form, by id, because `this.upload/2` searches the whole LiveView and
  drops a clip when it finds two inputs.

  `format`, `max_seconds` and `label` are read once, when the recorder first renders.

  ## Where it cannot work

  The recorder stays hidden without a secure context (plain HTTP on a LAN address)
  or without `getUserMedia` or `MediaRecorder`, and without Web Audio for
  `:wav_16k`. It is hidden too on a host still serving a `phoenix_kit.js` from
  before this component, until `mix phoenix_kit.update` copies the new one.

  `busy` only disables the button. A clip already being recorded still arrives, and
  a page that must refuse a second clip decides that when it gets one.

  ## Testing a page that uses it

  `file_input/4` cannot reach into a portal. Test the page through its contract:

      send(view.pid, {:audio_recorded, "inquiry-voice", %{data: wav, format: "wav", duration: 1.0}})

  A page that knows the recorder is outside any form can pass `portal={false}`.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  @type reason :: :denied | :unavailable | :unreadable | :too_large | :failed
  @type clip :: %{
          data: binary(),
          format: String.t(),
          content_type: String.t(),
          duration: float() | nil
        }

  # 16 000 samples a second, two bytes each.
  @wav_bytes_per_second 32_000
  @wav_header_bytes 44

  # A generous ceiling for what a browser's encoder makes: about 384 kbit/s, where
  # Opus and AAC speech run well under half of that.
  @native_bytes_per_second 48_000

  # The clip stops on a timer, so it can run slightly over `max_seconds`.
  @slack_seconds 5

  attr :id, :string, required: true, doc: "Names the recorder in the messages it sends."

  attr :format, :atom,
    default: :wav_16k,
    values: [:wav_16k, :native],
    doc: "`:wav_16k` for speech-to-text, `:native` for storing and playing back."

  attr :max_seconds, :integer,
    default: 180,
    doc: "Recording stops and sends at this length."

  attr :label, :string,
    default: nil,
    doc: "The start button; defaults to a translated \"Record\"."

  attr :busy, :boolean,
    default: false,
    doc: "Disables the start button, for example while the last clip is being read."

  attr :errors, :atom,
    default: :inline,
    values: [:inline, :notify],
    doc: "`:inline` shows a problem under the button, `:notify` sends it to the page."

  attr :target, :any,
    default: nil,
    doc: "A LiveComponent's `@myself`, to deliver through its `update/2`."

  attr :portal, :boolean,
    default: true,
    doc: "Moves the upload form to `body`, so the recorder can sit inside a form."

  attr :class, :any, default: nil

  @doc "The recorder. See the module documentation."
  def audio_recorder(assigns) do
    ~H"""
    <.live_component
      module={__MODULE__}
      id={@id}
      format={@format}
      max_seconds={@max_seconds}
      label={@label}
      busy={@busy}
      errors={@errors}
      target={@target}
      portal={@portal}
      class={@class}
    />
    """
  end

  @doc "The translated text for a reason, for a page that shows its own errors."
  @spec error_message(reason()) :: String.t()
  def error_message(:denied),
    do: gettext("Microphone access was refused. Allow it in your browser and try again.")

  def error_message(:unavailable), do: gettext("No microphone is available.")

  def error_message(:unreadable),
    do: gettext("The recording could not be read. Please try again.")

  def error_message(:too_large), do: gettext("The recording is too long.")
  def error_message(:failed), do: gettext("The recording could not be sent. Please try again.")

  @impl true
  def mount(socket) do
    {:ok, assign(socket, error: nil, client_duration: nil)}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> allow_once()}
  end

  # A LiveComponent is updated on every render of its parent, and an upload is
  # only allowed once. The name is this recorder's own: the LiveView holds a name for
  # as long as an entry uses it, and raises when another component starts an upload
  # under it, so two recorders sharing one take the page down when their clips overlap.
  defp allow_once(%{assigns: %{upload_name: _name}} = socket), do: socket

  defp allow_once(%{assigns: %{id: id, format: format, max_seconds: seconds}} = socket) do
    name = "audio_recorder_#{id}"

    socket
    |> assign(:upload_name, name)
    |> allow_upload(name,
      accept: accepted(format),
      max_entries: 1,
      max_file_size: max_bytes(format, seconds),
      auto_upload: true,
      progress: &handle_progress/3
    )
  end

  defp accepted(:wav_16k), do: ~w(.wav)
  # Not a list of extensions: `.ogg` has no MIME type here, and `allow_upload/3`
  # refuses those. `clip/3` reads the real format from the bytes anyway.
  defp accepted(:native), do: ~w(audio/*)

  defp max_bytes(:wav_16k, seconds),
    do: @wav_header_bytes + (seconds + @slack_seconds) * @wav_bytes_per_second

  defp max_bytes(:native, seconds), do: (seconds + @slack_seconds) * @native_bytes_per_second

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, refuse_invalid(socket)}

  def handle_event("recorder_started", _params, socket),
    do: {:noreply, assign(socket, :error, nil)}

  def handle_event("recorder_clip", params, socket) do
    {:noreply, assign(socket, :client_duration, client_duration(params, socket))}
  end

  # An upload still running is cancelled: the person has been told this clip failed,
  # so it must not reach the page after all.
  def handle_event("recorder_error", params, socket) do
    {:noreply, socket |> cancel_entries() |> report(client_reason(params))}
  end

  # A code from the browser, so only the ones it may send become reasons; `too_large`
  # is the server's own to decide.
  defp client_reason(%{"reason" => "denied"}), do: :denied
  defp client_reason(%{"reason" => "unreadable"}), do: :unreadable
  defp client_reason(%{"reason" => "failed"}), do: :failed
  defp client_reason(_params), do: :unavailable

  defp client_duration(%{"duration" => seconds}, %{assigns: %{max_seconds: max}})
       when is_number(seconds) and seconds >= 0,
       do: Float.round(min(seconds, max) / 1, 1)

  defp client_duration(_params, _socket), do: nil

  defp cancel_entries(%{assigns: %{upload_name: name, uploads: uploads}} = socket),
    do: Enum.reduce(uploads[name].entries, socket, &cancel_upload(&2, name, &1.ref))

  defp refuse_invalid(%{assigns: %{upload_name: name}} = socket) do
    config = socket.assigns.uploads[name]

    case Enum.find(config.entries, &(not &1.valid?)) do
      nil ->
        socket

      entry ->
        reason = if :too_large in upload_errors(config, entry), do: :too_large, else: :unreadable

        socket |> cancel_upload(name, entry.ref) |> report(reason) |> settled()
    end
  end

  # Each step tells the hook the upload is alive, so a slow one is not taken for a dead
  # one. An entry the server could not write stays unfinished, and only this says so.
  defp handle_progress(name, %{done?: false} = entry, socket) do
    case upload_errors(socket.assigns.uploads[name], entry) do
      [] ->
        {:noreply, push_event(socket, "audio_recorder_progress", %{id: socket.assigns.id})}

      _errors ->
        {:noreply, socket |> cancel_upload(name, entry.ref) |> report(:failed) |> settled()}
    end
  end

  defp handle_progress(_name, entry, socket) do
    bytes = consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

    {:noreply, socket |> deliver_clip(bytes) |> settled()}
  end

  defp deliver_clip(socket, bytes) do
    case clip(bytes, socket.assigns.format, socket.assigns.client_duration) do
      {:ok, clip} ->
        deliver(socket, :audio_recorded, clip)
        socket

      :error ->
        report(socket, :unreadable)
    end
  end

  # The header `toWav` in the hook writes, and nothing else: a clip of this
  # recorder has exactly this shape, and its length is in it.
  defp clip(
         <<"RIFF", _size::binary-size(4), "WAVE", "fmt ", 16::little-32, 1::little-16,
           1::little-16, 16_000::little-32, @wav_bytes_per_second::little-32, 2::little-16,
           16::little-16, "data", size::little-32, samples::binary>> = bytes,
         :wav_16k,
         _client_duration
       )
       when size > 0 and size == byte_size(samples) do
    duration = Float.round(size / @wav_bytes_per_second, 1)
    {:ok, %{data: bytes, format: "wav", content_type: "audio/wav", duration: duration}}
  end

  defp clip(<<0x1A, 0x45, 0xDF, 0xA3, _rest::binary>> = bytes, :native, duration),
    do: {:ok, %{data: bytes, format: "webm", content_type: "audio/webm", duration: duration}}

  defp clip(<<"OggS", _rest::binary>> = bytes, :native, duration),
    do: {:ok, %{data: bytes, format: "ogg", content_type: "audio/ogg", duration: duration}}

  defp clip(<<_size::binary-size(4), "ftyp", _rest::binary>> = bytes, :native, duration),
    do: {:ok, %{data: bytes, format: "mp4", content_type: "audio/mp4", duration: duration}}

  defp clip(_bytes, _format, _client_duration), do: :error

  defp report(%{assigns: %{errors: :notify}} = socket, reason) do
    deliver(socket, :audio_recorder_error, reason)
    socket
  end

  defp report(socket, reason), do: assign(socket, :error, reason)

  # A LiveComponent shares its LiveView's process, so `self()` is the page.
  defp deliver(%{assigns: %{target: nil, id: id}}, tag, payload),
    do: send(self(), {tag, id, payload})

  defp deliver(%{assigns: %{target: target, id: id}}, tag, payload),
    do: send_update(target, %{tag => {id, payload}})

  # Tells the hook this clip is over, whichever way it ended, so the spinner goes.
  defp settled(socket), do: push_event(socket, "audio_recorder_settled", %{id: socket.assigns.id})

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={@class}>
      <%!-- `phx-update="ignore"` keeps the state the hook shows; LiveView still
            updates `data-` attributes on it, which is how `busy` gets through. --%>
      <div
        id={"#{@id}-recorder"}
        phx-hook="AudioRecorder"
        phx-update="ignore"
        phx-target={@myself}
        data-recorder={@id}
        data-format={@format}
        data-busy={to_string(@busy)}
        data-max-seconds={@max_seconds}
        data-upload-form={"#{@id}-upload"}
        data-upload-name={@upload_name}
        hidden
      >
        <div data-recorder-state="idle">
          <button type="button" data-recorder-start class="btn btn-sm btn-outline">
            <.icon name="hero-microphone" class="size-4" /> {@label || gettext("Record")}
          </button>
        </div>
        <div data-recorder-state="recording" role="status" hidden>
          <div class="flex flex-wrap items-center gap-2">
            <span class="relative flex size-3" aria-hidden="true">
              <span class="absolute inline-flex size-full rounded-full bg-error opacity-75 animate-ping"></span>
              <span class="relative inline-flex size-3 rounded-full bg-error"></span>
            </span>
            <span class="text-sm whitespace-nowrap">
              {gettext("Recording")}
              <span data-recorder-time class="tabular-nums" aria-hidden="true">0:00</span>
            </span>
            <progress
              data-recorder-level
              class="progress progress-success w-16"
              max="100"
              value="0"
              aria-hidden="true"
            ></progress>
            <button type="button" data-recorder-send class="btn btn-sm btn-primary">
              <.icon name="hero-paper-airplane" class="size-4" /> {gettext("Send")}
            </button>
            <button type="button" data-recorder-cancel class="btn btn-sm btn-ghost">
              {gettext("Cancel")}
            </button>
          </div>
        </div>
        <div data-recorder-state="preparing" role="status" hidden>
          <div class="flex items-center gap-2 text-sm">
            <span class="loading loading-spinner loading-xs"></span> {gettext("Sending…")}
          </div>
        </div>
      </div>

      <p :if={@error} role="alert" class="mt-1 text-sm text-error">{error_message(@error)}</p>

      <.portal :if={@portal} id={"#{@id}-portal"} target="body">
        <.upload_form id={"#{@id}-upload"} upload={@uploads[@upload_name]} myself={@myself} />
      </.portal>
      <.upload_form
        :if={!@portal}
        id={"#{@id}-upload"}
        upload={@uploads[@upload_name]}
        myself={@myself}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :upload, :any, required: true
  attr :myself, :any, required: true

  # `phx-auto-recover="ignore"`: a reconnect has nothing to resend, and the clip of
  # an upload it interrupted is reported by the hook.
  defp upload_form(assigns) do
    ~H"""
    <form
      id={@id}
      phx-change="validate"
      phx-target={@myself}
      phx-auto-recover="ignore"
      class="hidden"
    >
      <.live_file_input upload={@upload} />
    </form>
    """
  end
end
