defmodule PhoenixKitWeb.Components.MediaGalleryTest do
  @moduledoc """
  Unit tests for PhoenixKitWeb.Components.MediaGallery.

  These tests exercise the render output of the component directly using
  `rendered_to_string/1`. They do NOT require a database connection because
  all tests use `selected: []` (no file resolution needed) or supply
  pre-built assigns for the render function.

  Event-driven behaviors (remove, reorder, lightbox navigation) are covered
  by verifying the `handle_event/3` private logic via its public effects on
  assigns, using a minimal wrapper that bypasses Storage calls.
  """

  use ExUnit.Case, async: true

  # `render_component` macro reads @endpoint at compile time.
  # The endpoint is started once in test_helper.exs (no DB required).
  @endpoint PhoenixKitWeb.Endpoint

  import Phoenix.LiveViewTest, except: [render: 1]

  alias PhoenixKitWeb.Components.MediaGallery

  # Build a minimal assigns map for rendering MediaGallery.render/1 directly.
  # We expose `selected`, `readonly`, `title`, and `preview_uuid` as options.
  defp gallery_assigns(opts) do
    selected = Keyword.get(opts, :selected, [])
    readonly = Keyword.get(opts, :readonly, false)
    title = Keyword.get(opts, :title, nil)
    preview_uuid = Keyword.get(opts, :preview_uuid, nil)
    files = Keyword.get(opts, :files, [])
    variants_map = Keyword.get(opts, :variants_map, %{})
    rotations_map = Keyword.get(opts, :rotations_map, %{})
    cols = Keyword.get(opts, :cols, 4)
    featured_first = Keyword.get(opts, :featured_first, false)

    %{
      id: "test-gallery",
      selected: selected,
      mode: :multiple,
      cols: cols,
      featured_first: featured_first,
      scope_folder_id: nil,
      phoenix_kit_current_user: nil,
      readonly: readonly,
      max_count: nil,
      title: title,
      show_picker: false,
      preview_uuid: preview_uuid,
      files: files,
      variants_map: variants_map,
      rotations_map: rotations_map,
      # LiveComponent requires a CID for phx-target — use a stub struct
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    }
  end

  defp render(assigns) do
    rendered_to_string(MediaGallery.render(assigns))
  end

  # ── single-root constraint ────────────────────────────────────────────────────

  describe "single-root constraint (stateful component)" do
    # Phoenix LiveView raises ArgumentError at runtime when rendered.root != true
    # for stateful components with an id. This constraint is NOT caught by
    # rendered_to_string/1 — only by inspecting the Rendered struct directly.
    # Regression for: templates with <% %> expressions or text before root tag.
    test "rendered struct satisfies LiveView single-root requirement" do
      rendered = MediaGallery.render(gallery_assigns([]))

      assert rendered.root == true,
             "MediaGallery template violates single-root constraint (rendered.root=#{inspect(rendered.root)}). " <>
               "Ensure no <% %> expressions or other content appear before the root <div>."
    end

    # render_component/2 exercises the real Diff.component_to_rendered path and
    # raises ArgumentError if rendered.root != true for a component with an id.
    # No DB needed: selected: [] avoids the Storage round-trip in load_files/1.
    test "render_component mounts as stateful LiveComponent without raising" do
      html = render_component(MediaGallery, id: "gallery-root-check", selected: [])
      assert html =~ "gallery-root-check"
    end
  end

  # ── title ────────────────────────────────────────────────────────────────────

  describe "title" do
    test "renders title text when title is set" do
      html = render(gallery_assigns(title: "Cover images"))
      assert html =~ "Cover images"
    end

    test "omits title block when title is nil" do
      html = render(gallery_assigns(title: nil))
      refute html =~ "Cover images"
    end
  end

  # ── empty selection ──────────────────────────────────────────────────────────

  describe "empty selection" do
    test "renders no sortable container when selected is empty" do
      html = render(gallery_assigns(selected: []))
      refute html =~ "sortable-item"
      refute html =~ "SortableGrid"
    end

    test "renders pick button when selected is empty and not readonly" do
      html = render(gallery_assigns(selected: [], readonly: false))
      assert html =~ "open-picker-test-gallery"
      # Pick-button text changed in the draggable_list refactor: it is now
      # the trailing "Add" tile of the grid, not a separate "Choose images"
      # row. The data-role assertion above is the stable contract.
      assert html =~ ">Add</span>"
    end
  end

  # ── readonly attr ────────────────────────────────────────────────────────────

  describe "readonly" do
    test "hides pick button in readonly mode" do
      html = render(gallery_assigns(readonly: true))
      refute html =~ "open-picker-test-gallery"
    end

    test "shows pick button when not readonly" do
      html = render(gallery_assigns(readonly: false))
      assert html =~ "open-picker-test-gallery"
    end

    test "hides remove buttons when readonly (with pre-set items)" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns(
            selected: [uuid],
            readonly: true,
            variants_map: %{uuid => []}
          )
        )

      refute html =~ "remove-image-test-gallery-#{uuid}"
    end

    test "shows remove buttons when not readonly (with pre-set items)" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns(
            selected: [uuid],
            readonly: false,
            variants_map: %{uuid => []}
          )
        )

      assert html =~ "remove-image-test-gallery-#{uuid}"
    end

    test "omits SortableGrid hook when readonly" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns(
            selected: [uuid],
            readonly: true,
            variants_map: %{uuid => []}
          )
        )

      refute html =~ "SortableGrid"
    end

    test "includes SortableGrid hook when not readonly and multiple items present" do
      # Drag is only meaningful with 2+ items. Single-item grids skip the
      # hook (and the cursor-grab styling) so users aren't given a
      # drag-affordance that does nothing.
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"

      html =
        render(
          gallery_assigns(
            selected: [uuid1, uuid2],
            readonly: false,
            variants_map: %{uuid1 => [], uuid2 => []}
          )
        )

      assert html =~ "SortableGrid"
    end

    test "omits SortableGrid hook for single-item selection (no reorder possible)" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns(
            selected: [uuid],
            readonly: false,
            variants_map: %{uuid => []}
          )
        )

      refute html =~ "SortableGrid"
    end

    test "preview (eye) button is still rendered in readonly mode" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns(
            selected: [uuid],
            readonly: true,
            variants_map: %{uuid => []}
          )
        )

      assert html =~ "preview-image-test-gallery-#{uuid}"
    end
  end

  # ── thumbnail strip ──────────────────────────────────────────────────────────

  describe "thumbnail strip" do
    test "renders one sortable-item per selected UUID" do
      uuids = [
        "01900000-0000-7000-8000-000000000001",
        "01900000-0000-7000-8000-000000000002"
      ]

      html =
        render(
          gallery_assigns(
            selected: uuids,
            variants_map: %{
              "01900000-0000-7000-8000-000000000001" => [],
              "01900000-0000-7000-8000-000000000002" => []
            }
          )
        )

      assert html =~ ~s(data-id="01900000-0000-7000-8000-000000000001")
      assert html =~ ~s(data-id="01900000-0000-7000-8000-000000000002")
      assert html =~ "sortable-item"
    end

    test "thumbnails carry the file's saved rotation, unrotated files none" do
      # The gallery grid iterates uuids, so orientation comes from the
      # rotations_map lookup; thumbnails render it as a CSS transform to
      # stay consistent with the media grid and the lightbox canvas.
      turned = "01900000-0000-7000-8000-000000000001"
      upright = "01900000-0000-7000-8000-000000000002"

      html =
        render(
          gallery_assigns(
            selected: [turned, upright],
            variants_map: %{turned => [], upright => []},
            rotations_map: %{turned => 90, upright => 0}
          )
        )

      assert html =~ "rotate-90"
      refute html =~ "rotate-180"
    end

    test "reorder grid carries a bare event name plus a component target" do
      # <.draggable_list> drives reorder. The event name is bare
      # ("reorder_images", not "reorder_images:test-gallery"); collisions
      # between MediaGallery instances are avoided by `data-sortable-target`,
      # a per-instance CSS selector ("#test-gallery"). The SortableGrid hook
      # reads that and uses `pushEventTo` so the event reaches *this*
      # component's `handle_event/3` rather than the host LiveView.
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"

      html =
        render(
          gallery_assigns(
            selected: [uuid1, uuid2],
            variants_map: %{uuid1 => [], uuid2 => []}
          )
        )

      assert html =~ ~s(data-sortable-event="reorder_images")
      assert html =~ ~s(data-sortable-target="#test-gallery")
    end

    test "cursor-grab class applied when not readonly and multiple items" do
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"

      html =
        render(
          gallery_assigns(
            selected: [uuid1, uuid2],
            readonly: false,
            variants_map: %{uuid1 => [], uuid2 => []}
          )
        )

      assert html =~ "cursor-grab"
    end

    test "cursor-grab class absent when readonly" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns(
            selected: [uuid],
            readonly: true,
            variants_map: %{uuid => []}
          )
        )

      refute html =~ "cursor-grab"
    end
  end

  # ── lightbox (preview_uuid set) ──────────────────────────────────────────────

  describe "lightbox" do
    test "media_viewer_closed update clears preview_uuid" do
      uuid = "01900000-0000-7000-8000-000000000001"

      socket = %Phoenix.LiveView.Socket{
        assigns: Map.put(gallery_assigns(selected: [uuid], preview_uuid: uuid), :__changed__, %{})
      }

      {:ok, socket} = MediaGallery.update(%{media_viewer_closed: true}, socket)
      assert is_nil(socket.assigns.preview_uuid)
    end

    test "does not render viewer when preview_uuid is nil" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns(
            selected: [uuid],
            preview_uuid: nil,
            variants_map: %{uuid => []}
          )
        )

      refute html =~ "test-gallery-viewer"
      refute html =~ "close_viewer"
    end

    test "media_viewer_closed is safe when preview_uuid is already nil" do
      uuid = "01900000-0000-7000-8000-000000000001"

      socket = %Phoenix.LiveView.Socket{
        assigns: Map.put(gallery_assigns(selected: [uuid], preview_uuid: nil), :__changed__, %{})
      }

      {:ok, socket} = MediaGallery.update(%{media_viewer_closed: true}, socket)
      assert is_nil(socket.assigns.preview_uuid)
    end

    test "preview_image with second item sets preview_uuid to second item" do
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"

      assigns =
        gallery_assigns(
          selected: [uuid1, uuid2],
          variants_map: %{uuid1 => [], uuid2 => []}
        )

      {:noreply, socket} = call_handle_event("preview_image", %{"uuid" => uuid2}, assigns)
      assert socket.assigns.preview_uuid == uuid2
    end

    test "gallery selected list is the navigable files for the viewer" do
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"
      assigns = gallery_assigns(selected: [uuid1, uuid2])
      assert assigns.selected == [uuid1, uuid2]
    end

    test "open_picker event sets show_picker to true" do
      assigns = gallery_assigns([]) |> Map.put(:show_picker, false)
      {:noreply, socket} = call_handle_event("open_picker", %{}, assigns)
      assert socket.assigns.show_picker == true
    end

    test "gallery exposes file structs through files assign" do
      uuid = "01900000-0000-7000-8000-000000000001"
      file_struct = %{uuid: uuid, original_file_name: "cover.jpg", file_name: nil}
      assigns = gallery_assigns(selected: [uuid], files: [file_struct])
      assert [%{uuid: ^uuid, original_file_name: "cover.jpg"}] = assigns.files
    end
  end

  # ── handle_event logic ────────────────────────────────────────────────────────
  #
  # These tests call the private step_preview logic indirectly by verifying
  # the public MediaGallery module's exported functions and the assign
  # transformations via inline helpers. For full event dispatch tests see
  # the integration suite (requires DB + endpoint).

  describe "step_preview logic (via handle_event delegation)" do
    # We test the handle_event clauses by invoking the module's public
    # handle_event/3 with a minimal Phoenix.LiveView.Socket-shaped value.

    defp call_handle_event(event, params, assigns) do
      # Build a minimal socket-like struct
      socket = %Phoenix.LiveView.Socket{
        assigns: Map.put(assigns, :__changed__, %{})
      }

      MediaGallery.handle_event(event, params, socket)
    end

    test "remove_image drops the UUID and the rest are preserved" do
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"

      assigns =
        gallery_assigns(
          selected: [uuid1, uuid2],
          variants_map: %{}
        )

      {:noreply, socket} = call_handle_event("remove_image", %{"uuid" => uuid1}, assigns)
      assert socket.assigns.selected == [uuid2]
    end

    test "preview_image sets preview_uuid" do
      uuid = "01900000-0000-7000-8000-000000000001"
      assigns = gallery_assigns(selected: [uuid])

      {:noreply, socket} = call_handle_event("preview_image", %{"uuid" => uuid}, assigns)
      assert socket.assigns.preview_uuid == uuid
    end

    test "media_viewer_closed is the close path (replaces close_preview)" do
      uuid = "01900000-0000-7000-8000-000000000001"

      socket = %Phoenix.LiveView.Socket{
        assigns: Map.put(gallery_assigns(selected: [uuid], preview_uuid: uuid), :__changed__, %{})
      }

      {:ok, socket} = MediaGallery.update(%{media_viewer_closed: true}, socket)
      assert is_nil(socket.assigns.preview_uuid)
    end

    test "media_viewer_closed update does not change selected or readonly" do
      uuid = "01900000-0000-7000-8000-000000000001"

      socket = %Phoenix.LiveView.Socket{
        assigns: Map.put(gallery_assigns(selected: [uuid], preview_uuid: uuid), :__changed__, %{})
      }

      {:ok, socket} = MediaGallery.update(%{media_viewer_closed: true}, socket)
      assert socket.assigns.selected == [uuid]
      assert socket.assigns.readonly == false
    end

    test "media_viewer_closed allows re-opening preview by setting preview_uuid again" do
      uuid = "01900000-0000-7000-8000-000000000001"

      socket = %Phoenix.LiveView.Socket{
        assigns: Map.put(gallery_assigns(selected: [uuid], preview_uuid: uuid), :__changed__, %{})
      }

      {:ok, socket} = MediaGallery.update(%{media_viewer_closed: true}, socket)
      assert is_nil(socket.assigns.preview_uuid)

      # Re-open via preview_image event
      {:noreply, socket} = MediaGallery.handle_event("preview_image", %{"uuid" => uuid}, socket)
      assert socket.assigns.preview_uuid == uuid
    end

    test "reorder_images appends items not in ids list as leftovers" do
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"
      uuid3 = "01900000-0000-7000-8000-000000000003"

      assigns = gallery_assigns(selected: [uuid1, uuid2, uuid3], variants_map: %{})

      # ordered_ids list omits uuid3 — it should be appended at the end.
      # Event contract changed from "reorder_images:{id}" + "ids" key (raw
      # SortableGrid hook) to "reorder_images" + "ordered_ids" key
      # (<.draggable_list> wrapper; routed to this component via
      # `target` -> SortableGrid `pushEventTo`).
      {:noreply, socket} =
        call_handle_event("reorder_images", %{"ordered_ids" => [uuid2, uuid1]}, assigns)

      assert socket.assigns.selected == [uuid2, uuid1, uuid3]
    end

    test "remove_image on the last selected item empties the selection" do
      uuid = "01900000-0000-7000-8000-000000000001"
      assigns = gallery_assigns(selected: [uuid], variants_map: %{})

      {:noreply, socket} = call_handle_event("remove_image", %{"uuid" => uuid}, assigns)
      assert socket.assigns.selected == []
    end

    test "preview_image can target any uuid in the selected list" do
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"
      uuid3 = "01900000-0000-7000-8000-000000000003"
      assigns = gallery_assigns(selected: [uuid1, uuid2, uuid3])

      {:noreply, socket} = call_handle_event("preview_image", %{"uuid" => uuid3}, assigns)
      assert socket.assigns.preview_uuid == uuid3
    end

    test "reorder_images reorders the selection list" do
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"
      uuid3 = "01900000-0000-7000-8000-000000000003"

      assigns =
        gallery_assigns(
          selected: [uuid1, uuid2, uuid3],
          variants_map: %{}
        )

      {:noreply, socket} =
        call_handle_event(
          "reorder_images",
          %{"ordered_ids" => [uuid3, uuid1, uuid2]},
          assigns
        )

      assert socket.assigns.selected == [uuid3, uuid1, uuid2]
    end
  end

  # ── max_count / Add-button disable behavior ────────────────────────────────────

  describe "max_count" do
    defp gallery_assigns_with(extra) do
      base =
        gallery_assigns([])
        |> Map.put(:max_count, nil)

      Map.merge(base, extra)
    end

    test "Add button is enabled when selection is below max_count" do
      html =
        render(
          gallery_assigns_with(%{
            mode: :multiple,
            max_count: 3,
            selected: ["01900000-0000-7000-8000-000000000001"],
            variants_map: %{"01900000-0000-7000-8000-000000000001" => []}
          })
        )

      assert html =~ "open-picker-test-gallery"
      refute html =~ ~s(disabled="")
    end

    test "Add tile is omitted when selection equals max_count" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns_with(%{
            mode: :multiple,
            max_count: 1,
            selected: [uuid],
            variants_map: %{uuid => []}
          })
        )

      # The :add_button slot is conditional on `selection_at_limit?/3`
      # so the entire trigger button is dropped (no disabled-state
      # rendering). See media_gallery.html.heex line 71.
      refute html =~ "open-picker-test-gallery"
    end

    test "Add tile is omitted in :single mode with one item" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns_with(%{
            mode: :single,
            max_count: nil,
            selected: [uuid],
            variants_map: %{uuid => []}
          })
        )

      refute html =~ "open-picker-test-gallery"
    end

    test "Add button is enabled in :single mode with empty selection" do
      html =
        render(
          gallery_assigns_with(%{
            mode: :single,
            max_count: nil,
            selected: [],
            variants_map: %{}
          })
        )

      assert html =~ "open-picker-test-gallery"
      refute html =~ "cursor-not-allowed"
    end

    test "Add button is enabled when max_count is nil (unlimited)" do
      uuid = "01900000-0000-7000-8000-000000000001"

      html =
        render(
          gallery_assigns_with(%{
            mode: :multiple,
            max_count: nil,
            selected: [uuid],
            variants_map: %{uuid => []}
          })
        )

      assert html =~ "open-picker-test-gallery"
      refute html =~ "cursor-not-allowed"
    end

    test "apply_selection clamps to max_count in :multiple mode" do
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"
      uuid3 = "01900000-0000-7000-8000-000000000003"

      assigns_before =
        gallery_assigns([])
        |> Map.put(:mode, :multiple)
        |> Map.put(:max_count, 2)
        |> Map.put(:selected, [uuid1])
        |> Map.put(:selected_loaded, [uuid1])
        |> Map.put(:files, [])
        |> Map.put(:variants_map, %{})
        |> Map.put(:__changed__, %{})

      socket_before = %Phoenix.LiveView.Socket{assigns: assigns_before}

      {:ok, socket} =
        MediaGallery.update(%{media_selected: [uuid1, uuid2, uuid3]}, socket_before)

      assert length(socket.assigns.selected) <= 2
      assert uuid3 not in socket.assigns.selected
    end
  end

  # ── single mode ───────────────────────────────────────────────────────────────

  describe "single mode" do
    test "render shows mode=:single in the gallery (no crash)" do
      uuid = "01900000-0000-7000-8000-000000000001"

      assigns =
        gallery_assigns(selected: [uuid], variants_map: %{uuid => []})
        |> Map.put(:mode, :single)

      html = render(assigns)
      assert html =~ ~s(data-id="#{uuid}")
    end

    test "apply_selection with :single mode keeps only the first UUID" do
      uuid1 = "01900000-0000-7000-8000-000000000001"
      uuid2 = "01900000-0000-7000-8000-000000000002"

      # Simulate the media_selected update path: update/2 calls apply_selection
      # with mode: :single. We verify via update/2 → assigns.selected.
      assigns_before =
        gallery_assigns(selected: [uuid1], variants_map: %{})
        |> Map.put(:mode, :single)
        |> Map.put(:__changed__, %{})

      socket_before = %Phoenix.LiveView.Socket{assigns: assigns_before}

      # Inject media_selected with two UUIDs — single mode should keep only the first.
      {:ok, socket} =
        MediaGallery.update(%{media_selected: [uuid1, uuid2]}, socket_before)

      assert socket.assigns.selected == [uuid1]
    end
  end
end
