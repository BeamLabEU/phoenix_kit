defmodule PhoenixKit.Modules.Storage.HdrSynthTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Hdr
  alias PhoenixKit.Modules.Storage.HdrResize
  alias PhoenixKit.Modules.Storage.HdrSynth

  @moduletag :tmp_dir

  # A picture with a dark half (left) and a white half (right), written by ImageMagick,
  # the tool a real photo goes through.
  defp source(ctx, opts \\ []) do
    path = Path.join(ctx.tmp_dir, Keyword.get(opts, :name, "src.jpg"))

    {_, 0} =
      System.cmd(
        "convert",
        ["-size", "400x300", "xc:gray15", "-fill", "white", "-draw", "rectangle 200,0 399,299"] ++
          ["-quality", "90", path],
        stderr_to_stdout: true
      )

    if n = opts[:orientation], do: put_orientation(path, n)
    path
  end

  # ImageMagick writes no EXIF orientation of its own, so the segment is put in by hand,
  # right after JFIF: `Exif`, a TIFF header and one entry (tag 0x0112, SHORT).
  defp put_orientation(path, n) do
    bin = File.read!(path)
    {segments, _core_at} = HdrResize.segments(bin)
    jfif = Enum.find(segments, &(&1.marker == 0xE0))

    body =
      <<"Exif\0\0", "MM", 42::16, 8::32, 1::16, 0x0112::16, 3::16, 1::32, n::16, 0::16, 0::32>>

    exif = <<0xFF, 0xE1, byte_size(body) + 2::16, body::binary>>
    at = jfif.at + byte_size(jfif.raw)

    File.write!(
      path,
      binary_part(bin, 0, at) <> exif <> binary_part(bin, at, byte_size(bin) - at)
    )
  end

  defp dest(ctx), do: Path.join(ctx.tmp_dir, "out_#{System.unique_integer([:positive])}.jpg")

  # The gain map of an Ultra HDR file, as a file of its own.
  defp gain_map_of(ctx, path) do
    {:ok, %{gain: gain}} = path |> File.read!() |> HdrResize.split()
    out = Path.join(ctx.tmp_dir, "gain_#{System.unique_integer([:positive])}.jpg")
    File.write!(out, gain)
    out
  end

  # The mean brightness (0..1) of the left and right half of a picture.
  defp halves(path) do
    mean = fn gravity ->
      {out, 0} =
        System.cmd(
          "magick",
          [path, "-gravity", gravity, "-crop", "50%x100%+0+0", "+repage"] ++
            ["-format", "%[fx:mean]", "info:"],
          stderr_to_stdout: true
        )

      {value, _} = out |> String.split() |> List.last() |> Float.parse()
      value
    end

    {mean.("west"), mean.("east")}
  end

  describe "make/3" do
    test "writes an Ultra HDR JPEG that Hdr.read sees", ctx do
      out = dest(ctx)

      assert {:ok, %{width: 400, height: 300, gain_map_bytes: bytes, headroom: headroom}} =
               HdrSynth.make(source(ctx), out)

      assert_in_delta headroom, :math.pow(2, 1.5), 1.0e-9

      assert %{
               "gain_map" => true,
               "kinds" => ["ultrahdr"],
               "gain_map_bytes" => ^bytes,
               "headroom" => seen
             } = Hdr.read(out)

      assert_in_delta seen, headroom, 1.0e-6
    end

    test "copies the picture's JPEG data byte for byte", ctx do
      src = source(ctx)
      out = dest(ctx)
      {:ok, _} = HdrSynth.make(src, out)

      bin = File.read!(src)
      {_segments, core_at} = HdrResize.segments(bin)
      core = binary_part(bin, core_at, byte_size(bin) - core_at)

      assert {_, _} = :binary.match(File.read!(out), core)
    end

    test "boosts the bright half and leaves the dark one alone", ctx do
      out = dest(ctx)
      {:ok, _} = HdrSynth.make(source(ctx), out)

      {dark, bright} = out |> then(&gain_map_of(ctx, &1)) |> halves()

      assert dark < 0.05
      assert bright > 0.7
    end

    test "midtone_lift: 0 leaves the shadows with no boost at all", ctx do
      out = dest(ctx)
      {:ok, _} = HdrSynth.make(source(ctx), out, midtone_lift: 0)

      {dark, _bright} = out |> then(&gain_map_of(ctx, &1)) |> halves()
      assert dark < 0.01
    end

    test "a higher midtone_lift lifts the dark half more", ctx do
      src = source(ctx)
      a = dest(ctx)
      b = dest(ctx)
      {:ok, _} = HdrSynth.make(src, a, midtone_lift: 0)

      {:ok, _} =
        HdrSynth.make(src, b, midtone_lift: 0.6, midtone_start: 0.0, midtone_end: 0.1)

      {dark_a, _} = halves(gain_map_of(ctx, a))
      {dark_b, _} = halves(gain_map_of(ctx, b))
      assert dark_b > dark_a + 0.03
    end

    test ":ceiling is the headroom's log2", ctx do
      out = dest(ctx)
      assert {:ok, %{headroom: headroom}} = HdrSynth.make(source(ctx), out, ceiling: 2)
      assert_in_delta headroom, 4.0, 1.0e-9
      assert %{"headroom" => seen} = Hdr.read(out)
      assert_in_delta seen, 4.0, 1.0e-6
    end

    test ":map_size sets the gain map's longest side", ctx do
      out = dest(ctx)
      {:ok, _} = HdrSynth.make(source(ctx), out, map_size: 100)

      {dims, 0} =
        System.cmd("identify", ["-format", "%wx%h", gain_map_of(ctx, out)],
          stderr_to_stdout: true
        )

      assert dims == "100x75"
    end

    test "never makes a map larger than the photo", ctx do
      out = dest(ctx)
      {:ok, _} = HdrSynth.make(source(ctx), out, map_size: 4096)

      {dims, 0} =
        System.cmd("identify", ["-format", "%wx%h", gain_map_of(ctx, out)],
          stderr_to_stdout: true
        )

      assert dims == "400x300"
    end

    test "keeps the EXIF orientation, and draws the map in the stored frame", ctx do
      out = dest(ctx)
      {:ok, _} = HdrSynth.make(source(ctx, orientation: 6), out, map_size: 100)

      {orient, 0} =
        System.cmd("identify", ["-format", "%[orientation]", out <> "[0]"],
          stderr_to_stdout: true
        )

      assert orient == "RightTop"

      # stored 400x300, so the map is 100x75 whatever the orientation says
      {dims, 0} =
        System.cmd("identify", ["-format", "%wx%h", gain_map_of(ctx, out)],
          stderr_to_stdout: true
        )

      assert dims == "100x75"
    end

    test "leaves out what follows the picture's end, such as a camera's preview", ctx do
      src = source(ctx)
      preview = Path.join(ctx.tmp_dir, "preview.jpg")
      {_, 0} = System.cmd("convert", ["-size", "64x48", "plasma:", "-quality", "80", preview])
      preview_bin = File.read!(preview)
      File.write!(src, File.read!(src) <> preview_bin)

      out = dest(ctx)
      assert {:ok, _} = HdrSynth.make(src, out)

      out_bin = File.read!(out)
      assert :binary.match(out_bin, preview_bin) == :nomatch
      assert %{"gain_map" => true, "kinds" => ["ultrahdr"]} = Hdr.read(out)
      assert {:ok, %{primary: primary}} = HdrResize.split(out_bin)
      assert binary_part(primary, byte_size(primary) - 2, 2) == <<0xFF, 0xD9>>
    end

    test "finds the end of a progressive JPEG, past every scan", ctx do
      src = Path.join(ctx.tmp_dir, "progressive.jpg")

      {_, 0} =
        System.cmd("convert", ["-size", "300x200", "plasma:", "-interlace", "JPEG", src])

      bin = File.read!(src)
      {_segments, core_at} = HdrResize.segments(bin)
      core = binary_part(bin, core_at, byte_size(bin) - core_at)
      trailer = <<0xFF, 0xD8, "not part of the picture", 0xFF, 0xD9>>
      File.write!(src, bin <> trailer)

      out = dest(ctx)
      assert {:ok, _} = HdrSynth.make(src, out)

      out_bin = File.read!(out)
      assert {_, _} = :binary.match(out_bin, core)
      assert :binary.match(out_bin, trailer) == :nomatch
    end

    test "refuses a CMYK JPEG", ctx do
      src = Path.join(ctx.tmp_dir, "cmyk.jpg")
      {_, 0} = System.cmd("convert", ["-size", "40x30", "xc:red", "-colorspace", "CMYK", src])
      out = dest(ctx)
      assert HdrSynth.make(src, out) == {:error, :unsupported_colour}
      refute File.exists?(out)
    end

    test "refuses what is not a JPEG", ctx do
      png = Path.join(ctx.tmp_dir, "src.png")
      {_, 0} = System.cmd("convert", ["-size", "20x20", "xc:white", png])
      assert HdrSynth.make(png, dest(ctx)) == {:error, :not_a_jpeg}
    end

    test "refuses a photo that is HDR already, and writes nothing", ctx do
      out = dest(ctx)
      {:ok, _} = HdrSynth.make(source(ctx), out)

      again = dest(ctx)
      assert HdrSynth.make(out, again) == {:error, :already_hdr}
      refute File.exists?(again)
    end

    test "a missing file is an error, not a crash", ctx do
      assert {:error, :enoent} = HdrSynth.make(Path.join(ctx.tmp_dir, "nope.jpg"), dest(ctx))
    end

    test "writes nothing when an option is wrong", ctx do
      out = dest(ctx)
      assert {:error, {:bad_option, :ceiling, _}} = HdrSynth.make(source(ctx), out, ceiling: 99)
      refute File.exists?(out)
    end
  end

  describe "normalize/1" do
    test "fills the defaults in" do
      assert {:ok, opts} = HdrSynth.normalize([])
      assert opts == HdrSynth.defaults()
      assert opts.ceiling == 1.5
    end

    test "takes a map or a keyword list, and turns integers into floats where a float is meant" do
      assert {:ok, %{ceiling: 2.0}} = HdrSynth.normalize(ceiling: 2)
      assert {:ok, %{ceiling: 2.0}} = HdrSynth.normalize(%{ceiling: 2})
    end

    test "rejects an unknown option" do
      assert HdrSynth.normalize(cieling: 2) == {:error, {:unknown_option, :cieling}}
    end

    test "rejects out-of-range and mistyped values" do
      assert {:error, {:bad_option, :ceiling, _}} = HdrSynth.normalize(ceiling: 0)

      assert {:error, {:bad_option, :ceiling, "must be a number"}} =
               HdrSynth.normalize(ceiling: "2")

      assert {:error, {:bad_option, :smoothing, _}} = HdrSynth.normalize(smoothing: 1.5)
      assert {:error, {:bad_option, :quality, _}} = HdrSynth.normalize(quality: 20)
    end

    test "rejects a range that runs backwards" do
      assert {:error, {:bad_option, :highlight_start, _}} =
               HdrSynth.normalize(highlight_start: 0.9, highlight_end: 0.5)

      assert {:error, {:bad_option, :midtone_start, _}} =
               HdrSynth.normalize(midtone_start: 0.5, midtone_end: 0.2)
    end
  end

  describe "option_specs/0" do
    test "describes every default, each one inside its own range" do
      specs = HdrSynth.option_specs()
      assert Enum.sort(Enum.map(specs, & &1.key)) == Enum.sort(Map.keys(HdrSynth.defaults()))

      for %{default: d, min: min, max: max, description: doc} <- specs do
        assert d >= min and d <= max
        assert doc != ""
      end
    end
  end
end
