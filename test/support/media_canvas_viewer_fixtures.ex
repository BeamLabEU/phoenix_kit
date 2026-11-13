defmodule PhoenixKitWeb.MediaCanvasViewerFixtures do
  @moduledoc """
  The assigns `MediaCanvasViewer.render/1` needs for one image with one
  annotation, shared by the viewer's tests: `render_html/1` takes overrides.
  """

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @file_uuid "01900000-0000-7000-8000-000000000001"
  @shape_uuid "0190aaaa-bbbb-7000-8000-00000000c0de"

  def file_uuid, do: @file_uuid
  def shape_uuid, do: @shape_uuid

  def image(src) do
    Fresco.Canvas.new(width: 800, height: 600)
    |> Fresco.Canvas.add_image(%{
      src: src,
      x: 0,
      y: 0,
      width: 800,
      natural_width: 800,
      natural_height: 600
    })
  end

  # The live canvas as build_viewer_canvas/3 shapes it: the picture plus
  # the annotations riding in the "etcher" extension.
  def viewer_canvas do
    Fresco.Canvas.put_extension(image("/f/small.jpg"), "etcher", %{
      "version" => "1",
      "annotations" => [%{"uuid" => @shape_uuid, "kind" => "rectangle"}]
    })
  end

  def render_assigns(overrides) do
    Map.merge(
      %{
        id: "canvas-eye-test",
        file: %{
          file_uuid: @file_uuid,
          filename: "test.jpg",
          file_type: "image",
          mime_type: "image/jpeg",
          size: 1024,
          inserted_at: ~U[2026-05-19 12:00:00Z],
          width: 800,
          height: 600,
          urls: %{
            "small" => "/f/small.jpg",
            "medium" => "/f/medium.jpg",
            "original" => "/f/original.jpg"
          },
          burn_fingerprint: "abc123"
        },
        board: nil,
        current_user: nil,
        parent_id: "mb-test",
        has_prev: false,
        has_next: false,
        viewer_only: false,
        can_annotate: true,
        viewer_canvas: viewer_canvas(),
        burn_mode: true,
        burn_canvas: image("/f/burned.jpg"),
        burn_version: "v1",
        etchings_hidden: false,
        auto_annotate: false,
        viewer_annotations: [],
        replying_annotation_uuid: nil,
        reply_parent_uuid: nil,
        etcher_colors: ["#e11d48"],
        etcher_line_params: %{"width" => 2, "opacity" => 1, "dash" => "solid"},
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
      },
      overrides
    )
  end

  def render_html(overrides) do
    overrides |> render_assigns() |> MediaCanvasViewer.render() |> rendered_to_string()
  end
end
