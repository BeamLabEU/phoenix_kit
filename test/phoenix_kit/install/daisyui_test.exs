defmodule PhoenixKit.Install.DaisyUITest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.DaisyUI

  describe "installed_version/1" do
    @tag :tmp_dir
    test "parses the version marker out of a plugin bundle", %{tmp_dir: tmp} do
      path = Path.join(tmp, "daisyui.js")
      File.write!(path, ~s|/** daisyUI */\nvar version = "5.0.35";\nmodule.exports = {};|)

      assert DaisyUI.installed_version(path) == "5.0.35"
    end

    @tag :tmp_dir
    test "returns nil when the file has no version marker", %{tmp_dir: tmp} do
      path = Path.join(tmp, "daisyui.js")
      File.write!(path, "module.exports = {};")

      assert DaisyUI.installed_version(path) == nil
    end

    test "returns nil for a missing file" do
      assert DaisyUI.installed_version("/nonexistent/daisyui.js") == nil
    end
  end

  describe "outdated?/1" do
    test "versions below the minimum are outdated" do
      assert DaisyUI.outdated?("5.0.35")
      assert DaisyUI.outdated?("5.1.0")
    end

    test "the minimum and above are not outdated" do
      refute DaisyUI.outdated?(DaisyUI.minimum_version())
      refute DaisyUI.outdated?("5.6.17")
      # semver comparison, not string comparison
      refute DaisyUI.outdated?("5.10.0")
      refute DaisyUI.outdated?("6.0.0")
    end

    test "unparseable versions are not claimed outdated" do
      refute DaisyUI.outdated?("not-a-version")
    end
  end

  describe "minimum_version/0" do
    test "is a valid semver string" do
      assert {:ok, _} = Version.parse(DaisyUI.minimum_version())
    end
  end

  describe "gutter_fix_version/0" do
    test "is a valid semver string below the minimum" do
      assert {:ok, gutter_fix} = Version.parse(DaisyUI.gutter_fix_version())
      assert {:ok, minimum} = Version.parse(DaisyUI.minimum_version())

      # The two bands only exist if the gutter fix predates the minimum.
      assert Version.compare(gutter_fix, minimum) == :lt
    end
  end

  describe "severity/1" do
    test "below the gutter fix modals are genuinely broken" do
      assert DaisyUI.severity("5.0.35") == :broken
      assert DaisyUI.severity("4.12.0") == :broken
    end

    test "from the gutter fix up to the minimum is merely behind" do
      assert DaisyUI.severity(DaisyUI.gutter_fix_version()) == :behind
      assert DaisyUI.severity("5.1.0") == :behind
      # What `mix phx.new` vendors today: a freshly scaffolded app must never
      # be told its modals are broken.
      assert DaisyUI.severity("5.5.19") == :behind
    end

    test "unparseable versions get the benign verdict" do
      assert DaisyUI.severity("not-a-version") == :behind
    end
  end

  describe "outdated_warning/1" do
    test "names the installed and minimum versions and the upgrade path" do
      warning = DaisyUI.outdated_warning("5.0.35")

      assert warning =~ "5.0.35"
      assert warning =~ DaisyUI.minimum_version()
      assert warning =~ "assets/vendor"
      assert warning =~ "daisyui.js"
    end

    test "below the gutter fix it reports the rendering bug" do
      warning = DaisyUI.outdated_warning("5.0.35")

      assert warning =~ "phantom right-edge strip"
      assert warning =~ DaisyUI.gutter_fix_version()
    end

    test "above the gutter fix it is advisory, not a bug report" do
      warning = DaisyUI.outdated_warning("5.5.19")

      assert warning =~ "5.5.19"
      assert warning =~ DaisyUI.minimum_version()
      assert warning =~ "nothing is broken"
      # The <5.1 symptoms must not be pinned on a host that does not have them.
      refute warning =~ "phantom right-edge strip"
      refute warning =~ "content shifting"
      # Upgrade steps still travel with both bands.
      assert warning =~ "assets/vendor"
    end
  end

  # phx.new 1.8 no longer vendors daisyUI: mix.exs declares it as a sparse git
  # dependency and app.css loads deps/daisyui/packages/bundle/daisyui. The
  # sparse checkout has no package.json; the bundle carries the marker.
  describe "the phx.new 1.8 git dependency" do
    @tag :tmp_dir
    test "is read when there is no vendored copy", %{tmp_dir: root} do
      write_bundle(root, ["deps", "daisyui", "packages", "bundle"], "5.6.17")

      assert DaisyUI.host_path(root) ==
               Path.join(root, "deps/daisyui/packages/bundle/daisyui.js")

      assert DaisyUI.check(root) == :ok
      assert DaisyUI.source(DaisyUI.host_path(root)) == :dep
    end

    @tag :tmp_dir
    test "an old tag is reported as outdated, with dependency upgrade steps", %{tmp_dir: root} do
      write_bundle(root, ["deps", "daisyui", "packages", "bundle"], "5.5.20")

      assert DaisyUI.check(root) == {:outdated, "5.5.20"}

      warning = DaisyUI.outdated_warning("5.5.20", DaisyUI.host_path(root))
      assert warning =~ "deps/daisyui"
      assert warning =~ "mix deps.update daisyui"
      refute warning =~ "assets/vendor"
    end

    @tag :tmp_dir
    test "the vendored copy wins when both exist", %{tmp_dir: root} do
      write_bundle(root, ["deps", "daisyui", "packages", "bundle"], "5.6.17")
      write_bundle(root, ["assets", "vendor"], "5.0.35")

      assert DaisyUI.source(DaisyUI.host_path(root)) == :vendored
      assert DaisyUI.check(root) == {:outdated, "5.0.35"}
    end

    @tag :tmp_dir
    test "neither shape present is :missing", %{tmp_dir: root} do
      assert DaisyUI.check(root) == :missing
    end
  end

  defp write_bundle(root, dir, version) do
    dir = Path.join([root | dir])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "daisyui.js"), ~s|var version = "#{version}";\n|)
  end
end
