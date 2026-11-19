defmodule PhoenixKitWeb.Components.MediaCanvasViewerEmbedOptionsTest do
  @moduledoc """
  The viewer's side of the two embedding options of `MediaBrowser` that act on
  it, and of `own_files_only` for drawings. No database: what needs one lives
  in `test/integration/phoenix_kit_web/components/media_canvas_viewer_own_files_test.exs`.

  * `comments` (default `true`) — `false` takes the discussion out of the
    viewer: no thread in the sidebar, no reply popup, no Reply / View buttons
    and no counts on the shapes, and the Reply event is refused on the server.
  * `own_files_only` — a drawing on a file someone else uploaded is not
    writable; the check answers before it reaches the database.
  """
  use ExUnit.Case, async: true

  import PhoenixKitWeb.MediaCanvasViewerFixtures

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @shape_uuid "0190aaaa-bbbb-7000-8000-00000000c0de"

  defp row do
    %{
      annotation: %{
        uuid: @shape_uuid,
        kind: "rectangle",
        geometry: %{},
        style: %{},
        metadata: %{},
        title: nil,
        inserted_at: ~U[2026-05-19 12:00:00Z],
        creator_uuid: nil
      },
      first_comment: %{
        content: "Looks good",
        author: "Jane",
        thumbnail_url: nil,
        has_attachment: false
      },
      comment_count: 3,
      master_comment_uuid: nil
    }
  end

  describe "curate_row/2 (what the shapes carry to the tooltip)" do
    test "with comments on, the preview, the count and the badge are there" do
      meta = MediaCanvasViewer.curate_row(row(), true).metadata

      assert meta["comment_count"] == 3
      assert meta["comment_text"] == "Looks good"
      assert meta["comment_author"] == "Jane"
      assert meta["badge"] == 3
    end

    test "with comments off there is nothing of the discussion on the shape" do
      meta = MediaCanvasViewer.curate_row(row(), false).metadata

      # `comment_count` present is what makes the tooltip offer Reply / View.
      for key <- ~w(comment_count comment_text comment_author comment_thumbnail_url
                    comment_has_attachment comment_created_at badge) do
        refute Map.has_key?(meta, key), "#{key} leaked onto the shape"
      end
    end

    test "the default is with comments" do
      assert MediaCanvasViewer.curate_row(row()).metadata["comment_count"] == 3
    end
  end

  describe "the discussion's markup" do
    defp replying(overrides) do
      Map.merge(
        %{
          current_user: %{uuid: "01900000-0000-7000-8000-0000000000aa", email: "a@example.com"},
          replying_annotation_uuid: @shape_uuid,
          reply_parent_uuid: nil
        },
        overrides
      )
    end

    # The popup holds a stateful component (`AnnotationComposer`), which
    # `rendered_to_string/1` cannot turn into HTML outside a LiveView — it
    # raises naming the component. So "the popup is drawn" is asserted as
    # exactly that raise: the branch was taken. (The sidebar's thread needs the
    # Comments package, which core does not depend on; it is gated by the same
    # `assigns[:comments] != false` and is traced by hand in the report.)
    test "default: the reply popup branch is taken for the shape being replied to" do
      assert_raise ArgumentError, ~r/AnnotationComposer/, fn -> render_html(replying(%{})) end
    end

    test "comments: true is the default spelled out" do
      assert_raise ArgumentError, ~r/AnnotationComposer/, fn ->
        render_html(replying(%{comments: true}))
      end
    end

    test "comments: false draws no reply popup" do
      html = render_html(replying(%{comments: false}))

      refute html =~ "annotation-composer-popover-"
      refute html =~ "Reply to this annotation"
    end
  end

  describe "annotation_reply with comments off" do
    defp reply_socket(assigns) do
      %Phoenix.LiveView.Socket{
        assigns:
          Map.merge(
            %{
              __changed__: %{},
              can_annotate: true,
              comments: false,
              current_user: %{uuid: "01900000-0000-7000-8000-0000000000aa"},
              file: %{file_uuid: file_uuid()},
              replying_annotation_uuid: nil,
              reply_parent_uuid: nil,
              viewer_annotations: [%{uuid: @shape_uuid, kind: "rectangle", metadata: %{}}]
            },
            assigns
          )
      }
    end

    test "is refused before anything is looked up or written" do
      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "annotation_reply",
          %{"uuid" => @shape_uuid},
          reply_socket(%{})
        )

      assert socket.assigns.replying_annotation_uuid == nil
      assert socket.assigns.reply_parent_uuid == nil
    end
  end

  describe "annotation_row_writable?/2 under own_files_only" do
    @me "01900000-0000-7000-8000-0000000000aa"
    @someone_else "01900000-0000-7000-8000-0000000000bb"

    test "a file someone else uploaded is not writable" do
      row = %Storage.File{user_uuid: @someone_else}

      refute MediaCanvasViewer.annotation_row_writable?(row, %{own_files_only: @me})
    end

    test "a file with no uploader is not writable either" do
      refute MediaCanvasViewer.annotation_row_writable?(%Storage.File{user_uuid: nil}, %{
               own_files_only: @me
             })
    end
  end
end
