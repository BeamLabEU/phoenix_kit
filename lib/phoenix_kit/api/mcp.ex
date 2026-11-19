defmodule PhoenixKit.API.MCP do
  @moduledoc """
  The MCP transport of the machine API: Model Context Protocol over Streamable
  HTTP, tools only, stateless, JSON answers only. A plug that the router
  `forward`s to, once per audience:

      forward "/mcp/admin", PhoenixKit.API.MCP, audience: :admin
      forward "/mcp/public", PhoenixKit.API.MCP, audience: :public

  `phoenix_kit_routes/0` emits both (`PhoenixKit.API.Paths`).

  The admin endpoint takes the same bearer key as the REST API (clients that
  let you set a request header for a remote MCP server can use it); the public
  endpoint needs no key.

  ## What it speaks

  `POST` with one JSON-RPC message per request:

    * `initialize`: the revision is negotiated (`PhoenixKit.API.MCP.Versions`),
      the capabilities are `tools` only;
    * `notifications/*` and responses from the client: `202`, no body, and
      nothing is run, whatever the method;
    * `ping`: `{}`;
    * `tools/list`: the tools the caller may use, with `_` in their names;
    * `tools/call`: runs a tool through `PhoenixKit.API.Executor`. Both name
      forms are accepted. A failure of the tool is a result with `isError`,
      not a JSON-RPC error; an unknown tool name is the JSON-RPC error `-32602`;
    * anything else: JSON-RPC `-32601`.

  `GET`, `DELETE` and every other method are `405` with `Allow: POST`: there
  is no event stream and no session to close. The public endpoint's `405` also
  carries `Link: <guide>; rel="service-doc"` while the guide is published
  (`PhoenixKit.API.PublicDiscovery`). No session id is issued; every
  request carries its own key. No CORS headers are sent.

  ## Protocol revisions

  The revisions it speaks, and what differs between them, are the table of
  `PhoenixKit.API.MCP.Versions`; `config :phoenix_kit, :mcp_protocol_versions`
  narrows or orders them without a code change. No header means `2025-03-26`
  (the MCP rule) while that revision is spoken. An unsupported
  `MCP-Protocol-Version` is HTTP `400` with JSON-RPC `-32600`, whatever
  revision the client speaks; `initialize` answers a revision it does not speak
  with the most preferred one it does.

  ## The order of the checks

  `PhoenixKit.API.Auth` first (API switch, website gate, credential in the
  URL, the `Origin` check of `PhoenixKit.API.MCP.Origin`, key), then the HTTP
  method, `Accept` (must allow `application/json`), the JSON-RPC shape of the
  body (`PhoenixKit.API.MCP.Rpc`), the `MCP-Protocol-Version` header, and
  last the method of the message.

  `initialize`, `ping`, notifications, responses and unknown methods cost one
  rate-limit unit each, so that a flood of cheap messages is throttled like
  any other traffic. So do a `tools/list` and a `tools/call` with invalid
  params. A valid `tools/list` costs one unit through
  `PhoenixKit.API.Executor.visible/2`. A refusal is HTTP `429` with
  `Retry-After`.

  A `tools/call` is priced by the executor. An admin call that the executor
  refuses before its limiter (an unknown, hidden, forbidden or disabled-module
  tool) is charged one unit here; the public audience is charged by the
  executor before the lookup and before the name is mapped from its MCP form
  (`PhoenixKit.API.MCP.Names.resolve/2`). A rate limit is HTTP `429`, a name
  that no tool has (or that the caller's switches hide: `api_disabled_tools`) is
  a JSON-RPC `-32602` error with HTTP `200`, every other failure of the tool is
  an `isError` result.

  Malformed JSON never reaches this plug: `PhoenixKit.API.BodyGuard` answers
  it with a JSON-RPC parse error in the endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.API.MCP.Origin
  alias PhoenixKit.API.MCP.Rpc
  alias PhoenixKit.API.MCP.Shape
  alias PhoenixKit.API.MCP.Versions
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.PublicDiscovery
  alias PhoenixKit.API.RateLimit
  alias PhoenixKit.API.Registry

  @doc "The protocol revisions this server speaks, most preferred first (`PhoenixKit.API.MCP.Versions.supported/0`)."
  @spec supported_versions() :: [String.t()]
  def supported_versions, do: Versions.supported()

  @impl Plug
  def init(opts) do
    audience = Keyword.fetch!(opts, :audience)

    unless audience in [:admin, :public] do
      raise ArgumentError,
            "PhoenixKit.API.MCP :audience must be :admin or :public, got: #{inspect(audience)}"
    end

    [audience: audience]
  end

  @impl Plug
  def call(conn, opts) do
    audience = Keyword.fetch!(opts, :audience)
    # Only the admin endpoint takes OAuth access tokens (`Auth` checks the switch itself).
    auth =
      opts
      |> Keyword.put(:before_auth, {Origin, :check})
      |> Keyword.put(:oauth, audience == :admin)

    conn = Auth.call(conn, Auth.init(auth))

    if conn.halted, do: conn, else: route(conn, audience)
  end

  defp route(%Plug.Conn{path_info: [], method: "POST"} = conn, audience), do: post(conn, audience)
  defp route(%Plug.Conn{path_info: []} = conn, audience), do: method_not_allowed(conn, audience)
  defp route(conn, _audience), do: Problem.send(conn, :not_found, "No such MCP path.", %{})

  # A client that GETs the server URL may be looking for how to connect: the
  # public endpoint points to the guide while the guide is published.
  defp method_not_allowed(conn, audience) do
    conn
    |> put_service_doc(audience)
    |> put_resp_header("allow", "POST")
    |> Problem.send(
      :method_not_allowed,
      "This endpoint accepts POST only: there is no event stream and no session to close.",
      %{allow: "POST"}
    )
  end

  defp put_service_doc(conn, :public), do: PublicDiscovery.put_service_doc_link(conn)
  defp put_service_doc(conn, :admin), do: conn

  # --- one POST ---------------------------------------------------------------

  defp post(conn, audience) do
    with :ok <- accepts_json(conn),
         {:ok, message} <- classify(conn),
         {:ok, version} <- protocol_version(conn, message) do
      dispatch(message, conn, audience, version)
    else
      {:rpc_error, status, id, name, text} -> Rpc.send_error(conn, status, id, name, text)
    end
  rescue
    error ->
      # The class only: a stacktrace holds the call's arguments (the conn and its
      # Authorization header among them) and a message may embed request values.
      Logger.error(
        "[PhoenixKit.API] MCP request failed (request #{conn.assigns[:phoenix_kit_api_request_id]}): " <>
          LogSafe.exception_label(error)
      )

      Problem.send(conn, :internal_error, "The request could not be processed.", %{})
  end

  defp accepts_json(conn) do
    values = get_req_header(conn, "accept")

    if values == [] or Enum.any?(values, &accepts_json_value?/1) do
      :ok
    else
      {:rpc_error, 406, nil, :invalid_request, "The Accept header must allow application/json."}
    end
  end

  defp accepts_json_value?(value) do
    String.trim(value) == "" or
      value
      |> String.split(",")
      |> Enum.map(fn range ->
        range |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      end)
      |> Enum.any?(&(&1 in ["*/*", "application/*", "application/json"]))
  end

  defp classify(conn) do
    case Rpc.classify(conn.body_params) do
      {:invalid, id, text} -> {:rpc_error, 400, id, :invalid_request, text}
      message -> {:ok, message}
    end
  end

  defp protocol_version(conn, message) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        implied(message)

      [version] ->
        cond do
          Versions.supported?(version) -> {:ok, version}
          initialize?(message) -> {:ok, Versions.implied()}
          true -> unsupported(version, message)
        end

      _several ->
        unsupported("(several values)", message)
    end
  end

  # No header means the revision MCP names for that case, if this server still
  # speaks it; `initialize` is the way to learn what it does speak.
  defp implied(message) do
    if Versions.supported?(Versions.implied()) or initialize?(message),
      do: {:ok, Versions.implied()},
      else: {:rpc_error, 400, request_id(message), :invalid_request, missing_text()}
  end

  defp missing_text do
    "The MCP-Protocol-Version header is required: without it a client is taken for " <>
      "#{Versions.implied()}, which this server does not speak. " <>
      "Supported: #{Enum.join(Versions.supported(), ", ")}."
  end

  defp initialize?({:request, _id, "initialize", _params}), do: true
  defp initialize?(_message), do: false

  defp unsupported(given, message) do
    text =
      "Unsupported MCP-Protocol-Version #{inspect(LogSafe.take_codepoints(given, 40))}. " <>
        "Supported: #{Enum.join(Versions.supported(), ", ")}."

    {:rpc_error, 400, request_id(message), :invalid_request, text}
  end

  defp request_id({:request, id, _method, _params}), do: id
  defp request_id(_message), do: nil

  # --- the message ------------------------------------------------------------

  defp dispatch({:notification, _method}, conn, audience, _version),
    do: cheap(conn, audience, &Rpc.accepted/1)

  defp dispatch(:response, conn, audience, _version), do: cheap(conn, audience, &Rpc.accepted/1)

  defp dispatch({:request, id, method, params}, conn, audience, version),
    do: request(method, id, params, conn, audience, version)

  defp request("initialize", id, params, conn, audience, _version),
    do: cheap(conn, audience, &initialize(&1, id, params, audience))

  defp request("ping", id, _params, conn, audience, _version),
    do: cheap(conn, audience, &reply(&1, id, %{}))

  defp request("tools/list", id, params, conn, audience, version) do
    case list_params(params) do
      :ok -> tools_list(conn, id, audience, version)
      {:error, text} -> cheap(conn, audience, &Rpc.send_error(&1, 200, id, :invalid_params, text))
    end
  end

  defp request("tools/call", id, params, conn, audience, version) do
    case call_params(params) do
      {:ok, name, arguments} -> tools_call(conn, id, audience, version, name, arguments)
      {:error, text} -> cheap(conn, audience, &Rpc.send_error(&1, 200, id, :invalid_params, text))
    end
  end

  defp request(method, id, _params, conn, audience, _version) do
    cheap(
      conn,
      audience,
      &Rpc.send_error(
        &1,
        200,
        id,
        :method_not_found,
        "Method not found: #{LogSafe.take_codepoints(method, 80)}."
      )
    )
  end

  defp initialize(conn, id, %{"protocolVersion" => requested}, audience)
       when is_binary(requested) do
    negotiated = Versions.negotiate(requested)

    reply(conn, id, %{
      "protocolVersion" => negotiated,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => Shape.server_info(audience, negotiated),
      "instructions" => Shape.instructions(audience)
    })
  end

  defp initialize(conn, id, _params, _audience),
    do: Rpc.send_error(conn, 200, id, :invalid_params, "initialize needs params.protocolVersion.")

  # The server never issues a cursor, so any cursor is one it did not issue.
  defp list_params(nil), do: :ok

  defp list_params(%{} = params) do
    if Map.get(params, "cursor") == nil,
      do: :ok,
      else: {:error, "Unknown cursor: this server returns every tool in one page."}
  end

  defp list_params(_other), do: {:error, "params must be an object."}

  # `Executor.visible/2` is the list `GET /` shows over REST: the tools whose
  # scope the key holds right now, plus the scope-less ones. It charges one
  # rate-limit unit.
  defp tools_list(conn, id, audience, version) do
    case Executor.visible(conn, audience) do
      {:ok, tools, headers} ->
        descriptors = tools |> Names.dedupe() |> Enum.map(&Shape.tool_descriptor(&1, version))

        conn |> put_headers(headers) |> reply(id, %{"tools" => descriptors})

      {:error, code, detail, context, headers} ->
        conn |> put_headers(headers) |> Problem.send(code, detail, context)
    end
  end

  # `name` is a string; `arguments` is an object, absent or null (both: {}).
  defp call_params(%{"name" => name} = params) when is_binary(name) and name != "" do
    case Map.get(params, "arguments") do
      nil -> {:ok, name, %{}}
      %{} = arguments -> {:ok, name, arguments}
      _other -> {:error, "params.arguments must be an object."}
    end
  end

  defp call_params(_other), do: {:error, "tools/call needs params.name, a tool name."}

  # Runs the tool as REST would. Every error becomes an `isError` result, except
  # a rate limit (HTTP 429, so a client library backs off) and an unknown tool
  # name (JSON-RPC -32602, which every revision in `Versions` prescribes for it).
  defp tools_call(conn, id, audience, version, name, arguments) do
    request_id = conn.assigns[:phoenix_kit_api_request_id]

    # The executor resolves the name itself, after the public charge: an over-limit
    # anonymous caller ends in 429 without a registry walk.
    resolve = &Names.resolve(&1, audience)

    case Executor.execute(conn, audience, name, arguments,
           resolve_name: resolve,
           idempotency_header: false
         ) do
      {:error, :rate_limited, detail, context, headers} ->
        conn |> put_headers(headers) |> Problem.send(:rate_limited, detail, context)

      {:error, :not_found, _detail, %{tool: _clipped}, headers} = outcome ->
        conn = put_headers(conn, headers)

        if unknown_tool?(name, audience),
          do: Rpc.send_error(conn, 200, id, :invalid_params, unknown_tool_text(name)),
          else: reply(conn, id, Shape.call_result(outcome, version, request_id))

      outcome ->
        conn
        |> put_headers(outcome_headers(outcome))
        |> reply(id, Shape.call_result(outcome, version, request_id))
    end
  end

  # A tool can answer `not_found` for its own subject (a missing record), and that stays a
  # tool result. The executor's `not_found` for the tool itself is told apart by asking the
  # registry again, on this failure path only and after the public charge, so the repeat is
  # bounded by the rate limit. The outcome alone cannot tell the two apart (a handler may
  # answer a context with a `tool` key too), and REST pins the executor's context.
  defp unknown_tool?(name, audience),
    do: Registry.find(Names.resolve(name, audience), audience) == {:error, :not_found}

  defp unknown_tool_text(name), do: "Unknown tool: #{LogSafe.take_codepoints(name, 80)}"

  defp outcome_headers({:ok, _result, headers}), do: headers
  defp outcome_headers({:error, _code, _detail, _context, headers}), do: headers

  defp reply(conn, id, result), do: Rpc.send_json(conn, 200, Rpc.result_envelope(id, result))

  # --- the rate limit of the methods that do no executor work -----------------

  defp cheap(conn, audience, fun) do
    case charge(conn, audience) do
      {:ok, headers} -> conn |> put_headers(headers) |> fun.()
      {:error, retry_after, headers} -> rate_limited(conn, retry_after, headers)
    end
  end

  defp charge(conn, :admin),
    do: RateLimit.check_admin(conn.assigns.phoenix_kit_api_actor.key_uuid, 1)

  defp charge(conn, :public),
    do: RateLimit.check_public(conn.assigns.phoenix_kit_api_actor.ip || "unknown", nil, 1)

  defp rate_limited(conn, retry_after, headers) do
    conn
    |> put_headers(headers)
    |> Problem.send(:rate_limited, "Too many requests.", %{retry_after: retry_after})
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_resp_header(acc, String.downcase(name), to_string(value))
    end)
  end
end
