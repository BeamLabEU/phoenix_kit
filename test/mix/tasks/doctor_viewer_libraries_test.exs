defmodule Mix.Tasks.PhoenixKit.DoctorViewerLibrariesTest do
  @moduledoc """
  The doctor's "Viewer Libraries" verdict. The vendored phoenix_kit.js is
  what loads the viewer/editor libraries and reports their failures — so a
  host without it gets neither, and nothing in the browser can say so.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Doctor

  test "compiler configured and bundle on disk passes — and says it proves the disk only" do
    assert {:pass, msg} = Doctor.viewer_libraries_verdict(:host, [:phoenix_kit_js_sources], true)
    assert msg =~ "only provable in a browser"
  end

  test "a missing compiler warns with the line to add" do
    assert {:warn, msg} = Doctor.viewer_libraries_verdict(:host, [:elixir, :app], true)
    assert msg =~ "compilers: [:phoenix_kit_js_sources] ++ Mix.compilers()"
  end

  test "compiler present but no bundle on disk warns to compile" do
    assert {:warn, msg} = Doctor.viewer_libraries_verdict(:host, [:phoenix_kit_js_sources], false)
    assert msg =~ "mix compile"
  end

  test "phoenix_kit's own checkout has nothing to check" do
    assert {:pass, _} = Doctor.viewer_libraries_verdict(:phoenix_kit, nil, false)
  end

  describe "viewer_library_facts_verdict/1" do
    @describetag :tmp_dir

    test "a file naming the libraries passes", %{tmp_dir: dir} do
      path = Path.join(dir, "phoenix_kit_modules.js")
      File.write!(path, ~s(window.PHOENIX_KIT_LIBS={"fresco":{"file":"f.js","cdn":null}};))
      assert {:pass, _} = Doctor.viewer_library_facts_verdict(path)
    end

    test "a file without the install facts warns, naming the script tag", %{tmp_dir: dir} do
      path = Path.join(dir, "phoenix_kit_modules.js")
      File.write!(path, "// hooks only")
      assert {:warn, msg} = Doctor.viewer_library_facts_verdict(path)
      assert msg =~ "phoenix_kit_modules.js"
    end

    test "facts that name no admin bundle warn: the admin hooks would have nothing to load", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "phoenix_kit_modules.js")
      File.write!(path, ~s(window.PHOENIX_KIT_LIBS={"fresco":{"file":"f.js","cdn":null}};))
      File.mkdir_p!(Path.join(dir, "lib"))

      assert {:pass, _} = Doctor.viewer_library_facts_verdict(path)
      assert {:warn, msg} = Doctor.admin_bundle_verdict(path)
      assert msg =~ "admin"
      assert msg =~ "mix phoenix_kit.update"
    end

    test "facts naming an admin bundle that is not on disk warn with the file", %{tmp_dir: dir} do
      path = Path.join(dir, "phoenix_kit_modules.js")

      File.write!(
        path,
        ~s(window.PHOENIX_KIT_LIBS={"admin":{"file":"admin-9.9.9-deadbeef.js","cdn":null}};)
      )

      File.mkdir_p!(Path.join(dir, "lib"))

      assert {:warn, msg} = Doctor.admin_bundle_verdict(path)
      assert msg =~ "admin-9.9.9-deadbeef.js"
    end

    test "facts naming an admin bundle that is on disk pass", %{tmp_dir: dir} do
      path = Path.join(dir, "phoenix_kit_modules.js")

      File.write!(
        path,
        ~s(window.PHOENIX_KIT_LIBS={"admin":{"file":"admin-9.9.9-deadbeef.js","cdn":null}};)
      )

      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join([dir, "lib", "admin-9.9.9-deadbeef.js"]), "// admin")

      assert {:pass, _} = Doctor.admin_bundle_verdict(path)
    end

    test "facts a host's own esbuild has minified (keys unquoted, one line) are still read", %{
      tmp_dir: dir
    } do
      # Real esbuild output for a file with a module's admin stubs after the facts:
      # `admin:{file:"…",cdn:null}`, which is not JSON.
      minified =
        File.read!(Path.expand("../../fixtures/phoenix_kit_modules.esbuild.min.js", __DIR__))

      refute minified =~ ~s("admin")

      assert {:ok, file} = Doctor.admin_file_in_facts(minified)
      assert file =~ ~r/\Aadmin-3\.0\.0-[0-9a-f]{8}\.js\z/

      path = Path.join(dir, "phoenix_kit_modules.js")
      File.write!(path, minified)
      File.mkdir_p!(Path.join(dir, "lib"))
      assert {:warn, msg} = Doctor.admin_bundle_verdict(path)
      assert msg =~ file, "names the file it could not find"

      File.write!(Path.join([dir, "lib", file]), "// admin")
      assert {:pass, _} = Doctor.admin_bundle_verdict(path)
    end

    test "the facts are found whatever their key order, and another module's admin key is not mistaken for them" do
      assert {:ok, "a.js"} =
               Doctor.admin_file_in_facts(
                 ~s(window.PHOENIX_KIT_LIBS={fresco:{cdn:null,file:"f.js"},admin:{cdn:null,file:"a.js"}};)
               )

      assert :error =
               Doctor.admin_file_in_facts(
                 ~s(window.PHOENIX_KIT_LIBS={fresco:{file:"f.js"}};window.X={admin:{file:"nope.js"}};)
               )

      assert :error = Doctor.admin_file_in_facts("// no facts here")
    end

    test "a missing file warns to compile", %{tmp_dir: dir} do
      assert {:warn, msg} = Doctor.viewer_library_facts_verdict(Path.join(dir, "nope.js"))
      assert msg =~ "mix compile"
    end
  end
end
