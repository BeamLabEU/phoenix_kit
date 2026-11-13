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

  import PhoenixKitWeb.MediaCanvasViewerFixtures

  alias PhoenixKitWeb.Components.MediaCanvasViewer
  alias PhoenixKitWeb.MediaCanvasViewerFixtures

  @file_uuid MediaCanvasViewerFixtures.file_uuid()
  @shape_uuid MediaCanvasViewerFixtures.shape_uuid()

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

    test "hidden from the editor — no burn on file at all — still shows the clean original" do
      html = render_html(%{etchings_hidden: true, burn_canvas: nil, burn_version: nil})

      assert html =~ ~s(id="media-plain-#{@file_uuid}")
      assert html =~ ~s(data-fresco-id="media-plain-#{@file_uuid}")
      refute html =~ ~s(phx-hook="EtcherLayer")
      refute html =~ @shape_uuid
    end
  end

  describe "the live layer's nav buttons" do
    test "an annotator gets Etcher's View | Annotate switch alone — their eye is the hook's" do
      # The annotator's eye must end the editing session (composing the
      # burn while the overlay is still up) before swapping to the clean
      # picture; Etcher's client-side overlay toggle cannot do that, so
      # the AnnotationBurn hook owns the eye on every surface of theirs.
      # `modes` is the switch that replaces the pencil (Etcher 0.25).
      html = render_html(%{burn_canvas: nil, burn_version: nil})

      assert html =~ ~s(data-nav-buttons="modes")
      refute html =~ ~s(data-nav-buttons="pencil")
      refute html =~ ~s(data-nav-buttons="modes,visibility")
    end

    test "the viewer's buttons are drawn as one dark bar, Etcher's tool bar look" do
      html = render_html(%{burn_canvas: nil, burn_version: nil})
      assert html =~ ~s(data-nav-style="bar")
    end

    test "a read-only viewer gets Etcher's eye — no session to end, nothing to swap" do
      html = render_html(%{burn_canvas: nil, burn_version: nil, can_annotate: false})

      assert html =~ ~s(data-nav-buttons="visibility")
    end
  end

  describe "Export as PDF" do
    test "every canvas offers it, named after the file" do
      for overrides <- [
            %{},
            %{burn_canvas: nil, burn_version: nil},
            %{etchings_hidden: true}
          ] do
        html = render_html(overrides)
        assert html =~ ~s(data-pdf-export="true")
        assert html =~ ~s(data-export-filename="test.jpg")
      end
    end

    test "the picture exported is the original, not the screen-sized rung" do
      image = %{src: "/f/small.jpg", x: 0, y: 0, width: 800}

      file = %{
        mime_type: "image/jpeg",
        urls: %{"small" => "/f/small.jpg", "original" => "/f/original.jpg"}
      }

      assert %{export_src: "/f/original.jpg"} = MediaCanvasViewer.export_src(image, file)

      canvas =
        Fresco.Canvas.add_image(
          Fresco.Canvas.new(width: 800, height: 600),
          MediaCanvasViewer.export_src(image, file)
        )

      assert [%{export_src: "/f/original.jpg"}] = canvas.images

      # No original on file: the stage's own picture is what gets exported.
      refute Map.has_key?(MediaCanvasViewer.export_src(image, %{urls: %{}}), :export_src)
    end

    test "an original no browser can draw exports the top rung instead" do
      image = %{src: "/f/small.jpg", x: 0, y: 0, width: 800}

      for mime <- ~w(image/heic image/tiff image/x-canon-cr2) do
        file = %{
          mime_type: mime,
          urls: %{"small" => "/f/small.jpg", "large" => "/f/large.jpg", "original" => "/f/orig"}
        }

        assert %{export_src: "/f/large.jpg"} = MediaCanvasViewer.export_src(image, file)

        # No rung above the stage's own: that one is exported, not the original.
        no_large = %{file | urls: Map.delete(file.urls, "large")}
        refute Map.has_key?(MediaCanvasViewer.export_src(image, no_large), :export_src)
      end
    end
  end

  describe "the full-quality loading pill" do
    test "a picture carries it, idle until the hook says a sharper one is loading" do
      html = render_html(%{})

      assert html =~ ~s(id="pk-hires-loading-#{@file_uuid}")
      assert html =~ ~s(phx-hook="ViewerHiresLoading")
      assert html =~ ~s(data-state="idle")
      assert html =~ "Loading full quality"
    end

    test "something that is not a picture has no sharper version to wait for" do
      file = %{render_assigns(%{}).file | file_type: "document", mime_type: "application/pdf"}
      html = render_html(%{file: file, viewer_canvas: nil, burn_canvas: nil})

      refute html =~ "pk-hires-loading-"
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
        MediaCanvasViewer.handle_event(
          "toggle_etchings",
          %{},
          socket(%{burn_mode: true, etchings_hidden: false})
        )

      assert hidden.assigns.etchings_hidden

      {:noreply, shown} = MediaCanvasViewer.handle_event("toggle_etchings", %{}, hidden)

      refute shown.assigns.etchings_hidden
    end

    test "the eye pressed in the editor ends the session onto the clean picture" do
      {:noreply, plain} =
        MediaCanvasViewer.handle_event(
          "toggle_etchings",
          %{},
          socket(%{burn_mode: false, etchings_hidden: false, auto_annotate: true})
        )

      assert plain.assigns.burn_mode
      assert plain.assigns.etchings_hidden
      refute plain.assigns.auto_annotate

      # Un-hiding from there is a look at the markup, not a trip back
      # into the editor: it lands on the burned copy.
      {:noreply, shown} = MediaCanvasViewer.handle_event("toggle_etchings", %{}, plain)

      assert shown.assigns.burn_mode
      refute shown.assigns.etchings_hidden
    end

    test "the invert-two-finger-pan preference reads a stored true and nothing else" do
      stored = fn value ->
        %PhoenixKit.Users.Auth.User{
          custom_fields: %{MediaCanvasViewer.invert_two_finger_pan_key() => value}
        }
      end

      assert MediaCanvasViewer.invert_two_finger_pan?(stored.(true))

      refute MediaCanvasViewer.invert_two_finger_pan?(%PhoenixKit.Users.Auth.User{
               custom_fields: %{}
             })

      refute MediaCanvasViewer.invert_two_finger_pan?(nil)
      refute MediaCanvasViewer.invert_two_finger_pan?(stored.("true"))
    end

    test "the open-annotating preference reads a stored true and nothing else" do
      stored = fn value ->
        %PhoenixKit.Users.Auth.User{
          custom_fields: %{MediaCanvasViewer.open_annotating_key() => value}
        }
      end

      assert MediaCanvasViewer.open_annotating?(stored.(true))

      # The shipped default is the finished picture: an absent key, a
      # never-written user, no user at all, and garbage all mean "off".
      refute MediaCanvasViewer.open_annotating?(%PhoenixKit.Users.Auth.User{custom_fields: %{}})
      refute MediaCanvasViewer.open_annotating?(%PhoenixKit.Users.Auth.User{custom_fields: nil})
      refute MediaCanvasViewer.open_annotating?(nil)
      refute MediaCanvasViewer.open_annotating?(stored.("true"))
      refute MediaCanvasViewer.open_annotating?(stored.(1))
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

  describe "two-finger pan direction" do
    # Every canvas the viewer can put up carries it — the burned copy, the
    # clean original and the live layer — or the direction would change
    # under the user's fingers as they press the eye or the pencil.
    test "off by default: no canvas carries the flag" do
      for overrides <- [%{}, %{etchings_hidden: true}, %{burn_mode: false}] do
        refute render_html(overrides) =~ "data-invert-two-finger-pan"
      end
    end

    test "on: every canvas is inverted" do
      for overrides <- [%{}, %{etchings_hidden: true}, %{burn_mode: false}] do
        html = render_html(Map.put(overrides, :invert_two_finger_pan, true))
        assert html =~ ~s(data-invert-two-finger-pan="true"), inspect(overrides)
      end
    end
  end
