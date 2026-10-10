defmodule PhoenixKit.Modules.Storage.HdrTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.Hdr

  @moduletag :tmp_dir

  @iso "urn:iso:std:iso:ts:21496:-1\0"
  @apple_xmp """
  <x:xmpmeta><rdf:RDF><rdf:Description>
   <HDRGainMap:HDRGainMapVersion>131072</HDRGainMap:HDRGainMapVersion>
   <HDRGainMap:HDRGainMapHeadroom>4.974161</HDRGainMap:HDRGainMapHeadroom>
   <apdi:AuxiliaryImageType>urn:com:apple:photo:2020:aux:hdrgainmap</apdi:AuxiliaryImageType>
  </rdf:Description></rdf:RDF></x:xmpmeta>
  """

  # A JPEG-shaped file: segments, a Multi-Picture directory naming two pictures,
  # then the pictures. Nothing in it decodes; the detector only reads structure.
  defp segment(marker, payload), do: <<0xFF, marker, byte_size(payload) + 2::16, payload::binary>>

  defp mpf(second_offset_from_header, second_size) do
    entries =
      <<0::32, 1000::32, 0::32, 0::16, 0::16>> <>
        <<0::32, second_size::32, second_offset_from_header::32, 0::16, 0::16>>

    # IFD at 8: two tags, then the entries' data after the IFD (8 + 2 + 24 + 4).
    ifd =
      <<2::16>> <>
        <<0xB001::16, 4::16, 1::32, 2::32>> <>
        <<0xB002::16, 7::16, 32::32, 38::32>> <>
        <<0::32>>

    "MPF\0" <> "MM" <> <<0x2A::16, 8::32>> <> ifd <> entries
  end

  defp jpeg(opts) do
    iso = if opts[:iso], do: segment(0xE2, @iso), else: <<>>

    xmp =
      if opts[:primary_xmp],
        do: segment(0xE1, "http://ns.adobe.com/xap/1.0/\0" <> opts[:primary_xmp]),
        else: <<>>

    head = <<0xFF, 0xD8>> <> xmp <> iso

    # The MP header (the byte order mark) is 8 bytes into the MPF segment's
    # marker, length and signature.
    primary_len =
      byte_size(head) + byte_size(segment(0xE2, mpf(0, 0))) + byte_size(<<0xFF, 0xDA, 0, 2>>) + 20

    second_offset = primary_len
    base = byte_size(head) + 8
    seg = segment(0xE2, mpf(second_offset - base, 300))
    primary = head <> seg <> <<0xFF, 0xDA, 0, 2>> <> :binary.copy(<<0>>, 20)

    second =
      <<0xFF, 0xD8>> <>
        segment(0xE1, "http://ns.adobe.com/xap/1.0/\0" <> (opts[:second_xmp] || "")) <>
        :binary.copy(<<0>>, 100)

    # The directory says the picture is 300 bytes long.
    second = second <> :binary.copy(<<0>>, max(300 - byte_size(second), 0))
    if opts[:second], do: primary <> second, else: primary
  end

  defp write!(ctx, name, bytes) do
    path = Path.join(ctx.tmp_dir, name)
    File.write!(path, bytes)
    path
  end

  test "an iPhone-style JPEG: Apple's map, the ISO marker and the headroom", ctx do
    path = write!(ctx, "a.jpg", jpeg(iso: true, second: true, second_xmp: @apple_xmp))

    assert %{
             "gain_map" => true,
             "container" => "jpeg",
             "kinds" => ["apple", "iso21496"],
             "headroom" => 4.974161,
             "gain_map_bytes" => 300
           } = Hdr.read(path)
  end

  test "an ISO marker with a second picture is a map even without Apple's description", ctx do
    path = write!(ctx, "i.jpg", jpeg(iso: true, second: true))
    assert %{"gain_map" => true, "kinds" => ["iso21496"], "headroom" => nil} = Hdr.read(path)
  end

  # Android's Ultra HDR: the primary picture's XMP names the gain-map namespace and
  # the map's own XMP gives the capacity as a power of two.
  test "an Android Ultra HDR JPEG is read, its capacity turned into a ratio", ctx do
    primary =
      ~s(<x:xmpmeta xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0"/>)

    second =
      ~s(<x:xmpmeta xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:HDRCapacityMax="2.0"/>)

    path = write!(ctx, "u.jpg", jpeg(primary_xmp: primary, second: true, second_xmp: second))

    assert %{
             "gain_map" => true,
             "kinds" => ["ultrahdr"],
             "headroom" => 4.0,
             "gain_map_bytes" => 300
           } =
             Hdr.read(path)
  end

  test "Ultra HDR and ISO 21496-1 together (newer Android) are both named", ctx do
    primary =
      ~s(<x:xmpmeta xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0"/>)

    path = write!(ctx, "ui.jpg", jpeg(iso: true, primary_xmp: primary, second: true))
    assert %{"kinds" => ["iso21496", "ultrahdr"]} = Hdr.read(path)
  end

  test "a marker alone is not a map: the second picture has to be there", ctx do
    path = write!(ctx, "m.jpg", jpeg(iso: true, second: false))
    assert Hdr.read(path) == %{}
  end

  test "an ordinary JPEG, other files and a missing file have none", ctx do
    assert Hdr.read(
             write!(
               ctx,
               "p.jpg",
               <<0xFF, 0xD8>> <> segment(0xE0, "JFIF\0") <> <<0xFF, 0xDA, 0, 2>>
             )
           ) ==
             %{}

    assert Hdr.read(write!(ctx, "t.txt", "hello")) == %{}
    assert Hdr.read(write!(ctx, "empty", "")) == %{}
    assert Hdr.read(Path.join(ctx.tmp_dir, "nope")) == %{}
  end

  defp box(type, payload), do: <<byte_size(payload) + 8::32, type::binary, payload::binary>>

  defp infe(id, type), do: box("infe", <<2, 0, 0, 0, id::16, 0::16, type::binary, 0>>)

  defp heif(items, extra \\ "") do
    meta =
      box(
        "meta",
        <<0::32>> <> box("iinf", <<0::32, length(items)::16>> <> Enum.join(items)) <> extra
      )

    box("ftyp", "heic" <> <<0::32>> <> "mif1heic") <> meta <> box("mdat", :binary.copy(<<0>>, 64))
  end

  test "a HEIC with an ISO tone-map (tmap) item has a map", ctx do
    path = write!(ctx, "i.heic", heif([infe(1, "grid"), infe(2, "tmap")]))
    assert %{"gain_map" => true, "container" => "heic", "kinds" => ["iso21496"]} = Hdr.read(path)
  end

  test "an AVIF is named as one", ctx do
    avif = String.replace(heif([infe(1, "grid"), infe(2, "tmap")]), "heic", "avif", global: false)
    assert %{"container" => "avif"} = Hdr.read(write!(ctx, "i.avif", avif))
  end

  test "a HEIC with Apple's auxiliary picture has a map", ctx do
    path =
      write!(
        ctx,
        "a.heic",
        heif([infe(1, "grid")], "auxC" <> "urn:com:apple:photo:2020:aux:hdrgainmap\0")
      )

    assert %{"gain_map" => true, "kinds" => ["apple"]} = Hdr.read(path)
  end

  test "a HEIC without either has none, and bytes that merely spell tmap are not an item", ctx do
    assert Hdr.read(write!(ctx, "n.heic", heif([infe(1, "grid")]))) == %{}

    mdat_only =
      box("ftyp", "heic" <> <<0::32>> <> "mif1") <>
        box("mdat", "infe tmap urn:com:apple:photo:2020:aux:hdrgainmap")

    assert Hdr.read(write!(ctx, "m.heic", mdat_only)) == %{}
  end

  test "gain_map?/1" do
    assert Hdr.gain_map?(%{"gain_map" => true})
    refute Hdr.gain_map?(%{})
    refute Hdr.gain_map?(nil)
  end
end
