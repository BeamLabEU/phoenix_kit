defmodule PhoenixKit.Annotations.AnnotationKindTest do
  @moduledoc """
  Guards the two layers that must agree on the set of allowed annotation
  `kind`s: the schema's `@kinds` (`validate_inclusion`) and the DB
  `phoenix_kit_annotations_kind_check` CHECK constraint. A new Etcher tool
  is only usable when both accept its kind — `"marker"` (V130) was the
  regression that motivated this test: it drew + skipped the composer but
  silently failed to persist because both layers still rejected it.
  `"image"` (V157) repeated the same regression when PR #660 exposed
  Etcher's `:image` tool without widening either layer. `"arrow"` (V192)
  made it three: Etcher 0.13's single-arrow tool shipped in the viewer's
  toolbar while both layers still rejected the kind — drawing and
  labelling worked, persisting warned and dropped, and the arrows were
  gone on reload.

  The final test therefore stops playing whack-a-mole: every drawing
  tool the media viewer offers must have its kind accepted by the
  schema, so the NEXT tool cannot ship without widening the layers.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Annotations.Annotation

  @geometry %{"path" => [[0, 0], [10, 10]]}

  describe "schema @kinds" do
    test "accepts marker" do
      changeset =
        Annotation.changeset(%Annotation{}, %{
          file_uuid: UUIDv7.generate(),
          kind: "marker",
          geometry: @geometry
        })

      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :kind)
    end

    test "still rejects an unknown kind" do
      changeset =
        Annotation.changeset(%Annotation{}, %{
          file_uuid: UUIDv7.generate(),
          kind: "scribble",
          geometry: @geometry
        })

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:kind]
    end

    test "marker is listed in kinds/0" do
      assert "marker" in Annotation.kinds()
    end

    test "accepts image" do
      changeset =
        Annotation.changeset(%Annotation{}, %{
          file_uuid: UUIDv7.generate(),
          kind: "image",
          geometry: @geometry
        })

      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :kind)
    end

    test "image is listed in kinds/0" do
      assert "image" in Annotation.kinds()
    end

    test "accepts arrow" do
      changeset =
        Annotation.changeset(%Annotation{}, %{
          file_uuid: UUIDv7.generate(),
          kind: "arrow",
          geometry: %{"a" => [0, 0], "b" => [10, 10], "points" => []}
        })

      assert changeset.valid?
      refute Keyword.has_key?(changeset.errors, :kind)
    end

    test "every drawing tool the media viewer offers persists" do
      # The viewer's toolbar is where a kind becomes drawable; the schema
      # is where it becomes durable. Three separate regressions (marker,
      # image, arrow) shipped the first without the second — each drew
      # fine and silently vanished on reload. Read the tool list from the
      # template so a NEW tool fails here before it ships.
      heex =
        [__DIR__, "..", "..", "..", "lib", "phoenix_kit_web", "components"]
        |> Path.join()
        |> Path.join("media_canvas_viewer.html.heex")
        |> Path.expand()
        |> File.read!()

      [tools_block] = Regex.run(~r/tools=\{.*?\]/s, heex)

      # A tool is not always a kind of its own: the highlighter draws
      # MARKER shapes at a fixed opacity, and the textbox draws TEXT
      # shapes carrying `style.box: "fixed"` — deliberate reuses, so
      # their persistence never needed widening. A new alias belongs
      # here with the kind it commits as; a new KIND must not appear
      # here, or this test would wave it through unpersisted.
      tool_kinds = %{"highlighter" => "marker", "textbox" => "text"}

      offered =
        Regex.scan(~r/:(\w+)/, tools_block)
        |> Enum.map(fn [_, t] -> t end)
        # Not annotation kinds: the grabber draws nothing and the eraser
        # deletes; both are tools without a persisted shape.
        |> Enum.reject(&(&1 in ["grabber", "eraser"]))
        |> Enum.map(&Map.get(tool_kinds, &1, &1))

      assert offered != [], "could not read the viewer's tool list"

      for tool <- offered do
        assert tool in Annotation.kinds(),
               "the viewer offers :#{tool} but the schema rejects kind \"#{tool}\" — " <>
                 "it will draw and silently fail to persist (see marker/V130, " <>
                 "image/V157, arrow/V192)"
      end
    end
  end

  describe "DB kind check constraint" do
    test "phoenix_kit_annotations_kind_check allows marker" do
      %{rows: [[def]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'phoenix_kit_annotations_kind_check'"
        )

      assert def =~ "marker",
             "expected the kind CHECK constraint to include 'marker' (V130), got: #{def}"
    end

    test "phoenix_kit_annotations_kind_check allows arrow" do
      %{rows: [[def]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'phoenix_kit_annotations_kind_check'"
        )

      assert def =~ "arrow",
             "expected the kind CHECK constraint to include 'arrow' (V192), got: #{def}"
    end

    test "phoenix_kit_annotations_kind_check allows image" do
      %{rows: [[def]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'phoenix_kit_annotations_kind_check'"
        )

      assert def =~ "image",
             "expected the kind CHECK constraint to include 'image' (V157), got: #{def}"
    end
  end
end
