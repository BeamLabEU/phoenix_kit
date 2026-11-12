defmodule PhoenixKit.Modules.Storage.AnnotationThumbnailFontListingTest do
  @moduledoc "Reading a `convert -list font` listing keeps only fonts whose file exists."
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.AnnotationThumbnail

  @listing """
  Path: /etc/ImageMagick-6/type-ghostscript.xml

  Font: Helvetica
    family: Helvetica
    style: Normal
    stretch: Normal
    weight: 400
    glyphs: /nonexistent/fonts/default/ghostscript/n019003l.pfb

  Font: Real-Font
    family: Real
    style: Normal
    stretch: Normal
    weight: 400
    glyphs: /bin/sh

  Font: No-Glyphs
    family: Nothing
    style: Normal
  """

  test "only the font whose glyphs file exists is kept" do
    assert AnnotationThumbnail.installed_from_listing(@listing) == [{"Real-Font", "/bin/sh"}]
  end

  test "an empty listing has no fonts" do
    assert AnnotationThumbnail.installed_from_listing("") == []
  end
end
