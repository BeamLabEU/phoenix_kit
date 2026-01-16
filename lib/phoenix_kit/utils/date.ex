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

  alias PhoenixKit.Settings

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
  ## These functions automatically load format preferences from Settings

  @doc """
  Formats a datetime using the user's date format preference from Settings.

  Automatically loads the date_format setting and applies it to the datetime.
  Returns "Never" for nil values.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_datetime_with_user_format(~N[2024-01-15 15:30:00])
      "January 15, 2024"  # If user has "F j, Y" format selected

      iex> PhoenixKit.Utils.Date.format_datetime_with_user_format(nil)
      "Never"
  """
  def format_datetime_with_user_format(datetime) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    format_datetime(datetime, date_format)
  end

  @doc """
  Formats a date using the user's date format preference from Settings.

  Automatically loads the date_format setting and applies it to the date.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_date_with_user_format(~D[2024-01-15])
      "January 15, 2024"  # If user has "F j, Y" format selected
  """
  def format_date_with_user_format(date) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    format_date(date, date_format)
  end

  @doc """
  Formats a time using the user's time format preference from Settings.
  Automatically loads the time_format setting and applies it to the time.
  ## Examples
      iex> PhoenixKit.Utils.Date.format_time_with_user_format(~T[15:30:00])
      "3:30 PM"  # If user has "h:i A" format selected
  """
  def format_time_with_user_format(time) do
    time_format = Settings.get_setting("time_format", "H:i")
    format_time(time, time_format)
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

  Automatically loads date_format and time_format settings and applies them.
  Returns "Never" for nil values.

  ## Examples

      iex> PhoenixKit.Utils.Date.format_datetime_full_with_user_format(~N[2024-01-15 15:30:00])
      "January 15, 2024 3:30 PM"  # If user has "F j, Y" and "h:i A" formats selected

      iex> PhoenixKit.Utils.Date.format_datetime_full_with_user_format(nil)
      "Never"
  """
  def format_datetime_full_with_user_format(datetime) do
    date_format = Settings.get_setting("date_format", "Y-m-d")
    time_format = Settings.get_setting("time_format", "H:i")
    format_datetime_full(datetime, date_format, time_format)
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
  defp shift_to_timezone_offset(datetime, timezone_offset) do
    case Integer.parse(timezone_offset) do
      {offset_hours, ""} ->
        # Convert offset hours to seconds and shift
        offset_seconds = offset_hours * 3600
        DateTime.add(datetime, offset_seconds, :second)

      _ ->
        # Invalid timezone offset, return original datetime
        datetime
    end
  end

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
      nil -> Settings.get_setting("time_zone", "0")
      timezone -> timezone
    end
  end

  ## Cache-Optimized Functions
  ## These functions accept pre-loaded settings to eliminate database queries

  @doc """
  Formats a datetime using pre-loaded date format settings (cache-optimized).

  This function accepts pre-loaded settings to avoid database queries,
  providing significant performance improvements when formatting many dates.

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
    date = NaiveDateTime.to_date(datetime)
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
      nil -> Map.get(settings, "time_zone", "0")
      timezone -> timezone
    end
  end
end
