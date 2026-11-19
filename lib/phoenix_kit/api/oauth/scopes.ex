defmodule PhoenixKit.API.OAuth.Scopes do
  @moduledoc """
  The scopes an OAuth request can ask for and the consent screen can offer.

  A scope is the name an admin tool declares (`"<module>.<resource>:<action>"`,
  `PhoenixKit.API.Tool`). The server publishes no list of them (`scopes_supported` is left out
  of its metadata, so an anonymous visitor learns nothing about the modules), so a client asks
  blind and the `scope` it sends is only a hint: values no enabled admin tool declares are
  dropped (`parse/1`), and the person chooses on the consent screen among the scopes they hold
  (`PhoenixKit.API.Keys.allowed_scopes_for/1`).

  Reading is the default. `read?/1` tells a read scope (action `read`) from the rest.
  """

  alias PhoenixKit.API.Registry
  alias PhoenixKit.ModuleRegistry

  @max_requested 64
  @token ~r/\A[\x21\x23-\x5B\x5D-\x7E]{1,200}\z/

  @type detail :: %{name: String.t(), title: String.t(), description: String.t()}

  @type entry :: %{
          scope: String.t(),
          group: String.t(),
          resource: String.t(),
          action: String.t(),
          read?: boolean(),
          module_key: String.t(),
          module_name: String.t(),
          tools: [String.t()],
          details: [detail()]
        }

  @doc "Every scope the enabled admin tools declare, sorted."
  @spec known() :: [String.t()]
  def known do
    Registry.all_tools()
    |> Enum.filter(&(&1.audience == :admin and is_binary(&1.scope)))
    |> Enum.map(& &1.scope)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The scopes named in a `scope` request parameter (RFC 6749 section 3.3: space separated),
  limited to `known/0`, without repeats, in the order asked. Anything that is not a string,
  or names nothing known, is `[]`.
  """
  @spec parse(term()) :: [String.t()]
  def parse(value) when is_binary(value) do
    known = MapSet.new(known())

    value
    |> String.split(" ", trim: true)
    |> Enum.take(@max_requested)
    |> Enum.filter(&(Regex.match?(@token, &1) and MapSet.member?(known, &1)))
    |> Enum.uniq()
  end

  def parse(_value), do: []

  @doc "Whether `scope` is a read scope (its action is `read`)."
  @spec read?(String.t()) :: boolean()
  def read?(scope) when is_binary(scope), do: String.ends_with?(scope, ":read")

  @doc """
  What the consent screen shows for `scopes`: one entry per scope, in the words of the tool
  registry. An entry has the scope, its group (`module.resource`), the `resource` (the part of
  the group after the module), the action, whether it only reads, the module that owns it
  (`module_key`, and `module_name`, the name the module gives itself) and the tools it unlocks:
  their names (`tools`) and, sorted by title, their `details` (name, title, description) as the
  module wrote them for a person. A scope is placed under the module whose key starts its group,
  or else under the module of its first tool. Sorted by module name, then group, reads first.
  """
  @spec describe([String.t()]) :: [entry()]
  def describe(scopes) when is_list(scopes) do
    tools =
      Registry.all_tools()
      |> Enum.filter(&(&1.audience == :admin and &1.scope in scopes))
      |> Enum.group_by(& &1.scope)

    modules = Map.new(ModuleRegistry.api_modules(), &{&1.module, &1})

    scopes
    |> Enum.uniq()
    |> Enum.map(&entry(&1, Map.get(tools, &1, []), modules))
    |> Enum.sort_by(&{&1.module_name, &1.module_key, &1.group, not &1.read?, &1.action})
  end

  defp entry(scope, tools, modules) do
    {group, action} = split(scope)
    {module_key, resource} = split_group(group)
    owners = tools |> Enum.sort_by(& &1.name) |> Enum.map(&Map.get(modules, &1.module))

    owner =
      Enum.find(owners, &(&1 && &1.key == module_key)) || Enum.find(owners, & &1)

    %{
      scope: scope,
      group: group,
      resource: resource,
      action: action,
      read?: read?(scope),
      module_key: if(owner, do: owner.key, else: module_key),
      module_name: if(owner, do: owner.name, else: module_key),
      tools: tools |> Enum.map(& &1.name) |> Enum.sort(),
      details: tools |> Enum.map(&detail/1) |> Enum.sort_by(&{&1.title, &1.name})
    }
  end

  defp detail(tool),
    do: %{name: tool.name, title: tool.title || tool.name, description: tool.description || ""}

  defp split_group(group) do
    case String.split(group, ".", parts: 2) do
      [module_key, resource] -> {module_key, resource}
      [module_key] -> {module_key, ""}
    end
  end

  defp split(scope) do
    case String.split(scope, ":", parts: 2) do
      [group, action] -> {group, action}
      [group] -> {group, ""}
    end
  end
end
