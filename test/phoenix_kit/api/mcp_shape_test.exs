defmodule PhoenixKit.API.MCP.ShapeTest do
  @moduledoc """
  How a tool, a result and an error look on MCP, and the output schema both
  MCP and OpenAPI use. The server info reads the project title, so this is a
  database test.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.MCP.Shape
  alias PhoenixKit.API.OutputShape
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.ToolLint
  alias PhoenixKit.API.Validator

  @new "2025-06-18"
  @old "2025-03-26"

  @output %{"type" => "object", "properties" => %{"a" => %{"type" => "string"}}}

  defp tool(attrs \\ []) do
    Tool.new!(
      Keyword.merge(
        [
          name: "demo.list_things",
          audience: :admin,
          scope: "demo.things:read",
          permission: "dashboard",
          title: "List things",
          description: "Lists the things.",
          input_schema: %{
            "type" => "object",
            "properties" => %{"limit" => %{"type" => "integer", "minimum" => 1}}
          },
          output_schema: @output,
          handler: {Kernel, :inspect},
          annotations: %{read_only: true, idempotent: true}
        ],
        attrs
      )
    )
  end

  defp write_tool(attrs \\ []),
    do: tool(Keyword.merge([name: "demo.set_things", annotations: %{destructive: true}], attrs))

  describe "OutputShape" do
    test "a read-only tool's output schema is its own, with a root type" do
      assert OutputShape.for_tool(tool()) == @output

      assert %{"type" => "object"} =
               OutputShape.for_tool(tool(output_schema: %{"properties" => %{}}))
    end

    test "any other tool's is the success shape or a preview" do
      assert %{"type" => "object", "anyOf" => [@output, preview]} =
               OutputShape.for_tool(write_tool())

      assert preview == OutputShape.preview_shape()
    end

    test "the preview alternative is there exactly for the tools ControlFields calls write tools" do
      for annotations <- [
            %{},
            %{read_only: false},
            %{read_only: true},
            %{destructive: true},
            %{read_only: true, idempotent: true}
          ] do
        tool = tool(annotations: annotations)

        assert match?(%{"anyOf" => _}, OutputShape.for_tool(tool)) ==
                 ControlFields.write_tool?(tool),
               inspect(annotations)
      end
    end

    test "the preview shape accepts the three answers: a dry run, a confirmation request and a pending approval" do
      schema = OutputShape.preview_shape()

      dry_run = %{"executed" => false, "dry_run" => true, "preview" => %{"rows" => []}}

      confirmation = %{
        "executed" => false,
        "status" => "confirmation_required",
        "preview" => %{"rows" => []},
        "confirm_token" => "ct_abc",
        "expires_at" => "2026-10-11T12:00:00Z",
        "expires_in_seconds" => 120
      }

      pending = %{
        "executed" => false,
        "status" => "pending_approval",
        "approval_id" => "0b5f3c8e-0000-4000-8000-000000000000",
        "preview" => %{"rows" => []},
        "expires_at" => "2026-10-11T12:00:00Z",
        "expires_in_seconds" => 259_200
      }

      for answer <- [dry_run, confirmation, pending] do
        assert {:ok, _} = Validator.validate(schema, answer), inspect(answer)
      end

      assert {:error, _} = Validator.validate(schema, Map.put(confirmation, "status", "executed"))
      assert {:error, _} = Validator.validate(schema, Map.put(dry_run, "executed", true))
    end

    test "no output schema, no shape" do
      assert OutputShape.for_tool(tool(output_schema: nil)) == nil
      assert OutputShape.for_tool(write_tool(output_schema: nil)) == nil
    end

    test "atom keys come out as strings" do
      shape =
        OutputShape.for_tool(
          tool(output_schema: %{type: "object", properties: %{a: %{type: "string"}}})
        )

      assert shape == @output
    end

    test "atom keys inside a list come out as strings too" do
      schema = %{
        type: "object",
        properties: %{
          a: %{
            type: "object",
            anyOf: [%{properties: %{b: %{type: "string"}}}, %{required: ["b"]}]
          }
        }
      }

      assert %{
               "properties" => %{
                 "a" => %{
                   "anyOf" => [
                     %{"properties" => %{"b" => %{"type" => "string"}}},
                     %{"required" => ["b"]}
                   ]
                 }
               }
             } = OutputShape.for_tool(tool(output_schema: schema))
    end

    test "the root of the output schema is an object even when the tool declares another type" do
      assert %{"type" => "object"} =
               OutputShape.for_tool(tool(output_schema: %{"type" => "array"}))

      assert %{"anyOf" => [%{"type" => "object"}, _]} =
               OutputShape.for_tool(write_tool(output_schema: %{"type" => "array"}))
    end

    test "the preview shape is the documented vocabulary and a valid output schema" do
      preview = OutputShape.preview_shape()

      assert preview["required"] == ["executed"]
      assert preview["properties"]["executed"]["enum"] == [false]

      for key <-
            ~w(preview confirm_token expires_at expires_in_seconds approval_id status dry_run) do
        assert Map.has_key?(preview["properties"], key), key
      end

      assert preview["properties"]["status"]["enum"] == [
               "confirmation_required",
               "pending_approval"
             ]

      assert :ok = ToolLint.check_schema(preview, :output)
      assert :ok = ToolLint.check_schema(OutputShape.for_tool(write_tool()), :output)
    end
  end

  describe "structured?/1" do
    test "from 2025-06-18 on" do
      refute Shape.structured?("2025-03-26")
      assert Shape.structured?("2025-06-18")
      assert Shape.structured?("2025-11-25")
    end
  end

  describe "tool_descriptor/2" do
    test "name with underscores, description, the closed input schema, the hints" do
      descriptor = Shape.tool_descriptor(tool(), @new)

      assert descriptor["name"] == "demo_list_things"
      assert descriptor["description"] == "Lists the things."
      assert descriptor["title"] == "List things"
      assert descriptor["inputSchema"] == Executor.input_schema(tool())
      assert descriptor["inputSchema"]["additionalProperties"] == false

      assert descriptor["annotations"] == %{
               "readOnlyHint" => true,
               "destructiveHint" => false,
               "idempotentHint" => true,
               "openWorldHint" => false
             }
    end

    test "each hint follows its own annotation, never a neighbour's" do
      all_off = %{
        "readOnlyHint" => false,
        "destructiveHint" => false,
        "idempotentHint" => false,
        "openWorldHint" => false
      }

      for {annotation, hint} <- [
            read_only: "readOnlyHint",
            destructive: "destructiveHint",
            idempotent: "idempotentHint",
            open_world: "openWorldHint"
          ] do
        descriptor = Shape.tool_descriptor(tool(annotations: %{annotation => true}), @new)

        assert descriptor["annotations"] == Map.put(all_off, hint, true), "#{annotation}"
      end
    end

    test "a write tool's hints and output schema" do
      descriptor =
        Shape.tool_descriptor(
          write_tool(annotations: %{destructive: true, open_world: true}),
          @new
        )

      assert descriptor["annotations"]["readOnlyHint"] == false
      assert descriptor["annotations"]["destructiveHint"] == true
      assert descriptor["annotations"]["openWorldHint"] == true
      assert %{"type" => "object", "anyOf" => [_, _]} = descriptor["outputSchema"]
    end

    test "an older revision gets no title and no outputSchema" do
      descriptor = Shape.tool_descriptor(tool(), @old)

      assert Map.keys(descriptor) |> Enum.sort() == [
               "annotations",
               "description",
               "inputSchema",
               "name"
             ]
    end

    test "a tool without an output schema has no outputSchema" do
      refute Map.has_key?(Shape.tool_descriptor(tool(output_schema: nil), @new), "outputSchema")
    end

    test "a schema without a root type is sent as an object: MCP requires it and one bad entry can break the whole list" do
      typeless = tool(input_schema: %{"properties" => %{"limit" => %{"type" => "integer"}}})
      refute Map.has_key?(typeless.input_schema, "type")

      descriptor = Shape.tool_descriptor(typeless, @new)

      assert descriptor["inputSchema"]["type"] == "object"
      assert descriptor["inputSchema"]["additionalProperties"] == false
      assert descriptor["inputSchema"]["properties"] == typeless.input_schema["properties"]
    end

    test "the root of the input schema is an object even when the tool declares another type" do
      array_root = tool(input_schema: %{"type" => "array", "items" => %{"type" => "string"}})

      assert Shape.tool_descriptor(array_root, @new)["inputSchema"]["type"] == "object"
    end

    test "the input schema is closed even when the tool's own is open" do
      open = tool(input_schema: %{"type" => "object", "properties" => %{}})
      refute Map.has_key?(open.input_schema, "additionalProperties")

      assert Shape.tool_descriptor(open, @new)["inputSchema"]["additionalProperties"] == false
    end

    test "is JSON and passes the schema lint" do
      for t <- [tool(), write_tool()] do
        descriptor = Shape.tool_descriptor(t, @new)

        assert is_binary(JSON.encode!(descriptor))
        assert :ok = ToolLint.check_schema(descriptor["inputSchema"], :input)
        assert :ok = ToolLint.check_schema(descriptor["outputSchema"], :output)
      end
    end
  end

  describe "call_result/3: success" do
    @result %{"limit" => 3, "effects" => [%{"code" => "x"}]}
    @ok {:ok, %{result: @result, json: ~s({"limit":3,"effects":[{"code":"x"}]})}, []}

    test "the text content is the JSON and the structured content the map" do
      assert %{
               "isError" => false,
               "content" => [%{"type" => "text", "text" => text}],
               "structuredContent" => @result
             } = Shape.call_result(@ok, @new, "req-1")

      assert JSON.decode!(text) == @result
    end

    test "an older revision gets the text only" do
      result = Shape.call_result(@ok, @old, "req-1")

      refute Map.has_key?(result, "structuredContent")
      assert result["isError"] == false
    end
  end

  describe "call_result/3: errors" do
    @error {:error, :validation_failed, "The input does not match the schema of demo.set_things.",
            %{errors: [%{path: "limit", message: "must be at least 1", limit: 1, allowed: nil}]},
            []}

    test "two text items: the line to read and the problem document; no structured content" do
      result = Shape.call_result(@error, @new, "req-9")

      assert result["isError"] == true
      refute Map.has_key?(result, "structuredContent")

      assert [%{"type" => "text", "text" => line}, %{"type" => "text", "text" => json}] =
               result["content"]

      assert String.starts_with?(
               line,
               "[validation_failed] The input does not match the schema of demo.set_things. - "
             )

      assert line =~ "context.errors"

      assert %{
               "code" => "validation_failed",
               "status" => 422,
               "request_id" => "req-9",
               "context" => %{"errors" => [%{"path" => "limit", "limit" => 1}]}
             } = JSON.decode!(json)
    end

    test "the same for the older revision: errors never had structured content" do
      assert Shape.call_result(@error, @old, nil)["isError"] == true
    end

    test "a context JSON cannot carry does not turn the error into a crash" do
      error = {:error, :internal_error, "Failed.", %{oops: {:a, :tuple}}, []}

      assert %{"content" => [_, %{"text" => json}]} = Shape.call_result(error, @new, nil)
      assert %{"code" => "internal_error", "context" => %{}} = JSON.decode!(json)
    end

    test "a request id of nil leaves the member out" do
      %{"content" => [_, %{"text" => json}]} = Shape.call_result(@error, @new, nil)
      refute Map.has_key?(JSON.decode!(json), "request_id")
    end
  end

  describe "advice/1" do
    test "every error code has its own sentence" do
      default = Shape.advice(:some_code_nobody_knows)

      for code <- Map.keys(Problem.statuses()) do
        advice = Shape.advice(code)
        assert is_binary(advice) and advice != "", "#{code}"
        assert advice != default, "#{code} has only the default advice"
      end
    end

    test "an unknown code gets a sentence too" do
      assert Shape.advice(:some_code_nobody_knows) =~ "problem document"
    end
  end

  describe "server_info/2 and instructions/1" do
    test "the title is the project title and the side" do
      KeyTestSupport.start_cache_registry!()
      KeyTestSupport.put_setting("project_title", "Acme Print")

      assert Shape.server_info(:admin, @new)["title"] == "Acme Print admin API"
      assert Shape.server_info(:public, @new)["title"] == "Acme Print public API"
    end

    test "the admin side" do
      info = Shape.server_info(:admin, @new)

      assert info["name"] == "phoenix_kit"
      assert info["version"] == PhoenixKit.version()
      assert info["title"] =~ "admin API"
      assert Shape.instructions(:admin) =~ "system_get_identity"
    end

    test "the admin instructions name the control fields of a write tool in one sentence" do
      sentence =
        :admin
        |> Shape.instructions()
        |> String.split(~r/(?<=\.) /)
        |> Enum.find(&(&1 =~ "dry_run"))

      assert sentence =~ "confirm_token"
      assert sentence =~ "idempotency_key"
    end

    test "the admin instructions open with the one sentence on approval_pending, then identity" do
      instructions = Shape.instructions(:admin)

      assert String.starts_with?(
               instructions,
               "If calls answer approval_pending, the connection is not approved yet: see the advice in that answer. Call system_get_identity first"
             )
    end

    test "the advice of approval_pending names where an owner approves and that no reconnecting is needed" do
      advice = Shape.advice(:approval_pending)

      assert advice =~ "waiting for approval by an Owner"
      assert advice =~ "Sign-in (OAuth)"
      assert advice =~ "Waiting for approval"
      assert advice =~ "no need to connect again"
    end

    test "the public side" do
      info = Shape.server_info(:public, @new)

      assert info["title"] =~ "public API"
      refute Shape.instructions(:public) =~ "system_get_identity"
      assert Shape.instructions(:public) != ""
    end

    test "the public instructions are pinned: no key, the domain's language and currency, the error code" do
      assert Shape.instructions(:public) ==
               "This endpoint needs no key. List the tools with tools/list. Answers follow the language " <>
                 "and currency of the domain you call, unless a tool takes a language or currency field and " <>
                 "the call sets it. A failed call of a tool comes back as a result with isError set (an " <>
                 "unknown tool name is a JSON-RPC error, -32602); the code in square brackets is stable and " <>
                 "the second text item is the full problem document."
    end

    test "the public instructions name no URL, no admin tool and no approval" do
      instructions = Shape.instructions(:public)

      refute instructions =~ "http"
      refute instructions =~ ~r/approval|admin|Bearer|scope/i
    end

    test "an older revision gets no title" do
      refute Map.has_key?(Shape.server_info(:admin, @old), "title")
      assert Shape.server_info(:admin, @old)["name"] == "phoenix_kit"
    end
  end
end
