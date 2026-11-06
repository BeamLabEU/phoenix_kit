defmodule PhoenixKit.Integrations.KeyStore.S3Test do
  @moduledoc """
  The S3 key store through the real HTTP stack, against a local stub served by
  Bandit, in a region shaped like Backblaze B2's. ExAws refuses such a region before
  the host applies (`Storage.Providers.S3Request`), and this store's settings can come
  from the caller or from `config :ex_aws`, so both are covered, and what each request
  is signed for is checked: a service refuses a signature for the wrong region.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.KeyStore.S3
  alias PhoenixKit.Modules.Storage.Providers.S3Request

  @region "us-west-002"
  @secret "a-secret-long-enough-to-be-one"

  defmodule StubS3 do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(store), do: store

    @impl true
    def call(conn, store) do
      Agent.update(store, &Map.put(&1, :signed, get_req_header(conn, "authorization")))
      answer(conn, store, conn.method)
    end

    defp answer(conn, store, "PUT") do
      {:ok, body, conn} = read_body(conn)
      Agent.update(store, &Map.put(&1, conn.request_path, body))
      send_resp(conn, 200, "")
    end

    defp answer(conn, store, "GET") do
      case Agent.get(store, &Map.get(&1, conn.request_path)) do
        nil -> send_resp(conn, 404, "")
        body -> send_resp(conn, 200, body)
      end
    end

    defp answer(conn, store, "DELETE") do
      Agent.update(store, &Map.delete(&1, conn.request_path))
      send_resp(conn, 204, "")
    end
  end

  setup do
    store = start_supervised!({Agent, fn -> %{} end})

    server =
      start_supervised!(
        {Bandit, plug: {StubS3, store}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    settings = Application.get_all_env(:ex_aws)
    on_exit(fn -> restore(settings) end)

    %{store: store, port: port}
  end

  defp restore(settings) do
    for {key, _value} <- Application.get_all_env(:ex_aws),
        do: Application.delete_env(:ex_aws, key)

    for {key, value} <- settings, do: Application.put_env(:ex_aws, key, value)
  end

  defp credentials do
    [access_key_id: "key", secret_access_key: "secret", http_client: ExAws.Request.Req]
  end

  defp address(port), do: [host: "127.0.0.1", port: port, scheme: "http://"]

  defp signed_for(store) do
    [authorization] = Agent.get(store, & &1.signed)
    [_all, region] = Regex.run(~r{Credential=[^/]+/\d+/([^/]+)/s3/aws4_request}, authorization)
    region
  end

  test "a B2-shaped region takes the secret and gives it back", ctx do
    opts = [
      bucket: "ops",
      ex_aws_config: credentials() ++ address(ctx.port) ++ [region: @region]
    ]

    assert S3.write(@secret, opts) == :ok
    assert S3.read(opts) == {:ok, @secret}
    assert signed_for(ctx.store) == @region
    assert S3.preflight(opts) == :ok
  end

  test "the host and the region can both come from config :ex_aws", ctx do
    Application.put_env(:ex_aws, :s3, address(ctx.port) ++ [region: @region])
    opts = [bucket: "ops", ex_aws_config: credentials()]

    assert S3.write(@secret, opts) == :ok
    assert S3.read(opts) == {:ok, @secret}
    assert signed_for(ctx.store) == @region
  end

  # The neutral region must not stand in for one the host configured elsewhere.
  test "a region left to config :ex_aws is the one requests are signed for", ctx do
    Application.put_env(:ex_aws, :region, "eu-central-003")
    opts = [bucket: "ops", ex_aws_config: credentials() ++ address(ctx.port)]

    assert S3.write(@secret, opts) == :ok
    assert signed_for(ctx.store) == "eu-central-003"
  end

  test "a region read from the environment is read" do
    System.put_env("PK_KEY_STORE_REGION", @region)
    on_exit(fn -> System.delete_env("PK_KEY_STORE_REGION") end)
    Application.put_env(:ex_aws, :s3, region: {:system, "PK_KEY_STORE_REGION"})

    assert %{region: @region} = S3Request.config(credentials() ++ [host: "s3.example.com"])
  end

  test "nothing changes for AWS itself: no host named, ExAws's own config" do
    assert %{host: "s3.eu-west-1.amazonaws.com", region: "eu-west-1"} =
             S3Request.config(credentials() ++ [region: "eu-west-1"])
  end
end
