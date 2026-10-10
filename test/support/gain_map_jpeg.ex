defmodule PhoenixKit.TestSupport.GainMapJpeg do
  @moduledoc """
  Builds a small HDR gain-map JPEG for tests, in the Android "Ultra HDR" layout (the
  picture, then the map; a Multi-Picture directory; the map's length in the picture's
  XMP), with ImageMagick for the two images.

  Deliberately written without `PhoenixKit.Modules.Storage.HdrResize`, so a test of it
  is not the code checking itself.
  """

  @xmp "http://ns.adobe.com/xap/1.0/\0"

  @doc "Writes the file at `path`; returns `%{gain_map_bytes:, width:, height:}`."
  def build(path, opts \\ []) do
    width = Keyword.get(opts, :width, 1600)
    height = Keyword.get(opts, :height, 1200)
    extended? = Keyword.get(opts, :extended_xmp, false)
    dir = Path.dirname(path)
    n = System.unique_integer([:positive])

    primary_in = Path.join(dir, "gm_p_#{n}.jpg")
    gain_in = Path.join(dir, "gm_g_#{n}.jpg")

    {_, 0} =
      System.cmd("convert", ["-size", "#{width}x#{height}", "gradient:white-black", primary_in],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd(
        "convert",
        [
          "-size",
          "#{div(width, 4)}x#{div(height, 4)}",
          "gradient:gray20-gray80",
          "-colorspace",
          "Gray",
          gain_in
        ],
        stderr_to_stdout: true
      )

    primary_core = core(File.read!(primary_in))
    gain_core = core(File.read!(gain_in))

    gain_xmp = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/" hdrgm:Version="1.0"
     hdrgm:GainMapMin="0.0" hdrgm:GainMapMax="3.0" hdrgm:HDRCapacityMin="0.0" hdrgm:HDRCapacityMax="3.0"/>
    </rdf:RDF></x:xmpmeta>
    """

    gain = <<0xFF, 0xD8>> <> app1(@xmp <> gain_xmp) <> gain_core

    primary_xmp = fn ->
      """
      <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"
       xmlns:xmpNote="http://ns.adobe.com/xmp/note/"
       xmlns:Container="http://ns.google.com/photos/1.0/container/"
       xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
       hdrgm:Version="1.0" #{if extended?, do: ~s(xmpNote:HasExtendedXMP="0123456789ABCDEF0123456789ABCDEF"), else: ""}>
      <Container:Directory><rdf:Seq>
      <rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/></rdf:li>
      <rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg" Item:Length="#{byte_size(gain)}"/></rdf:li>
      </rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>
      """
    end

    xmp_segment = app1(@xmp <> primary_xmp.())

    extension =
      if extended?,
        do: app1("http://ns.adobe.com/xmp/extension/\0" <> :binary.copy("x", 3000)),
        else: <<>>

    head = <<0xFF, 0xD8>> <> xmp_segment <> extension
    mpf_len = byte_size(mpf(0, 0, 0))
    total = byte_size(head) + mpf_len + byte_size(primary_core)
    base = byte_size(head) + 8

    primary = head <> mpf(total, byte_size(gain), total - base) <> primary_core

    File.write!(path, primary <> gain)
    File.rm(primary_in)
    File.rm(gain_in)
    %{gain_map_bytes: byte_size(gain), width: width, height: height}
  end

  defp app1(payload), do: <<0xFF, 0xE1, byte_size(payload) + 2::16, payload::binary>>

  # The JPEG image data alone: from the first segment that is not an APPn.
  defp core(<<0xFF, 0xD8, rest::binary>>), do: skip_apps(rest)

  defp skip_apps(<<0xFF, m, len::16, rest::binary>> = all) when m in 0xE0..0xEF or m == 0xFE do
    <<_::binary-size(len - 2), tail::binary>> = rest
    _ = all
    skip_apps(tail)
  end

  defp skip_apps(core), do: core

  # Little-endian, like the Pixel's.
  defp mpf(total, gain_len, gain_offset) do
    ifd =
      <<3::little-16>> <>
        <<0xB000::little-16, 7::little-16, 4::little-32, "0100">> <>
        <<0xB001::little-16, 4::little-16, 1::little-32, 2::little-32>> <>
        <<0xB002::little-16, 7::little-16, 32::little-32, 50::little-32>> <>
        <<0::little-32>>

    entries =
      <<0::32, total::little-32, 0::little-32, 0::16, 0::16>> <>
        <<0::32, gain_len::little-32, gain_offset::little-32, 0::16, 0::16>>

    payload = "MPF\0II" <> <<0x2A::little-16, 8::little-32>> <> ifd <> entries
    <<0xFF, 0xE2, byte_size(payload) + 2::16, payload::binary>>
  end
end
