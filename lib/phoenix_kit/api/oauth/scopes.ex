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

  @max_requested 64
  @token ~r/\A[\x21\x23-\x5B\x5D-\x7E]{1,200}\z/

  @type entry :: %{
          scope: String.t(),
          group: String.t(),
          action: String.t(),
          read?: boolean(),
          tools: [String.t()]
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
  What the consent screen shows for `scopes`: one entry per scope, the group (`module.resource`),
  the action, whether it only reads, and the names of the tools it unlocks. Sorted by group, reads
  first.
  """
  @spec describe([String.t()]) :: [entry()]
  def describe(scopes) when is_list(scopes) do
    tools =
      Registry.all_tools()
      |> Enum.filter(&(&1.audience == :admin and &1.scope in scopes))
      |> Enum.group_by(& &1.scope, & &1.name)

    scopes
    |> Enum.uniq()
    |> Enum.map(fn scope ->
      {group, action} = split(scope)

      %{
        scope: scope,
        group: group,
        action: action,
        read?: read?(scope),
        tools: tools |> Map.get(scope, []) |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{&1.group, not &1.read?, &1.action})
  end

  defp split(scope) do
    case String.split(scope, ":", parts: 2) do
      [group, action] -> {group, action}
      [group] -> {group, ""}
    end
  end
end
