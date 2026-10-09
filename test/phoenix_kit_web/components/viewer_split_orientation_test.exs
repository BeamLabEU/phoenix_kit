defmodule PhoenixKitWeb.Components.ViewerSplitOrientationTest do
  @moduledoc """
  The popup viewer puts its details panel beside the picture only when the
  popup is wider than it is tall.

  `lg:` alone reads width, and a tall window that happens to be ≥1024px wide
  — a portrait monitor, a half-screen split — kept the side split and squeezed
  a landscape picture into what was left of a column beside a 280-416px panel.
  Measured at 1100×1500 with the panel open: 688×318 of picture before,
  1031×477 after, a little over twice the pixels. `landscape:` adds the shape
  test, so a portrait popup falls back to the stacked layout mobile already
  used — picture on top, panel docked along the bottom, same collapse toggle.

  These assertions read the templates rather than rendering them because the
  rule spans two files that must agree. `MediaCanvasViewer` is the real
  viewer; the `InstantViewer` stand-in in `MediaBrowser` paints a mirror of
  that split on the click, before the server has sent anything back. If the
  stand-in predicts a side split where the viewer will dock at the bottom,
  the hand-off lands with exactly the jump the stand-in exists to prevent —
  and nothing else in the suite would notice, because each half is correct on
  its own.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @viewer Path.join(
            __DIR__,
            "../../../lib/phoenix_kit_web/components/media_canvas_viewer.html.heex"
          )
  @browser Path.join(
             __DIR__,
             "../../../lib/phoenix_kit_web/components/media_browser.html.heex"
           )
  @media_viewer Path.join(
                  __DIR__,
                  "../../../lib/phoenix_kit_web/components/media_viewer.html.heex"
                )

  defp viewer_source, do: File.read!(@viewer)

  # The stand-in only — MediaBrowser holds other `lg:` layouts that have
  # nothing to do with the viewer split.
  defp standin_source do
    src = File.read!(@browser)
    start = :binary.match(src, "-instant-viewer") |> elem(0)
    stop = :binary.match(src, "Read-only modal viewer") |> elem(0)
    :binary.part(src, start, stop - start)
  end

  describe "the split is keyed on shape, not width alone" do
    test "the real viewer goes side by side only when landscape" do
      src = viewer_source()

      assert src =~ "flex flex-col lg:landscape:flex-row",
             "the viewer's split must ask for landscape before going side by side"

      refute src =~ ~r/\blg:flex-row\b/,
             "a bare `lg:flex-row` is the width-only rule this replaced"
    end

    test "the instant stand-in mirrors it" do
      src = standin_source()

      assert src =~ "flex flex-col lg:landscape:flex-row",
             "the stand-in predicts the layout the viewer is about to use — " <>
               "predicting a side split where the viewer docks at the bottom " <>
               "hands over with a jump"

      refute src =~ ~r/\blg:flex-row\b/
    end
  end

  describe "everything that encodes the side-by-side state moves with it" do
    # Each of these is half of the same rule. A leftover bare `lg:` here is
    # the layout disagreeing with itself: a panel holding a 280px minimum
    # while docked along the bottom, a seam chevron floating in a stacked
    # layout that has no seam, or the in-viewer toggle hiding itself where
    # it is the only way to get the panel back.
    test "the picture column, the panel, the seam and the toggle all agree" do
      src = viewer_source()

      for class <- [
            # picture column: padding beside the panel, and a floor that
            # belongs to the full-screen phone popup rather than to every
            # stacked layout — at desktop widths the pane's height comes
            # from the picture, and a 40vh floor would undo that.
            "lg:landscape:p-2",
            "max-lg:min-h-[40vh]",
            # panel: a width to hold beside the picture
            "lg:landscape:min-w-[280px]",
            "lg:landscape:max-w-[26rem]",
            # the seam host exists only where the seam does
            "hidden lg:landscape:block",
            # the in-viewer toggle covers every state with no seam
            "right-14 lg:landscape:hidden",
            # and points along the axis the panel actually docks on
            "rotate-90 lg:landscape:rotate-0"
          ] do
        assert src =~ class, "#{class} is missing — half the rule is still width-only"
      end
    end

    test "no width-only leftovers remain in the split" do
      src = viewer_source()

      for stale <- ["lg:min-w-[280px]", "lg:max-w-[26rem]", "lg:p-2", "lg:hidden"] do
        refute src =~ ~r/(?<!landscape:)#{Regex.escape(stale)}/,
               "#{stale} still reads width alone, so it disagrees with the split it belongs to"
      end
    end
  end

  describe "the panel stays collapsible in both layouts" do
    test "the toggle is rendered for every state without a seam" do
      src = viewer_source()

      # Collapsed has no seam (there is nothing to sit between), and neither
      # does the stacked layout — so the in-viewer button carries those, and
      # is only hidden where the seam takes over.
      assert src =~
               ~s|if(@sidebar_collapsed, do: "right-14", else: "right-14 lg:landscape:hidden")|,
             "collapsed must keep an always-visible toggle, and the expanded " <>
               "one may only hide itself where the seam exists to replace it"
    end

    test "the panel and the seam are both dropped while collapsed" do
      src = viewer_source()

      assert length(String.split(src, "not @viewer_only and not @sidebar_collapsed")) == 3,
             "the seam host and the panel are the two things a collapse removes"
    end
  end

  describe "stacked, the pane is sized to the picture" do
    # Why this is not a share of the popup's height: a 1080×2840 window makes
    # the popup 2556px tall, of which a landscape photograph wants about 470.
    # The rest was empty canvas above and below the picture, with the details
    # panel stranded at the bottom of a popup the picture had no use for.
    test "the pane holds the picture's ratio, clamped at both ends" do
      src = viewer_source()

      assert src =~ "lg:portrait:aspect-[var(--pk-pane-aspect,1.5)]",
             "the stacked pane's height comes from the picture's own ratio"

      assert src =~ "style={pane_style(aspect, @viewer_only)}" and
               File.read!(
                 Path.expand(
                   "../../../lib/phoenix_kit_web/components/media_canvas_viewer.ex",
                   __DIR__
                 )
               ) =~ "--pk-pane-aspect: ",
             "…which the server hands down to the stylesheet as a custom " <>
               "property (via `pane_style/2`), so the rule is shared and only " <>
               "the number is per-file"

      assert src =~ "lg:portrait:min-h-[18rem]",
             "a panorama still gets a usable pane rather than a letterbox slot"

      assert src =~ "lg:portrait:max-h-[60vh]",
             "and a tall picture leaves room for the panel under it"
    end

    test "the pane stops taking a flex share once it has an aspect" do
      src = viewer_source()

      assert src =~ "lg:portrait:flex-none",
             "a flex share and an aspect cannot both decide the height — and " <>
               "in an auto-height popup a zero-basis share collapses to nothing"

      assert src =~ "lg:portrait:h-[60vh]",
             "a file with no dimensions to give (a PDF, an audio file) keeps " <>
               "a fixed pane instead of collapsing"
    end

    test "the panel gives way rather than pushing the popup past its ceiling" do
      src = viewer_source()

      assert src =~ "lg:portrait:flex-initial",
             "docked, the panel is content-sized and still able to shrink"

      assert src =~ "lg:portrait:max-h-[32vh]"
    end

    test "the popup stops holding a fixed height in portrait" do
      for {name, src} <- [
            {"stand-in and viewer modal", File.read!(@browser)},
            {"standalone viewer", File.read!(@media_viewer)}
          ] do
        assert src =~ "lg:landscape:!h-[90vh] lg:portrait:!max-h-[90vh]",
               "#{name}: a portrait popup is as tall as the picture plus the " <>
                 "panel, capped — not 90vh of mostly empty canvas"
      end
    end

    test "and sits near the top instead of floating in the middle" do
      # The modal is a centring grid, so a popup shorter than the window lands
      # in the middle of it with as much empty space above as the picture is
      # tall. A fixed top margin with an auto bottom one wins over that (auto
      # margins take the alignment axis) and puts it where the eye starts.
      for {name, src} <- [
            {"stand-in and viewer modal", File.read!(@browser)},
            {"standalone viewer", File.read!(@media_viewer)}
          ] do
        assert src =~ "lg:portrait:!mt-[4vh] lg:portrait:!mb-auto",
               "#{name}: a shrink-wrapped popup should hang from the top, not float"
      end
    end

    test "the stand-in predicts the same pane" do
      src = standin_source()

      for class <- [
            "lg:portrait:flex-none",
            "lg:portrait:aspect-[var(--pk-pane-aspect,1.5)]",
            "lg:portrait:min-h-[18rem]",
            "lg:portrait:max-h-[60vh]",
            "lg:portrait:max-h-[32vh]"
          ] do
        assert src =~ class,
               "#{class} is missing from the stand-in, which paints the split " <>
                 "before the server answers — a pane of a different shape hands " <>
                 "over by resizing the popup"
      end
    end
  end

  describe "the picture's shape" do
    defp file(w, h), do: %{width: w, height: h}

    test "is its own dimensions" do
      assert MediaCanvasViewer.pane_aspect(file(4000, 3000)) == "4000 / 3000"
      assert MediaCanvasViewer.pane_aspect(file(11_384, 4221)) == "11384 / 4221"
    end

    test "turns with a quarter turn, and only a quarter turn" do
      assert MediaCanvasViewer.pane_aspect(file(4000, 3000), 90) == "3000 / 4000"
      assert MediaCanvasViewer.pane_aspect(file(4000, 3000), 270) == "3000 / 4000"
      assert MediaCanvasViewer.pane_aspect(file(4000, 3000), 180) == "4000 / 3000"
      assert MediaCanvasViewer.pane_aspect(file(4000, 3000), 0) == "4000 / 3000"

      # Rotation reaches the viewer as metadata, which is a string there.
      assert MediaCanvasViewer.pane_aspect(file(4000, 3000), "90") == "3000 / 4000"
      assert MediaCanvasViewer.pane_aspect(file(4000, 3000), "garbage") == "4000 / 3000"
    end

    test "is nothing at all when the file has no shape to give" do
      # A PDF, an audio file, a picture whose probe failed: the pane falls
      # back to a fixed height rather than to an aspect of nothing.
      assert MediaCanvasViewer.pane_aspect(%{}) == nil
      assert MediaCanvasViewer.pane_aspect(file(nil, nil)) == nil
      assert MediaCanvasViewer.pane_aspect(file(800, nil)) == nil
      assert MediaCanvasViewer.pane_aspect(file(0, 600)) == nil
      assert MediaCanvasViewer.pane_aspect(file(-4, 3)) == nil
    end

    test "a neighbour announces its own, rotation included" do
      # Stepping prev/next repaints the stand-in with the neighbour's bitmap
      # before any viewer has read that file's metadata, so the rotation comes
      # off the row.
      assert MediaCanvasViewer.neighbor_pane_aspect(%{width: 800, height: 600}) == "800 / 600"

      assert MediaCanvasViewer.neighbor_pane_aspect(%{width: 800, height: 600, rotation: 90}) ==
               "600 / 800"

      assert MediaCanvasViewer.neighbor_pane_aspect(%{width: 800, height: 600, rotation: nil}) ==
               "800 / 600"

      # No nil clause on purpose: the template guards the lookup the same way
      # it guards `data-step-prev-src`, and a clause nothing can reach is one
      # dialyzer flags rather than one that protects anybody.
      assert_raise FunctionClauseError, fn -> MediaCanvasViewer.neighbor_pane_aspect(nil) end
    end
  end

  describe "the burned copy" do
    test "which is what the viewer keys the burned copy on" do
      urls = %{"burned_large" => "/f/1/burned_large", "large" => "/f/1/large"}

      assert MediaCanvasViewer.burned?(%{
               urls: urls,
               burn_size: %{variant: "burned_large", w: 1920, h: 888}
             })

      refute MediaCanvasViewer.burned?(%{urls: urls}),
             "no burn_size, no burned copy — this is the bit a host that does not " <>
               "supply it was missing"

      refute MediaCanvasViewer.burned?(%{
               urls: %{"large" => "/f/1/large"},
               burn_size: %{variant: "burned_large", w: 1920, h: 888}
             }),
             "…and a burn_size naming a variant with no URL is not one either"
    end
  end

  describe "the browser corrects the prediction" do
    # `pane_aspect/2` is right about the picture as uploaded. It is not always
    # right about what gets PAINTED: the viewer opens on a burned copy where
    # one exists, and a burn is not always composed at the picture's ratio —
    # this dev library holds a 1.685 photograph whose burned_large is 1.332.
    # Left uncorrected the pane holds a shape the picture does not have and
    # bands of empty canvas appear down its sides.
    @hook Path.join(__DIR__, "../../../priv/static/assets/phoenix_kit.js")

    test "the pane carries a handle for the hook to find" do
      assert viewer_source() =~ "data-viewer-pane"
      assert viewer_source() =~ ~s|phx-hook="ViewerPaneFit"|
    end

    test "the hook measures the bitmap on screen, not the file" do
      # Bounded at the next hook's registration: run to the end of the file
      # instead and every assertion here is satisfied by somebody else's
      # code, which is how the first draft of this test passed while the
      # `load` listener was deleted.
      hook =
        @hook
        |> File.read!()
        |> String.split("window.PhoenixKitHooks.ViewerPaneFit")
        |> Enum.at(1)
        |> String.split("window.PhoenixKitHooks.")
        |> Enum.at(0)

      assert hook =~ "naturalWidth", "the correction is the decoded bitmap's own size"
      assert hook =~ "rotate-(90|270)", "a quarter turn swaps the axes here too"
      assert hook =~ "--pk-pane-aspect"

      assert hook =~ "addEventListener(\"load\"",
             "the viewer's ladder climbs small → large while it is open, so " <>
               "the correction has to survive the rung changing under it"

      assert hook =~ "removeEventListener",
             "and let go of the picture it was listening to"
    end
  end
end
