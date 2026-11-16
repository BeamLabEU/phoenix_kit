defmodule PhoenixKit.API.OAuth.ReservedPathsTest do
  @moduledoc """
  `oauth` is never a locale: the router's `/:locale/...` scope must not take `/oauth/...` for
  a language (`PhoenixKitWeb.Users.Auth`'s reserved segments), as it does not take `mcp`.
  The URL builder's side of the same rule is in `PhoenixKit.Utils.RoutesTest`.
  """
  use PhoenixKit.DataCase, async: false

  import Plug.Test

  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKitWeb.Users.Auth

  setup do
    LanguageSettings.multilingual!()
  end

  defp locale_pass(segment) do
    conn(:get, "/phoenix_kit/#{segment}/x")
    |> Map.put(:path_params, %{"locale" => segment})
    |> Plug.Test.init_test_session(%{})
    |> Auth.validate_and_set_locale([])
  end

  test "a reserved segment is handled as no locale, exactly as mcp is" do
    assert location(locale_pass("oauth"), "oauth") == location(locale_pass("mcp"), "mcp")
    refute location(locale_pass("oauth"), "oauth") =~ "/en/"
  end

  test "an unknown segment in the locale position is sent to the default locale instead" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(self(), {:conn, locale_pass("zzzz")})
      end)

    assert_received {:conn, conn}
    assert conn.halted
    assert location(conn, "zzzz") =~ "/en/"
    assert log =~ "Invalid locale"
  end

  # The target of the redirect, with the segment under test blanked out so two segments compare.
  defp location(conn, segment) do
    [target] = Plug.Conn.get_resp_header(conn, "location")
    String.replace(target, segment, "SEG")
  end
end
