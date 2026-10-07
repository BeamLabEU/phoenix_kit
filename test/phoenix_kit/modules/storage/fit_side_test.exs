defmodule PhoenixKit.Modules.Storage.FitSideTest do
  @moduledoc """
  A rendition that keeps proportions fixes one side and lets the other follow each
  photo: its width (a column as tall as it needs to be: a vertical panorama) or its
  height (a row as long as it needs to be: a horizontal one). What the rendition
  accepts, what its spec hash says, and, where ImageMagick is installed, the
  thumbnails of real panoramas.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{Dimension, ImageProcessor, VariantSets}

  defp changeset(attrs) do
    Dimension.changeset(
      %Dimension{},
      Map.merge(
        %{name: "strip", applies_to: "image", maintain_aspect_ratio: true},
        Map.new(attrs)
      )
    )
  end

  defp errors(changeset), do: Ecto.Changeset.traverse_errors(changeset, fn {m, _} -> m end)

  describe "what a rendition accepts" do
    test "fixes the width unless it says the height" do
      assert %Dimension{}.fit_by == "width"
      assert Dimension.fit_sides() == ~w(width height)
    end

    test "a fixed height needs a height, and no width" do
      assert changeset(%{fit_by: "height", height: 300}).valid?

      assert %{height: ["height is required when the height is fixed"]} =
               errors(changeset(%{fit_by: "height"}))

      refute errors(changeset(%{fit_by: "height", height: 300})) |> Map.has_key?(:width)
    end

    test "a fixed width still needs a width" do
      assert changeset(%{width: 300}).valid?
      assert %{width: ["width is required"]} = errors(changeset(%{fit_by: "width"}))
    end

    test "the width of a fixed-height rendition is dropped, so it is not picked by width" do
      changeset = changeset(%{fit_by: "height", height: 300, width: 500})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :width) == nil
    end

    test "refuses another side" do
      refute changeset(%{width: 300, fit_by: "diagonal"}).valid?
    end

    test "a fixed box ignores it: both sides are set" do
      changeset =
        changeset(%{maintain_aspect_ratio: false, width: 400, height: 300, fit_by: "height"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :width) == 400
    end

    test "a standard size keeps fixing its width" do
      assert %{fit_by: [message]} =
               errors(changeset(%{name: "small", fit_by: "height", height: 300}))

      assert message =~ "must stay on width"

      assert changeset(%{name: "small", width: 300}).valid?
    end

    test "only a rendition that keeps proportions can fix its height" do
      assert Dimension.fixed_height?(%Dimension{maintain_aspect_ratio: true, fit_by: "height"})
      refute Dimension.fixed_height?(%Dimension{maintain_aspect_ratio: true, fit_by: "width"})
      refute Dimension.fixed_height?(%Dimension{maintain_aspect_ratio: false, fit_by: "height"})
    end
  end

  describe "the spec hash" do
    defp dimension(attrs) do
      struct!(
        Dimension,
        Map.merge(
          %{
            name: "strip",
            width: 300,
            height: 300,
            quality: 85,
            format: "jpg",
            applies_to: "image",
            maintain_aspect_ratio: true
          },
          Map.new(attrs)
        )
      )
    end

    test "a fixed height is a different picture from a fixed width" do
      refute VariantSets.spec_hash(dimension(fit_by: "width")) ==
               VariantSets.spec_hash(dimension(fit_by: "height"))
    end

    test "a fixed width leaves every existing hash as it was, so V211 remakes nothing" do
      assert VariantSets.spec_hash(dimension(fit_by: "width")) ==
               VariantSets.spec_hash(dimension([]))
    end

    test "the side means nothing for a fixed box" do
      assert VariantSets.spec_hash(dimension(maintain_aspect_ratio: false, fit_by: "height")) ==
               VariantSets.spec_hash(dimension(maintain_aspect_ratio: false, fit_by: "width"))
    end
  end

  describe "real panoramas" do
    @describetag :integration
    @describetag :tmp_dir

    defp imagemagick?,
      do: match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))

    defp image!(dir, name, size) do
      path = Path.join(dir, name)
      {_, 0} = System.cmd("convert", ["-size", size, "gradient:red-blue", path])
      path
    end

    defp size_of(path),
      do: elem(System.cmd("identify", ["-format", "%wx%h", path]), 0) |> String.trim()

    test "a horizontal panorama gets a fixed height and the width it needs", %{tmp_dir: dir} do
      if imagemagick?() do
        out = Path.join(dir, "wide.jpg")
        pano = image!(dir, "pano.png", "4000x400")

        assert {:ok, _} = ImageProcessor.resize(pano, out, nil, 200, format: "jpg")
        assert size_of(out) == "2000x200"
      end
    end

    test "a vertical panorama gets a fixed width and the height it needs", %{tmp_dir: dir} do
      if imagemagick?() do
        out = Path.join(dir, "tall.jpg")
        pano = image!(dir, "tall.png", "400x4000")

        assert {:ok, _} = ImageProcessor.resize(pano, out, 200, nil, format: "jpg")
        assert size_of(out) == "200x2000"
      end
    end

    test "an ordinary photo follows the same rule, whichever side is fixed", %{tmp_dir: dir} do
      if imagemagick?() do
        photo = image!(dir, "photo.png", "1600x1000")
        by_height = Path.join(dir, "h.jpg")
        by_width = Path.join(dir, "w.jpg")

        assert {:ok, _} = ImageProcessor.resize(photo, by_height, nil, 250, format: "jpg")
        assert {:ok, _} = ImageProcessor.resize(photo, by_width, 400, nil, format: "jpg")

        assert size_of(by_height) == "400x250"
        assert size_of(by_width) == "400x250"
      end
    end

    test "a panorama smaller than the size is not enlarged", %{tmp_dir: dir} do
      if imagemagick?() do
        out = Path.join(dir, "small.jpg")
        small = image!(dir, "small.png", "600x100")

        assert {:ok, _} = ImageProcessor.resize(small, out, nil, 300, format: "jpg")
        assert size_of(out) == "600x100"
      end
    end
  end
end
