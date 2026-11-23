defmodule PhoenixKitWeb.Components.MediaCanvasViewerLabelSyncTest do
  @moduledoc """
  The label half of the media viewer's annotation sync.

  Since Etcher 0.12 the label-bearing kinds (text / callout / dimension)
  collect their text through Etcher's INLINE editor, arriving on the wire as
  `metadata.title` — not through the comment composer, which is what the sync
  was written for. Two silent failure modes are pinned here:

    * a metadata-only change judged "unchanged" (geometry/style/kind-only
      comparison), so the label's DB write was skipped and the text vanished
      on the next open;
    * the wire metadata persisted verbatim, baking the server-injected
      comment preview (`comment_count`, …) into the row.

  `current` in these tests is the CURATED map `load_annotations_for/1`
  produces (title surfaced as `metadata.title`, comment preview injected) —
  the same shape `viewer_annotations` holds. Reading `current.title` as if it
  were a schema struct crashed the LiveView on every label commit.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Components.MediaCanvasViewer, as: Viewer

  # A curated map as load_annotations_for/1 builds it.
  defp curated(attrs) do
    Map.merge(
      %{
        uuid: "01a0-test",
        kind: "callout",
        geometry: %{"anchor" => [1, 2]},
        style: %{"color" => "#fca5a5"},
        metadata: %{"comment_count" => 0, "comment_created_at" => "Aug 15, 2026"}
      },
      attrs
    )
  end

  defp wire(attrs) do
    Map.merge(
      %{
        "uuid" => "01a0-test",
        "kind" => "callout",
        "geometry" => %{"anchor" => [1, 2]},
        "style" => %{"color" => "#fca5a5"}
      },
      attrs
    )
  end

  describe "annotation_unchanged?/2" do
    test "typing a label IS a change, even with geometry/style/kind untouched" do
      w = wire(%{"metadata" => %{"title" => "measure this", "comment_count" => 0}})

      refute Viewer.annotation_unchanged?(w, curated(%{}))
    end

    test "an identical round-trip is unchanged — including the title" do
      w = wire(%{"metadata" => %{"title" => "measure this", "comment_count" => 0}})
      c = curated(%{metadata: %{"title" => "measure this", "comment_count" => 0}})

      assert Viewer.annotation_unchanged?(w, c)
    end

    test "a moved label (title_box) is a change; injected comment keys are not" do
      c =
        curated(%{
          metadata: %{"title" => "t", "title_box" => %{"x" => 1}, "comment_count" => 3}
        })

      moved = wire(%{"metadata" => %{"title" => "t", "title_box" => %{"x" => 99}}})
      refute Viewer.annotation_unchanged?(moved, c)

      # comment_count differing between wire and curated must NOT force a
      # write — it's derived at load, not Etcher-owned state.
      same_label = wire(%{"metadata" => %{"title" => "t", "title_box" => %{"x" => 1}}})
      assert Viewer.annotation_unchanged?(same_label, c)
    end

    test "no crash on curated maps — there is no :title key to read" do
      # The regression shape: current is a plain map whose title lives inside
      # metadata. Reading current.title raised KeyError and took the LV down
      # with every label commit.
      w = wire(%{"metadata" => %{}})
      assert Viewer.annotation_unchanged?(w, curated(%{}))
    end
  end

  describe "persistable_attrs/2" do
    test "the label text goes to the title column, trimmed, blank collapsing to nil" do
      attrs = Viewer.persistable_attrs(wire(%{"metadata" => %{"title" => "  hi  "}}), nil)
      assert attrs["title"] == "hi"

      attrs = Viewer.persistable_attrs(wire(%{"metadata" => %{"title" => "   "}}), nil)
      assert attrs["title"] == nil
    end

    test "wire metadata is never persisted verbatim — only Etcher's label keys survive" do
      w =
        wire(%{
          "metadata" => %{
            "title" => "t",
            "title_box" => %{"x" => 5},
            "title_color" => "#123456",
            "comment_count" => 7,
            "comment_text" => "spoofed",
            "badge" => 7,
            "rogue_key" => true
          }
        })

      attrs = Viewer.persistable_attrs(w, nil)

      assert attrs["metadata"] == %{"title_box" => %{"x" => 5}, "title_color" => "#123456"}
    end

    test "stored server-owned metadata survives, load-injected preview does not" do
      # comment_author is genuinely stored for markers (the byline stamp);
      # comment_count and comment_preview_author are injected at load. A drag
      # must keep the former and shed the latter two — the preview author must
      # never be baked over the byline.
      c =
        curated(%{
          kind: "marker",
          metadata: %{
            "comment_author" => "Alexander Don",
            "comment_count" => 4,
            "comment_preview_author" => "First Commenter",
            "title" => "t",
            "title_box" => %{"x" => 1}
          }
        })

      attrs = Viewer.persistable_attrs(wire(%{"kind" => "marker", "metadata" => %{}}), c)

      assert attrs["metadata"] == %{"comment_author" => "Alexander Don"}
      assert attrs["title"] == nil
    end
  end
end
