defmodule PhoenixKitWeb.Components.Core.ResizableModalTest do
  @moduledoc """
  Render tests for `<.resizable_modal>`: the same dialog as `<.modal>` with
  a box the `PkResizable` hook resizes by eight grips.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.ResizableModal, only: [resizable_modal: 1]

  defp grips(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-pk-resize]") |> LazyHTML.attribute("data-pk-resize")
  end

  test "renders the dialog with the PkDialog hook and a box with the PkResizable hook" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.resizable_modal id="compose" show={true} on_close="close">
        <:title>New message</:title>
        body
        <:actions><button>Send</button></:actions>
      </.resizable_modal>
      """)

    doc = LazyHTML.from_fragment(html)

    assert LazyHTML.attribute(LazyHTML.query(doc, "dialog#compose"), "phx-hook") == ["PkDialog"]
    assert LazyHTML.attribute(LazyHTML.query(doc, "dialog#compose"), "data-close-event") == ["close"]

    box = LazyHTML.query(doc, "#compose-box.modal-box")
    assert LazyHTML.attribute(box, "phx-hook") == ["PkResizable"]
    assert LazyHTML.attribute(box, "data-size-key") == ["compose"]
    assert LazyHTML.attribute(box, "data-min-width") == ["320"]
    assert LazyHTML.attribute(box, "data-min-height") == ["240"]

    assert Enum.sort(grips(html)) == ~w(e n ne nw s se sw w)
    assert html =~ "compose-title"
    assert html =~ "modal-action"
  end

  test "never renders the open attribute, and nothing while hidden" do
    assigns = %{}

    shown =
      rendered_to_string(~H"""
      <.resizable_modal id="m" show={true} on_close="close">body</.resizable_modal>
      """)

    refute shown =~ ~r/<dialog[^>]*\sopen/

    hidden =
      rendered_to_string(~H"""
      <.resizable_modal id="m" show={false} on_close="close">body</.resizable_modal>
      """)

    refute hidden =~ "<dialog"
  end

  test "keep_in_dom renders the hidden dialog for the hook to open" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.resizable_modal id="m" show={false} on_close="close" keep_in_dom>body</.resizable_modal>
      """)

    assert html =~ ~s(data-show="false")
    assert grips(html) != []
  end

  test "height, the minimums and the initial width are the caller's" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.resizable_modal
        id="m"
        show={true}
        on_close="close"
        max_width="4xl"
        height="70vh"
        min_width={480}
        min_height={300}
      >
        body
      </.resizable_modal>
      """)

    assert html =~ "max-w-4xl"
    assert html =~ "height: 70vh"
    assert html =~ ~s(data-min-width="480")
    assert html =~ ~s(data-min-height="300")
  end

  test "the box fills a phone's screen unless the caller turns that off" do
    assigns = %{}

    full =
      rendered_to_string(~H"""
      <.resizable_modal id="m" show={true} on_close="close">body</.resizable_modal>
      """)

    assert full =~ "max-sm:h-full"

    boxed =
      rendered_to_string(~H"""
      <.resizable_modal id="m" show={true} on_close="close" fullscreen_on_mobile={false}>
        body
      </.resizable_modal>
      """)

    refute boxed =~ "max-sm:h-full"
  end
end
