defmodule PhoenixKit.Test.ExifFixture do
  @moduledoc """
  JPEGs carrying a hand-built EXIF segment, for capture-date tests.

  Needs no exiftool and no image library: ImageMagick draws a plain JPEG with
  no metadata of its own, and an APP1 segment holding a little-endian TIFF
  structure (IFD0 → Exif IFD → the ASCII date tags) is spliced in after the
  SOI marker — the same bytes a camera writes, so `identify` reads them back
  as it would a real photo.
  """

  # Where each tag lives, its TIFF type and its number (2 = ASCII, 5 = three RATIONALs).
  @tags %{
    make: {:ifd0, 0x010F, :ascii},
    model: {:ifd0, 0x0110, :ascii},
    date_time_original: {:exif, 0x9003, :ascii},
    date_time_digitized: {:exif, 0x9004, :ascii},
    offset_time_original: {:exif, 0x9011, :ascii},
    offset_time_digitized: {:exif, 0x9012, :ascii},
    gps_latitude_ref: {:gps, 1, :ascii},
    gps_latitude: {:gps, 2, :rationals},
    gps_longitude_ref: {:gps, 3, :ascii},
    gps_longitude: {:gps, 4, :rationals}
  }

  @doc "Whether ImageMagick is installed, which every function here needs."
  @spec available?() :: boolean()
  def available?, do: not is_nil(System.find_executable("convert"))

  @doc """
  Writes a JPEG to `path` carrying `tags`, e.g.
  `%{date_time_original: "2018:07:31 23:04:05", offset_time_original: "-07:00"}`.
  ASCII tags take a string; `gps_latitude` and `gps_longitude` take
  `[{degrees, 1}, {minutes, 1}, {seconds * 100, 100}]`. An empty map writes an
  Exif IFD with no tags in it. Returns `path`.

  Every call draws a random colour, so no two fixtures share bytes: Storage
  deduplicates by checksum, and two identical uploads would quietly become
  one file.
  """
  @spec write_jpeg!(Path.t(), %{atom() => String.t()}) :: Path.t()
  def write_jpeg!(path, tags \\ %{}) do
    colour = "xc:#" <> Base.encode16(:crypto.strong_rand_bytes(3))

    {_, 0} =
      System.cmd("convert", ["-size", "64x48", colour, "-strip", "jpg:" <> path],
        stderr_to_stdout: true
      )

    <<0xFF, 0xD8, rest::binary>> = File.read!(path)
    File.write!(path, [<<0xFF, 0xD8>>, app1(tags), rest])
    path
  end

  defp app1(tags) do
    by_ifd =
      Enum.group_by(
        for(
          {name, value} <- tags,
          {ifd, tag, type} = Map.fetch!(@tags, name),
          do: {ifd, tag, type, value}
        ),
        &elem(&1, 0)
      )

    gps = entries(by_ifd[:gps])
    exif = entries(by_ifd[:exif])
    ifd0 = entries(by_ifd[:ifd0])

    # IFD0 also points at the Exif IFD, and at the GPS IFD when there is one.
    pointers = 1 + if(gps == [], do: 0, else: 1)
    ifd0_count = length(ifd0) + pointers

    ifd0_offset = 8
    exif_offset = ifd0_offset + ifd_size(ifd0_count)
    gps_offset = exif_offset + ifd_size(length(exif))
    data_offset = gps_offset + if(gps == [], do: 0, else: ifd_size(length(gps)))

    ifd0_pointers =
      [{0x8769, 4, 1, <<exif_offset::little-32>>}] ++
        if gps == [], do: [], else: [{0x8825, 4, 1, <<gps_offset::little-32>>}]

    {ifd0_bin, blobs0, cursor} = directory(ifd0 ++ ifd0_pointers, data_offset)
    {exif_bin, blobs1, cursor} = directory(exif, cursor)
    {gps_bin, blobs2, _cursor} = directory(gps, cursor)

    tiff =
      IO.iodata_to_binary([
        "II",
        <<42::little-16, ifd0_offset::little-32>>,
        ifd0_bin,
        exif_bin,
        if(gps == [], do: [], else: gps_bin),
        blobs0,
        blobs1,
        blobs2
      ])

    payload = "Exif" <> <<0, 0>> <> tiff
    <<0xFF, 0xE1, byte_size(payload) + 2::big-16>> <> payload
  end

  defp ifd_size(count), do: 2 + 12 * count + 4

  # `{tag, type, count, raw}` entries, sorted by tag as TIFF requires.
  defp entries(nil), do: []

  defp entries(list) do
    list
    |> Enum.map(fn {_ifd, tag, type, value} -> encode(tag, type, value) end)
    |> Enum.sort()
  end

  defp encode(tag, :ascii, value) do
    raw = value <> <<0>>
    {tag, 2, byte_size(raw), raw}
  end

  defp encode(tag, :rationals, values) do
    raw = for {n, d} <- values, into: <<>>, do: <<n::little-32, d::little-32>>
    {tag, 5, length(values), raw}
  end

  # One directory: its entries (a value of 4 bytes or fewer sits in the entry,
  # a longer one after the directories, the entry holding its offset), then
  # the next-IFD pointer (none).
  defp directory([], cursor), do: {[], [], cursor}

  defp directory(entries, cursor) do
    {dir, blobs, cursor} =
      Enum.reduce(entries, {[], [], cursor}, fn {tag, type, count, raw}, {dir, blobs, cursor} ->
        head = <<tag::little-16, type::little-16, count::little-32>>

        if byte_size(raw) <= 4 do
          {[dir, head, raw, :binary.copy(<<0>>, 4 - byte_size(raw))], blobs, cursor}
        else
          {[dir, head, <<cursor::little-32>>], [blobs, raw], cursor + byte_size(raw)}
        end
      end)

    {[<<length(entries)::little-16>>, dir, <<0::little-32>>], blobs, cursor}
  end
end
