defmodule PhoenixKit.Modules.Storage.AnnotationThumbnailFontTest do
  @moduledoc """
  A text or callout annotation is drawn by ImageMagick `-draw "text …"`, which
  needs a font. Without a `-font` it asks for its default (Helvetica), which a
  host without ghostscript fonts cannot read: `convert` exits 1 and the
  annotated thumbnail is never baked.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.TestSupport.LinkCopyHelpers

  alias PhoenixKit.Annotations
  alias PhoenixKit.Modules.Storage.AnnotationThumbnail
  alias PhoenixKit.Settings

  @moduletag :tmp_dir

  @key "storage_annotated_thumbnails_enabled"

  unless imagemagick?(),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  # Text can only be drawn with a font that is installed.
  if imagemagick?() and AnnotationThumbnail.font_args(["-draw", "text 0,0 'x'"]) == [],
    do: @moduletag(skip: "ImageMagick has no installed font")

  setup %{tmp_dir: tmp} do
    if imagemagick?() do
      env = setup_storage(tmp)
      owner = user!("owner", env.n)
      file = upload!(owner, image!(tmp, "photo.jpg"))

      {:ok, _} = Settings.update_boolean_setting(@key, true)
      on_exit(fn -> PhoenixKit.Cache.invalidate(:settings, @key) end)

      Map.merge(env, %{photo: file})
    else
      {:ok, skip: true}
    end
  end

  test "a text label is baked into the annotated thumbnail", %{photo: file} do
    {:ok, _} =
      Annotations.create(%{
        file_uuid: file.uuid,
        kind: "text",
        title: "North wall",
        geometry: %{"x" => 100, "y" => 100, "w" => 400, "h" => 80},
        style: %{"color" => "#112233"}
      })

    assert {:ok, _instance} = AnnotationThumbnail.refresh(file.uuid)
    assert instance(file, "thumbnail_annotated")
  end

  test "a callout with words is baked too", %{photo: file} do
    {:ok, _} =
      Annotations.create(%{
        file_uuid: file.uuid,
        kind: "callout",
        title: "Crack here",
        geometry: %{
          "anchor" => %{"x" => 50, "y" => 50},
          "text_box" => %{"x" => 200, "y" => 200, "w" => 400, "h" => 80}
        }
      })

    assert {:ok, _instance} = AnnotationThumbnail.refresh(file.uuid)
    assert instance(file, "thumbnail_annotated")
  end
end
