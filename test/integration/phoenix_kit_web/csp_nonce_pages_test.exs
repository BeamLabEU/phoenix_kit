defmodule PhoenixKitWeb.CSPNoncePagesTest do
  @moduledoc """
  A kit page rendered for a host that names its CSP nonce assign: every inline tag of the
  response carries the nonce, on the first render and after the socket connects.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Utils.Routes

  @nonce "n0nceForThisPage"

  setup do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)
    on_exit(fn -> Application.delete_env(:phoenix_kit, :csp_nonce_assign_key) end)
  end

  # What the host's own plug does, ahead of the kit's in the `:browser` pipeline.
  defp with_nonce(conn), do: Plug.Conn.assign(conn, :csp_nonce, @nonce)

  defp inline_tags(html) do
    ~r/<(?:script|style)\b[^>]*>/
    |> Regex.scan(html)
    |> List.flatten()
    |> Enum.reject(&(&1 =~ "src="))
  end

  test "every inline tag of the sign-in page has the nonce", %{conn: conn} do
    html = conn |> with_nonce() |> get(Routes.path("/users/log-in")) |> html_response(200)

    tags = inline_tags(html)
    assert tags != []
    assert Enum.reject(tags, &(&1 =~ ~s(nonce="#{@nonce}"))) == []
  end

  test "the connected render keeps it", %{conn: conn} do
    {:ok, _view, html} = conn |> with_nonce() |> live(Routes.path("/users/log-in"))

    tags = inline_tags(html)
    assert tags != []
    assert Enum.reject(tags, &(&1 =~ ~s(nonce="#{@nonce}"))) == []
  end

  test "no attribute is rendered for a host that names no assign", %{conn: conn} do
    Application.delete_env(:phoenix_kit, :csp_nonce_assign_key)

    html = conn |> with_nonce() |> get(Routes.path("/users/log-in")) |> html_response(200)

    refute html =~ "nonce="
  end
end
