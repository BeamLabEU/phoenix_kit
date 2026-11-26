defmodule PhoenixKit.Modules.Storage.WatermarkTest do
  @moduledoc """
  A variant set's watermark (V237) without a database: the config's validation,
  which sizes carry it, its part of the spec hash, the escaping of its text, and
  the drawing itself on small generated pictures (a strip below and over the
  picture, a corner mark with text and with a logo), checked by the output's size
  and the colour of the regions it should and should not touch.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage.{Dimension, VariantSets, Watermark, WatermarkRenderer}

  @moduletag :tmp_dir

  defp changeset(attrs), do: Watermark.changeset(%Watermark{}, attrs)

  defp watermark!(attrs) do
    {:ok, watermark} = attrs |> changeset() |> Ecto.Changeset.apply_action(:insert)
    watermark
  end

  describe "config" do
    test "the defaults are off and valid" do
      assert changeset(%{}).valid?
      refute watermark!(%{}).enabled
    end

    test "on, it needs a text or a logo, and at least one size" do
      cs = changeset(%{enabled: true, text: "", dimensions: ["large"]})
      assert {"give a text or a logo", _} = cs.errors[:text]

      assert changeset(%{
               enabled: true,
               text: "",
               logo_file_uuid: Ecto.UUID.generate(),
               dimensions: ["large"]
             }).valid?

      cs = changeset(%{"enabled" => "true", "text" => "x", "dimensions" => [""]})
      assert {"choose at least one rendition", _} = cs.errors[:dimensions]
    end

    test "modes, positions, corners, colours and ranges are checked" do
      for {attrs, field} <- [
            {%{mode: "overlay"}, :mode},
            {%{strip_position: "top"}, :strip_position},
            {%{corner: "middle"}, :corner},
            {%{background_color: "white"}, :background_color},
            {%{text_color: "#12345"}, :text_color},
            {%{strip_height_percent: 50}, :strip_height_percent},
            {%{background_opacity: 101}, :background_opacity},
            {%{mark_size_percent: 2}, :mark_size_percent},
            {%{opacity: 0}, :opacity},
            {%{margin_percent: -1}, :margin_percent},
            {%{text: String.duplicate("a", 201)}, :text},
            {%{logo_file_uuid: "not-a-uuid"}, :logo_file_uuid}
          ] do
        assert Keyword.has_key?(changeset(attrs).errors, field), inspect(attrs)
      end
    end

    test "the text loses control characters, a blank logo is none, sizes are de-duplicated" do
      wm =
        watermark!(%{
          "text" => " a\nb\u0007 ",
          "logo_file_uuid" => "",
          "dimensions" => ["", "large", "large", " medium "]
        })

      assert wm.text == "ab"
      assert wm.logo_file_uuid == nil
      assert wm.dimensions == ["large", "medium"]
    end

    test "only an enabled watermark goes on the sizes it names" do
      on = watermark!(%{enabled: true, text: "x", dimensions: ["large"]})
      assert Watermark.for_size(on, %Dimension{name: "large"}) == on
      assert Watermark.for_size(on, %Dimension{name: "thumbnail"}) == nil
      assert Watermark.for_size(%{on | enabled: false}, %Dimension{name: "large"}) == nil
      assert Watermark.for_size(nil, %Dimension{name: "large"}) == nil
    end
  end

  describe "spec hash" do
    test "a size without a watermark keeps its old hash; one with it gets another, by its look" do
      size = %Dimension{name: "large", width: 1200, quality: 85, format: "jpg"}
      plain = VariantSets.spec_hash(size)
      on = watermark!(%{enabled: true, text: "x", dimensions: ["large"]})

      assert VariantSets.spec_hash(%{size | watermark: nil}) == plain
      marked = VariantSets.spec_hash(%{size | watermark: on})
      refute marked == plain

      # Which sizes carry it does not change the pixels of this one; its look does.
      assert VariantSets.spec_hash(%{size | watermark: %{on | dimensions: ["large", "x"]}}) ==
               marked

      refute VariantSets.spec_hash(%{size | watermark: %{on | text: "y"}}) == marked
      refute VariantSets.spec_hash(%{size | watermark: %{on | mode: "corner"}}) == marked
    end
  end

  describe "escape_text/1" do
    test "percent escapes, a leading @ and backslashes are literal" do
      assert WatermarkRenderer.escape_text("100% %[fx:1] %w") == "100%% %%[fx:1] %%w"
      assert WatermarkRenderer.escape_text("@/etc/passwd") == "\\@/etc/passwd"
      assert WatermarkRenderer.escape_text("a\\nb") == "a\\\\nb"
      assert WatermarkRenderer.escape_text("a@b.com") == "a@b.com"
    end
  end

  describe "drawing" do
    defp picture!(dir, name, size, colour) do
      path = Path.join(dir, name)
      {_, 0} = System.cmd("convert", ["-size", size, "xc:#{colour}", path])
      path
    end

    defp size_of(path) do
      {out, 0} = System.cmd("identify", ["-format", "%w %h", path])
      out |> String.split() |> Enum.map(&String.to_integer/1)
    end

    # The mean of each channel (0-1) of a region.
    defp mean(path, geometry) do
      {out, 0} =
        System.cmd("convert", [
          path,
          "-crop",
          geometry,
          "+repage",
          "-format",
          "%[fx:mean.r] %[fx:mean.g] %[fx:mean.b]",
          "info:"
        ])

      out |> String.split() |> Enum.map(&String.to_float(normalise(&1)))
    end

    defp normalise(n), do: if(String.contains?(n, "."), do: n, else: n <> ".0")

    defp red?([r, g, b]), do: r > 0.95 and g < 0.05 and b < 0.05

    # The share of a region's pixels that are no longer red.
    defp changed_share(path, geometry) do
      {out, 0} =
        System.cmd("convert", [
          path,
          "-crop",
          geometry,
          "+repage",
          "-fx",
          "r>0.9&&g<0.1&&b<0.1?0:1",
          "-format",
          "%[fx:mean]",
          "info:"
        ])

      out |> String.split() |> List.last() |> normalise() |> String.to_float()
    end

    test "a strip below makes the picture taller and leaves the picture as it was", %{
      tmp_dir: dir
    } do
      path = picture!(dir, "a.png", "400x200", "red")
      wm = watermark!(%{enabled: true, text: "example.com", dimensions: ["large"]})

      assert {:ok, ^path} = WatermarkRenderer.render(path, wm)
      # 6% of 400 is 24, the least a strip is.
      assert size_of(path) == [400, 224]
      assert red?(mean(path, "400x200+0+0"))

      [r, g, b] = mean(path, "400x24+0+200")
      # A white bar with dark text on its right.
      assert r > 0.6 and g > 0.6 and b > 0.6
      refute mean(path, "200x24+200+200") == [1.0, 1.0, 1.0]
    end

    test "a strip over the picture keeps its size and covers only the bottom", %{tmp_dir: dir} do
      path = picture!(dir, "b.jpg", "400x200", "red")

      wm =
        watermark!(%{
          enabled: true,
          text: "example.com",
          strip_position: "over",
          background_color: "#000000",
          background_opacity: 100,
          text_color: "#ffffff",
          dimensions: ["large"]
        })

      assert {:ok, _} = WatermarkRenderer.render(path, wm, quality: 90)
      assert size_of(path) == [400, 200]
      assert red?(mean(path, "400x150+0+0"))
      [r, _g, _b] = mean(path, "400x20+0+178")
      assert r < 0.5
    end

    test "a corner mark of text changes only its corner", %{tmp_dir: dir} do
      path = picture!(dir, "c.png", "400x200", "red")

      wm =
        watermark!(%{
          enabled: true,
          mode: "corner",
          corner: "bottom_right",
          text: "SAMPLE",
          text_color: "#ffffff",
          opacity: 100,
          mark_size_percent: 40,
          dimensions: ["large"]
        })

      assert {:ok, _} = WatermarkRenderer.render(path, wm)
      assert size_of(path) == [400, 200]
      assert red?(mean(path, "200x100+0+0"))
      assert changed_share(path, "160x40+228+148") > 0.02
      assert changed_share(path, "200x100+0+0") == 0.0
    end

    test "a corner mark of a logo is drawn in the chosen corner, see-through by its opacity",
         %{tmp_dir: dir} do
      path = picture!(dir, "d.png", "400x200", "red")
      logo = picture!(dir, "logo.png", "50x50", "blue")

      wm =
        watermark!(%{
          enabled: true,
          mode: "corner",
          corner: "top_left",
          text: "",
          logo_file_uuid: Ecto.UUID.generate(),
          opacity: 50,
          margin_percent: 0,
          mark_size_percent: 20,
          dimensions: ["large"]
        })

      assert {:ok, _} = WatermarkRenderer.render(path, wm, logo_path: logo)
      assert size_of(path) == [400, 200]
      # 20% of 400 = 80 px: half blue, half red at 50%.
      [r, _g, b] = mean(path, "60x60+5+5")
      assert r > 0.3 and r < 0.7 and b > 0.3 and b < 0.7
      assert red?(mean(path, "200x100+200+100"))
    end

    test "a strip with a logo and text has both", %{tmp_dir: dir} do
      path = picture!(dir, "e.png", "600x300", "red")
      logo = picture!(dir, "logo2.png", "100x100", "blue")

      wm =
        watermark!(%{
          enabled: true,
          text: "shop.example",
          logo_file_uuid: Ecto.UUID.generate(),
          strip_height_percent: 10,
          dimensions: ["large"]
        })

      assert {:ok, _} = WatermarkRenderer.render(path, wm, logo_path: logo)
      assert size_of(path) == [600, 360]
      # The logo on the left of the bar is blue.
      [_r, _g, b] = mean(path, "30x30+20+315")
      assert b > 0.9
    end

    test "a picture it cannot read is left alone with an error", %{tmp_dir: dir} do
      path = Path.join(dir, "junk.png")
      File.write!(path, "not a picture")
      wm = watermark!(%{enabled: true, text: "x", dimensions: ["large"]})

      assert {:error, _} = WatermarkRenderer.render(path, wm)
      assert File.read!(path) == "not a picture"
    end

    test "the temp output is removed when it cannot be moved into place", %{tmp_dir: dir} do
      path = picture!(dir, "g.png", "40x20", "red")
      out = Path.join(dir, "g.wm.png")
      before = File.read!(path)

      # convert exits 0 without writing the output.
      quiet = fn "convert", _args, _opts -> {"", 0} end

      capture_log(fn ->
        assert {:error, :watermark_failed} = WatermarkRenderer.run_convert([], out, path, quiet)
      end)

      assert File.read!(path) == before
      refute File.exists?(out)

      # The output is written, but the move fails (here: onto a directory that is
      # not empty, as a full disk or a vanished directory would).
      busy = Path.join(dir, "busy")
      File.mkdir_p!(Path.join(busy, "inside"))
      writes = fn "convert", _args, _opts -> {File.write!(out, "x") && "", 0} end

      capture_log(fn ->
        assert {:error, :watermark_failed} = WatermarkRenderer.run_convert([], out, busy, writes)
      end)

      refute File.exists?(out)

      # Anything raising on the way still removes it.
      raises = fn "convert", _args, _opts ->
        File.write!(out, "x")
        raise "boom"
      end

      assert_raise RuntimeError, fn -> WatermarkRenderer.run_convert([], out, path, raises) end
      refute File.exists?(out)
      assert File.read!(path) == before
    end

    test "nothing to draw is an error", %{tmp_dir: dir} do
      path = picture!(dir, "f.png", "40x20", "red")
      wm = %Watermark{enabled: true, text: "", dimensions: ["large"]}
      assert {:error, :nothing_to_draw} = WatermarkRenderer.render(path, wm)
    end
  end
end
