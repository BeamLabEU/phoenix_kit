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
end
