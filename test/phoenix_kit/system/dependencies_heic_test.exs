defmodule PhoenixKit.System.DependenciesHeicTest do
  @moduledoc """
  Whether ImageMagick can READ HEIC (the iPhone's photo format), read from the list
  of formats it prints. It only matters that it can decode: PhoenixKit never writes
  HEIC (a rendition of a HEIC photo is a JPEG).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.System.Dependencies

  describe "parse_heic/1" do
    test "reads the libheif version ImageMagick 7 prints" do
      out = """
         HEIC* HEIC      r--   High Efficiency Image Format (1.19.8)
      """

      assert Dependencies.parse_heic(out) == {:ok, "1.19.8"}
    end

    test "accepts a HEIC that is also written, or whose description has no version" do
      assert Dependencies.parse_heic("      HEIC* HEIC       rw+  High Efficiency Image Format\n") ==
               {:ok, "libheif"}

      assert Dependencies.parse_heic("   HEIC HEIC  r--  High Efficiency Image Format (1.12)\n") ==
               {:ok, "1.12"}
    end

    test "finds it among the other formats" do
      out = """
         Format  Module    Mode  Description
      -------------------------------------------------------------
          AVIF* HEIC      r--   AV1 Image File Format (1.19.8)
          HEIC* HEIC      r--   High Efficiency Image Format (1.19.8)
          JPEG* JPEG      rw-   Joint Photographic Experts Group JFIF format
           PNG* PNG       rw-   Portable Network Graphics
      """

      assert Dependencies.parse_heic(out) == {:ok, "1.19.8"}
    end

    test "a HEIC that can only be written cannot be used" do
      assert Dependencies.parse_heic(
               "   HEIC  HEIC      -w-   High Efficiency Image Format (1.2.0)\n"
             ) == {:error, :not_installed}
    end

    test "a build with no HEIC at all cannot read it" do
      out = """
           PNG* PNG       rw-   Portable Network Graphics
          WEBP* WEBP      rw-   WebP Image Format
      """

      assert Dependencies.parse_heic(out) == {:error, :not_installed}
      assert Dependencies.parse_heic("") == {:error, :not_installed}
      assert Dependencies.parse_heic("convert: command not found") == {:error, :not_installed}
    end

    test "AVIF and HEIF lines are not HEIC" do
      assert Dependencies.parse_heic("   AVIF* HEIC      r--   AV1 Image File Format (1.19.8)\n") ==
               {:error, :not_installed}
    end
  end

  test "external_tools/0 lists HEIC support after the ImageMagick check" do
    ids = Enum.map(Dependencies.external_tools(), & &1.id)

    assert :heic in ids
    assert Enum.find_index(ids, &(&1 == :heic)) > Enum.find_index(ids, &(&1 == :imagemagick))
  end
end
