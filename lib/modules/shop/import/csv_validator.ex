defmodule PhoenixKit.Modules.Shop.Import.CSVValidator do
  @moduledoc """
  Validates CSV files before import processing.

  Performs early validation to fail fast with meaningful errors
  rather than discovering issues mid-import.

  ## Validation Checks

  1. **File exists and readable** - Basic filesystem check
  2. **CSV parseable** - File is valid CSV format
  3. **Required columns present** - Checks for Handle, Title, Variant Price by default
  4. **Warning detection** - Non-blocking issues like empty rows

  ## Examples

      # Basic validation with default required columns
      case CSVValidator.validate_file("/path/to/products.csv") do
        :ok -> IO.puts("File is valid")
        {:error, reason} -> IO.puts("Validation failed: \#{reason}")
      end

      # Validation with custom required columns
      CSVValidator.validate_headers("/path/to/products.csv", ["Handle", "Title", "Price"])

      # Full validation report
      report = CSVValidator.get_validation_report("/path/to/products.csv")
      # => %{
      #   valid: true,
      #   file_path: "/path/to/products.csv",
      #   headers: ["Handle", "Title", ...],
      #   row_count: 1234,
      #   warnings: ["Some rows have empty Handle values"]
      # }
  """

  alias PhoenixKit.Modules.Shop.ImportConfig

  NimbleCSV.define(ValidatorCSV, separator: ",", escape: "\"")

  @default_required_columns ImportConfig.default_required_columns()

  @doc """
  Validates that a file exists, is readable, and has valid CSV format.

  Returns `:ok` or `{:error, reason}`.
  """
  def validate_file(file_path) do
    with :ok <- check_file_exists(file_path),
         :ok <- check_file_readable(file_path) do
      check_csv_parseable(file_path)
    end
  end

  @doc """
  Extracts and validates CSV headers against required columns.

  Uses default required columns: #{inspect(@default_required_columns)}

  Returns `{:ok, headers}` or `{:error, reason}`.
  """
  def validate_headers(file_path) do
    validate_headers(file_path, @default_required_columns)
  end

  @doc """
  Extracts and validates CSV headers against custom required columns.

  Returns `{:ok, headers}` or `{:error, {:missing_columns, missing}}`.
  """
  def validate_headers(file_path, required_columns) when is_list(required_columns) do
    with :ok <- validate_file(file_path),
         {:ok, headers} <- extract_headers(file_path) do
      missing = find_missing_columns(headers, required_columns)

      if missing == [] do
        {:ok, headers}
      else
        {:error, {:missing_columns, missing}}
      end
    end
  end

  @doc """
  Returns a comprehensive validation report.

  ## Report Structure

      %{
        valid: boolean,
        file_path: string,
        file_size: integer,
        headers: list | nil,
        row_count: integer | nil,
        missing_columns: list,
        warnings: list,
        error: string | nil
      }
  """
  def get_validation_report(file_path, opts \\ []) do
    required_columns = Keyword.get(opts, :required_columns, @default_required_columns)

    report = %{
      valid: false,
      file_path: file_path,
      file_size: nil,
      headers: nil,
      row_count: nil,
      missing_columns: [],
      warnings: [],
      error: nil
    }

    with :ok <- check_file_exists(file_path),
         {:ok, file_size} <- get_file_size(file_path),
         :ok <- check_file_readable(file_path),
         {:ok, headers} <- extract_headers(file_path),
         {:ok, row_count} <- count_data_rows(file_path) do
      missing = find_missing_columns(headers, required_columns)
      warnings = detect_warnings(file_path, headers)

      %{
        report
        | valid: missing == [],
          file_size: file_size,
          headers: headers,
          row_count: row_count,
          missing_columns: missing,
          warnings: warnings
      }
    else
      {:error, reason} ->
        %{report | error: format_error(reason)}
    end
  end

  @doc """
  Extracts headers from a CSV file.

  Returns `{:ok, headers}` or `{:error, reason}`.
  """
  def extract_headers(file_path) do
    file_path
    |> File.stream!([:utf8])
    |> ValidatorCSV.parse_stream(skip_headers: false)
    |> Enum.take(1)
    |> case do
      [headers] when is_list(headers) ->
        {:ok, headers}

      [] ->
        {:error, :empty_file}

      _ ->
        {:error, :invalid_csv_format}
    end
  rescue
    e in NimbleCSV.ParseError ->
      {:error, {:parse_error, Exception.message(e)}}

    e ->
      {:error, {:unexpected_error, Exception.message(e)}}
  end

  # ============================================
  # PRIVATE FUNCTIONS
  # ============================================

  defp check_file_exists(file_path) do
    if File.exists?(file_path) do
      :ok
    else
      {:error, :file_not_found}
    end
  end

  defp check_file_readable(file_path) do
    # Try to open and read first few bytes to check readability
    case File.open(file_path, [:read, :utf8]) do
      {:ok, file} ->
        result = IO.read(file, 1024)
        File.close(file)

        case result do
          {:error, reason} -> {:error, {:file_not_readable, reason}}
          _ -> :ok
        end

      {:error, reason} ->
        {:error, {:file_not_readable, reason}}
    end
  end

  defp check_csv_parseable(file_path) do
    file_path
    |> File.stream!([:utf8])
    |> ValidatorCSV.parse_stream(skip_headers: false)
    |> Enum.take(2)
    |> case do
      [_ | _] -> :ok
      [] -> {:error, :empty_file}
    end
  rescue
    e in NimbleCSV.ParseError ->
      {:error, {:parse_error, Exception.message(e)}}

    _ ->
      {:error, :invalid_csv_format}
  end

  defp get_file_size(file_path) do
    case File.stat(file_path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, {:stat_error, reason}}
    end
  end

  defp count_data_rows(file_path) do
    count =
      file_path
      |> File.stream!([:utf8])
      |> ValidatorCSV.parse_stream(skip_headers: true)
      |> Enum.count()

    {:ok, count}
  rescue
    _ -> {:ok, nil}
  end

  defp find_missing_columns(headers, required_columns) do
    headers_set = MapSet.new(headers)

    required_columns
    |> Enum.reject(fn col -> MapSet.member?(headers_set, col) end)
  end

  defp detect_warnings(file_path, headers) do
    warnings = []

    # Check for Handle column index
    handle_index = Enum.find_index(headers, &(&1 == "Handle"))

    warnings =
      if handle_index do
        empty_handles = count_empty_handles(file_path, handle_index)

        if empty_handles > 0 do
          ["#{empty_handles} rows have empty Handle values" | warnings]
        else
          warnings
        end
      else
        warnings
      end

    # Check for duplicate headers
    duplicate_headers = find_duplicate_headers(headers)

    warnings =
      if duplicate_headers != [] do
        ["Duplicate headers found: #{Enum.join(duplicate_headers, ", ")}" | warnings]
      else
        warnings
      end

    Enum.reverse(warnings)
  end

  defp count_empty_handles(file_path, handle_index) do
    file_path
    |> File.stream!([:utf8])
    |> ValidatorCSV.parse_stream(skip_headers: true)
    |> Enum.count(fn row ->
      handle = Enum.at(row, handle_index, "")
      handle == nil or String.trim(handle) == ""
    end)
  rescue
    _ -> 0
  end

  defp find_duplicate_headers(headers) do
    headers
    |> Enum.frequencies()
    |> Enum.filter(fn {_header, count} -> count > 1 end)
    |> Enum.map(fn {header, _count} -> header end)
  end

  defp format_error(:file_not_found), do: "File not found"
  defp format_error(:empty_file), do: "File is empty"
  defp format_error(:invalid_csv_format), do: "Invalid CSV format"
  defp format_error({:file_not_readable, reason}), do: "File not readable: #{reason}"
  defp format_error({:stat_error, reason}), do: "Cannot read file stats: #{reason}"
  defp format_error({:parse_error, msg}), do: "CSV parse error: #{msg}"
  defp format_error({:unexpected_error, msg}), do: "Unexpected error: #{msg}"
end
