defmodule PhoenixKit.Install.RuntimeDetector do
  @moduledoc """
  Detects Phoenix runtime configuration patterns and determines appropriate config strategy.

  This module analyzes Phoenix project configuration files to determine:
  - Whether the project uses runtime.exs patterns
  - The appropriate configuration file to modify
  - The correct insertion location for PhoenixKit configuration
  """

  @doc """
  Detects if the project uses runtime configuration patterns.

  ## Returns

  - `:runtime` - Uses runtime.exs with conditional blocks
  - `:dev_exs` - Uses simple dev.exs file
  - `:config_exs` - Uses config.exs with environment variables

  ## Examples

      iex> RuntimeDetector.detect_config_pattern()
      :runtime
  """
  def detect_config_pattern do
    cond do
      runtime_exists?() && has_runtime_patterns?() -> :runtime
      dev_exs_exists?() && simple_dev_config?() -> :dev_exs
      true -> :config_exs
    end
  end

  @doc """
  Checks if runtime.exs file exists in the project.

  ## Returns

  `true` if runtime.exs exists, `false` otherwise.
  """
  def runtime_exists? do
    File.exists?("config/runtime.exs")
  end

  @doc """
  Checks if runtime.exs contains runtime configuration patterns.

  ## Returns

  `true` if runtime patterns are detected, `false` otherwise.
  """
  def has_runtime_patterns? do
    case File.read("config/runtime.exs") do
      {:ok, content} ->
        runtime_patterns?(content)

      {:error, _} ->
        false
    end
  end

  @doc """
  Checks if dev.exs file exists and is simple enough to modify.

  ## Returns

  `true` if simple dev.exs exists, `false` otherwise.
  """
  def simple_dev_config? do
    case File.read("config/dev.exs") do
      {:ok, content} ->
        not (runtime_patterns?(content) or has_complex_conditionals?(content))

      {:error, _} ->
        false
    end
  end

  @doc """
  Checks if dev.exs file exists.

  ## Returns

  `true` if dev.exs exists, `false` otherwise.
  """
  def dev_exs_exists? do
    File.exists?("config/dev.exs")
  end

  @doc """
  Finds the appropriate insertion point for PhoenixKit configuration.

  ## Returns

  - `{:runtime, line_number}` - Insert at specific line in runtime.exs
  - `{:dev_exs, line_number}` - Insert at end of dev.exs
  - `{:config_exs, line_number}` - Insert in config.exs with env check

  ## Examples

      iex> RuntimeDetector.find_insertion_point()
      {:runtime, 76}
  """
  def find_insertion_point do
    case detect_config_pattern() do
      :runtime ->
        line_num = find_runtime_insertion_point()
        {:runtime, line_num}

      :dev_exs ->
        {:dev_exs, find_end_of_file("config/dev.exs")}

      :config_exs ->
        {:config_exs, find_end_of_file("config/config.exs")}
    end
  end

  @doc """
  Finds the appropriate location within runtime.exs for development configuration.

  ## Returns

  `line_number` where PhoenixKit config should be inserted.
  """
  def find_runtime_insertion_point do
    case File.read("config/runtime.exs") do
      {:ok, content} ->
        lines = String.split(content, "\n")

        # Look for the dev configuration block
        case find_dev_block_end(lines) do
          {:ok, line_num} ->
            line_num

          {:error, :no_dev_block} ->
            # If no dev block found, insert after imports
            find_insertion_after_imports(lines)
        end

      {:error, _} ->
        1
    end
  end

  # Private functions

  defp runtime_patterns?(content) do
    patterns = [
      ~r/config_env\(\)/,
      ~r/System\.get_env/,
      ~r/Dotenvy\.env!/,
      ~r/\.env\.\s*Atom\.to_string/,
      ~r/if.*config_env.*==/
    ]

    Enum.any?(patterns, &Regex.match?(&1, content))
  end

  defp has_complex_conditionals?(content) do
    patterns = [
      # Multi-line if blocks
      ~r/if.*do.*end/s,
      # Case statements
      ~r/case.*do.*end/s,
      # Cond statements
      ~r/cond.*do/s
    ]

    Enum.any?(patterns, &Regex.match?(&1, content))
  end

  defp find_dev_block_end(lines) do
    lines
    |> Enum.with_index()
    |> Enum.find(fn {line, _index} ->
      String.contains?(line, "config :swoosh, :api_client, false") &&
        String.contains?(line, "end")
    end)
    |> case do
      {_line, index} ->
        # Find the actual "end" of the dev block
        remaining_lines = Enum.drop(lines, index + 1)

        case find_next_config_block(remaining_lines) do
          {:ok, next_line_num} ->
            {:ok, index + 1 + next_line_num - 1}

          :not_found ->
            {:ok, index + 1}
        end

      nil ->
        {:error, :no_dev_block}
    end
  end

  defp find_next_config_block(lines) do
    lines
    |> Enum.with_index()
    |> Enum.find(fn {line, _index} ->
      String.starts_with?(String.trim(line), "config ") ||
        String.starts_with?(String.trim(line), "if config_env")
    end)
    |> case do
      {_, index} -> {:ok, index}
      nil -> :not_found
    end
  end

  defp find_insertion_after_imports(lines) do
    lines
    |> Enum.with_index()
    |> Enum.find(fn {line, _index} ->
      String.starts_with?(String.trim(line), "import Config")
    end)
    |> case do
      {_, index} -> index + 1
      nil -> 1
    end
  end

  defp find_end_of_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        String.split(content, "\n") |> length()

      {:error, _} ->
        1
    end
  end
end
