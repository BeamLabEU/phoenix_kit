defmodule PhoenixKit.Modules.Storage.VideoFfmpegArgsTest do
  @moduledoc """
  The FFmpeg arguments of a video rendition (`VariantGenerator.ffmpeg_args/3`)
  come from what the rendition is configured to be: its size, its quality and
  its format. Its name decides nothing (the standard `360p`, `720p` and
  `1080p` used to be hard-coded to 640x360, 1280x720 and 1920x1080 at a
  built-in CRF, whatever the page said).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{Dimension, VariantGenerator}

  defp dimension(attrs) do
    struct!(
      Dimension,
      Map.merge(
        %{
          name: "720p",
          width: 1280,
          height: 720,
          quality: 25,
          format: "mp4",
          applies_to: "video",
          maintain_aspect_ratio: false
        },
        Map.new(attrs)
      )
    )
  end

  defp args(attrs), do: VariantGenerator.ffmpeg_args("in.mov", "out.mp4", dimension(attrs))

  defp option(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end

  test "reads from the input, overwrites, and ends on the output" do
    args = args([])
    assert Enum.take(args, 3) == ["-i", "in.mov", "-y"]
    assert List.last(args) == "out.mp4"
  end

  describe "a fixed size is a box the video fits inside" do
    test "is scaled to fit, never enlarged, and kept on even sides" do
      filter = args([]) |> option("-vf")

      assert filter =~
               "scale=w='min(1280,iw)':h='min(720,ih)':force_original_aspect_ratio=decrease"

      # Not the old exact-size scale, which stretched a video of another shape.
      refute filter =~ "scale=1280:720"
      assert String.ends_with?(filter, ",scale=trunc(iw/2)*2:trunc(ih/2)*2")
    end

    test "follows the configured numbers, not the name" do
      filter = args(name: "720p", width: 1920, height: 1080) |> option("-vf")

      assert filter =~ "min(1920,iw)"
      assert filter =~ "min(1080,ih)"
      refute filter =~ "1280"
    end

    test "any name is treated alike" do
      assert args(name: "720p", width: 800, height: 450) |> option("-vf") ==
               args(name: "teaser", width: 800, height: 450) |> option("-vf")
    end
  end

  describe "keeping proportions sets the width and the height follows" do
    test "scales to the width, never enlarging, with an even height" do
      filter = args(maintain_aspect_ratio: true, width: 640, height: nil) |> option("-vf")

      assert filter == "scale=w='min(640,iw)':h=-2,scale=trunc(iw/2)*2:trunc(ih/2)*2"
    end

    test "ignores a leftover height" do
      assert args(maintain_aspect_ratio: true, width: 640, height: 360) |> option("-vf") =~
               "h=-2"
    end
  end

  test "a height-fixed video or poster follows its height, ignoring a leftover width" do
    for format <- ["mp4", "jpg"] do
      filter =
        args(
          maintain_aspect_ratio: true,
          fit_by: "height",
          height: 120,
          width: 640,
          format: format
        )
        |> option("-vf")

      assert filter == "scale=w=-2:h='min(120,ih)',scale=trunc(iw/2)*2:trunc(ih/2)*2"
    end
  end

  test "a rendition with no size leaves the video as it is" do
    assert args(width: nil, height: nil) |> option("-vf") == nil
  end

  describe "quality is the CRF" do
    test "H.264 takes the configured number, whatever the name" do
      assert args(name: "720p", quality: 25) |> option("-crf") == "25"
      assert args(name: "1080p", quality: 23) |> option("-crf") == "23"
      assert args(name: "360p", quality: 30) |> option("-crf") == "30"
      assert args(name: "clip", quality: 18) |> option("-crf") == "18"
      assert args(format: "mp4") |> option("-c:v") == "libx264"
      assert args(format: "mov") |> option("-c:v") == "libx264"
    end

    test "is not read as the 1-100 image scale" do
      # 28 used to come out as CRF 37 for any name that was not 360p/720p/1080p.
      assert args(name: "clip", quality: 28) |> option("-crf") == "28"
    end

    test "preserving the original container still applies its quality" do
      assert args(format: nil, quality: 18) |> option("-crf") == "18"
      assert args(format: "", quality: 18) |> option("-c:v") == "libx264"
    end

    test "a shared image/video rendition keeps its 1-100 scale" do
      assert args(applies_to: "both", quality: 85) |> option("-crf") == "8"
      assert args(applies_to: "both", quality: 1) |> option("-crf") == "51"
    end

    test "VP9 gets a constant-quality bitrate beside the CRF" do
      args = args(format: "webm", quality: 32)

      assert option(args, "-c:v") == "libvpx-vp9"
      assert option(args, "-b:v") == "0"
      assert option(args, "-crf") == "32"
    end

    test "a container with no CRF is left to FFmpeg's defaults" do
      assert args(format: "avi") |> option("-crf") == nil
    end

    test "no quality sets no CRF" do
      assert args(quality: nil) |> option("-crf") == nil
    end
  end

  describe "a still frame (the video thumbnail)" do
    defp thumbnail(attrs \\ []) do
      args(
        Keyword.merge(
          [name: "video_thumbnail", width: 640, height: 360, quality: 85, format: "jpg"],
          attrs
        )
      )
    end

    test "is one frame, one second in, with no video encoder options" do
      args = thumbnail()

      assert option(args, "-ss") == "00:00:01.000"
      assert option(args, "-vframes") == "1"
      assert option(args, "-crf") == nil
    end

    test "is sized like any other rendition" do
      assert thumbnail() |> option("-vf") =~ "min(640,iw)"
    end

    test "quality is the 1-100 image scale, mapped onto JPEG's 2-31" do
      assert thumbnail(quality: 100) |> option("-q:v") == "2"
      assert thumbnail(quality: 85) |> option("-q:v") == "6"
      assert thumbnail(quality: 1) |> option("-q:v") == "31"
    end

    test "WebP takes it as it is, and PNG has none" do
      assert thumbnail(format: "webp", quality: 70) |> option("-quality") == "70"
      refute "-quality" in thumbnail(format: "png")
      refute "-q:v" in thumbnail(format: "png")
    end

    test "is a still because of its format, not its name" do
      assert option(thumbnail(name: "poster"), "-vframes") == "1"
    end
  end

  describe "the quality scale a dimension accepts" do
    defp quality_errors(attrs) do
      %Dimension{}
      |> Dimension.changeset(
        Map.merge(
          %{name: "x#{System.unique_integer([:positive])}", width: 640, applies_to: "video"},
          Map.new(attrs)
        )
      )
      |> Ecto.Changeset.traverse_errors(fn {message, _} -> message end)
      |> Map.get(:quality, [])
    end

    test "a video format takes a CRF, 0-51" do
      assert quality_errors(format: "mp4", quality: 28) == []
      assert quality_errors(format: "mp4", quality: 85) != []
    end

    test "a still frame takes the image scale, 1-100, whatever it is called" do
      assert quality_errors(format: "jpg", quality: 85) == []
      assert quality_errors(name: "video_thumbnail", format: "jpg", quality: 85) == []
    end
  end
end
