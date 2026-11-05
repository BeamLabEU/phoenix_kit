defmodule PhoenixKitWeb.Test.AudioRecorderHostLive do
  @moduledoc """
  Stand-in for a page with `<.audio_recorder>`, backing
  test/integration/phoenix_kit_web/components/audio_recorder_test.exs.

  The session decides what the page passes: `"test_pid"` gets every message, and
  `"attrs"` goes to the recorder as it is. `portal` defaults to `false` here, because
  `file_input/4` cannot reach into a portal. With `"consumer"` set the recorder sits
  in `Consumer`, a LiveComponent, which is what `target={@myself}` is for. Not routed;
  rendered with `Phoenix.LiveViewTest.live_isolated/3`.
  """
  use Phoenix.LiveView

  import PhoenixKitWeb.Components.Core.AudioRecorder, only: [audio_recorder: 1]

  defmodule Consumer do
    @moduledoc false
    use Phoenix.LiveComponent

    import PhoenixKitWeb.Components.Core.AudioRecorder, only: [audio_recorder: 1]

    @impl true
    def update(%{audio_recorded: delivered}, socket) do
      send(socket.assigns.test_pid, {:consumer, :audio_recorded, delivered})
      {:ok, socket}
    end

    def update(%{audio_recorder_error: delivered}, socket) do
      send(socket.assigns.test_pid, {:consumer, :audio_recorder_error, delivered})
      {:ok, socket}
    end

    def update(assigns, socket), do: {:ok, assign(socket, assigns)}

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <.audio_recorder id="nested" portal={false} errors={:notify} target={@myself} />
      </div>
      """
    end
  end

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       test_pid: session["test_pid"],
       attrs: Map.merge(%{id: "rec", portal: false}, session["attrs"] || %{}),
       consumer: session["consumer"] == true,
       busy: false
     ), layout: false}
  end

  @impl true
  def handle_info(:toggle_busy, socket), do: {:noreply, update(socket, :busy, &(!&1))}

  def handle_info(message, socket) do
    send(socket.assigns.test_pid, message)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.live_component :if={@consumer} module={Consumer} id="consumer" test_pid={@test_pid} />
      <.audio_recorder :if={!@consumer} busy={@busy} {@attrs} />
    </div>
    """
  end
end
