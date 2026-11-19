defmodule PhoenixKit.API.OpenAPI do
  @moduledoc """
  The OpenAPI 3.1 document of the machine API, generated from the tool registry.

  `GET /api/admin/v1/openapi.json` and `GET /api/public/v1/openapi.json` serve
  it (`PhoenixKit.API.REST`). An agent or a client generator reads it to learn
  every tool, its input and output schemas and the error format.

    * every tool is `POST /<tool name>` (the dot is part of the path);
      `operationId` is that same dotted name;
    * `x-agent-safety` is `read` for a read-only tool, `destructive` for one
      whose `annotations.destructive` is set, else `write` (`irreversible` does
      not occur in v1); `x-idempotent` is `annotations.idempotent`;
      `x-required-scope` is the scope an admin tool needs;
    * the request body schema is `PhoenixKit.API.Executor.input_schema/1`, the
      schema the validator enforces; the `200` schema is
      `PhoenixKit.API.OutputShape.for_tool/1`, the same as MCP's
      `outputSchema` (a write tool may answer with a preview instead);
    * a write tool (`PhoenixKit.API.ControlFields.write_tool?/1`) that can replay
      (`PhoenixKit.API.ControlFields.replay_tool?/1`) also takes the
      optional `Idempotency-Key` request header, can answer with the
      `Idempotent-Replayed` header on a replay (for the admin API also on the
      held answer of an operation that already waits for approval), and lists
      `409` (a confirmation code that is not valid, an idempotency key reused
      for another request or still in progress);
    * errors are RFC 9457 `application/problem+json`, defined once in
      `components.schemas.Problem`.

  `build/3` is pure. `respond/2` builds the document for the tools the caller
  may use (a key sees only what its effective scopes unlock; a module that is
  switched off is absent) and sends it.
  """

  import Plug.Conn

  require Logger

  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.LogSafe
  alias PhoenixKit.API.OutputShape
  alias PhoenixKit.API.Paths
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.RequestContext
  alias PhoenixKit.API.Tool
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # {status, response name in components, description}
  @statuses [
    {"400", "BadRequest", "The body is not valid JSON, or a credential was sent in the URL."},
    {"401", "Unauthorized",
     "The key is missing, invalid, revoked or expired, or its owner is no longer active."},
    {"403", "Forbidden",
     "The key lacks the scope (context.required_scope), or comes from an address it does not allow."},
    {"404", "NotFound",
     "Unknown tool, a row that does not exist, a disabled module, or the API is switched off."},
    {"413", "PayloadTooLarge", "The request body is larger than 2 MB."},
    {"422", "ValidationFailed",
     "The input does not match the schema (context.errors), or a business rule refused it."},
    {"429", "RateLimited", "Too many requests; wait Retry-After seconds."},
    {"500", "InternalError", "The tool failed unexpectedly; report the request_id."}
  ]

  @conflict {"409", "Conflict",
             "The confirm_token is not valid (context.reason), the Idempotency-Key was used for " <>
               "another request, or the request with this key is still running."}

  @doc """
  Builds the document for `tools` (the tools of one `audience`).

  Options: `:server_url` (the REST base URL, required), `:title` (required),
  `:version` (the version of the API description, default `"1"`).
  """
  @spec build([Tool.t()], Tool.audience(), keyword()) :: map()
  def build(tools, audience, opts) when is_list(tools) and audience in [:admin, :public] do
    server_url = Keyword.fetch!(opts, :server_url)
    title = Keyword.fetch!(opts, :title)
    version = Keyword.get(opts, :version, "1")

    document = %{
      "openapi" => "3.1.0",
      "info" => %{"title" => title, "version" => version, "description" => description(audience)},
      "servers" => [%{"url" => server_url}],
      "tags" => tags(tools),
      "paths" => paths(tools, audience),
      "components" => components(audience)
    }

    if audience == :admin,
      do: Map.put(document, "security", [%{"bearerAuth" => []}]),
      else: document
  end

  @doc """
  Sends the document for the tools the caller may use. Costs one rate-limit
  unit, like the discovery list; answers the executor's error otherwise.
  """
  @spec respond(Plug.Conn.t(), Tool.audience()) :: Plug.Conn.t()
  def respond(conn, audience) do
    case Executor.visible(conn, audience) do
      {:ok, tools, headers} ->
        send_document(conn, audience, tools, headers)

      {:error, code, detail, context, headers} ->
        conn |> put_headers(headers) |> Problem.send(code, detail, context)
    end
  end

  defp send_document(conn, audience, tools, headers) do
    context = RequestContext.resolve(conn)

    document =
      build(tools, audience,
        server_url: context.base_url <> Routes.path(base_path(audience)),
        title: Settings.get_project_title() <> side(audience)
      )

    conn
    |> put_headers(headers)
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, JSON.encode!(document))
  rescue
    error ->
      # The class only: a message may embed values from a request or a tool.
      Logger.error(
        "[PhoenixKit.API] the OpenAPI document could not be built " <>
          "(request #{conn.assigns[:phoenix_kit_api_request_id]}): #{LogSafe.exception_label(error)}"
      )

      Problem.send(conn, :internal_error, "The document could not be built.", %{})
  end

  defp base_path(audience), do: Paths.rest_path(audience)

  defp side(:admin), do: " admin API"
  defp side(:public), do: " public API"

  defp description(:admin) do
    "Admin tools of this site. Every call is POST /<tool> with a JSON object; send the API key as " <>
      "Authorization: Bearer. " <>
      json_body_text() <>
      " A write call from a key that needs approval (other than a dry run) is not run, dangerous or " <>
      "not: it is answered with HTTP 200 " <>
      "and executed: false, status: pending_approval, an approval_id and a preview, and runs only " <>
      "when an owner approves it. While that approval is still waiting, asking again for the same " <>
      "operation (with or without an Idempotency-Key) answers with the same approval_id and the " <>
      "Idempotent-Replayed header, unless the values it touches changed meanwhile: the waiting approval is " <>
      "then closed and a new one (another approval_id) is queued. " <>
      "Errors are application/problem+json."
  end

  defp description(:public) do
    "Public tools of this site. Every call is POST /<tool> with a JSON object; no key is needed. " <>
      json_body_text() <> " Errors are application/problem+json."
  end

  defp json_body_text do
    "The request body is always read as JSON, whatever its Content-Type says."
  end

  # --- tags and paths -----------------------------------------------------------

  defp tags(tools) do
    namespaces = tools |> Enum.map(&namespace/1) |> Enum.uniq() |> Enum.sort()

    [
      %{"name" => "discovery", "description" => "Which tools exist."}
      | Enum.map(namespaces, &%{"name" => &1})
    ]
  end

  defp namespace(%Tool{name: name}), do: name |> String.split(".", parts: 2) |> hd()

  defp paths(tools, audience) do
    tools
    |> Map.new(fn tool -> {"/" <> tool.name, %{"post" => operation(tool, audience)}} end)
    |> Map.put("/", %{"get" => list_operation(audience)})
  end

  defp operation(%Tool{} = tool, audience) do
    operation = %{
      "operationId" => tool.name,
      "summary" => tool.title,
      "description" => tool.description,
      "tags" => [namespace(tool)],
      "x-agent-safety" => safety(tool),
      "x-idempotent" => flag(tool, :idempotent),
      "requestBody" => request_body(tool),
      "responses" => Map.put(error_responses(audience), "200", ok_response(tool))
    }

    operation
    |> put_write_extras(tool)
    |> put_scope(tool)
  end

  defp put_scope(operation, %Tool{scope: nil}), do: operation

  defp put_scope(operation, %Tool{scope: scope}),
    do: Map.put(operation, "x-required-scope", scope)

  # The control fields of a write tool: the header form of `idempotency_key`, the replay
  # header and the conflicts the flow answers (a read tool has none of them; a tool that
  # cannot replay has the conflicts only when a confirmation is possible).
  defp put_write_extras(operation, tool) do
    if ControlFields.write_tool?(tool) do
      operation
      |> put_replay(tool)
      |> put_conflict(tool)
    else
      operation
    end
  end

  # Without a replay the only conflict left is a confirmation code: a tool with a `danger`,
  # and every admin write tool (the batch-size rule).
  defp put_conflict(operation, tool) do
    if ControlFields.replay_tool?(tool) or tool.danger != nil or tool.audience == :admin do
      {status, name, _text} = @conflict
      put_in(operation, ["responses", status], %{"$ref" => "#/components/responses/" <> name})
    else
      operation
    end
  end

  defp put_replay(operation, tool) do
    if ControlFields.replay_tool?(tool) do
      operation
      |> Map.put("parameters", [idempotency_parameter(tool)])
      |> update_in(["responses", "200"], fn ok ->
        Map.put(ok, "headers", %{
          "Idempotent-Replayed" => %{"$ref" => "#/components/headers/IdempotentReplayed"}
        })
      end)
    else
      operation
    end
  end

  defp safety(tool) do
    cond do
      flag(tool, :read_only) -> "read"
      flag(tool, :destructive) -> "destructive"
      true -> "write"
    end
  end

  defp flag(%Tool{annotations: annotations}, key), do: Map.get(annotations, key, false) == true

  defp request_body(tool) do
    # The root is an object on every surface (MCP's inputSchema is forced the same way).
    schema = tool |> Executor.input_schema() |> Map.put_new("type", "object")

    %{
      "required" => match?(%{"required" => [_ | _]}, schema),
      "content" => %{"application/json" => %{"schema" => schema}}
    }
  end

  defp ok_response(tool) do
    schema = OutputShape.for_tool(tool) || %{"type" => "object"}

    %{
      "description" => "The result.",
      "content" => %{"application/json" => %{"schema" => schema}}
    }
  end

  defp list_operation(audience) do
    %{
      "operationId" => "list_tools",
      "summary" => "List the tools",
      "description" => "The tools the caller may use, with their schemas.",
      "tags" => ["discovery"],
      "responses" =>
        Map.put(error_responses(audience), "200", %{
          "description" => "The tools.",
          "content" => %{"application/json" => %{"schema" => list_schema()}}
        })
    }
  end

  defp list_schema do
    %{
      "type" => "object",
      "properties" => %{
        "tools" => %{"type" => "array", "items" => %{"type" => "object"}},
        "count" => %{"type" => "integer"}
      }
    }
  end

  # --- components ---------------------------------------------------------------

  defp statuses(:admin), do: @statuses

  defp statuses(:public),
    do: Enum.reject(@statuses, fn {status, _name, _text} -> status in ["401", "403"] end)

  defp error_responses(audience) do
    Map.new(statuses(audience), fn {status, name, _text} ->
      {status, %{"$ref" => "#/components/responses/" <> name}}
    end)
  end

  defp components(audience) do
    components = %{
      "schemas" => %{"Problem" => problem_schema(audience)},
      "headers" => %{"IdempotentReplayed" => replayed_header(audience)},
      "responses" =>
        Map.new([@conflict | statuses(audience)], fn {_status, name, text} ->
          {name, problem_response(text)}
        end)
    }

    if audience == :admin do
      Map.put(components, "securitySchemes", %{
        "bearerAuth" => %{
          "type" => "http",
          "scheme" => "bearer",
          "bearerFormat" => "pk_<prefix>_<secret>",
          "description" => "An API key from Settings -> API, sent as Authorization: Bearer <key>."
        }
      })
    else
      components
    end
  end

  # The header form of the `idempotency_key` field, with the schema the field has.
  defp idempotency_parameter(tool) do
    %{
      "name" => "Idempotency-Key",
      "in" => "header",
      "required" => false,
      "description" =>
        "Makes a retry of this write safe: the same key and request replay the first answer, " <>
          "unless that answer was not stored (a held, preview or error answer); the key is then free. " <>
          "The same value may be sent as the idempotency_key field instead; both with " <>
          "different values is a 422.",
      "schema" =>
        tool
        |> ControlFields.properties()
        |> Map.fetch!("idempotency_key")
        |> Map.delete("description")
    }
  end

  defp replayed_header(audience) do
    %{
      "description" => replayed_text(audience),
      "schema" => %{"type" => "string", "enum" => ["true"]}
    }
  end

  defp replayed_text(:admin),
    do:
      "true when this is the stored answer of an earlier request with the same key, or the " <>
        "pending_approval answer of an operation that already waits for approval."

  defp replayed_text(:public),
    do: "true when this is the stored answer of an earlier request with the same key."

  defp problem_response(text) do
    %{
      "description" => text,
      "content" => %{
        "application/problem+json" => %{"schema" => %{"$ref" => "#/components/schemas/Problem"}}
      }
    }
  end

  # Codes only an admin key can meet (an OAuth connection that waits for an owner's approval): the
  # public document, served without a key, never names them.
  @admin_only_codes [:approval_pending]

  defp problem_schema(audience) do
    codes =
      Problem.statuses()
      |> Map.keys()
      |> Enum.reject(&(audience == :public and &1 in @admin_only_codes))
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    %{
      "type" => "object",
      "required" => ["type", "title", "status", "code", "detail"],
      "properties" => %{
        "type" => %{"type" => "string", "format" => "uri"},
        "title" => %{"type" => "string"},
        "status" => %{"type" => "integer"},
        "code" => %{"type" => "string", "enum" => codes},
        "detail" => %{"type" => "string"},
        "context" => %{"type" => "object"},
        "request_id" => %{"type" => "string"}
      }
    }
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_resp_header(acc, String.downcase(name), to_string(value))
    end)
  end
end
