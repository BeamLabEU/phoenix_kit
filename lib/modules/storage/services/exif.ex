defmodule PhoenixKit.Modules.Storage.Exif do
  @moduledoc """
  What a photo's EXIF says, in two forms: a **summary** worth keeping, and the
  **whole dump** to look at.

  ImageMagick (`CaptureDate.read_exif/1`) prints every tag as text, most of them
  as fractions: `FNumber=1433/512`, `GPSLatitude=45/1,28/1,1199/100`,
  `ExposureTime=10/1250`. This module turns that into something a person or a
  map can use.

  ## The summary

  `summary/1` is what is stored in the file's `metadata["exif"]`: a small,
  JSON-safe map with only the groups the photo has.

      %{
        "camera"   => %{"make" => "Apple", "model" => "iPhone 17 Pro",
                        "lens_model" => "...", "software" => "27.0"},
        "exposure" => %{"focal_length" => 16.9, "focal_length_35mm" => 200,
                        "f_number" => 2.8, "exposure_time" => "1/125", "iso" => 50,
                        "flash" => false},
        "dates"    => %{"original" => "2026-10-05T18:42:46", "digitized" => "...",
                        "modified" => "...", "offset" => "+02:00"},
        "gps"      => %{"latitude" => 45.4698, "longitude" => 10.7209,
                        "altitude" => 105.0, "speed_kmh" => 0.9, "direction" => 352.8,
                        "timestamp" => "2026-10-05T16:42:46Z"},
        "orientation" => 1
      }

  The camera's serial number and the maker note are not kept. The position is
  also written to the file's `latitude` / `longitude` columns (`coordinates/1`),
  the copy a map searches.

  ## The whole dump

  `groups/1` lists every tag the file carries, grouped as web EXIF viewers do
  (Camera, Exposure, Dates, Location, Image, Other), with fractions shown as
  numbers. It is read from the original on request, never stored.
  """

  alias PhoenixKit.Modules.Storage.CaptureDate

  @type tags :: %{String.t() => String.t()}

  @doc "The EXIF tags of the image at `path` (`CaptureDate.read_exif/1`): `%{}` when it has none."
  @spec read(Path.t()) :: tags()
  def read(path), do: CaptureDate.read_exif(path)

  # ── The summary ───────────────────────────────────────────────

  @doc """
  What to record on a file for `tags`: `%{exif: summary, latitude: lat, longitude: lon}`
  (the position `nil` when there is none). `summary` is `%{}` for a photo with no
  EXIF: stored as such, it says "read, and there was nothing", which is not the
  same as never read.
  """
  @spec file_attrs(tags()) :: %{exif: map(), latitude: float() | nil, longitude: float() | nil}
  def file_attrs(tags) do
    {lat, lon} = coordinates(tags) || {nil, nil}
    %{exif: summary(tags), latitude: lat, longitude: lon}
  end

  @doc "The curated, JSON-safe summary of `tags`; `%{}` when there is nothing worth keeping."
  @spec summary(tags()) :: map()
  def summary(tags) when is_map(tags) do
    %{}
    |> put_group("camera", camera(tags))
    |> put_group("exposure", exposure(tags))
    |> put_group("dates", dates(tags))
    |> put_group("gps", gps(tags))
    |> put_present("orientation", int(tags["Orientation"]))
  end

  defp put_group(map, _key, group) when group == %{}, do: map
  defp put_group(map, key, group), do: Map.put(map, key, group)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp compact(pairs), do: for({k, v} <- pairs, v not in [nil, ""], into: %{}, do: {k, v})

  defp camera(tags) do
    compact([
      {"make", text(tags["Make"])},
      {"model", text(tags["Model"])},
      {"lens_make", text(tags["LensMake"])},
      {"lens_model", text(tags["LensModel"])},
      {"software", text(tags["Software"])}
    ])
  end

  defp exposure(tags) do
    compact([
      {"focal_length", tags["FocalLength"] |> number() |> round_to(1)},
      {"focal_length_35mm", int(tags["FocalLengthIn35mmFilm"])},
      {"f_number", tags["FNumber"] |> number() |> round_to(1)},
      {"exposure_time", exposure_time(tags["ExposureTime"])},
      {"iso", int(tags["ISOSpeedRatings"] || tags["PhotographicSensitivity"])},
      {"flash", flash_fired(tags["Flash"])}
    ])
  end

  defp dates(tags) do
    compact([
      {"original", datetime(tags["DateTimeOriginal"], tags["SubSecTimeOriginal"])},
      {"digitized", datetime(tags["DateTimeDigitized"], tags["SubSecTimeDigitized"])},
      {"modified", datetime(tags["DateTime"], tags["SubSecTime"])},
      {"offset",
       text(tags["OffsetTimeOriginal"] || tags["OffsetTime"] || tags["OffsetTimeDigitized"])}
    ])
  end

  defp gps(tags) do
    case coordinates(tags) do
      {lat, lon} ->
        compact([
          {"latitude", lat},
          {"longitude", lon},
          {"altitude", altitude(tags)},
          {"speed_kmh", speed_kmh(tags)},
          {"direction", tags["GPSImgDirection"] |> number() |> round_to(1)},
          {"direction_ref", direction_ref(tags["GPSImgDirectionRef"])},
          {"timestamp", gps_timestamp(tags["GPSDateStamp"], tags["GPSTimeStamp"])}
        ])

      nil ->
        %{}
    end
  end

  @doc """
  The GPS position of `tags` as `{latitude, longitude}` in decimal degrees, or
  `nil`: no position, an impossible one, or the 0, 0 a camera without a fix
  writes.
  """
  @spec coordinates(tags()) :: {float(), float()} | nil
  def coordinates(tags) when is_map(tags) do
    with lat when is_number(lat) <- dms(tags["GPSLatitude"], tags["GPSLatitudeRef"], "S"),
         lon when is_number(lon) <- dms(tags["GPSLongitude"], tags["GPSLongitudeRef"], "W"),
         true <- abs(lat) <= 90 and abs(lon) <= 180,
         false <- lat == 0 and lon == 0 do
      {Float.round(lat * 1.0, 6), Float.round(lon * 1.0, 6)}
    else
      _ -> nil
    end
  end

  # "45/1,28/1,1199/100" → degrees + minutes/60 + seconds/3600; the south and
  # west references make it negative. Also accepts a plain decimal.
  defp dms(nil, _ref, _negative), do: nil

  defp dms(value, ref, negative) do
    parts = value |> String.split(",", trim: true) |> Enum.map(&number/1)

    degrees =
      case parts do
        [d, m, s] when is_number(d) and is_number(m) and is_number(s) -> d + m / 60 + s / 3600
        [d, m] when is_number(d) and is_number(m) -> d + m / 60
        [d] when is_number(d) -> d
        _ -> nil
      end

    cond do
      is_nil(degrees) -> nil
      text(ref) == negative -> -abs(degrees)
      true -> degrees
    end
  end

  defp altitude(tags) do
    case number(tags["GPSAltitude"]) do
      nil ->
        nil

      meters ->
        round_to(if(below_sea_level?(tags["GPSAltitudeRef"]), do: -meters, else: meters), 1)
    end
  end

  # The reference is one byte: 0 above sea level, 1 below. ImageMagick prints an
  # unprintable byte as a dot.
  defp below_sea_level?(ref), do: ref in ["1", "\x01"]

  defp speed_kmh(tags) do
    case number(tags["GPSSpeed"]) do
      nil ->
        nil

      speed ->
        factor =
          case text(tags["GPSSpeedRef"]) do
            "M" -> 1.609344
            "N" -> 1.852
            _ -> 1.0
          end

        round_to(speed * factor, 1)
    end
  end

  defp direction_ref("T"), do: "true"
  defp direction_ref("M"), do: "magnetic"
  defp direction_ref(_), do: nil

  # "2026:10:05" + "16/1,42/1,46/1" → "2026-10-05T16:42:46Z" (GPS time is UTC).
  defp gps_timestamp(date, time) do
    with [y, m, d] <- String.split(date || "", ":"),
         [h, mi, s] <- String.split(time || "", ",") |> Enum.map(&number/1),
         true <- Enum.all?([h, mi, s], &is_number/1) do
      "#{y}-#{m}-#{d}T#{pad(trunc(h))}:#{pad(trunc(mi))}:#{pad(trunc(s))}Z"
    else
      _ -> nil
    end
  end

  # ── Values ────────────────────────────────────────────────────

  # "2026:10:05 18:42:46" → "2026-10-05T18:42:46" (local time, as the camera
  # wrote it; the offset is kept apart), with the sub-second part when there is
  # one. Anything that is not a date is nil.
  defp datetime(nil, _sub), do: nil

  defp datetime(value, sub) do
    case Regex.run(~r/^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})$/, value) do
      [_, y, mo, d, h, mi, s] when y != "0000" ->
        "#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}" <> fraction(sub)

      _ ->
        nil
    end
  end

  defp fraction(sub) do
    if is_binary(sub) and Regex.match?(~r/^\d{1,6}$/, sub), do: "." <> sub, else: ""
  end

  # "10/1250" → "1/125"; "2/1" → "2"; "1/176" stays.
  defp exposure_time(nil), do: nil

  defp exposure_time(value) do
    case Regex.run(~r/^(\d+)\/(\d+)$/, value) do
      [_, n, d] ->
        {n, d} = {String.to_integer(n), String.to_integer(d)}

        cond do
          n == 0 or d == 0 -> nil
          rem(n, d) == 0 -> Integer.to_string(div(n, d))
          true -> reduced(n, d)
        end

      _ ->
        text(value)
    end
  end

  defp reduced(n, d) do
    g = Integer.gcd(n, d)
    {n, d} = {div(n, g), div(d, g)}

    # 1/x as the camera shows it; a longer exposure as seconds.
    if n == 1, do: "1/#{d}", else: "#{round_to(n / d, 2)}"
  end

  # Bit 0 of the Flash tag is "the flash fired". ImageMagick prints the number.
  defp flash_fired(nil), do: nil

  defp flash_fired(value) do
    case int(value) do
      nil -> nil
      n -> Bitwise.band(n, 1) == 1
    end
  end

  # A fraction ("1433/512"), a plain number, or nil.
  defp number(nil), do: nil

  defp number(value) when is_binary(value) do
    case Regex.run(~r/^\s*(-?\d+(?:\.\d+)?)\s*(?:\/\s*(-?\d+(?:\.\d+)?))?\s*$/, value) do
      [_, n] -> parse_float(n)
      [_, n, d] -> divide(parse_float(n), parse_float(d))
      _ -> nil
    end
  end

  defp parse_float(text) do
    case Float.parse(text) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp divide(_n, d) when d in [nil, 0, 0.0], do: nil
  defp divide(nil, _d), do: nil
  defp divide(n, d), do: n / d

  defp int(nil), do: nil

  defp int(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp round_to(nil, _places), do: nil
  defp round_to(number, places), do: Float.round(number * 1.0, places)

  # Text without control bytes and padding; "" is nothing.
  defp text(nil), do: nil

  defp text(value) do
    case value |> String.replace(~r/[\x00-\x1f]/, "") |> String.trim() do
      "" -> nil
      cleaned -> String.slice(cleaned, 0, 255)
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # ── The whole dump ────────────────────────────────────────────

  @groups [
    camera: "Camera",
    exposure: "Exposure",
    dates: "Dates",
    location: "Location",
    image: "Image",
    other: "Other"
  ]

  @camera ~w(Make Model LensMake LensModel LensSpecification LensSerialNumber Software HostComputer
             Artist Copyright CameraOwnerName BodySerialNumber MakerNote)
  @exposure ~w(ExposureTime FNumber ExposureProgram ISOSpeedRatings PhotographicSensitivity
               SensitivityType ShutterSpeedValue ApertureValue BrightnessValue ExposureBiasValue
               MaxApertureValue SubjectDistance SubjectDistanceRange MeteringMode LightSource Flash
               FlashPixVersion FocalLength FocalLengthIn35mmFilm ExposureMode WhiteBalance
               DigitalZoomRatio SceneCaptureType SceneType SensingMethod CustomRendered SubjectArea
               GainControl Contrast Saturation Sharpness FileSource)
  @image ~w(ColorSpace PixelXDimension PixelYDimension Orientation XResolution YResolution
            ResolutionUnit YCbCrPositioning ComponentsConfiguration Compression ExifVersion
            ExifOffset JPEGInterchangeFormat JPEGInterchangeFormatLength)

  @doc "The titles of the groups `groups/1` uses, in order: `[{group, title}]`."
  def group_titles, do: @groups

  @doc """
  Every tag in `tags`, grouped for a viewer: `[{group, [{label, value}]}]` in the
  order of `group_titles/0`, empty groups left out. Fractions are shown as numbers
  and a GPS position as decimal degrees.
  """
  @spec groups(tags()) :: [{atom(), [{String.t(), String.t()}]}]
  def groups(tags) when is_map(tags) do
    grouped =
      tags
      |> Enum.reject(fn {name, _} -> name == "GPSInfo" end)
      |> Enum.group_by(fn {name, _} -> group_of(name) end, fn {name, value} ->
        {label(name), display(name, value, tags)}
      end)

    for {group, _title} <- @groups, rows = grouped[group], rows != nil do
      {group, Enum.sort_by(rows, &elem(&1, 0))}
    end
  end

  defp group_of("thumbnail:" <> _), do: :image
  defp group_of("GPS" <> _), do: :location
  defp group_of("DateTime" <> _), do: :dates
  defp group_of("SubSecTime" <> _), do: :dates
  defp group_of("OffsetTime" <> _), do: :dates
  defp group_of(name) when name in @camera, do: :camera
  defp group_of(name) when name in @exposure, do: :exposure
  defp group_of(name) when name in @image, do: :image
  defp group_of(_), do: :other

  # "DateTimeOriginal" → "Date Time Original"; "ISOSpeedRatings" → "ISO Speed Ratings".
  defp label(name) do
    name
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1 \\2")
    |> String.replace("thumbnail:", "Thumbnail ")
  end

  defp display(name, value, tags) when name in ["GPSLatitude", "GPSLongitude"] do
    ref_key = name <> "Ref"
    negative = if name == "GPSLatitude", do: "S", else: "W"

    case dms(value, tags[ref_key], negative) do
      nil -> value
      degrees -> "#{Float.round(degrees * 1.0, 6)}°"
    end
  end

  defp display("ExposureTime", value, _tags), do: exposure_time(value) || value
  defp display(_name, value, _tags), do: fraction_text(value)

  # A fraction (or a list of them) as numbers; anything else as it is.
  defp fraction_text(value) do
    parts = String.split(value, ",", trim: true)

    if parts != [] and Enum.all?(parts, &Regex.match?(~r/^\s*-?\d+\/\d+\s*$/, &1)) do
      Enum.map_join(parts, ", ", fn part -> part |> number() |> format_number() end)
    else
      value
    end
  end

  defp format_number(nil), do: "–"
  defp format_number(number), do: number |> Float.round(4) |> trim_float()

  defp trim_float(float) do
    text = :erlang.float_to_binary(float, decimals: 4)
    text |> String.trim_trailing("0") |> String.trim_trailing(".")
  end
end
