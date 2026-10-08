defmodule PhoenixKit.Install.ViewerLibrariesTest do
  @moduledoc """
  Vendoring the viewer/editor libraries into the host (Part B1 of
  dev_docs/plans/2026-10-07-self-hosted-viewer-libraries.md): versioned,
  content-hashed names; an unchanged compile touches nothing; old names are
  never deleted; CDN URLs only on the host's opt-in, built from the
  consumer's version; the core-committed SortableJS checked against its
  recorded checksum.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Compile.PhoenixKitJsSources, as: Compiler
  alias PhoenixKit.Install.ViewerLibraries

  setup do
    root = Path.join(System.tmp_dir!(), "pk_viewer_libs_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:phoenix_kit, :library_cdn_fallback)

    on_exit(fn ->
      File.rm_rf(root)

      if is_nil(previous),
        do: Application.delete_env(:phoenix_kit, :library_cdn_fallback),
        else: Application.put_env(:phoenix_kit, :library_cdn_fallback, previous)
    end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    %{root: root}
  end

  defp lib_path(root, file), do: Path.join([root, ViewerLibraries.lib_dir(), file])

  test "every library lands at a versioned, content-hashed name", %{root: root} do
    facts = ViewerLibraries.vendor!(root)

    assert Enum.sort(Map.keys(facts)) == ~w(etcher fresco leaf sortable tessera)
    assert facts["sortable"].file =~ ~r/\Asortable-1\.15\.0-[0-9a-f]{8}\.js\z/

    for {_name, %{file: file, cdn: cdn}} <- facts do
      assert File.regular?(lib_path(root, file))
      assert cdn == nil, "no CDN unless the host opted in"
    end
  end

  test "an unchanged vendor touches nothing, and a previous name is never deleted", %{root: root} do
    facts = ViewerLibraries.vendor!(root)
    path = lib_path(root, facts["fresco"].file)
    File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
    stale = lib_path(root, "fresco-0.0.1-deadbeef.js")
    File.write!(stale, "old build")

    assert ViewerLibraries.vendor!(root) == facts
    assert File.stat!(path).mtime == {{2000, 1, 1}, {0, 0, 0}}, "not rewritten"
    assert File.exists?(stale), "an open tab or a rolling deploy may still ask for it"
  end

  test "different bytes under the same version get a different name" do
    a = ViewerLibraries.file_name("fresco", "0.13.1", "one")
    b = ViewerLibraries.file_name("fresco", "0.13.1", "two")
    assert a != b
  end

  test "an opted-in host gets CDN fallbacks built from the loaded version", %{root: root} do
    Application.put_env(:phoenix_kit, :library_cdn_fallback, true)
    facts = ViewerLibraries.vendor!(root)
    vsn = to_string(Application.spec(:etcher, :vsn))

    assert facts["etcher"].cdn ==
             "https://cdn.jsdelivr.net/gh/alexdont/etcher@v#{vsn}/priv/static/etcher.js"

    assert facts["sortable"].cdn ==
             "https://cdn.jsdelivr.net/npm/sortablejs@1.15.0/Sortable.min.js"
  end

  test "the committed SortableJS is the exact upstream file its manifest names" do
    %{sha256: expected, source: {:phoenix_kit, path}} =
      Enum.find(ViewerLibraries.libraries(), &(&1.name == "sortable"))

    content = File.read!(Path.join(to_string(:code.priv_dir(:phoenix_kit)), path))
    assert :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) == expected
    assert content =~ "Sortable 1.15.0 - MIT"

    assert File.exists?(
             Path.join([File.cwd!(), "priv/static/assets/vendor_libs/sortablejs/LICENSE"])
           )
  end

  test "the facts are one JS statement naming every file", %{root: root} do
    js = root |> ViewerLibraries.vendor!() |> ViewerLibraries.facts_js()

    assert js =~ ~r/\Awindow\.PHOENIX_KIT_LIBS=\{.*\};\z/
    assert js =~ ~s("sortable":{"file":"sortable-1.15.0-)
    assert js =~ ~s("cdn":null)
  end

  test "vendor_all writes bundle, libraries and facts together — the path update and install take",
       %{root: root} do
    :ok = Compiler.vendor_all(root)

    modules = File.read!(Path.join(root, "priv/static/assets/vendor/phoenix_kit_modules.js"))
    assert modules =~ "window.PHOENIX_KIT_LIBS="
    assert File.exists?(Path.join(root, "priv/static/assets/vendor/phoenix_kit.js"))

    [_, json] = Regex.run(~r/window\.PHOENIX_KIT_LIBS=(\{.*?\});/, modules)

    for {_name, %{"file" => file}} <- Jason.decode!(json) do
      assert File.regular?(lib_path(root, file)), "#{file} named by the facts is on disk"
    end

    # Identical output when run again, as from `mix phoenix_kit.update`.
    before = File.read!(Path.join(root, "priv/static/assets/vendor/phoenix_kit_modules.js"))
    :ok = Compiler.vendor_all(root)

    assert File.read!(Path.join(root, "priv/static/assets/vendor/phoenix_kit_modules.js")) ==
             before
  end
end
