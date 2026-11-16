defmodule PhoenixKit.Modules.Storage.RemoteFetchHeadersTest do
  @moduledoc """
  `RemoteFetch.download/2` with `return_headers: true`: the response headers come back with the
  file, so a caller that caches (the client metadata documents of the OAuth server) can read
  `Cache-Control`. Against a loopback server, reached through the test-only `:unsafe_resolver`;
  nothing leaves the machine.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.RemoteFetch

  defmodule Server do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/doc" do
      conn
      |> put_resp_header("cache-control", "max-age=600")
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, ~s({"a":1}))
    end

    match(_, do: send_resp(conn, 404, ""))
  end

  setup do
    server = start_supervised!({Bandit, plug: Server, port: 0, ip: :loopback, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    local = [
      allow_http: true,
      allowed_ports: [port],
      unsafe_resolver: fn _host -> {:ok, {127, 0, 0, 1}} end
    ]

    %{url: "http://localhost:#{port}/doc", local: local}
  end

  test "return_headers adds the response headers to the result", %{url: url, local: local} do
    assert {:ok, %{path: path, headers: headers}} =
             RemoteFetch.download(url, [return_headers: true] ++ local)

    on_exit(fn -> File.rm(path) end)

    assert File.read!(path) == ~s({"a":1})
    assert {"cache-control", "max-age=600"} in headers
    assert {"content-type", "application/json"} in headers
  end

  test "without it the result has no headers key", %{url: url, local: local} do
    assert {:ok, %{path: path} = result} = RemoteFetch.download(url, local)
    on_exit(fn -> File.rm(path) end)

    refute Map.has_key?(result, :headers)
  end
end
