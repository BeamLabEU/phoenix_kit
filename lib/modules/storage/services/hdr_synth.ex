defmodule PhoenixKit.Modules.Storage.HdrSynth do
  @moduledoc """
  Makes an HDR photo out of an ordinary (SDR) JPEG: an Ultra HDR JPEG, the form
  `HdrResize` writes and `Hdr.read/1` reports as a gain map (the picture, a grey
  gain-map JPEG and a Multi-Picture directory).

  A camera that shoots HDR records a gain map: per pixel, how many stops brighter the
  HDR picture is than the SDR one. A photo that was never shot that way has none, so
  this makes one from the picture itself. It is a tone *expansion*, not a recovery: it
  cannot bring back detail the JPEG has already clipped, it makes the bright parts shine
  on a screen that can show them and leaves the picture as it is on one that cannot.

  ## What is done

    1. The picture's brightness is read in linear light (ImageMagick, at the map's size,
       in the orientation the JPEG is stored in, so the map and the picture line up
       whatever the EXIF orientation says).
    2. Two curves turn it into the map. **Highlights**: nothing below `:highlight_start`,
       a smooth rise to the full boost at `:highlight_end` (the bright feathers, the
       sky, the wall in the sun). **Midtones**: a gentle lift of the rest of the picture
       that starts at `:midtone_start` and is complete at `:midtone_end`, weighted by
       `:midtone_lift` (`0` leaves the shadows and midtones exactly as they were).
    3. The map is smoothed so the boost follows edges without a halo
       (`:smoothing`, an edge-preserving filter, then `:blur`).
    4. `:ceiling` says how many stops white in the map adds (`1.5` is 2.8 times
       brighter). The picture's JPEG data is copied byte for byte, not decoded and
       encoded again (anything after its end, such as a camera's preview pictures, is
       left out); EXIF, the colour profile and the orientation are kept.

  XMP and IPTC of the source are not carried over (as for every HDR rendition core
  writes): the XMP packet is the one that names the map.

  ## Options

  See `option_specs/0` for the list with ranges and defaults; every option is checked
  and a value out of range is `{:error, {:bad_option, key, why}}`, never clamped silently.
  The defaults are the setting that was tried and liked on a heron photo (a strong
  boost of the whites, a light lift of the rest, +1.5 stops); they are a starting
  point, not a law. Things to try:

    * brighter or calmer overall: `:ceiling`
    * only the very brightest parts glow: raise `:highlight_start`, `midtone_lift: 0`
    * a softer, more even lift: raise `:midtone_lift` (0.3), lower `:highlight_weight`
    * sharper map: `smoothing: 0, blur: 0.3` (this can show a halo at edges)

  Anything that cannot be done is an `{:error, _}` and nothing is written: a source
  that is not a JPEG (`:not_a_jpeg`), a CMYK one (`:unsupported_colour`), one that is
  HDR already (`:already_hdr`), one over the pixel budget (`:too_large`), ImageMagick
  failing.
  """

  alias PhoenixKit.Modules.Storage.Hdr
  alias PhoenixKit.Modules.Storage.HdrResize
  alias PhoenixKit.Modules.Storage.HeifHdr
  alias PhoenixKit.Modules.Storage.ImageProcessor

  @xmp "http://ns.adobe.com/xap/1.0/\0"

  # Above any real camera, as in `HeifHdr`.
  @max_pixels 100_000_000

  # The offsets Ultra HDR writers use: they keep the maths away from zero.
  @offset 1 / 64

  # key => {default, min, max, kind, what it does}
  @specs [
    ceiling:
      {1.5, 0.25, 4.0, :float,
       "stops added where the map is white (1 stop is twice as bright); the HDR headroom is 2 to this power"},
    highlight_start:
      {0.38, 0.0, 0.99, :float,
       "linear brightness (1.0 is SDR white) below which the highlight boost is zero"},
    highlight_end:
      {0.85, 0.01, 1.0, :float,
       "linear brightness at and above which the highlight boost is complete"},
    highlight_weight:
      {0.85, 0.0, 1.0, :float,
       "share of the ceiling the highlight curve reaches (the midtone lift adds to it)"},
    midtone_lift:
      {0.18, 0.0, 1.0, :float, "share of the ceiling the midtones are lifted by; 0 is none"},
    midtone_start:
      {0.02, 0.0, 0.99, :float, "linear brightness at which the midtone lift begins"},
    midtone_end:
      {0.40, 0.01, 1.0, :float, "linear brightness at which the midtone lift is complete"},
    smoothing: {3, 0, 8, :integer, "radius of the edge-preserving filter over the map; 0 is off"},
    blur: {0.8, 0.0, 10.0, :float, "sigma of the blur over the map, in map pixels; 0 is off"},
    map_size:
      {2048, 64, 4096, :integer,
       "longest side of the gain map in pixels (never larger than the photo)"},
    quality: {92, 50, 100, :integer, "JPEG quality of the gain map"}
  ]

  @type opts :: keyword()
  @type result ::
          {:ok,
           %{
             width: pos_integer(),
             height: pos_integer(),
             gain_map_bytes: pos_integer(),
             headroom: float(),
             options: map()
           }}

  @doc """
  The options, as `[%{key:, default:, min:, max:, type:, description:}]`, for a form
  or a help text.
  """
  @spec option_specs() :: [map()]
  def option_specs do
    for {key, {default, min, max, type, doc}} <- @specs do
      %{key: key, default: default, min: min, max: max, type: type, description: doc}
    end
  end

  @doc "The options with their defaults, as a map."
  @spec defaults() :: map()
  def defaults, do: Map.new(@specs, fn {key, {default, _, _, _, _}} -> {key, default} end)

  @doc """
  Checks `opts` (a keyword list or a map) and fills the defaults in: `{:ok, map}` or
  `{:error, {:bad_option, key, why}}` / `{:error, {:unknown_option, key}}`.
  """
  @spec normalize(opts() | map()) :: {:ok, map()} | {:error, term()}
  def normalize(opts) do
    opts = Map.new(opts)

    with :ok <- known(opts),
         {:ok, merged} <- check_each(Map.merge(defaults(), opts)),
         :ok <- ordered(merged, :highlight_start, :highlight_end),
         :ok <- ordered(merged, :midtone_start, :midtone_end) do
      {:ok, merged}
    end
  end

  defp known(opts) do
    case Enum.find(Map.keys(opts), &(not Keyword.has_key?(@specs, &1))) do
      nil -> :ok
      key -> {:error, {:unknown_option, key}}
    end
  end

  defp check_each(merged) do
    Enum.reduce_while(@specs, {:ok, merged}, fn {key, {_d, min, max, type, _}}, {:ok, acc} ->
      case check(Map.fetch!(acc, key), min, max, type) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, why} -> {:halt, {:error, {:bad_option, key, why}}}
      end
    end)
  end

  defp check(value, min, max, :float) when is_number(value) do
    if value >= min and value <= max,
      do: {:ok, value * 1.0},
      else: {:error, "must be between #{min} and #{max}"}
  end

  defp check(value, min, max, :integer) when is_integer(value) do
    if value >= min and value <= max,
      do: {:ok, value},
      else: {:error, "must be between #{min} and #{max}"}
  end

  defp check(_value, _min, _max, :float), do: {:error, "must be a number"}
  defp check(_value, _min, _max, :integer), do: {:error, "must be a whole number"}

  defp ordered(opts, low, high) do
    if opts[low] < opts[high],
      do: :ok,
      else: {:error, {:bad_option, low, "must be below #{high}"}}
  end

  @doc """
  Writes an Ultra HDR copy of the JPEG at `source` to `dest`, the same size as the
  source. See the module doc for `opts`.
  """
  @spec make(Path.t(), Path.t(), opts()) :: result() | {:error, term()}
  def make(source, dest, opts \\ []) do
    dir = temp_dir()

    try do
      with {:ok, opts} <- normalize(opts),
           {:ok, bin} <- read_jpeg(source),
           {:ok, picture} <- picture(bin),
           :ok <- not_hdr(source),
           {:ok, {width, height}} <- sized(source),
           :ok <- File.mkdir_p(dir),
           gain_path = Path.join(dir, "gain.jpg"),
           :ok <- render_map(source, gain_path, {width, height}, opts),
           {:ok, gain} <- File.read(gain_path) do
        write(picture, gain, opts, dest, {width, height})
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, reason -> {:error, {:exit, inspect(reason)}}
    after
      File.rm_rf(dir)
    end
  end

  # ── reading ───────────────────────────────────────────────────

  defp read_jpeg(source) do
    case File.read(source) do
      {:ok, <<0xFF, 0xD8, _::binary>> = bin} -> {:ok, bin}
      {:ok, _other} -> {:error, :not_a_jpeg}
      {:error, reason} -> {:error, reason}
    end
  end

  # The picture's marker segments and its image data, which ends at its EOI: a camera
  # JPEG can carry more after it (the previews of its own MP directory), dead weight
  # once that directory is replaced. A CMYK JPEG is refused: the Adobe segment that
  # says how to read its colours is not carried over, and no HDR viewer takes CMYK.
  defp picture(bin) do
    {segments, core_at} = HdrResize.segments(bin)

    case walk(bin, core_at, nil) do
      {:ok, _end_at, 4} ->
        {:error, :unsupported_colour}

      {:ok, end_at, _components} ->
        {:ok, {segments, binary_part(bin, core_at, end_at - core_at)}}

      # Not understood: keep everything, as ImageMagick will read it.
      :error ->
        {:ok, {segments, binary_part(bin, core_at, byte_size(bin) - core_at)}}
    end
  end

  @sof Enum.to_list(0xC0..0xCF) -- [0xC4, 0xC8, 0xCC]

  # Marker segments, from the first table on, to the EOI; the SOF gives the number of
  # colour components.
  defp walk(bin, at, components) do
    case bin do
      <<_::binary-size(at), 0xFF, 0xD9, _::binary>> ->
        {:ok, at + 2, components}

      <<_::binary-size(at), 0xFF, 0xFF, _::binary>> ->
        walk(bin, at + 1, components)

      <<_::binary-size(at), 0xFF, 0xDA, len::16, _::binary>> when len >= 2 ->
        scan(bin, at + 2 + len, components)

      <<_::binary-size(at), 0xFF, marker, len::16, _precision, _h::16, _w::16, n, _::binary>>
      when marker in @sof and len >= 8 ->
        walk(bin, at + 2 + len, n)

      <<_::binary-size(at), 0xFF, marker, len::16, _::binary>> when marker >= 0xC0 and len >= 2 ->
        walk(bin, at + 2 + len, components)

      _ ->
        :error
    end
  end

  # Entropy-coded data: in it 0xFF is followed by 0x00 (a stuffed byte), a restart
  # marker or a fill byte; anything else is the next marker.
  defp scan(bin, at, components) when at < byte_size(bin) do
    case :binary.match(bin, <<0xFF>>, scope: {at, byte_size(bin) - at}) do
      {pos, 1} ->
        case bin do
          <<_::binary-size(pos), 0xFF, next, _::binary>>
          when next == 0x00 or next in 0xD0..0xD7 ->
            scan(bin, pos + 2, components)

          <<_::binary-size(pos), 0xFF, 0xFF, _::binary>> ->
            scan(bin, pos + 1, components)

          <<_::binary-size(pos), 0xFF, _next, _::binary>> ->
            walk(bin, pos, components)

          _ ->
            :error
        end

      :nomatch ->
        :error
    end
  end

  defp scan(_bin, _at, _components), do: :error

  defp not_hdr(source) do
    case Hdr.read(source) do
      %{"gain_map" => true} -> {:error, :already_hdr}
      _ -> :ok
    end
  end

  defp sized(source) do
    case ImageProcessor.extract_dimensions(source) do
      {:ok, {w, h}} when w * h > @max_pixels -> {:error, :too_large}
      {:ok, {w, h}} -> {:ok, {w, h}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── the map ───────────────────────────────────────────────────

  # The map is drawn from the pixels as the JPEG stores them (no `-auto-orient`), the
  # frame the picture's data and its gain map share.
  defp render_map(source, out, {width, height}, opts) do
    with {:ok, input} <- ImageProcessor.pinned_input(source, "[0]") do
      side = opts.map_size

      args =
        ImageProcessor.limit_args() ++
          decode_hint(max(width, height), side) ++
          [input] ++
          ["-resize", "#{side}x#{side}>", "-colorspace", "RGB"] ++
          ["-grayscale", "Rec709Luminance", "-depth", "16"] ++
          highlights(opts) ++
          midtones(opts) ++
          ["-delete", "0", "-compose", "Plus", "-composite"] ++
          smooth(opts) ++
          ["-colorspace", "Gray", "-depth", "8", "-quality", to_string(opts.quality)] ++
          ["jpg:" <> out]

      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, _code} -> {:error, "ImageMagick convert failed: #{String.trim(output)}"}
      end
    end
  end

  # A big JPEG is decoded already scaled down (the decoder skips most of the work); the
  # hint is only given when the photo is at least twice the map, because ImageMagick
  # scales a smaller one *up* to meet it.
  defp decode_hint(long_side, side) when long_side >= side * 2,
    do: ["-define", "jpeg:size=#{side * 2}x#{side * 2}"]

  defp decode_hint(_long_side, _side), do: []

  # Each curve is a copy of the brightness: levels clamp it to 0..1 between the two
  # brightnesses, the polynomial -2x^3 + 3x^2 makes that ramp smooth, a multiply sets
  # its share of the ceiling.
  defp highlights(opts),
    do: curve(opts.highlight_start, opts.highlight_end, opts.highlight_weight)

  defp midtones(opts),
    do: curve(opts.midtone_start, opts.midtone_end, opts.midtone_lift)

  defp curve(from, to, weight) do
    [
      "(",
      "-clone",
      "0",
      "-level",
      "#{pct(from)},#{pct(to)}",
      "-function",
      "Polynomial",
      "-2,3,0,0",
      "-evaluate",
      "Multiply",
      to_string(weight),
      ")"
    ]
  end

  defp smooth(opts) do
    kuwahara = if opts.smoothing > 0, do: ["-kuwahara", to_string(opts.smoothing)], else: []
    blur = if opts.blur > 0, do: ["-blur", "0x#{opts.blur}"], else: []
    kuwahara ++ blur
  end

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 3)}%"

  # ── writing ───────────────────────────────────────────────────

  defp write({segments, core}, gain_jpg, opts, dest, {width, height}) do
    {gain_segments, gain_core_at} = HdrResize.segments(gain_jpg)
    gain_core = binary_part(gain_jpg, gain_core_at, byte_size(gain_jpg) - gain_core_at)

    params = %{
      gain_map_min: 0.0,
      gain_map_max: opts.ceiling,
      gamma: 1.0,
      base_offset: @offset,
      alternate_offset: @offset,
      base_headroom: 0.0,
      alternate_headroom: opts.ceiling
    }

    gain_file =
      HdrResize.assemble_gain(
        jfif(gain_segments) ++ [segment(0xE1, @xmp <> HeifHdr.gain_xmp(params))],
        gain_core,
        false
      )

    parts = primary_parts(segments)
    primary = HdrResize.assemble_primary(parts, core, byte_size(gain_file), false)

    with :ok <- File.write(dest, primary <> gain_file) do
      {:ok,
       %{
         width: width,
         height: height,
         gain_map_bytes: byte_size(gain_file),
         headroom: :math.pow(2, opts.ceiling),
         options: opts
       }}
    end
  end

  # The picture's own segments (JFIF, EXIF with its orientation, the colour profile),
  # the XMP that names the map and the place of the directory: what `HdrResize` reads
  # from a JPEG that is HDR already.
  defp primary_parts(segments) do
    exif = Enum.filter(segments, &match?(%{marker: 0xE1, payload: <<"Exif\0\0", _::binary>>}, &1))

    icc =
      Enum.filter(segments, &match?(%{marker: 0xE2, payload: <<"ICC_PROFILE\0", _::binary>>}, &1))

    %{
      segments:
        jfif(segments) ++
          exif ++
          [segment(0xE1, @xmp <> HeifHdr.primary_xmp())] ++ icc ++ [segment(0xE2, "MPF\0")],
      order: "II",
      attrs: {<<0, 0, 3, 0>>, <<0, 0, 0, 0>>},
      deps: {<<0::32>>, <<0::32>>}
    }
  end

  defp jfif(segments), do: segments |> Enum.filter(&(&1.marker == 0xE0)) |> Enum.take(1)

  defp segment(marker, payload) do
    %{
      marker: marker,
      at: 0,
      payload: payload,
      raw: <<0xFF, marker, byte_size(payload) + 2::16, payload::binary>>
    }
  end

  defp temp_dir do
    Path.join(
      System.tmp_dir!(),
      "pk_hdr_synth_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}"
    )
  end
end
