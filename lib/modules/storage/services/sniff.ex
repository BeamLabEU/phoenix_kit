defmodule PhoenixKit.Modules.Storage.Sniff do
  @moduledoc """
  What a file is, read from its first bytes rather than from its name or the
  browser's `Content-Type` — both of which are the uploader's claims.

  Two uses:

    * at upload, `Storage` lets a sniffed raster image type overrule the
      claimed one, and stops a file that claims to be a raster image but is
      not from being handed to the image pipeline;
    * before ImageMagick touches a file, `ImageProcessor` pins the decoder to
      the sniffed raster format (`png:/tmp/x`), so a file can never be read
      by a coder nobody meant to run.

  Only the formats in `raster_formats/0` are ever given to ImageMagick. SVG,
  PDF, PostScript/EPS, MVG, MSL and the rest reach their decoders through
  delegates (librsvg, Ghostscript…) with a long history of command injection
  and memory-safety bugs; they are recognised here so they can be *refused*,
  never pinned. The one exception is drawn elsewhere on purpose: an SVG is
  rendered to a PNG by `SvgRaster`, through ImageMagick's librsvg coder only
  (`rsvg:`, never `svg:` or `msvg:`), alone in a private folder.
  """

  @type format ::
          :png
          | :jpeg
          | :gif
          | :webp
          | :tiff
          | :bmp
          | :ico
          | :heic
          | :avif
          | :svg
          | :cr3
          | :raf
          | :orf
          | :rw2
          | :pdf
          | :postscript
          | :zip
          | :mp4
          | :quicktime
          | :webm
          | :mp3
          | :wav
          | :ogg

  @type result :: {:ok, %{format: format(), mime: String.t()}} | :unknown

  @raster [:png, :jpeg, :gif, :webp, :tiff, :bmp, :heic, :avif]

  @mimes %{
    png: "image/png",
    jpeg: "image/jpeg",
    gif: "image/gif",
    webp: "image/webp",
    tiff: "image/tiff",
    bmp: "image/bmp",
    ico: "image/x-icon",
    heic: "image/heic",
    avif: "image/avif",
    svg: "image/svg+xml",
    cr3: "image/x-canon-cr3",
    raf: "image/x-fuji-raf",
    orf: "image/x-olympus-orf",
    rw2: "image/x-panasonic-rw2",
    pdf: "application/pdf",
    postscript: "application/postscript",
    zip: "application/zip",
    mp4: "video/mp4",
    quicktime: "video/quicktime",
    webm: "video/webm",
    mp3: "audio/mpeg",
    wav: "audio/wav",
    ogg: "audio/ogg"
  }

  @doc "The raster formats ImageMagick may decode, each with a pinned coder."
  @spec raster_formats() :: [format()]
  def raster_formats, do: @raster

  # Camera raw files whose header is not a plain TIFF's. The TIFF-shaped ones (DNG, CR2,
  # NEF, ARW, PEF, SRW…) sniff as `:tiff`; their type then comes from the name
  # (`Storage.CameraRaw`). Neither kind is a raster format: their pixels are developed
  # by libraw, never decoded by a coder chosen here.
  @camera_raw [:cr3, :raf, :orf, :rw2]

  @doc "The camera raw formats recognised by their own header (not the TIFF-shaped ones)."
  @spec camera_raw_formats() :: [format()]
  def camera_raw_formats, do: @camera_raw

  @doc "Whether `format` is one ImageMagick may be given."
  @spec raster?(format() | nil) :: boolean()
  def raster?(format), do: format in @raster

  @doc """
  The ImageMagick coder name that pins decoding to `format`
  (`"png"` → `png:/path`), or `nil` for anything that must not reach
  ImageMagick.
  """
  @spec magick_coder(format() | nil) :: String.t() | nil
  def magick_coder(:png), do: "png"
  def magick_coder(:jpeg), do: "jpeg"
  def magick_coder(:gif), do: "gif"
  def magick_coder(:webp), do: "webp"
  def magick_coder(:tiff), do: "tiff"
  def magick_coder(:bmp), do: "bmp"
  def magick_coder(:heic), do: "heic"
  def magick_coder(:avif), do: "avif"
  def magick_coder(_), do: nil

  @doc "The MIME type for a sniffed format."
  @spec mime(format()) :: String.t()
  def mime(format), do: Map.fetch!(@mimes, format)

  @doc """
  Reads the first bytes of the file at `path` and names its format.
  `:unknown` for anything unrecognised or unreadable.
  """
  @spec sniff(Path.t()) :: result()
  def sniff(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 512)) do
      {:ok, head} when is_binary(head) -> sniff_binary(head)
      _ -> :unknown
    end
  end

  @doc "`sniff/1` over bytes already in memory (the first ~512 are enough)."
  @spec sniff_binary(binary()) :: result()
  def sniff_binary(head) when is_binary(head) do
    case detect(head) do
      nil -> :unknown
      format -> {:ok, %{format: format, mime: mime(format)}}
    end
  end

  defp detect(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: :png
  defp detect(<<0xFF, 0xD8, 0xFF, _::binary>>), do: :jpeg
  defp detect(<<"GIF87a", _::binary>>), do: :gif
  defp detect(<<"GIF89a", _::binary>>), do: :gif
  defp detect(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: :webp
  defp detect(<<"RIFF", _size::binary-size(4), "WAVE", _::binary>>), do: :wav
  defp detect(<<"FUJIFILMCCD-RAW", _::binary>>), do: :raf
  defp detect(<<"IIRO", _::binary>>), do: :orf
  defp detect(<<"IIRS", _::binary>>), do: :orf
  defp detect(<<"MMOR", _::binary>>), do: :orf
  defp detect(<<"IIU", 0, _::binary>>), do: :rw2
  defp detect(<<"II", 42, 0, _::binary>>), do: :tiff
  defp detect(<<"MM", 0, 42, _::binary>>), do: :tiff
  # "BM" alone is two letters a CSV or a note can start with ("BMI,weight"),
  # so a BMP is also asked for the file header's other fields: the pixel
  # data offset, and a DIB header of one of the sizes the format defines.
  defp detect(
         <<"BM", _size::binary-size(4), _reserved::binary-size(4), _offset::little-32,
           dib_size::little-32, _::binary>>
       )
       when dib_size in [12, 40, 52, 56, 64, 108, 124],
       do: :bmp

  defp detect(<<0, 0, 1, 0, _::binary>>), do: :ico
  defp detect(<<"%PDF-", _::binary>>), do: :pdf
  defp detect(<<"%!PS", _::binary>>), do: :postscript
  defp detect(<<0xC5, 0xD0, 0xD3, 0xC6, _::binary>>), do: :postscript
  defp detect(<<"PK", 3, 4, _::binary>>), do: :zip
  defp detect(<<"OggS", _::binary>>), do: :ogg
  defp detect(<<"ID3", _::binary>>), do: :mp3
  defp detect(<<0xFF, b, _::binary>>) when b in [0xFB, 0xF3, 0xF2], do: :mp3
  defp detect(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: :webm

  # ISO base media: a box size, then "ftyp" and the major brand.
  defp detect(<<_size::binary-size(4), "ftyp", brand::binary-size(4), _::binary>>) do
    cond do
      brand in ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"] -> :heic
      brand in ["avif", "avis"] -> :avif
      brand == "qt  " -> :quicktime
      brand == "crx " -> :cr3
      true -> :mp4
    end
  end

  defp detect(head), do: if(svg?(head), do: :svg, else: nil)

  # SVG is text: an optional BOM, whitespace, an XML declaration, comments
  # or a doctype, then an `<svg` element within the first bytes. Byte-level
  # regexes, not String functions: a 512-byte cut can split a UTF-8 character.
  defp svg?(head) do
    Regex.match?(~r/\A(\xEF\xBB\xBF)?\s*(<\?xml|<!--|<!doctype\s+svg|<svg)/i, head) and
      Regex.match?(~r/<svg[\s>]/i, head)
  end
end
