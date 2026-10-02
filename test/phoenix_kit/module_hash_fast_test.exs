defmodule PhoenixKit.ModuleHashFastTest do
  @moduledoc """
  `ModuleDiscovery.module_hash_fast/0` is what the host router's
  `__mix_recompile__?/0` evaluates on every compile — in dev, on every request.
  It must answer like `module_hash/0` (a module added or removed still forces a
  router recompile) while reading no beam when the disk did not change.

  DB-free. Sync: the memo is one global `:persistent_term`, the beam-read counter
  is a global trace, and `:modules` config is global.

  Scan work is measured through `:beam_lib.chunks/2` calls, not mocked.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.ModuleDiscovery

  @moduletag :tmp_dir

  @old {{2020, 1, 1}, {0, 0, 0}}
  @older {{2019, 6, 1}, {0, 0, 0}}

  setup_all do
    # `module_hash_fast/0` never remembers a fingerprint holding an mtime newer
    # than ~2 s, and the suite has just compiled and written files. Let the
    # environment settle once so the memo-hit tests are deterministic.
    Process.sleep(2_200)
    :ok
  end

  setup do
    ModuleDiscovery.clear_hash_memo()
    on_exit(&ModuleDiscovery.clear_hash_memo/0)
    :ok
  end

  test "answers like module_hash/0, and the second call reads no beam", %{tmp_dir: tmp_dir} do
    write_dep(tmp_dir, :hash_fast_fixture_same, aged: true)

    reads_during(fn reads ->
      assert ModuleDiscovery.module_hash_fast() == ModuleDiscovery.module_hash()
      first = reads.()
      assert first > 0, "the first call has to scan"

      ModuleDiscovery.clear_hash_memo()
      hash = ModuleDiscovery.module_hash_fast()
      after_rescan = reads.()
      assert after_rescan > first

      for _ <- 1..10, do: assert(ModuleDiscovery.module_hash_fast() == hash)
      assert reads.() == after_rescan
    end)
  end

  test "a module that appears changes the hash, exactly as module_hash/0 does", %{
    tmp_dir: tmp_dir
  } do
    # What `current_hash` bakes into the router at compile time.
    baked = ModuleDiscovery.module_hash()
    assert ModuleDiscovery.module_hash_fast() == baked

    write_dep(tmp_dir, :hash_fast_fixture_new, aged: true)

    refute ModuleDiscovery.module_hash_fast() == baked,
           "`__mix_recompile__?/0` would stay false and the router would keep its stale routes"

    assert ModuleDiscovery.module_hash_fast() == ModuleDiscovery.module_hash()

    File.rm_rf!(Path.join(tmp_dir, "hash_fast_fixture_new"))
    assert ModuleDiscovery.module_hash_fast() == baked
  end

  test "a beam that loses its marker is noticed, even rewritten in place", %{tmp_dir: tmp_dir} do
    mod = write_dep(tmp_dir, :hash_fast_fixture_unmark, aged: true)
    marked = ModuleDiscovery.module_hash_fast()
    assert mod in ModuleDiscovery.scan_beam_files()

    # Same file name, same directory: only the beam's own mtime/size change.
    beam = Path.join([tmp_dir, "hash_fast_fixture_unmark", "#{mod}.beam"])
    # The unmarked beam may carry any module name: with no marker the scan
    # ignores it. A different one avoids redefining the loaded fixture module.
    unmarked = Module.concat(mod, Unmarked)
    [{^unmarked, binary}] = Code.compile_string("defmodule #{inspect(unmarked)} do\nend")
    File.write!(beam, binary)
    File.touch!(beam, @older)

    refute ModuleDiscovery.module_hash_fast() == marked
    assert ModuleDiscovery.module_hash_fast() == ModuleDiscovery.module_hash()
    refute mod in ModuleDiscovery.scan_beam_files()
  end

  test "a change to the :modules config is noticed" do
    original = Application.get_env(:phoenix_kit, :modules)

    on_exit(fn ->
      if original,
        do: Application.put_env(:phoenix_kit, :modules, original),
        else: Application.delete_env(:phoenix_kit, :modules)
    end)

    before_hash = ModuleDiscovery.module_hash_fast()

    Application.put_env(:phoenix_kit, :modules, (original || []) ++ [HashFastConfigProbe])

    refute ModuleDiscovery.module_hash_fast() == before_hash
    assert ModuleDiscovery.module_hash_fast() == ModuleDiscovery.module_hash()
  end

  test "a fingerprint holding a just-written file is never remembered", %{tmp_dir: tmp_dir} do
    # Fresh mtimes: within the filesystem's timestamp resolution a rewrite could
    # go unseen, so every call must keep scanning until the files settle.
    write_dep(tmp_dir, :hash_fast_fixture_fresh, aged: false)

    reads_during(fn reads ->
      ModuleDiscovery.module_hash_fast()
      first = reads.()
      assert first > 0

      ModuleDiscovery.module_hash_fast()
      assert reads.() > first, "a fresh fingerprint must not be answered from the memo"
    end)
  end

  defp reads_during(fun) do
    mfa = {:beam_lib, :chunks, 2}
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

  # A fake dep ebin in `<tmp_dir>/<app>`: a `<app>.app` depending on :phoenix_kit
  # plus one beam carrying `@phoenix_kit_module true`, on the code path until the
  # test exits. `aged: true` back-dates everything so it counts as settled.
  defp write_dep(tmp_dir, app, opts) do
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

    beam = Path.join(dir, "#{module}.beam")
    app_file = Path.join(dir, "#{app}.app")
    File.write!(beam, binary)

    File.write!(app_file, """
    {application, #{app}, [
      {description, "fixture"},
      {vsn, "0.1.0"},
      {modules, ['#{module}']},
      {applications, [kernel, stdlib, phoenix_kit]}
    ]}.
    """)

    if opts[:aged], do: Enum.each([beam, app_file, dir], &File.touch!(&1, @old))

    Code.append_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)
    module
  end
end
