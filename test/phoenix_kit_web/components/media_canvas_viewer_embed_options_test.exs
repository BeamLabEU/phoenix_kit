defmodule PhoenixKitWeb.Components.MediaCanvasViewerEmbedOptionsTest do
  @moduledoc """
  The viewer's side of the two embedding options of `MediaBrowser` that act on
  it, and of `own_files_only` for drawings. No database: what needs one lives
  in `test/integration/phoenix_kit_web/components/media_canvas_viewer_own_files_test.exs`.

  * `comments` (default `true`) — `false` takes the discussion out of the
    viewer: no thread in the sidebar, no reply popup, no Reply / View buttons
    (the label stays editable) and no counts on the shapes, and the Reply
    event is refused on the server.
  * `own_files_only` — a drawing on a file someone else uploaded is not
    writable; the check answers before it reaches the database.
  """
  use ExUnit.Case, async: true

  import PhoenixKitWeb.MediaCanvasViewerFixtures

  alias Phoenix.LiveView.Utils, as: LiveUtils
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
      refute Map.has_key?(meta, "comments_off")
    end

    test "with comments off there is nothing of the discussion on the shape" do
      meta = MediaCanvasViewer.curate_row(row(), false).metadata

      # With no `comment_count` the tooltip has no Reply / View; `comments_off`
      # is what tells it the label is still there to edit.
      for key <- ~w(comment_count comment_text comment_author comment_thumbnail_url
                    comment_has_attachment comment_created_at badge) do
        refute Map.has_key?(meta, key), "#{key} leaked onto the shape"
      end

      assert meta["comments_off"] == true
    end

    test "with comments off a marker keeps its stored byline" do
      # `comment_author` of a marker is the stored name of whoever drew it, not
      # a thread: dropping it from the row would erase it on the next drag.
      stored = %{"comment_author" => "Jane"}
      row = put_in(row(), [:annotation, :metadata], stored)

      assert MediaCanvasViewer.curate_row(row, false).metadata["comment_author"] == "Jane"
    end

    test "the mark of comments off is not persisted with the row" do
      current = %{
        metadata: MediaCanvasViewer.curate_row(row(), false).metadata,
        geometry: %{},
        style: %{},
        kind: "rectangle"
      }

      refute Map.has_key?(
               MediaCanvasViewer.persistable_attrs(%{"metadata" => %{}}, current)["metadata"],
               "comments_off"
             )
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

    # The shape already has its thread (`master_comment_uuid`) and the file
    # has no uuid to look up, so an unguarded Reply opens the popup without
    # touching a database or the Comments package: the only thing that can
    # leave `replying_annotation_uuid` empty here is the refusal itself.
    defp threaded_socket(overrides) do
      reply_socket(
        Map.merge(
          %{
            file: %{file_uuid: nil},
            viewer_annotations: [
              %{
                uuid: @shape_uuid,
                kind: "rectangle",
                metadata: %{},
                master_comment_uuid: "01900000-0000-7000-8000-0000000000cc"
              }
            ]
          },
          overrides
        )
      )
    end

    test "the same Reply opens the popup when comments are on" do
      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "annotation_reply",
          %{"uuid" => @shape_uuid},
          threaded_socket(%{comments: true})
        )

      assert socket.assigns.replying_annotation_uuid == @shape_uuid
      assert socket.assigns.reply_parent_uuid == "01900000-0000-7000-8000-0000000000cc"
    end

    test "is refused before anything is looked up or written" do
      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "annotation_reply",
          %{"uuid" => @shape_uuid},
          threaded_socket(%{})
        )

      assert socket.assigns.replying_annotation_uuid == nil
      assert socket.assigns.reply_parent_uuid == nil
    end

    test "authors off refuses it as well: the thread is not shown, a reply could not be read back" do
      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "annotation_reply",
          %{"uuid" => @shape_uuid},
          reply_socket(%{comments: true, authors: false})
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

    test "a file of another library than the host's is not writable" do
      row = %Storage.File{user_uuid: @me, library_uuid: @someone_else}

      refute MediaCanvasViewer.annotation_row_writable?(row, %{write_library_uuid: @me})
    end

    test "a restricted viewer's file is not writable unless they uploaded it" do
      row = %Storage.File{user_uuid: @someone_else}

      refute MediaCanvasViewer.annotation_row_writable?(row, %{viewer_uuid: @me})
    end
  end

  describe "can_annotate: false, read at the moment of the event" do
    # What `MediaViewer` hands the child per file under `annotate_only`. The
    # events below run on a plain socket with no repo started: a write, or a
    # lookup of the file, would raise, so a clean return is a refusal.
    @mount_socket %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    defp mounted do
      {:ok, socket} = MediaCanvasViewer.mount(@mount_socket)
      socket
    end

    defp updated(socket, assigns) do
      {:ok, socket} =
        MediaCanvasViewer.update(Map.merge(%{id: "mcv-1", file: nil}, assigns), socket)

      socket
    end

    defp forged_annotation do
      %{"uuid" => @shape_uuid, "kind" => "rectangle", "geometry" => %{}, "style" => %{}}
    end

    test "a drawing sync is refused and nothing is stored" do
      known = [%{uuid: @shape_uuid, kind: "rectangle", geometry: %{}, style: %{}, metadata: %{}}]

      socket =
        mounted()
        |> updated(%{can_annotate: false})
        |> Phoenix.Component.assign(:file, %{file_uuid: file_uuid()})
        |> Phoenix.Component.assign(:viewer_annotations, known)

      # A wipe (the list sent back is empty) and an addition, both forged.
      for payload <- [[], [forged_annotation()], [forged_annotation(), %{"uuid" => "x"}]] do
        assert {:noreply, after_event} =
                 MediaCanvasViewer.handle_event(
                   "etcher:annotations-changed",
                   %{"annotations" => payload},
                   socket
                 )

        assert after_event.assigns.viewer_annotations == known
      end
    end

    test "update/2 works can_annotate out again every time, and the event follows it" do
      socket = updated(mounted(), %{can_annotate: true})
      assert socket.assigns.can_annotate == true

      # The host re-renders the child for a file outside its set.
      socket =
        updated(socket, %{
          can_annotate: false,
          current_user: %{uuid: "01900000-0000-7000-8000-0000000000aa"}
        })

      assert socket.assigns.can_annotate == false

      # A file and a shape the user could reply to, were it not refused: Reply
      # would look the file up (and raise here, no repo).
      socket =
        socket
        |> Phoenix.Component.assign(:file, %{file_uuid: file_uuid()})
        |> Phoenix.Component.assign(:viewer_annotations, [
          %{uuid: @shape_uuid, kind: "rectangle", metadata: %{}}
        ])

      assert {:noreply, ^socket} =
               MediaCanvasViewer.handle_event(
                 "etcher:annotations-changed",
                 %{"annotations" => [forged_annotation()]},
                 socket
               )

      assert {:noreply, ^socket} =
               MediaCanvasViewer.handle_event(
                 "annotation_reply",
                 %{"uuid" => @shape_uuid},
                 socket
               )
    end

    test "a shape's title edited from the thread is refused too" do
      socket = updated(mounted(), %{can_annotate: false})

      # With a writable file this would reach `persist_annotation_title/2`,
      # which writes through the repo and raises here.
      assert {:ok, ^socket} =
               MediaCanvasViewer.update(
                 %{action: :annotation_title_updated, metadata_value: @shape_uuid, label: "x"},
                 socket
               )
    end
  end

  describe "details: false (the sidebar)" do
    defp file_row do
      %{
        status: "active",
        edited?: false,
        updated_at: ~U[2026-06-01 12:00:00Z],
        inserted_at: ~U[2026-05-19 12:00:00Z],
        pages: nil,
        hdr: nil,
        uploader: "UploaderUniq",
        uuid: "0190ffff-0000-7000-8000-00000000f11e",
        extra: [%{label: "Source:", text: "ExtraUniq", href: nil}]
      }
    end

    defp sidebar(overrides) do
      render_html(
        Map.merge(
          %{
            sidebar_collapsed: false,
            media_details_open: true,
            media_meta: %{title: "TitleUniq", alt: "AltUniq", description: "DescUniq"},
            media_tags: ["TagUniq"],
            file_row: file_row(),
            file_exif: %{"camera" => %{"make" => "CameraUniq", "model" => "X1"}},
            file_geo: {nil, nil},
            exif_tags: nil,
            exif_status: nil,
            media_meta_langs: [],
            media_meta_values: %{},
            file_writable: true
          },
          overrides
        )
      )
    end

    defp text_of(html, selector) do
      html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
    end

    # Stored fields of the file row and its instances the sidebar prints.
    @stored ~w(TitleUniq DescUniq AltUniq TagUniq UploaderUniq ExtraUniq CameraUniq 0190ffff-0000-7000-8000-00000000f11e)

    test "default: the sidebar prints every one of them (the control)" do
      html = sidebar(%{})

      for text <- ~w(TitleUniq DescUniq AltUniq TagUniq UploaderUniq ExtraUniq) do
        assert html =~ text, "#{text} should be in the default sidebar"
      end

      assert text_of(html, "h2") =~ "test.jpg"
    end

    test "details: true is the default spelled out" do
      assert sidebar(%{details: true}) == sidebar(%{})
    end

    test "read-only: none of the stored fields is printed, the name and Download are" do
      html = sidebar(%{details: false})

      for text <- @stored, do: refute(html =~ text, "#{text} leaked into the sidebar")

      for label <- [
            "Type:",
            "MIME:",
            "Size:",
            "Dimensions:",
            "Uploaded:",
            "Uploaded by:",
            "Updated:",
            "Status:",
            "File UUID:",
            "Alt text",
            "Title &amp; description"
          ] do
        refute html =~ label, "#{label} is still in the sidebar"
      end

      assert text_of(html, "h2") =~ "test.jpg"
      assert html =~ ~s(href="/f/original.jpg")
      assert html =~ "Download"
    end

    test "with the editor on offer (details_path) it is gone as well, and so are the EXIF and the link" do
      html = sidebar(%{details_path: "/admin/media/x"})

      assert html =~ "CameraUniq"
      assert html =~ "/admin/media/x"

      html = sidebar(%{details_path: "/admin/media/x", details: false})

      for text <- @stored, do: refute(html =~ text, "#{text} leaked into the sidebar")
      refute html =~ "/admin/media/x"
      refute html =~ "media-exif-"
      refute html =~ "media-meta-form-"
      assert html =~ ~s(href="/f/original.jpg")
    end

    test "the name is the uploaded one, with or without a title: the title is never the name" do
      for meta <- [
            %{title: "TitleUniq", alt: "", description: ""},
            %{title: "", alt: "", description: ""}
          ] do
        html = sidebar(%{details: false, media_meta: meta})

        assert text_of(html, "h2") =~ "test.jpg"
        refute html =~ "TitleUniq"
      end
    end

    test "an audio card and a PDF frame carry the uploaded name, not the title" do
      audio = %{render_assigns(%{}).file | mime_type: "audio/mpeg", file_type: "audio"}
      pdf = %{render_assigns(%{}).file | mime_type: "application/pdf", file_type: "document"}

      for file <- [audio, pdf] do
        html = sidebar(%{file: file, details: false})

        refute html =~ "TitleUniq"
        assert html =~ "test.jpg"
      end
    end

    test "update/2 keeps the flag, and the default is on" do
      assert mounted().assigns.details == true
      assert updated(mounted(), %{details: false}).assigns.details == false
      assert updated(mounted(), %{}).assigns.details == true
    end

    test "the Download links name the file as it was uploaded, whatever is shown" do
      html = sidebar(%{details: false})

      assert html =~ ~s(download="test.jpg")
    end

    test "a file the viewer cannot preview: the card prints no type and no MIME type" do
      file = %{render_assigns(%{}).file | mime_type: "application/zip", file_type: "archive"}

      assert sidebar(%{file: file}) =~ "application/zip"
      assert sidebar(%{file: file}) =~ "ARCHIVE"

      html = sidebar(%{file: file, details: false})
      refute html =~ "application/zip"
      refute html =~ "ARCHIVE"
    end
  end

  describe "authors: false" do
    @author "AuthorUniq Jane"
    @stamped %{
      uuid: @shape_uuid,
      kind: "marker",
      geometry: %{"x" => 1, "y" => 2},
      style: nil,
      creator_uuid: "01900000-0000-7000-8000-0000000000cc",
      metadata: %{
        "title" => "Label stays",
        "comment_author" => @author,
        "comment_text" => "Looks good",
        "comment_count" => 1
      }
    }

    defp built(authors?) do
      file = render_assigns(%{}).file
      canvas = MediaCanvasViewer.build_viewer_canvas(file, [@stamped], false, authors?)
      [shape] = canvas.extensions["etcher"]["annotations"]
      {canvas, shape}
    end

    test "default: the shape carries the author's name (the control)" do
      {_canvas, shape} = built(true)

      assert shape["metadata"]["comment_author"] == @author
    end

    test "the shape's payload has no author, and keeps the label and the rest" do
      {canvas, shape} = built(false)

      refute inspect(canvas.extensions) =~ "AuthorUniq"
      refute inspect(canvas.extensions) =~ "01900000-0000-7000-8000-0000000000cc"
      refute Map.has_key?(shape["metadata"], "comment_author")
      assert shape["metadata"]["title"] == "Label stays"
      assert shape["metadata"]["comment_text"] == "Looks good"
      assert shape["geometry"] == %{"x" => 1, "y" => 2}
    end

    test "the rendered markup has no author name, with the author stamped on the row" do
      {canvas, _shape} = built(false)

      # The live layer, not the burned copy: that is where the shapes ride.
      live = %{burn_mode: false, burn_canvas: nil}

      refute render_html(Map.put(live, :viewer_canvas, canvas)) =~ "AuthorUniq"
      {with_author, _} = built(true)
      assert render_html(Map.put(live, :viewer_canvas, with_author)) =~ "AuthorUniq"
    end

    test "wire_metadata/2 drops only the byline" do
      meta = %{"comment_author" => @author, "title" => "t", "badge" => 2}

      assert MediaCanvasViewer.wire_metadata(meta, true) == meta
      assert MediaCanvasViewer.wire_metadata(meta, false) == %{"title" => "t", "badge" => 2}
      assert MediaCanvasViewer.wire_metadata(nil, false) == nil
    end

    test "the patch pushed to a drawn shape has no author either" do
      socket = Phoenix.Component.assign(mounted(), :authors, false)

      pushed =
        socket
        |> MediaCanvasViewer.patch_shape(file_uuid(), @stamped)
        |> LiveUtils.get_push_events()

      assert [["etcher:patch-shape", payload]] = pushed
      assert payload.uuid == @shape_uuid
      refute inspect(payload) =~ "AuthorUniq"
      assert payload.metadata["title"] == "Label stays"

      [["etcher:patch-shape", default]] =
        mounted()
        |> MediaCanvasViewer.patch_shape(file_uuid(), @stamped)
        |> LiveUtils.get_push_events()

      assert default.metadata["comment_author"] == @author
    end

    test "update/2 keeps the flag, and the default is on" do
      assert mounted().assigns.authors == true
      assert updated(mounted(), %{authors: false}).assigns.authors == false
      assert updated(mounted(), %{}).assigns.authors == true
    end
  end
end
