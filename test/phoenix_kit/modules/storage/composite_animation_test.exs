defmodule PhoenixKit.Modules.Storage.CompositeAnimationTest do
  @moduledoc """
  `ImageProcessor.composite_animation/5` — the markup of a burned animated GIF
  drawn onto every frame, the picture set at its place in a canvas that may be
  bigger than it (ink drawn past its edges) or smaller (a picture cropped by
  it). Skipped where ImageMagick is not installed.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.ImageProcessor

  @moduletag :tmp_dir

  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  # 120x60 white, a 20 px red square that moves right in three frames.
  defp animation(ctx, frames \\ 3) do
    path = Path.join(ctx.tmp_dir, "anim.gif")

    frame_args =
      for i <- 0..(frames - 1) do
        ["(", "-size", "120x60", "xc:white", "-fill", "red"] ++
          ["-draw", "rectangle #{i * 30},20 #{i * 30 + 19},39", "-set", "delay", "10", ")"]
      end

    run!(List.flatten(frame_args) ++ ["-loop", "0", "-layers", "optimize", path])
    path
  end

  # A see-through canvas with a blue 10 px square in its top-left corner.
  defp overlay(ctx, w, h) do
    path = Path.join(ctx.tmp_dir, "overlay.png")
    run!(~w[-size #{w}x#{h} xc:none -fill blue -draw] ++ ["rectangle 0,0 9,9", "png:#{path}"])
    path
  end

  defp run!(args) do
    {_, 0} = System.cmd("convert", args, stderr_to_stdout: true)
  end

  defp layout(canvas_w, canvas_h, x, y, w \\ 120, h \\ 60),
    do: %{canvas_w: canvas_w, canvas_h: canvas_h, x: x, y: y, w: w, h: h}

  # The canvas (page) size: an optimised GIF frame stores only what changed, so
  # a frame's own width and height say little.
  defp size(path, frame) do
    {out, 0} = System.cmd("identify", ["-format", "%Wx%H", "#{path}[#{frame}]"])
    out
  end

  defp frames(path) do
    {out, 0} = System.cmd("identify", ["-format", "%n\n", path])
    out |> String.split("\n", trim: true) |> hd() |> String.to_integer()
  end

  # {r, g, b, alpha} of one pixel of one frame, 0..255 (alpha 255 = opaque).
  # The frames are put on the full canvas first, as a player does: a frame read
  # alone from an optimised GIF is only the part that changed.
  defp pixel(path, frame, x, y) do
    channels = for c <- ~w(r g b a), do: "%[fx:round(255*p{#{x},#{y}}.#{c})]"

    {out, 0} =
      System.cmd("convert", [
        path,
        "-coalesce",
        # IM7 reads `.a` as zero when an opaque PNG has no alpha channel.
        # Enable it before measuring, preserving any existing transparency.
        "-alpha",
        "on",
        "-format",
        Enum.join(channels, ",") <> "\n",
        "info:"
      ])

    out
    |> String.split("\n", trim: true)
    |> Enum.at(frame)
    |> String.split(",")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  test "every frame keeps playing, with the markup on it and the margin see-through", ctx do
    source = animation(ctx)
    out = Path.join(ctx.tmp_dir, "out.gif")

    # The picture sits 20 px in and 10 px down in a 160x100 canvas.
    assert {:ok, ^out} =
             ImageProcessor.composite_animation(
               source,
               overlay(ctx, 160, 100),
               out,
               layout(160, 100, 20, 10)
             )

    assert frames(out) == 3
    assert size(out, 0) == "160x100"

    for i <- 0..2 do
      # The blue square, drawn into the margin.
      assert {0, 0, 255, 255} = pixel(out, i, 5, 5)
      # The far corner of the margin was never drawn on.
      assert {_, _, _, 0} = pixel(out, i, 155, 95)
      # The picture's own white.
      assert {255, 255, 255, 255} = pixel(out, i, 20 + 115, 10 + 5)
    end

    # The red square moves with the frames: picture x = i * 30 + 10, canvas +20.
    assert {255, 0, 0, 255} = pixel(out, 0, 20 + 10, 10 + 30)
    assert {255, 255, 255, 255} = pixel(out, 0, 20 + 40, 10 + 30)
    assert {255, 0, 0, 255} = pixel(out, 1, 20 + 40, 10 + 30)
  end

  test "a negative offset shifts the picture left and up, cropping what leaves the canvas",
       ctx do
    source = animation(ctx)
    out = Path.join(ctx.tmp_dir, "cropped.gif")

    assert {:ok, _} =
             ImageProcessor.composite_animation(
               source,
               overlay(ctx, 100, 50),
               out,
               layout(100, 50, -10, -5)
             )

    assert size(out, 0) == "100x50"
    # Frame 0's square spans picture x 0..19, y 20..39: canvas x -10..9, y 15..34.
    assert {255, 0, 0, 255} = pixel(out, 0, 5, 20)
    assert {255, 255, 255, 255} = pixel(out, 0, 15, 20)
  end

  test "the picture is scaled to its box, not drawn at its own size", ctx do
    source = animation(ctx)
    out = Path.join(ctx.tmp_dir, "scaled.gif")

    assert {:ok, _} =
             ImageProcessor.composite_animation(
               source,
               overlay(ctx, 60, 30),
               out,
               layout(60, 30, 0, 0, 60, 30)
             )

    assert size(out, 0) == "60x30"
    assert frames(out) == 3
  end

  test "still: true keeps the first frame alone, as a PNG", ctx do
    source = animation(ctx)
    out = Path.join(ctx.tmp_dir, "still.png")

    assert {:ok, ^out} =
             ImageProcessor.composite_animation(
               source,
               overlay(ctx, 120, 60),
               out,
               layout(120, 60, 0, 0),
               still: true
             )

    assert frames(out) == 1
    assert {0, 0, 255, 255} = pixel(out, 0, 5, 5)
    # Frame 0's red square, not a later frame's.
    assert {255, 0, 0, 255} = pixel(out, 0, 10, 30)
    assert {255, 255, 255, 255} = pixel(out, 0, 40, 30)
  end

  test "an animation with too many frames is refused, and the still fallback works", ctx do
    long = Path.join(ctx.tmp_dir, "long.gif")
    run!(~w[-size 8x8 xc:white -duplicate 300 -set delay 1 -loop 0] ++ [long])
    assert frames(long) > ImageProcessor.animation_limits().frames

    out = Path.join(ctx.tmp_dir, "long_out.gif")

    assert {:error, :too_large} =
             ImageProcessor.composite_animation(
               long,
               overlay(ctx, 8, 8),
               out,
               layout(8, 8, 0, 0, 8, 8)
             )

    refute File.exists?(out)

    still = Path.join(ctx.tmp_dir, "long_still.png")

    assert {:ok, ^still} =
             ImageProcessor.composite_animation(
               long,
               overlay(ctx, 8, 8),
               still,
               layout(8, 8, 0, 0, 8, 8),
               still: true
             )
  end

  test "a picture box the client claims far past any budget is refused before ImageMagick", ctx do
    source = animation(ctx)
    out = Path.join(ctx.tmp_dir, "huge.gif")

    # A one-pixel canvas and a 32-million-pixel-wide picture: what a forged
    # layout scales to when the overlay it came with is real.
    assert {:error, "image is too large"} =
             ImageProcessor.composite_animation(
               source,
               overlay(ctx, 120, 60),
               out,
               layout(120, 60, 0, 0, 32_000_000, 320_000)
             )

    refute File.exists?(out)
  end

  test "the frame budget includes the resized picture before cropping to a small canvas", ctx do
    source = animation(ctx)
    out = Path.join(ctx.tmp_dir, "resized_budget.gif")

    # Each resized frame fits the 100 MP per-image limit; three of them exceed
    # the animation limit, even though the final canvas is just 120x60.
    assert {:error, :too_large} =
             ImageProcessor.composite_animation(
               source,
               overlay(ctx, 120, 60),
               out,
               layout(120, 60, 0, 0, 8_000, 8_000)
             )

    refute File.exists?(out)
  end

  test "the frame budget includes the source canvas before coalescing and shrinking", ctx do
    source = animation(ctx) |> set_canvas(8_000, 8_000)
    out = Path.join(ctx.tmp_dir, "source_budget.gif")
    assert {:ok, {8_000, 8_000}} = ImageProcessor.extract_dimensions(source)

    assert {:error, :too_large} =
             ImageProcessor.composite_animation(
               source,
               overlay(ctx, 120, 60),
               out,
               layout(120, 60, 0, 0)
             )

    refute File.exists?(out)
  end

  test "an oversized source canvas is refused even for the still fallback", ctx do
    source = animation(ctx) |> set_canvas(12_000, 12_000)
    out = Path.join(ctx.tmp_dir, "source_too_large.png")

    assert {:error, "image is too large"} =
             ImageProcessor.composite_animation(
               source,
               overlay(ctx, 120, 60),
               out,
               layout(120, 60, 0, 0),
               still: true
             )

    refute File.exists?(out)
  end

  # GIF's logical screen can be huge while every encoded patch is tiny.
  # Change the header only, so fixtures never allocate the claimed canvas.
  defp set_canvas(path, width, height) do
    <<header::binary-size(6), _old_size::binary-size(4), rest::binary>> = File.read!(path)
    File.write!(path, <<header::binary, width::little-16, height::little-16, rest::binary>>)
    path
  end
end
