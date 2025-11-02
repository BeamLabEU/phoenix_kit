# ============================================================================
# COMMENTED OUT: Component-based rendering system - XML Parser
# ============================================================================
# This module was part of an experimental component-based page building system
# using XML-style markup (.phk files) with swappable design variants.
# Related to: lib/phoenix_kit/blogging/page_builder.ex
# ============================================================================

# defmodule PhoenixKitWeb.Live.Modules.Blogging.PageBuilder.Parser do
#   @moduledoc """
#   Parses .phk (PhoenixKit) XML-style markup into an AST.
#
#   Example input:
#   ```xml
#   <Page slug="home">
#     <Hero variant="split-image">
#       <Headline>Welcome to PhoenixKit</Headline>
#       <Subheadline>Build faster with {{framework}}</Subheadline>
#       <CTA primary="true" action="/signup">Get Started</CTA>
#     </Hero>
#   </Page>
#   ```
#
#   Output AST:
#   ```elixir
#   %{
#     type: :page,
#     attributes: %{slug: "home"},
#     children: [
#       %{
#         type: :hero,
#         attributes: %{variant: "split-image"},
#         children: [
#           %{type: :headline, content: "Welcome to PhoenixKit"},
#           %{type: :subheadline, content: "Build faster with {{framework}}"},
#           %{type: :cta, attributes: %{primary: "true", action: "/signup"}, content: "Get Started"}
#         ]
#       }
#     ]
#   }
#   ```
#   """
#
#   @doc """
#   Parses .phk XML content into an AST.
#   """
#   @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
#   def parse(content) when is_binary(content) do
#     content = String.trim(content)
#
#     case Saxy.parse_string(content, PhoenixKitWeb.Live.Modules.Blogging.PageBuilder.SaxHandler, []) do
#       {:ok, ast} -> {:ok, ast}
#       {:error, reason} -> {:error, {:parse_error, reason}}
#     end
#   rescue
#     e -> {:error, {:parse_exception, e}}
#   end
#
#   def parse(_), do: {:error, :invalid_content}
# end
#
# defmodule PhoenixKitWeb.Live.Modules.Blogging.PageBuilder.SaxHandler do
#   @moduledoc false
#   @behaviour Saxy.Handler
#
#   def handle_event(:start_document, _prolog, _state) do
#     {:ok, %{stack: [], result: nil}}
#   end
#
#   def handle_event(:end_document, _data, state) do
#     {:ok, state.result}
#   end
#
#   def handle_event(:start_element, {name, attributes}, state) do
#     node = %{
#       type: normalize_tag_name(name),
#       attributes: parse_attributes(attributes),
#       children: [],
#       content: nil
#     }
#
#     new_state = %{state | stack: [node | state.stack]}
#     {:ok, new_state}
#   end
#
#   def handle_event(:end_element, _name, %{stack: [current | rest]} = state) do
#     # Simplify node if it only has content and no children
#     simplified =
#       cond do
#         current.children == [] and is_binary(current.content) ->
#           %{
#             type: current.type,
#             attributes: current.attributes,
#             content: String.trim(current.content)
#           }
#
#         current.content == nil and current.children != [] ->
#           %{
#             type: current.type,
#             attributes: current.attributes,
#             children: Enum.reverse(current.children)
#           }
#
#         true ->
#           %{
#             type: current.type,
#             attributes: current.attributes,
#             children: Enum.reverse(current.children),
#             content: current.content && String.trim(current.content)
#           }
#       end
#
#     case rest do
#       [] ->
#         {:ok, %{state | stack: [], result: simplified}}
#
#       [parent | ancestors] ->
#         updated_parent = %{parent | children: [simplified | parent.children]}
#         {:ok, %{state | stack: [updated_parent | ancestors]}}
#     end
#   end
#
#   def handle_event(:characters, chars, %{stack: [current | rest]} = state) do
#     trimmed = String.trim(chars)
#
#     updated_current =
#       if trimmed != "" do
#         case current.content do
#           nil -> %{current | content: chars}
#           existing -> %{current | content: existing <> chars}
#         end
#       else
#         current
#       end
#
#     {:ok, %{state | stack: [updated_current | rest]}}
#   end
#
#   def handle_event(:characters, _chars, state) do
#     {:ok, state}
#   end
#
#   # Normalize tag names to atoms (Page -> :page, Hero -> :hero)
#   defp normalize_tag_name(name) do
#     name
#     |> String.downcase()
#     |> String.to_atom()
#   end
#
#   # Convert attribute list to map with string keys
#   defp parse_attributes(attrs) do
#     Enum.into(attrs, %{}, fn {key, value} ->
#       {String.downcase(key), value}
#     end)
#   end
# end
