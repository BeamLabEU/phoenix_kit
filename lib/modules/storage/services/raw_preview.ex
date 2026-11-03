defmodule PhoenixKit.Modules.Storage.RawPreview do
  @moduledoc """
  The JPEG a camera embeds in its raw file: the picture as the camera rendered it, with
  its colours, which is what its screen showed. `CameraRaw.develop/1` uses it instead of
  libraw's development when it is big enough for every rendition, because libraw renders
  the colours of a camera newer than itself wrongly (a magenta cast), and a camera's own
  rendering is what a photographer expects to see.

  ## Finding it

  A raw file holds several JPEGs (a thumbnail, a preview, sometimes a full-size one) at
  places each maker keeps differently. Rather than read every maker's layout, every
  JPEG start in the file is followed (`find/1`): a baseline or progressive JPEG (not the
  lossless JPEG some makers store the sensor data in) whose segments lead to a frame
  header and an end. The largest wins.

  ## Turning it upright

  The camera writes which way up the photo is in the raw file's own TIFF header (IFD0's
  Orientation), not in the preview, which is stored as the sensor saw it.
  `orientation/1` reads that header in a TIFF-shaped file, an ORF or RW2 (TIFF with
  another magic number), and a CR3 (its CMT1 box is a TIFF header). A RAF's preview
  carries the orientation itself, in its own EXIF.
  """

  @max_side 20_000

  @type found :: %{
          offset: non_neg_integer(),
          length: pos_integer(),
          width: pos_integer(),
          height: pos_integer()
        }

  @doc """
  The largest embedded JPEG in `bin` (a raw file's bytes), or nil.
  """
  @spec find(binary()) :: found() | nil
  def find(bin) when is_binary(bin) do
    bin
    |> :binary.matches(<<0xFF, 0xD8, 0xFF>>)
    |> Enum.flat_map(fn {offset, _} ->
      case jpeg_at(bin, offset) do
        {:ok, found} -> [found]
        :error -> []
      end
    end)
    |> Enum.max_by(&(&1.width * &1.height), fn -> nil end)
  end

  @doc """
  The raw file's EXIF orientation (1–8) from its TIFF header, or nil when it has none
  this can read.
  """
  @spec orientation(binary()) :: 1..8 | nil
  def orientation(<<"II", _::binary>> = bin), do: ifd0_orientation(bin, 0, :little)
  def orientation(<<"MM", _::binary>> = bin), do: ifd0_orientation(bin, 0, :big)

  def orientation(<<_size::binary-size(4), "ftypcrx ", _::binary>> = bin) do
    case :binary.match(bin, "CMT1") do
      {pos, 4} ->
        tiff = binary_part(bin, pos + 4, min(byte_size(bin) - pos - 4, 65_536))

        case tiff do
          <<"II", _::binary>> -> ifd0_orientation(tiff, 0, :little)
          <<"MM", _::binary>> -> ifd0_orientation(tiff, 0, :big)
          _ -> nil
        end

      :nomatch ->
        nil
    end
  end

  def orientation(_bin), do: nil

  @doc "ImageMagick's name for an EXIF orientation, for `-orient`."
  @spec magick_orient(1..8) :: String.t()
  def magick_orient(1), do: "TopLeft"
  def magick_orient(2), do: "TopRight"
  def magick_orient(3), do: "BottomRight"
  def magick_orient(4), do: "BottomLeft"
  def magick_orient(5), do: "LeftTop"
  def magick_orient(6), do: "RightTop"
  def magick_orient(7), do: "RightBottom"
  def magick_orient(8), do: "LeftBottom"

  # ── TIFF ──────────────────────────────────────────────────────

  defp ifd0_orientation(bin, base, endian) do
    with {:ok, ifd} <- u32(bin, base + 4, endian),
         {:ok, count} <- u16(bin, base + ifd, endian),
         true <- count in 1..1000 do
      Enum.find_value(0..(count - 1), fn i ->
        entry = base + ifd + 2 + i * 12

        with {:ok, 0x0112} <- u16(bin, entry, endian),
             {:ok, 3} <- u16(bin, entry + 2, endian),
             {:ok, value} when value in 1..8 <- u16(bin, entry + 8, endian) do
          value
        else
          _ -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  defp u16(bin, at, endian) when at >= 0 and at + 2 <= byte_size(bin) do
    <<_::binary-size(at), value::size(16)-unsigned-integer-unit(1), _::binary>> =
      bin |> binary_part(0, at + 2) |> pad()

    {:ok, swap16(value, endian)}
  end

  defp u16(_bin, _at, _endian), do: :error

  defp u32(bin, at, endian) when at >= 0 and at + 4 <= byte_size(bin) do
    <<_::binary-size(at), value::size(32)-unsigned-integer-unit(1), _::binary>> =
      bin |> binary_part(0, at + 4) |> pad()

    {:ok, swap32(value, endian)}
  end

  defp u32(_bin, _at, _endian), do: :error

  defp pad(bin), do: bin <> <<0>>

  defp swap16(v, :big), do: v
  defp swap16(v, :little), do: :binary.decode_unsigned(<<v::16>>, :little)
  defp swap32(v, :big), do: v
  defp swap32(v, :little), do: :binary.decode_unsigned(<<v::32>>, :little)

  # ── JPEG ──────────────────────────────────────────────────────

  # Walks the segments of the JPEG starting at `offset`: the frame header gives its
  # size, and the end marker its length. Only baseline (SOF0), extended (SOF1) and
  # progressive (SOF2) pictures count.
  defp jpeg_at(bin, offset), do: segments(bin, offset, offset + 2, nil)

  defp segments(bin, start, at, size) do
    case bin do
      <<_::binary-size(at), 0xFF, marker, len::16, _::binary>> ->
        segment(marker_kind(marker), bin, start, at, len, size)

      <<_::binary-size(at), 0xFF, 0xD9, _::binary>> ->
        finish(start, at + 2, size)

      _ ->
        :error
    end
  end

  defp segment(:end, _bin, start, at, _len, size), do: finish(start, at + 2, size)
  defp segment(:scan, bin, start, at, len, size), do: scan(bin, start, at + 2 + len, size)

  defp segment(:frame, bin, start, at, len, _size) when len >= 8 do
    case bin do
      <<_::binary-size(at + 5), h::16, w::16, _::binary>> ->
        segments(bin, start, at + 2 + len, {w, h})

      _ ->
        :error
    end
  end

  defp segment(:other, bin, start, at, len, size) when len >= 2,
    do: segments(bin, start, at + 2 + len, size)

  defp segment(_kind, _bin, _start, _at, _len, _size), do: :error

  defp marker_kind(0xD9), do: :end
  defp marker_kind(0xDA), do: :scan
  defp marker_kind(marker) when marker in [0xC0, 0xC1, 0xC2], do: :frame
  # Another frame type (lossless sensor data, arithmetic coding): not a preview.
  defp marker_kind(marker) when marker in 0xC3..0xCF and marker not in [0xC4, 0xC8, 0xCC],
    do: :refused

  defp marker_kind(marker) when marker >= 0xC0 and marker != 0xFF, do: :other
  defp marker_kind(_marker), do: :refused

  # Entropy-coded data after a scan header: it holds 0xFF only as 0xFF00 or a restart
  # marker (0xFFD0–D7), so the next other marker ends it.
  defp scan(bin, start, at, size) when at < byte_size(bin) do
    case :binary.match(bin, <<0xFF>>, scope: {at, byte_size(bin) - at}) do
      {pos, 1} ->
        case bin do
          <<_::binary-size(pos + 1), next, _::binary>> when next == 0x00 or next in 0xD0..0xD7 ->
            scan(bin, start, pos + 2, size)

          <<_::binary-size(pos + 1), 0xFF, _::binary>> ->
            scan(bin, start, pos + 1, size)

          _ ->
            segments(bin, start, pos, size)
        end

      :nomatch ->
        :error
    end
  end

  defp scan(_bin, _start, _at, _size), do: :error

  defp finish(start, stop, {w, h}) when w in 1..@max_side and h in 1..@max_side,
    do: {:ok, %{offset: start, length: stop - start, width: w, height: h}}

  defp finish(_start, _stop, _size), do: :error
end
