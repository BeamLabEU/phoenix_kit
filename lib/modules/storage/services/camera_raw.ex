defmodule PhoenixKit.Modules.Storage.CameraRaw do
  @moduledoc """
  Camera raw files: DNG and the makers' own (CR2, CR3, NEF, NRW, ARW, ORF, RW2, RAF,
  PEF, SRW, 3FR). The raw file is kept as it is; its size, renditions and previews are
  made from a JPEG **developed** from it by libraw (`develop/1`), the way an SVG's are
  made from a PNG (`SvgRaster`). `DrawnSource` picks which.

  ## What a raw file is

  Most raw formats are TIFF-shaped (DNG, CR2, NEF, ARW, PEF, SRW, 3FR start like any
  TIFF), so the bytes alone cannot tell one from a TIFF; the name says which, and the
  type is the maker's (`mime_for_extension/1`). CR3, RAF, ORF and RW2 have headers of
  their own (`Sniff.camera_raw_formats/0`). Either way a file is developed only when
  its bytes are one of those shapes, and always through ImageMagick's libraw coder
  pinned by name (`dng:`, which reads every raw format libraw knows), with
  `ImageProcessor`'s resource limits. libraw applies the camera's rotation itself.

  ## Its EXIF

  A TIFF-shaped raw file carries its EXIF in the TIFF structure, which
  `CaptureDate.read_exif/1` reads as it does any TIFF's. For the others libraw's
  reading stands in (`exif_tags/1`): the date taken, the camera and the exposure, in
  EXIF's own tag names, so `Exif` and `CaptureDate` take them as they are.
  """

  alias PhoenixKit.Modules.Storage.{ImageProcessor, Sniff}

  @mimes %{
    "dng" => "image/x-adobe-dng",
    "cr2" => "image/x-canon-cr2",
    "cr3" => "image/x-canon-cr3",
    "nef" => "image/x-nikon-nef",
    "nrw" => "image/x-nikon-nrw",
    "arw" => "image/x-sony-arw",
    "orf" => "image/x-olympus-orf",
    "rw2" => "image/x-panasonic-rw2",
    "raf" => "image/x-fuji-raf",
    "pef" => "image/x-pentax-pef",
    "srw" => "image/x-samsung-srw",
    "3fr" => "image/x-hasselblad-3fr"
  }

  @mime_set @mimes |> Map.values() |> MapSet.new()

  @doc """
  Every raw extension and its MIME type, for a host's `config :mime, :types` (LiveView
  takes an upload extension only when MIME knows its type).
  """
  @spec mime_types() :: %{String.t() => [String.t()]}
  def mime_types, do: Map.new(@mimes, fn {ext, mime} -> {mime, [ext]} end)

  @doc "The raw file extensions, without the dot."
  @spec extensions() :: [String.t()]
  def extensions, do: Map.keys(@mimes)

  @doc ~S|The raw type of an extension ("NEF", ".nef"), or nil.|
  @spec mime_for_extension(String.t() | nil) :: String.t() | nil
  def mime_for_extension(ext) when is_binary(ext),
    do: @mimes[ext |> String.trim_leading(".") |> String.downcase()]

  def mime_for_extension(_ext), do: nil

  @doc "Whether a file of this MIME type is a camera raw file."
  @spec mime?(String.t() | nil) :: boolean()
  def mime?(mime) when is_binary(mime), do: MapSet.member?(@mime_set, String.downcase(mime))
  def mime?(_mime), do: false

  @doc """
  Whether the bytes at `path` have a shape a raw file has: TIFF, or one of the raw
  formats with a header of its own.
  """
  @spec raw_shaped?(Path.t()) :: boolean()
  def raw_shaped?(path) do
    case Sniff.sniff(path) do
      {:ok, %{format: format}} -> format == :tiff or format in Sniff.camera_raw_formats()
      :unknown -> false
    end
  end

  @doc """
  Develops the raw file at `path` into a new JPEG (quality 92, sRGB, upright) and
  returns its path. The caller removes it.
  """
  @spec develop(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def develop(path) do
    jpeg = Path.join(System.tmp_dir!(), "phoenix_kit_raw_#{token()}.jpg")

    args =
      ["-quiet"] ++
        ImageProcessor.limit_args() ++
        ["dng:" <> path, "-quality", "92", "jpeg:" <> jpeg]

    with true <- raw_shaped?(path) || {:error, :not_raw},
         {_output, 0} <- System.cmd("magick", args, stderr_to_stdout: true),
         true <- File.exists?(jpeg) || {:error, :raw_no_output} do
      {:ok, jpeg}
    else
      {:error, _} = error ->
        File.rm(jpeg)
        error

      {output, status} ->
        File.rm(jpeg)
        {:error, {:raw_develop, status, output}}
    end
  end

  @doc """
  What libraw reads of the raw file at `path`, as EXIF tags (`DateTimeOriginal`,
  `Make`, `Model`, `ExposureTime`, `FNumber`, `ISOSpeedRatings`, `FocalLength`,
  `FocalLengthIn35mmFilm`, `Software`). `%{}` when it is not a raw file or libraw
  cannot read it.
  """
  @spec exif_tags(Path.t()) :: %{String.t() => String.t()}
  def exif_tags(path) do
    with true <- raw_shaped?(path),
         {output, 0} <-
           System.cmd(
             "magick",
             ["identify", "-quiet", "-ping"] ++
               ImageProcessor.limit_args() ++ ["-format", "%[dng:*]", "dng:" <> path],
             stderr_to_stdout: true
           ) do
      output |> parse_properties() |> to_exif()
    else
      _ -> %{}
    end
  rescue
    ErlangError -> %{}
  end

  @doc false
  def parse_properties(output) do
    for line <- output |> String.replace_invalid("") |> String.split(["\r\n", "\n"], trim: true),
        [_, key, value] <- [Regex.run(~r/^dng:([^=]+)=(.*)$/, line)],
        into: %{},
        do: {key, String.trim(value)}
  end

  @doc false
  # libraw prints its numbers in short scientific notation ("1/5e+02", "3e+01 mm").
  def to_exif(props) do
    [
      {"Make", text(props["make"])},
      {"Model", text(props["camera.model.name"])},
      {"Software", text(props["software"])},
      {"DateTimeOriginal", date(props["create.date"])},
      {"ExposureTime", exposure(props["exposure.time"])},
      {"FNumber", positive(props["f.number"])},
      {"ISOSpeedRatings", whole(props["iso.setting"])},
      {"FocalLength", positive(props["focal.length"])},
      {"FocalLengthIn35mmFilm", whole(props["focal.length.in.35mm.format"])}
    ]
    |> Enum.reject(fn {_tag, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp text(nil), do: nil
  defp text(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  # libraw's time is the camera's clock as it was set, written as if it were UTC:
  # a wall-clock time without an offset, as EXIF's DateTimeOriginal is.
  defp date(nil), do: nil

  defp date(value) do
    case Regex.run(~r/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/, value) do
      [_, y, mo, d, h, mi, s] when y != "1970" -> "#{y}:#{mo}:#{d} #{h}:#{mi}:#{s}"
      _ -> nil
    end
  end

  defp exposure(nil), do: nil

  defp exposure(value) do
    case String.split(value, "/") do
      ["1", den] -> if n = positive_float(den), do: "1/#{round(n)}"
      [n] -> if n = positive_float(n), do: format(n)
      _ -> nil
    end
  end

  defp positive(value), do: if(n = positive_float(value), do: format(n))

  defp whole(value), do: if(n = positive_float(value), do: Integer.to_string(round(n)))

  defp positive_float(value) do
    case float(value) do
      n when is_number(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp float(nil), do: nil

  defp float(value) do
    case value |> String.split(" ", parts: 2) |> hd() |> Float.parse() do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp format(n) when n == trunc(n), do: Integer.to_string(trunc(n))
  defp format(n), do: n |> Float.round(2) |> Float.to_string()

  defp token, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
