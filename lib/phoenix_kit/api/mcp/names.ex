defmodule PhoenixKit.API.MCP.Names do
  @moduledoc """
  Tool names on MCP.

  Some model APIs accept only `[a-zA-Z0-9_-]` in tool names, so MCP shows
  every tool with `_` where the name has a `.` (`catalogue.set_prices` is
  `catalogue_set_prices`). REST and OpenAPI keep the dotted name, and
  `tools/call` accepts both.

  Two tools of one audience can map to the same MCP name (`a.b_c` and
  `a_b.c`). `PhoenixKit.API.ToolLint.check_tools/1` reports that in a
  module's tests; at run time the first one in registry order wins, in
  `dedupe/1` and in `resolve/2`. `dedupe/1` works on the list the caller may
  see and `resolve/2` ignores scopes, so when the two tools need different
  scopes a key that holds only the second one sees the second tool in
  `tools/list`, while `tools/call` with the underscore name reaches the first
  and is refused. The dotted name always reaches its own tool.
  """

  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.Tool
  alias PhoenixKit.ModuleRegistry

  @doc "The MCP form of a tool name."
  @spec to_mcp(String.t()) :: String.t()
  def to_mcp(name) when is_binary(name), do: String.replace(name, ".", "_")

  @doc """
  The dotted name for `name`, which may be given in either form.

  A name that has a `.` is returned as it is, and so is a name that is itself the
  undotted name or an alias of a tool of `audience` (`PhoenixKit.API.Tool`, "Undotted
  names and aliases"); `PhoenixKit.API.Registry.find/2` resolves an alias. Any other
  underscore name is mapped to
  the dotted name of a tool **of `audience`**: a live one, or one whose module
  is switched off (so that `PhoenixKit.API.Executor` can say `module_disabled`
  instead of `not_found`). That is decided by `PhoenixKit.API.Registry.find/2`,
  which looks at the audience, so the answer for a tool of the other audience,
  a tool hidden by `api_disabled_tools`, a tool of a module switched off in
  `api_disabled_modules` and a name nobody has is the same: the name comes
  back unchanged. An anonymous caller of the public endpoint can
  therefore not learn the dotted name of an admin tool, or that it exists.

  Whether the tool is visible to the caller, permitted or enabled is the
  executor's answer.
  """
  @spec resolve(String.t(), Tool.audience()) :: String.t()
  def resolve(name, audience) when is_binary(name) do
    cond do
      String.contains?(name, ".") -> name
      # An undotted name or an alias of a tool of this audience is a name of its own.
      known?(name, audience) -> name
      true -> name |> candidates() |> Enum.find(name, &known?(&1, audience))
    end
  end

  @doc "Drops every tool whose MCP name an earlier tool of the list already has."
  @spec dedupe([Tool.t()]) :: [Tool.t()]
  def dedupe(tools) when is_list(tools), do: Enum.uniq_by(tools, &to_mcp(&1.name))

  # Every dotted name, of either audience, that has this MCP name, in registry
  # order. Which of them this audience may know is `known?/2`'s decision.
  defp candidates(mcp_name) do
    live = for %Tool{name: name} <- Registry.all_tools(), do: name
    registered = ModuleRegistry.api_tool_names(:admin) ++ ModuleRegistry.api_tool_names(:public)

    (live ++ registered) |> Enum.uniq() |> Enum.filter(&(to_mcp(&1) == mcp_name))
  end

  # `Registry.find/2` looks at the audience: a tool of the other audience, a hidden
  # one (`api_disabled_tools` or `api_disabled_modules`) and an unknown name are all
  # `:not_found`.
  defp known?(dotted, audience) do
    case Registry.find(dotted, audience) do
      {:ok, _tool} -> true
      {:error, :module_disabled} -> true
      {:error, :not_found} -> false
    end
  end
end
