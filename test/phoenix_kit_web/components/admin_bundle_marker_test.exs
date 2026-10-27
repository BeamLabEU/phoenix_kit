defmodule PhoenixKitWeb.Components.AdminBundleMarkerTest do
  @moduledoc """
  `phoenix_kit.js` starts downloading the admin hook bundle as soon as the
  document is parsed when the page carries `data-pk-admin`, instead of waiting
  for the first admin hook to mount after the socket has joined. The marker is
  an optimisation (the stubs work without it), so what is pinned here is only
  that the two layouts that mount admin hooks carry it and the bundle looks for
  the same attribute.
  """
  use ExUnit.Case, async: true

  @root Path.join(__DIR__, "../../..")

  test "the admin layout and the user dashboard layout carry the marker" do
    wrapper = File.read!(Path.join(@root, "lib/phoenix_kit_web/components/layout_wrapper.ex"))

    dashboard =
      File.read!(Path.join(@root, "lib/phoenix_kit_web/components/layouts/dashboard.html.heex"))

    assert wrapper =~ ~r/id="admin-drawer"\s+data-pk-admin/
    assert dashboard =~ ~r/<div class="min-h-screen bg-base-100" data-pk-admin>/
  end

  test "the public bundle looks for that attribute" do
    js = File.read!(Path.join(@root, "priv/static/assets/phoenix_kit.js"))
    assert js =~ ~s|document.querySelector("[data-pk-admin]")|
  end
end
