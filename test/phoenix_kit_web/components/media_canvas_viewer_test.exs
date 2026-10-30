defmodule PhoenixKitWeb.Components.MediaCanvasViewerTest do
  @moduledoc """
  Render-shape tests for `MediaCanvasViewer`. The full per-event +
  per-helper coverage requires a real DB (annotation persistence,
  comment-thread refresh, etc.) so it lives in the integration suite.

  This file covers the contracts the LiveView runtime enforces at
  render time — specifically the single-static-root-tag constraint
  that stateful components must satisfy, which `rendered_to_string/1`
  does NOT surface. Regression for the runtime crash that happens
  when a `<% %>` expression or other content appears before the root
  tag.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @file_uuid "01900000-0000-7000-8000-000000000001"

  defp render_assigns do
    %{
      id: "canvas-test",
      file: %{
        file_uuid: @file_uuid,
        filename: "test.jpg",
        file_type: "image",
        mime_type: "image/jpeg",
        size: 1024,
        inserted_at: ~U[2026-05-19 12:00:00Z],
        width: 800,
        height: 600,
        urls: %{}
      },
      # current_user=nil short-circuits the comments-thread branch
      # (no PhoenixKitComments.enabled?() DB call), and viewer_canvas=nil
      # gates out the Fresco.canvas mount.
      current_user: nil,
      parent_id: "media-browser-test",
      has_prev: false,
      has_next: false,
      viewer_canvas: nil,
      composing_annotation_uuid: nil,
      viewer_annotations: [],
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    }
  end

  describe "single-root constraint (stateful component)" do
    # Phoenix LiveView raises ArgumentError at render time when
    # rendered.root != true for a stateful component (one with an id).
    # rendered_to_string/1 doesn't surface this — only inspecting the
    # Rendered struct directly does. Regression for: templates with
    # `<% %>` expressions or other content before the root <div>.
    test "rendered struct satisfies LiveView single-root requirement" do
      rendered = MediaCanvasViewer.render(render_assigns())

      assert rendered.root == true,
             "MediaCanvasViewer template violates single-root constraint (rendered.root=#{inspect(rendered.root)}). " <>
               "Ensure no <% %> expressions, comments, or other content appear before the root <div>."
    end
  end

  describe "pdf preview" do
    # Chrome blocks its PDF viewer in a sandboxed iframe, so a PDF preview
    # with `sandbox` renders as an error page instead of the document.
    defp pdf_assigns do
      %{
        id: "canvas-test",
        file: %{
          file_uuid: @file_uuid,
          filename: "doc.pdf",
          file_type: "document",
          mime_type: "application/pdf",
          size: 1024,
          inserted_at: ~U[2026-05-19 12:00:00Z],
          width: nil,
          height: nil,
          urls: %{"original" => "/file/x/original/y"}
        },
        board: nil,
        current_user: nil,
        parent_id: "media-browser-test",
        has_prev: false,
        has_next: false,
        viewer_only: false,
        can_annotate: false,
        viewer_canvas: nil,
        burn_mode: false,
        burn_canvas: nil,
        burn_version: nil,
        etchings_hidden: false,
        auto_annotate: false,
        viewer_annotations: [],
        replying_annotation_uuid: nil,
        reply_parent_uuid: nil,
        etcher_colors: [],
        etcher_line_params: %{},
        viewer_rotation: 0,
        persist_rotation: false,
        rotation_status: nil,
        sidebar_collapsed: true,
        details_path: nil,
        edit_target: nil,
        write_scope: nil,
        file_writable: false,
        featured: nil,
        media_meta: %{title: "", alt: "", description: ""},
        media_meta_own: %{title: "", alt: "", description: ""},
        media_meta_placeholders: %{title: "", alt: "", description: ""},
        media_meta_lang: nil,
        media_meta_lang_name: nil,
        media_details_open: false,
        media_meta_status: nil,
        invert_two_finger_pan: false,
        nav_overflow: MediaCanvasViewer.nav_overflow(),
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      }
    end

    test "pdf iframe is not sandboxed" do
      html =
        pdf_assigns() |> MediaCanvasViewer.render() |> Phoenix.LiveViewTest.rendered_to_string()

      assert [iframe] = Regex.run(~r/<iframe[^>]*id="canvas-test-pdf"[^>]*>/, html),
             "no PDF iframe rendered"

      assert iframe =~ ~s(src="/file/x/original/y")
      refute iframe =~ "sandbox"
    end
  end
end
