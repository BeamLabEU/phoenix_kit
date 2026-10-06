defmodule PhoenixKitWeb.Components.MediaViewerTest do
  @moduledoc """
  Unit tests for PhoenixKitWeb.Components.MediaViewer.

  Per-file content (canvas, annotations, sidebar) is delegated to
  `MediaCanvasViewer` — covered by integration tests against a real
  DB, not here. These tests focus on MediaViewer's surface:
  navigation state (`current_uuid`), event routing (close + step), and
  the notify hand-off.

  No DB required — `curate_file/1` calls catch
  `DBConnection.OwnershipError` and resolve to nil, which makes the
  render path early-return (no `<.live_component>` mounted). The
  navigation + close handlers don't touch the DB at all.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, except: [render: 1]

  alias PhoenixKitWeb.Components.MediaViewer

  @u1 "01900000-0000-7000-8000-000000000001"
  @u2 "01900000-0000-7000-8000-000000000002"
  @u3 "01900000-0000-7000-8000-000000000003"

  defp viewer_assigns(opts) do
    files = Keyword.get(opts, :files, [@u1, @u2, @u3])
    current = Keyword.get(opts, :current, @u1)

    %{
      id: "test-viewer",
      current_uuid: current,
      current_file: nil,
      current_user: nil,
      files: files,
      notify: Keyword.get(opts, :notify, nil),
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    }
  end

  defp render(assigns), do: rendered_to_string(MediaViewer.render(assigns))

  defp call(event, params, assigns) do
    socket = %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
    MediaViewer.handle_event(event, params, socket)
  end

  # Minimal socket for calling update/2 — no pre-existing assigns.
  defp fresh_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

  describe "update/2" do
    # Needs the repo process, which only runs when the test database is reachable.
    @tag :integration
    test "maps :current attr to :current_uuid assign" do
      {:ok, socket} =
        MediaViewer.update(
          %{id: "v1", current: @u2, files: [@u1, @u2], notify: nil},
          fresh_socket()
        )

      assert socket.assigns.current_uuid == @u2
    end

    @tag :integration
    test "stores :notify tuple in assigns" do
      notify = {__MODULE__, "my-id"}

      {:ok, socket} =
        MediaViewer.update(
          %{id: "v1", current: @u1, files: [@u1], notify: notify},
          fresh_socket()
        )

      assert socket.assigns.notify == notify
    end

    @tag :integration
    test "assign_new(:current_uuid) preserves navigated state on re-render" do
      # First update seeds current_uuid from :current
      {:ok, s1} =
        MediaViewer.update(
          %{id: "v1", current: @u1, files: [@u1, @u2], notify: nil},
          fresh_socket()
        )

      assert s1.assigns.current_uuid == @u1

      # Simulate user navigating to @u2 (step_viewer mutates current_uuid)
      s1_navigated = %{s1 | assigns: Map.put(s1.assigns, :current_uuid, @u2)}

      # Re-render with same :current — assign_new preserves the navigated state
      {:ok, s2} =
        MediaViewer.update(
          %{id: "v1", current: @u1, files: [@u1, @u2], notify: nil},
          s1_navigated
        )

      assert s2.assigns.current_uuid == @u2
    end

    @tag :integration
    test "current_file is nil when curate_file can't resolve (no DB / unknown uuid)" do
      {:ok, socket} =
        MediaViewer.update(
          %{id: "v1", current: @u1, files: [@u1], notify: nil},
          fresh_socket()
        )

      # No sandboxed connection in this test — curate_file's rescue
      # catches the OwnershipError and returns nil. The render path
      # then early-returns instead of mounting MediaCanvasViewer.
      assert socket.assigns.current_file == nil
    end
  end

  describe "single-root constraint (stateful component)" do
    # Phoenix LiveView raises ArgumentError at runtime when rendered.root != true
    # for stateful components with an id. This constraint is NOT caught by
    # rendered_to_string/1 — only by inspecting the Rendered struct directly.
    # Regression for: templates with <% %> expressions or text before root tag.
    test "rendered struct satisfies LiveView single-root requirement" do
      rendered = MediaViewer.render(viewer_assigns([]))

      assert rendered.root == true,
             "MediaViewer template violates single-root constraint (rendered.root=#{inspect(rendered.root)}). " <>
               "Ensure no <% %> expressions or other content appear before the root <dialog>."
    end
  end

  describe "render" do
    test "renders the <dialog> modal shell" do
      html = render(viewer_assigns(current: @u1))
      assert html =~ ~s(<dialog)
      assert html =~ "modal"
      assert html =~ "test-viewer"
    end

    test "shows the 'File not found' fallback when current_file is nil" do
      html = render(viewer_assigns(current: @u1))
      assert html =~ "File not found"
    end
  end

  describe "close" do
    test "close_viewer sends {MediaViewer, id, :closed} to self when notify is nil" do
      assigns = viewer_assigns(notify: nil)
      socket = %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
      MediaViewer.handle_event("close_viewer", %{}, socket)
      assert_received {PhoenixKitWeb.Components.MediaViewer, "test-viewer", :closed}
    end

    test "viewer_keydown Escape sends closed message when notify is nil" do
      assigns = viewer_assigns(notify: nil)
      socket = %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}
      MediaViewer.handle_event("viewer_keydown", %{"key" => "Escape"}, socket)
      assert_received {PhoenixKitWeb.Components.MediaViewer, "test-viewer", :closed}
    end

    test "viewer_keydown unknown key is a no-op (no close)" do
      assigns = viewer_assigns(notify: nil)
      {:noreply, socket} = call("viewer_keydown", %{"key" => "Tab"}, assigns)
      assert socket.assigns.current_uuid == @u1
      refute_received {PhoenixKitWeb.Components.MediaViewer, _, _}
    end
  end

  describe "stepping" do
    @tag :integration
    test "step_viewer next advances current_uuid" do
      {:noreply, socket} = call("step_viewer", %{"dir" => "next"}, viewer_assigns(current: @u1))
      assert socket.assigns.current_uuid == @u2
    end

    @tag :integration
    test "step_viewer prev goes back" do
      {:noreply, socket} = call("step_viewer", %{"dir" => "prev"}, viewer_assigns(current: @u2))
      assert socket.assigns.current_uuid == @u1
    end

    test "step_viewer next at the last image is a no-op" do
      {:noreply, socket} = call("step_viewer", %{"dir" => "next"}, viewer_assigns(current: @u3))
      assert socket.assigns.current_uuid == @u3
    end

    @tag :integration
    test "ArrowRight steps forward, ArrowLeft steps back" do
      {:noreply, s1} =
        call("viewer_keydown", %{"key" => "ArrowRight"}, viewer_assigns(current: @u1))

      assert s1.assigns.current_uuid == @u2

      {:noreply, s2} =
        call("viewer_keydown", %{"key" => "ArrowLeft"}, viewer_assigns(current: @u2))

      assert s2.assigns.current_uuid == @u1
    end
  end
end
