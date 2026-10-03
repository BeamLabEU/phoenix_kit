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
    # than 2 s, and mtimes are whole seconds: a file written at t is "settled"
    # from t + 3 at the latest. The suite has just compiled and written files, so
    # let the environment settle once; the memo-hit tests depend on it.
    Process.sleep(3_200)
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

  test "an .app rewritten in place to depend on :phoenix_kit is noticed", %{tmp_dir: tmp_dir} do
    # The dep starts out NOT depending on :phoenix_kit, so its marked beam is
    # ignored. Rewriting its .app in place leaves the directory's mtime alone:
    # only the `.app` file's own stat can show it.
    mod = write_dep(tmp_dir, :hash_fast_fixture_app, aged: true, depends?: false)
    before_hash = ModuleDiscovery.module_hash_fast()
    refute mod in ModuleDiscovery.scan_beam_files()

    app_file = Path.join([tmp_dir, "hash_fast_fixture_app", "hash_fast_fixture_app.app"])
    File.write!(app_file, app_spec(:hash_fast_fixture_app, mod, true))
    File.touch!(app_file, @older)

    refute ModuleDiscovery.module_hash_fast() == before_hash
    assert ModuleDiscovery.module_hash_fast() == ModuleDiscovery.module_hash()
    assert mod in ModuleDiscovery.scan_beam_files()
  end

  test "files created in a code-path directory that was empty are noticed", %{tmp_dir: tmp_dir} do
    # An existing, aged, empty directory on the code path when the memo is taken;
    # the beam and .app appear later. Neither is in the inventory, so only the
    # directory's own mtime can show it.
    dir = Path.join(tmp_dir, "hash_fast_fixture_late")
    File.mkdir_p!(dir)
    File.touch!(dir, @old)
    Code.append_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)

    before_hash = ModuleDiscovery.module_hash_fast()

    mod = write_beam(dir, :hash_fast_fixture_late, true)

    File.write!(
      Path.join(dir, "hash_fast_fixture_late.app"),
      app_spec(:hash_fast_fixture_late, mod, true)
    )

    refute ModuleDiscovery.module_hash_fast() == before_hash
    assert ModuleDiscovery.module_hash_fast() == ModuleDiscovery.module_hash()
    assert mod in ModuleDiscovery.scan_beam_files()
  end

  test "a dependent ebin that is deleted and rebuilt is noticed", %{tmp_dir: tmp_dir} do
    mod = write_dep(tmp_dir, :hash_fast_fixture_rebuilt, aged: true)
    marked = ModuleDiscovery.module_hash_fast()
    assert mod in ModuleDiscovery.scan_beam_files()

    # Rebuilt: same directory, same file names, but the module lost its marker.
    dir = Path.join(tmp_dir, "hash_fast_fixture_rebuilt")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    write_beam(dir, :hash_fast_fixture_rebuilt, false)

    File.write!(
      Path.join(dir, "hash_fast_fixture_rebuilt.app"),
      app_spec(:hash_fast_fixture_rebuilt, mod, true)
    )

    refute ModuleDiscovery.module_hash_fast() == marked
    assert ModuleDiscovery.module_hash_fast() == ModuleDiscovery.module_hash()
    refute mod in ModuleDiscovery.scan_beam_files()
  end

  test "a memo of another shape falls back to the honest hash" do
    :persistent_term.put({ModuleDiscovery, :module_hash_memo}, {:stale, :layout})
    assert ModuleDiscovery.module_hash_fast() == ModuleDiscovery.module_hash()

    :persistent_term.put({ModuleDiscovery, :module_hash_memo}, :garbage)
    assert ModuleDiscovery.module_hash_fast() == ModuleDiscovery.module_hash()
  end

  test "a miss does no more directory and .app reading than one scan", %{tmp_dir: tmp_dir} do
    write_dep(tmp_dir, :hash_fast_fixture_cost, aged: true)

    for mfa <- [{:beam_lib, :chunks, 2}, {:file, :consult, 1}, {:file, :list_dir, 1}] do
      scan =
        calls_during(mfa, fn calls ->
          ModuleDiscovery.module_hash()
          calls.()
        end)

      ModuleDiscovery.clear_hash_memo()

      miss =
        calls_during(mfa, fn calls ->
          ModuleDiscovery.module_hash_fast()
          calls.()
        end)

      assert miss <= scan, "#{inspect(mfa)}: a miss made #{miss} calls, one scan makes #{scan}"
    end
  end

  test "the router's __mix_recompile__?/0 does not re-read beams on a second call", %{
    tmp_dir: tmp_dir
  } do
    # The router is what Mix actually asks, on every compile. Reverting its check
    # to `module_hash/0` must fail here.
    assert function_exported?(PhoenixKitWeb.Router, :__mix_recompile__?, 0)
    write_dep(tmp_dir, :hash_fast_fixture_router, aged: true)

    reads_during(fn reads ->
      PhoenixKitWeb.Router.__mix_recompile__?()
      first = reads.()
      assert first > 0, "the first check has to scan"

      for _ <- 1..5, do: PhoenixKitWeb.Router.__mix_recompile__?()
      assert reads.() == first
    end)
  end

  defp reads_during(fun), do: calls_during({:beam_lib, :chunks, 2}, fun)

  defp calls_during(mfa, fun) do
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

  # A fake dep ebin in `<tmp_dir>/<app>`: a `<app>.app` (depending on
  # :phoenix_kit unless `depends?: false`) plus one beam carrying
  # `@phoenix_kit_module true`, on the code path until the test exits. `aged: true`
  # back-dates everything so it counts as settled.
  defp write_dep(tmp_dir, app, opts) do
    dir = Path.join(tmp_dir, to_string(app))
    File.mkdir_p!(dir)

    module = write_beam(dir, app, true)
    app_file = Path.join(dir, "#{app}.app")
    File.write!(app_file, app_spec(app, module, Keyword.get(opts, :depends?, true)))

    if opts[:aged] do
      beam = Path.join(dir, "#{module}.beam")
      Enum.each([beam, app_file, dir], &File.touch!(&1, @old))
    end

    Code.append_path(dir)
    on_exit(fn -> Code.delete_path(dir) end)
    module
  end

  # Writes `<Module>.beam` into `dir` and returns the module. The module name comes
  # from `app`; an unmarked beam is compiled under another name (the scan ignores
  # an unmarked beam's name) so the loaded marked module is never redefined.
  defp write_beam(dir, app, marked?) do
    module = Module.concat([Macro.camelize(to_string(app))])
    compiled = if marked?, do: module, else: Module.concat(module, Unmarked)

    marker =
      if marked? do
        "Module.register_attribute(__MODULE__, :phoenix_kit_module, persist: true)\n@phoenix_kit_module true"
      else
        ""
      end

    # A marked module is compiled once per name (each test uses its own app).
    [{^compiled, binary}] =
      Code.compile_string("defmodule #{inspect(compiled)} do\n#{marker}\nend")

    File.write!(Path.join(dir, "#{module}.beam"), binary)
    module
  end

  defp app_spec(app, module, depends?) do
    extra = if depends?, do: ", phoenix_kit", else: ""

    """
    {application, #{app}, [
      {description, "fixture"},
      {vsn, "0.1.0"},
      {modules, ['#{module}']},
      {applications, [kernel, stdlib#{extra}]}
    ]}.
    """
  end
end
