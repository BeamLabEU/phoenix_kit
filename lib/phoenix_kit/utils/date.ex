defmodule PhoenixKit.Utils.Date do
  @moduledoc """
  Date and time formatting utilities for PhoenixKit.

  This module provides robust date and time formatting functionality using Timex,
  supporting various format codes used throughout the PhoenixKit system.

  ## Core Functions

  ### Date Formatting
  - `format_date/2` - Format a date using PHP-style format codes
  - `format_time/2` - Format a time using PHP-style format codes
  - `get_date_examples/1` - Generate example formatted dates
  - `get_time_examples/1` - Generate example formatted times

  ### Format Support

  The module supports the following format codes:

  **Date Formats:**
  - `Y-m-d` - 2025-09-02 (ISO format)
  - `m/d/Y` - 09/02/2025 (US format)
  - `d/m/Y` - 02/09/2025 (European format)
  - `d.m.Y` - 02.09.2025 (German format)
  - `d-m-Y` - 02-09-2025 (Alternative European)
  - `F j, Y` - September 2, 2025 (Long format)

  **Time Formats:**
  - `H:i` - 15:30 (24-hour format)
  - `h:i A` - 3:30 PM (12-hour format with AM/PM)

  ## Usage Examples

      # Format a date
      date = Date.utc_today()
      PhoenixKit.Utils.Date.format_date(date, "F j, Y")
      # => "September 2, 2025"

      # Format a time
      time = Time.utc_now()
      PhoenixKit.Utils.Date.format_time(time, "h:i A")
      # => "3:30 PM"

      # Get examples for all date formats
      PhoenixKit.Utils.Date.get_date_examples(Date.utc_today())
      # => %{"Y-m-d" => "2025-09-02", "F j, Y" => "September 2, 2025", ...}

  ## Implementation

  This module uses Elixir's built-in Calendar.strftime for robust date/time formatting
  with extensive format support.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Utils.TimeZone

  alias PhoenixKit.Settings

  @doc """
  Returns current UTC time truncated to second precision.

  Use this for all `:utc_datetime` schema fields to avoid
  `ArgumentError: :utc_datetime expects microseconds to be empty`.

  ## Examples

      iex> PhoenixKit.Utils.Date.utc_now()
      ~U[2026-02-21 14:30:45Z]
  """
  @spec utc_now() :: DateTime.t()
  def utc_now do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  @doc """
  The abbreviated month name for `month`, in the current Gettext locale.

  `Calendar.strftime/2`'s `%b` is locale-blind and always yields English, so
  every localized consumer was rebuilding the same twelve-entry gettext table.
  The strings already live in core's catalog with et/ru translations, so this
  is one place to call rather than a new translation burden.

      iex> PhoenixKit.Utils.Date.short_month(1)
      "Jan"
  """
  @spec short_month(1..12) :: String.t()
  def short_month(1), do: gettext("Jan")
  def short_month(2), do: gettext("Feb")
  def short_month(3), do: gettext("Mar")
  def short_month(4), do: gettext("Apr")
  def short_month(5), do: gettext("May")
  def short_month(6), do: gettext("Jun")
  def short_month(7), do: gettext("Jul")
  def short_month(8), do: gettext("Aug")
  def short_month(9), do: gettext("Sep")
  def short_month(10), do: gettext("Oct")
  def short_month(11), do: gettext("Nov")
  def short_month(12), do: gettext("Dec")

  @doc """
  A short, localized day and month — "3 Oct" in English, "3. okt" in
  Estonian. The order and punctuation come from the translation of
  `"%{day} %{month}"`, so each language writes it its own way.

  Accepts a `Date`, `DateTime` or `NaiveDateTime`; `nil` gives `""`.
  """
  @spec short(Elixir.Date.t() | DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def short(nil), do: ""

  def short(%{day: day, month: month}) do
    gettext("%{day} %{month}", day: day, month: short_month(month))
  end

  @doc """
  `short/1` with the year — "3 Oct 2026". Translated from
  `"%{day} %{month} %{year}"`.
  """
  @spec short_with_year(Elixir.Date.t() | DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def short_with_year(nil), do: ""

  def short_with_year(%{day: day, month: month, year: year}) do
    gettext("%{day} %{month} %{year}", day: day, month: short_month(month), year: year)
  end

  @doc """
  A short, localized "MMM D, YYYY at HH:MM" rendering of a datetime.

  For the places that reached for `Calendar.strftime(dt, "%b %d, %Y at %H:%M")`
  and silently got English month names on a translated page.

  Shown in the site time zone (Settings → `time_zone`); a `NaiveDateTime` is
  read as UTC.
  """
  @spec format_short_datetime(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_short_datetime(nil), do: ""

  def format_short_datetime(datetime) do
    datetime = in_site_zone(datetime)

    "#{short_month(datetime.month)} #{pad2(datetime.day)}, #{datetime.year}" <>
      " at #{pad2(datetime.hour)}:#{pad2(datetime.minute)}"
  end

  defp pad2(n), do: String.pad_leading(to_string(n), 2, "0")

  @doc """
  Formats a date according to the specified format string.

  Uses Calendar.strftime for robust date formatting with extensive format support.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_date(~D[2024-01-15], "Y-m-d")
      "2024-01-15"

      iex> PhoenixKit.Utils.Date.format_date(~D[2024-01-15], "m/d/Y")
      "01/15/2024"

      iex> PhoenixKit.Utils.Date.format_date(~D[2024-01-15], "F j, Y")
      "January 15, 2024"
  """
  def format_date(date, format) do
    strftime_format = convert_php_to_strftime(format, :date)
    Calendar.strftime(date, strftime_format)
  end

  @doc """
  Formats a time according to the specified format string.

  Uses Calendar.strftime for robust time formatting with extensive format support.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_time(~T[15:30:00], "H:i")
      "15:30"

      iex> PhoenixKit.Utils.Date.format_time(~T[15:30:00], "h:i A")
      "3:30 PM"
  """
  def format_time(time, format) do
    strftime_format = convert_php_to_strftime(format, :time)
    Calendar.strftime(time, strftime_format)
  end

  # Convert PHP-style format strings to strftime format strings
  defp convert_php_to_strftime(format, :date) do
    case format do
      "Y-m-d" -> "%Y-%m-%d"
      "m/d/Y" -> "%m/%d/%Y"
      "d/m/Y" -> "%d/%m/%Y"
      "d.m.Y" -> "%d.%m.%Y"
      "d.m" -> "%d.%m"
      "d-m-Y" -> "%d-%m-%Y"
      "F j, Y" -> "%B %-d, %Y"
      # Default to Y-m-d format
      _ -> "%Y-%m-%d"
    end
  end

  # Convert PHP-style time format strings to strftime format strings
  defp convert_php_to_strftime(format, :time) do
    case format do
      "H:i" -> "%H:%M"
      "h:i A" -> "%I:%M %p"
      # Default to 24-hour format
      _ -> "%H:%M"
    end
  end

  @doc """
  Generates example formatted dates for all supported formats.

  Returns a map with format codes as keys and formatted examples as values.
  Useful for generating dropdown options and previews.

  ## Examples

      iex> PhoenixKit.Utils.Date.get_date_examples(~D[2024-01-15])
      %{
        "Y-m-d" => "2024-01-15",
        "m/d/Y" => "01/15/2024",
        "d/m/Y" => "15/01/2024",
        "d.m.Y" => "15.01.2024",
        "d-m-Y" => "15-01-2024",
        "F j, Y" => "January 15, 2024"
      }
  """
  def get_date_examples(date) do
    %{
      "Y-m-d" => format_date(date, "Y-m-d"),
      "m/d/Y" => format_date(date, "m/d/Y"),
      "d/m/Y" => format_date(date, "d/m/Y"),
      "d.m.Y" => format_date(date, "d.m.Y"),
      "d-m-Y" => format_date(date, "d-m-Y"),
      "F j, Y" => format_date(date, "F j, Y")
    }
  end

  @doc """
  Generates example formatted times for all supported formats.

  Returns a map with format codes as keys and formatted examples as values.
  Useful for generating dropdown options and previews.

  ## Examples

      iex> PhoenixKit.Utils.Date.get_time_examples(~T[15:30:00])
      %{
        "H:i" => "15:30",
        "h:i A" => "3:30 PM"
      }
  """
  def get_time_examples(time) do
    %{
      "H:i" => format_time(time, "H:i"),
      "h:i A" => format_time(time, "h:i A")
    }
  end

  @doc """
  Formats a datetime (NaiveDateTime) according to the specified date format.

  Extracts the date part and formats it using format_date/2.
  Returns "Never" for nil values.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_datetime(~N[2024-01-15 15:30:00], "F j, Y")
      "January 15, 2024"

      iex> PhoenixKit.Utils.Date.format_datetime(nil, "Y-m-d")
      "Never"
  """
  def format_datetime(nil, _format), do: "Never"

  def format_datetime(datetime, format) do
    date = NaiveDateTime.to_date(datetime)
    format_date(date, format)
  end

  @doc """
  Gets all supported date format options with dynamic examples.

  Returns a list of {label, format_code} tuples suitable for dropdown menus.
  Each label includes the format description and a current date example.

  ## Examples

      iex> PhoenixKit.Utils.Date.get_date_format_options()
      [
        {"YYYY-MM-DD (2025-09-02)", "Y-m-d"},
        {"MM/DD/YYYY (09/02/2025)", "m/d/Y"},
        # ... more formats
      ]
  """
  def get_date_format_options do
    today = Date.utc_today()
    date_examples = get_date_examples(today)

    [
      {"YYYY-MM-DD (#{date_examples["Y-m-d"]})", "Y-m-d"},
      {"MM/DD/YYYY (#{date_examples["m/d/Y"]})", "m/d/Y"},
      {"DD/MM/YYYY (#{date_examples["d/m/Y"]})", "d/m/Y"},
      {"DD.MM.YYYY (#{date_examples["d.m.Y"]})", "d.m.Y"},
      {"DD-MM-YYYY (#{date_examples["d-m-Y"]})", "d-m-Y"},
      {"Month Day, Year (#{date_examples["F j, Y"]})", "F j, Y"}
    ]
  end

  @doc """
  Gets all supported time format options with dynamic examples.

  Returns a list of {label, format_code} tuples suitable for dropdown menus.
  Each label includes the format description and a current time example.

  ## Examples

      iex> PhoenixKit.Utils.Date.get_time_format_options()
      [
        {"24 Hour (15:30)", "H:i"},
        {"12 Hour (3:30 PM)", "h:i A"}
      ]
  """
  def get_time_format_options do
    now = Time.utc_now()
    time_examples = get_time_examples(now)

    [
      {"24 Hour (#{time_examples["H:i"]})", "H:i"},
      {"12 Hour (#{time_examples["h:i A"]})", "h:i A"}
    ]
  end

  ## Settings-Aware Functions
  ## These functions automatically load format preferences from Settings.
  ## An instant (a `DateTime`, or a `NaiveDateTime`, read as UTC) is shown in
  ## the site time zone (Settings → `time_zone`); a `Date` or a `Time` has no
  ## instant to move and is formatted as given.

  @doc """
  Formats a datetime using the user's date format preference from Settings.

  Automatically loads the date_format setting and applies it to the datetime,
  in the site time zone — 23:30 UTC on a site in UTC+3 is the next day.
  Returns "Never" for nil values.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_datetime_with_user_format(~N[2024-01-15 15:30:00])
      "January 15, 2024"  # If user has "F j, Y" format selected

      iex> PhoenixKit.Utils.Date.format_datetime_with_user_format(nil)
      "Never"
  """
  def format_datetime_with_user_format(datetime) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    format_datetime(in_site_zone(datetime), date_format)
  end

  @doc """
  Formats a date using the user's date format preference from Settings.

  Automatically loads the date_format setting and applies it to the date. A
  `DateTime` or `NaiveDateTime` gives its date in the site time zone.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_date_with_user_format(~D[2024-01-15])
      "January 15, 2024"  # If user has "F j, Y" format selected
  """
  def format_date_with_user_format(date) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    format_date(in_site_zone(date), date_format)
  end

  @doc """
  Formats a time using the user's time format preference from Settings.
  Automatically loads the time_format setting and applies it to the time. A
  `DateTime` or `NaiveDateTime` gives its time in the site time zone.
  ## Examples
      iex> PhoenixKit.Utils.Date.format_time_with_user_format(~T[15:30:00])
      "3:30 PM"  # If user has "h:i A" format selected
  """
  def format_time_with_user_format(time) do
    time_format = Settings.get_setting("time_format", "H:i")
    format_time(in_site_zone(time), time_format)
  end

  @doc """
  Formats a datetime (NaiveDateTime or DateTime) showing both date and time
  according to the specified date and time formats.

  Returns "Never" for nil values.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_datetime_full(~N[2024-01-15 15:30:00], "F j, Y", "h:i A")
      "January 15, 2024 3:30 PM"

      iex> PhoenixKit.Utils.Date.format_datetime_full(nil, "Y-m-d", "H:i")
      "Never"
  """
  def format_datetime_full(nil, _date_format, _time_format), do: "Never"

  def format_datetime_full(datetime, date_format, time_format) do
    date = NaiveDateTime.to_date(datetime)
    time = NaiveDateTime.to_time(datetime)
    formatted_date = format_date(date, date_format)
    formatted_time = format_time(time, time_format)
    "#{formatted_date} #{formatted_time}"
  end

  @doc """
  Formats a datetime showing both date and time using user preferences from Settings.

  Automatically loads date_format and time_format settings and applies them,
  in the site time zone. Returns "Never" for nil values.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_datetime_full_with_user_format(~N[2024-01-15 15:30:00])
      "January 15, 2024 3:30 PM"  # If user has "F j, Y" and "h:i A" formats selected

      iex> PhoenixKit.Utils.Date.format_datetime_full_with_user_format(nil)
      "Never"
  """
  def format_datetime_full_with_user_format(datetime) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    time_format = Settings.get_setting("time_format", "H:i")
    format_datetime_full(in_site_zone(datetime), date_format, time_format)
  end

  @doc """
  Formats a datetime using the user's timezone and date format preferences.

  Takes a user struct and uses their personal timezone preference if set,
  otherwise falls back to system timezone, and finally UTC as last resort.

  ## Examples

      iex> user = %User{user_timezone: "+5"}
      iex> PhoenixKit.Utils.Date.format_datetime_with_user_timezone(~N[2024-01-15 15:30:00], user)
      "January 15, 2024"  # If user has "F j, Y" format selected

      iex> user = %User{user_timezone: nil}  # Falls back to system timezone
      iex> PhoenixKit.Utils.Date.format_datetime_with_user_timezone(~N[2024-01-15 15:30:00], user)
      "2024-01-15"  # System default format
  """
  def format_datetime_with_user_timezone(datetime, user) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    format_datetime_with_timezone(datetime, date_format, user)
  end

  @doc """
  Formats a date using the user's timezone and date format preferences.

  Takes a user struct and uses their personal timezone preference if set,
  otherwise falls back to system timezone.

  ## Examples

      iex> user = %User{user_timezone: "+5"}
      iex> PhoenixKit.Utils.Date.format_date_with_user_timezone(~D[2024-01-15], user)
      "January 15, 2024"  # If user has "F j, Y" format selected
  """
  def format_date_with_user_timezone(date, user) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    format_date_with_timezone(date, date_format, user)
  end

  @doc """
  Formats a time using the user's timezone and time format preferences.

  Takes a user struct and uses their personal timezone preference if set,
  otherwise falls back to system timezone.

  ## Examples

      iex> user = %User{user_timezone: "+5"}
      iex> PhoenixKit.Utils.Date.format_time_with_user_timezone(~T[15:30:00], user)
      "3:30 PM"  # If user has "h:i A" format selected
  """
  def format_time_with_user_timezone(time, user) do
    time_format = Settings.get_setting("time_format", "H:i")
    format_time_with_timezone(time, time_format, user)
  end

  # Private helper function to handle timezone conversion and formatting
  defp format_datetime_with_timezone(datetime, format, user) do
    case datetime do
      nil ->
        "Never"

      %NaiveDateTime{} = naive_dt ->
        # Convert NaiveDateTime to UTC DateTime first, then shift timezone
        utc_datetime = DateTime.from_naive!(naive_dt, "Etc/UTC")
        shifted_datetime = shift_to_user_timezone(utc_datetime, user)
        format_datetime(shifted_datetime, format)

      %DateTime{} = dt ->
        # Already a DateTime, shift to user timezone
        shifted_datetime = shift_to_user_timezone(dt, user)
        format_datetime(shifted_datetime, format)

      _ ->
        # Fallback for other types
        format_datetime(datetime, format)
    end
  end

  # Private helper function to handle timezone conversion for dates
  defp format_date_with_timezone(date, format, user) do
    case date do
      %Date{} = d ->
        # Pure dates don't need timezone conversion
        format_date(d, format)

      %NaiveDateTime{} = naive_dt ->
        # Convert to user's timezone first, then extract date
        utc_datetime = DateTime.from_naive!(naive_dt, "Etc/UTC")
        shifted_datetime = shift_to_user_timezone(utc_datetime, user)
        format_date(DateTime.to_date(shifted_datetime), format)

      %DateTime{} = dt ->
        # Shift to user timezone, then extract date
        shifted_datetime = shift_to_user_timezone(dt, user)
        format_date(DateTime.to_date(shifted_datetime), format)

      _ ->
        # Fallback
        format_date(date, format)
    end
  end

  # Private helper function to handle timezone conversion for times
  defp format_time_with_timezone(time, format, user) do
    case time do
      %Time{} = t ->
        # Pure times don't have timezone context
        format_time(t, format)

      %NaiveDateTime{} = naive_dt ->
        # Convert to user's timezone first, then extract time
        utc_datetime = DateTime.from_naive!(naive_dt, "Etc/UTC")
        shifted_datetime = shift_to_user_timezone(utc_datetime, user)
        format_time(DateTime.to_time(shifted_datetime), format)

      %DateTime{} = dt ->
        # Shift to user timezone, then extract time
        shifted_datetime = shift_to_user_timezone(dt, user)
        format_time(DateTime.to_time(shifted_datetime), format)

      _ ->
        # Fallback
        format_time(time, format)
    end
  end

  # Private helper to shift datetime to user's timezone
  defp shift_to_user_timezone(datetime, user) do
    user_timezone_offset = get_user_timezone(user)
    shift_to_timezone_offset(datetime, user_timezone_offset)
  end

  # Private helper to shift datetime to user's timezone using cached settings
  defp shift_to_user_timezone_cached(datetime, user, settings) do
    user_timezone_offset = get_user_timezone_cached(user, settings)
    shift_to_timezone_offset(datetime, user_timezone_offset)
  end

  # Private helper to apply timezone offset to datetime
  # One choke point for every timestamp the app renders. Handles both an IANA
  # identifier ("Europe/Warsaw", DST applied for the instant being shown) and a
  # pre-IANA numeric offset ("2"), which still shifts by a fixed amount so
  # accounts written before the change keep reading the same.
  #
  # This used to parse with `Integer.parse/1` and require an empty remainder,
  # so `"5.5"` left `".5"`, failed the match, and returned the timestamp
  # unshifted — every UTC+5:30 and +9:30 account was quietly reading UTC.
  defp shift_to_timezone_offset(datetime, timezone), do: TimeZone.shift(datetime, timezone)

  # An instant in the site time zone, for the Settings-aware formatters that
  # take no user. They read the date and time formats from Settings and used
  # to print the stored UTC clock as if it were local. Read through the
  # settings cache (a write invalidates it): these run once per row of a list.
  defp in_site_zone(value), do: in_zone(value, Settings.get_setting_cached("time_zone", "0"))

  # A `NaiveDateTime` is UTC here, as in every other function of this module;
  # a `Date`, a `Time` or anything else has no instant to move and is returned
  # untouched. No zone (`nil`/`""`) leaves the clock as stored.
  defp in_zone(value, zone) when zone in [nil, ""], do: value
  defp in_zone(%DateTime{} = datetime, zone), do: shift_to_timezone_offset(datetime, zone)

  defp in_zone(%NaiveDateTime{} = naive, zone),
    do: naive |> DateTime.from_naive!("Etc/UTC") |> shift_to_timezone_offset(zone)

  defp in_zone(value, _zone), do: value

  # Cached variant of format_datetime_with_timezone
  defp format_datetime_with_timezone_cached(datetime, format, user, settings) do
    case datetime do
      nil ->
        "Never"

      %NaiveDateTime{} = naive_dt ->
        utc_datetime = DateTime.from_naive!(naive_dt, "Etc/UTC")
        shifted_datetime = shift_to_user_timezone_cached(utc_datetime, user, settings)
        format_datetime(shifted_datetime, format)

      %DateTime{} = dt ->
        shifted_datetime = shift_to_user_timezone_cached(dt, user, settings)
        format_datetime(shifted_datetime, format)

      _ ->
        format_datetime(datetime, format)
    end
  end

  # Cached variant of format_date_with_timezone
  defp format_date_with_timezone_cached(date, format, user, settings) do
    case date do
      %Date{} = d ->
        format_date(d, format)

      %NaiveDateTime{} = naive_dt ->
        utc_datetime = DateTime.from_naive!(naive_dt, "Etc/UTC")
        shifted_datetime = shift_to_user_timezone_cached(utc_datetime, user, settings)
        format_date(DateTime.to_date(shifted_datetime), format)

      %DateTime{} = dt ->
        shifted_datetime = shift_to_user_timezone_cached(dt, user, settings)
        format_date(DateTime.to_date(shifted_datetime), format)

      _ ->
        format_date(date, format)
    end
  end

  # Cached variant of format_time_with_timezone
  defp format_time_with_timezone_cached(time, format, user, settings) do
    case time do
      %Time{} = t ->
        format_time(t, format)

      %NaiveDateTime{} = naive_dt ->
        utc_datetime = DateTime.from_naive!(naive_dt, "Etc/UTC")
        shifted_datetime = shift_to_user_timezone_cached(utc_datetime, user, settings)
        format_time(DateTime.to_time(shifted_datetime), format)

      %DateTime{} = dt ->
        shifted_datetime = shift_to_user_timezone_cached(dt, user, settings)
        format_time(DateTime.to_time(shifted_datetime), format)

      _ ->
        format_time(time, format)
    end
  end

  @doc """
  Gets the effective timezone for a user.

  Returns the user's personal timezone if set, otherwise falls back to
  system timezone, and finally UTC as last resort.

  ## Examples

      iex> user = %User{user_timezone: "+5"}
      iex> PhoenixKit.Utils.Date.get_user_timezone(user)
      "+5"

      iex> user = %User{user_timezone: nil}
      iex> PhoenixKit.Utils.Date.get_user_timezone(user)
      "0"  # System default
  """
  def get_user_timezone(user) do
    case user.user_timezone do
      # Blank is "not set" too: the changeset normalises "" to nil, but a row
      # written around it would otherwise read as UTC instead of the site.
      value when value in [nil, ""] -> Settings.get_setting("time_zone", "0")
      timezone -> timezone
    end
  end

  ## Cache-Optimized Functions
  ## These functions accept pre-loaded settings to eliminate database queries

  @doc """
  Formats a datetime using pre-loaded date format settings (cache-optimized).

  This function accepts pre-loaded settings to avoid database queries,
  providing significant performance improvements when formatting many dates.
  When the settings carry `"time_zone"`, the date is the one in that zone (a
  `NaiveDateTime` is read as UTC); without it, the date is taken as given.

  ## Examples

      iex> settings = %{"date_format" => "F j, Y"}
      iex> PhoenixKit.Utils.Date.format_datetime_with_cached_settings(~N[2024-01-15 15:30:00], settings)
      "January 15, 2024"

      iex> PhoenixKit.Utils.Date.format_datetime_with_cached_settings(nil, %{})
      "Never"
  """
  def format_datetime_with_cached_settings(nil, _settings), do: "Never"

  def format_datetime_with_cached_settings(datetime, settings) do
    date_format = Map.get(settings, "date_format", "Y-m-d")
    date = datetime |> in_zone(Map.get(settings, "time_zone")) |> NaiveDateTime.to_date()
    format_date(date, date_format)
  end

  @doc """
  Formats a date using pre-loaded date format settings (cache-optimized).

  ## Examples

      iex> settings = %{"date_format" => "F j, Y"}
      iex> PhoenixKit.Utils.Date.format_date_with_cached_settings(~D[2024-01-15], settings)
      "January 15, 2024"
  """
  def format_date_with_cached_settings(date, settings) do
    date_format = Map.get(settings, "date_format", "Y-m-d")
    format_date(date, date_format)
  end

  @doc """
  Formats a time using pre-loaded time format settings (cache-optimized).

  ## Examples

      iex> settings = %{"time_format" => "h:i A"}
      iex> PhoenixKit.Utils.Date.format_time_with_cached_settings(~T[15:30:00], settings)
      "3:30 PM"
  """
  def format_time_with_cached_settings(time, settings) do
    time_format = Map.get(settings, "time_format", "H:i")
    format_time(time, time_format)
  end

  @doc """
  Formats a datetime with timezone using pre-loaded settings (cache-optimized).

  This function combines timezone conversion with cached date/time formatting
  for optimal performance when processing multiple users' data.

  ## Examples

      iex> settings = %{"date_format" => "F j, Y"}
      iex> user = %User{user_timezone: "+5"}
      iex> PhoenixKit.Utils.Date.format_datetime_with_user_timezone_cached(~N[2024-01-15 15:30:00], user, settings)
      "January 15, 2024"
  """
  def format_datetime_with_user_timezone_cached(datetime, user, settings) do
    date_format = Map.get(settings, "date_format", "Y-m-d")
    format_datetime_with_timezone_cached(datetime, date_format, user, settings)
  end

  @doc """
  Formats a date with timezone using pre-loaded settings (cache-optimized).

  ## Examples

      iex> settings = %{"date_format" => "F j, Y"}
      iex> user = %User{user_timezone: "+5"}
      iex> PhoenixKit.Utils.Date.format_date_with_user_timezone_cached(~D[2024-01-15], user, settings)
      "January 15, 2024"
  """
  def format_date_with_user_timezone_cached(date, user, settings) do
    date_format = Map.get(settings, "date_format", "Y-m-d")
    format_date_with_timezone_cached(date, date_format, user, settings)
  end

  @doc """
  Formats a time with timezone using pre-loaded settings (cache-optimized).

  ## Examples

      iex> settings = %{"time_format" => "h:i A"}
      iex> user = %User{user_timezone: "+5"}
      iex> PhoenixKit.Utils.Date.format_time_with_user_timezone_cached(~T[15:30:00], user, settings)
      "8:30 PM"
  """
  def format_time_with_user_timezone_cached(time, user, settings) do
    time_format = Map.get(settings, "time_format", "H:i")
    format_time_with_timezone_cached(time, time_format, user, settings)
  end

  @doc """
  Gets the effective timezone for a user using cached system timezone.

  Optimized version that accepts pre-loaded system timezone setting.

  ## Examples

      iex> settings = %{"time_zone" => "+1"}
      iex> user = %User{user_timezone: nil}
      iex> PhoenixKit.Utils.Date.get_user_timezone_cached(user, settings)
      "+1"

      iex> user = %User{user_timezone: "+5"}
      iex> PhoenixKit.Utils.Date.get_user_timezone_cached(user, %{})
      "+5"
  """
  def get_user_timezone_cached(user, settings) do
    case user.user_timezone do
      value when value in [nil, ""] -> Map.get(settings, "time_zone", "0")
      timezone -> timezone
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Timezone offset helpers — for converting between UTC and system timezone
  # stored as a numeric hour offset string (e.g., "2", "-5", "5.5").
  # Used primarily for datetime-local form inputs which have no timezone.
  # ═══════════════════════════════════════════════════════════════════════════

  @doc """
  Converts a timezone value to its offset from UTC in seconds, right now.

  Deprecated: every caller that added this to another instant was an hour
  off across a daylight-saving switch (the calendar's day window, the
  bookings frame), because an IANA zone has no single offset. Use
  `PhoenixKit.Utils.TimeZone.shift/2` to display an instant, `from_wall/2`
  to read a typed wall clock, `date_start/2` for a day window and
  `local_date/2` for "today" — each resolves the instant it is given.

  Accepts a legacy offset like `"0"`, `"2"`, `"-5"`, `"5.5"` (hours from
  UTC) or an IANA id (resolved for this instant). Returns `0` for invalid
  input (safe default).

  ## Examples

      iex> PhoenixKit.Utils.Date.offset_to_seconds("0")
      0

      iex> PhoenixKit.Utils.Date.offset_to_seconds("2")
      7200

      iex> PhoenixKit.Utils.Date.offset_to_seconds("-5")
      -18000

      iex> PhoenixKit.Utils.Date.offset_to_seconds("5.5")
      19800

      iex> PhoenixKit.Utils.Date.offset_to_seconds("invalid")
      0
  """
  @deprecated "A snapshot of the offset now; use TimeZone.shift/2, from_wall/2, date_start/2 or local_date/2, which resolve the instant being converted"
  def offset_to_seconds(tz_offset) when is_binary(tz_offset) do
    # Delegated so an IANA identifier resolves instead of falling through to 0.
    # The old body was `Float.parse/1`, which cannot read "Europe/Warsaw" and
    # returned 0 — so every caller silently computed in UTC on any site that
    # used the timezone picker, which since the move to IANA ids is every site
    # that has touched the setting. Callers doing arithmetic across a
    # daylight-saving boundary want `TimeZone.shift/2` or `from_wall/2`, which
    # are correct per-instant; this is a snapshot of the offset now.
    TimeZone.offset_seconds(tz_offset)
  end

  def offset_to_seconds(_), do: 0

  @doc """
  Shifts a DateTime by the system timezone offset (for display purposes only).

  The result is NOT a properly-zoned DateTime — its `time_zone` still says UTC.
  Use only when you need the wall-clock value for display. Never store this.
  """
  def shift_to_offset(%DateTime{} = dt, tz_offset) do
    # Routed through TimeZone so an IANA identifier works here too. The old
    # body added `offset_to_seconds/1`, which cannot parse "Europe/Warsaw" and
    # returned 0 — silently rendering UTC once a site set a named timezone.
    TimeZone.shift(dt, tz_offset)
  end

  @doc """
  Parses a datetime-local input value (assumed to be in `tz_offset` timezone)
  and returns the equivalent UTC `DateTime`.

  Returns `{:ok, datetime}` or an error tuple. The tolerance input format is
  `"YYYY-MM-DDTHH:MM"` (no seconds) or `"YYYY-MM-DDTHH:MM:SS"`.

  ## Examples

      iex> {:ok, dt} = PhoenixKit.Utils.Date.parse_datetime_local("2026-04-14T12:00", "0")
      iex> DateTime.to_iso8601(dt)
      "2026-04-14T12:00:00Z"

      iex> {:ok, dt} = PhoenixKit.Utils.Date.parse_datetime_local("2026-04-14T12:00", "2")
      iex> DateTime.to_iso8601(dt)
      "2026-04-14T10:00:00Z"

      iex> PhoenixKit.Utils.Date.parse_datetime_local("not-a-date", "0")
      {:error, :invalid_format}
  """
  def parse_datetime_local("", _tz_offset), do: {:error, :empty}
  def parse_datetime_local(nil, _tz_offset), do: {:error, :empty}

  def parse_datetime_local(str, tz_offset) when is_binary(str) do
    case parse_naive_datetime_local(str) do
      {:ok, naive} ->
        # TimeZone.from_wall/2 rather than subtracting a fixed offset: with a
        # named timezone the offset depends on the date being parsed, so a
        # window scheduled across a daylight-saving boundary lands on the hour
        # the admin actually typed.
        case TimeZone.from_wall(naive, tz_offset) do
          {:ok, utc} -> {:ok, utc}
          :error -> {:error, :invalid_format}
        end

      {:error, _reason} ->
        {:error, :invalid_format}
    end
  end

  defp parse_naive_datetime_local(str) do
    # datetime-local inputs typically return "YYYY-MM-DDTHH:MM" (no seconds)
    case NaiveDateTime.from_iso8601(str <> ":00") do
      {:ok, naive} -> {:ok, naive}
      _ -> NaiveDateTime.from_iso8601(str)
    end
  end

  @doc """
  Formats a UTC `DateTime` as a `datetime-local`-compatible string,
  shifted to the given timezone offset.

  Returns `""` for `nil` input. Output format: `"YYYY-MM-DDTHH:MM"`.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_datetime_local(~U[2026-04-14 12:00:00Z], "0")
      "2026-04-14T12:00"

      iex> PhoenixKit.Utils.Date.format_datetime_local(~U[2026-04-14 12:00:00Z], "2")
      "2026-04-14T14:00"

      iex> PhoenixKit.Utils.Date.format_datetime_local(nil, "0")
      ""
  """
  def format_datetime_local(nil, _tz_offset), do: ""

  def format_datetime_local(%DateTime{} = dt, tz_offset) do
    Calendar.strftime(shift_to_offset(dt, tz_offset), "%Y-%m-%dT%H:%M")
  end
end
