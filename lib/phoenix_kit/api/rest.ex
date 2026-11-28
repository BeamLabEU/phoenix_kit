defmodule PhoenixKit.API.REST do
  @moduledoc """
  The REST transport of the machine API: a plug that the router `forward`s to,
  once per audience.

      forward "/api/admin/v1", PhoenixKit.API.REST, audience: :admin
      forward "/api/public/v1", PhoenixKit.API.REST, audience: :public

  `phoenix_kit_routes/0` emits both (`PhoenixKit.API.Paths`). The plug sees the path after the
  forward, so the routes are:

    * `POST /<tool>` runs a tool; the body is the tool's input as one JSON
      object. A tool name has a dot in it (`catalogue.set_prices`), except an undotted
      name of a host tool (`call_endpoint`), and an alias of a tool runs that tool;
    * `GET /` lists the tools the caller may use, with their schemas;
    * `GET /openapi.json` is the generated OpenAPI 3.1 document of the tools the
      caller may use.

  Any other method on those paths answers `405` with an `allow` header,
  and any other path `404`, both as `application/problem+json`.

  The public tool list also carries a `Link` header to the OpenAPI document
  and the guide while the guide is published
  (`PhoenixKit.API.PublicDiscovery.put_list_links/1`).

  Everything else is done by `PhoenixKit.API.Auth` (API switch, key) and
  `PhoenixKit.API.Executor` (rights, limits, validation, the tool). The
  request body is `conn.body_params`, which `PhoenixKit.API.BodyGuard`
  filled in the endpoint; a body that never went through a parser reads as
  `%{}`.

  A tool name is matched as sent: the segments of the guarded prefix are
  percent-decoded by `BodyGuard`, the tool segment is not (`system%2Eget_identity`
  is an unknown tool).

  ## Encoded prefixes need `BodyGuard` in the endpoint

  Phoenix's `forward` strips its prefix from the raw `path_info`, so a request
  that writes the prefix percent-encoded (`/api/%61dmin/v1/x`, which the router
  still matches) raises a `MatchError` inside the forward. `BodyGuard`, in the
  host's endpoint, decodes those segments first. A host that has not run
  `mix phoenix_kit.update` since `BodyGuard` was added answers such a crafted
  URL with a 500; the MCP forwards will have the same dependency.

  ## CORS

  The public audience answers cross-origin requests from any origin, so a
  browser-based agent can call it: `access-control-allow-origin: *`, no
  credentials, and a `204` for the `OPTIONS` preflight. The headers the rate
  limit and the support flow rely on (`retry-after`, `ratelimit-*`,
  `x-request-id`, `idempotent-replayed`) are listed in `access-control-expose-headers`, otherwise a
  browser script cannot read them. The admin audience
  sends no CORS headers: a browser must not call it from another site.
  """

  @behaviour Plug

  import Plug.Conn

  @exposed_headers "retry-after, ratelimit-limit, ratelimit-remaining, ratelimit-reset, x-request-id, idempotent-replayed"

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.OpenAPI
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.PublicDiscovery

  @impl Plug
  def init(opts) do
    audience = Keyword.fetch!(opts, :audience)

    unless audience in [:admin, :public] do
      raise ArgumentError,
            "PhoenixKit.API.REST :audience must be :admin or :public, got: #{inspect(audience)}"
    end

    [audience: audience]
  end

  @impl Plug
  def call(conn, opts) do
    audience = Keyword.fetch!(opts, :audience)
    conn = put_cors(conn, audience)
    conn = Auth.call(conn, Auth.init(opts))

    if conn.halted, do: conn, else: dispatch(conn, audience)
  end

  # `openapi.json` is a reserved path: it is the generated description, never a tool.
  defp dispatch(%Plug.Conn{method: "POST", path_info: [tool]} = conn, audience)
       when tool != "openapi.json",
       do: Executor.call(conn, audience, tool, body_input(conn))

  defp dispatch(%Plug.Conn{method: "GET", path_info: []} = conn, :public),
    do: conn |> PublicDiscovery.put_list_links() |> Executor.list(:public)

  defp dispatch(%Plug.Conn{method: "GET", path_info: []} = conn, audience),
    do: Executor.list(conn, audience)

  defp dispatch(%Plug.Conn{method: "GET", path_info: ["openapi.json"]} = conn, audience),
    do: OpenAPI.respond(conn, audience)

  defp dispatch(%Plug.Conn{method: "OPTIONS", path_info: path} = conn, :public)
       when path == [] or length(path) == 1,
       do: preflight(conn)

  defp dispatch(%Plug.Conn{path_info: []} = conn, _audience), do: not_allowed(conn, "GET")

  defp dispatch(%Plug.Conn{path_info: ["openapi.json"]} = conn, _audience),
    do: not_allowed(conn, "GET")

  defp dispatch(%Plug.Conn{path_info: [_tool]} = conn, _audience), do: not_allowed(conn, "POST")

  defp dispatch(conn, _audience) do
    Problem.send(conn, :not_found, "No such API path.", %{})
  end

  defp body_input(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_input(%Plug.Conn{body_params: params}), do: params

  defp not_allowed(conn, allowed) do
    conn
    |> put_resp_header("allow", allowed)
    |> Problem.send(:method_not_allowed, "This path accepts #{allowed} only.", %{allow: allowed})
  end

  defp put_cors(conn, :public), do: put_public_cors(conn)
  defp put_cors(conn, :admin), do: conn

  @doc false
  # The CORS headers of every answer of the public audience, shared with
  # `PhoenixKit.API.BodyGuard`, which answers before this plug runs.
  @spec put_public_cors(Plug.Conn.t()) :: Plug.Conn.t()
  def put_public_cors(conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-expose-headers", @exposed_headers)
  end

  defp preflight(conn) do
    conn
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, idempotency-key")
    |> put_resp_header("access-control-max-age", "86400")
    |> send_resp(204, "")
    |> halt()
  end
end
