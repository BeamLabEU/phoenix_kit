defmodule PhoenixKit.Modules.Storage.FocusCropTest do
  @moduledoc """
  Cropping a rendition around the subject: the window math (`focus_window/3`), the
  rendition's crop mode and its place in the spec hash, and, where ImageMagick is
  installed, the crop of a real photo, which keeps a subject at the edge in frame
  where the center crop cuts it off.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{Dimension, ImageProcessor, VariantSets}

  describe "focus_window/3" do
    test "a square window on a landscape photo is the full height" do
      assert {1000, 1000, left, 0} =
               ImageProcessor.focus_window({0.5, 0.5}, {1600, 1000}, {300, 300})

      assert left == 300
    end

    test "follows the subject to the right, and stops at the edge" do
      assert {1000, 1000, 600, 0} =
               ImageProcessor.focus_window({0.81, 0.2}, {1600, 1000}, {300, 300})

      assert {1000, 1000, 600, 0} =
               ImageProcessor.focus_window({1.0, 0.5}, {1600, 1000}, {300, 300})
    end

    test "follows the subject to the left, and stops at the edge" do
      assert {1000, 1000, 0, 0} =
               ImageProcessor.focus_window({0.0, 0.5}, {1600, 1000}, {300, 300})

      assert {1000, 1000, 60, 0} =
               ImageProcessor.focus_window({0.35, 0.5}, {1600, 1000}, {300, 300})
    end

    test "on a portrait photo it moves vertically" do
      assert {1000, 1000, 0, 0} =
               ImageProcessor.focus_window({0.5, 0.0}, {1000, 1600}, {300, 300})

      assert {1000, 1000, 0, 600} =
               ImageProcessor.focus_window({0.5, 1.0}, {1000, 1600}, {300, 300})

      assert {1000, 1000, 0, 300} =
               ImageProcessor.focus_window({0.5, 0.5}, {1000, 1600}, {300, 300})
    end

    test "a window of another shape keeps that shape" do
      # 16:9 out of a 4:3 photo: full width, a shorter window that follows the subject.
      assert {1600, 900, 0, 150} =
               ImageProcessor.focus_window({0.5, 0.5}, {1600, 1200}, {320, 180})

      assert {1600, 900, 0, 300} =
               ImageProcessor.focus_window({0.5, 1.0}, {1600, 1200}, {320, 180})
    end

    test "a photo already of the window's shape is not cropped" do
      assert {1000, 1000, 0, 0} =
               ImageProcessor.focus_window({0.9, 0.1}, {1000, 1000}, {200, 200})
    end

    test "the window is always inside the photo" do
      for fx <- [0.0, 0.25, 0.5, 0.75, 1.0],
          fy <- [0.0, 0.5, 1.0],
          size <- [{1600, 1000}, {1000, 1600}, {999, 701}] do
        {cur_w, cur_h} = size
        {cw, ch, left, top} = ImageProcessor.focus_window({fx, fy}, size, {300, 300})

        assert left >= 0 and top >= 0
        assert left + cw <= cur_w and top + ch <= cur_h
      end
    end
  end

  describe "a rendition's crop mode" do
    defp dimension(attrs) do
      Dimension.new(
        Map.merge(
          %{
            name: "thumbnail",
            width: 400,
            height: 400,
            quality: 85,
            format: "jpg",
            applies_to: "image",
            maintain_aspect_ratio: false,
            crop_mode: "center"
          },
          Map.new(attrs)
        )
      )
    end

    test "is center unless said otherwise" do
      assert Dimension.crop_mode(%Dimension{}) == "center"
      assert Dimension.crop_modes() == ~w(center focus)
    end

    test "only a fixed box can be cropped around the subject" do
      assert Dimension.focus_crop?(dimension(crop_mode: "focus"))
      refute Dimension.focus_crop?(dimension(crop_mode: "center"))
      # A rendition that keeps proportions is not cropped at all.
      refute Dimension.focus_crop?(dimension(crop_mode: "focus", maintain_aspect_ratio: true))
    end

    test "the changeset accepts the two modes and refuses another" do
      attrs = %{
        name: "square",
        width: 400,
        height: 400,
        applies_to: "image",
        maintain_aspect_ratio: false
      }

      assert Dimension.changeset(%Dimension{}, Map.put(attrs, :crop_mode, "focus")).valid?
      assert Dimension.changeset(%Dimension{}, Map.put(attrs, :crop_mode, "center")).valid?
      refute Dimension.changeset(%Dimension{}, Map.put(attrs, :crop_mode, "smart")).valid?
    end

    test "focus changes the spec hash, so the reconciler remakes the rendition" do
      refute VariantSets.spec_hash(dimension(crop_mode: "center")) ==
               VariantSets.spec_hash(dimension(crop_mode: "focus"))
    end

    test "a profile check also remakes focus crops written by 2.56.0" do
      old_hash =
        :crypto.hash(:md5, "v1|w=400|h=400|q=85|f=jpg|a=f|p=2|c=focus")
        |> Base.encode16(case: :lower)

      refute VariantSets.spec_hash(dimension(crop_mode: "focus")) == old_hash
    end

    test "center leaves the spec hash as it was, so V210 remakes nothing" do
      # The hash of an existing fixed thumbnail, as it was before crop modes.
      assert VariantSets.spec_hash(dimension(crop_mode: "center")) ==
               VariantSets.spec_hash(dimension([]))

      # A crop mode on a rendition that keeps proportions changes nothing either.
      assert VariantSets.spec_hash(dimension(maintain_aspect_ratio: true, crop_mode: "focus")) ==
               VariantSets.spec_hash(dimension(maintain_aspect_ratio: true, crop_mode: "center"))
    end
  end

  describe "a real photo" do
    @describetag :integration
    @describetag :tmp_dir

    defp imagemagick?,
      do: match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))

    # 1600x1000 grey noise with a red 120x120 square, centered at (1300, 220).
    defp photo!(dir) do
      path = Path.join(dir, "photo.png")

      {_, 0} =
        System.cmd("convert", [
          "-size",
          "1600x1000",
          "xc:gray(110)",
          "-attenuate",
          "0.15",
          "+noise",
          "Gaussian",
          "-fill",
          "rgb(255,20,20)",
          "-draw",
          "rectangle 1240,160 1360,280",
          path
        ])

      path
    end

    # The share of pixels that are the subject's red, read from the raw pixels:
    # ImageMagick 6 and 7 disagree on how `-format` reports a mean, but both write
    # the same 8-bit gray bytes (255 where the pixel is red, 0 elsewhere).
    defp red_share(path) do
      {bytes, 0} =
        System.cmd("convert", [
          path,
          "-fx",
          "r>0.7&&g<0.45&&b<0.45?1:0",
          "-depth",
          "8",
          "gray:-"
        ])

      red = for <<byte <- bytes>>, byte > 127, reduce: 0, do: (count -> count + 1)
      red / byte_size(bytes)
    end

    test "the focus crop keeps a subject the center crop cuts off", %{tmp_dir: dir} do
      if imagemagick?() do
        photo = photo!(dir)
        center = Path.join(dir, "center.jpg")
        focus = Path.join(dir, "focus.jpg")

        assert {:ok, _} =
                 ImageProcessor.resize_and_crop_center(photo, center, 300, 300, format: "jpg")

        assert {:ok, _} =
                 ImageProcessor.resize_and_crop_focus(photo, focus, 300, 300, {0.8125, 0.22},
                   format: "jpg"
                 )

        assert {"300x300", 0} =
                 {String.trim(elem(System.cmd("identify", ["-format", "%wx%h", focus]), 0)), 0}

        # The square is 120px of 1600: half of it falls outside the center window.
        assert red_share(focus) > red_share(center) * 1.8
      end
    end

    test "never enlarges a photo smaller than the box", %{tmp_dir: dir} do
      if imagemagick?() do
        small = Path.join(dir, "small.png")
        {_, 0} = System.cmd("convert", ["-size", "200x100", "xc:red", small])
        out = Path.join(dir, "small_focus.jpg")

        assert {:ok, _} =
                 ImageProcessor.resize_and_crop_focus(small, out, 400, 400, {0.5, 0.5},
                   format: "jpg"
                 )

        # A square window of the photo, 100x100, not scaled up to 400.
        assert {"100x100", _} =
                 {String.trim(elem(System.cmd("identify", ["-format", "%wx%h", out]), 0)), 0}
      end
    end
  end
end
