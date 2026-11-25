defmodule PhoenixKitWeb.CSPTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Mix.Tasks.PhoenixKit.Doctor
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
        {:cont, _socket} = CSP.on_mount(:default, %{}, session, %Phoenix.LiveView.Socket{})
        {CSP.nonce(:script), CSP.nonce(:style)}
      end)

    assert Task.await(task) == {"abc", "abc"}
  end

  # A nested LiveView (`live_render/3`) is its own process and skips the live session's
  # on_mount: the parent puts the nonces into the child's session, the child restores them.
  test "a nested view gets the nonces through its own session" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, %{script: :s, style: :t})
    CSP.put_nonces(conn(s: "sn", t: "tn"))

    session = CSP.nested_session(%{"user_uuid" => "u"})
    assert session["user_uuid"] == "u"

    task =
      Task.async(fn ->
        {:cont, _socket} = CSP.on_mount(:default, %{}, session, %Phoenix.LiveView.Socket{})
        {CSP.nonce(:script), CSP.nonce(:style)}
      end)

    assert Task.await(task) == {"sn", "tn"}
  end

  test "a nested session is left as it is when the page has no nonce" do
    assert CSP.nested_session(%{"a" => 1}) == %{"a" => 1}
  end

  test "the nonce is forgotten when the response is sent" do
    Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)

    conn = CSP.put_nonces(conn(csp_nonce: "abc"))
    assert CSP.nonce(:script) == "abc"

    Plug.Conn.send_resp(conn, 200, "ok")
    assert CSP.nonce(:script) == nil
  end

  describe "a host plug that runs after Integration" do
    import ExUnit.CaptureLog

    setup do
      :persistent_term.erase({CSP, :late_plug_warned})
      Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)
      :ok
    end

    test "kit routes still get the nonce, and the log says to move the plug, once" do
      first = CSP.put_nonces_first(conn([]))
      assert CSP.nonce(:script) == nil

      late = Plug.Conn.assign(first, :csp_nonce, "late")

      log =
        capture_log(fn ->
          PhoenixKitWeb.Integration.call(late, :phoenix_kit_auto_setup)
        end)

      assert CSP.nonce(:script) == "late"
      assert log =~ "runs after"

      again =
        capture_log(fn ->
          conn([])
          |> CSP.put_nonces_first()
          |> Plug.Conn.assign(:csp_nonce, "x")
          |> CSP.put_nonces()
        end)

      refute again =~ "runs after"
    end

    test "the documented order logs nothing" do
      log =
        capture_log(fn ->
          conn(csp_nonce: "abc")
          |> CSP.put_nonces_first()
          |> PhoenixKitWeb.Integration.call(:phoenix_kit_auto_setup)
        end)

      assert CSP.nonce(:script) == "abc"
      refute log =~ "runs after"
    end

    test "a first reading with no Integration before it is not a late plug" do
      log = capture_log(fn -> CSP.put_nonces(conn(csp_nonce: "abc")) end)
      refute log =~ "runs after"
    end
  end

  describe "config_problem/0" do
    test "the two supported shapes are fine" do
      assert CSP.config_problem() == nil
      Application.put_env(:phoenix_kit, :csp_nonce_assign_key, :csp_nonce)
      assert CSP.config_problem() == nil
      Application.put_env(:phoenix_kit, :csp_nonce_assign_key, %{script: :a, style: :b})
      assert CSP.config_problem() == nil
    end

    test "a shape that would silently read as no nonce is named" do
      for bad <- ["csp_nonce", %{scripts: :a}, %{script: "a"}, %{script: false}, %{}, 1] do
        Application.put_env(:phoenix_kit, :csp_nonce_assign_key, bad)
        assert is_binary(CSP.config_problem()), inspect(bad)
        assert CSP.nonce(conn(csp_nonce: "abc", a: "abc"), :script) == nil
      end
    end

    test "true and false are not assign names, and the doctor does not raise on them" do
      for key <- [false, true] do
        Application.put_env(:phoenix_kit, :csp_nonce_assign_key, key)
        problem = CSP.config_problem()
        assert is_binary(problem), inspect(key)

        # The same call as the doctor: `key && router` is `false` when the setting is `false`,
        # which used to miss every clause of `csp_verdict/3` and raise.
        assert {:warn, message} =
                 Doctor.csp_verdict(key, problem, key && "router source")

        assert message =~ "not usable"
        # A value stored under that key is still not the nonce.
        assert CSP.nonce(conn([{key, "abc"}]), :script) == nil
      end
    end
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
