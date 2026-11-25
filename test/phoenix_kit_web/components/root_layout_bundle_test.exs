defmodule PhoenixKitWeb.Components.RootLayoutBundleTest do
  @moduledoc """
  The fallback root layout loads the kit's bundle when the host serves it. Without it a page
  under that layout has the kit's `data-pk-*` controls and nothing that listens for them.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Layouts

  defmodule Endpoint do
    def static_path(path), do: path <> "?vsn=d"
  end

  @tag :tmp_dir
  test "names the files the host has, as its endpoint serves them", %{tmp_dir: dir} do
    assert Layouts.kit_bundle_paths(Endpoint, dir) == []

    vendor = Path.join(dir, "assets/vendor")
    File.mkdir_p!(vendor)
    File.write!(Path.join(vendor, "phoenix_kit.js"), "")

    assert Layouts.kit_bundle_paths(Endpoint, dir) == ["/assets/vendor/phoenix_kit.js?vsn=d"]

    File.write!(Path.join(vendor, "phoenix_kit_modules.js"), "")

    assert Layouts.kit_bundle_paths(Endpoint, dir) == [
             "/assets/vendor/phoenix_kit.js?vsn=d",
             "/assets/vendor/phoenix_kit_modules.js?vsn=d"
           ]
  end

  test "a connection with no endpoint, or no connection, names nothing" do
    assert Layouts.kit_bundle_paths(nil) == []
    assert Layouts.kit_bundle_paths(%Plug.Conn{}) == []
  end

  test "the root template loads them before app.js, deferred" do
    source = File.read!("lib/phoenix_kit_web/components/layouts/root.html.heex")
    [before_app, _] = String.split(source, ~s(src={~p"/assets/app.js"}), parts: 2)

    assert before_app =~ "kit_bundle_paths(assigns[:conn])"
  end
end
