defmodule PhoenixKit.API.Tool do
  @moduledoc """
  One operation a module offers through the API (REST today, MCP later).

  A module returns a list of tools from the optional `c:PhoenixKit.Module.api_tools/0`
  callback. Core collects them (`PhoenixKit.API.Registry`), checks the caller's rights,
  validates the input against `input_schema`, calls the handler and shapes the answer.

  ## Fields

    * `:name` - `"<namespace>.<verb>_<noun>"`, lowercase, stable (`"catalogue.set_prices"`),
      at most 100 characters. A tool of the **host application** may instead have an
      undotted name, `[A-Za-z0-9_-]+` (`"call_endpoint"`), so an existing MCP server can move
      onto the kit without renaming its tools for its clients; PhoenixKit's own packages keep
      the dotted form. An undotted name is shown as it is on MCP, REST and OpenAPI. See
      "Undotted names and aliases" below for the rules both share.
    * `:aliases` - other names the tool answers to (`["callEndpoint", "orders.call"]`),
      each a dotted or an undotted name as above, default `[]`. A call by an alias runs the
      tool under its own name: the alias is resolved before the key's scopes, the owner's
      rights, the rate limit, confirmations and the request log see the call, so all of
      them see the real name. Listings (`tools/list`, `GET /`, OpenAPI) show only the name.
    * `:audience` - `:admin` (a key with scopes) or `:public` (no key).
    * `:scope` - the scope a key must carry, `"<module>.<resource>:<action>"`. `nil` for
      public tools and for core's own `system.*` tools, which every valid key may call. A
      public tool must have **no** scope: it is called without a key, so one could never be
      met, and `validate/1` refuses the tool.
      The `system.` namespace belongs to core: a tool a module returns from `api_tools/0`
      under that name is ignored, so a module cannot declare a tool that skips the scope and
      permission checks.
    * `:permission` - the role permission the key's owner must hold right now
      (`"catalogue"`). `nil` under the same rule as `:scope`; a public tool must
      have no permission either.
    * `:title`, `:description` - written for a person and for an agent. The title defaults
      to the name, the description to `""`.
    * `:input_schema` - JSON Schema (string keys) of the input, limited to the keywords
      `PhoenixKit.API.Validator` enforces (`Validator.check_schema/2` refuses the rest).
      Defaults to an object with no properties and `additionalProperties: false`.
      Keep it **static**: build it from literals, not from data that changes at runtime (an
      enum of database values, say). The result of the schema check is remembered per
      distinct schema for the life of the node and never erased, so a schema that keeps
      changing adds an entry each time.
    * `:output_schema` - JSON Schema of a success answer, or `nil`.
    * `:handler` - `{module, function}`, called as `apply(module, function, [input, ctx])`.
    * `:module` - the module that declared the tool. Filled in by the registry.
    * `:annotations` - hints for clients: `:read_only`, `:destructive`, `:idempotent`,
      `:open_world` (all `false` unless given).
    * `:danger` - when a call needs a person's confirmation: `nil` (never, except the
      generic batch-size rule for admin writes), `:always`, or `{module, function}`, a
      check `function(input, ctx) :: boolean()` called with a dry-run context. Any other
      value is refused by `validate/1`. A key marked "requires approval" holds every
      write for a person regardless of `:danger`.
    * `:replay` - whether a retry of a write call with the same `idempotency_key` gets the
      first answer back. `true` by default. Set `false` on a write tool whose answer carries a
      credential (a session token, a claim URL): such an answer is never stored
      (`PhoenixKit.API.Idempotency.credential_bearing?/2`), so the key could not be honoured.
      The tool then takes no `idempotency_key`: the schemas, MCP and OpenAPI do not offer it, a
      body that sends it is a `422`, and the `Idempotency-Key` header is ignored, as it is on a
      read tool. Say in the description that a repeated call is not the same call.
      The field is newer than core 2.63.0, where `new/1` refuses it. A module that must also
      run there passes it only when `Code.ensure_loaded?(PhoenixKit.API.ControlFields) and
      function_exported?(PhoenixKit.API.ControlFields, :replay_tool?, 1)`.
    * `:client_token` - for a `:public` tool, the name of the input field that carries the
      anonymous client's token (`"session_token"`), or `nil` (default). It must be a string
      property of `input_schema`. Core hashes the value (sha256, url-safe base64, never kept
      in clear) into `PhoenixKit.API.Actor.client_token_hash` and uses the hash as the
      caller's identity where there is no key: the per-token rate-limit bucket, the scope of
      the `idempotency_key` and the binding of a confirmation code. A public tool with a
      `danger:` must declare it and list it in `required`; a call without the token is a
      `422` naming the field. An `:admin` tool may not declare one. The field is a credential
      like a key and is redacted from stored answers. It is refused in a URL, and filtered
      from the request log, only when core's credential rule knows its name (the listed names
      and `*_token`; see `PhoenixKit.API.Auth.credential_name?/1`), so name it `*_token`.
      The field is newer than core 2.63.x, where `new/1` refuses it. A module that must also
      run there sets it only when `Map.has_key?(PhoenixKit.API.Tool.__struct__(), :client_token)`
      (a struct key is not a function, so `function_exported?/3` cannot tell; and
      `%PhoenixKit.API.Tool{}` does not compile, it has required keys).
    * `:credentials` - names of **output** fields in which the tool hands out a secret that is
      not named `*_token` (a link with a claim code in it, say). An answer carrying one of
      them is never stored for replay and is redacted from an approval's result. The tool's
      `:client_token` counts as one without being listed. Same rule as `:client_token` for
      older cores: pass it only when the struct has the key.
    * `:max_items` - the largest batch the tool accepts, or `nil`.
    * `:cost` - the rate-limit units one call costs. `nil` (default) means the executor's
      rule: 1, or for a non-read-only admin tool `max(1, ceil(longest list / 50))`. A
      positive integer up to 1000 is a fixed price. `{Module, :function}` is called as
      `Module.function(input)` with the raw, unvalidated input and returns a positive
      integer (a failure falls back to the default rule). Use it for a batch read:
      `cost: {MyModule.API, :batch_cost}`.

  ## Building a tool

  Always build it with `new!/1` (or `new/1` when the caller wants the error list) so the
  defaults above are filled in and the shape is checked:

      PhoenixKit.API.Tool.new!(
        name: "catalogue.list_products",
        audience: :admin,
        scope: "catalogue.products:read",
        permission: "catalogue",
        title: "List products",
        handler: {MyModule.API, :list_products},
        annotations: %{read_only: true}
      )

  A tool returned from `api_tools/0` that fails `validate/1` is ignored with one warning
  per module; the module's other tools still work.

  ## Undotted names and aliases

  Every name and alias of every tool, together with its MCP form (`.` read as `_`), goes
  through one collision check, `PhoenixKit.ModuleRegistry.check_api_tool_names!/1`, when the
  registry starts and when a module is registered or the modules are rescanned. It raises
  `ArgumentError`, naming both tools, when an undotted name or an alias is already the name,
  the MCP name or an alias of another tool of the same audience, and when one begins with a
  reserved namespace: `system` (core's) or the namespace of a dotted tool that another module
  declares (`catalogue_...` while a module declares `catalogue.*`), so a later release of
  that package cannot collide with it. Two dotted names that share an MCP name (`a.b_c`,
  `a_b.c`) keep the older rule: `PhoenixKit.API.ToolLint` reports them and the first one
  wins at run time.
  """

  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Validator

  @name_pattern ~r/\A[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\z/
  # An undotted name, for the tools of a host application ("Undotted names and aliases").
  @plain_name_pattern ~r/\A[A-Za-z0-9_-]+\z/
  # A confirmation or an approval keeps the name in a `varchar(120)`; the cap leaves room.
  @name_max 100
  @audiences [:admin, :public]
  @annotation_keys [:read_only, :destructive, :idempotent, :open_world]
  @default_annotations %{
    read_only: false,
    destructive: false,
    idempotent: false,
    open_world: false
  }
  @empty_input_schema %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @struct_fields [
    :name,
    :audience,
    :scope,
    :permission,
    :title,
    :description,
    :input_schema,
    :output_schema,
    :handler,
    :module,
    aliases: [],
    annotations: @default_annotations,
    danger: nil,
    replay: true,
    client_token: nil,
    credentials: [],
    max_items: nil,
    cost: nil
  ]

  # The keys `new/1` accepts: the struct's own, listed once.
  @fields Enum.map(@struct_fields, fn
            {field, _default} -> field
            field -> field
          end)

  @enforce_keys [:name, :audience, :handler]
  defstruct @struct_fields

  @typedoc "Who may call the tool: `:admin` needs a key, `:public` needs nothing."
  @type audience :: :admin | :public

  @typedoc "`{module, function}`, called as `apply(module, function, [input, ctx])`."
  @type handler :: {module(), atom()}

  @type t :: %__MODULE__{}

  @doc """
  Builds a tool from a map or keyword list, fills the defaults and validates it.

  Returns `{:ok, tool}` or `{:error, messages}` (every problem found, not only the first).
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs |> Map.new() |> new()
    else
      {:error, ["attributes must be a map or a keyword list"]}
    end
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    case Enum.reject(Map.keys(attrs), &(&1 in @fields)) do
      [] -> attrs |> build() |> validate()
      unknown -> {:error, ["unknown field(s): " <> Enum.map_join(unknown, ", ", &inspect/1)]}
    end
  end

  def new(_attrs), do: {:error, ["attributes must be a map or a keyword list"]}

  @doc "Like `new/1`, but raises `ArgumentError` listing every problem."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, tool} ->
        tool

      {:error, messages} ->
        raise ArgumentError, "invalid API tool: " <> Enum.join(messages, "; ")
    end
  end

  @doc """
  Checks the shape of a tool struct (the registry runs this on everything a module returns).

  An `:admin` tool needs a `:scope` and a `:permission`, except a core `system.*` tool,
  which every valid key may call. This check does not know who built the tool: that the
  `system.` namespace is core's alone is enforced where module tools are collected
  (`PhoenixKit.ModuleRegistry.all_api_tools/0`).
  """
  @spec validate(t()) :: {:ok, t()} | {:error, [String.t()]}
  def validate(%__MODULE__{} = tool) do
    checks = [
      &check_name/1,
      &check_aliases/1,
      &check_audience/1,
      &check_handler/1,
      &check_rights/1,
      &check_texts/1,
      &check_encoding/1,
      &check_schemas/1,
      &check_annotations/1,
      &check_danger/1,
      &check_replay/1,
      &check_client_token/1,
      &check_credentials/1,
      &check_max_items/1,
      &check_cost/1
    ]

    case Enum.flat_map(checks, & &1.(tool)) do
      [] -> {:ok, tool}
      messages -> {:error, messages}
    end
  end

  @doc """
  The output field names whose values must never be stored or shown in clear for `tool`:
  its `:credentials` and its `:client_token`. `PhoenixKit.API.Idempotency` adds them to the
  names core already treats as credentials.
  """
  @spec credential_keys(t()) :: [String.t()]
  def credential_keys(%__MODULE__{credentials: credentials, client_token: client_token}) do
    Enum.filter(List.wrap(credentials) ++ [client_token], &is_binary/1)
  end

  @doc """
  True when `name` is a valid tool name or alias: dotted (`"catalogue.set_prices"`) or
  undotted (`"call_endpoint"`), at most 100 characters.
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name),
    do: byte_size(name) <= @name_max and (dotted_name?(name) or plain_name?(name))

  def valid_name?(_name), do: false

  @doc ~S|True for an undotted name (`"call_endpoint"`).|
  @spec plain_name?(term()) :: boolean()
  def plain_name?(name) when is_binary(name), do: Regex.match?(@plain_name_pattern, name)
  def plain_name?(_name), do: false

  defp dotted_name?(name), do: Regex.match?(@name_pattern, name)

  @doc "The name of `tool` followed by its aliases."
  @spec names(t()) :: [String.t()]
  def names(%__MODULE__{name: name, aliases: aliases}), do: [name | List.wrap(aliases)]

  @doc "True when `name` is the name or one of the aliases of `tool`."
  @spec answers_to?(t(), String.t()) :: boolean()
  def answers_to?(%__MODULE__{name: name}, name), do: true
  def answers_to?(%__MODULE__{aliases: aliases}, name) when is_list(aliases), do: name in aliases
  def answers_to?(%__MODULE__{}, _name), do: false

  @doc "True for core's own `system.*` tools."
  @spec system?(t()) :: boolean()
  def system?(%__MODULE__{name: name}) when is_binary(name),
    do: String.starts_with?(name, "system.")

  def system?(%__MODULE__{}), do: false

  defp build(attrs) do
    tool = struct!(__MODULE__, Map.merge(%{name: nil, audience: nil, handler: nil}, attrs))

    %{
      tool
      | title: tool.title || default_title(tool.name),
        description: tool.description || "",
        input_schema: tool.input_schema || @empty_input_schema,
        annotations: merge_annotations(tool.annotations)
    }
  end

  defp default_title(name) when is_binary(name), do: name
  defp default_title(_name), do: ""

  defp merge_annotations(nil), do: @default_annotations

  defp merge_annotations(given) when is_map(given), do: Map.merge(@default_annotations, given)

  defp merge_annotations(other), do: other

  defp check_name(%{name: name}) do
    cond do
      not (is_binary(name) and (dotted_name?(name) or plain_name?(name))) ->
        [
          "name must look like \"namespace.verb_noun\" (lowercase letters, digits, underscores), " <>
            "or be an undotted name of letters, digits, \"_\" and \"-\", got #{inspect(name)}"
        ]

      byte_size(name) > @name_max ->
        ["name must be at most #{@name_max} characters, got #{byte_size(name)}"]

      true ->
        []
    end
  end

  defp check_aliases(%{aliases: aliases} = tool) when is_list(aliases) do
    cond do
      not Enum.all?(aliases, &valid_name?/1) ->
        [
          "aliases must be dotted or undotted tool names of at most #{@name_max} characters, got #{inspect(aliases)}"
        ]

      aliases != Enum.uniq(aliases) ->
        ["aliases must not repeat a name, got #{inspect(aliases)}"]

      tool.name in aliases ->
        ["aliases must not repeat the tool's own name #{inspect(tool.name)}"]

      true ->
        []
    end
  end

  defp check_aliases(%{aliases: aliases}),
    do: ["aliases must be a list of tool names, got #{inspect(aliases)}"]

  defp check_audience(%{audience: audience}) when audience in @audiences, do: []

  defp check_audience(%{audience: audience}),
    do: ["audience must be :admin or :public, got #{inspect(audience)}"]

  defp check_handler(%{handler: {module, function}})
       when is_atom(module) and not is_nil(module) and is_atom(function) and not is_nil(function),
       do: []

  defp check_handler(%{handler: handler}),
    do: ["handler must be {module, function}, got #{inspect(handler)}"]

  defp check_rights(%{audience: :admin} = tool) do
    if system?(tool) do
      optional_binary(tool.scope, "scope") ++ optional_binary(tool.permission, "permission")
    else
      required_binary(tool.scope, "scope", "an admin tool") ++
        required_binary(tool.permission, "permission", "an admin tool")
    end
  end

  # A public tool is anonymous, so a scope or a permission on it could never be satisfied.
  defp check_rights(%{audience: :public} = tool),
    do: must_be_nil(tool.scope, "scope") ++ must_be_nil(tool.permission, "permission")

  defp check_rights(_tool), do: []

  defp must_be_nil(nil, _field), do: []

  defp must_be_nil(value, field),
    do: ["#{field} must be nil for a public tool, got #{inspect(value)}"]

  defp required_binary(value, _field, _what) when is_binary(value) and value != "", do: []
  defp required_binary(_value, field, what), do: ["#{field} is required for #{what}"]

  defp optional_binary(nil, _field), do: []
  defp optional_binary(value, _field) when is_binary(value) and value != "", do: []

  defp optional_binary(value, field),
    do: ["#{field} must be a non-empty string or nil, got #{inspect(value)}"]

  defp check_texts(tool) do
    Enum.flat_map([title: tool.title, description: tool.description], fn
      {_field, value} when is_binary(value) -> []
      {field, value} -> ["#{field} must be a string, got #{inspect(value)}"]
    end)
  end

  # Every text of a tool reaches the JSON listing of the tools (`GET /`), and the encoder raises
  # on a binary that is not UTF-8. The name is held to its pattern; the schemas are held to
  # the encodability check below, which walks every key and value.
  defp check_encoding(tool) do
    for {field, value} <- [
          title: tool.title,
          description: tool.description,
          scope: tool.scope,
          permission: tool.permission
        ],
        is_binary(value) and not String.valid?(value) do
      "#{field} must be valid UTF-8"
    end
  end

  defp check_schemas(tool) do
    input_schema_problems(tool.input_schema) ++ output_schema_problems(tool.output_schema)
  end

  # A keyword the validator would ignore is refused here, so a schema mistake fails when the
  # tool is registered and not as a 500 on the first request that reaches it. The same goes for
  # a schema JSON cannot encode (an annotation such as `default` may hold any term, and a
  # listing of the tools encodes every schema), and for an input property named after a field
  # the executor adds itself.
  #
  # The registry validates every tool of every enabled module on each call, which is the request
  # path of a public endpoint, so the answer for a schema is remembered (`:persistent_term`, keyed
  # by a digest of the schema). One entry stays behind for every distinct schema ever seen, so
  # schemas must be static (documented under `:input_schema`); `:persistent_term.put/2` of a new
  # key is not free either.
  defp input_schema_problems(schema) when is_map(schema) do
    remembered(:input, schema, fn ->
      schema_problems(schema) ++
        reserved_property_problems(schema) ++ encodable_problems(schema, "input_schema")
    end)
  end

  defp input_schema_problems(_schema), do: ["input_schema must be a map (JSON Schema)"]

  defp output_schema_problems(nil), do: []

  defp output_schema_problems(schema) when is_map(schema) do
    remembered(:output, schema, fn -> encodable_problems(schema, "output_schema") end)
  end

  defp output_schema_problems(_schema), do: ["output_schema must be a map (JSON Schema) or nil"]

  defp remembered(kind, schema, compute) do
    key =
      {__MODULE__, :schema_problems, kind,
       schema |> :erlang.term_to_binary([:deterministic]) |> :erlang.md5()}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        problems = compute.()
        :persistent_term.put(key, problems)
        problems

      problems ->
        problems
    end
  end

  defp schema_problems(schema) do
    case Validator.check_schema(schema, "input_schema") do
      :ok -> []
      {:error, problems} -> problems
    end
  end

  defp reserved_property_problems(schema) do
    case Map.get(schema, "properties", Map.get(schema, :properties)) do
      properties when is_map(properties) and not is_struct(properties) ->
        # The control fields the executor adds itself, read at run time: that module reads this
        # struct. `language` and `currency` of a public tool are declared by the module that owns it.
        reserved = ControlFields.names()

        properties
        |> Map.keys()
        |> Enum.filter(&((is_binary(&1) or is_atom(&1)) and to_string(&1) in reserved))
        |> Enum.map(
          &"input_schema.properties.#{&1} is a field the executor adds itself; name the property otherwise"
        )

      _ ->
        []
    end
  end

  defp encodable_problems(schema, label) do
    _ = JSON.encode!(schema)
    []
  rescue
    _ ->
      [
        "#{label} must be JSON-encodable (a tuple, a pid or a function cannot be encoded, " <>
          "nor a string that is not valid UTF-8)"
      ]
  end

  defp check_annotations(%{annotations: annotations})
       when is_map(annotations) and not is_struct(annotations) do
    unknown = Map.keys(annotations) -- @annotation_keys

    not_boolean =
      for {key, value} <- annotations, key in @annotation_keys, not is_boolean(value), do: key

    unknown_message =
      if unknown == [],
        do: [],
        else: ["unknown annotation(s): " <> Enum.map_join(unknown, ", ", &inspect/1)]

    boolean_message =
      if not_boolean == [],
        do: [],
        else: [
          "annotation(s) must be true or false: " <> Enum.map_join(not_boolean, ", ", &inspect/1)
        ]

    unknown_message ++ boolean_message
  end

  defp check_annotations(_tool), do: ["annotations must be a map"]

  defp check_replay(%{replay: replay}) when is_boolean(replay), do: []

  defp check_replay(%{replay: replay}),
    do: ["replay must be true or false, got #{inspect(replay)}"]

  defp check_danger(%{danger: danger}) when danger in [nil, :always], do: []

  defp check_danger(%{danger: {module, function}})
       when is_atom(module) and not is_nil(module) and is_atom(function) and not is_nil(function),
       do: []

  defp check_danger(%{danger: danger}),
    do: ["danger must be nil, :always or {module, function}, got #{inspect(danger)}"]

  defp check_client_token(%{client_token: nil}), do: []

  defp check_client_token(%{client_token: field, audience: :public} = tool)
       when is_binary(field) and field != "" do
    case string_property?(tool.input_schema, field) do
      true -> []
      false -> ["client_token #{inspect(field)} must be a string property of input_schema"]
    end
  end

  defp check_client_token(%{client_token: field, audience: :public}),
    do: ["client_token must be a non-empty string or nil, got #{inspect(field)}"]

  defp check_client_token(%{client_token: _field}),
    do: ["client_token is for a public tool only: an admin caller is identified by its key"]

  defp string_property?(schema, field) when is_map(schema) and not is_struct(schema) do
    properties = Map.get(schema, "properties", Map.get(schema, :properties))

    with true <- is_map(properties) and not is_struct(properties),
         %{} = property <- Map.get(properties, field),
         type when type in ["string", :string] <-
           Map.get(property, "type", Map.get(property, :type)) do
      true
    else
      _ -> false
    end
  end

  defp string_property?(_schema, _field), do: false

  defp check_credentials(%{credentials: credentials}) when is_list(credentials) do
    if Enum.all?(credentials, &(is_binary(&1) and &1 != "")),
      do: [],
      else: ["credentials must be a list of non-empty strings, got #{inspect(credentials)}"]
  end

  defp check_credentials(%{credentials: credentials}),
    do: ["credentials must be a list of non-empty strings, got #{inspect(credentials)}"]

  defp check_max_items(%{max_items: nil}), do: []
  defp check_max_items(%{max_items: max}) when is_integer(max) and max > 0, do: []

  defp check_max_items(%{max_items: max}),
    do: ["max_items must be a positive integer or nil, got #{inspect(max)}"]

  @max_cost 1000

  defp check_cost(%{cost: nil}), do: []
  defp check_cost(%{cost: cost}) when is_integer(cost) and cost > 0 and cost <= @max_cost, do: []

  defp check_cost(%{cost: {module, function}})
       when is_atom(module) and not is_nil(module) and is_atom(function) and not is_nil(function),
       do: []

  defp check_cost(%{cost: cost}),
    do: [
      "cost must be nil, a positive integer up to #{@max_cost}, or {module, function}, got #{inspect(cost)}"
    ]
end
