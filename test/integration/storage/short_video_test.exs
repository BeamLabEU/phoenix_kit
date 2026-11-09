defmodule PhoenixKit.Modules.Storage.ShortVideoTest do
  @moduledoc """
  A video shorter than half a second is processed like any other: its duration is kept as
  1 second, not rounded to 0, which the file's changeset refuses (and with it the size, the
  capture date and the previews).
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Users.Auth

  @moduletag :tmp_dir
  @buckets_cache :phoenix_kit_buckets_cache

  unless System.find_executable("ffmpeg") && System.find_executable("ffprobe"),
    do: @moduletag(skip: "ffmpeg and ffprobe are not installed")

  setup %{tmp_dir: tmp} do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    Repo.update_all(Bucket, set: [enabled: false])
    on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "short-video-#{n}",
        provider: "local",
        endpoint: Path.join(tmp, "bucket"),
        enabled: true,
        priority: 0
      })

    {:ok, user} =
      Auth.register_user(%{
        "email" => "short-video-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{tmp: tmp, user: user}
  end

  defp clip!(ctx, seconds) do
    path = Path.join(ctx.tmp, "clip-#{seconds}.mp4")

    {_, 0} =
      System.cmd("ffmpeg", [
        "-v",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "testsrc2=size=320x240:rate=25:duration=#{seconds}",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        path
      ])

    path
  end

  defp process!(ctx, path) do
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    file =
      case Storage.store_file_in_buckets(path, "video", ctx.user.uuid, sha, "mp4", "clip.mp4") do
        {:ok, file} -> file
        {:ok, file, _} -> file
      end

    :ok =
      ProcessFileJob.perform(%Oban.Job{
        args: %{"file_uuid" => file.uuid, "filename" => "clip.mp4"}
      })

    Storage.get_file(file.uuid)
  end

  test "a clip of 0.4 seconds is active, 1 second long, with its size", ctx do
    file = process!(ctx, clip!(ctx, 0.4))

    assert file.status == "active"
    assert file.duration == 1
    assert {file.width, file.height} == {320, 240}
  end

  test "a longer clip keeps its rounded length", ctx do
    file = process!(ctx, clip!(ctx, 2.6))

    assert file.status == "active"
    assert file.duration == 3
  end
end
