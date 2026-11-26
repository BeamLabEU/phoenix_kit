defmodule PhoenixKit.API.ToolTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Tool

  @admin_tool [
    name: "catalogue.list_products",
    audience: :admin,
    scope: "catalogue.products:read",
    permission: "catalogue",
    handler: {Kernel, :inspect}
  ]

  @public_tool [name: "shop.search_products", audience: :public, handler: {Kernel, :inspect}]

  describe "new/1" do
    test "builds an admin tool from a keyword list and fills the defaults" do
      assert {:ok, %Tool{} = tool} = Tool.new(@admin_tool)

      assert tool.name == "catalogue.list_products"
      assert tool.audience == :admin
      assert tool.title == "catalogue.list_products"
      assert tool.description == ""
      assert tool.module == nil
      assert tool.danger == nil
      assert tool.max_items == nil
      assert tool.output_schema == nil

      assert tool.input_schema == %{
               "type" => "object",
               "properties" => %{},
               "additionalProperties" => false
             }

      assert tool.annotations == %{
               read_only: false,
               destructive: false,
               idempotent: false,
               open_world: false
             }
    end

    test "a tool replays by default, and replay must be true or false" do
      assert {:ok, %Tool{replay: true}} = Tool.new(@admin_tool)
      assert {:ok, %Tool{replay: false}} = Tool.new(Keyword.put(@admin_tool, :replay, false))

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :replay, "no"))
      assert message == ~s(replay must be true or false, got "no")
    end

    test "accepts a map and merges the annotations it is given over the defaults" do
      attrs = @admin_tool |> Map.new() |> Map.put(:annotations, %{read_only: true})

      assert {:ok, tool} = Tool.new(attrs)
      assert tool.annotations.read_only == true
      assert tool.annotations.destructive == false
    end

    test "a public tool needs neither scope nor permission" do
      assert {:ok, %Tool{audience: :public, scope: nil, permission: nil}} =
               Tool.new(
                 name: "shop.search_products",
                 audience: :public,
                 handler: {Kernel, :inspect}
               )
    end

    test "a core system.* admin tool needs neither scope nor permission" do
      assert {:ok, tool} =
               Tool.new(
                 name: "system.get_identity",
                 audience: :admin,
                 handler: {Kernel, :inspect}
               )

      assert Tool.system?(tool)
    end

    test "an admin tool outside system.* needs a scope and a permission" do
      assert {:error, messages} =
               Tool.new(
                 name: "catalogue.list_products",
                 audience: :admin,
                 handler: {Kernel, :inspect}
               )

      assert "scope is required for an admin tool" in messages
      assert "permission is required for an admin tool" in messages
    end

    # An undotted name (`list_products`) is a host tool's name now: see tool_aliases_test.exs.
    test "rejects a name that is neither namespace.verb_noun nor an undotted name" do
      bad_names = [
        "list products",
        "Catalogue.list",
        "catalogue.List",
        "a.b.c",
        "",
        nil,
        :atom,
        "catalogue.list_products\n"
      ]

      for bad <- bad_names do
        assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :name, bad))
        assert message =~ "name must look like"
      end
    end

    test "rejects a name over 100 characters and accepts one of exactly 100" do
      name = fn size -> "shop." <> String.duplicate("a", size - 5) end

      assert {:ok, _tool} = Tool.new(Keyword.put(@admin_tool, :name, name.(100)))

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :name, name.(101)))
      assert message =~ "name must be at most 100 characters"
    end

    test "rejects an unknown audience and a malformed handler" do
      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :audience, :private))
      assert message =~ "audience must be :admin or :public"

      for bad <- [nil, Kernel, {Kernel, "inspect"}, {nil, :inspect}, {Kernel, nil}] do
        assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :handler, bad))
        assert message =~ "handler must be {module, function}"
      end
    end

    test "rejects unknown fields and unknown or non-boolean annotations" do
      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :color, "red"))
      assert message =~ "unknown field(s): :color"

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :annotations, %{fast: true}))
      assert message =~ "unknown annotation(s): :fast"

      assert {:error, [message]} =
               Tool.new(Keyword.put(@admin_tool, :annotations, %{read_only: "yes"}))

      assert message =~ "must be true or false: :read_only"
    end

    test "rejects a bad max_items and a non-map schema" do
      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :max_items, 0))
      assert message =~ "max_items must be a positive integer"

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :input_schema, "object"))
      assert message =~ "input_schema must be a map"

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :output_schema, "object"))
      assert message =~ "output_schema must be a map (JSON Schema) or nil"

      assert {:ok, %Tool{max_items: 50}} = Tool.new(Keyword.put(@admin_tool, :max_items, 50))

      assert {:ok, %Tool{output_schema: %{"type" => "object"}}} =
               Tool.new(Keyword.put(@admin_tool, :output_schema, %{"type" => "object"}))
    end

    test "rejects an input schema the validator would not enforce" do
      schema = %{
        "type" => "object",
        "properties" => %{"price" => %{"type" => "number", "exclusiveMinimum" => 0}}
      }

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :input_schema, schema))
      assert message =~ "input_schema.properties.price.exclusiveMinimum is not supported"

      assert {:error, [message]} =
               Tool.new(Keyword.put(@admin_tool, :input_schema, %{"minLength" => "2"}))

      assert message =~ "input_schema.minLength must be a non-negative integer"

      assert_raise ArgumentError,
                   ~r/input_schema.pattern is not a valid regular expression/,
                   fn ->
                     Tool.new!(Keyword.put(@admin_tool, :input_schema, %{"pattern" => "(x"}))
                   end

      supported = %{
        "type" => "object",
        "properties" => %{
          "price" => %{"type" => "number", "minimum" => 0, "description" => "ok"},
          "id" => %{"type" => "string", "format" => "uuid"}
        }
      }

      assert {:ok, %Tool{}} = Tool.new(Keyword.put(@admin_tool, :input_schema, supported))
    end

    test "rejects a schema JSON cannot encode, input and output" do
      bad = %{"type" => "object", "default" => {:a, 1}}

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :output_schema, bad))
      assert message =~ "output_schema must be JSON-encodable"

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :input_schema, bad))
      assert message =~ "input_schema must be JSON-encodable"

      # The refusal is the same on the second call (the answer is remembered).
      assert {:error, [_]} = Tool.new(Keyword.put(@admin_tool, :output_schema, bad))

      fine = %{"type" => "object", "default" => %{"a" => [1, "x", nil, true]}}
      assert {:ok, %Tool{}} = Tool.new(Keyword.put(@admin_tool, :output_schema, fine))
    end

    test "rejects an input property named after a field the executor adds" do
      # Every control field is reserved, whatever list `ControlFields` holds.
      for name <- ControlFields.names() do
        schema = %{
          "type" => "object",
          "properties" => %{"sku" => %{"type" => "string"}, name => %{"type" => "string"}}
        }

        assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :input_schema, schema))
        assert message =~ "input_schema.properties.#{name} is a field the executor adds itself"

        assert {:error, [message]} = Tool.new(Keyword.put(@public_tool, :input_schema, schema))
        assert message =~ "input_schema.properties.#{name} is a field the executor adds itself"
      end

      atom_keyed = %{"type" => "object", "properties" => %{dry_run: %{"type" => "boolean"}}}
      assert {:error, [_]} = Tool.new(Keyword.put(@admin_tool, :input_schema, atom_keyed))

      # Only a top-level property is reserved; a nested one is the module's own.
      nested = %{
        "type" => "object",
        "properties" => %{
          "filter" => %{
            "type" => "object",
            "properties" => %{"language" => %{"type" => "string"}}
          }
        }
      }

      assert {:ok, %Tool{}} = Tool.new(Keyword.put(@admin_tool, :input_schema, nested))
    end

    test "accepts language and currency as top-level properties of an admin and of a public tool" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "language" => %{"type" => "string"},
          "currency" => %{"type" => "string"}
        }
      }

      for base <- [@admin_tool, @public_tool] do
        assert {:ok, %Tool{input_schema: ^schema}} =
                 Tool.new(Keyword.put(base, :input_schema, schema))
      end

      atom_keyed = %{"type" => "object", "properties" => %{language: %{"type" => "string"}}}
      assert {:ok, %Tool{}} = Tool.new(Keyword.put(@public_tool, :input_schema, atom_keyed))
    end

    test "rejects a title or description that is not a string" do
      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :title, 42))
      assert message =~ "title must be a string, got 42"

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :description, :nope))
      assert message =~ "description must be a string, got :nope"
    end

    test "rejects annotations that are not a map, including a struct" do
      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :annotations, [:read_only]))
      assert message == "annotations must be a map"

      assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :annotations, %URI{}))
      assert message == "annotations must be a map"
    end

    test "an empty or non-string scope or permission is refused" do
      for field <- [:scope, :permission], bad <- ["", :read, 5] do
        assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, field, bad))
        assert message == "#{field} is required for an admin tool"
      end

      for field <- [:scope, :permission], bad <- ["", :read] do
        public = [name: "shop.search_products", audience: :public, handler: {Kernel, :inspect}]

        assert {:error, [message]} = Tool.new(Keyword.put(public, field, bad))
        assert message == "#{field} must be nil for a public tool, got #{inspect(bad)}"
      end
    end

    test "a public tool that names a scope or a permission is refused" do
      public = [name: "shop.search_products", audience: :public, handler: {Kernel, :inspect}]

      assert {:error, [message]} = Tool.new(Keyword.put(public, :scope, "shop.products:read"))
      assert message == ~s(scope must be nil for a public tool, got "shop.products:read")

      assert {:error, [message]} = Tool.new(Keyword.put(public, :permission, "shop"))
      assert message == ~s(permission must be nil for a public tool, got "shop")

      assert {:error, messages} =
               Tool.new(Keyword.merge(public, scope: "shop.products:read", permission: "shop"))

      assert length(messages) == 2

      assert Tool.validate(%Tool{
               name: "shop.search_products",
               audience: :public,
               scope: "x:y",
               handler: {Kernel, :inspect}
             })
             |> elem(0) == :error
    end

    test "reports every problem at once" do
      assert {:error, messages} = Tool.new(name: "B a d", audience: :nobody, handler: :nope)

      assert Enum.any?(messages, &(&1 =~ "name must look like"))
      assert Enum.any?(messages, &(&1 =~ "audience must be :admin or :public"))
      assert Enum.any?(messages, &(&1 =~ "handler must be {module, function}"))
    end

    test "accepts every field of the struct (the accepted keys follow the struct)" do
      assert {:ok, tool} = Tool.new(@admin_tool)

      assert {:ok, ^tool} = tool |> Map.from_struct() |> Tool.new()
    end

    test "refuses attributes that are neither a map nor a keyword list" do
      assert {:error, [_]} = Tool.new([1, 2, 3])
      assert {:error, [_]} = Tool.new("name")
    end
  end

  @token_schema %{
    "type" => "object",
    "properties" => %{"session_token" => %{"type" => "string"}, "n" => %{"type" => "integer"}},
    "additionalProperties" => false
  }

  defp public_with(attrs),
    do: Tool.new(Keyword.merge(@public_tool ++ [input_schema: @token_schema], attrs))

  describe "client_token and credentials" do
    test "default to nil and an empty list" do
      assert {:ok, %Tool{client_token: nil, credentials: []}} = Tool.new(@public_tool)
    end

    test "a public tool may name a string property of its input as the client token" do
      assert {:ok, %Tool{client_token: "session_token"}} =
               public_with(client_token: "session_token")
    end

    test "the client token must be a string property of the input schema" do
      assert {:error, [missing]} = public_with(client_token: "nope")
      assert missing =~ ~s(client_token "nope" must be a string property of input_schema)

      assert {:error, [not_string]} = public_with(client_token: "n")
      assert not_string =~ ~s(client_token "n" must be a string property of input_schema)

      assert {:error, [empty]} = public_with(client_token: "")
      assert empty =~ "client_token must be a non-empty string or nil"

      assert {:error, [wrong]} = public_with(client_token: :session_token)
      assert wrong =~ "client_token must be a non-empty string or nil"
    end

    test "an admin tool may not have a client token" do
      assert {:error, [message]} =
               Tool.new(
                 Keyword.merge(@admin_tool,
                   input_schema: @token_schema,
                   client_token: "session_token"
                 )
               )

      assert message =~ "client_token is for a public tool only"
    end

    test "credentials are a list of non-empty strings" do
      assert {:ok, %Tool{credentials: ["url", "claim"]}} =
               Tool.new(Keyword.put(@admin_tool, :credentials, ["url", "claim"]))

      for bad <- ["url", [""], [:url], [nil], %{}] do
        assert {:error, [message]} = Tool.new(Keyword.put(@admin_tool, :credentials, bad))
        assert message =~ "credentials must be a list of non-empty strings"
      end
    end

    test "credential_keys/1 lists the credentials and the client token" do
      {:ok, tool} = public_with(client_token: "session_token", credentials: ["url"])
      assert Tool.credential_keys(tool) == ["url", "session_token"]

      {:ok, plain} = Tool.new(@public_tool)
      assert Tool.credential_keys(plain) == []
    end
  end

  describe "new!/1" do
    test "returns the tool" do
      assert %Tool{name: "catalogue.list_products"} = Tool.new!(@admin_tool)
    end

    test "raises with every message when the tool is invalid" do
      assert_raise ArgumentError, ~r/invalid API tool: .*name must look like/, fn ->
        Tool.new!(Keyword.put(@admin_tool, :name, "no pe"))
      end
    end
  end

  describe "validate/1" do
    test "accepts a struct built by new/1 and rejects a hand-written one with holes" do
      assert {:ok, tool} = Tool.new(@admin_tool)
      assert {:ok, ^tool} = Tool.validate(tool)

      literal = %Tool{
        name: "catalogue.list_products",
        audience: :admin,
        handler: {Kernel, :inspect}
      }

      assert {:error, messages} = Tool.validate(literal)
      assert Enum.any?(messages, &(&1 =~ "scope is required"))
      assert Enum.any?(messages, &(&1 =~ "input_schema must be a map"))
      assert "title must be a string, got nil" in messages
      assert "description must be a string, got nil" in messages
    end
  end

  describe "text that is not valid UTF-8" do
    # `GET /` encodes the whole list of tools, so a tool carrying such text has to be refused
    # here, before the registry can hand it to the encoder.
    @bad <<0xFF, 0xFE>>

    @admin_tool_defaults [
      name: "catalogue.list_products",
      audience: :admin,
      scope: "catalogue.products:read",
      permission: "catalogue",
      handler: {Kernel, :inspect},
      title: "List products",
      description: "Lists",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
    ]

    defp built(overrides), do: struct!(Tool, Keyword.merge(@admin_tool_defaults, overrides))

    test "the tool the helper builds is valid" do
      assert {:ok, %Tool{}} = Tool.validate(built([]))
    end

    for field <- [:title, :description, :scope, :permission] do
      test "refuses a #{field} that is not valid UTF-8" do
        assert {:error, messages} = Tool.validate(built([{unquote(field), @bad}]))
        assert "#{unquote(field)} must be valid UTF-8" in messages
      end
    end

    test "refuses a name that is not valid UTF-8" do
      assert {:error, [_ | _]} = Tool.validate(built(name: "catalogue.list_" <> @bad))
    end

    test "refuses a public tool whose title or description is not valid UTF-8" do
      assert {:error, _} =
               Tool.validate(built(audience: :public, scope: nil, permission: nil, title: @bad))

      assert {:error, _} =
               Tool.validate(
                 built(audience: :public, scope: nil, permission: nil, description: @bad)
               )
    end

    test "refuses an input schema holding such text anywhere" do
      schemas = [
        %{"type" => "object", "description" => @bad},
        %{"type" => "object", "title" => @bad},
        %{
          "type" => "object",
          "properties" => %{"kind" => %{"type" => "string", "description" => @bad}}
        },
        %{
          "type" => "object",
          "properties" => %{"kind" => %{"type" => "string", "enum" => ["ok", @bad]}}
        },
        %{
          "type" => "object",
          "properties" => %{@bad => %{"type" => "string"}}
        },
        %{
          "type" => "object",
          "properties" => %{
            "items" => %{
              "type" => "array",
              "items" => %{"type" => "object", "properties" => %{"x" => %{"title" => @bad}}}
            }
          }
        }
      ]

      for schema <- schemas do
        assert {:error, messages} = Tool.validate(built(input_schema: schema))

        assert Enum.any?(messages, &(&1 =~ "input_schema must be JSON-encodable")),
               inspect(schema)
      end
    end

    test "refuses an output schema holding such text anywhere" do
      schemas = [
        %{"type" => "object", "description" => @bad},
        %{"type" => "object", "properties" => %{"a" => %{"title" => @bad}}},
        %{"type" => "string", "enum" => [@bad]}
      ]

      for schema <- schemas do
        assert {:error, messages} = Tool.validate(built(output_schema: schema))

        assert Enum.any?(messages, &(&1 =~ "output_schema must be JSON-encodable")),
               inspect(schema)
      end
    end

    test "still accepts multibyte text" do
      text = "Каталог товаров, 商品"
      schema = %{"type" => "string", "description" => text, "enum" => [text]}

      assert {:ok, %Tool{}} =
               Tool.validate(
                 built(
                   title: text,
                   description: text,
                   permission: "catalogue",
                   input_schema: %{"type" => "object", "description" => text},
                   output_schema: schema
                 )
               )
    end
  end
end
