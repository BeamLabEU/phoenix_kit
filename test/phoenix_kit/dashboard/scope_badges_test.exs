defmodule PhoenixKit.Dashboard.ScopeBadgesTest do
  @moduledoc """
  The host application's per-viewer menu badges (`config :phoenix_kit, :scope_badges`):
  how its answer is put onto the tabs, and that a broken answer never breaks the menu.
  """
  # Flips application config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Dashboard.{AdminTabs, Badge, ScopeBadges, Tab}
  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKit.Users.ScopeNotifier

  @uuid "0193a5e4-0000-7000-8000-0000000000cc"

  defmodule Host do
    @behaviour PhoenixKit.Dashboard.ScopeBadges

    alias PhoenixKit.Dashboard.Badge

    @impl true
    def badges(scope) do
      send(self(), {:badges_called, scope})

      case Process.get(:scope_badges_answer) do
        nil -> %{orders: Badge.count(3), rfqs: nil}
        fun when is_function(fun, 0) -> fun.()
        answer -> answer
      end
    end

    def other_name(_scope), do: %{orders: Badge.count(7)}
  end

  setup do
    previous = Application.fetch_env(:phoenix_kit, :scope_badges)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :scope_badges, value)
        :error -> Application.delete_env(:phoenix_kit, :scope_badges)
      end
    end)

    Application.delete_env(:phoenix_kit, :scope_badges)
    :ok
  end

  defp scope, do: %Scope{user: %User{uuid: @uuid}, authenticated?: true}

  defp tabs do
    [
      %Tab{id: :orders, label: "Orders", path: "/admin/orders"},
      %Tab{id: :rfqs, label: "RFQs", path: "/admin/rfqs", badge: Badge.count(9)},
      %Tab{id: :inquiries, label: "Inquiries", path: "/admin/inquiries", badge: Badge.count(5)}
    ]
  end

  defp badge_values(tabs), do: Map.new(tabs, &{&1.id, &1.badge && &1.badge.value})

  test "with nothing configured the tabs come back as they were" do
    assert ScopeBadges.put_badges(tabs(), scope()) == tabs()
    refute_received {:badges_called, _}
  end

  test "a module's badges replace the tabs' own, nil takes one away, other tabs keep theirs" do
    Application.put_env(:phoenix_kit, :scope_badges, Host)

    assert badge_values(ScopeBadges.put_badges(tabs(), scope())) ==
             %{orders: 3, rfqs: nil, inquiries: 5}
  end

  test "the module is called once per render, with the viewer's scope" do
    Application.put_env(:phoenix_kit, :scope_badges, Host)
    viewer = scope()

    ScopeBadges.put_badges(tabs(), viewer)

    assert_received {:badges_called, ^viewer}
    refute_received {:badges_called, _}
  end

  test "{module, function} names another function" do
    Application.put_env(:phoenix_kit, :scope_badges, {Host, :other_name})
    assert badge_values(ScopeBadges.put_badges(tabs(), scope())).orders == 7
  end

  test "an empty menu asks nothing" do
    Application.put_env(:phoenix_kit, :scope_badges, Host)
    assert ScopeBadges.put_badges([], scope()) == []
    refute_received {:badges_called, _}
  end

  test "a key naming no tab is ignored" do
    Application.put_env(:phoenix_kit, :scope_badges, Host)
    Process.put(:scope_badges_answer, %{nowhere: Badge.count(1), orders: Badge.count(2)})

    result = ScopeBadges.put_badges(tabs(), scope())

    assert badge_values(result) == %{orders: 2, rfqs: 9, inquiries: 5}
  end

  test "a value that is not a badge leaves the tab's own, and is logged without the value" do
    Application.put_env(:phoenix_kit, :scope_badges, Host)
    Process.put(:scope_badges_answer, %{rfqs: "secret-count-41"})

    log =
      capture_log(fn ->
        assert badge_values(ScopeBadges.put_badges(tabs(), scope())).rfqs == 9
      end)

    assert log =~ ":rfqs"
    refute log =~ "secret-count-41"
  end

  describe "a broken module never breaks the menu" do
    setup do
      Application.put_env(:phoenix_kit, :scope_badges, Host)
      :ok
    end

    test "a raise is logged by its module, not its message" do
      Process.put(:scope_badges_answer, fn -> raise ArgumentError, "sentinel-7731" end)

      log = capture_log(fn -> assert ScopeBadges.put_badges(tabs(), scope()) == tabs() end)

      assert log =~ "ArgumentError"
      refute log =~ "sentinel-7731"
    end

    test "an exit" do
      Process.put(:scope_badges_answer, fn -> exit(:sentinel_7732) end)

      log = capture_log(fn -> assert ScopeBadges.put_badges(tabs(), scope()) == tabs() end)

      assert log =~ "exit"
      refute log =~ "sentinel_7732"
    end

    test "a throw" do
      Process.put(:scope_badges_answer, fn -> throw(:sentinel_7733) end)
      capture_log(fn -> assert ScopeBadges.put_badges(tabs(), scope()) == tabs() end)
    end

    test "an answer that is not a map" do
      Process.put(:scope_badges_answer, orders: 1)

      log = capture_log(fn -> assert ScopeBadges.put_badges(tabs(), scope()) == tabs() end)
      assert log =~ "not a map"
    end

    test "a module that does not exist" do
      Application.put_env(:phoenix_kit, :scope_badges, PhoenixKit.NoSuchBadgeModule)

      log = capture_log(fn -> assert ScopeBadges.put_badges(tabs(), scope()) == tabs() end)
      assert log =~ "UndefinedFunctionError"
    end

    test "a config value of the wrong shape" do
      Application.put_env(:phoenix_kit, :scope_badges, "MyApp.MenuBadges")

      log = capture_log(fn -> assert ScopeBadges.put_badges(tabs(), scope()) == tabs() end)
      assert log =~ ":scope_badges must be a module"
    end
  end

  test "AdminTabs.with_scope_badges/2 applies them" do
    Application.put_env(:phoenix_kit, :scope_badges, Host)
    assert badge_values(AdminTabs.with_scope_badges(tabs(), scope())).orders == 3
  end

  describe "changed/1" do
    test "tells the account's open pages on its scope topic" do
      ScopeNotifier.subscribe(@uuid)

      assert ScopeBadges.changed(@uuid) == :ok
      assert_receive {:phoenix_kit_scope_badges_changed, @uuid}

      assert ScopeBadges.changed(%User{uuid: @uuid}) == :ok
      assert_receive {:phoenix_kit_scope_badges_changed, @uuid}
    end

    test "ignores anything that names no account" do
      assert ScopeBadges.changed(nil) == :ok
      assert ScopeBadges.changed(%User{uuid: nil}) == :ok
    end
  end
end
