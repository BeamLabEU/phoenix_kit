defmodule PhoenixKit.Modules.Storage.CaptureDate do
  @moduledoc """
  When a photo or video was taken, as opposed to when it was uploaded.

  Four columns on `phoenix_kit_files` (V200) hold it:

    * `taken_at` — the moment, in UTC. Exact when the offset is known. When it
      is not — most EXIF carries only a local wall-clock time — it is that
      local time stored as if it were UTC: it still orders a library
      correctly, but it is not a true instant.
    * `taken_on` — the local calendar **date**, which is what a library
      groups by. A photo taken at 23:00 on 31 July in California is a July
      photo, although in UTC it is already 1 August; grouping on `taken_at`
      would file it under the wrong month.
    * `taken_at_offset` — seconds east of UTC, when known.
    * `taken_at_source` — where the date came from (see below).

  ## Where a date comes from, strongest first

    1. `"manual"` — set by a person. Never replaced automatically.
    2. `"exif"` — an image's `DateTimeOriginal`, else `DateTimeDigitized`,
       with `OffsetTimeOriginal` / `OffsetTimeDigitized` when present.
       `"container"` — a video's QuickTime creation date (a local time with
       its offset), else the container's `creation_time` (UTC). Same strength.
    3. `"filename"` — a date in the uploaded file's name, the way phones and
       cameras name files (`IMG_20180701_120000.jpg`,
       `PXL_20240315_081100123.jpg`, `2018-07-01 12.34.56.jpg`).
    4. `"inserted_at"` — the upload time. Always available, so every file
       resolves to *some* date.

  A file's modification time is deliberately not a source: originals live on
  local disk or in object storage, where it is the upload time — the same
  information `inserted_at` already carries.

  ## Never downgraded

  An image edit re-encodes the file keeping only its ICC profile (see
  `PhoenixKit.Modules.Storage.ImageEdit`), so an edited original carries no
  EXIF, and anything that reads a date from those bytes finds the file name or
  the upload time at best. `replace?/2` is the guard every automatic writer
  goes through: a date is replaced only by one from an equally strong or
  stronger source, and a manual date never.
  """

  alias PhoenixKit.Modules.Storage.ImageProcessor

  @typedoc "Where a capture date came from. See the moduledoc."
  @type source :: String.t()

  @type t :: %{
          taken_at: DateTime.t(),
          taken_on: Date.t(),
          taken_at_offset: integer() | nil,
          taken_at_source: source()
        }

  @fields [:taken_at, :taken_on, :taken_at_offset, :taken_at_source]

  @rank %{
    "manual" => 4,
    "exif" => 3,
    "container" => 3,
    "filename" => 2,
    "inserted_at" => 1
  }

  # Real UTC offsets run from -12:00 to +14:00.
  @max_offset 14 * 3600

  # Older than any photograph; rejects the zeroed and garbage dates some
  # cameras and converters write.
  @earliest ~N[1826-01-01 00:00:00]

  # "Unset" values containers write instead of leaving the tag out: the
  # QuickTime and Unix epochs.
  @epochs [~N[1904-01-01 00:00:00], ~N[1970-01-01 00:00:00]]

  @exif_pairs [
    {"DateTimeOriginal", "OffsetTimeOriginal"},
    {"DateTimeDigitized", "OffsetTimeDigitized"}
  ]

  @local_re ~r/^(\d{4})[:\-](\d{2})[:\-](\d{2})[ T](\d{2}):(\d{2}):(\d{2})/
  @offset_re ~r/^([+-])(\d{2}):?(\d{2})$/
  @quicktime_re ~r/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?([+-]\d{2}:?\d{2})?$/

  # Each pattern captures year, month, day and optionally hour, minute, second.
  # The year must look like one (19xx/20xx) so a run of digits in a name is not
  # mistaken for a date.
  # A compiled `~r` carries a runtime reference on OTP 28, so a list of them
  # cannot live in a module attribute that a function body reads — Elixir
  # refuses to escape it at compile time. Building the list in a function
  # keeps the sigils (and their comments) and compiles everywhere.
  defp filename_patterns do
    [
      # IMG_20180701_120000, VID_…, PXL_20240315_081100123, Screenshot_20240315-081100
      ~r/(?<!\d)((?:19|20)\d{2})(\d{2})(\d{2})[_\-](\d{2})(\d{2})(\d{2})(?:\d{1,3})?(?!\d)/,
      # 2018-07-01 12.34.56 and macOS "… 2024-03-15 at 08.11.00"
      ~r/(?<!\d)((?:19|20)\d{2})-(\d{2})-(\d{2})(?: at |[ _T])(\d{2})[.:\-](\d{2})[.:\-](\d{2})(?!\d)/,
      # IMG-20240315-WA0001 (WhatsApp): a date, no time
      ~r/(?<!\d)((?:19|20)\d{2})(\d{2})(\d{2})-WA\d+/,
      # a bare 2018-07-01: a date, no time
      ~r/(?<!\d)((?:19|20)\d{2})-(\d{2})-(\d{2})(?!\d)/
    ]
  end

  @doc "The four columns a capture date occupies on `phoenix_kit_files`."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "Every valid `taken_at_source`, strongest first."
  @spec sources() :: [source()]
  def sources, do: ~w(manual exif container filename inserted_at)

  @doc """
  The capture date of `file`, reading its bytes at `path` when given.

  Always returns a date: embedded metadata, else the original file name, else
  the upload time. `path` is `nil` when the bytes could not be read, which
  skips straight to the file name.
  """
  @spec resolve(Path.t() | nil, map()) :: t()
  def resolve(path, file) do
    embedded(path, file.file_type) ||
      from_filename(file.original_file_name) ||
      from_inserted_at(file.inserted_at)
  end

  @doc """
  Whether an automatic writer may replace a date from `current` with one
  from `new`: only by an equally strong or stronger source, and a manual date
  never. `nil` (no date yet) is always replaceable.
  """
  @spec replace?(source() | nil, source()) :: boolean()
  def replace?(nil, _new), do: true
  def replace?("manual", _new), do: false
  def replace?(current, new), do: rank(new) >= rank(current)

  @doc """
  `attrs` without its capture-date keys when writing them over `current`
  would be a downgrade (`replace?/2`), unchanged otherwise.
  """
  @spec admit(map(), map()) :: map()
  def admit(%{taken_at_source: new} = attrs, current) do
    if replace?(current.taken_at_source, new), do: attrs, else: Map.drop(attrs, @fields)
  end

  def admit(attrs, _current), do: attrs

  ## Images

  defp embedded(nil, _file_type), do: nil
  defp embedded(path, "image"), do: path |> read_exif() |> from_exif()
  defp embedded(path, "video"), do: path |> read_video_tags() |> from_video_tags()
  defp embedded(_path, _file_type), do: nil

  @doc """
  The EXIF tags ImageMagick reads from the first frame at `path`, as
  `%{"DateTimeOriginal" => "2018:07:31 23:04:05", …}`.

  `%[EXIF:*]` rather than one `%[EXIF:Tag]` per tag: ImageMagick 7 warns on
  stderr for every named tag a file lacks, and most files lack some. An empty
  map when the file has no EXIF, is not an image, or `identify` is missing.
  """
  @spec read_exif(Path.t()) :: %{String.t() => String.t()}
  def read_exif(path) do
    # Decoder pinned to the sniffed raster format, with the processor's
    # resource limits; anything that is not a known raster image has no EXIF
    # worth reading here.
    with {:ok, input} <- ImageProcessor.pinned_input(path, "[0]"),
         {output, 0} <-
           System.cmd(
             "identify",
             ImageProcessor.limit_args() ++
               ["-format", "%[EXIF:*]", input],
             stderr_to_stdout: true
           ) do
      parse_exif_properties(output)
    else
      _ -> %{}
    end
  rescue
    # System.cmd raises when the executable is missing.
    ErlangError -> %{}
  end

  @doc false
  def parse_exif_properties(output) do
    # A tag in a legacy encoding is not UTF-8; it would not survive being
    # stored as JSON or rendered, so what is not valid is dropped here.
    for line <- output |> String.replace_invalid("") |> String.split(["\r\n", "\n"], trim: true),
        [_, key, value] <- [Regex.run(~r/^exif:([^=]+)=(.*)$/, line)],
        into: %{},
        do: {key, String.trim(value)}
  end

  @doc """
  A capture date from EXIF tags: `DateTimeOriginal`, else `DateTimeDigitized`,
  each with its own offset tag when present. `nil` when neither is a
  plausible date.
  """
  @spec from_exif(%{String.t() => String.t()}) :: t() | nil
  def from_exif(tags) when is_map(tags) do
    Enum.find_value(@exif_pairs, fn {date_key, offset_key} ->
      case parse_local(tags[date_key]) do
        {:ok, local} -> build(local, parse_offset(tags[offset_key]), "exif")
        :error -> nil
      end
    end)
  end

  ## Video

  @doc """
  The creation tags `ffprobe` reads from the container at `path`, as
  `%{"creation_time" => …, "com.apple.quicktime.creationdate" => …}`. An
  empty map when there are none or `ffprobe` is missing.
  """
  @spec read_video_tags(Path.t()) :: %{String.t() => String.t()}
  def read_video_tags(path) do
    args = [
      "-v",
      "error",
      "-show_entries",
      "format_tags=creation_time,com.apple.quicktime.creationdate:stream_tags=creation_time",
      "-of",
      "default=noprint_wrappers=1",
      path
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {output, 0} -> parse_ffprobe_tags(output)
      {_output, _status} -> %{}
    end
  rescue
    ErlangError -> %{}
  end

  @doc false
  # ffprobe prints the `[STREAM]` sections before `[FORMAT]`. A plausible
  # `creation_time` keeps its place (a stream and its container are normally
  # the same instant, and the first one wins). An unset epoch on the stream
  # must not hide the container's real instant — `from_creation_time/1`
  # rejects the epoch and would otherwise have no second candidate.
  # QuickTime's creation date is a format tag under its own key, so it never
  # competes.
  def parse_ffprobe_tags(output) do
    output
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^TAG:([^=]+)=(.*)$/, line) do
        [_, key, value] -> put_ffprobe_tag(acc, key, String.trim(value))
        nil -> acc
      end
    end)
  end

  defp put_ffprobe_tag(acc, "creation_time" = key, value) do
    case Map.get(acc, key) do
      nil -> Map.put(acc, key, value)
      current -> if from_creation_time(current), do: acc, else: Map.put(acc, key, value)
    end
  end

  defp put_ffprobe_tag(acc, key, value), do: Map.put_new(acc, key, value)

  @doc """
  A capture date from container tags: QuickTime's creation date, which keeps
  the local time and its offset (what an iPhone writes), else the container's
  `creation_time`, which is UTC with no offset — the instant is exact, but the
  local date can only be taken from UTC.
  """
  @spec from_video_tags(%{String.t() => String.t()}) :: t() | nil
  def from_video_tags(tags) when is_map(tags) do
    from_quicktime_date(tags["com.apple.quicktime.creationdate"]) ||
      from_creation_time(tags["creation_time"])
  end

  defp from_quicktime_date(nil), do: nil

  defp from_quicktime_date(value) do
    case Regex.run(@quicktime_re, String.trim(value), capture: :all_but_first) do
      [y, mo, d, h, mi, s | offset] ->
        case naive([y, mo, d, h, mi, s]) do
          {:ok, local} -> build(local, parse_offset(List.first(offset)), "container")
          :error -> nil
        end

      nil ->
        nil
    end
  end

  defp from_creation_time(nil), do: nil

  defp from_creation_time(value) do
    with {:ok, instant, _utc_offset} <- DateTime.from_iso8601(String.trim(value)),
         instant = DateTime.truncate(instant, :second),
         true <- plausible?(DateTime.to_naive(instant)) do
      %{
        taken_at: instant,
        taken_on: DateTime.to_date(instant),
        taken_at_offset: nil,
        taken_at_source: "container"
      }
    else
      _ -> nil
    end
  end

  ## File name and upload time

  @doc """
  A capture date from the date in a file name, or `nil`. Only the base name
  is read, and only dates in the shapes phones and cameras write.
  """
  @spec from_filename(String.t() | nil) :: t() | nil
  def from_filename(nil), do: nil

  def from_filename(name) do
    base = Path.basename(name)

    Enum.find_value(filename_patterns(), fn pattern ->
      case Regex.run(pattern, base, capture: :all_but_first) do
        nil -> nil
        parts -> filename_date(parts)
      end
    end)
  end

  defp filename_date([y, mo, d]), do: filename_date([y, mo, d, "0", "0", "0"])

  defp filename_date(parts) do
    case naive(parts) do
      {:ok, local} -> build(local, nil, "filename")
      :error -> nil
    end
  end

  @doc "The upload time as a capture date: the fallback every file has."
  @spec from_inserted_at(DateTime.t() | NaiveDateTime.t()) :: t()
  def from_inserted_at(%NaiveDateTime{} = inserted_at),
    do: inserted_at |> DateTime.from_naive!("Etc/UTC") |> from_inserted_at()

  def from_inserted_at(%DateTime{} = inserted_at) do
    instant = DateTime.truncate(inserted_at, :second)

    %{
      taken_at: instant,
      taken_on: DateTime.to_date(instant),
      taken_at_offset: nil,
      taken_at_source: "inserted_at"
    }
  end

  ## Parsing

  defp parse_local(nil), do: :error

  defp parse_local(value) do
    case Regex.run(@local_re, String.trim(value), capture: :all_but_first) do
      nil -> :error
      parts -> naive(parts)
    end
  end

  defp parse_offset(nil), do: nil

  defp parse_offset(value) do
    case Regex.run(@offset_re, String.trim(value), capture: :all_but_first) do
      [sign, hours, minutes] ->
        seconds = String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60
        seconds = if sign == "-", do: -seconds, else: seconds
        if abs(seconds) <= @max_offset, do: seconds

      nil ->
        nil
    end
  end

  defp naive(parts) do
    [y, mo, d, h, mi, s] = Enum.map(parts, &String.to_integer/1)

    with {:ok, local} <- NaiveDateTime.new(y, mo, d, h, mi, s),
         true <- plausible?(local) do
      {:ok, local}
    else
      _ -> :error
    end
  end

  # Not before photography, not a container's "unset" epoch, and not more than
  # a day ahead of now (a wrong camera clock, or a time zone we cannot see).
  defp plausible?(local) do
    NaiveDateTime.compare(local, @earliest) != :lt and local not in @epochs and
      NaiveDateTime.compare(local, NaiveDateTime.add(NaiveDateTime.utc_now(), 86_400)) != :gt
  end

  # `local` is the wall-clock time where the photo was taken; with a known
  # offset it converts to an exact instant, without one it is stored as if it
  # were UTC (see the moduledoc).
  defp build(local, offset, source) do
    %{
      taken_at: local |> NaiveDateTime.add(-(offset || 0)) |> DateTime.from_naive!("Etc/UTC"),
      taken_on: NaiveDateTime.to_date(local),
      taken_at_offset: offset,
      taken_at_source: source
    }
  end

  defp rank(source), do: Map.get(@rank, source, 0)
end
