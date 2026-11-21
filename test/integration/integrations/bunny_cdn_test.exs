defmodule PhoenixKit.Integration.BunnyCDNTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.BunnyCDN
  alias PhoenixKit.Integrations.Providers

  setup do
    previous = Application.fetch_env(:phoenix_kit, :integrations_check_req_options)

    Application.put_env(:phoenix_kit, :integrations_check_req_options,
      plug: {Req.Test, __MODULE__}
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :integrations_check_req_options, value)
        :error -> Application.delete_env(:phoenix_kit, :integrations_check_req_options)
      end
    end)

    owner = {:user, UUIDv7.generate()}
    {:ok, %{uuid: uuid}} = Integrations.add_connection("bunny_cdn", "Photos", nil, owner: owner)

    {:ok, _} =
      Integrations.save_setup(uuid, %{"api_key" => "example", "pull_zone_id" => "42"}, nil,
        owner: owner
      )

    %{owner: owner, uuid: uuid}
  end

  defp stub_zone(secured) do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "api.bunny.net"
      assert Plug.Conn.get_req_header(conn, "accesskey") == ["example"]

      case {conn.method, conn.request_path} do
        {"GET", "/pullzone/42"} ->
          Req.Test.json(conn, %{
            "Id" => 42,
            "Name" => "photos",
            "OriginUrl" => "https://origin.example/derived/",
            "Enabled" => true,
            "Suspended" => false,
            "ZoneSecurityEnabled" => secured,
            "Hostnames" => [
              %{
                "Value" => "photos.b-cdn.net",
                "IsSystemHostname" => true,
                "HasCertificate" => true
              }
            ]
          })

        {"POST", "/purge"} ->
          assert URI.decode_query(conn.query_string) == %{
                   "async" => "false",
                   "url" => "https://photos.b-cdn.net/derived/a%20b.jpg"
                 }

          Plug.Conn.send_resp(conn, 200, "")
      end
    end)
  end

  test "zone resolution respects the connection owner", %{uuid: uuid, owner: owner} do
    stub_zone(false)
    assert Providers.get("bunny_cdn") in Providers.with_capability(:cdn_delivery)
    assert {:ok, "https://photos.b-cdn.net"} = BunnyCDN.public_base_url(uuid, owner)
    assert {:error, :not_configured} = BunnyCDN.public_base_url(uuid, :system)
    assert {:error, :not_configured} = BunnyCDN.public_base_url(uuid, {:user, UUIDv7.generate()})
    assert {:error, :not_configured} = BunnyCDN.public_base_url(uuid, :any)
  end

  test "pilot check compares the exact origin path and rejects additional hostnames", %{
    uuid: uuid,
    owner: owner
  } do
    stub_zone(false)

    assert {:ok, "https://photos.b-cdn.net"} =
             BunnyCDN.check_origin(uuid, owner, "https://origin.example/derived")

    assert {:error, :origin_mismatch} =
             BunnyCDN.check_origin(uuid, owner, "https://origin.example")

    assert {:error, :invalid_origin} = BunnyCDN.check_origin(uuid, owner, "http://origin.example")

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "Id" => 42,
        "Name" => "photos",
        "Enabled" => true,
        "Suspended" => false,
        "ZoneSecurityEnabled" => false,
        "OriginUrl" => "https://origin.example/derived",
        "Hostnames" => [
          %{"Value" => "photos.b-cdn.net", "IsSystemHostname" => true, "HasCertificate" => true},
          %{"Value" => "cdn.example", "IsSystemHostname" => false}
        ]
      })
    end)

    assert {:error, :additional_hostnames} =
             BunnyCDN.check_origin(uuid, owner, "https://origin.example/derived")
  end

  test "a secured zone still permits withdrawal of previously public objects", %{
    uuid: uuid,
    owner: owner
  } do
    stub_zone(true)
    assert {:error, :no_public_hostname} = BunnyCDN.public_base_url(uuid, owner)
    assert :ok = BunnyCDN.purge(uuid, owner, "derived/a b.jpg")
    assert {:error, :invalid_object_key} = BunnyCDN.purge(uuid, owner, "derived/*")
  end

  test "bucket mappings are owner scoped and unique, with atomic creation", %{
    uuid: personal,
    owner: owner
  } do
    alias PhoenixKit.Modules.Storage.{Bucket, CDNSource}

    bucket =
      Repo.insert!(%Bucket{
        name: "Dev",
        provider: "hetzner",
        bucket_name: "example",
        endpoint: "hel1.your-objectstorage.com"
      })

    origin = "https://example.hel1.your-objectstorage.com/cdn-pilot/"
    assert CDNSource.suggestion(bucket) == origin

    assert CDNSource.suggestion(%{
             bucket
             | provider: "b2",
               endpoint: "s3.us-west-002.backblazeb2.com"
           }) ==
             "https://s3.us-west-002.backblazeb2.com/example/cdn-pilot/"

    assert CDNSource.suggestion(%{bucket | provider: "local"}) == nil

    attrs = %{"source_bucket_uuid" => bucket.uuid, "source_origin" => origin}

    assert {:error, :invalid_cdn_source} =
             Integrations.save_setup(personal, attrs, nil, owner: owner)

    assert {:ok, %{uuid: site}} =
             Integrations.add_configured_connection("bunny_cdn", "Mapped", attrs, nil, [])

    assert CDNSource.mapping(bucket.uuid) == %{uuid: site, name: "Mapped"}

    assert {:error, :invalid_cdn_source} =
             Integrations.add_configured_connection("bunny_cdn", "Duplicate", attrs, nil, [])

    refute Enum.any?(Integrations.list_connections("bunny_cdn"), &(&1.name == "Duplicate"))

    assert {:ok, _} =
             Integrations.update_connection(site, "Mapped", %{
               "source_bucket_uuid" => "",
               "source_origin" => ""
             })

    assert CDNSource.mapping(bucket.uuid) == nil
  end

  @tag :tmp_dir
  test "verifying exercises the bucket, edge and purge, and clears proof on reconfiguration", %{
    tmp_dir: dir
  } do
    alias PhoenixKit.Modules.Storage.{Bucket, CDNSource}
    bucket = Repo.insert!(%Bucket{name: "Local pilot", provider: "local", endpoint: dir})

    attrs = %{
      "api_key" => "test",
      "pull_zone_id" => "42",
      "source_bucket_uuid" => bucket.uuid,
      "source_origin" => "https://origin.example/cdn-pilot/"
    }

    {:ok, %{uuid: site}} =
      Integrations.add_configured_connection("bunny_cdn", "Test edge", attrs, nil, [])

    {:ok, edge} = Agent.start_link(fn -> nil end)

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.host, conn.request_path} do
        {"api.bunny.net", "/pullzone/42"} ->
          Req.Test.json(conn, %{
            "Id" => 42,
            "Name" => "photos",
            "OriginUrl" => attrs["source_origin"],
            "Enabled" => true,
            "Suspended" => false,
            "ZoneSecurityEnabled" => false,
            "Hostnames" => [
              %{
                "Value" => "photos.b-cdn.net",
                "IsSystemHostname" => true,
                "HasCertificate" => true
              }
            ]
          })

        {"api.bunny.net", "/purge"} ->
          Agent.update(edge, fn _ -> nil end)
          Plug.Conn.send_resp(conn, 200, "")

        {"photos.b-cdn.net", "/" <> key} ->
          assert Plug.Conn.get_req_header(conn, "accesskey") == []

          body =
            Agent.get_and_update(edge, fn cached ->
              content =
                cached ||
                  case File.read(Path.join([dir, "cdn-pilot", key])) do
                    {:ok, body} -> body
                    _ -> nil
                  end

              {content, content}
            end)

          if body,
            do: Plug.Conn.send_resp(conn, 200, body),
            else: Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    assert :ok = CDNSource.verify(site, :system)
    assert File.ls!(Path.join(dir, "cdn-pilot")) == []
    {:ok, %{data: data}} = Integrations.get_integration_by_uuid(site, :system)
    assert data["source_checked_at"]
    {:ok, updated} = Integrations.save_setup(site, %{"pull_zone_id" => "43"})
    refute updated["source_checked_at"]
  end

  test "validation checks the pull zone ID against Bunny's response" do
    stub_zone(false)

    assert {:ok, %{fact: "photos"}} =
             BunnyCDN.validate_connection(%{"api_key" => "example", "pull_zone_id" => "42"})

    assert {:error, _} =
             BunnyCDN.validate_connection(%{
               "api_key" => "example",
               "pull_zone_id" => "42/subpath"
             })

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"Id" => 43, "Name" => "other"}) end)

    assert {:error, _} =
             BunnyCDN.validate_connection(%{"api_key" => "example", "pull_zone_id" => "42"})
  end
end
