defmodule PhoenixKit.Install.AssetRebuildTest do
  @moduledoc """
  The asset rebuild NordAPI's update hit: `mix assets.build` (6 s by hand)
  timed out waiting on the build lock of the `mix` that ran it, then the
  fallbacks called the `default` esbuild/tailwind profiles (phx.new names
  them after the app) and `npm run build` with no package.json.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.AssetRebuild

  test "a phx.new host gets its app-named profiles and no npm without package.json" do
    assert AssetRebuild.build_commands(
             app: :nord_api,
             esbuild_profiles: [:nord_api],
             tailwind_profiles: [:nord_api],
             package_json?: false
           ) == [
             {"mix", ["assets.build"]},
             {"mix", ["esbuild", "nord_api", "--minify"]},
             {"mix", ["tailwind", "nord_api", "--minify"]}
           ]
  end

  test "an older host's `default` profile is still used" do
    assert {"mix", ["esbuild", "default", "--minify"]} in AssetRebuild.build_commands(
             app: :old_app,
             esbuild_profiles: [:default],
             tailwind_profiles: [],
             package_json?: false
           )
  end

  test "the app-named profile wins over `default`, and an unconfigured tool is skipped" do
    commands =
      AssetRebuild.build_commands(
        app: :my_app,
        esbuild_profiles: [:default, :my_app],
        tailwind_profiles: [],
        package_json?: false
      )

    assert {"mix", ["esbuild", "my_app", "--minify"]} in commands
    refute Enum.any?(commands, fn {_cmd, args} -> hd(args) == "tailwind" end)
  end

  test "npm runs only when there is a package.json" do
    commands = AssetRebuild.build_commands(app: :my_app, package_json?: true)

    assert {"npm", ["run", "build"]} in commands
    assert {"npm", ["run", "build.css"]} in commands
  end

  test "a child mix does not wait on the parent's build lock" do
    assert AssetRebuild.command_env("mix") == [{"MIX_OS_CONCURRENCY_LOCK", "0"}]
    assert AssetRebuild.command_env("npm") == []
  end
end
