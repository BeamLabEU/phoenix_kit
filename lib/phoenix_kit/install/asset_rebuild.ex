defmodule PhoenixKit.Install.AssetRebuild do
  @moduledoc """
  Handles asset rebuilding for PhoenixKit installations and updates.

  This module provides asset rebuilding using the standard Phoenix asset pipeline.
  It tries multiple build commands in order of preference:

  1. `mix assets.build` - Phoenix 1.8+ standard asset pipeline
  2. `mix esbuild default --minify` - Individual ESBuild compilation
  3. `mix tailwind default --minify` - Individual Tailwind compilation
  4. `npm run build` - NPM build script fallback
  5. `npm run build.css` - NPM CSS build script fallback

  Assets are always rebuilt to ensure consistency after PhoenixKit updates.
  """

  @doc """
  Executes asset rebuilding using standard Phoenix asset pipeline.

  ## Options
  - `:verbose` - Show detailed output (default: true)

  ## Returns
  - `:rebuild_completed` - Assets were successfully rebuilt
  - `:rebuild_failed` - Asset rebuild failed (non-critical)
  """
  def check_and_rebuild(opts \\ []) do
    verbose = Keyword.get(opts, :verbose, true)

    # Execute rebuild using Phoenix standard commands
    execute_asset_rebuild(verbose)
  end

  # Execute the actual asset rebuild process using Phoenix standards
  defp execute_asset_rebuild(verbose) do
    if verbose do
      IO.puts("🎨 Rebuilding assets using Phoenix asset pipeline...")
    end

    # Try Phoenix standard asset build commands in order of preference
    commands_to_try = [
      # Phoenix 1.8+ standard asset pipeline
      {"mix", ["assets.build"]},
      # Individual asset builders
      {"mix", ["esbuild", "default", "--minify"]},
      {"mix", ["tailwind", "default", "--minify"]},
      # Fallback to npm
      {"npm", ["run", "build"]},
      {"npm", ["run", "build.css"]}
    ]

    execute_first_available_command(commands_to_try, verbose)
  end

  # Try commands in order until one succeeds
  defp execute_first_available_command([], verbose) do
    if verbose do
      IO.puts("ℹ️  No asset build commands available - skipping asset rebuild")
    end

    :rebuild_completed
  end

  defp execute_first_available_command([{cmd, args} | rest], verbose) do
    if verbose do
      IO.puts("🔧 Trying: #{cmd} #{Enum.join(args, " ")}")
    end

    try do
      # Run command with 60 second timeout to prevent hanging
      result = run_with_timeout(cmd, args, 60_000)

      case result do
        {:ok, _output} ->
          if verbose, do: IO.puts("✅ Assets rebuilt successfully with #{cmd}!")
          :rebuild_completed

        {:error, :timeout} ->
          if verbose do
            IO.puts("⚠️  Command timed out after 60 seconds, trying next option...")
          end

          execute_first_available_command(rest, verbose)

        {:error, output} ->
          if verbose do
            IO.puts("⚠️  Command failed, trying next option...")
            IO.puts("Output: #{String.slice(output, 0, 200)}")
          end

          execute_first_available_command(rest, verbose)
      end
    rescue
      _ ->
        if verbose do
          IO.puts("❌ #{cmd} not available, trying next option...")
        end

        execute_first_available_command(rest, verbose)
    end
  end

  # Run a command with a timeout
  defp run_with_timeout(cmd, args, timeout_ms) do
    parent = self()
    ref = make_ref()

    # Spawn a process to run the command
    {pid, _} =
      spawn_monitor(fn ->
        result =
          try do
            case System.cmd(cmd, args, stderr_to_stdout: true) do
              {output, 0} -> {:ok, output}
              {output, _} -> {:error, output}
            end
          rescue
            e -> {:error, inspect(e)}
          end

        send(parent, {ref, result})
      end)

    # Wait for result or timeout
    receive do
      {^ref, result} ->
        result

      {:DOWN, _, :process, ^pid, _reason} ->
        {:error, "process crashed"}
    after
      timeout_ms ->
        # Kill the spawned process if it's still running
        Process.exit(pid, :kill)

        # Drain any pending messages from the killed process
        receive do
          {^ref, _} -> :ok
          {:DOWN, _, :process, ^pid, _} -> :ok
        after
          100 -> :ok
        end

        {:error, :timeout}
    end
  end
end