end

defmodule PhoenixKitWeb.Components.MediaCanvasViewerOpenAnnotatingTest do
  @moduledoc """
  The per-user "open media ready to annotate" preference, applied at
  viewer-open: with it, the editor is live the moment the popup is
  (Etcher armed via `auto_annotate`, no pencil press first); without it
  — or where it means nothing — the viewer opens on the picture.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @file_uuid "01900000-0000-7000-8000-00000000f11e"

  defp register!(custom_fields) do
    {:ok, user} =
      Auth.register_user(%{
        email: "open-annotating-viewer-#{System.unique_integer([:positive])}@example.com",
        password: "hello world!"
      })

    case custom_fields do
      map when map_size(map) > 0 ->
        {:ok, user} = Auth.merge_user_custom_fields(user, map)
        user

      _ ->
        user
    end
  end

  defp open_viewer(user, overrides) do
    {:ok, socket} =
      MediaCanvasViewer.mount(%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}})

    assigns =
      Map.merge(
        %{
          id: "viewer-open-test",
          file: %{
            file_uuid: @file_uuid,
            filename: "test.jpg",
            file_type: "image",
            mime_type: "image/jpeg",
            width: 800,
            height: 600,
            urls: %{"small" => "/f/small.jpg"}
          },
          current_user: user,
          parent_id: "mb-test"
        },
        overrides
      )

    {:ok, socket} = MediaCanvasViewer.update(assigns, socket)
    socket.assigns
  end

  test "the flag opens the viewer in the editor, Etcher armed" do
    user = register!(%{MediaCanvasViewer.open_annotating_key() => true})
    assigns = open_viewer(user, %{})

    refute assigns.burn_mode
    assert assigns.auto_annotate
    refute assigns.etchings_hidden, "the editor shows the shapes it edits"
  end

  test "without the flag the viewer opens on the picture — the shipped default" do
    assigns = open_viewer(register!(%{}), %{})

    assert assigns.burn_mode
    refute assigns.auto_annotate
  end

  test "a read-only viewer keeps the picture whatever the flag says" do
    user = register!(%{MediaCanvasViewer.open_annotating_key() => true})
    assigns = open_viewer(user, %{can_annotate: false})

    assert assigns.burn_mode
    refute assigns.auto_annotate
  end

  test "no user at all (a public lightbox) opens on the picture" do
    assigns = open_viewer(nil, %{})

    assert assigns.burn_mode
    refute assigns.auto_annotate
  end
end
