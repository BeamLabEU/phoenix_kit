defmodule PhoenixKitWeb.Components.MediaCanvasViewerCspTest do
  @moduledoc """
  The media viewer under a nonce-based Content-Security-Policy: its
  `<Fresco.canvas>` gets the host's style nonce (`style_nonce`, Fresco
  0.17.1), so the canvas's inline styles go out as `data-fresco-style`, which
  such a policy does not block, and its `<style>` carries the nonce. With no
  nonce configured the markup is what it was.

  `async: false`: `csp_nonce_assign_key` is application env.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import PhoenixKitWeb.MediaCanvasViewerFixtures

  alias PhoenixKitWeb.CSP

  setup do
    previous = Application.get_env(:phoenix_kit, :csp_nonce_assign_key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :csp_nonce_assign_key, previous),
        else: Application.delete_env(:phoenix_kit, :csp_nonce_assign_key)
    end)

    Application.delete_env(:phoenix_kit, :csp_nonce_assign_key)
    CSP.put_nonces(build_conn())
    :ok
  end

  defp canvas_tag(html) do
    [tag] = Regex.run(~r/<div[^>]*phx-hook="FrescoCanvas".*?data-fresco-stage[^>]*>/s, html)
    tag
  end

  test "no nonce configured: the canvas keeps its inline styles" do
    html = render_html(%{burn_canvas: nil, burn_version: nil})

    refute html =~ "data-fresco-style"
    assert canvas_tag(html) =~ ~r/data-fresco-stage[^>]*\sstyle="/
  end

  test "a style nonce reaches the canvas: no style attribute, its <style> nonced" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, %{
      script: :script_nonce,
      style: :style_nonce
    })

    build_conn()
    |> Plug.Conn.assign(:script_nonce, "SCR")
    |> Plug.Conn.assign(:style_nonce, "STY")
    |> CSP.put_nonces()

    html = render_html(%{burn_canvas: nil, burn_version: nil})
    tag = canvas_tag(html)

    assert tag =~ ~r/data-fresco-stage[^>]*\sdata-fresco-style="/
    refute tag =~ ~r/data-fresco-stage[^>]*\sstyle="/
    refute html =~ ~r/<img[^>]*data-fresco-canvas-img[^>]*\sstyle="/

    assert html =~ ~s(<style nonce="STY">)

    board_html =
      render_html(%{
        file: nil,
        board: %{target_uuid: file_uuid()},
        viewer_canvas: Fresco.Canvas.new(width: 800, height: 600, background: "#ffffff")
      })

    assert canvas_tag(board_html) =~ ~r/data-fresco-stage[^>]*\sdata-fresco-style="/
  end
end
