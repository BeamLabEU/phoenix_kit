defmodule Mix.Tasks.Compile.PhoenixKitJsSourcesTest do
  @moduledoc """
  Unit tests for the pure content-generation + validation helpers of the
  `:phoenix_kit_js_sources` compiler (the IIFE wrapping, the merge line, the
  empty case, and the fail-loud guards). The full `run/1` does live module
  discovery in the host app and is exercised end-to-end by consumers, not here.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Compile.PhoenixKitJsSources, as: Compiler

  describe "build_content/1" do
    test "no specs emits NO merge line (no Object.assign syntax error)" do
      js = Compiler.build_content([])

      refute js =~ "Object.assign"
      assert js =~ "No external module declares js_sources/0"
    end

    test "the install-facts preamble is emitted even with no module bundles" do
      # It rides in this file because the file is already <script>-tagged in
      # every host's layout — a separate globals file would need a layout edit
      # and a `phoenix_kit.update` backfill to reach existing installs.
      js = Compiler.build_content([])

      assert js =~ "window.PHOENIX_KIT_PREFIX="
      assert js =~ "window.PHOENIX_KIT_CONSENT_AVAILABLE="
    end

    test "the preamble is also present alongside module bundles" do
      dir = tmp_dir!()
      file = Path.join(dir, "p.js")
      File.write!(file, "window.PHooks={}")
      spec = %{app: :p, file: "p.js", global: "PHooks", source: file}

      js = Compiler.build_content([spec])

      assert js =~ "window.PHOENIX_KIT_PREFIX="
      assert js =~ "Object.assign"
    end

    test "wraps each bundle in an IIFE and folds its global into PhoenixKitHooks" do
      dir = tmp_dir!()
      file = Path.join(dir, "a.js")
      File.write!(file, "window.AHooks={X:1}")
      spec = %{app: :a, file: "a.js", global: "AHooks", source: file}

      js = Compiler.build_content([spec])

      # IIFE wrapper isolates the bundle's top-level scope; leading ; guards ASI.
      assert js =~ ";(function(){"
      assert js =~ "})();"
      assert js =~ "window.AHooks={X:1}"
      # Merge folds the bundle's global into the host-spread global.
      assert js =~
               "window.PhoenixKitHooks=Object.assign(window.PhoenixKitHooks||{},window.AHooks||{});"
    end

    test "merges every distinct global into a single Object.assign" do
      dir = tmp_dir!()
      a = Path.join(dir, "a.js")
      b = Path.join(dir, "b.js")
      File.write!(a, "window.AHooks={}")
      File.write!(b, "window.BHooks={}")

      js =
        Compiler.build_content([
          %{app: :a, file: "a.js", global: "AHooks", source: a},
          %{app: :b, file: "b.js", global: "BHooks", source: b}
        ])

      assert js =~
               "Object.assign(window.PhoenixKitHooks||{},window.AHooks||{},window.BHooks||{});"
    end
  end

  describe "a module's admin bundle (scope: :admin)" do
    # A bundle only admin pages use stays out of phoenix_kit_modules.js, which
    # every page loads. It rides in the admin bundle instead, and the page gets
    # a stub under each hook name the module declared.

    test "a spec without a scope is public: bundled and folded as it always was" do
      dir = tmp_dir!()
      file = Path.join(dir, "a.js")
      File.write!(file, "window.AHooks={X:1}")
      spec = %{app: :a, file: "a.js", global: "AHooks", source: file}

      js = Compiler.build_content([spec])

      assert js =~ "window.AHooks={X:1}"
      refute js =~ "PhoenixKitModuleAdminHooks"
      assert Compiler.admin_specs([spec]) == []
    end

    test "an admin spec is not in phoenix_kit_modules.js; its declared hooks get stubs there" do
      dir = tmp_dir!()
      file = Path.join(dir, "g.js")
      File.write!(file, "window.GridHooks={GridSort:{}}")

      spec = %{
        app: :grid,
        file: "g.js",
        global: "GridHooks",
        source: file,
        scope: :admin,
        hooks: ["GridSort", "GridMenu"]
      }

      js = Compiler.build_content([spec])

      refute js =~ "window.GridHooks={GridSort:{}}", "the code is not in the page-wide file"
      refute js =~ "Object.assign(window.PhoenixKitHooks", "nothing to fold: the hooks are stubs"
      assert js =~ ~s(["GridSort","GridMenu"])
      assert js =~ "PhoenixKitModuleAdminHooks"
      assert js =~ "PhoenixKitRegisterAdminStubs"
    end

    test "public and admin specs side by side: one folded, one stubbed" do
      dir = tmp_dir!()
      a = Path.join(dir, "a.js")
      g = Path.join(dir, "g.js")
      File.write!(a, "window.AHooks={}")
      File.write!(g, "window.GridHooks={}")

      js =
        Compiler.build_content([
          %{app: :a, file: "a.js", global: "AHooks", source: a},
          %{
            app: :grid,
            file: "g.js",
            global: "GridHooks",
            source: g,
            scope: :admin,
            hooks: ["GridSort"]
          }
        ])

      assert js =~ "Object.assign(window.PhoenixKitHooks||{},window.AHooks||{});"
      refute js =~ "GridHooks||{}"
      assert js =~ ~s(["GridSort"])
    end

    test "the admin bundle carries core's admin file, then each module's bundle, then the fold" do
      dir = tmp_dir!()
      g = Path.join(dir, "g.js")
      File.write!(g, "window.GridHooks={GridSort:{mounted(){}}}")

      spec = %{
        app: :grid,
        file: "g.js",
        global: "GridHooks",
        source: g,
        scope: :admin,
        hooks: ["GridSort"]
      }

      core = "/* core admin */"
      js = Compiler.build_admin_content(core, [spec])

      assert js =~ core
      assert js =~ ";(function(){"
      assert js =~ "window.GridHooks={GridSort:{mounted(){}}}"

      assert js =~
               "window.PhoenixKitAdminHooks=Object.assign(window.PhoenixKitAdminHooks||{},window.GridHooks||{});"

      assert :binary.match(js, core) < :binary.match(js, "window.GridHooks")
    end

    test "with no admin modules the admin bundle is core's file untouched" do
      assert Compiler.build_admin_content("/* core admin */", []) == "/* core admin */"
    end

    test "the admin bundle checks the hooks a module lists against the ones its bundle exports" do
      # test/fixtures/admin_hooks_check.js is this exact text; the JS test
      # (test/js/admin_split.test.cjs) runs it.
      dir = tmp_dir!()
      g = Path.join(dir, "g.js")
      File.write!(g, "window.GridHooks={}")

      spec = %{
        app: :grid,
        file: "g.js",
        global: "GridHooks",
        source: g,
        scope: :admin,
        hooks: ["GridSort"]
      }

      check = File.read!(Path.expand("../../fixtures/admin_hooks_check.js", __DIR__))
      assert Compiler.build_admin_content("/* core */", [spec]) =~ String.trim_trailing(check)
    end

    test "core's hook names are read from its own two files, with no list to keep in step" do
      names = Compiler.core_hook_names()

      for known <-
            ~w(RowMenu SortableGrid EmailCharts CookieConsent FlashAutoDismiss PkDialog Leaf) do
        assert known in names, "#{known} is a core hook"
      end

      assert length(names) > 60
      refute "Same" in names
    end

    test "a module admin hook may not take a name core already has" do
      spec = %{app: :a, file: "a.js", global: "AHooks", scope: :admin, hooks: ["RowMenu", "Mine"]}

      assert_raise Mix.Error, ~r/PhoenixKit itself defines.*RowMenu/s, fn ->
        Compiler.check_unique_hooks([spec])
      end

      assert :ok = Compiler.check_unique_hooks([%{spec | hooks: ["Mine"]}])
      assert :ok = Compiler.check_unique_hooks([%{spec | hooks: ["RowMenu"]}], ["Other"])
    end

    test "an admin spec must name its hooks, or nothing could ever mount them" do
      assert_raise Mix.Error, ~r/hooks/, fn ->
        Compiler.normalize_entry(%{app: :a, file: "a.js", global: "AHooks", scope: :admin})
      end

      assert_raise Mix.Error, ~r/hooks/, fn ->
        Compiler.normalize_entry(%{
          app: :a,
          file: "a.js",
          global: "AHooks",
          scope: :admin,
          hooks: []
        })
      end
    end

    test "hook names must be valid and distinct, and the scope one of the two" do
      assert_raise Mix.Error, ~r/hook/i, fn ->
        Compiler.normalize_entry(%{
          app: :a,
          file: "a.js",
          global: "AHooks",
          scope: :admin,
          hooks: ["bad name"]
        })
      end

      assert_raise Mix.Error, ~r/scope/, fn ->
        Compiler.normalize_entry(%{app: :a, file: "a.js", global: "AHooks", scope: :private})
      end
    end

    test "a well-formed admin entry passes through with its hooks" do
      entry = %{app: :a, file: "a.js", global: "AHooks", scope: :admin, hooks: ["X"]}
      assert %{scope: :admin, hooks: ["X"]} = Compiler.normalize_entry(entry)
      public = %{app: :a, file: "a.js", global: "AHooks"}

      assert Compiler.normalize_entry(public) == public,
             "a public entry keeps the shape it always had"

      assert %{scope: :admin, hooks: ["X"]} =
               Compiler.normalize_entry(Map.merge(public, %{scope: :admin, hooks: ["X"]}))
    end

    test "two modules stubbing the same hook name would silently share one body: refused" do
      specs = [
        %{app: :a, file: "a.js", global: "AHooks", scope: :admin, hooks: ["Same"]},
        %{app: :b, file: "b.js", global: "BHooks", scope: :admin, hooks: ["Same"]}
      ]

      assert_raise Mix.Error, ~r/Same/, fn -> Compiler.check_unique_hooks(specs) end
    end
  end

  describe "check_unique_globals/1" do
    test "passes when every bundle declares a distinct global" do
      specs = [
        %{app: :a, file: "a.js", global: "AHooks"},
        %{app: :b, file: "b.js", global: "BHooks"}
      ]

      assert Compiler.check_unique_globals(specs) == :ok
    end

    test "raises when two bundles share a global (would clobber each other)" do
      specs = [
        %{app: :a, file: "a.js", global: "Dup"},
        %{app: :b, file: "b.js", global: "Dup"}
      ]

      assert_raise Mix.Error, ~r/same window global/, fn ->
        Compiler.check_unique_globals(specs)
      end
    end
  end

  describe "normalize_entry/1" do
    test "passes a well-formed map through" do
      entry = %{app: :a, file: "a.js", global: "AHooks"}
      assert Compiler.normalize_entry(entry) == entry
    end

    test "raises on a malformed entry" do
      assert_raise Mix.Error, ~r/Invalid js_sources/, fn ->
        Compiler.normalize_entry(%{app: :a})
      end
    end

    test "raises when :global is not a valid JS identifier" do
      assert_raise Mix.Error, ~r/valid JavaScript/, fn ->
        Compiler.normalize_entry(%{app: :a, file: "a.js", global: "foo-bar"})
      end
    end
  end

  defp tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "pk_js_sources_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
