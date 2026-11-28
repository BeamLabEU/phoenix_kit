defmodule PhoenixKit.Install.AssetRebuild do
  @moduledoc """
  Handles asset rebuilding for PhoenixKit installations and updates.

  This module provides asset rebuilding using the standard Phoenix asset pipeline.
  It tries multiple build commands in order of preference:

  1. `mix assets.build` - Phoenix 1.8+ standard asset pipeline
  2. `mix esbuild <profile> --minify` - Individual ESBuild compilation
  3. `mix tailwind <profile> --minify` - Individual Tailwind compilation
  4. `npm run build` - NPM build script fallback (only with a `package.json`)
  5. `npm run build.css` - NPM CSS build script fallback (same)

  The esbuild/tailwind profile is the one the host configured: `mix phx.new`
  names it after the app (`config :esbuild, my_app: [...]`), older apps used
  `default`. A tool with neither configured is skipped rather than called
  with a profile it does not have.

  The `mix` commands run in a child process while this task's own `mix`
  holds the build lock, and `mix assets.build` starts with `compile`: the
  child then waited on the parent's lock until the timeout. They are run
  with `MIX_OS_CONCURRENCY_LOCK=0` — the parent is idle, waiting for the
  child, so nothing else compiles meanwhile.

  Assets are always rebuilt to ensure consistency after PhoenixKit updates.
  """

  # Keys of `config :esbuild` / `config :tailwind` that are settings, not
  # build profiles.
  @tool_settings [:version, :path, :target, :cacerts_path, :version_check]

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

    build_commands(
      app: Mix.Project.config()[:app],
      esbuild_profiles: configured_profiles(:esbuild),
      tailwind_profiles: configured_profiles(:tailwind),
      package_json?: File.exists?("package.json")
    )
    |> execute_first_available_command(verbose)
  end

  @doc false
  # The commands to try, in order, for a host described by `facts`:
  # `:app` (the host's OTP app), `:esbuild_profiles` / `:tailwind_profiles`
  # (the profile names its config declares) and `:package_json?`.
  @spec build_commands(keyword()) :: [{String.t(), [String.t()]}]
  def build_commands(facts) do
    app = Keyword.get(facts, :app)

    tool_commands =
      for tool <- [:esbuild, :tailwind],
          profile = pick_profile(Keyword.get(facts, :"#{tool}_profiles", []), app),
          do: {"mix", [to_string(tool), to_string(profile), "--minify"]}

    npm_commands =
      if Keyword.get(facts, :package_json?, false),
        do: [{"npm", ["run", "build"]}, {"npm", ["run", "build.css"]}],
        else: []

    [{"mix", ["assets.build"]}] ++ tool_commands ++ npm_commands
  end

  # The app-named profile (phx.new), else `default` (older generators).
  defp pick_profile(profiles, app) do
    cond do
      app && app in profiles -> app
      :default in profiles -> :default
      true -> nil
    end
  end

  defp configured_profiles(tool) do
    tool
    |> Application.get_all_env()
    |> Keyword.keys()
    |> Enum.reject(&(&1 in @tool_settings))
  end

  @doc false
  # Environment for a child command: a child `mix` must not wait on the build
  # lock this task's own `mix` holds (see the moduledoc).
  @spec command_env(String.t()) :: [{String.t(), String.t()}]
  def command_env("mix"), do: [{"MIX_OS_CONCURRENCY_LOCK", "0"}]
  def command_env(_cmd), do: []

  # Try commands in order until one succeeds
  defp execute_first_available_command([], verbose) do
    if verbose do
      IO.puts("⚠️  No asset build command succeeded — assets were NOT rebuilt")
    end

    :rebuild_failed
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
            case System.cmd(cmd, args, stderr_to_stdout: true, env: command_env(cmd)) do
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
