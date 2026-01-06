defmodule PhoenixKit.Modules.Blogging.PageBuilder do
  @moduledoc """
  Rendering pipeline for .phk (PhoenixKit) page files.

  Processes component-based page definitions through:
  1. Read .phk file
  2. Parse XML to AST
  3. Inject dynamic data ({{variable}} placeholders)
  4. Resolve components (map to actual component modules)
  5. Apply theme/variants
  6. Render to HTML
  """

  alias PhoenixKit.Modules.Blogging.PageBuilder.Parser
  alias PhoenixKit.Modules.Blogging.PageBuilder.Renderer

  @type assigns :: map()
  @type ast :: map()
  @type render_result :: {:ok, Phoenix.LiveView.Rendered.t()} | {:error, term()}

  @doc """
  Renders a .phk page file to HTML.

  ## Examples

      iex> PageBuilder.render_page("/path/to/page.phk", %{user: %{name: "Alice"}})
      {:ok, rendered_html}
  """
  @spec render_page(String.t(), assigns()) :: render_result()
  def render_page(page_path, assigns \\ %{}) do
    with {:ok, content} <- read_page_file(page_path),
         {:ok, ast} <- parse_to_ast(content),
         {:ok, ast_with_data} <- inject_dynamic_data(ast, assigns),
         {:ok, resolved} <- resolve_components(ast_with_data),
         {:ok, themed} <- apply_theme(resolved, assigns),
         {:ok, html} <- render_to_html(themed, assigns) do
      {:ok, html}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Renders .phk content directly (without file path).
  """
  @spec render_content(String.t(), assigns()) :: render_result()
  def render_content(content, assigns \\ %{}) do
    with {:ok, ast} <- parse_to_ast(content),
         {:ok, ast_with_data} <- inject_dynamic_data(ast, assigns),
         {:ok, resolved} <- resolve_components(ast_with_data),
         {:ok, themed} <- apply_theme(resolved, assigns),
         {:ok, html} <- render_to_html(themed, assigns) do
      {:ok, html}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Step 1: Read .phk file
  defp read_page_file(page_path) do
    case File.read(page_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  # Step 2: Parse XML to AST
  defp parse_to_ast(content) do
    Parser.parse(content)
  end

  # Step 3: Inject dynamic data (replace {{variable}} placeholders)
  defp inject_dynamic_data(ast, assigns) do
    {:ok, inject_assigns(ast, assigns)}
  end

  # Step 4: Resolve components (map XML tags to actual component modules)
  defp resolve_components(ast) do
    {:ok, ast}
  end

  # Step 5: Apply theme/variant settings
  defp apply_theme(ast, _assigns) do
    {:ok, ast}
  end

  # Step 6: Render to HTML
  defp render_to_html(ast, assigns) do
    Renderer.render(ast, assigns)
  end

  # Recursively inject assigns into AST nodes
  defp inject_assigns(ast, assigns) when is_map(ast) do
    ast
    |> Map.update(:content, nil, &inject_assigns(&1, assigns))
    |> Map.update(:attributes, %{}, &inject_assigns(&1, assigns))
    |> Map.update(:children, [], &inject_assigns(&1, assigns))
  end

  defp inject_assigns(ast, assigns) when is_list(ast) do
    Enum.map(ast, &inject_assigns(&1, assigns))
  end

  defp inject_assigns(content, assigns) when is_binary(content) do
    interpolate_string(content, assigns)
  end

  defp inject_assigns(value, _assigns), do: value

  # Interpolate {{variable}} placeholders
  defp interpolate_string(string, assigns) do
    Regex.replace(~r/\{\{([^}]+)\}\}/, string, fn _, path ->
      get_nested_value(assigns, String.trim(path)) |> to_string()
    end)
  end

  # Get nested value from assigns (e.g., "user.name" -> assigns.user.name)
  defp get_nested_value(map, path) do
    path
    |> String.split(".")
    |> Enum.reduce(map, fn key, acc ->
      case acc do
        %{} -> Map.get(acc, key) || Map.get(acc, String.to_existing_atom(key))
        _ -> nil
      end
    end)
  rescue
    _ -> ""
  end
end
