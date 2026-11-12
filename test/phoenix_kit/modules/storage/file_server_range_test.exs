defmodule PhoenixKit.Modules.Storage.FileServerRangeTest do
  @moduledoc """
  `FileServer.parse_range_header/2`: the one range of a `Range` header a
  browser sends to play a video (RFC 9110 §14.1.2).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.FileServer

  defp parse(header, size \\ 5000), do: FileServer.parse_range_header(header, size)

  test "no header is no range" do
    assert parse(nil) == :no_range
  end

  test "first-last, first- and -length" do
    assert parse("bytes=0-1023") == {:ok, 0, 1023, content_range: "bytes 0-1023/5000"}
    assert parse("bytes=1000-") == {:ok, 1000, 4999, content_range: "bytes 1000-4999/5000"}
    assert parse("bytes=-500") == {:ok, 4500, 4999, content_range: "bytes 4500-4999/5000"}
  end

  test "Safari's first probe, bytes=0-1" do
    assert parse("bytes=0-1") == {:ok, 0, 1, content_range: "bytes 0-1/5000"}
  end

  test "a last byte past the end means the end; a suffix longer than the file is all of it" do
    assert parse("bytes=4000-99999") == {:ok, 4000, 4999, content_range: "bytes 4000-4999/5000"}
    assert parse("bytes=-99999") == {:ok, 0, 4999, content_range: "bytes 0-4999/5000"}
  end

  test "a start at or past the end cannot be served" do
    assert parse("bytes=5000-") == {:error, :range_out_of_bounds}
    assert parse("bytes=6000-7000") == {:error, :range_out_of_bounds}
    assert parse("bytes=-0") == {:error, :range_out_of_bounds}
    assert parse("bytes=0-", 0) == {:error, :range_out_of_bounds}
  end

  test "anything else is ignored (the whole file is sent)" do
    for header <- ["bytes=0-1,5-9", "items=0-1", "bytes=9-1", "bytes=a-b", "bytes=-", "0-1", ""] do
      assert parse(header) == {:error, :invalid_range}, inspect(header)
    end
  end
end
