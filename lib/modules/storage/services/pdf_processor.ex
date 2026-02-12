defmodule PhoenixKit.Modules.Storage.PdfProcessor do
  @moduledoc """
  Poppler-based PDF processing module.

  Handles PDF operations using poppler-utils command-line tools:
  - `pdftoppm` - Convert PDF pages to images (JPEG)
  - `pdfinfo` - Extract PDF metadata (page count, author, title)

  ## Dependencies

  Requires `poppler-utils` to be installed:
  - Debian/Ubuntu: `apt-get install poppler-utils`
  - macOS: `brew install poppler`
  """

  require Logger

  @doc """
  Convert the first page of a PDF to a JPEG image.

  Uses `pdftoppm` to render the first page at the specified DPI.

  ## Parameters

  - `pdf_path` - Path to the input PDF file
  - `output_prefix` - Prefix for the output JPEG file (e.g., "/tmp/my_pdf")
  - `opts` - Options
    - `:dpi` - Resolution in DPI (default: 150)

  ## Returns

  - `{:ok, jpeg_path}` - Path to the generated JPEG file
  - `{:error, reason}` - If conversion fails
  """
  def first_page_to_jpeg(pdf_path, output_prefix, opts \\ []) do
    dpi = Keyword.get(opts, :dpi, 150)

    args = [
      "-jpeg",
      "-f",
      "1",
      "-l",
      "1",
      "-r",
      Integer.to_string(dpi),
      pdf_path,
      output_prefix
    ]

    case System.cmd("pdftoppm", args, stderr_to_stdout: true) do
      {_output, 0} ->
        # pdftoppm appends page number suffix (e.g., "-1.jpg" or "-01.jpg")
        case Path.wildcard("#{output_prefix}*.jpg") do
          [jpeg_path | _] ->
            {:ok, jpeg_path}

          [] ->
            {:error, "pdftoppm produced no output files"}
        end

      {output, exit_code} ->
        {:error, "pdftoppm failed (exit #{exit_code}): #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      if e.reason == :enoent do
        {:error, :poppler_not_installed}
      else
        {:error, "pdftoppm error: #{inspect(e.reason)}"}
      end
  end

  @doc """
  Extract metadata from a PDF file using `pdfinfo`.

  ## Parameters

  - `pdf_path` - Path to the PDF file

  ## Returns

  - `{:ok, metadata}` - Map with extracted metadata
  - `{:ok, %{}}` - Empty map on failure (graceful degradation)
  """
  def extract_metadata(pdf_path) do
    case System.cmd("pdfinfo", [pdf_path], stderr_to_stdout: true) do
      {output, 0} ->
        metadata = parse_pdfinfo_output(output)
        {:ok, metadata}

      {_output, _exit_code} ->
        Logger.warning("PdfProcessor: pdfinfo failed for #{pdf_path}")
        {:ok, %{}}
    end
  rescue
    e in ErlangError ->
      if e.reason == :enoent do
        Logger.warning("PdfProcessor: pdfinfo not installed")
      else
        Logger.warning("PdfProcessor: pdfinfo error: #{inspect(e.reason)}")
      end

      {:ok, %{}}
  end

  @field_mapping %{
    "Pages" => "page_count",
    "Title" => "title",
    "Author" => "author",
    "Creator" => "creator",
    "CreationDate" => "creation_date"
  }

  defp parse_pdfinfo_output(output) do
    output
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          parse_pdfinfo_field(String.trim(key), String.trim(value), acc)

        _ ->
          acc
      end
    end)
  end

  defp parse_pdfinfo_field(key, value, acc) do
    case Map.get(@field_mapping, key) do
      nil -> acc
      "page_count" -> parse_page_count(value, acc)
      mapped_key when value != "" -> Map.put(acc, mapped_key, value)
      _mapped_key -> acc
    end
  end

  defp parse_page_count(value, acc) do
    case Integer.parse(value) do
      {count, _} -> Map.put(acc, "page_count", count)
      :error -> acc
    end
  end
end
