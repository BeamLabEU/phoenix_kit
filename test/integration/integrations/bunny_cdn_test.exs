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
