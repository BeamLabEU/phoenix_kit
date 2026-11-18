defmodule PhoenixKitWeb.Components.MediaCanvasViewerOfflineTest do
  @moduledoc """
  Offline annotating (`config :phoenix_kit, offline_annotations: true`,
  `PhoenixKit.Offline`): the switch, the worker core serves for Etcher, and
  what the media viewer hands Etcher so a file annotated online opens and
  saves with no connection.

  `async: false`: the switch is application env, global to the VM.
  """
  use ExUnit.Case, async: false

  import PhoenixKitWeb.MediaCanvasViewerFixtures
  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [get_resp_header: 2]

  alias PhoenixKitWeb.Components.MediaCanvasViewer

  setup do
    previous = Application.fetch_env(:phoenix_kit, :offline_annotations)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :offline_annotations, value)
        :error -> Application.delete_env(:phoenix_kit, :offline_annotations)
      end
    end)
  end

  describe "the switch" do
    test "off unless the host turns it on, and only a literal true does" do
      Application.delete_env(:phoenix_kit, :offline_annotations)
      refute PhoenixKit.Offline.enabled?()

      Application.put_env(:phoenix_kit, :offline_annotations, "true")
      refute PhoenixKit.Offline.enabled?()

      Application.put_env(:phoenix_kit, :offline_annotations, true)
      assert PhoenixKit.Offline.enabled?()
    end

    test "the worker has one URL, with no locale in it" do
      assert PhoenixKit.Offline.worker_url() =~ ~r{/assets/etcher-offline-sw\.js$}
      refute PhoenixKit.Offline.worker_url() =~ ~r"/[a-z]{2}/assets/"
    end
  end

  describe "the worker" do
    defp get_worker do
      conn(:get, "/assets/etcher-offline-sw.js", %{})
      |> PhoenixKitWeb.AssetsController.serve(%{"file" => "etcher-offline-sw.js"})
    end

    test "is Etcher's, served so the browser keeps it current and may widen its scope" do
      Application.put_env(:phoenix_kit, :offline_annotations, true)
      conn = get_worker()

      assert conn.status == 200
      assert conn.resp_body == Etcher.offline_worker()
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/javascript"
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert get_resp_header(conn, "service-worker-allowed") == ["/"]
    end

    test "is not there while offline annotating is off" do
      Application.delete_env(:phoenix_kit, :offline_annotations)
      assert get_worker().status == 404
    end
  end

  describe "the viewer" do
    test "off: nothing offline in the markup" do
      Application.delete_env(:phoenix_kit, :offline_annotations)
      html = render_html(%{burn_canvas: nil, burn_version: nil})
      refute html =~ "data-offline"
    end

    test "on: an annotator's layer keeps this file offline, its comments protected" do
      Application.put_env(:phoenix_kit, :offline_annotations, true)
      html = render_html(%{burn_canvas: nil, burn_version: nil})

      assert [_, key] = Regex.run(~r/data-offline-key="([^"]+)"/, html)
      assert "file:" <> _uuid = key
      assert html =~ ~s(data-offline-sw="#{PhoenixKit.Offline.worker_url()}")
      # A shape with a comment thread is never deleted by an offline device.
      assert html =~ ~s(data-offline-protect="comment_count")
      # The area Etcher copies while annotating, and where the copy goes when
      # the page opens with no connection.
      assert html =~ ~s(data-offline-root="media")
      assert html =~ ~s(data-offline-slot="media")
    end

    test "on: a read-only viewer keeps nothing — there is nothing to save" do
      Application.put_env(:phoenix_kit, :offline_annotations, true)
      html = render_html(%{burn_canvas: nil, burn_version: nil, can_annotate: false})
      refute html =~ "data-offline"
    end

    test "offline_key/2: per file, annotators only" do
      Application.put_env(:phoenix_kit, :offline_annotations, true)
      assert MediaCanvasViewer.offline_key(%{can_annotate: true}, %{file_uuid: "f1"}) == "file:f1"
      assert MediaCanvasViewer.offline_key(%{can_annotate: false}, %{file_uuid: "f1"}) == nil
      assert MediaCanvasViewer.offline_key(%{can_annotate: true}, nil) == nil

      Application.delete_env(:phoenix_kit, :offline_annotations)
      assert MediaCanvasViewer.offline_key(%{can_annotate: true}, %{file_uuid: "f1"}) == nil
    end
  end
end
