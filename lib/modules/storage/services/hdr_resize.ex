defmodule PhoenixKit.Modules.Storage.HdrResize do
  @moduledoc """
  Makes a smaller copy of a gain-map JPEG that is still an HDR photo.

  An iPhone or Pixel JPEG is two JPEGs in one file: the picture (SDR) and a small
  **gain map** that says how much brighter each part is on an HDR screen, tied
  together by a Multi-Picture directory (and, for Android, a line of XMP naming the
  map's length). A plain resize keeps the picture and loses the map; this keeps both:

    1. the file is split into the picture and the gain map (`Hdr`'s directory);
    2. each is resized with ImageMagick (`ImageProcessor.resize/5`: pinned input,
       resource limits, a pixel budget), the map by the same ratio as the picture;
    3. the metadata that describes the pictures (colour profile, EXIF, the XMP and
       ISO 21496-1 parameters of the map) is carried over **unchanged**, because it
       is about brightness and colour, not size. With `strip_metadata: true` the EXIF
       (device, time, position, maker notes) is dropped but for the orientation tag;
    4. what *is* about size is rewritten: the directory's sizes and offsets, and the
       map's byte length in the picture's XMP.

  Nothing is decoded to HDR pixels, so nothing is tone-mapped or clipped: the map
  is the camera's own.

  Only JPEGs whose map is a second picture are handled (`{:error, :no_gain_map}`
  otherwise; a HEIC gain map is a different container). Anything that does not
  parse as expected is an `{:error, _}`, and the caller keeps its ordinary SDR
  rendition: an HDR rendition is a bonus, never a reason for a size to be missing.
  """

  require Logger

  alias PhoenixKit.Modules.Storage.ImageProcessor

  # The gain map is detail the eye does not see, but its precision is brightness.
  @gain_map_quality 90

  @type result ::
          {:ok, %{width: pos_integer(), height: pos_integer(), gain_map_bytes: pos_integer()}}

  @doc """
  Writes a copy of the gain-map JPEG at `source` to `dest`, `width` pixels wide
  (never larger than the source), at JPEG `:quality` (default 85).
  """
  @spec resize(Path.t(), Path.t(), pos_integer(), keyword()) :: result() | {:error, term()}
  def resize(source, dest, width, opts \\ []) do
    quality = Keyword.get(opts, :quality, 85)
    strip? = Keyword.get(opts, :strip_metadata, false)

    with {:ok, bin} <- File.read(source),
         {:ok, parts} <- split(bin),
         {:ok, {src_w, _src_h}} <- sof_dims(parts.primary),
         {:ok, {gm_w, _gm_h}} <- sof_dims(parts.gain),
         new_w = min(width, src_w),
         {:ok, primary_core} <- resized_core(parts.primary, new_w, quality),
         {:ok, {out_w, out_h}} <- sof_dims(primary_core),
         gm_target = max(round(gm_w * out_w / src_w), 1),
         {:ok, gain_core} <- resized_core(parts.gain, gm_target, @gain_map_quality) do
      gain = assemble_gain(parts.gain_segments, gain_core)
      primary = assemble_primary(parts, primary_core, byte_size(gain), strip?)

      case File.write(dest, primary <> gain) do
        :ok ->
          {:ok, %{width: out_w, height: out_h, gain_map_bytes: byte_size(gain)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # ── splitting ─────────────────────────────────────────────────

  @doc false
  # The picture and the gain map of `bin`, each with its marker segments (before the
  # image data) and the MP directory's description of them.
  def split(<<0xFF, 0xD8, _::binary>> = bin) do
    {segments, _core_at} = segments(bin)

    with %{} = mpf <- Enum.find(segments, &mpf?/1),
         {:ok, order, entries} <- mp_entries(mpf, byte_size(bin)),
         [first, second | _] <- entries do
      primary = binary_part(bin, 0, second.at)
      gain = binary_part(bin, second.at, min(second.size, byte_size(bin) - second.at))
      {gain_segments, _} = segments(gain)

      {:ok,
       %{
         primary: primary,
         gain: gain,
         segments: segments,
         gain_segments: gain_segments,
         order: order,
         attrs: {first.attr, second.attr},
         deps: {first.dep, second.dep}
       }}
    else
      _ -> {:error, :no_gain_map}
    end
  end

  def split(_), do: {:error, :not_a_jpeg}

  # `[%{marker, at, raw, payload}]` for the marker segments that open a JPEG (up to
  # the first that is not an APPn or comment), and where its image data starts.
  defp segments(bin), do: segments(bin, 2, [])

  defp segments(bin, at, acc) when at + 4 <= byte_size(bin) do
    case binary_part(bin, at, 4) do
      <<0xFF, marker, len::16>> when (marker in 0xE0..0xEF or marker == 0xFE) and len >= 2 ->
        if at + 2 + len <= byte_size(bin) do
          raw = binary_part(bin, at, 2 + len)
          <<_::binary-size(4), payload::binary>> = raw

          segments(bin, at + 2 + len, [
            %{marker: marker, at: at, raw: raw, payload: payload} | acc
          ])
        else
          {Enum.reverse(acc), at}
        end

      _ ->
        {Enum.reverse(acc), at}
    end
  end

  defp segments(_bin, at, acc), do: {Enum.reverse(acc), at}

  defp mpf?(%{marker: 0xE2, payload: <<"MPF\0", _::binary>>}), do: true
  defp mpf?(_), do: false

  # The pictures an MP directory lists: `%{attr, size, at, dep}` with `at` a file offset.
  defp mp_entries(%{at: seg_at, payload: <<"MPF\0", tiff::binary>>}, file_size) do
    case tiff do
      <<order::binary-size(2), _::binary>> when order in ["II", "MM"] ->
        mp_entries(tiff, order, seg_at + 8, file_size)

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp mp_entries(tiff, order, base, file_size) do
    big? = order == "MM"
    ifd = int(tiff, 4, 4, big?)
    count = int(tiff, ifd, 2, big?)
    tags = for i <- 0..(count - 1)//1, do: binary_part(tiff, ifd + 2 + i * 12, 12)

    case Enum.find(tags, &(int(&1, 0, 2, big?) == 0xB002)) do
      nil ->
        :error

      tag ->
        list = binary_part(tiff, int(tag, 8, 4, big?), int(tag, 4, 4, big?))

        entries =
          for <<attr::binary-size(4), size::binary-size(4), off::binary-size(4),
                dep::binary-size(4) <- list>> do
            offset = int(off, 0, 4, big?)

            %{
              attr: attr,
              size: int(size, 0, 4, big?),
              at: if(offset == 0, do: 0, else: base + offset),
              dep: dep
            }
          end

        if Enum.all?(entries, &(&1.at + &1.size <= file_size)),
          do: {:ok, order, entries},
          else: :error
    end
  end

  defp int(bin, at, len, big?) do
    bits = len * 8
    chunk = binary_part(bin, at, len)

    if big? do
      <<n::big-integer-size(bits)>> = chunk
      n
    else
      <<n::little-integer-size(bits)>> = chunk
      n
    end
  end

  defp put_int(n, len, true), do: <<n::big-integer-size(len * 8)>>
  defp put_int(n, len, false), do: <<n::little-integer-size(len * 8)>>

  # ── image dimensions, from the SOF marker ─────────────────────

  @sof Enum.to_list(0xC0..0xCF) -- [0xC4, 0xC8, 0xCC]

  # A whole JPEG, or its image data alone (from the first table on).
  defp sof_dims(<<0xFF, 0xD8, rest::binary>>), do: sof_dims(rest, 0)
  defp sof_dims(<<0xFF, _marker, _::binary>> = core), do: sof_dims(core, 0)
  defp sof_dims(_), do: {:error, :not_a_jpeg}

  defp sof_dims(<<0xFF, marker, len::16, body::binary>>, guard) when guard < 200 do
    cond do
      marker in @sof ->
        case body do
          <<_precision, h::16, w::16, _::binary>> when w > 0 and h > 0 -> {:ok, {w, h}}
          _ -> {:error, :no_dimensions}
        end

      marker in [0xDA, 0xD9] ->
        {:error, :no_dimensions}

      len >= 2 and byte_size(body) >= len - 2 ->
        <<_::binary-size(len - 2), rest::binary>> = body
        sof_dims(rest, guard + 1)

      true ->
        {:error, :no_dimensions}
    end
  end

  defp sof_dims(_bin, _guard), do: {:error, :no_dimensions}

  # ── resizing ──────────────────────────────────────────────────

  # `bin` resized to `width`, as the JPEG image data alone (from its first DQT on):
  # ImageMagick's own marker segments are not wanted, the originals are carried over.
  defp resized_core(bin, width, quality) do
    input = temp(".jpg")
    output = temp(".jpg")

    try do
      with :ok <- File.write(input, bin),
           {:ok, _} <-
             ImageProcessor.resize(input, output, width, nil, quality: quality, format: "jpg"),
           {:ok, out} <- File.read(output) do
        {_segments, core_at} = segments(out)
        {:ok, binary_part(out, core_at, byte_size(out) - core_at)}
      end
    after
      File.rm(input)
      File.rm(output)
    end
  end

  defp temp(ext) do
    Path.join(
      System.tmp_dir!(),
      "pk_hdr_#{System.unique_integer([:positive])}_#{:erlang.phash2(make_ref())}#{ext}"
    )
  end

  # ── reassembly ────────────────────────────────────────────────

  @xmp "http://ns.adobe.com/xap/1.0/\0"
  @xmp_extension "http://ns.adobe.com/xmp/extension/\0"

  # The gain map: its own segments (parameters, ISO marker) and the resized image.
  defp assemble_gain(segments, core) do
    kept = for %{raw: raw} = s <- segments, not mpf?(s), do: raw
    IO.iodata_to_binary([<<0xFF, 0xD8>>, kept, core])
  end

  # The picture: what describes it (kept), the XMP's map length (rewritten), and the
  # directory (rewritten for the new sizes), then the resized image.
  defp assemble_primary(parts, core, gain_len, strip?) do
    # The directory is a fixed size, so everything before it can be laid out first,
    # then its offsets are known.
    layout =
      parts.segments
      |> Enum.flat_map(&keep_segment(&1, gain_len, strip?))

    {before_mpf, after_mpf} = Enum.split_while(layout, &(&1 != :mpf))
    [:mpf | after_mpf] = after_mpf ++ []

    head = IO.iodata_to_binary([<<0xFF, 0xD8>>, before_mpf])
    placeholder = mpf_segment(parts, 0, 0, 0)
    tail = IO.iodata_to_binary([after_mpf, core])
    total = byte_size(head) + byte_size(placeholder) + byte_size(tail)
    # The directory's offsets count from its own byte-order mark.
    base = byte_size(head) + 8

    head <> mpf_segment(parts, total, gain_len, total - base) <> tail
  end

  defp keep_segment(%{marker: 0xE0, raw: raw}, _, _), do: [raw]

  # The camera's EXIF (the device, the time, the position, maker notes) goes when the
  # rendition drops metadata; the orientation is not the camera's secret, it is how to
  # show the picture, so that one tag stays.
  defp keep_segment(%{marker: 0xE1, payload: <<"Exif\0\0", tiff::binary>>}, _, true),
    do: orientation_exif(tiff)

  defp keep_segment(%{marker: 0xE1, payload: <<"Exif\0\0", _::binary>>, raw: raw}, _, _),
    do: [raw]

  defp keep_segment(%{marker: 0xE1, payload: <<@xmp_extension, _::binary>>}, _, _), do: []

  defp keep_segment(%{marker: 0xE1, payload: <<@xmp, xml::binary>>}, gain_len, _),
    do: [xmp_segment(xml, gain_len)]

  defp keep_segment(%{marker: 0xE2, payload: <<"ICC_PROFILE\0", _::binary>>, raw: raw}, _, _),
    do: [raw]

  defp keep_segment(
         %{marker: 0xE2, payload: <<"urn:iso:std:iso:ts:21496", _::binary>>, raw: raw},
         _,
         _
       ),
       do: [raw]

  defp keep_segment(%{marker: 0xE2, payload: <<"MPF\0", _::binary>>}, _, _), do: [:mpf]
  defp keep_segment(_other, _, _), do: []

  # An EXIF segment holding the orientation tag and nothing else, when the photo is
  # turned (2..8); none when it is upright or the tag cannot be read.
  defp orientation_exif(tiff) do
    case exif_orientation(tiff) do
      n when n in 2..8 ->
        body =
          <<"Exif\0\0", "MM", 42::16, 8::32, 1::16, 0x0112::16, 3::16, 1::32, n::16, 0::16,
            0::32>>

        [<<0xFF, 0xE1, byte_size(body) + 2::16, body::binary>>]

      _ ->
        []
    end
  end

  defp exif_orientation(<<order::binary-size(2), _::binary>> = tiff) when order in ["II", "MM"] do
    big? = order == "MM"
    <<_::binary-size(4), ifd_at::binary-size(4), _::binary>> = tiff

    at =
      if big?,
        do: :binary.decode_unsigned(ifd_at, :big),
        else: :binary.decode_unsigned(ifd_at, :little)

    with true <- at + 2 <= byte_size(tiff),
         <<_::binary-size(at), count::binary-size(2), entries::binary>> <- tiff do
      n = :binary.decode_unsigned(count, if(big?, do: :big, else: :little))
      find_orientation(entries, n, big?)
    else
      _ -> nil
    end
  end

  defp exif_orientation(_), do: nil

  defp find_orientation(_, 0, _), do: nil

  defp find_orientation(
         <<tag::binary-size(2), _type::binary-size(2), _count::binary-size(4),
           value::binary-size(2), _::binary-size(2), rest::binary>>,
         left,
         big?
       ) do
    endian = if big?, do: :big, else: :little

    if :binary.decode_unsigned(tag, endian) == 0x0112,
      do: :binary.decode_unsigned(value, endian),
      else: find_orientation(rest, left - 1, big?)
  end

  defp find_orientation(_, _, _), do: nil

  # The picture's XMP, with the gain map's length corrected, and the pointer to an
  # extended XMP (a packet of further metadata that is not carried over) removed.
  defp xmp_segment(xml, gain_len) do
    patched =
      xml
      |> String.replace(
        ~r/(Item:Semantic="GainMap"[^>]*?Item:Length=")\d+(")/s,
        "\\g{1}#{gain_len}\\g{2}"
      )
      |> String.replace(~r/\s+xmpNote:HasExtendedXMP="[^"]*"/, "")

    payload = @xmp <> patched
    <<0xFF, 0xE1, byte_size(payload) + 2::16, payload::binary>>
  end

  # The Multi-Picture directory for two pictures: the picture (`total` bytes, at 0)
  # and the gain map (`gain_len` bytes, `gain_offset` from the directory), in the
  # byte order the original used.
  defp mpf_segment(parts, total, gain_len, gain_offset) do
    big? = parts.order == "MM"
    {attr1, attr2} = parts.attrs
    {dep1, dep2} = parts.deps

    ifd =
      put_int(3, 2, big?) <>
        tag(0xB000, 7, 4, "0100", big?) <>
        tag(0xB001, 4, 1, put_int(2, 4, big?), big?) <>
        tag(0xB002, 7, 32, put_int(50, 4, big?), big?) <>
        put_int(0, 4, big?)

    entries =
      attr1 <>
        put_int(total, 4, big?) <>
        put_int(0, 4, big?) <>
        dep1 <>
        attr2 <> put_int(gain_len, 4, big?) <> put_int(gain_offset, 4, big?) <> dep2

    payload =
      "MPF\0" <> parts.order <> put_int(0x2A, 2, big?) <> put_int(8, 4, big?) <> ifd <> entries

    <<0xFF, 0xE2, byte_size(payload) + 2::16, payload::binary>>
  end

  defp tag(id, type, count, value, big?),
    do: put_int(id, 2, big?) <> put_int(type, 2, big?) <> put_int(count, 4, big?) <> value
end
