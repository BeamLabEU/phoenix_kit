defmodule PhoenixKit.PackageContentsTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.PhoenixKit.ReleaseCheck

  @tag :tmp_dir
  test "a Hex build excludes uploaded media and keeps shipped assets", %{tmp_dir: tmp_dir} do
    media_dir = Path.join("priv/media", "package-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(media_dir)
    File.write!(Path.join(media_dir, "upload.jpg"), "generated media")
    on_exit(fn -> File.rm_rf!(media_dir) end)

    tar_path = Path.join(tmp_dir, "phoenix_kit.tar")

    {output, status} =
      System.cmd("mix", ["hex.build", "--output", tar_path],
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert {:ok, outer} = :erl_tar.extract(String.to_charlist(tar_path), [:memory])
    {~c"contents.tar.gz", contents} = List.keyfind(outer, ~c"contents.tar.gz", 0)
    assert {:ok, files} = :erl_tar.extract({:binary, contents}, [:memory, :compressed])
    paths = Enum.map(files, fn {path, _bytes} -> to_string(path) end)

    refute Enum.any?(paths, &String.starts_with?(&1, "priv/media/"))
    assert "priv/static/assets/phoenix_kit.js" in paths
    # The admin half of the hook bundle and Chart.js are fetched by the public
    # file on demand; a package without them breaks the admin area.
    assert "priv/static/assets/phoenix_kit_admin.js" in paths
    assert "priv/static/assets/vendor_libs/chartjs/chart.umd.js" in paths
    assert "priv/gettext/default.pot" in paths
    assert "lib/phoenix_kit.ex" in paths
    assert {:pass, _} = ReleaseCheck.check_package_contents(tar_path)
  end

  @tag :tmp_dir
  test "the release gate rejects runtime media in a built package", %{tmp_dir: tmp_dir} do
    contents_path = Path.join(tmp_dir, "contents.tar.gz")

    assert :ok =
             :erl_tar.create(
               String.to_charlist(contents_path),
               [{~c"priv/media/upload.jpg", "generated media"}],
               [:compressed]
             )

    tar_path = Path.join(tmp_dir, "bad_package.tar")

    assert :ok =
             :erl_tar.create(
               String.to_charlist(tar_path),
               [{~c"contents.tar.gz", File.read!(contents_path)}]
             )

    assert {:fail, message} = ReleaseCheck.check_package_contents(tar_path)
    assert message =~ "priv/media/upload.jpg"
  end
end
