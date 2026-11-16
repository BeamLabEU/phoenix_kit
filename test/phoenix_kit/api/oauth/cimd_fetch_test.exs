defmodule PhoenixKit.API.OAuth.CimdFetchTest do
  @moduledoc """
  The real download path of the client metadata documents (`PhoenixKit.API.OAuth.Cimd` over
  `PhoenixKit.Modules.Storage.RemoteFetch`) and its refusals: private and metadata addresses, a
  redirect, a body over the limit (declared and streamed) and a body that never ends.

  Two kinds of test, neither of which opens a connection to anything outside this machine:

    * the real resolver, with addresses that must be refused **before** any connection is made;
    * a server on the loopback interface, reached through a test downloader that points the
      document URL at it and resolves `localhost` alone (every other name, a redirect target
      included, still goes to the real resolver). The downloader also shortens the deadline so
      the slow body does not hold the suite for five seconds; the limits the code asks for are
      checked in `CimdTest`.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.API.OAuth.Cimd
  alias PhoenixKit.API.OAuthCimdStub, as: Stub
  alias PhoenixKit.Modules.Storage.RemoteFetch
  alias PhoenixKit.Utils.PublicAddress

  @site "https://doc.test"

  defmodule Server do
    use Plug.Router

    alias PhoenixKit.API.OAuthCimdStub

    plug(:match)
    plug(:dispatch)

    get "/ok" do
      document =
        OAuthCimdStub.claude_document()
        |> Map.put("client_id", "https://doc.test/ok")

      conn
      |> put_resp_header("content-type", "application/json")
      |> put_resp_header("cache-control", "max-age=900")
      |> send_resp(200, JSON.encode!(document))
    end

    get "/big-declared" do
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, :binary.copy(" ", 70_000) <> "{}")
    end

    get "/big-streamed" do
      conn =
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_chunked(200)

      Enum.reduce_while(1..40, conn, fn _n, conn ->
        case chunk(conn, :binary.copy(" ", 4_000)) do
          {:ok, conn} -> {:cont, conn}
          {:error, _closed} -> {:halt, conn}
        end
      end)
    end

    get "/never-ends" do
      {:ok, conn} =
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_chunked(200)
        |> chunk("{")

      receive do
      after
        1_000 -> conn
      end
    end

    get "/to-metadata" do
      conn
      |> put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
      |> send_resp(302, "")
    end

    get "/to-local" do
      conn |> put_resp_header("location", "/ok") |> send_resp(302, "")
    end

    match(_, do: send_resp(conn, 404, ""))
  end

  defmodule Loopback do
    @moduledoc false
    # `https://doc.test/<path>` -> the loopback server; resolves `localhost` only.
    def download(url, opts) do
      port = Application.fetch_env!(:phoenix_kit, :oauth_cimd_test_port)
      uri = URI.parse(url)
      target = "http://localhost:#{port}#{uri.path}"

      local = [
        allow_http: true,
        allowed_ports: [port, 80],
        timeout: 400,
        unsafe_resolver: fn
          "localhost" -> {:ok, {127, 0, 0, 1}}
          host -> PublicAddress.resolve_public(host)
        end
      ]

      RemoteFetch.download(target, Keyword.merge(opts, local))
    end
  end

  defmodule Rebinding do
    @moduledoc false
    # A name that answers the loopback the first time it is resolved and the cloud metadata
    # address every time after: a download that resolves twice (once to judge the address, once
    # to connect) would be sent to the second answer.
    def download(url, opts) do
      port = Application.fetch_env!(:phoenix_kit, :oauth_cimd_test_port)
      counter = Application.fetch_env!(:phoenix_kit, :oauth_cimd_test_counter)
      target = "http://localhost:#{port}#{URI.parse(url).path}"

      local = [
        allow_http: true,
        allowed_ports: [port, 80],
        timeout: 400,
        unsafe_resolver: fn "localhost" ->
          :counters.add(counter, 1, 1)

          case :counters.get(counter, 1) do
            1 -> {:ok, {127, 0, 0, 1}}
            _ -> {:ok, {169, 254, 169, 254}}
          end
        end
      ]

      RemoteFetch.download(target, Keyword.merge(opts, local))
    end
  end

  setup do
    server = start_supervised!({Bandit, plug: Server, port: 0, ip: :loopback, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:phoenix_kit, :oauth_cimd_test_port, port)

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :oauth_cimd_test_port)
      Application.delete_env(:phoenix_kit, :oauth_cimd_test_counter)
      Application.delete_env(:phoenix_kit, :oauth_cimd_downloader)
    end)

    %{port: port}
  end

  defp loopback, do: Application.put_env(:phoenix_kit, :oauth_cimd_downloader, Loopback)

  describe "the real resolver" do
    test "refuses private, loopback, link-local and metadata addresses before connecting" do
      for host <- [
            "127.0.0.1",
            "10.0.0.5",
            "172.16.4.4",
            "192.168.1.10",
            "169.254.169.254",
            "100.64.0.1",
            "0.0.0.0",
            "[::1]",
            "[fd00::1]",
            "[fe80::1]",
            "[::ffff:127.0.0.1]",
            "[::ffff:169.254.169.254]"
          ] do
        assert {:error, {:fetch_failed, :blocked_host}} =
                 Cimd.fetch("https://#{host}/client.json"),
               host
      end
    end

    test "refuses a name that resolves to an internal address" do
      # `localhost` is answered from the hosts file: no DNS server is asked.
      assert {:error, {:fetch_failed, :blocked_host}} =
               Cimd.fetch("https://localhost/client.json")
    end

    test "refuses a port other than 443 without a request" do
      assert {:error, :invalid_client_id} = Cimd.fetch("https://client.example:8443/c.json")
    end
  end

  describe "against a server that misbehaves" do
    setup do
      loopback()
    end

    test "a good document is read, and its caching time comes from the headers" do
      assert {:ok, %{client_name: "Claude", ttl: 900}} = Cimd.fetch(@site <> "/ok")
    end

    test "a body declared bigger than 64 KB is refused" do
      assert {:error, {:fetch_failed, :too_large}} = Cimd.fetch(@site <> "/big-declared")
    end

    test "a body that grows past 64 KB with no declared length is cut off" do
      assert {:error, {:fetch_failed, :too_large}} = Cimd.fetch(@site <> "/big-streamed")
    end

    test "a body that never ends is cut off at the deadline" do
      assert {:error, {:fetch_failed, :timeout}} = Cimd.fetch(@site <> "/never-ends")
    end

    test "a redirect is not followed, not even to a public place" do
      assert {:error, {:fetch_failed, :too_many_redirects}} = Cimd.fetch(@site <> "/to-local")
    end

    test "a redirect to the cloud metadata address is refused" do
      assert {:error, {:fetch_failed, :too_many_redirects}} = Cimd.fetch(@site <> "/to-metadata")
    end

    test "no temporary file survives a refusal" do
      before = temp_files()

      for path <- ["/big-declared", "/big-streamed", "/never-ends", "/to-metadata"] do
        assert {:error, _reason} = Cimd.fetch(@site <> path)
      end

      assert temp_files() -- before == []
    end
  end

  describe "DNS rebinding" do
    test "the name is resolved once, and the connection goes to the address that was judged" do
      counter = :counters.new(1, [])
      Application.put_env(:phoenix_kit, :oauth_cimd_test_counter, counter)
      Application.put_env(:phoenix_kit, :oauth_cimd_downloader, Rebinding)

      assert {:ok, %{client_name: "Claude"}} = Cimd.fetch(@site <> "/ok")
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "RemoteFetch itself, were redirects allowed" do
    test "a hop to the metadata address is refused by the resolver, nothing is requested", %{
      port: port
    } do
      opts = [
        allow_http: true,
        allowed_ports: [port, 80],
        max_redirects: 3,
        unsafe_resolver: fn
          "localhost" -> {:ok, {127, 0, 0, 1}}
          host -> PublicAddress.resolve_public(host)
        end
      ]

      assert {:error, :blocked_host} =
               RemoteFetch.download("http://localhost:#{port}/to-metadata", opts)
    end
  end

  test "the stub and the loopback server agree on the fixture" do
    assert Stub.claude_document()["redirect_uris"] == ["https://claude.ai/api/mcp/auth_callback"]
  end

  defp temp_files do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "pk_remote_"))
    |> Enum.sort()
  end
end
