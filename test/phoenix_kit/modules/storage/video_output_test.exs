defmodule PhoenixKit.Modules.Storage.VideoOutputTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{Dimension, VariantGenerator}

  @moduletag :tmp_dir

  unless System.find_executable("ffmpeg") && System.find_executable("ffprobe"),
    do: @moduletag(skip: "FFmpeg and ffprobe are not installed")

  setup %{tmp_dir: dir} do
    input = Path.join(dir, "input.mp4")

    {log, status} =
      System.cmd(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "testsrc2=size=320x240:rate=10",
          "-t",
          "2",
          "-c:v",
          "libx264",
          "-threads",
          "1",
          "-y",
          input
        ],
        stderr_to_stdout: true
      )

    assert status == 0, log
    %{input: input}
  end

  defp render!(ctx, attrs) do
    dimension =
      Dimension.new(
        Map.merge(
          %{
            name: "clip",
            applies_to: "video",
            quality: 25,
            format: "mp4",
            width: 160,
            maintain_aspect_ratio: true
          },
          Map.new(attrs)
        )
      )

    output = Path.join(ctx.tmp_dir, "output.#{dimension.format || "mp4"}")
    args = VariantGenerator.ffmpeg_args(ctx.input, output, dimension)
    # Bound native threads so several ExUnit cases fit on a shared server.
    args = Enum.drop(args, -1) ++ ["-filter_threads", "1", "-threads", "1", output]

    {log, status} =
      System.cmd("ffmpeg", ["-hide_banner", "-loglevel", "error"] ++ args, stderr_to_stdout: true)

    assert status == 0, log

    {json, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=codec_name,width,height",
        "-of",
        "json",
        output
      ])

    [stream] = Jason.decode!(json)["streams"]
    stream
  end

  test "a video fits its box without stretching or enlargement", ctx do
    stream = render!(ctx, maintain_aspect_ratio: false, width: 160, height: 90)
    assert {stream["width"], stream["height"]} == {120, 90}
    assert stream["codec_name"] == "h264"
  end

  test "a height-fixed video and poster follow their height", ctx do
    for format <- ["mp4", "jpg"] do
      stream = render!(ctx, fit_by: "height", width: nil, height: 120, format: format)
      assert {stream["width"], stream["height"]} == {160, 120}
    end

    stream = render!(ctx, fit_by: "height", width: nil, height: 500)
    assert {stream["width"], stream["height"]} == {320, 240}
  end

  test "a shared rendition's image-scale quality produces a valid video", ctx do
    stream = render!(ctx, applies_to: "both", quality: 85)
    assert stream["codec_name"] == "h264"
    assert {stream["width"], stream["height"]} == {160, 120}
  end

  test "preserving the original format produces a valid video", ctx do
    stream = render!(ctx, format: nil)
    assert stream["codec_name"] == "h264"
    assert {stream["width"], stream["height"]} == {160, 120}
  end
end
