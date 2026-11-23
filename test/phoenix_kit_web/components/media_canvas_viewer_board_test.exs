defmodule PhoenixKitWeb.Components.MediaCanvasViewerBoardTest do
  @moduledoc """
  The viewer's board mode (V183): a `:board` target instead of a file
  renders an empty Fresco scene with the Etcher tools, persists shapes
  against the target pair, and touches none of the file-only machinery.
  """

  use PhoenixKit.DataCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Annotations
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @board_uuid "01900000-0000-7000-8000-00000000b0a1"

  defp board_assigns(extra \\ %{}) do
    Map.merge(
      %{
        id: "board-" <> @board_uuid,
        file: nil,
        board: %{
          target_type: "projects_whiteboard",
          target_uuid: @board_uuid,
          width: 1600,
          height: 900,
          background: nil
        },
        current_user: nil,
        parent_id: "host",
        viewer_only: true
      },
      extra
    )
  end

  test "renders an empty infinite canvas with the drawing tools and no file chrome" do
    html = render_component(MediaCanvasViewer, board_assigns())

    assert html =~ ~s(id="media-zoom-#{@board_uuid}")
    assert html =~ ~s(data-canvas-width="1600")
    assert html =~ ~s(data-canvas-height="900")
    assert html =~ ~s(data-infinite-canvas="true")
    refute html =~ "data-fresco-canvas-img"
    assert html =~ "EtcherTooltipActions"
    # No file: no sidebar, no close button, no rotation, no comments.
    refute html =~ "close_viewer"
    refute html =~ "media-comments-"
  end

  test "keeps the single-root contract in board mode" do
    assigns =
      board_assigns(%{
        viewer_canvas: nil,
        viewer_annotations: [],
        etcher_colors: [],
        etcher_line_params: %{},
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      })

    assert MediaCanvasViewer.render(assigns).root == true
  end

  test "a malformed board renders nothing rather than an orphan canvas" do
    html =
      render_component(
        MediaCanvasViewer,
        board_assigns(%{board: %{target_type: "file", target_uuid: @board_uuid}})
      )

    refute html =~ "media-zoom-"
  end

  test "hydrates the board's own shapes and none of a file's" do
    {:ok, mine} =
      Annotations.create(%{
        target_type: "projects_whiteboard",
        target_uuid: @board_uuid,
        kind: "rectangle",
        geometry: %{"x" => 1, "y" => 2, "w" => 3, "h" => 4},
        title: "Island"
      })

    {:ok, _other} =
      Annotations.create(%{
        target_type: "projects_whiteboard",
        target_uuid: UUIDv7.generate(),
        kind: "line",
        geometry: %{"path" => [[0, 0], [1, 1]]}
      })

    html = render_component(MediaCanvasViewer, board_assigns())
    assert html =~ mine.uuid
    assert html =~ "Island"
    refute html =~ ~s("badge":1)
  end

  test "a read-only viewer (can_annotate: false) gets locked shapes, no tools, no pencil" do
    {:ok, mine} =
      Annotations.create(%{
        target_type: "projects_whiteboard",
        target_uuid: @board_uuid,
        kind: "rectangle",
        geometry: %{"x" => 1, "y" => 2, "w" => 3, "h" => 4}
      })

    html = render_component(MediaCanvasViewer, board_assigns(%{can_annotate: false}))

    # The shape still renders — locked (Etcher's readonly flag rides the wire map).
    assert html =~ mine.uuid
    assert html =~ ~s(readonly)
    # No drawing toolbar, no pencil in the nav column, no tools at all.
    assert html =~ ~s(data-toolbar="false")
    assert html =~ ~s(data-tools="[]")
    # Only the visibility toggle in the nav column — no pencil.
    assert html =~ ~s(data-nav-buttons="visibility")

    # The default keeps every existing host as it was: both buttons (nil →
    # no attribute), the toolbar, the tools, nothing locked.
    html = render_component(MediaCanvasViewer, board_assigns(%{current_user: register!()}))
    refute html =~ ~s(data-toolbar="false")
    refute html =~ ~s(data-nav-buttons=)
    refute html =~ ~s(readonly)
    assert html =~ ~s(rectangle)
  end

  test "nobody signed in gets a read-only viewer, whatever can_annotate says" do
    {:ok, shape} =
      Annotations.create(%{
        target_type: "projects_whiteboard",
        target_uuid: @board_uuid,
        kind: "rectangle",
        geometry: %{"x" => 1, "y" => 2, "w" => 3, "h" => 4}
      })

    html =
      render_component(MediaCanvasViewer, board_assigns(%{current_user: nil, can_annotate: true}))

    assert html =~ shape.uuid
    assert html =~ ~s(data-toolbar="false")
    assert html =~ ~s(data-tools="[]")
    assert html =~ ~s(readonly)
  end

  defp register! do
    {:ok, user} =
      Auth.register_user(%{
        email: "board-viewer-#{System.unique_integer([:positive])}@example.com",
        password: "hello world!"
      })

    user
  end
end
