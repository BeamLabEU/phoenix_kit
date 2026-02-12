defmodule PhoenixKit.System.Dependencies do
  @moduledoc """
  System dependency checker for PhoenixKit.

  Probes for required system tools like ImageMagick and FFmpeg.
  Results are cached to avoid repeated system calls.
  """

  require Logger

  # Cache TTL for dependency checks (1 hour)
  @cache_ttl 3_600_000

  @doc """
  Check if ImageMagick is installed and available.

  Returns:
  - `{:ok, version}` - ImageMagick is installed with version string
  - `{:error, :not_installed}` - ImageMagick not found
  - `{:error, reason}` - Other error occurred
  """
  def check_imagemagick do
    case check_command("identify", ["--version"]) do
      {:ok, output} ->
        # Extract version from output (first line is usually the version)
        version =
          output
          |> String.split("\n")
          |> List.first("")
          |> String.trim()

        {:ok, version}

      {:error, :enoent} ->
        {:error, :not_installed}

      error ->
        error
    end
  rescue
    _error -> {:error, :not_installed}
  end

  @doc """
  Check if Poppler (pdftoppm/pdfinfo) is installed and available.

  Returns:
  - `{:ok, version}` - Poppler is installed with version string
  - `{:error, :not_installed}` - Poppler not found
  - `{:error, reason}` - Other error occurred
  """
  def check_poppler do
    case System.cmd("pdftoppm", ["-v"], stderr_to_stdout: true) do
      {output, _exit_code} ->
        version =
          output
          |> String.split("\n")
          |> List.first("")
          |> String.trim()

        if version != "", do: {:ok, version}, else: {:error, :not_installed}
    end
  rescue
    _error -> {:error, :not_installed}
  end

  @doc """
  Check if FFmpeg is installed and available.

  Returns:
  - `{:ok, version}` - FFmpeg is installed with version string
  - `{:error, :not_installed}` - FFmpeg not found
  - `{:error, reason}` - Other error occurred
  """
  def check_ffmpeg do
    case check_command("ffmpeg", ["-version"]) do
      {:ok, output} ->
        # Extract version from output (first line is usually the version)
        version =
          output
          |> String.split("\n")
          |> List.first("")
          |> String.trim()

        {:ok, version}

      {:error, :enoent} ->
        {:error, :not_installed}

      error ->
        error
    end
  rescue
    _error -> {:error, :not_installed}
  end

  @doc """
  Check if ImageMagick is installed (cached version).

  Returns the cached result if available, otherwise probes system.
  """
  def check_imagemagick_cached do
    case get_cached("imagemagick") do
      nil ->
        result = check_imagemagick()
        cache_result("imagemagick", result)
        result

      cached_result ->
        cached_result
    end
  end

  @doc """
  Check if Poppler is installed (cached version).

  Returns the cached result if available, otherwise probes system.
  """
  def check_poppler_cached do
    case get_cached("poppler") do
      nil ->
        result = check_poppler()
        cache_result("poppler", result)
        result

      cached_result ->
        cached_result
    end
  end

  @doc """
  Check if FFmpeg is installed (cached version).

  Returns the cached result if available, otherwise probes system.
  """
  def check_ffmpeg_cached do
    case get_cached("ffmpeg") do
      nil ->
        result = check_ffmpeg()
        cache_result("ffmpeg", result)
        result

      cached_result ->
        cached_result
    end
  end

  @doc """
  Clear the dependency check cache.

  Useful for testing or when you know system dependencies have changed.
  """
  def clear_cache do
    :persistent_term.erase(:phoenix_kit_deps_imagemagick)
    :persistent_term.erase(:phoenix_kit_deps_ffmpeg)
    :persistent_term.erase(:phoenix_kit_deps_poppler)
    :ok
  end

  # Private helper to check a system command
  defp check_command(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {_output, _code} ->
        {:error, :command_failed}
    end
  rescue
    e in ErlangError ->
      # ErlangError with :enoent means command not found
      if e.reason == :enoent do
        {:error, :enoent}
      else
        {:error, "Error checking #{command}: #{inspect(e.reason)}"}
      end

    error ->
      {:error, "Unexpected error: #{inspect(error)}"}
  end

  # Get cached result with TTL check
  defp get_cached(tool) do
    cache_key = String.to_atom("phoenix_kit_deps_#{tool}")

    case :persistent_term.get(cache_key, nil) do
      {timestamp, result} ->
        current_time = System.monotonic_time(:millisecond)

        if current_time - timestamp < @cache_ttl do
          result
        else
          # Cache expired
          :persistent_term.erase(cache_key)
          nil
        end

      _ ->
        nil
    end
  end

  # Cache a result with timestamp
  defp cache_result(tool, result) do
    cache_key = String.to_atom("phoenix_kit_deps_#{tool}")
    timestamp = System.monotonic_time(:millisecond)
    :persistent_term.put(cache_key, {timestamp, result})
  end
end
