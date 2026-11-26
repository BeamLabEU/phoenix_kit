defmodule PhoenixKitWeb.Components.Core.PhotoGalleryTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.PhotoGallery

  alias PhoenixKitWeb.Components.Core.PhotoGallery

  defp render(template), do: rendered_to_string(template)

  @uuid "019a0000-0000-7000-8000-000000000001"

  defp variants do
    [
      %{
        variant_name: "original",
        mime_type: "image/jpeg",
        width: 3000,
        height: 2000,
        url: "/f/o"
      },
      %{variant_name: "medium", mime_type: "image/jpeg", width: 800, height: 533, url: "/f/m"},
      %{
        variant_name: "medium_webp",
        mime_type: "image/webp",
        width: 800,
        height: 533,
        url: "/f/mw"
      }
    ]
  end

  test "plain URLs: a thumbnail per photo opening the lightbox on it" do
    assigns = %{
      photos: [
        %{src: "/a.jpg", thumb: "/a_t.jpg", alt: "Harbour", caption: "Tallinn harbour"},
        %{"src" => "/b.jpg", "srcset" => "/b_800.jpg 800w, /b.jpg 2000w", "alt" => "Old town"},
        "/c.jpg"
      ]
    }

    html = render(~H|<.photo_gallery id="trip" photos={@photos} />|)

    assert html =~ ~s(id="trip")
    assert html =~ ~s(data-pk-gallery-root)
    assert html =~ ~s(data-pk-gallery-open="0")
    assert html =~ ~s(data-pk-gallery-open="2")
    assert html =~ ~s(src="/a_t.jpg")
    assert html =~ ~s(aria-label="Open photo 1 of 3: Harbour")
    assert html =~ ~s(aria-controls="trip-dialog")

    # The lightbox
    assert html =~ ~s(<dialog id="trip-dialog")
    assert html =~ ~s(aria-label="Photo gallery")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(src="/a.jpg")
    assert html =~ ~s(srcset="/b_800.jpg 800w, /b.jpg 2000w")
    assert html =~ ~s(sizes="100vw")
    assert html =~ ~s(src="/c.jpg")
    assert html =~ "Tallinn harbour"
    assert html =~ ~s(aria-label="Photo 2 of 3")
    assert html =~ ~s(data-template="{n} / {count}")
    assert html =~ "1 / 3"
    assert html =~ ~s(data-pk-gallery-prev)
    assert html =~ ~s(data-pk-gallery-next)
    assert html =~ ~s(aria-live="polite")

    # Only the first slide is live; the rest are inert until shown.
    [_, first | rest] = String.split(html, "data-pk-gallery-slide=")
    refute first =~ ~r/^"0"[^>]*inert/
    assert Enum.all?(rest, &(&1 =~ ~r/^"\d"[^>]*inert/))
  end

  test "storage files render their variants as a srcset, original as the download" do
    assigns = %{photos: [%{file_uuid: @uuid, variants: variants(), alt: "A bike"}]}

    html =
      render(~H"""
      <.photo_gallery id="bike" photos={@photos}>
        <:actions :let={photo}>
          <a href={photo.download} download data-test-download>Download</a>
        </:actions>
      </.photo_gallery>
      """)

    assert html =~ ~s(type="image/webp")
    assert html =~ "/f/mw 800w"
    assert html =~ ~s(href="/f/o")
    assert html =~ ~s(alt="A bike")
    # One photo: no arrows, no counter.
    refute html =~ "data-pk-gallery-prev"
    refute html =~ "data-pk-gallery-counter"
  end

  test "the actions and caption slots are rendered per photo, all but the first hidden" do
    assigns = %{photos: ["/a.jpg", "/b.jpg"]}

    html =
      render(~H"""
      <.photo_gallery id="g" photos={@photos} thumbnails={false} label="Listing photos">
        <:actions :let={photo}>
          <button type="button" phx-click="report" phx-value-index={photo.index}>Report</button>
        </:actions>
        <:caption :let={photo}><em>Shot {photo.index + 1}: {photo.item}</em></:caption>
      </.photo_gallery>
      """)

    refute html =~ "data-pk-gallery-open"
    assert html =~ ~s(aria-label="Listing photos")
    assert html =~ ~s(phx-value-index="0")
    assert html =~ ~s(phx-value-index="1")
    assert html =~ "<em>Shot 2: /b.jpg</em>"
    assert html =~ ~r/data-pk-gallery-actions="1"[^>]*hidden/
    refute html =~ ~r/data-pk-gallery-actions="0"[^>]*hidden/
    assert html =~ ~r/data-pk-gallery-caption="1"[^>]*hidden/
  end

  test "the stage id follows the photos, so new photos re-render the ignored region" do
    a = PhotoGallery.normalize(["/a.jpg"])
    b = PhotoGallery.normalize(["/b.jpg"])

    stage = fn photos ->
      assigns = %{photos: photos}
      html = render(~H|<.photo_gallery id="g" photos={@photos} />|)
      [_, id] = Regex.run(~r/id="(g-stage-[^"]+)"/, html)
      id
    end

    assert stage.(["/a.jpg"]) == stage.(["/a.jpg"])
    refute stage.(["/a.jpg"]) == stage.(["/b.jpg"])
    assert [%{src: "/a.jpg", index: 0}] = a
    assert [%{src: "/b.jpg"}] = b
  end

  test "normalize drops what is neither a file nor a URL and keeps the order" do
    photos =
      PhotoGallery.normalize([
        nil,
        %{},
        %{src: ""},
        %{file_uuid: @uuid, variants: variants(), alt: ""},
        "/x.jpg"
      ])

    assert [%{file_uuid: @uuid, index: 0, src: "/f/o", item: %{}}, %{src: "/x.jpg", index: 1}] =
             photos

    assert PhotoGallery.normalize(:nope) == []
  end

  test "open/3 dispatches the open event at the gallery" do
    js = PhotoGallery.open("trip", 2)

    assert [["dispatch", %{event: "pk:photo-gallery-open", to: "#trip", detail: %{index: 2}}]] =
             js.ops

    chained = "x" |> Phoenix.LiveView.JS.push() |> PhotoGallery.open("trip", 0)
    assert [["push", _], ["dispatch", %{detail: %{index: 0}}]] = chained.ops
    assert [["dispatch", %{detail: %{index: 0}}]] = PhotoGallery.open("trip").ops
  end

  test "an empty gallery renders no grid" do
    assigns = %{}
    html = render(~H|<.photo_gallery id="none" photos={[]} />|)
    refute html =~ "<ul"
  end
end
