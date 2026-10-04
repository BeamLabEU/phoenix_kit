defmodule PhoenixKitWeb.Components.MediaCanvasViewerEyeTest do
  @moduledoc """
  The eye: hide the etchings to see the clean original.

  Three contracts, all deliberate:

  - **Default visible.** Every open starts with the markup showing —
    the burned copy when one exists, the live layer otherwise.
  - **Hiding swaps the picture, not a CSS flag.** The burned copy IS
    the markup (baked into the bitmap), so the hidden state renders a
    different canvas: the original with no Etcher layer and no
    annotation payload in the DOM at all.
  - **Never persisted.** Session state only; a mode switch (pencil)
    also lands back on "visible". There is no user-meta key for it, on
    purpose.

  In the live layer the same job belongs to Etcher's own `:visibility`
  nav button, which is client-side and equally unpersisted — asserted
  here through the `data-nav-buttons` allowlist.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @file_uuid "01900000-0000-7000-8000-000000000001"
  @shape_uuid "0190aaaa-bbbb-7000-8000-00000000c0de"

  defp image(src) do
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
  defp viewer_canvas do
    Fresco.Canvas.put_extension(image("/f/small.jpg"), "etcher", %{
      "version" => "1",
      "annotations" => [%{"uuid" => @shape_uuid, "kind" => "rectangle"}]
    })
  end

  defp render_assigns(overrides) do
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
        myself: %Phoenix.LiveComponent.CID{cid: 1}
      },
      overrides
    )
  end

  defp render_html(overrides) do
    overrides |> render_assigns() |> MediaCanvasViewer.render() |> rendered_to_string()
  end

  describe "the burned view's eye (markup baked into the bitmap)" do
    test "default: the burned copy is up and the hook reads etchings as shown" do
      html = render_html(%{})

      assert html =~ ~s(id="media-burn-#{@file_uuid}-v1")
      assert html =~ ~s(data-etchings-hidden="false")
      assert html =~ ~s(data-fresco-id="media-burn-#{@file_uuid}-v1")
      refute html =~ "media-plain-"
    end

    test "hidden: the clean original replaces the burned copy, no shape reaches the DOM" do
      html = render_html(%{etchings_hidden: true})

      assert html =~ ~s(id="media-plain-#{@file_uuid}")
      assert html =~ ~s(data-etchings-hidden="true")
      assert html =~ ~s(data-fresco-id="media-plain-#{@file_uuid}")
      refute html =~ "media-burn-"
      # No Etcher layer over the clean picture, and the annotation
      # payload is stripped rather than merely unrendered.
      refute html =~ ~s(phx-hook="EtcherLayer")
      refute html =~ @shape_uuid
      # The zoom ladder still runs — looking closely at the clean
      # picture is the point of asking for it.
      assert html =~ ~s(phx-hook="TesseraLayer")
    end

    test "hidden with no live canvas to fall back on keeps the burned copy up" do
      html = render_html(%{etchings_hidden: true, viewer_canvas: nil})

      assert html =~ ~s(id="media-burn-#{@file_uuid}-v1")
      refute html =~ "media-plain-"
    end
  end

  describe "the live layer's eye (Etcher's own :visibility nav button)" do
    test "an annotator gets the pencil and the eye" do
      html = render_html(%{burn_canvas: nil, burn_version: nil})

      assert html =~ ~s(data-nav-buttons="pencil,visibility")
    end

    test "a read-only viewer still gets the eye" do
      html = render_html(%{burn_canvas: nil, burn_version: nil, can_annotate: false})

      assert html =~ ~s(data-nav-buttons="visibility")
      refute html =~ "pencil,"
    end
  end

  describe "event flow" do
    defp socket(assigns) do
      %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
    end

    test "mount opens with the markup showing" do
      {:ok, socket} = MediaCanvasViewer.mount(socket(%{}))

      refute socket.assigns.etchings_hidden
    end

    test "the eye flips the state, and back" do
      {:noreply, hidden} =
        MediaCanvasViewer.handle_event("toggle_etchings", %{}, socket(%{etchings_hidden: false}))

      assert hidden.assigns.etchings_hidden

      {:noreply, shown} = MediaCanvasViewer.handle_event("toggle_etchings", %{}, hidden)

      refute shown.assigns.etchings_hidden
    end

    test "a mode switch always lands with the markup showing" do
      # Pencil pressed while the etchings were hidden: the editor edits
      # shapes it can see.
      {:noreply, live} =
        MediaCanvasViewer.handle_event(
          "toggle_burn_mode",
          %{"annotate" => true},
          socket(%{burn_mode: true, etchings_hidden: true})
        )

      refute live.assigns.burn_mode
      refute live.assigns.etchings_hidden
      assert live.assigns.auto_annotate

      # And the way back out of the editor lands on the burned copy,
      # markup showing.
      {:noreply, burned} =
        MediaCanvasViewer.handle_event(
          "toggle_burn_mode",
          %{},
          socket(%{burn_mode: false, etchings_hidden: true})
        )

      assert burned.assigns.burn_mode
      refute burned.assigns.etchings_hidden
    end
  end
end
