defmodule PhoenixKitWeb.FileProxyRangeTest do
  @moduledoc """
  A file the app proxies (a private bucket) is read from the bucket only as far
  as a request asks. A browser plays a video by asking for parts; each used to
  download the whole object to a temporary file first, so every seek in a large
  private video cost the whole video.

  End to end through `FileController.show/2`, against a stand-in S3 that keeps
  what it is sent and records every request it answers.
  """

  use PhoenixKit.DataCase, async: false

  import Ecto.Query
  import Plug.Test

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Locations, Manager, URLSigner}
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.FileController

  @buckets_cache :phoenix_kit_buckets_cache
  @bytes :crypto.strong_rand_bytes(100_000)

  defmodule FakeS3 do
    @moduledoc false
    # Path-style S3: PUT, HEAD and GET (with Range) of /<bucket>/<key>.
    @behaviour Plug
    import Plug.Conn

    def init(table), do: table

    def call(conn, table) do
      key = conn.request_path
      :ets.insert(table, {:request, {conn.method, key, get_req_header(conn, "range")}})

      case {conn.method, :ets.lookup(table, {:object, key})} do
        {"PUT", _} ->
          {:ok, body, conn} = read_whole(conn, [])
          :ets.insert(table, {{:object, key}, body})
          conn |> put_resp_header("etag", ~s("e")) |> send_resp(200, "")

        {"HEAD", [{_, body}]} ->
          conn
          |> put_resp_header("content-length", Integer.to_string(byte_size(body)))
          |> send_resp(200, "")

        {"GET", [{_, body}]} ->
          case get_req_header(conn, "range") do
            ["bytes=" <> spec] ->
              [first, last] = String.split(spec, "-") |> Enum.map(&String.to_integer/1)
              last = min(last, byte_size(body) - 1)

              conn
              |> put_resp_header("content-range", "bytes #{first}-#{last}/#{byte_size(body)}")
              |> send_resp(206, binary_part(body, first, last - first + 1))

            [] ->
              send_resp(conn, 200, body)
          end

        _ ->
          send_resp(conn, 404, "")
      end
    end

    defp read_whole(conn, acc) do
      case read_body(conn) do
        {:ok, data, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([data | acc])), conn}
        {:more, data, conn} -> read_whole(conn, [data | acc])
      end
    end
  end

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    table = :ets.new(:fake_s3, [:public, :duplicate_bag])
    server = start_supervised!({Bandit, plug: {FakeS3, table}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "proxy-range-#{n}",
        provider: "s3",
        bucket_name: "pk-range-#{n}",
        region: "us-east-1",
        endpoint: "http://127.0.0.1:#{port}",
        access_key_id: "AKIATEST",
        secret_access_key: "test-secret",
        access_type: "private",
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    source = Path.join(System.tmp_dir!(), "pk_proxy_range_#{n}.mp4")
    File.write!(source, @bytes)
    on_exit(fn -> :persistent_term.erase(@buckets_cache) && File.rm(source) end)

    {:ok, owner} =
      Auth.register_user(%{
        "email" => "proxy-range-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    checksum = :sha256 |> :crypto.hash(@bytes) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(source, "video", owner.uuid, checksum, "mp4", "clip.mp4")

    # Stored where the Default profile puts it; then only the stand-in S3 holds it,
    # so it is served from there.
    instance = Storage.get_file_instance_by_name(file.uuid, "original")
    :ets.insert(table, {{:object, "/#{bucket.bucket_name}/#{instance.file_name}"}, @bytes})
    Locations.record(instance.file_name, bucket.uuid)

    Repo.update_all(
      from(b in PhoenixKit.Modules.Storage.Bucket, where: b.uuid != ^bucket.uuid),
      set: [enabled: false]
    )

    :persistent_term.erase(@buckets_cache)
    assert {:proxy, _} = Manager.get_file_access(instance.file_name, file_uuid: file.uuid)

    :ets.delete(table, :request)
    %{stored: file, table: table, bucket: bucket}
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

  defp gets(table) do
    for {:request, {"GET", _key, range}} <- :ets.lookup(table, :request), do: range
  end

  test "a part is read from the bucket as that part alone", %{stored: file, table: table} do
    conn = request(file, [{"range", "bytes=1000-1999"}])

    assert conn.status == 206
    assert conn.resp_body == binary_part(@bytes, 1000, 1000)
    assert Plug.Conn.get_resp_header(conn, "content-range") == ["bytes 1000-1999/100000"]
    assert Plug.Conn.get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert gets(table) == [["bytes=1000-1999"]]
  end

  test "a browser's first ask, bytes=0-, and the end where an index may be", ctx do
    first = request(ctx.stored, [{"range", "bytes=0-"}])
    assert first.status == 206
    assert first.resp_body == @bytes

    tail = request(ctx.stored, [{"range", "bytes=-100"}])
    assert tail.status == 206
    assert tail.resp_body == binary_part(@bytes, 99_900, 100)
    assert gets(ctx.table) |> Enum.sort() == [["bytes=0-99999"], ["bytes=99900-99999"]]
  end

  test "without Range the whole file still comes, and says ranges are welcome", ctx do
    conn = request(ctx.stored, [])

    assert conn.status == 200
    assert conn.resp_body == @bytes
    assert Plug.Conn.get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "If-Range naming other bytes gets the whole file", ctx do
    conn = request(ctx.stored, [{"range", "bytes=0-9"}, {"if-range", ~s("other")}])

    assert conn.status == 200
    assert conn.resp_body == @bytes
  end

  test "a signed bucket's link for a video lasts hours: a browser never asks again", ctx do
    Repo.update_all(
      from(b in PhoenixKit.Modules.Storage.Bucket, where: b.uuid == ^ctx.bucket.uuid),
      set: [access_type: "signed"]
    )

    :persistent_term.erase(@buckets_cache)

    conn = request(ctx.stored, [])
    assert conn.status == 302
    [location] = Plug.Conn.get_resp_header(conn, "location")
    assert location =~ "X-Amz-Expires=14400"
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]

    # Anything else keeps the short link.
    name = Storage.get_file_instance_by_name(ctx.stored.uuid, "original").file_name
    assert {:signed_redirect, url} = Manager.get_file_access(name, file_uuid: ctx.stored.uuid)
    assert url =~ "X-Amz-Expires=300"
  end
end
