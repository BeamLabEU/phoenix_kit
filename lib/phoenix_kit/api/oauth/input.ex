defmodule PhoenixKit.API.OAuth.Input do
  @moduledoc """
  The one question the OAuth code asks of text a stranger or an administrator typed before it
  goes anywhere near the database: can it be stored at all.

  A NUL byte and bytes that are not UTF-8 cannot be written to (or compared in) a PostgreSQL text
  column: the query raises, and an unauthenticated request would turn into an HTTP 500. `valid?/1`
  is `false` for them, in a string, in a map key or value, or anywhere inside a list or map, so
  the entries (`PhoenixKit.API.OAuth.Authorize.validate/2`, `PhoenixKit.API.OAuth.Exchange`,
  `PhoenixKit.API.OAuth.Clients`' lookup and registration, and the name of a grant's hidden key in
  `PhoenixKit.API.OAuth.Grants.create/4`) answer with their ordinary refusal instead.
  """

  @doc "Whether every string in `term` is valid UTF-8 without a NUL byte (anything else passes)."
  @spec valid?(term()) :: boolean()
  def valid?(text) when is_binary(text), do: String.valid?(text) and not nul?(text)

  def valid?(%_{}), do: true

  def valid?(map) when is_map(map),
    do: Enum.all?(map, fn {name, value} -> valid?(name) and valid?(value) end)

  def valid?(list) when is_list(list), do: Enum.all?(list, &valid?/1)
  def valid?(_other), do: true

  defp nul?(text), do: :binary.match(text, <<0>>) != :nomatch
end
