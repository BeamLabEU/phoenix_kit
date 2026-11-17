defmodule PhoenixKit.API.MCP.Shape do
  @moduledoc """
  How tools, results and errors look on MCP.

  The `version` argument is the protocol revision of the request
  (`MCP-Protocol-Version`, `2025-03-26` when the header is absent). What a
  revision gets is its profile in `PhoenixKit.API.MCP.Versions`: `title`,
  `outputSchema` and `structuredContent` exist from `2025-06-18` on, and a
  client of the older revision gets text only.

  The root of `inputSchema` and `outputSchema` is always sent as an object
  (MCP requires it and the executor accepts only an object); the rest of a
  schema is passed through as declared and `PhoenixKit.API.ToolLint` is what
  checks that it is sound.
  """

  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.MCP.Names
  alias PhoenixKit.API.MCP.Versions
  alias PhoenixKit.API.OutputShape
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.Tool
  alias PhoenixKit.Settings

  @advice %{
    unauthorized:
      "Check that the API key is correct, active and sent in the Authorization header.",
    forbidden:
      "The key lacks the scope in context.required_scope, or its owner lacks the permission; ask an administrator.",
    ip_not_allowed: "Call from an address the key allows.",
    approval_pending:
      "This connection is waiting for approval by an Owner of this site (Settings -> API, tab \"Sign-in (OAuth)\", block \"Waiting for approval\"). Tell the person; calls work right after the approval, there is no need to connect again.",
    origin_not_allowed:
      "Call from a client that sends no Origin header, or ask an administrator to allow the origin.",
    token_in_url:
      "Send credentials in the Authorization header (admin) or the request body (client tokens), never in the URL.",
    invalid_json: "Send a valid JSON body.",
    not_found: "Check the tool name or the id with tools/list and try again.",
    module_disabled:
      "The module behind this tool is switched off; use another tool or ask an administrator to enable it.",
    module_write_disabled:
      "Writes of this module are off for a person's session; ask an administrator to let the agent act in Settings -> API.",
    method_not_allowed: "Use the method named in the Allow header.",
    not_acceptable:
      "Ask for text/html or text/markdown, or use the endpoint named in the detail.",
    confirm_token_invalid:
      "Repeat the call without the confirmation token to get a fresh preview.",
    revision_mismatch: "Read the current state, then repeat the change on top of it.",
    idempotency_key_reused: "Use a new idempotency key for a different request.",
    idempotency_in_progress: "Wait a moment and repeat the same request.",
    payload_too_large: "Send fewer rows per call.",
    validation_failed: "Fix the fields listed in context.errors and call again.",
    rate_limited: "Wait the number of seconds in context.retry_after, then repeat.",
    internal_error: "The tool failed; repeat once, then report the request_id."
  }

  @default_advice "Read the problem document below."

  @doc """
  Whether a client of revision `version` understands `structuredContent`
  (the `:structured_content` flag of its profile).
  """
  @spec structured?(String.t()) :: boolean()
  def structured?(version) when is_binary(version),
    do: Versions.feature?(version, :structured_content)

  @doc "The MCP descriptor of `tool` for a client of revision `version`."
  @spec tool_descriptor(Tool.t(), String.t()) :: map()
  def tool_descriptor(%Tool{} = tool, version) when is_binary(version) do
    base = %{
      "name" => Names.to_mcp(tool.name),
      "description" => tool.description,
      "inputSchema" => tool |> Executor.input_schema() |> Map.put("type", "object"),
      "annotations" => annotations(tool)
    }

    base
    |> put_title(tool, version)
    |> put_output_schema(tool, version)
  end

  defp put_title(descriptor, tool, version) do
    if Versions.feature?(version, :tool_title),
      do: Map.put(descriptor, "title", tool.title),
      else: descriptor
  end

  defp put_output_schema(descriptor, tool, version) do
    with true <- Versions.feature?(version, :output_schema),
         schema when not is_nil(schema) <- OutputShape.for_tool(tool) do
      Map.put(descriptor, "outputSchema", schema)
    else
      _no_schema -> descriptor
    end
  end

  defp annotations(%Tool{annotations: annotations}) do
    %{
      "readOnlyHint" => flag(annotations, :read_only),
      "destructiveHint" => flag(annotations, :destructive),
      "idempotentHint" => flag(annotations, :idempotent),
      "openWorldHint" => flag(annotations, :open_world)
    }
  end

  defp flag(annotations, key), do: Map.get(annotations, key, false) == true

  @doc """
  The `result` of a `tools/call` for an executor `outcome`.

  Success: the JSON as text and, for a revision with `:structured_content`, the
  map as `structuredContent`. Error: `isError: true`, a line `[code] message - what
  to do next` and the problem document as JSON text, no `structuredContent`.
  """
  @spec call_result(Executor.outcome(), String.t(), String.t() | nil) :: map()
  def call_result({:ok, %{result: result, json: json}, _headers}, version, _request_id) do
    base = %{"content" => [%{"type" => "text", "text" => json}], "isError" => false}

    if structured?(version), do: Map.put(base, "structuredContent", result), else: base
  end

  def call_result({:error, code, detail, context, _headers}, _version, request_id) do
    %{
      "content" => [
        %{"type" => "text", "text" => "[#{code}] #{detail} - #{advice(code)}"},
        %{"type" => "text", "text" => problem_json(code, detail, context, request_id)}
      ],
      "isError" => true
    }
  end

  @doc """
  What to do next after an error `code`, one sentence for an agent.

  Core's codes have it here; any other code takes the `advice` of the enabled module that
  declares it (`c:PhoenixKit.Module.api_problems/0`) and a
  code with none gets a pointer to the problem document.
  """
  @spec advice(atom()) :: String.t()
  def advice(code) do
    case Map.fetch(@advice, code) do
      {:ok, advice} -> advice
      :error -> declared_advice(code)
    end
  end

  defp declared_advice(code) do
    case Problem.declared(code) do
      %{advice: advice} when is_binary(advice) -> advice
      _no_advice -> @default_advice
    end
  end

  defp problem_json(code, detail, context, request_id),
    do: code |> Problem.body(detail, context, request_id) |> Problem.encode()

  @doc "The `serverInfo` of the `initialize` answer."
  @spec server_info(Tool.audience(), String.t()) :: map()
  def server_info(audience, version) do
    base = %{"name" => "phoenix_kit", "version" => PhoenixKit.version()}

    if Versions.feature?(version, :server_title),
      do: Map.put(base, "title", Settings.get_project_title() <> side(audience)),
      else: base
  end

  defp side(:admin), do: " admin API"
  defp side(:public), do: " public API"

  @doc "The `instructions` of the `initialize` answer."
  @spec instructions(Tool.audience()) :: String.t()
  def instructions(:admin) do
    "If calls answer approval_pending, the connection is not approved yet: see the advice in that answer. " <>
      "Call system_get_identity first: it lists the scopes this key holds right now and the tools they unlock. " <>
      "A failed call of a tool comes back as a result with isError set (an unknown tool name is a JSON-RPC error, -32602); the code in square brackets is stable and " <>
      "the second text item is the full problem document. A write call from a key that needs approval " <>
      "(other than a dry run) is not run, dangerous or not: it comes back as a normal result with executed false, status pending_approval and an " <>
      "approval_id, and runs only when an owner approves it; while that approval is still waiting, asking " <>
      "again for the same operation returns the same approval_id, unless the values it touches changed " <>
      "meanwhile (the waiting approval is then closed and a new one is queued). A write tool also takes " <>
      "dry_run to preview without changing anything, confirm_token to confirm a dangerous operation with " <>
      "the code its preview returned, and idempotency_key to make a retry safe."
  end

  def instructions(:public) do
    "This endpoint needs no key. List the tools with tools/list. Answers follow the language and currency " <>
      "of the domain you call, unless a tool takes a language or currency field and the call sets it. " <>
      "A failed call of a tool comes back as a result with isError set (an unknown tool name is a JSON-RPC " <>
      "error, -32602); the code in square brackets is stable and the second text item is the full problem " <>
      "document."
  end
end
