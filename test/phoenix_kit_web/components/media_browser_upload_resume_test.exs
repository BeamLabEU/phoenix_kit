defmodule PhoenixKitWeb.Components.MediaBrowserUploadResumeTest do
  @moduledoc """
  What the browser component answers when the UploadResume hook reports files
  a lost transfer left in the browser's stash: send them again (told to the
  hook, by key) unless the server has them, is receiving them, or has no room;
  list the rest with the Resume button.
  """

  use ExUnit.Case, async: false

  alias PhoenixKitWeb.Components.MediaBrowser
  alias PhoenixKitWeb.ResumableUpload

  @resume "phoenix_kit:upload-resume"
  @discard "phoenix_kit:upload-discard"

  setup do
    dir = Path.join(System.tmp_dir!(), "pk_resume_report_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:phoenix_kit, :resumable_upload_dir, dir)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :resumable_upload_dir)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      endpoint: PhoenixKitWeb.Endpoint,
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            id: "media",
            picker: false,
            readonly: false,
            upload_name: :media_files,
            upload_problems_session: [],
            upload_inbox_problems: [],
            parent_uploads: uploads([]),
            phoenix_kit_current_user: %{uuid: "u1"}
          },
          assigns
        ),
      private: %{live_temp: %{}}
    }
  end

  # The upload as the browser has it: resumable, as the media browser's own are.
  defp uploads(entries, max_entries \\ 10, external \\ ResumableUpload.external()) do
    %{media_files: %{entries: entries, max_entries: max_entries, external: external}}
  end

  # The marker `ResumableUpload.consume/3` leaves, written by hand.
  defp mark_taken(name, written_at \\ nil) do
    {:ok, meta, _} =
      ResumableUpload.external(base: "/up").(
        %{client_name: name, client_size: 5, client_last_modified: 7},
        socket()
      )

    path = Path.join(ResumableUpload.dir(), meta.id <> ".done")
    File.write!(path, "")
    if written_at, do: File.touch!(path, written_at)
  end

  defp report(socket, items) do
    {:noreply, socket} =
      MediaBrowser.handle_event("upload_resume_available", %{"items" => items}, socket)

    socket
  end

  defp item(name, extra \\ %{}) do
    Map.merge(%{"key" => "#{name}|5|7", "name" => name, "size" => 5, "blob" => true}, extra)
  end

  defp pushed(socket) do
    (socket.private.live_temp[:push_events] || [])
    |> Enum.reverse()
    |> Enum.map(fn [event, payload] -> {event, payload} end)
  end

  defp problems(socket), do: socket.assigns.upload_problems_session

  defp entry(name), do: %{client_name: name, client_size: 5, client_last_modified: 7}

  describe "auto (the default)" do
    test "files the browser holds are sent again, by key, with no row to click" do
      socket = report(socket(), [item("a.png"), item("b.png")])

      assert pushed(socket) == [{@resume, %{keys: ["a.png|5|7", "b.png|5|7"], auto: true}}]
      assert problems(socket) == []
    end

    test "a file too large to keep is listed to be added again, and not sent" do
      socket = report(socket(), [item("a.png"), item("huge.mov", %{"blob" => false})])

      assert pushed(socket) == [{@resume, %{keys: ["a.png|5|7"], auto: true}}]
      assert [%{client_key: "huge.mov|5|7", retry: false, kind: :browser}] = problems(socket)
    end

    test "a picker names itself, so the browser beside it does not act on it" do
      socket =
        report(socket(%{picker: true, id: "pick-1", picker_uploading: false}), [item("a.png")])

      assert pushed(socket) ==
               [{@resume, %{browser: "pick-1", keys: ["a.png|5|7"], auto: true}}]
    end

    test "what the hook could not send itself is listed with Resume, never pushed again" do
      socket = report(socket(), [item("a.png", %{"manual" => true})])

      assert pushed(socket) == []
      assert [%{client_key: "a.png|5|7", retry: true}] = problems(socket)
    end

    test "a file already listed, or already arriving, is left alone" do
      listed = %{client_key: "listed.png|5|7", key: "s-1"}

      socket =
        socket(%{
          upload_problems_session: [listed],
          parent_uploads: uploads([entry("coming.png")])
        })
        |> report([item("listed.png"), item("coming.png"), item("new.png")])

      assert pushed(socket) == [{@resume, %{keys: ["new.png|5|7"], auto: true}}]
      assert [^listed] = problems(socket)
    end

    test "no more than the upload has room for; the rest wait in the stash, with no row" do
      socket =
        socket(%{parent_uploads: uploads([entry("busy.png")], 3)})
        |> report([item("a.png"), item("b.png"), item("c.png")])

      assert pushed(socket) == [{@resume, %{keys: ["a.png|5|7", "b.png|5|7"], auto: true}}]
      assert problems(socket) == [], "the hook asks again when a batch ends"
    end

    test "with no room at all nothing is sent and nothing is listed" do
      socket =
        socket(%{parent_uploads: uploads([entry("busy.png")], 1)})
        |> report([item("a.png")])

      assert pushed(socket) == []
      assert problems(socket) == []
    end

    test "an upload that is not resumable asks, as :ask does: it has no record of what it took" do
      for external <- [false, fn _entry, socket -> {:ok, %{}, socket} end] do
        socket =
          socket(%{parent_uploads: uploads([], 10, external)})
          |> report([item("a.png")])

        assert pushed(socket) == []
        assert [%{client_key: "a.png|5|7", retry: true}] = problems(socket)
      end

      socket = report(socket(%{parent_uploads: nil}), [item("a.png")])
      assert pushed(socket) == []
      assert [%{client_key: "a.png|5|7"}] = problems(socket)
    end

    test "a marker older than the copy is not about it: a file picked again after it went" do
      two_days_ago = System.os_time(:second) - 2 * 86_400
      mark_taken("done.png", two_days_ago)
      one_day = 86_400_000

      socket = report(socket(), [item("done.png", %{"age_ms" => one_day})])

      assert pushed(socket) == [{@resume, %{keys: ["done.png|5|7"], auto: true}}]
    end

    test "a marker newer than the copy is: it was taken after the pick" do
      mark_taken("done.png")

      socket = report(socket(), [item("done.png", %{"age_ms" => 60_000})])

      assert pushed(socket) == [{@discard, %{keys: ["done.png|5|7"]}}]
    end

    test "a copy that does not say when it was picked is judged by any marker" do
      mark_taken("done.png", System.os_time(:second) - 2 * 86_400)

      socket = report(socket(), [item("done.png")])

      assert pushed(socket) == [{@discard, %{keys: ["done.png|5|7"]}}]
    end

    test "an age that makes no sense counts as none" do
      mark_taken("done.png")

      for age <- [-5, "soon", nil, 1.5] do
        socket = report(socket(), [item("done.png", %{"age_ms" => age})])
        assert pushed(socket) == [{@discard, %{keys: ["done.png|5|7"]}}], inspect(age)
      end
    end

    test "a file the server has already taken is let go of, not sent again" do
      mark_taken("done.png")

      socket = report(socket(), [item("done.png"), item("other.png")])

      assert pushed(socket) == [
               {@discard, %{keys: ["done.png|5|7"]}},
               {@resume, %{keys: ["other.png|5|7"], auto: true}}
             ]

      assert problems(socket) == []
    end

    test "the same file under another person is not taken" do
      mark_taken("done.png")

      socket = report(socket(%{phoenix_kit_current_user: %{uuid: "u2"}}), [item("done.png")])

      assert pushed(socket) == [{@resume, %{keys: ["done.png|5|7"], auto: true}}]
    end

    test "a name with the separator in it is told apart from its size and date" do
      name = "a|b.png"

      mark_taken(name)

      socket = report(socket(), [item(name)])
      assert pushed(socket) == [{@discard, %{keys: ["a|b.png|5|7"]}}]
    end

    test "a read-only browser sends nothing by itself" do
      socket = report(socket(%{readonly: true}), [item("a.png")])

      assert pushed(socket) == []
      assert [%{client_key: "a.png|5|7"}] = problems(socket)
    end
  end

  describe "upload_resume: :ask" do
    test "everything is listed with Resume and nothing is sent" do
      socket =
        socket(%{upload_resume: :ask})
        |> report([item("a.png"), item("huge.mov", %{"blob" => false})])

      assert pushed(socket) == []

      assert [
               %{client_key: "huge.mov|5|7", retry: false},
               %{client_key: "a.png|5|7", retry: true}
             ] =
               problems(socket)
    end

    test "a file the server has taken is still let go of" do
      mark_taken("done.png")

      socket = report(socket(%{upload_resume: :ask}), [item("done.png")])
      assert pushed(socket) == [{@discard, %{keys: ["done.png|5|7"]}}]
    end
  end

  describe "through the real upload path" do
    test "a file the browser's page took is discarded when a new page reports it" do
      user = %{uuid: "u1"}

      entry = %Phoenix.LiveView.UploadEntry{
        ref: "0",
        uuid: Ecto.UUID.generate(),
        upload_config: :media_files,
        done?: true,
        client_name: "fresh.png",
        client_type: "image/png",
        client_size: 5,
        client_last_modified: 7
      }

      upload_socket = socket(%{phoenix_kit_current_user: user})

      {:ok, meta, _} = ResumableUpload.external(base: "/up").(entry, upload_socket)
      File.mkdir_p!(Path.dirname(meta.path))
      File.write!(meta.path, "01234")

      conf = %Phoenix.LiveView.UploadConfig{
        name: :media_files,
        ref: "phx-media",
        external: true,
        entries: [entry],
        entry_refs_to_metas: %{"0" => meta}
      }

      upload_socket = put_in(upload_socket.assigns[:uploads], %{media_files: conf})
      on_exit(fn -> File.rm(Path.join(System.tmp_dir!(), "pk_upload_#{entry.uuid}")) end)

      # The old page: the server takes the file...
      {:noreply, _old_page} = MediaBrowser.parent_progress(:media_files, entry, upload_socket)
      refute File.exists?(meta.path), "the partial file went"

      # ...and the page that heard of it is gone. A new page finds the copy
      # in the browser's stash and reports it.
      reported = report(socket(), [item("fresh.png", %{"age_ms" => 30_000})])

      assert pushed(reported) == [{@discard, %{keys: ["fresh.png|5|7"]}}]
      assert problems(reported) == []
    end
  end

  test "a malformed report changes nothing" do
    socket = socket()
    assert {:noreply, ^socket} = MediaBrowser.handle_event("upload_resume_available", %{}, socket)

    socket = report(socket, [%{"name" => "no key"}, "junk", %{"key" => 5}])
    assert pushed(socket) == []
    assert problems(socket) == []
  end
end
