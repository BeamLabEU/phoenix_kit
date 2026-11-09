defmodule PhoenixKitWeb.Components.Core.AudioRecorderTest do
  @moduledoc """
  The server half of `<.audio_recorder>`: the clip a page gets, and every way one is
  refused. The hook itself is covered by test/js/audio_recorder.test.cjs.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias Phoenix.LiveView.JS
  alias PhoenixKitWeb.Components.Core.AudioRecorder
  alias PhoenixKitWeb.Test.AudioRecorderHostLive, as: Host

  # What the hook's `encodeWav` writes, at 32 000 bytes a second.
  defp wav(seconds) do
    size = trunc(seconds * 32_000)

    <<"RIFF", 36 + size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
      16_000::little-32, 32_000::little-32, 2::little-16, 16::little-16, "data", size::little-32,
      :binary.copy(<<0>>, size)::binary>>
  end

  defp host(conn, session \\ %{}) do
    session = Map.put(session, "test_pid", self())
    {:ok, view, html} = live_isolated(conn, Host, session: session)
    {view, html}
  end

  defp upload(view, name, type, content, id \\ "rec") do
    view
    |> file_input("##{id}-upload", "audio_recorder_#{id}", [
      %{name: name, type: type, content: content}
    ])
    |> render_upload(name)
  end

  defp wav_input(view, id \\ "rec", seconds \\ 1.0) do
    file_input(view, "##{id}-upload", "audio_recorder_#{id}", [
      %{name: "clip.wav", type: "audio/wav", content: wav(seconds)}
    ])
  end

  # What the browser sends first, before any bytes: the form's `phx-change`.
  defp validate(view, name, type, content) do
    upload =
      file_input(view, "#rec-upload", "audio_recorder_rec", [
        %{name: name, type: type, content: content}
      ])

    view |> element("#rec-upload") |> render_change(upload)
  end

  defp alert(view) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("[role=alert]")
  end

  describe "a clip" do
    test "reaches the page, read from the bytes", %{conn: conn} do
      {view, _html} = host(conn)
      bytes = wav(2.5)

      upload(view, "clip.wav", "audio/wav", bytes)

      assert_receive {:audio_recorded, "rec", clip}
      assert %{format: "wav", content_type: "audio/wav", duration: 2.5} = clip
      assert clip.data == bytes
      assert_push_event(view, "audio_recorder_settled", %{id: "rec"})
    end

    test "a second clip works after the first", %{conn: conn} do
      {view, _html} = host(conn)

      upload(view, "clip.wav", "audio/wav", wav(1.0))
      assert_receive {:audio_recorded, "rec", %{duration: 1.0}}

      upload(view, "clip.wav", "audio/wav", wav(2.0))
      assert_receive {:audio_recorded, "rec", %{duration: 2.0}}
    end

    # `update/2` runs on every render of the page, and `allow_upload/3` raises on an
    # upload with entries: a page setting `busy` while a clip uploads is exactly that.
    test "a re-render of the page during an upload leaves it alone", %{conn: conn} do
      {view, _html} = host(conn)

      input = wav_input(view)

      render_upload(input, "clip.wav", 50)
      send(view.pid, :toggle_busy)
      assert render(view) =~ ~s(data-busy="true")

      render_upload(input, "clip.wav", 50)
      assert_receive {:audio_recorded, "rec", %{format: "wav", duration: 1.0}}
    end

    test "the WAV's own length wins over what the browser says", %{conn: conn} do
      {view, _html} = host(conn)

      view |> element("#rec-recorder") |> render_hook("recorder_clip", %{duration: 99})
      upload(view, "clip.wav", "audio/wav", wav(1.0))

      assert_receive {:audio_recorded, "rec", %{duration: 1.0}}
    end

    test "two recorders on a page each deliver under their own id", %{conn: conn} do
      {view, _html} = host(conn, %{"second" => true})

      upload(view, "clip.wav", "audio/wav", wav(1.0), "rec")
      upload(view, "clip.wav", "audio/wav", wav(2.0), "other")

      assert_receive {:audio_recorded, "rec", %{duration: 1.0}}
      assert_receive {:audio_recorded, "other", %{duration: 2.0}}
    end

    # An upload's name belongs to the LiveView, not the component: a recorder that
    # starts under a name another still uploads with raises in the page's process.
    test "two recorders on a page can send at the same moment", %{conn: conn} do
      {view, _html} = host(conn, %{"second" => true})

      first = wav_input(view, "rec", 1.0)
      second = wav_input(view, "other", 2.0)

      render_upload(first, "clip.wav", 50)
      render_upload(second, "clip.wav", 50)
      render_upload(first, "clip.wav", 50)
      render_upload(second, "clip.wav", 50)

      assert_receive {:audio_recorded, "rec", %{duration: 1.0}}
      assert_receive {:audio_recorded, "other", %{duration: 2.0}}
    end
  end

  describe "an upload that does not finish" do
    # Each step puts the hook's watchdog back: a slow upload is not a dead one.
    test "each step tells the hook it is alive", %{conn: conn} do
      {view, _html} = host(conn)

      view |> wav_input() |> render_upload("clip.wav", 50)

      assert_push_event(view, "audio_recorder_progress", %{id: "rec"})
    end

    # The hook gave up and said so: the clip must not reach the page after that.
    test "one the hook gave up on never reaches the page", %{conn: conn} do
      {view, _html} = host(conn)
      view |> wav_input() |> render_upload("clip.wav", 50)
      view |> element("#rec-recorder") |> render_hook("recorder_error", %{reason: "failed"})

      assert LazyHTML.text(alert(view)) == AudioRecorder.error_message(:failed)

      # One clip at a time: a next one goes through only if that entry is gone.
      upload(view, "clip.wav", "audio/wav", wav(2.0))
      assert_receive {:audio_recorded, "rec", %{duration: 2.0}}
      refute_received {:audio_recorded, "rec", %{duration: 1.0}}
    end

    # A failed write leaves the entry unfinished: only the progress callback hears of it.
    test "one the server could not write is reported and ended", %{conn: conn} do
      {view, _html} = host(conn)

      view |> wav_input() |> render_upload("clip.wav", 50)
      assert_push_event(view, "audio_recorder_progress", %{id: "rec"})

      [channel] = view.pid |> :sys.get_state() |> Map.fetch!(:upload_pids) |> Map.keys()
      send(view.pid, {:phoenix, :report_writer_error, channel, :enospc})

      assert_push_event(view, "audio_recorder_settled", %{id: "rec"})
      assert LazyHTML.text(alert(view)) == AudioRecorder.error_message(:failed)
      refute_received {:audio_recorded, _id, _clip}
    end
  end

  describe "format={:native}" do
    setup %{conn: conn} do
      # Also the regression: `.ogg` in `accept` raised when the component mounted.
      {view, _html} = host(conn, %{"attrs" => %{format: :native, max_seconds: 60}})
      %{view: view}
    end

    for {name, type, bytes, format} <- [
          {"clip.webm", "audio/webm", <<0x1A, 0x45, 0xDF, 0xA3, 1, 2, 3>>, "webm"},
          {"clip.ogg", "audio/ogg", "OggS" <> <<0, 2, 0>>, "ogg"},
          {"clip.mp4", "audio/mp4", <<0, 0, 0, 28>> <> "ftypM4A ", "mp4"}
        ] do
      test "reads #{format} from the bytes", %{view: view} do
        upload(view, unquote(name), unquote(type), unquote(bytes))

        assert_receive {:audio_recorded, "rec", clip}
        assert clip.format == unquote(format)
        assert clip.content_type == "audio/" <> unquote(format)
        assert clip.data == unquote(bytes)
      end
    end

    test "believes the bytes over the name and the type", %{view: view} do
      upload(view, "clip.webm", "audio/webm", "OggS" <> <<0, 2, 0>>)

      assert_receive {:audio_recorded, "rec", %{format: "ogg"}}
    end

    test "takes the browser's duration, within max_seconds", %{view: view} do
      bytes = "OggS" <> <<0, 2, 0>>

      view |> element("#rec-recorder") |> render_hook("recorder_clip", %{duration: 12.44})
      upload(view, "clip.ogg", "audio/ogg", bytes)
      assert_receive {:audio_recorded, "rec", %{duration: 12.4}}

      view |> element("#rec-recorder") |> render_hook("recorder_clip", %{duration: 9_999})
      upload(view, "clip.ogg", "audio/ogg", bytes)
      assert_receive {:audio_recorded, "rec", %{duration: 60.0}}
    end

    test "has no duration when the browser's is not a number", %{view: view} do
      view |> element("#rec-recorder") |> render_hook("recorder_clip", %{duration: "long"})
      upload(view, "clip.ogg", "audio/ogg", "OggS" <> <<0, 2, 0>>)

      assert_receive {:audio_recorded, "rec", %{duration: nil}}
    end

    test "refuses audio it does not recognise", %{view: view} do
      upload(view, "clip.webm", "audio/webm", "not audio at all")

      refute_received {:audio_recorded, _id, _clip}
      assert LazyHTML.text(alert(view)) == AudioRecorder.error_message(:unreadable)
      assert_push_event(view, "audio_recorder_settled", %{id: "rec"})
    end
  end

  describe "a clip that is not what it claims" do
    test "a WAV with no samples: the page gets no clip", %{conn: conn} do
      {view, _html} = host(conn)

      upload(view, "clip.wav", "audio/wav", wav(0))

      refute_received {:audio_recorded, _id, _clip}
      assert LazyHTML.text(alert(view)) == AudioRecorder.error_message(:unreadable)
    end

    for {label, bytes} <- [
          {"is not a WAV", "this is not audio"},
          {"is cut short", "RIFF"}
        ] do
      test "#{label}: the page gets no clip", %{conn: conn} do
        {view, _html} = host(conn)

        upload(view, "clip.wav", "audio/wav", unquote(bytes))

        refute_received {:audio_recorded, _id, _clip}
        assert LazyHTML.text(alert(view)) == AudioRecorder.error_message(:unreadable)
        assert_push_event(view, "audio_recorder_settled", %{id: "rec"})
      end
    end

    test "a length in the header that the samples do not match", %{conn: conn} do
      {view, _html} = host(conn)

      upload(view, "clip.wav", "audio/wav", binary_part(wav(1.0), 0, 1_000))

      refute_received {:audio_recorded, _id, _clip}
      assert LazyHTML.text(alert(view)) == AudioRecorder.error_message(:unreadable)
    end

    test "a WAV of another rate", %{conn: conn} do
      {view, _html} = host(conn)
      <<head::binary-size(24), _rate::binary-size(4), rest::binary>> = wav(1.0)

      upload(view, "clip.wav", "audio/wav", head <> <<44_100::little-32>> <> rest)

      refute_received {:audio_recorded, _id, _clip}
    end
  end

  describe "the upload limit" do
    test "a clip over it never reaches the page, and says why", %{conn: conn} do
      {view, _html} = host(conn, %{"attrs" => %{max_seconds: 1}})

      # Over (1 + 5) seconds of WAV, with the slack the timer needs.
      validate(view, "clip.wav", "audio/wav", wav(7.0))

      refute_received {:audio_recorded, _id, _clip}
      assert LazyHTML.text(alert(view)) == AudioRecorder.error_message(:too_large)
      assert_push_event(view, "audio_recorder_settled", %{id: "rec"})
    end

    test "a clip that ran a little over max_seconds is still fine", %{conn: conn} do
      {view, _html} = host(conn, %{"attrs" => %{max_seconds: 1}})

      upload(view, "clip.wav", "audio/wav", wav(1.2))

      assert_receive {:audio_recorded, "rec", %{duration: 1.2}}
    end

    test "another kind of file is refused", %{conn: conn} do
      {view, _html} = host(conn)

      validate(view, "clip.exe", "application/octet-stream", "x")

      refute_received {:audio_recorded, _id, _clip}
      assert LazyHTML.text(alert(view)) == AudioRecorder.error_message(:unreadable)
    end
  end

  describe "errors" do
    test "are shown under the button, translated, and clear at the next recording", %{conn: conn} do
      {view, _html} = host(conn)
      recorder = element(view, "#rec-recorder")

      render_hook(recorder, "recorder_error", %{reason: "denied"})
      assert LazyHTML.text(alert(view)) == AudioRecorder.error_message(:denied)
      refute_received {:audio_recorder_error, _id, _reason}

      render_hook(recorder, "recorder_started", %{})
      assert Enum.empty?(alert(view))
    end

    test "with errors={:notify} go to the page and show nothing", %{conn: conn} do
      {view, _html} = host(conn, %{"attrs" => %{errors: :notify}})

      view |> element("#rec-recorder") |> render_hook("recorder_error", %{reason: "denied"})

      assert_receive {:audio_recorder_error, "rec", :denied}
      assert Enum.empty?(alert(view))
    end

    test "a reason the browser may not send is not taken at its word", %{conn: conn} do
      {view, _html} = host(conn, %{"attrs" => %{errors: :notify}})
      recorder = element(view, "#rec-recorder")

      render_hook(recorder, "recorder_error", %{reason: "too_large"})
      assert_receive {:audio_recorder_error, "rec", :unavailable}

      render_hook(recorder, "recorder_error", %{reason: "<script>"})
      assert_receive {:audio_recorder_error, "rec", :unavailable}

      render_hook(recorder, "recorder_error", %{})
      assert_receive {:audio_recorder_error, "rec", :unavailable}
    end

    test "every reason has a message" do
      for reason <- [:denied, :unavailable, :unreadable, :too_large, :failed] do
        assert AudioRecorder.error_message(reason) =~ ~r/\w/
      end
    end
  end

  describe "inside a LiveComponent" do
    test "the clip and the errors arrive through update/2", %{conn: conn} do
      {view, _html} = host(conn, %{"consumer" => true})

      upload(view, "clip.wav", "audio/wav", wav(1.0), "nested")
      assert_receive {:consumer, :audio_recorded, {"nested", %{format: "wav", duration: 1.0}}}
      refute_received {:audio_recorded, _id, _clip}

      view |> element("#nested-recorder") |> render_hook("recorder_error", %{reason: "denied"})
      assert_receive {:consumer, :audio_recorder_error, {"nested", :denied}}
    end
  end

  describe "markup" do
    test "stays hidden until the hook has found a way to record", %{conn: conn} do
      {_view, html} = host(conn)
      recorder = html |> LazyHTML.from_fragment() |> LazyHTML.query("#rec-recorder")

      assert LazyHTML.attribute(recorder, "hidden") == [""]
      assert LazyHTML.attribute(recorder, "phx-hook") == ["AudioRecorder"]
      assert LazyHTML.attribute(recorder, "phx-update") == ["ignore"]
      # What `render_hook/3` routes on; a browser finds the component from the DOM.
      assert [_cid] = LazyHTML.attribute(recorder, "phx-target")
    end

    test "the label goes on the button, translated by default", %{conn: conn} do
      {_view, html} = host(conn, %{"attrs" => %{label: "Say it instead"}})
      assert html =~ "Say it instead"

      {_view, html} = host(conn)
      assert html =~ "Record"
    end

    # A browser drops a form nested in another, and a page puts this in its own.
    test "by default the upload form goes through a portal", %{conn: conn} do
      {_view, html} = host(conn, %{"shipped_defaults" => true})
      template = html |> LazyHTML.from_fragment() |> LazyHTML.query("template[data-phx-portal]")

      assert LazyHTML.attribute(template, "data-phx-portal") == ["body"]
      assert LazyHTML.to_html(template) =~ ~s(id="rec-upload")
    end
  end

  describe "started from the page's own button" do
    test "start/2 dispatches to the recorder, and chains" do
      assert %JS{ops: [["dispatch", dispatch]]} = AudioRecorder.start("voice")
      assert dispatch == %{event: "phoenix_kit:audio_recorder_start", to: "#voice-recorder"}

      chained = JS.push("close_menu") |> AudioRecorder.start("voice")
      assert length(chained.ops) == 2
    end

    test "without a start button there is no button of its own", %{conn: conn} do
      {_view, html} = host(conn, %{"attrs" => %{start_button: false}})
      recorder = html |> LazyHTML.from_fragment() |> LazyHTML.query("#rec-recorder")

      assert LazyHTML.attribute(recorder, "data-start-button") == ["false"]
      assert recorder |> LazyHTML.query("[data-recorder-start]") |> Enum.count() == 0
      # Send and Cancel are still there for the recording itself.
      assert recorder |> LazyHTML.query("[data-recorder-send]") |> Enum.count() == 1
    end

    test "with one, by default", %{conn: conn} do
      {_view, html} = host(conn)
      recorder = html |> LazyHTML.from_fragment() |> LazyHTML.query("#rec-recorder")
      assert LazyHTML.attribute(recorder, "data-start-button") == ["true"]
      assert recorder |> LazyHTML.query("[data-recorder-start]") |> Enum.count() == 1
    end
  end

  describe "into the page's own upload" do
    test "points the hook at that upload, with no upload or form of its own", %{conn: conn} do
      {view, html} = host(conn, %{"page_upload" => true})
      doc = LazyHTML.from_fragment(html)
      recorder = LazyHTML.query(doc, "#into-recorder")
      input = LazyHTML.query(doc, "#page-form input[type=file]")

      assert LazyHTML.attribute(recorder, "data-upload-ref") == LazyHTML.attribute(input, "id")
      assert LazyHTML.attribute(recorder, "data-upload-name") == ["attachment"]
      assert LazyHTML.attribute(recorder, "data-upload-form") == []
      assert doc |> LazyHTML.query("#into-upload") |> Enum.count() == 0
      assert doc |> LazyHTML.query("#into-portal") |> Enum.count() == 0

      # The page's button starts it.
      assert view |> element("#page-record") |> render() =~ "phoenix_kit:audio_recorder_start"
    end

    test "a clip lands in the page's upload like any picked file", %{conn: conn} do
      {view, _html} = host(conn, %{"page_upload" => true})

      view
      |> file_input("#page-form", :attachment, [
        %{name: "recording-2026-11-06-203005.webm", type: "audio/webm", content: "webm"}
      ])
      |> render_upload("recording-2026-11-06-203005.webm")

      assert [%{client_name: "recording-2026-11-06-203005.webm", done?: true}] =
               :sys.get_state(view.pid).socket.assigns.uploads.attachment.entries

      refute_received {:audio_recorded, "into", _clip}
    end

    test "a recorder error leaves the page's files alone", %{conn: conn} do
      {view, _html} = host(conn, %{"page_upload" => true})

      view
      |> file_input("#page-form", :attachment, [
        %{name: "notes.pdf", type: "application/pdf", content: "%PDF"}
      ])
      |> render_upload("notes.pdf")

      view |> element("#into-recorder") |> render_hook("recorder_error", %{"reason" => "denied"})

      assert [%{client_name: "notes.pdf"}] =
               :sys.get_state(view.pid).socket.assigns.uploads.attachment.entries

      assert render(view) =~ AudioRecorder.error_message(:denied)
    end
  end
end
