defmodule PhoenixKitWeb.FileRangeTest do
  @moduledoc """
  A stored file is served in parts when asked (`Range`). A browser plays a
  video by asking for parts: answered whole every time, it shows 0:00 until
  the whole file has arrived, cannot seek, and Safari may refuse it.

  Served end to end through `FileController.show/2` from real stored bytes.
  """

  use PhoenixKit.DataCase, async: false

  import Plug.Test

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.FileController

  @buckets_cache :phoenix_kit_buckets_cache
  @bytes Enum.map_join(0..999, &rem(&1, 10)) |> String.duplicate(5)

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_range_#{n}")
    source = Path.join(System.tmp_dir!(), "pk_range_src_#{n}.mp4")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "range-test-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(tmp_root)
      File.rm(source)
    end)

    {:ok, owner} =
      Auth.register_user(%{
        "email" => "range-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    File.write!(source, @bytes)
    checksum = :sha256 |> :crypto.hash(@bytes) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(source, "video", owner.uuid, checksum, "mp4", "clip.mp4")

    %{stored: file}
  end

  defp request(file, headers) do
    params = %{
      "file_uuid" => file.uuid,
      "variant" => "original",
      "token" => URLSigner.generate_token(file.uuid, "original")
    }

    headers
    |> Enum.reduce(conn(:get, "/"), fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end)
    |> FileController.show(params)
  end

  defp header(conn, name), do: Plug.Conn.get_resp_header(conn, name)

  defp etag(file) do
    ~s("#{Storage.get_file_instance_by_name(file.uuid, "original").checksum}")
  end

  test "without Range the whole file comes, and ranges are offered", %{stored: file} do
    conn = request(file, [])

    assert conn.status == 200
    assert conn.resp_body == @bytes
    assert header(conn, "accept-ranges") == ["bytes"]
  end

  test "a range is answered 206 with just those bytes", %{stored: file} do
    conn = request(file, [{"range", "bytes=10-19"}])

    assert conn.status == 206
    assert conn.resp_body == binary_part(@bytes, 10, 10)
    assert header(conn, "content-range") == ["bytes 10-19/5000"]
  end

  test "the end of the file, where an mp4 without faststart keeps its index", %{stored: file} do
    conn = request(file, [{"range", "bytes=-100"}])

    assert conn.status == 206
    assert conn.resp_body == binary_part(@bytes, 4900, 100)
    assert header(conn, "content-range") == ["bytes 4900-4999/5000"]
  end

  test "a range past the end is 416 with the size", %{stored: file} do
    conn = request(file, [{"range", "bytes=9000-"}])

    assert conn.status == 416
    assert header(conn, "content-range") == ["bytes */5000"]
  end

  test "several ranges at once get the whole file", %{stored: file} do
    conn = request(file, [{"range", "bytes=0-1,5-9"}])

    assert conn.status == 200
    assert conn.resp_body == @bytes
  end

  test "If-Range: the same bytes get the part, other bytes the whole file", %{stored: file} do
    same = request(file, [{"range", "bytes=0-9"}, {"if-range", etag(file)}])
    other = request(file, [{"range", "bytes=0-9"}, {"if-range", ~s("something-else")}])

    assert same.status == 206
    assert other.status == 200
    assert other.resp_body == @bytes
  end
end
