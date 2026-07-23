defmodule PhoenixKit.Annotations.AnnotationKindTest do
  @moduledoc """
  Guards the two layers that must agree on the set of allowed annotation
  `kind`s: the schema's `@kinds` (`validate_inclusion`) and the DB
  `phoenix_kit_annotations_kind_check` CHECK constraint. A new Etcher tool
  is only usable when both accept its kind — `"marker"` (V130) was the
  regression that motivated this test: it drew + skipped the composer but
  silently failed to persist because both layers still rejected it.
  `"image"` (V157) repeated the same regression when PR #660 exposed
  Etcher's `:image` tool without widening either layer.
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
