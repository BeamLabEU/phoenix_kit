defmodule PhoenixKit.API.OutputShapeTest do
  @moduledoc """
  The output schema a client is told: a write tool may answer with a preview,
  and the preview of a public tool knows no approval (a document served without
  a key does not mention them).
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.OpenAPI
  alias PhoenixKit.API.OutputShape
  alias PhoenixKit.API.Tool

  @read %{read_only: true, destructive: false, idempotent: true, open_world: false}
  @write %{read_only: false, destructive: false, idempotent: false, open_world: false}

  defp tool(audience, annotations) do
    attrs = [
      name: "shapekit.do_it",
      audience: audience,
      title: "Do it",
      description: "Test tool.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      output_schema: %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}},
      handler: {__MODULE__, :handle},
      annotations: annotations
    ]

    attrs =
      if audience == :admin,
        do: Keyword.merge(attrs, scope: "shapekit.things:write", permission: "settings"),
        else: attrs

    Tool.new!(attrs)
  end

  describe "the preview of an admin write tool" do
    test "may be a pending approval" do
      assert %{"anyOf" => [_success, preview]} = OutputShape.for_tool(tool(:admin, @write))

      assert preview == OutputShape.preview_shape()
      assert preview == OutputShape.preview_shape(:admin)

      assert preview["properties"]["status"]["enum"] == [
               "confirmation_required",
               "pending_approval"
             ]

      assert Map.has_key?(preview["properties"], "approval_id")
      assert preview["description"] =~ "system.get_approval"
    end
  end

  describe "the preview of a public write tool" do
    test "is a dry run or a confirmation, never an approval" do
      assert %{"type" => "object", "anyOf" => [success, preview]} =
               OutputShape.for_tool(tool(:public, @write))

      assert success["properties"] == %{"ok" => %{"type" => "boolean"}}
      assert preview == OutputShape.preview_shape(:public)
      assert preview["required"] == ["executed"]
      assert preview["properties"]["status"]["enum"] == ["confirmation_required"]
      assert preview["properties"]["executed"] == %{"type" => "boolean", "enum" => [false]}
      assert Map.has_key?(preview["properties"], "confirm_token")
      assert Map.has_key?(preview["properties"], "dry_run")
      refute Map.has_key?(preview["properties"], "approval_id")
    end

    test "says nothing of approvals or of the admin tool that polls them" do
      encoded = JSON.encode!(OutputShape.for_tool(tool(:public, @write)))

      refute encoded =~ ~r/approval/i
      refute encoded =~ "system.get_approval"
    end

    test "the public OpenAPI document of a write tool does not name them either" do
      document =
        OpenAPI.build([tool(:public, @write)], :public,
          server_url: "https://shop.test/api/public/v1",
          title: "Public API"
        )

      refute JSON.encode!(document) =~ ~r/approval/i
    end

    test "the admin OpenAPI document still does" do
      document =
        OpenAPI.build([tool(:admin, @write)], :admin,
          server_url: "https://shop.test/api/admin/v1",
          title: "Admin API"
        )

      assert JSON.encode!(document) =~ "pending_approval"
      assert JSON.encode!(document) =~ "approval_pending"
    end
  end

  test "a read tool has no preview in either audience" do
    for audience <- [:admin, :public] do
      assert OutputShape.for_tool(tool(audience, @read)) ==
               %{
                 "type" => "object",
                 "properties" => %{"ok" => %{"type" => "boolean"}}
               }
    end
  end
end
