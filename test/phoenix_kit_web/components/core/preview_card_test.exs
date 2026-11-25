defmodule PreviewCardTestImage do
  @moduledoc false
  defstruct [:uuid, :name]
end

defmodule PhoenixKitWeb.Components.Core.PreviewCardTest do
  @moduledoc """
  Render-shape tests for `preview_card/1` and `preview_card_body/1`,
  ported from the catalogue's `product_card_test.exs` (the render this
  module moved out of core). Resolution helpers (`resolve_images/1` and
  friends) stay in the catalogue — this module is render-only, so its
  tests are render-only too.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias PhoenixKitWeb.Components.Core.PreviewCard

  defp images do
    [
      %{uuid: "img-1", name: "front.jpg"},
      %{uuid: "img-2", name: "back.jpg"},
      %{uuid: "img-3", name: nil}
    ]
  end

  defp files do
    [
      %{uuid: "pdf-1", name: "spec-sheet.pdf", size: 120_000, pdf?: true},
      %{uuid: "doc-1", name: "notes.txt", size: 900, pdf?: false}
    ]
  end

  defp base_assigns(overrides) do
    Map.merge(
      %{
        id: "pc",
        show: true,
        target: nil,
        title: "Oak Panel",
        images: images(),
        fields: [],
        files: []
      },
      overrides
    )
  end

  defp render_card(overrides \\ %{}) do
    render_component(&PreviewCard.preview_card/1, base_assigns(overrides))
  end

  describe "carousel" do
    test "renders every image as a slide (medium variant) and the title" do
      html = render_card()

      assert html =~ "Oak Panel"
      assert html =~ "carousel-item"
      for uuid <- ["img-1", "img-2", "img-3"], do: assert(html =~ uuid)
      assert html =~ "medium"
    end

    test "the first image slide is eager, the rest lazy" do
      html = render_card()

      [_before, after_first] = String.split(html, "img-1", parts: 2)
      assert after_first =~ ~s[loading="eager"]

      [_before, after_second] = String.split(html, "img-2", parts: 2)
      assert after_second =~ ~s[loading="lazy"]
    end

    test "slides are switched client-side: jump strip + arrows, no server events" do
      html = render_card()

      assert html =~ "data-pc-track"
      assert html =~ ~s(data-pc-jump="1")
      assert html =~ ~s(data-pc-step="-1")
      assert html =~ ~s(data-pc-step="1")
      # phoenix_kit.js does the switching; nothing inline (a strict CSP blocks it)
      refute html =~ "onclick"
      refute html =~ "onscroll"
      assert html =~ "Previous"
      assert html =~ "Next"
      refute html =~ "card_select_image"
    end

    test "a single image renders no strip and no arrows (nothing to switch to)" do
      html = render_card(%{images: [%{uuid: "only", name: "x.jpg"}]})

      assert html =~ "only"
      refute html =~ "data-pc-jump"
      refute html =~ "data-pc-step"
    end

    test "files continue the same swipe track after the photos, PDF iframe hidden below sm" do
      html = render_card(%{files: files()})

      assert html =~ "<iframe"
      assert html =~ ~s(class="w-full h-[50vh] hidden sm:block")
      assert html =~ "notes.txt"
      assert html =~ "pdf"
      assert html =~ "txt"
    end

    test "no media at all renders the placeholder, not a collapsed card" do
      html = render_card(%{images: [], files: []})

      assert html =~ "hero-photo"
      assert html =~ "No images"
    end

    test "one image renders no placeholder" do
      refute render_card(%{images: [%{uuid: "only", name: "x.jpg"}]}) =~ "No images"
    end
  end

  describe "images given by URL (:src)" do
    test "a :src image renders from that URL, not from a signed Storage path" do
      html =
        render_card(%{
          images: [%{src: "https://example.com/page-1-large.png", name: "Page 1"}]
        })

      assert html =~ ~s(src="https://example.com/page-1-large.png")
      assert html =~ ~s(alt="Page 1")
      refute html =~ "/file/"
    end

    test "the jump strip uses :thumb_src when given, else the :src itself" do
      html =
        render_card(%{
          images: [
            %{
              src: "https://example.com/a-large.png",
              thumb_src: "https://example.com/a-small.png"
            },
            %{src: "https://example.com/b-large.png", name: nil}
          ]
        })

      [_slides, strip] = String.split(html, "data-pc-strip>", parts: 2)
      assert strip =~ ~s(src="https://example.com/a-small.png")
      assert strip =~ ~s(src="https://example.com/b-large.png")
      refute strip =~ "a-large.png"
    end

    test "Storage images and URL images mix in one carousel" do
      html =
        render_card(%{images: [%{uuid: "img-1", name: "front.jpg"}, %{src: "/doc/thumb.png"}]})

      assert html =~ "img-1"
      assert html =~ ~s(src="/doc/thumb.png")
    end

    test "an image entry may be a struct (no Access), and :name is optional" do
      html = render_card(%{images: [%{src: "/p.png"}]})
      assert html =~ ~s(src="/p.png")
      assert html =~ ~s(alt="Oak Panel")

      html = render_card(%{images: [%PreviewCardTestImage{uuid: "img-9", name: "s.jpg"}]})
      assert html =~ "img-9"
      assert html =~ ~s(alt="s.jpg")
    end

    test "image_url/2 picks :src / :thumb_src, else signs the Storage variant" do
      assert PreviewCard.image_url(%{src: "https://x/l.png"}, "medium") == "https://x/l.png"

      assert PreviewCard.image_url(
               %{src: "https://x/l.png", thumb_src: "https://x/s.png"},
               "thumbnail"
             ) ==
               "https://x/s.png"

      assert PreviewCard.image_url(%{src: "https://x/l.png"}, "thumbnail") == "https://x/l.png"
      assert PreviewCard.image_url(%{uuid: "img-1"}, "medium") =~ "img-1"
      assert PreviewCard.image_url(%{uuid: "img-1"}, "medium") =~ "medium"
    end
  end

  describe "fields" do
    test "renders the provided filled fields" do
      html = render_card(%{fields: [{"SKU", "KF-001"}, {"Price", "42.50"}]})

      assert html =~ "SKU"
      assert html =~ "KF-001"
      assert html =~ "Price"
      assert html =~ "42.50"
    end

    test "renders no field list when there are no fields" do
      refute render_card(%{fields: []}) =~ "<dl"
    end
  end

  describe "title fallback" do
    test "falls back to gettext Preview when no title is given" do
      html = render_card(%{title: nil})
      assert html =~ "Preview"
    end
  end

  describe "show=false" do
    test "renders nothing when closed" do
      refute render_card(%{show: false}) =~ "Oak Panel"
    end
  end

  describe "extra_actions slot" do
    test "renders extra_actions content before the Close button" do
      assigns = base_assigns(%{})

      html =
        rendered_to_string(~H"""
        <PreviewCard.preview_card id={@id} show={@show} target={@target} title={@title} images={@images}>
          <:extra_actions>
            <button type="button" class="btn btn-primary" id="add-to-cart">Add</button>
          </:extra_actions>
        </PreviewCard.preview_card>
        """)

      assert html =~ "add-to-cart"
      assert html =~ "Add"
    end
  end

  describe "close button" do
    test "the default on_close is preview_card_close, pushed to the target" do
      html = render_card(%{target: "my-target"})

      assert html =~ ~s(phx-click="preview_card_close")
      assert html =~ ~s(phx-target="my-target")
    end

    test "a custom on_close event name is honoured" do
      html = render_card(%{on_close: "close_sub_order_card"})

      assert html =~ ~s(phx-click="close_sub_order_card")
    end
  end

  describe "files list" do
    test "lists files with size and an Open link, no server events" do
      html = render_card(%{files: files()})

      assert html =~ "spec-sheet.pdf"
      assert html =~ "notes.txt"
      assert html =~ "120.0 KB"
      assert html =~ ~s(target="_blank")
      refute html =~ "card_view_file"
    end

    test "no files renders no Files heading" do
      refute render_card() =~ ">Files<"
    end
  end

  describe "preview_card_body/1 (notpopup form)" do
    test "renders the same content without the modal shell" do
      html =
        render_component(
          &PreviewCard.preview_card_body/1,
          base_assigns(%{files: files()}) |> Map.drop([:id, :show, :target])
        )

      assert html =~ "img-1"
      assert html =~ "spec-sheet.pdf"
      assert html =~ "carousel"
      refute html =~ "<dialog"
    end
  end
end
