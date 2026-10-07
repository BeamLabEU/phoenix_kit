defmodule PhoenixKit.System.Dependencies do
  @moduledoc """

  System dependency checker for PhoenixKit.

  Probes for the external programs PhoenixKit shells out to (ImageMagick,
  FFmpeg, Poppler) and for libvips, which arrives with the optional `vix`
  package; `external_tools/0` lists them all. Results are cached
  to avoid repeated system calls.
  """

  # `vix` is optional (it bundles libvips): without it these calls are never reached.
  @compile {:no_warn_undefined, Vix.Vips}

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

  # The external programs PhoenixKit shells out to. `args` print the
  # version; `pattern` pulls the bare version number out of that output.
  # A compiled `~r` carries a runtime reference on OTP 28, so a list of them
  # cannot live in a module attribute that a function body reads — Elixir
  # refuses to escape it at compile time. Building the list in a function
  # keeps the sigils and compiles everywhere.
  defp tools do
    [
      %{
        id: :imagemagick,
        name: "ImageMagick",
        command: "identify",
        args: ["-version"],
        pattern: ~r/ImageMagick\s+(\S+)/,
        used_for: :images
      },
      %{
        id: :magick,
        name: "ImageMagick 7",
        command: "magick",
        args: ["-version"],
        pattern: ~r/ImageMagick\s+(\S+)/,
        used_for: :tiles
      },
      # Not a program on the PATH: libvips comes with the optional `vix` Elixir
      # package, which bundles it, so "found" means that package is loaded and
      # its library answers (`probe_libvips/0`).
      %{
        id: :libvips,
        name: "libvips",
        command: "vix",
        args: [],
        pattern: ~r/(\d+\.\d+\.\d+)/,
        used_for: :focus_crop
      },
      %{
        id: :ffmpeg,
        name: "FFmpeg",
        command: "ffmpeg",
        args: ["-version"],
        pattern: ~r/version\s+(\S+)/,
        used_for: :video
      },
      %{
        id: :ffprobe,
        name: "FFprobe",
        command: "ffprobe",
        args: ["-version"],
        pattern: ~r/version\s+(\S+)/,
        used_for: :video_metadata
      },
      %{
        id: :pdftoppm,
        name: "Poppler pdftoppm",
        command: "pdftoppm",
        args: ["-v"],
        pattern: ~r/version\s+(\S+)/,
        used_for: :pdf_previews
      },
      %{
        id: :pdfinfo,
        name: "Poppler pdfinfo",
        command: "pdfinfo",
        args: ["-v"],
        pattern: ~r/version\s+(\S+)/,
        used_for: :pdf_metadata
      }
    ]
  end

  @typedoc "One external program and whether it was found."
  @type tool :: %{
          id: atom(),
          name: String.t(),
          command: String.t(),
          used_for: atom(),
          status: {:ok, String.t()} | {:error, :not_installed}
        }

  @doc """
  Every external program PhoenixKit uses, each with its detected status:
  `{:ok, version}` (the bare version number, or the first line of the
  version output when no number is found) or `{:error, :not_installed}`.

  Cached like the single checks; `clear_cache/0` forces a fresh probe.
  """
  @spec external_tools() :: [tool()]
  def external_tools do
    Enum.map(tools(), fn tool ->
      status =
        case get_cached("tool_#{tool.id}") do
          nil ->
            result = probe_tool(tool)
            cache_result("tool_#{tool.id}", result)
            result

          cached_result ->
            cached_result
        end

      tool
      |> Map.take([:id, :name, :command, :used_for])
      |> Map.put(:status, status)
    end)
  end

  # libvips is found by asking the `vix` package for the version of the library it
  # carries; the package is optional, so its absence is not a compile warning. A package that is there
  # but whose library does not load answers like one that is not.
  defp probe_libvips do
    if Code.ensure_loaded?(Vix.Vips) and function_exported?(Vix.Vips, :version, 0) do
      {:ok, to_string(Vix.Vips.version())}
    else
      {:error, :not_installed}
    end
  rescue
    _ -> {:error, :not_installed}
  catch
    _, _ -> {:error, :not_installed}
  end

  # A tool is found by its executable; its version output is read whatever
  # the exit code (`pdftoppm -v` exits non-zero on older poppler).
  defp probe_tool(%{id: :libvips}), do: probe_libvips()

  defp probe_tool(tool) do
    case System.find_executable(tool.command) do
      nil ->
        {:error, :not_installed}

      path ->
        {output, _code} = System.cmd(path, tool.args, stderr_to_stdout: true)

        case Regex.run(tool.pattern, output) do
          [_, version] ->
            {:ok, version}

          _ ->
            {:ok, output |> String.split("\n") |> List.first("") |> String.trim()}
        end
    end
  rescue
    _error -> {:error, :not_installed}
  end

  @doc """
  Clear the dependency check cache.

  Useful for testing or when you know system dependencies have changed.
  """
  def clear_cache do
    :persistent_term.erase(:phoenix_kit_deps_imagemagick)
    :persistent_term.erase(:phoenix_kit_deps_ffmpeg)
    :persistent_term.erase(:phoenix_kit_deps_poppler)
    Enum.each(tools(), &:persistent_term.erase(:"phoenix_kit_deps_tool_#{&1.id}"))
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
      # A missing command raises ErlangError with :enoent in `original`
      # (`reason` is nil for it)
      if e.original == :enoent do
        {:error, :enoent}
      else
        {:error, "Error checking #{command}: #{inspect(e.original)}"}
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
