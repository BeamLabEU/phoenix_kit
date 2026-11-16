defmodule PhoenixKitWeb.Components.ImageSetCoverTest do
  # `image_set` in a cropped tile: `sizes` describes the slot's width, so a
  # wide picture scaled to cover a square or portrait box needs a variant
  # chosen by the box's height. Pre-loaded variants, no database.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Shared.Components.ImageSet
  alias PhoenixKitWeb.Components.MediaGallery

  doctest MediaGallery, only: [thumb_sizes: 1]

  # 16:9 picture: small, medium, large and the original, in JPEG and WebP
  defp landscape do
    for {name, w, h} <- [
          {"small", 300, 169},
          {"medium", 600, 338},
          {"large", 1440, 810},
          {"original", 1920, 1080}
        ],
        {suffix, mime} <- [{"", "image/jpeg"}, {"_webp", "image/webp"}] do
      %{
        variant_name: name <> suffix,
        mime_type: mime,
        width: w,
        height: h,
        url: "/f/#{name}#{suffix}"
      }
    end
  end

  # 4:5 portrait picture
  defp portrait do
    for {name, w, h} <- [{"small", 300, 375}, {"medium", 600, 750}, {"original", 1200, 1500}] do
      %{variant_name: name, mime_type: "image/jpeg", width: w, height: h, url: "/p/#{name}"}
    end
  end

  defp render(variants, extra) do
    render_component(
      &ImageSet.image_set/1,
      Map.merge(
        %{file_uuid: "00000000-0000-0000-0000-000000000001", variants: variants, alt: ""},
        extra
      )
    )
  end

  defp srcset(html, tag) do
    [_, value] = Regex.run(~r/<#{tag}[^>]*\ssrcset="([^"]*)"/, html)
    value
  end

  test "without fit, srcset is the files' own widths (unchanged)" do
    html = render(landscape(), %{sizes: "160px"})

    assert srcset(html, "img") ==
             "/f/small 300w, /f/medium 600w, /f/large 1440w, /f/original 1920w"
  end

  test "a wide picture in a square box advertises the width each variant can cover" do
    html = render(landscape(), %{sizes: "160px", fit: "cover", box_aspect: 1})

    # a 16:9 variant covers a square as wide as it is tall
    assert srcset(html, "img") ==
             "/f/small 169w, /f/medium 338w, /f/large 810w, /f/original 1080w"

    assert srcset(html, "source") =~ "/f/small_webp 169w"
  end

  test "the report's case: a 16:9 picture in a 445 × 556 tile is never stretched" do
    html = render(landscape(), %{sizes: "445px", fit: "cover", box_aspect: "445/556"})

    # the tile is 556 px tall: the 600-px variant (338 tall) can cover only a
    # 270-px-wide tile, so at 445 px the browser takes the 1440 one (810 tall)
    [medium] = Regex.run(~r{/f/medium (\d+)w}, srcset(html, "img"), capture: :all_but_first)
    assert String.to_integer(medium) < 445
    assert srcset(html, "img") =~ "/f/large 648w"
  end

  test "widths round down, and of two files covering the same box the smaller is kept" do
    odd = [
      %{variant_name: "small", mime_type: "image/jpeg", width: 200, height: 101, url: "/o/s"}
    ]

    # 101 × 0.5 = 50.5: the file covers a 50-px-wide box, not 51
    assert srcset(render(odd, %{fit: "cover", box_aspect: 0.5}), "img") == "/o/s 50w"

    same_height =
      for {name, w} <- [{"wide", 2560}, {"original", 1920}] do
        %{variant_name: name, mime_type: "image/jpeg", width: w, height: 1080, url: "/h/#{name}"}
      end

    assert srcset(render(same_height, %{fit: "cover", box_aspect: 1}), "img") ==
             "/h/original 1080w"
  end

  test "a portrait picture in a square box keeps its own widths" do
    html = render(portrait(), %{sizes: "160px", fit: "cover", box_aspect: 1})
    assert srcset(html, "img") == "/p/small 300w, /p/medium 600w, /p/original 1200w"
  end

  test "a variant without a height, or an unusable box_aspect, falls back to its width" do
    no_height = [
      %{variant_name: "small", mime_type: "image/jpeg", width: 300, height: nil, url: "/n/s"}
    ]

    assert srcset(render(no_height, %{fit: "cover"}), "img") == "/n/s 300w"

    for bad <- ["wide", "4/0", -1, 0, 1.0e308, 0.001] do
      html = render(landscape(), %{fit: "cover", box_aspect: bad})
      assert srcset(html, "img") =~ "/f/medium 600w", inspect(bad)
    end
  end

  test "sizes from the gallery's cols: integer, responsive classes, junk" do
    assert MediaGallery.thumb_sizes(6) == "calc(100vw / 6)"

    assert MediaGallery.thumb_sizes("grid-cols-4 lg:grid-cols-6 2xl:grid-cols-8") ==
             "(min-width: 1536px) calc(100vw / 8), (min-width: 1024px) calc(100vw / 6), calc(100vw / 4)"

    assert MediaGallery.thumb_sizes("md:grid-cols-3") ==
             "(min-width: 768px) calc(100vw / 3), calc(100vw / 1)"

    assert MediaGallery.thumb_sizes("flex gap-2") == "100vw"
    assert MediaGallery.thumb_sizes(nil) == "calc(100vw / 4)"
  end
end
