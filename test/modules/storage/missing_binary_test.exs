defmodule PhoenixKit.Modules.Storage.MissingBinaryTest do
  @moduledoc """
  A missing poppler/ImageMagick binary is reported as missing. `System.cmd/3`
  raises `ErlangError` with `:enoent` in `original` — `reason` is `nil` — so
  checks that read `reason` never fired: a container without poppler logged
  "pdftoppm error: nil" for every PDF instead of saying it isn't installed.

  `PATH` is pointed at an empty directory, so no real binary is found
  whatever the machine has installed.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage.PdfProcessor
  alias PhoenixKit.System.Dependencies

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = System.get_env("PATH")
    empty = Path.join(dir, "empty_path")
    File.mkdir_p!(empty)
    System.put_env("PATH", empty)
    Dependencies.clear_cache()

    on_exit(fn ->
      System.put_env("PATH", path)
      Dependencies.clear_cache()
    end)

    %{pdf: Path.join(dir, "missing.pdf"), prefix: Path.join(dir, "page")}
  end

  test "first_page_to_jpeg/3 says poppler isn't installed", %{pdf: pdf, prefix: prefix} do
    assert PdfProcessor.first_page_to_jpeg(pdf, prefix) == {:error, :poppler_not_installed}
  end

  test "extract_metadata/1 logs that pdfinfo isn't installed", %{pdf: pdf} do
    log = capture_log(fn -> assert PdfProcessor.extract_metadata(pdf) == {:ok, %{}} end)

    assert log =~ "pdfinfo not installed"
  end

  test "dependency checks report the tools as not installed" do
    assert Dependencies.check_poppler() == {:error, :not_installed}
    assert Dependencies.check_imagemagick() == {:error, :not_installed}
    assert Dependencies.check_ffmpeg() == {:error, :not_installed}
  end

  test "external_tools/0 lists every program on the PATH as not installed" do
    tools = Dependencies.external_tools()

    assert Enum.map(tools, & &1.id) ==
             [:imagemagick, :magick, :heic, :libvips, :ffmpeg, :ffprobe, :pdftoppm, :pdfinfo]

    {libvips, programs} = Enum.split_with(tools, &(&1.id == :libvips))
    assert Enum.all?(programs, &(&1.status == {:error, :not_installed}))

    # libvips is not a program: it arrives with the Vix package, so the PATH
    # does not decide whether it is there.
    assert [%{status: {:ok, version}}] = libvips
    assert version =~ ~r/^\d+\.\d+\.\d+/
  end
end
