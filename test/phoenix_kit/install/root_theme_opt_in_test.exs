defmodule PhoenixKit.Install.RootThemeOptInTest do
  @moduledoc """
  The theme bootstrap in the host's ROOT layout is opt-in
  (`--install-root-theme`); an update without the flag never adds or removes
  it. Changes the current directory, so it runs alone (`async: false`).
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.PhoenixKit.Update
  alias PhoenixKit.Install.JsIntegration

  describe "the root snippet is opt-in" do
    @layout "lib/phoenix_kit_web/components/layouts/root.html.heex"

    setup do
      root = Path.join(System.tmp_dir!(), "pk_root_theme_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, Path.dirname(@layout)))

      File.write!(
        Path.join(root, @layout),
        "<html>\n  <head>\n    <title>x</title>\n  </head>\n</html>\n"
      )

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    defp igniter, do: %{Igniter.new() | args: %Igniter.Mix.Task.Args{argv: []}}

    test "an update without the flag leaves the root layout alone", %{root: root} do
      before = File.read!(Path.join(root, @layout))
      File.cd!(root, fn -> Update.root_theme(igniter(), []) end)
      assert File.read!(Path.join(root, @layout)) == before
    end

    test "--install-root-theme adds it; --remove-root-theme takes it out", %{root: root} do
      File.cd!(root, fn ->
        Update.root_theme(igniter(), install_root_theme: true)
      end)

      assert File.read!(Path.join(root, @layout)) =~ "ThemeBootstrap"

      File.cd!(root, fn ->
        Update.root_theme(igniter(), remove_root_theme: true)
      end)

      refute File.read!(Path.join(root, @layout)) =~ "ThemeBootstrap"
    end

    test "an existing snippet is never removed without the flag", %{root: root} do
      File.cd!(root, fn -> JsIntegration.ensure_theme_bootstrap(igniter()) end)
      with_snippet = File.read!(Path.join(root, @layout))

      File.cd!(root, fn -> Update.root_theme(igniter(), []) end)
      assert File.read!(Path.join(root, @layout)) == with_snippet
    end

    test "the installer no longer injects it" do
      source = File.read!("lib/phoenix_kit/install/js_integration.ex")
      [_, body] = Regex.run(~r/def add_js_integration\(igniter\) do(.*?)\n  end/s, source)
      refute body =~ "ensure_theme_bootstrap"
    end
  end
end
