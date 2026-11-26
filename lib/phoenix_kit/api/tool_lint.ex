defmodule PhoenixKit.API.ToolLint do
  @moduledoc """
  Static checks for API tools, for the test suite of every module that
  declares `c:PhoenixKit.Module.api_tools/0`.

      test "the tools are well formed" do
        assert :ok = PhoenixKit.API.ToolLint.check_tools(MyModule.api_tools())
      end

  `PhoenixKit.API.Validator` enforces a small subset of JSON Schema and
  silently ignores every other keyword. A schema that uses an ignored keyword
  in a tool's **input** promises a check nobody makes, so this module flags:

    * in an input schema, **every keyword outside the supported subset**:
      anything but `type`, `required`, `properties`,
      `additionalProperties`, `enum`, `minimum`, `maximum`, `minLength`,
      `maxLength`, `minItems`, `maxItems`, `items`, `pattern` and the
      annotations the validator accepts and ignores
      (`PhoenixKit.API.Validator.annotation?/1`).
      That is a whitelist: `oneOf`, `const`, `nullable`, `dependencies`,
      `uniqueItems` and a keyword nobody has heard of are all caught. (In an
      output schema the combinators are fine: core generates `anyOf` itself
      for the MCP `outputSchema`, and outputs are not validated at run time.)
    * `$ref`, `$defs` and `definitions` anywhere: schemas are served as they
      are and nothing resolves a reference.

  It also checks the shape of what the validator does read (`type`,
  `required`, `properties`, `additionalProperties`, `items`, `enum`, the
  numeric and count bounds, `pattern`), that both roots are objects (MCP
  needs an object `inputSchema`, and `structuredContent` is an object), that a
  `required` name is declared when the object is closed, that a tool has a
  description, that a public tool with a `danger:` declares a `client_token:`
  and lists that field in `required` (a dry run is answered before the client
  token is checked, so the schema has to refuse a call without one), that a
  `client_token:` is a string property of the input schema and belongs to a
  public tool (an admin tool is identified by its key), and that no two tools
  of one audience share a name or an MCP name (`a.b_c` and `a_b.c` are both
  `a_b_c` on MCP).

  ## Relation to the validator

  `PhoenixKit.API.Tool.new/1` already runs `PhoenixKit.API.Validator.check_schema/2`
  on every tool, so a tool built through it is refused for an unsupported
  keyword, a bad bound or a bad `pattern`. This module is defence in depth:
  it also sees a tool built as a struct literal, reports every problem with its
  path instead of the first one, and checks what the validator does not (a
  `required` name that is not declared, an object root, an empty description,
  the MCP-name collisions). Where both read a keyword they agree: `pattern` is compiled with
  the validator's options, the annotations come from the validator, and an atom
  `type` or `required` name is read like a string. A test pins the agreement.
  The lint is stricter in a few places on purpose: a `type` list with a
  repeated name, a `minimum` above a `maximum`, an empty `enum`, an empty
  description.

  Every function returns `:ok` or `{:error, messages}` with all the problems
  found, in English. A schema message starts with the path inside the schema
  it is about (`properties.sku: ...`, `(root): ...`); `check_tool/1` adds
  `input_schema:` or `output_schema:` in front, and `check_tools/1` the tool
  name. A name message (`a.b_c, a_b.c share the MCP name a_b_c`) starts with
  the names.
  """

  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.Validator

  @types ~w(object array string integer number boolean null)

  # What the validator enforces. Its annotations are asked of the validator
  # (`Validator.annotation?/1`). Anything else in an input schema is flagged.
  @enforced_keywords ~w(type required properties additionalProperties enum
                        minimum maximum minLength maxLength minItems maxItems items pattern)

  @unsupported ~w($ref $defs definitions)

  @number_keys ~w(minimum maximum)
  @count_keys ~w(minLength maxLength minItems maxItems)
  @text_keys ~w(title description)

  @doc """
  Checks one JSON Schema. `kind` is `:input` for a tool's `input_schema` and
  `:output` for its `output_schema`.
  """
  @spec check_schema(term(), :input | :output) :: :ok | {:error, [String.t()]}
  def check_schema(schema, kind) when kind in [:input, :output] do
    messages =
      key_messages(schema, []) ++ (schema |> stringify() |> walk(kind, [], []) |> Enum.reverse())

    case messages do
      [] -> :ok
      messages -> {:error, messages}
    end
  end

  @doc "Checks the schemas, the roots and the description of one tool."
  @spec check_tool(Tool.t()) :: :ok | {:error, [String.t()]}
  def check_tool(%Tool{} = tool) do
    case input_messages(tool) ++
           output_messages(tool) ++
           description_messages(tool) ++
           danger_messages(tool) ++
           client_token_messages(tool) do
      [] -> :ok
      messages -> {:error, messages}
    end
  end

  @doc """
  Checks every tool of a set and the names across the set: a name declared
  twice in one audience, two names of one audience that are the same on
  MCP, and an undotted name or an alias that another tool of the set already answers
  to (the collision part of `PhoenixKit.ModuleRegistry.check_api_tool_names!/1`; the
  reserved namespaces need the whole registry and are checked there).
  """
  @spec check_tools([Tool.t()]) :: :ok | {:error, [String.t()]}
  def check_tools(tools) when is_list(tools) do
    per_tool =
      Enum.flat_map(tools, fn tool ->
        case check_tool(tool) do
          :ok -> []
          {:error, messages} -> Enum.map(messages, &"#{tool_label(tool.name)}: #{&1}")
        end
      end)

    valid = Enum.filter(tools, &match?({:ok, _}, Tool.validate(&1)))
    aliases = PhoenixKit.ModuleRegistry.api_name_problems(valid, reserved: false)

    case per_tool ++ name_messages(tools) ++ aliases do
      [] -> :ok
      messages -> {:error, messages}
    end
  end

  # --- one tool ----------------------------------------------------------------

  defp input_messages(%Tool{input_schema: nil}), do: []

  defp input_messages(%Tool{input_schema: schema}),
    do: prefix("input_schema", root_messages(schema) ++ schema_messages(schema, :input))

  defp output_messages(%Tool{output_schema: nil}), do: []

  defp output_messages(%Tool{output_schema: schema}),
    do: prefix("output_schema", root_messages(schema) ++ schema_messages(schema, :output))

  defp root_messages(schema) do
    case stringify(schema) do
      %{"type" => type} when type in ["object", :object] -> []
      %{"type" => other} -> ["the root type must be \"object\", got #{inspect(other)}"]
      %{} -> ["the root must declare type \"object\""]
      boolean when is_boolean(boolean) -> ["the root must be an object schema, not a boolean"]
      _not_a_map -> []
    end
  end

  defp schema_messages(schema, kind) do
    case check_schema(schema, kind) do
      :ok -> []
      {:error, messages} -> messages
    end
  end

  defp description_messages(%Tool{description: description}) when description in [nil, ""],
    do: ["description is empty: an agent chooses tools by their description"]

  defp description_messages(%Tool{}), do: []

  # `Flow.gate/1` answers a dry run before it asks for a client token, so the
  # schema itself has to refuse a call without one.
  defp danger_messages(%Tool{audience: :public, danger: danger} = tool) when danger != nil do
    case tool.client_token do
      field when is_binary(field) ->
        if field in required_names(tool),
          do: [],
          else: [
            "a public tool with a danger must list #{field} in required: a dry run is answered before the client token is checked"
          ]

      _none ->
        [
          "a public tool with a danger must declare a client_token and list it in required: a confirmation code is bound to the caller's client token"
        ]
    end
  end

  defp danger_messages(%Tool{}), do: []

  defp required_names(%Tool{input_schema: schema}) do
    case stringify(schema) do
      %{"required" => names} when is_list(names) -> Enum.map(names, &type_name/1)
      _no_required -> []
    end
  end

  defp client_token_messages(%Tool{client_token: nil}), do: []

  defp client_token_messages(%Tool{audience: :admin}),
    do: ["an admin tool may not declare a client_token: its caller is identified by its key"]

  defp client_token_messages(%Tool{client_token: field} = tool) do
    case stringify(tool.input_schema) do
      %{"properties" => %{^field => property}} when is_map(property) ->
        if type_name(Map.get(property, "type")) == "string",
          do: [],
          else: ["client_token #{inspect(field)} must be a property of type string"]

      _not_declared ->
        ["client_token #{inspect(field)} must be a property of the input schema"]
    end
  end

  defp prefix(label, messages), do: Enum.map(messages, &"#{label}: #{&1}")

  # --- names -------------------------------------------------------------------

  defp name_messages(tools) do
    tools
    |> Enum.group_by(&{&1.audience, mcp_name(&1.name)})
    |> Enum.sort()
    |> Enum.flat_map(fn {{_audience, mcp}, group} -> group_message(mcp, group) end)
  end

  defp group_message(_mcp, [_single]), do: []

  defp group_message(mcp, group) do
    names = Enum.map(group, & &1.name)
    distinct = Enum.uniq(names)

    declared_twice =
      for name <- Enum.uniq(names -- distinct), do: "#{tool_label(name)} is declared twice"

    shared =
      case distinct do
        [_single] ->
          []

        _several ->
          [
            "#{distinct |> Enum.map(&tool_label/1) |> Enum.sort() |> Enum.join(", ")} share the MCP name #{mcp}"
          ]
      end

    declared_twice ++ shared
  end

  defp tool_label(name) when is_binary(name), do: name
  defp tool_label(name), do: inspect(name)

  # A dotted tool name is exposed on MCP with `_` in place of each `.`.
  defp mcp_name(name) when is_binary(name), do: String.replace(name, ".", "_")
  defp mcp_name(name), do: inspect(name)

  # --- walking a schema --------------------------------------------------------

  # `path` is the list of segments walked so far, innermost first.
  defp walk(schema, _kind, _path, errors) when is_boolean(schema), do: errors

  defp walk(%{} = schema, kind, path, errors) do
    errors
    |> check_type(schema, path)
    |> check_required(schema, kind, path)
    |> check_numbers(schema, path)
    |> check_counts(schema, path)
    |> check_pattern(schema, path)
    |> check_enum(schema, path)
    |> check_texts(schema, path)
    |> check_keywords(schema, kind, path)
    |> walk_properties(schema, kind, path)
    |> walk_additional(schema, kind, path)
    |> walk_items(schema, kind, path)
    |> walk_combinators(schema, kind, path)
  end

  defp walk(_other, _kind, path, errors),
    do: err(errors, path, "a schema must be an object or a boolean")

  defp check_type(errors, schema, path) do
    case Map.fetch(schema, "type") do
      :error ->
        errors

      {:ok, type} when is_binary(type) or (is_atom(type) and type not in [nil, true, false]) ->
        name = type_name(type)
        if name in @types, do: errors, else: err(errors, path, "unknown type #{inspect(name)}")

      {:ok, [_ | _] = types} ->
        names = Enum.map(types, &type_name/1)

        if Enum.all?(names, &(is_binary(&1) and &1 in @types)) and names == Enum.uniq(names),
          do: errors,
          else: err(errors, path, "type must be a list of unique type names")

      {:ok, _other} ->
        err(errors, path, "type must be a string or a list of strings")
    end
  end

  # The validator reads an atom type or required name like a string, and it
  # encodes to the same JSON.
  defp type_name(name) when is_atom(name) and name not in [nil, true, false],
    do: Atom.to_string(name)

  defp type_name(name), do: name

  defp check_required(errors, schema, kind, path) do
    case Map.fetch(schema, "required") do
      :error ->
        errors

      {:ok, names} when is_list(names) ->
        check_required_names(errors, schema, Enum.map(names, &type_name/1), kind, path)

      {:ok, _other} ->
        err(errors, path, "required must be a list of property names")
    end
  end

  defp check_required_names(errors, schema, names, kind, path) do
    cond do
      not Enum.all?(names, &is_binary/1) or names != Enum.uniq(names) ->
        err(errors, path, "required must be a list of unique strings")

      closed?(schema, kind, path) and undeclared(schema, names) != [] ->
        err(
          errors,
          path,
          "required #{inspect(undeclared(schema, names))} is not declared in properties and no other property is allowed"
        )

      true ->
        errors
    end
  end

  # The executor closes the root of every input schema.
  defp closed?(schema, kind, path),
    do: Map.get(schema, "additionalProperties") == false or (kind == :input and path == [])

  defp undeclared(schema, names) do
    declared =
      case Map.get(schema, "properties") do
        %{} = properties -> Map.keys(properties)
        _other -> []
      end

    names -- declared
  end

  defp check_numbers(errors, schema, path) do
    errors =
      Enum.reduce(@number_keys, errors, fn key, acc ->
        case Map.fetch(schema, key) do
          {:ok, value} when not is_number(value) -> err(acc, path, "#{key} must be a number")
          _ok_or_absent -> acc
        end
      end)

    check_order(errors, schema, "minimum", "maximum", &is_number/1, path)
  end

  defp check_counts(errors, schema, path) do
    errors =
      Enum.reduce(@count_keys, errors, fn key, acc ->
        case Map.fetch(schema, key) do
          {:ok, value} ->
            if count?(value),
              do: acc,
              else: err(acc, path, "#{key} must be a non-negative integer")

          :error ->
            acc
        end
      end)

    errors
    |> check_order(schema, "minLength", "maxLength", &count?/1, path)
    |> check_order(schema, "minItems", "maxItems", &count?/1, path)
  end

  defp count?(value), do: is_integer(value) and value >= 0

  defp check_order(errors, schema, low_key, high_key, valid?, path) do
    with {:ok, low} <- Map.fetch(schema, low_key),
         {:ok, high} <- Map.fetch(schema, high_key),
         true <- valid?.(low) and valid?.(high),
         true <- low > high do
      err(errors, path, "#{low_key} is greater than #{high_key}")
    else
      _ -> errors
    end
  end

  defp check_pattern(errors, schema, path) do
    case Map.fetch(schema, "pattern") do
      :error ->
        errors

      {:ok, pattern} when is_binary(pattern) ->
        # The validator compiles patterns with its own options; ask it.
        case Validator.check_schema(%{"pattern" => pattern}) do
          :ok -> errors
          {:error, _reasons} -> err(errors, path, "pattern is not a valid regular expression")
        end

      {:ok, _other} ->
        err(errors, path, "pattern must be a string")
    end
  end

  defp check_enum(errors, schema, path) do
    case Map.fetch(schema, "enum") do
      :error -> errors
      {:ok, [_ | _]} -> errors
      {:ok, _other} -> err(errors, path, "enum must be a non-empty list")
    end
  end

  defp check_texts(errors, schema, path) do
    Enum.reduce(@text_keys, errors, fn key, acc ->
      case Map.fetch(schema, key) do
        {:ok, value} when not is_binary(value) -> err(acc, path, "#{key} must be a string")
        _ok_or_absent -> acc
      end
    end)
  end

  defp check_keywords(errors, schema, kind, path) do
    errors =
      @unsupported
      |> Enum.filter(&Map.has_key?(schema, &1))
      |> Enum.reduce(errors, fn keyword, acc ->
        err(acc, path, "keyword #{inspect(keyword)} is not supported: inline the schema")
      end)

    if kind == :input do
      schema
      |> Map.keys()
      |> Enum.reject(
        &(&1 in @enforced_keywords or &1 in @unsupported or Validator.annotation?(&1))
      )
      |> Enum.sort()
      |> Enum.reduce(errors, fn keyword, acc ->
        err(
          acc,
          path,
          "keyword #{inspect(keyword)} is not enforced by PhoenixKit.API.Validator; check it in the handler or drop it"
        )
      end)
    else
      errors
    end
  end

  defp walk_properties(errors, schema, kind, path) do
    case Map.fetch(schema, "properties") do
      :error ->
        errors

      {:ok, %{} = properties} ->
        properties
        |> Enum.sort()
        |> Enum.reduce(errors, fn {name, sub}, acc ->
          walk(sub, kind, [name, "properties" | path], acc)
        end)

      {:ok, _other} ->
        err(errors, path, "properties must be an object")
    end
  end

  defp walk_additional(errors, schema, kind, path) do
    case Map.fetch(schema, "additionalProperties") do
      :error -> errors
      {:ok, flag} when is_boolean(flag) -> errors
      {:ok, %{} = sub} -> walk(sub, kind, ["additionalProperties" | path], errors)
      {:ok, _other} -> err(errors, path, "additionalProperties must be a boolean or a schema")
    end
  end

  defp walk_items(errors, schema, kind, path) do
    case Map.fetch(schema, "items") do
      :error -> errors
      {:ok, sub} when is_map(sub) or is_boolean(sub) -> walk(sub, kind, ["items" | path], errors)
      {:ok, _other} -> err(errors, path, "items must be a single schema")
    end
  end

  defp walk_combinators(errors, schema, kind, path) do
    Enum.reduce(~w(oneOf anyOf allOf), errors, fn key, acc ->
      case Map.fetch(schema, key) do
        :error ->
          acc

        {:ok, [_ | _] = subs} ->
          subs
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {sub, index}, inner ->
            walk(sub, kind, ["#{key}[#{index}]" | path], inner)
          end)

        {:ok, _other} ->
          err(acc, path, "#{key} must be a non-empty list of schemas")
      end
    end)
  end

  # --- helpers -----------------------------------------------------------------

  defp err(errors, path, text), do: ["#{label(path)}: #{text}" | errors]

  defp label([]), do: "(root)"
  defp label(path), do: path |> Enum.reverse() |> Enum.join(".")

  # Keys become strings; values are left alone. An entry whose key is neither a
  # string nor an atom is dropped here and reported by `key_messages/2`.
  defp stringify(%{} = map) when not is_struct(map) do
    for {key, value} <- map, valid_key?(key), into: %{}, do: {key_string(key), stringify(value)}
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  defp valid_key?(key), do: is_binary(key) or is_atom(key)

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: inspect(key)

  defp key_messages(%{} = map, path) when not is_struct(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} ->
      own =
        if valid_key?(key),
          do: [],
          else: ["#{label(path)}: schema keys must be strings or atoms, got #{inspect(key)}"]

      own ++ key_messages(value, [key_string(key) | path])
    end)
  end

  defp key_messages(list, path) when is_list(list),
    do: Enum.flat_map(list, &key_messages(&1, path))

  defp key_messages(_other, _path), do: []
end
