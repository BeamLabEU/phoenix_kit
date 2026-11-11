defmodule PhoenixKit.Modules.Storage.AnnotationThumbnailFontArgsTest do
  @moduledoc """
  `-font` is added to a text draw only, and only with a font whose file is
  there. The font is resolved once per node, so these tests (sync) reset it.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Storage.AnnotationThumbnail

  @cache_key {AnnotationThumbnail, :font}
  @text_draw ["-pointsize", "20", "-draw", "text 1,1 'x'"]

  # A CI host with ImageMagick but no usable font gets no `-font` at all.
  @usable_font? System.find_executable("convert") != nil and
                  AnnotationThumbnail.font_args(@text_draw) != []

  setup do
    :persistent_term.erase(@cache_key)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :annotation_font)
      :persistent_term.erase(@cache_key)
    end)
  end

  test "no font for an outline-only draw" do
    assert AnnotationThumbnail.font_args(["-stroke", "red", "-draw", "rectangle 1,1 5,5"]) == []
  end

  if @usable_font? do
    test "a font that exists, before a text draw" do
      assert ["-font", font] = AnnotationThumbnail.font_args(@text_draw)
      assert is_binary(font) and font != ""
    end

    test "a configured font that is a file is used as it is" do
      path =
        Path.join(System.tmp_dir!(), "annotation_font_#{System.unique_integer([:positive])}.ttf")

      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)
      Application.put_env(:phoenix_kit, :annotation_font, path)

      assert ["-font", ^path] = AnnotationThumbnail.font_args(@text_draw)
    end

    test "a configured font ImageMagick cannot read gives way to the picked one" do
      assert ["-font", picked] = AnnotationThumbnail.font_args(@text_draw)
      :persistent_term.erase(@cache_key)
      Application.put_env(:phoenix_kit, :annotation_font, "No-Such-Font-Anywhere")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert ["-font", ^picked] = AnnotationThumbnail.font_args(@text_draw)
        end)

      assert log =~ "No-Such-Font-Anywhere"
    end
  end
end
