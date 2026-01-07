defmodule PhoenixKit.Modules.Publishing.PageBuilder.Renderer do
  @moduledoc """
  Renders AST nodes to HTML by delegating to component modules.
  """

  @doc """
  Renders an AST node to HTML.
  """
  def render(ast, assigns) when is_map(ast) do
    case resolve_component(ast.type) do
      {:ok, component_module} ->
        render_component(component_module, ast, assigns)

      {:error, :not_found} ->
        # Fallback for unknown components
        render_unknown(ast, assigns)
    end
  end

  def render(ast, _assigns) when is_list(ast) do
    {:ok,
     Phoenix.HTML.raw(
       Enum.map_join(ast, fn node ->
         case render(node, %{}) do
           {:ok, html} -> Phoenix.HTML.safe_to_string(html)
           {:error, _} -> ""
         end
       end)
     )}
  end

  def render(content, _assigns) when is_binary(content) do
    {:ok, Phoenix.HTML.raw(content)}
  end

  # Resolve component type to module
  defp resolve_component(:page), do: {:ok, PhoenixKit.Modules.Publishing.Components.Page}
  defp resolve_component(:hero), do: {:ok, PhoenixKit.Modules.Publishing.Components.Hero}
  defp resolve_component(:headline), do: {:ok, PhoenixKit.Modules.Publishing.Components.Headline}

  defp resolve_component(:subheadline),
    do: {:ok, PhoenixKit.Modules.Publishing.Components.Subheadline}

  defp resolve_component(:cta), do: {:ok, PhoenixKit.Modules.Publishing.Components.CTA}
  defp resolve_component(:image), do: {:ok, PhoenixKit.Modules.Publishing.Components.Image}
  defp resolve_component(:video), do: {:ok, PhoenixKit.Modules.Publishing.Components.Video}

  defp resolve_component(:entityform),
    do: {:ok, PhoenixKit.Modules.Publishing.Components.EntityForm}

  defp resolve_component(_), do: {:error, :not_found}

  # Render using the component module
  defp render_component(component_module, ast, assigns) do
    component_assigns = build_component_assigns(ast, assigns)

    try do
      html = component_module.render(component_assigns)
      {:ok, html}
    rescue
      e ->
        {:error, {:render_error, e}}
    end
  end

  # Build assigns map for component
  defp build_component_assigns(ast, parent_assigns) do
    base_assigns = %{
      __changed__: nil,
      variant: Map.get(ast.attributes, "variant", "default"),
      attributes: ast.attributes,
      content: ast[:content],
      children: ast[:children] || []
    }

    Map.merge(parent_assigns, base_assigns)
  end

  # Fallback renderer for unknown components
  defp render_unknown(ast, assigns) do
    content =
      cond do
        ast[:content] ->
          ast.content

        ast[:children] ->
          Enum.map_join(ast.children, fn child ->
            case render(child, assigns) do
              {:ok, html} -> Phoenix.HTML.safe_to_string(html)
              _ -> ""
            end
          end)

        true ->
          ""
      end

    {:ok, Phoenix.HTML.raw("<div class=\"unknown-component\">#{content}</div>")}
  end
end
