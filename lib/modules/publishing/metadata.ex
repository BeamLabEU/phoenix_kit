defmodule PhoenixKit.Modules.Publishing.Metadata do
  @moduledoc """
  Content metadata helpers for the Publishing module.

  Provides title extraction from markdown/component content.
  """

  @default_title PhoenixKit.Modules.Publishing.Constants.default_title()

  @doc """
  Extracts title from markdown content.
  Looks for the first H1 heading (# Title) within the first few lines.
  Falls back to the first line if no H1 found.
  """
  @spec extract_title_from_content(String.t()) :: String.t()
  def extract_title_from_content(content) when is_binary(content) do
    content
    |> String.trim()
    |> do_extract_title()
  end

  def extract_title_from_content(_), do: @default_title

  defp do_extract_title(""), do: @default_title

  defp do_extract_title(content) do
    content
    |> extract_title_from_lines()
    |> case do
      @default_title ->
        extract_title_from_components(content) || @default_title

      title ->
        title
    end
  end

  defp extract_title_from_lines(""), do: @default_title

  defp extract_title_from_lines(content) do
    lines =
      content
      |> extract_candidate_lines()
      |> Enum.take(15)

    # Look for first H1 heading (# Title)
    h1_line =
      Enum.find(lines, fn line ->
        String.starts_with?(line, "# ") and String.length(line) > 2
      end)

    cond do
      h1_line != nil ->
        h1_line
        |> String.trim_leading("# ")
        |> String.trim()

      not Enum.empty?(lines) ->
        List.first(lines)
        |> String.slice(0, 100)

      true ->
        @default_title
    end
  end

  defp extract_candidate_lines(content) do
    {lines, _depth} =
      content
      |> String.split("\n")
      |> Enum.reduce({[], 0}, fn raw_line, {acc, depth} ->
        line = String.trim(raw_line)

        cond do
          line == "" and depth == 0 ->
            {acc, depth}

          component_self_closing?(line) ->
            {acc, depth}

          component_open?(line) ->
            {acc, depth + 1}

          depth > 0 and multiline_self_close?(raw_line) ->
            {acc, max(depth - 1, 0)}

          component_close?(line) and depth > 0 ->
            {acc, max(depth - 1, 0)}

          depth > 0 ->
            {acc, depth}

          true ->
            {[line | acc], depth}
        end
      end)

    lines
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp component_open?(line) do
    String.starts_with?(line, "<") and
      not String.starts_with?(line, "</") and
      Regex.match?(~r/^<[A-Z][\w-]*/, line)
  end

  defp component_close?(line) do
    Regex.match?(~r{^</[A-Z][\w-]*>}, line)
  end

  defp component_self_closing?(line) do
    component_open?(line) and String.ends_with?(line, "/>")
  end

  defp multiline_self_close?(line) do
    line
    |> String.trim()
    |> case do
      "/>" -> true
      ">" -> false
      other -> String.ends_with?(other, "/>")
    end
  end

  defp extract_title_from_components(content) do
    component_title(content, "Headline") ||
      component_attribute(content, "Hero", "title") ||
      component_title(content, "Title")
  end

  defp component_title(content, tag) do
    regex = ~r/<#{tag}\b[^>]*>(.*?)<\/#{tag}>/is

    case Regex.run(regex, content, capture: :all_but_first) do
      [inner | _] -> sanitize_component_text(inner)
      _ -> nil
    end
  end

  defp component_attribute(content, tag, attr) do
    regex = ~r/<#{tag}\b[^>]*#{attr}="([^"]+)"[^>]*>/i

    case Regex.run(regex, content, capture: :all_but_first) do
      [value | _] -> sanitize_component_text(value)
      _ -> nil
    end
  end

  defp sanitize_component_text(text) do
    text
    |> String.trim()
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      cleaned -> String.slice(cleaned, 0, 100)
    end
  end
end
