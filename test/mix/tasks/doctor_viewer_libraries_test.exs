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

  # The facts reach the browser through one script tag in the root layout, which a look
  # at the disk cannot see. The installer writes the tag into the root layout of a
  # generated host; the doctor reads the same two files and guesses at no other.
  describe "facts_tag_verdict/2" do
    @describetag :tmp_dir

    defp layout!(dir, path, content) do
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      full
    end

    test "a root layout that loads the facts passes", %{tmp_dir: dir} do
      layout!(dir, "lib/my_app_web/components/layouts/root.html.heex", """
      <script src={~p"/assets/vendor/phoenix_kit.js"}></script>
      <script src={~p"/assets/vendor/phoenix_kit_modules.js"}></script>
      """)

      assert {:pass, msg} = Doctor.facts_tag_verdict(:my_app, dir)
      assert msg =~ "phoenix_kit_modules.js"
    end

    test "a root layout without the tag warns, naming the file and the fix", %{tmp_dir: dir} do
      path =
        layout!(dir, "lib/my_app_web/components/layouts/root.html.heex", """
        <script src={~p"/assets/vendor/phoenix_kit.js"}></script>
        """)

      assert {:warn, msg} = Doctor.facts_tag_verdict(:my_app, dir)
      assert msg =~ path
      assert msg =~ "phoenix_kit_modules.js"
      assert msg =~ "mix phoenix_kit.update"
      assert msg =~ "admin"
    end

    test "a tag that is commented out is not a tag", %{tmp_dir: dir} do
      tag = ~s(<script src={~p"/assets/vendor/phoenix_kit_modules.js"}></script>)

      for {kind, commented} <- [
            {"HEEx", "<%!-- #{tag} --%>"},
            {"HTML", "<!-- #{tag} -->"},
            {"EEx", "<%# #{tag} %>"},
            {"multi-line HEEx", "<%!--\n  #{tag}\n--%>"}
          ] do
        layout!(dir, "lib/my_app_web/components/layouts/root.html.heex", """
        <script src={~p"/assets/vendor/phoenix_kit.js"}></script>
        #{commented}
        """)

        assert {:warn, _} = Doctor.facts_tag_verdict(:my_app, dir),
               "#{kind} comment counted as present"
      end
    end

    test "a comment elsewhere in the layout does not hide a real tag", %{tmp_dir: dir} do
      layout!(dir, "lib/my_app_web/components/layouts/root.html.heex", """
      <%!-- the analytics tag is below --%>
      <!-- scripts -->
      <script src={~p"/assets/vendor/phoenix_kit_modules.js"}></script>
      """)

      assert {:pass, _} = Doctor.facts_tag_verdict(:my_app, dir)
    end

    test "the warning allows for a host that loads the facts another way", %{tmp_dir: dir} do
      layout!(dir, "lib/my_app_web/components/layouts/root.html.heex", "<html></html>")

      assert {:warn, msg} = Doctor.facts_tag_verdict(:my_app, dir)
      assert msg =~ "another way"
      assert msg =~ "ignore"
    end

    test "the older templates/layout path is read too", %{tmp_dir: dir} do
      layout!(
        dir,
        "lib/my_app_web/templates/layout/root.html.heex",
        "<script src=\"/a.js\"></script>"
      )

      assert {:warn, _} = Doctor.facts_tag_verdict(:my_app, dir)
    end

    test "a host with another layout, or none to find, is not guessed at", %{tmp_dir: dir} do
      assert {:pass, msg} = Doctor.facts_tag_verdict(:my_app, dir)
      assert msg =~ "not checked"

      layout!(dir, "lib/other_web/components/layouts/root.html.heex", "<html></html>")
      assert {:pass, _} = Doctor.facts_tag_verdict(:my_app, dir)
      assert {:pass, _} = Doctor.facts_tag_verdict(nil, dir)
    end
  end
end
