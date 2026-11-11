defmodule PhoenixKit.Modules.Storage.AnnotationThumbnailRasterTest do
  @moduledoc """
  `Etcher.Raster` draws a text or callout label from `metadata.title`. The
  words themselves live in the annotation's `title` column — the same split
  the live viewer already projects the other way when it loads a file. A
  top-level `"title"` key on the wire map is ignored, so a bake that puts
  the column there produces an empty box.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Annotations.Annotation
  alias PhoenixKit.Modules.Storage.AnnotationThumbnail

  test "the column title is what Raster draws, ahead of a stale metadata copy" do
    ann = %Annotation{
      kind: "text",
      title: "North wall",
      geometry: %{"x" => 10, "y" => 20, "w" => 80, "h" => 30},
      style: %{"color" => "#112233"},
      metadata: %{"title" => "stale"}
    }

    args =
      ann
      |> List.wrap()
      |> AnnotationThumbnail.raster_annotations()
      |> Etcher.Raster.to_draw_args()

    assert Enum.any?(args, &(&1 =~ "North wall"))
    refute Enum.any?(args, &(&1 =~ "stale"))
  end

  test "a metadata title is kept when the column is empty" do
    ann = %Annotation{
      kind: "callout",
      title: "  ",
      geometry: %{
        "anchor" => %{"x" => 0, "y" => 0},
        "text_box" => %{"x" => 10, "y" => 20, "w" => 80, "h" => 30}
      },
      metadata: %{"title" => "From the metadata"}
    }

    args =
      ann
      |> List.wrap()
      |> AnnotationThumbnail.raster_annotations()
      |> Etcher.Raster.to_draw_args()

    assert Enum.any?(args, &(&1 =~ "From the metadata"))
  end

  describe "font_args/1" do
    test "no font for an outline-only draw" do
      assert AnnotationThumbnail.font_args(["-stroke", "red", "-draw", "rectangle 1,1 5,5"]) ==
               []
    end

    test "a font before a text draw, when ImageMagick has one" do
      args = ["-pointsize", "20", "-draw", "text 1,1 'x'"]

      if System.find_executable("convert") do
        assert ["-font", font] = AnnotationThumbnail.font_args(args)
        assert is_binary(font) and font != ""
      else
        assert AnnotationThumbnail.font_args(args) == []
      end
    end
  end
end
