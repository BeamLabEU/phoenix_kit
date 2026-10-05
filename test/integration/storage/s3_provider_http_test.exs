defmodule PhoenixKit.Modules.Storage.S3ProviderHTTPTest do
  @moduledoc """
  `Providers.S3` through the real HTTP stack (#882), against a local
  S3-compatible stub served by Bandit: a HEAD answers (it raised a
  `CaseClauseError` under hackney 4 with ExAws's default client, so every
  object read as missing and every download failed), a download reads the
  bytes back, only a 404 means "not there", and the location backfill does
  not record an object as missing when a bucket could not answer.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, LocationCheck, Locations, Profiles, Reconciler}
  alias PhoenixKit.Modules.Storage.Providers.S3
  alias PhoenixKit.Modules.Storage.Workers.LocationBackfillJob
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  import Ecto.Query

  # A minimal S3: path-style `/<bucket>/<key>`, objects in an Agent. A key
  # starting with "broken" answers 500 to everything.
  defmodule StubS3 do
    @moduledoc false
    import Plug.Conn

    def init(store), do: store

    def call(conn, store) do
      [_bucket | key_parts] = conn.path_info
      key = Enum.join(key_parts, "/")

      cond do
        String.starts_with?(key, "broken") ->
          send_resp(conn, 500, "boom")

        conn.method == "PUT" and Agent.get(store, &Map.get(&1, :fail_writes, false)) ->
          send_resp(conn, 403, "denied")

        conn.method == "PUT" ->
          {:ok, body, conn} = read_all(conn, "")
          Agent.update(store, &Map.put(&1, key, body))
          conn |> put_resp_header("etag", ~s("etag")) |> send_resp(200, "")

        conn.method == "DELETE" ->
          Agent.update(store, &Map.delete(&1, key))
          send_resp(conn, 204, "")

        conn.method in ["HEAD", "GET"] ->
          case Agent.get(store, &Map.get(&1, key)) do
            nil -> send_resp(conn, 404, "")
            body -> object(conn, body)
          end

        true ->
          send_resp(conn, 405, "")
      end
    end

    defp object(%{method: "HEAD"} = conn, body) do
      conn
      |> put_resp_header("content-length", to_string(byte_size(body)))
      |> put_resp_header("etag", ~s("etag"))
      |> send_resp(200, "")
    end

    defp object(conn, body) do
      case get_req_header(conn, "range") do
        ["bytes=" <> range] ->
          [from, to] = range |> String.split("-") |> Enum.map(&String.to_integer/1)
          to = min(to, byte_size(body) - 1)
          send_resp(conn, 206, binary_part(body, from, to - from + 1))

        _ ->
          send_resp(conn, 200, body)
      end
    end

    defp read_all(conn, acc) do
      case read_body(conn) do
        {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
        {:more, chunk, conn} -> read_all(conn, acc <> chunk)
      end
    end
  end

  setup do
    store = start_supervised!({Agent, fn -> %{} end})

    server =
      start_supervised!(
        {Bandit, plug: {StubS3, store}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "stub-s3-#{System.unique_integer([:positive])}",
        provider: "s3",
        endpoint: "http://127.0.0.1:#{port}",
        bucket_name: "pk",
        region: "us-east-1",
        access_key_id: "test-key",
        secret_access_key: "test-secret",
        enabled: true,
        priority: 0
      })

    %{bucket: bucket, store: store}
  end

  defp source!(content) do
    path = Path.join(System.tmp_dir!(), "pk_s3_http_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp placement!(ctx, counts) do
    n = System.unique_integer([:positive])
    roots = for side <- ~w(a b), do: Path.join(System.tmp_dir!(), "pk_s3_placement_#{n}_#{side}")
    on_exit(fn -> Enum.each(roots, &File.rm_rf/1) end)

    locals =
      for root <- roots do
        {:ok, bucket} =
          Storage.create_bucket(
            %{
              name: Path.basename(root),
              provider: "local",
              endpoint: root,
              enabled: true
            },
            profile: nil
          )

        bucket
      end

    {:ok, profile} = Profiles.create_profile(Map.put(counts, :name, "S3 placement #{n}"))
    for bucket <- locals ++ [ctx.bucket], do: Profiles.put_bucket(profile, bucket.uuid, %{})
    {:ok, library} = Libraries.create_system_library(%{name: "S3 placement #{n}"})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "s3-placement-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    content = "S3 placement #{n}"
    sha = :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(source!(content), "document", user.uuid, sha, "txt", "a.txt",
        library_uuid: library.uuid
      )

    {:ok, file} = Storage.update_file(file, %{status: "active"})
    instance = Storage.get_file_instance_by_name(file.uuid, "original")

    Map.merge(ctx, %{
      locals: locals,
      profile: Profiles.get_profile(profile.uuid),
      library: library,
      file: Storage.get_file(file.uuid),
      key: instance.file_name,
      content: content
    })
  end

  test "profile placement writes two local copies and a cloud copy through HTTP", ctx do
    ctx = placement!(ctx, %{copies_local: 2, copies_cloud: 1, min_copies_on_write: 3})
    assert Agent.get(ctx.store, &Map.get(&1, ctx.key)) == ctx.content

    for bucket <- ctx.locals,
        do: assert(File.read!(Path.join(bucket.endpoint, ctx.key)) == ctx.content)

    assert length(Locations.bucket_uuids(ctx.key)) == 3
    assert ctx.file.placed_revision == ctx.profile.revision

    key = "#{ctx.file.file_path}/variant.txt"

    assert {:ok, %{complete?: true, successful_storages: 3}} =
             Storage.store_by_profile(source!("variant"), ctx.library.uuid, :derived,
               path_prefix: key
             )

    assert Agent.get(ctx.store, &Map.get(&1, key)) == "variant"
  end

  test "surplus local copies do not hide a failed cloud copy or permit unlinking", ctx do
    ctx = placement!(ctx, %{copies_local: 2, copies_cloud: 0})
    {:ok, _} = Profiles.update_profile(ctx.profile, %{copies_local: 1, copies_cloud: 1})
    Agent.update(ctx.store, &Map.delete(&1, ctx.key))
    Agent.update(ctx.store, &Map.put(&1, :fail_writes, true))

    assert Reconciler.reconcile_file(Storage.get_file(ctx.file.uuid)) == :stale
    assert Storage.get_file(ctx.file.uuid).placed_revision == ctx.profile.revision

    assert MapSet.new(Locations.bucket_uuids(ctx.key)) ==
             MapSet.new(ctx.locals, &to_string(&1.uuid))
  end

  test "switching to cloud only removes local copies after the cloud write succeeds", ctx do
    ctx = placement!(ctx, %{copies_local: 2, copies_cloud: 0})
    {:ok, _} = Profiles.update_profile(ctx.profile, %{copies_local: 0, copies_cloud: 1})

    assert Reconciler.reconcile_file(Storage.get_file(ctx.file.uuid)) == :reconciled
    assert Agent.get(ctx.store, &Map.get(&1, ctx.key)) == ctx.content
    assert Locations.bucket_uuids(ctx.key) == [to_string(ctx.bucket.uuid)]
    for bucket <- ctx.locals, do: refute(File.exists?(Path.join(bucket.endpoint, ctx.key)))
  end

  test "a cloud location without bytes cannot justify deleting a draining copy", ctx do
    ctx = placement!(ctx, %{copies_local: 2, copies_cloud: 1})
    root = Path.join(System.tmp_dir!(), "pk_s3_draining_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, draining} =
      Storage.create_bucket(
        %{
          name: Path.basename(root),
          provider: "local",
          endpoint: root,
          enabled: true
        },
        profile: nil
      )

    File.mkdir_p!(Path.dirname(Path.join(root, ctx.key)))
    File.write!(Path.join(root, ctx.key), ctx.content)
    Locations.record(ctx.key, draining.uuid)
    {:ok, _} = Profiles.put_bucket(ctx.profile, draining.uuid, %{status: "draining"})
    {:ok, _} = Profiles.update_profile(Profiles.get_profile(ctx.profile.uuid), %{copies_local: 1})
    Agent.update(ctx.store, &Map.delete(&1, ctx.key))

    assert Reconciler.reconcile_file(Storage.get_file(ctx.file.uuid)) == :stale
    assert File.exists?(Path.join(draining.endpoint, ctx.key))
    for bucket <- ctx.locals, do: assert(File.exists?(Path.join(bucket.endpoint, ctx.key)))
  end

  test "a serving fallback never writes a kind with zero copies wanted", ctx do
    ctx = placement!(ctx, %{copies_local: 0, copies_cloud: 1})
    {:ok, _} = Profiles.put_bucket(ctx.profile, ctx.bucket.uuid, %{role: "backup"})
    assert Reconciler.reconcile_file(Storage.get_file(ctx.file.uuid)) == :stale
    assert Locations.bucket_uuids(ctx.key) == [to_string(ctx.bucket.uuid)]
    for bucket <- ctx.locals, do: refute(File.exists?(Path.join(bucket.endpoint, ctx.key)))
  end

  test "a zero-count read-only serving bucket keeps its copies while only a cloud backup remains",
       ctx do
    ctx = placement!(ctx, %{copies_local: 2, copies_cloud: 1})
    {:ok, _} = Profiles.update_profile(ctx.profile, %{copies_local: 0})
    {:ok, _} = Profiles.put_bucket(ctx.profile, ctx.bucket.uuid, %{role: "backup"})

    for bucket <- ctx.locals,
        do: Profiles.put_bucket(ctx.profile, bucket.uuid, %{status: "read_only"})

    assert Reconciler.reconcile_file(Storage.get_file(ctx.file.uuid)) == :stale
    for bucket <- ctx.locals, do: assert(File.exists?(Path.join(bucket.endpoint, ctx.key)))
    assert length(Locations.bucket_uuids(ctx.key)) == 3
  end

  test "a zero-count full serving bucket keeps its copies while only a cloud backup remains",
       ctx do
    ctx = placement!(ctx, %{copies_local: 2, copies_cloud: 1})
    {:ok, _} = Profiles.update_profile(ctx.profile, %{copies_local: 0})
    {:ok, _} = Profiles.put_bucket(ctx.profile, ctx.bucket.uuid, %{role: "backup"})
    instance = Storage.get_file_instance_by_name(ctx.file.uuid, "original")
    {:ok, _} = Storage.update_file_instance(instance, %{size: 2_000_000})

    for bucket <- ctx.locals do
      {:ok, _} = Storage.update_bucket(bucket, %{max_size_mb: 1})
      :persistent_term.erase({:phoenix_kit_bucket_usage, to_string(bucket.uuid)})
    end

    assert Reconciler.reconcile_file(Storage.get_file(ctx.file.uuid)) == :stale
    for bucket <- ctx.locals, do: assert(File.exists?(Path.join(bucket.endpoint, ctx.key)))
    assert length(Locations.bucket_uuids(ctx.key)) == 3
  end

  test "verified backup copies cannot justify deleting the last real serving copy", ctx do
    ctx = placement!(ctx, %{copies_local: 2, copies_cloud: 1})
    [primary, backup] = ctx.locals
    {:ok, _} = Profiles.update_profile(ctx.profile, %{copies_local: 1})
    {:ok, _} = Profiles.put_bucket(ctx.profile, backup.uuid, %{role: "backup"})
    {:ok, _} = Profiles.put_bucket(ctx.profile, ctx.bucket.uuid, %{role: "backup"})

    root =
      Path.join(System.tmp_dir!(), "pk_s3_last_serving_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, draining} =
      Storage.create_bucket(
        %{
          name: Path.basename(root),
          provider: "local",
          endpoint: root,
          enabled: true
        },
        profile: nil
      )

    File.mkdir_p!(Path.dirname(Path.join(root, ctx.key)))
    File.write!(Path.join(root, ctx.key), ctx.content)
    Locations.record(ctx.key, draining.uuid)
    {:ok, _} = Profiles.put_bucket(ctx.profile, draining.uuid, %{status: "draining"})
    File.rm!(Path.join(primary.endpoint, ctx.key))

    assert Reconciler.reconcile_file(Storage.get_file(ctx.file.uuid)) == :stale
    assert File.exists?(Path.join(draining.endpoint, ctx.key))
    assert File.exists?(Path.join(backup.endpoint, ctx.key))
  end

  test "requests go through Req, never ExAws's default client", %{bucket: bucket} do
    assert Keyword.fetch!(S3.aws_config(bucket), :http_client) == ExAws.Request.Req
  end

  test "a HEAD answers: an object that is there exists", ctx do
    Agent.update(ctx.store, &Map.put(&1, "a/b.txt", "hello"))

    assert S3.file_exists?(ctx.bucket, "a/b.txt")
    refute S3.file_exists?(ctx.bucket, "a/missing.txt")
  end

  test "an error other than a 404 is not read as a missing object", ctx do
    assert_raise RuntimeError, ~r/S3 HEAD on bucket .* failed/, fn ->
      S3.file_exists?(ctx.bucket, "broken/x.txt")
    end
  end

  test "a download (which starts with a HEAD) reads the bytes back", ctx do
    assert {:ok, _} = S3.store_file(ctx.bucket, source!("round trip"), "c/d.txt")

    destination = Path.join(System.tmp_dir!(), "pk_s3_http_out_#{System.unique_integer()}")
    on_exit(fn -> File.rm(destination) end)

    assert :ok = S3.retrieve_file(ctx.bucket, "c/d.txt", destination)
    assert File.read!(destination) == "round trip"
  end

  test "the location backfill leaves an instance unchecked when a bucket errors", _ctx do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "s3-http-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    key = "broken/#{System.unique_integer([:positive])}.txt"

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "b.txt",
        file_name: Path.basename(key),
        file_path: Path.dirname(key),
        mime_type: "text/plain",
        file_type: "document",
        ext: "txt",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    {:ok, instance} =
      Storage.create_file_instance(%{
        variant_name: "original",
        file_name: key,
        mime_type: "text/plain",
        ext: "txt",
        checksum: "c",
        size: 1,
        processing_status: "completed",
        file_uuid: file.uuid
      })

    totals = LocationBackfillJob.run_pass()

    assert totals[:unsure] >= 1
    refute Repo.exists?(from(c in LocationCheck, where: c.file_instance_uuid == ^instance.uuid))
    refute Locations.known_missing?(key)
  end
end
