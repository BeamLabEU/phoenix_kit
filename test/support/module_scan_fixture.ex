defmodule PhoenixKit.TestSupport.ModuleScanFixture do
  @moduledoc """
  A fake phoenix_kit-dependent dep for tests of `PhoenixKit.ModuleDiscovery`.

  Core's own test env has no such dep, so a scan reads no beams; with one of
  these on the code path every scan is visible to a `:beam_lib.chunks/2` call
  counter. Test-only — never call it from application code.
  """

  @doc """
  Writes `<tmp_dir>/<app>/` holding a `<app>.app` that depends on `:phoenix_kit`
  and one beam carrying `@phoenix_kit_module true`, and puts it on the code path
  until the calling test exits. Returns the module. The app is never started.

  `app` must be unique across the suite: the module is compiled (and loaded)
  under a name derived from it.
  """
  @spec write_dep(Path.t(), atom()) :: module()
  def write_dep(tmp_dir, app) do
    dir = Path.join(tmp_dir, to_string(app))
    File.mkdir_p!(dir)
    module = Module.concat([Macro.camelize(to_string(app))])

    [{^module, binary}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)
        @phoenix_kit_module true
      end
      """)

    File.write!(Path.join(dir, "#{module}.beam"), binary)

    File.write!(Path.join(dir, "#{app}.app"), """
    {application, #{app}, [
      {description, "fixture"},
      {vsn, "0.1.0"},
      {modules, ['#{module}']},
      {applications, [kernel, stdlib, phoenix_kit]}
    ]}.
    """)

    Code.append_path(dir)
    ExUnit.Callbacks.on_exit(fn -> Code.delete_path(dir) end)

    module
  end

  @doc """
  Removes the fixture dep's files from disk, as a rebuilt release would.
  """
  @spec remove_dep(Path.t(), atom()) :: :ok
  def remove_dep(tmp_dir, app) do
    File.rm_rf!(Path.join(tmp_dir, to_string(app)))
    :ok
  end

  @doc """
  Calls `fun` with a zero-arity reader returning how many times `mfa` (e.g.
  `{:beam_lib, :chunks, 2}`) has been called since the counter started. Tracing is
  VM-global: only from a `async: false` test.
  """
  @spec count_calls({module(), atom(), arity()}, ((-> non_neg_integer()) -> result)) :: result
        when result: var
  def count_calls(mfa, fun) do
    :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      fun.(fn ->
        {:call_count, count} = :erlang.trace_info(mfa, :call_count)
        count
      end)
    after
      :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  @doc "`count_calls/2` for the beam reads a scan performs."
  @spec count_beam_reads(((-> non_neg_integer()) -> result)) :: result when result: var
  def count_beam_reads(fun), do: count_calls({:beam_lib, :chunks, 2}, fun)
end
