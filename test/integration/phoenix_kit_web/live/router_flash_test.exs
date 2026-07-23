defmodule PhoenixKitWeb.RouterFlashTest do
  @moduledoc """
  Regression test for issue #652: `** (ArgumentError) flash not fetched,
  call fetch_flash/2` on every router-rendered LiveView that redirects
  during mount with a flash message set.

  `:phoenix_kit_ensure_admin`'s on_mount hook is the most common trigger —
  visiting an admin route while unauthenticated calls
  `Phoenix.LiveView.put_flash/3` then `Phoenix.LiveView.redirect/2`, which
  `Phoenix.LiveView.Controller.live_render/3` folds back onto the `conn`
  via `Phoenix.Controller.put_flash/3`. That call requires
  `conn.assigns.flash` to already exist (from `fetch_flash`/
  `fetch_live_flash` having run), or it raises. `lib/phoenix_kit_web/router.ex`'s
  `:browser` pipeline previously had no such plug.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Utils.Routes

  test "visiting an admin route unauthenticated redirects with a flash instead of raising",
       %{conn: conn} do
    {:error, {:redirect, %{to: to}}} = live(conn, Routes.path("/admin/settings/integrations"))

    assert to =~ "/users/log-in"
  end
end
