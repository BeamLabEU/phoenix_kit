defmodule PhoenixKitWeb.CSPTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitWeb.Components.Core.PhoenixKitGlobals
  alias PhoenixKitWeb.CSP

  setup do
    previous = Application.get_env(:phoenix_kit, :csp_nonce_assign_key)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :csp_nonce_assign_key, previous),
        else: Application.delete_env(:phoenix_kit, :csp_nonce_assign_key)
    end)

    Application.delete_env(:phoenix_kit, :csp_nonce_assign_key)
    :ok
  end

  defp conn(assigns),
    do: Enum.reduce(assigns, build_conn(), fn {k, v}, c -> Plug.Conn.assign(c, k, v) end)

  test "reads nothing while the host names no assign" do
    conn = conn(csp_nonce: "abc")

    CSP.put_nonces(conn)

    assert CSP.nonce(:script) == nil
    assert CSP.nonce(conn, :style) == nil
    assert CSP.attr(:script) == ""
    assert CSP.live_session(conn) == %{}
  end

  test "one assign serves both kinds" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)
    conn = conn(csp_nonce: "abc")

    assert CSP.nonce(conn, :script) == "abc"

    CSP.put_nonces(conn)

    assert CSP.nonce(:script) == "abc"
    assert CSP.nonce(:style) == "abc"
    assert CSP.attr(:style) == ~s( nonce="abc")
  end

  test "a map names an assign per kind, and a missing kind gets no nonce" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, %{script: :script_nonce})

    CSP.put_nonces(conn(script_nonce: "s1", style_nonce: "s2"))

    assert CSP.nonce(:script) == "s1"
    assert CSP.nonce(:style) == nil
  end

  test "the next request of the same process does not inherit the nonce" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)

    CSP.put_nonces(conn(csp_nonce: "abc"))
    CSP.put_nonces(conn([]))

    assert CSP.nonce(:script) == nil
  end

  test "a connection is authoritative, even when an earlier request left a nonce" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)
    CSP.put_nonces(conn(csp_nonce: "from-a"))

    bare = conn([])
    assert CSP.nonce(bare, :script) == nil
    assert CSP.nonce(bare, :style) == nil
    assert CSP.attr(bare, :script) == ""
    # Components rendered with no conn still see the request that stored it.
    assert CSP.nonce(:script) == "from-a"
  end

  test "a connection that names one kind does not borrow the other from the process" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, %{
      script: :script_nonce,
      style: :style_nonce
    })

    CSP.put_nonces(conn(script_nonce: "s-old", style_nonce: "y-old"))

    only_script = conn(script_nonce: "s-new")
    assert CSP.nonce(only_script, :script) == "s-new"
    assert CSP.nonce(only_script, :style) == nil
    assert CSP.attr(only_script, :style) == ""
  end

  test "the attribute is escaped" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)

    assert CSP.attr(conn(csp_nonce: ~s(a"><b)), :script) == ~s( nonce="a&quot;&gt;&lt;b")
  end

  test "the live session carries the nonces into another process" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)
    session = CSP.live_session(conn(csp_nonce: "abc"))

    task =
      Task.async(fn ->
        {:cont, socket} = CSP.on_mount(:default, %{}, session, %Phoenix.LiveView.Socket{})
        {CSP.nonce(:script), CSP.nonce(:style), socket.assigns.phoenix_kit_csp_nonces}
      end)

    assert Task.await(task) == {"abc", "abc", %{script: "abc", style: "abc"}}
  end

  test "a session without nonces keeps what the plug stored" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)
    CSP.put_nonces(conn(csp_nonce: "abc"))

    {:cont, _} = CSP.on_mount(:default, %{}, %{}, %Phoenix.LiveView.Socket{})

    assert CSP.nonce(:script) == "abc"
  end

  test "a kit component renders the nonce" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)
    CSP.put_nonces(conn(csp_nonce: "abc"))

    html =
      render_component(
        &PhoenixKitGlobals.phoenix_kit_globals/1,
        %{}
      )

    assert html =~ ~s(<script nonce="abc">)
    assert html =~ ~s(<style nonce="abc")
  end
end
