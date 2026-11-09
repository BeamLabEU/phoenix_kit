defmodule PhoenixKit.ModuleRegistryHeaderWidgetsTest do
  @moduledoc """
  The `header_widgets/0` callback of `PhoenixKit.Module` and its readers,
  `ModuleRegistry.all_header_widgets/0` (enabled modules, validated, tagged with the module)
  and `ModuleRegistry.header_widgets_for/1` (with the session built from the layout's assigns).
  """
  # async: false - `register/1` changes global state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.HeaderWidget
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitWeb.Test.HeaderWidgetProbeLive, as: Probe

  defmodule UsingModule do
    use PhoenixKit.Module

    @impl PhoenixKit.Module
    def module_key, do: "hw_using_fake"
    @impl PhoenixKit.Module
    def module_name, do: "Header widget using fake"
    @impl PhoenixKit.Module
    def enabled?, do: true
    @impl PhoenixKit.Module
    def enable_system, do: :ok
    @impl PhoenixKit.Module
    def disable_system, do: :ok

    @impl PhoenixKit.Module
    def header_widgets do
      [{PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-using", fn _assigns -> %{} end}]
    end
  end

  defmodule PlainModule do
    use PhoenixKit.Module

    @impl PhoenixKit.Module
    def module_key, do: "hw_plain_fake"
    @impl PhoenixKit.Module
    def module_name, do: "Header widget plain fake"
    @impl PhoenixKit.Module
    def enabled?, do: true
    @impl PhoenixKit.Module
    def enable_system, do: :ok
    @impl PhoenixKit.Module
    def disable_system, do: :ok
  end

  defmodule OnModule do
    def enabled?, do: true

    def header_widgets do
      [
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-on-plain", &__MODULE__.session/1},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-on-dock", &__MODULE__.session/1,
         dock: true}
      ]
    end

    def session(assigns), do: %{"label" => "on", "user_uuid" => assigns[:marker]}
  end

  defmodule OffModule do
    def enabled?, do: false

    def header_widgets do
      [{PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-off", fn _ -> %{} end}]
    end
  end

  defmodule NoEnabledModule do
    def header_widgets do
      [{PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-no-enabled", fn _ -> %{} end}]
    end
  end

  defmodule BrokenModule do
    def enabled?, do: true

    def header_widgets do
      [
        :not_a_tuple,
        {NotALiveView, "hw-broken-1", fn _ -> %{} end},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "", fn _ -> %{} end},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-broken-3", :not_a_fun},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-broken-4", fn _ -> %{} end, dock: :yes},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-broken-5", fn _ -> %{} end, wide: true},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-broken-ok", fn _ -> %{} end}
      ]
    end
  end

  defmodule RaisingModule do
    def enabled?, do: true
    def header_widgets, do: raise("boom")
  end

  defmodule DuplicateModule do
    def enabled?, do: true

    def header_widgets do
      [{PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-on-plain", fn _ -> %{} end}]
    end
  end

  defmodule SessionModule do
    def enabled?, do: true

    def header_widgets do
      [
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-s-raises", fn _ -> raise "nope" end},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-s-nil", fn _ -> nil end},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-s-atom-keys", fn _ -> %{user: 1} end},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-s-good", fn _ -> %{"label" => "ok"} end}
      ]
    end
  end

  # The session function gets the layout's assigns (the signed-in user among them), so
  # a `MatchError`, a `KeyError` or a bad return value can carry a person's data.
  defmodule LeakyModule do
    def enabled?, do: true

    def header_widgets do
      [
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-leaky-match",
         fn assigns -> {:ok, _} = assigns.marker end},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-leaky-key",
         fn assigns -> Map.fetch!(assigns, :absent) end},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-leaky-throw",
         fn assigns -> throw({:oops, assigns.marker}) end},
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-leaky-return",
         fn assigns -> [assigns.marker] end}
      ]
    end
  end

  defmodule ReservedKeysModule do
    def enabled?, do: true

    def header_widgets do
      [
        {PhoenixKitWeb.Test.HeaderWidgetProbeLive, "hw-r-reserved",
         fn _ ->
           %{
             "label" => "kept",
             "user_token" => "forged",
             "pk_session_accounts" => [],
             "pk_own_tokens" => [],
             "pk_impersonators" => %{},
             "pk_organization_token" => "forged",
             "live_socket_id" => "x",
             "phoenix_kit_session_uuid" => "y"
           }
         end}
      ]
    end
  end

  # `warn_once` remembers in :persistent_term, which outlives a test (and a rerun of the file
  # in the same VM); forget the keys these tests use so each one sees its first warning.
  @warned_keys [
    {:bad_header_widget, BrokenModule},
    {:header_widgets_failed, RaisingModule},
    {:duplicate_header_widget, "hw-on-plain"},
    {:header_widget_session, SessionModule, "hw-s-raises"},
    {:header_widget_session, SessionModule, "hw-s-nil"},
    {:header_widget_session, SessionModule, "hw-s-atom-keys"},
    {:header_widget_reserved_keys, ReservedKeysModule, "hw-r-reserved"}
  ]

  setup do
    forget_warnings()
    on_exit(&forget_warnings/0)
  end

  defp forget_warnings do
    Enum.each(@warned_keys, &:persistent_term.erase({ModuleRegistry, :warned, &1}))
  end

  defp with_registered(modules, fun) do
    Enum.each(modules, &ModuleRegistry.register/1)

    try do
      fun.()
    after
      Enum.each(modules, &ModuleRegistry.unregister/1)
    end
  end

  defp scope_with(accounts), do: %Scope{multi_session_accounts: accounts}

  defp count(log, text), do: length(String.split(log, text)) - 1

  defp ids(widgets), do: widgets |> Enum.map(& &1.id) |> Enum.sort()

  defp mine(widgets, modules), do: Enum.filter(widgets, &(&1.module in modules))

  describe "use PhoenixKit.Module" do
    test "header_widgets/0 is an optional callback with no default" do
      assert {:header_widgets, 0} in PhoenixKit.Module.behaviour_info(:optional_callbacks)
      assert {:header_widgets, 0} in PhoenixKit.Module.behaviour_info(:callbacks)
      refute function_exported?(PlainModule, :header_widgets, 0)
    end

    test "a module that does not define it contributes nothing" do
      with_registered([PlainModule], fn ->
        assert [] == mine(ModuleRegistry.all_header_widgets(), [PlainModule])
      end)
    end

    test "a module that uses PhoenixKit.Module can define it" do
      with_registered([UsingModule], fn ->
        assert ["hw-using"] ==
                 ModuleRegistry.all_header_widgets() |> mine([UsingModule]) |> ids()
      end)
    end
  end

  describe "all_header_widgets/0" do
    test "returns the widgets of enabled modules, tagged with the module, as structs" do
      with_registered([OnModule], fn ->
        widgets = ModuleRegistry.all_header_widgets() |> mine([OnModule])

        assert ["hw-on-dock", "hw-on-plain"] == ids(widgets)
        assert Enum.all?(widgets, &match?(%HeaderWidget{live_view: Probe}, &1))

        assert %{dock: true} = Enum.find(widgets, &(&1.id == "hw-on-dock"))
        assert %{dock: false} = Enum.find(widgets, &(&1.id == "hw-on-plain"))
      end)
    end

    test "leaves out a module that is switched off" do
      with_registered([OnModule, OffModule], fn ->
        widgets = ModuleRegistry.all_header_widgets()

        assert [] == mine(widgets, [OffModule])
        assert [_, _] = mine(widgets, [OnModule])
      end)
    end

    test "a module with no enabled?/0 does not count as enabled" do
      with_registered([NoEnabledModule], fn ->
        assert [] == ModuleRegistry.all_header_widgets() |> mine([NoEnabledModule])
      end)
    end

    test "drops invalid entries with a warning, keeps the valid one" do
      with_registered([BrokenModule], fn ->
        log =
          capture_log(fn ->
            assert ["hw-broken-ok"] ==
                     ModuleRegistry.all_header_widgets() |> mine([BrokenModule]) |> ids()
          end)

        # One warning per module, however many entries are wrong and however often it runs.
        assert log =~ "BrokenModule.header_widgets/0 returned an invalid widget"
        assert 1 == count(log, "BrokenModule.header_widgets/0 returned an invalid widget")

        assert "" ==
                 capture_log(fn ->
                   assert ["hw-broken-ok"] ==
                            ModuleRegistry.all_header_widgets() |> mine([BrokenModule]) |> ids()
                 end)
      end)
    end

    test "a module whose callback raises contributes nothing" do
      with_registered([RaisingModule, OnModule], fn ->
        log =
          capture_log(fn ->
            widgets = ModuleRegistry.all_header_widgets()
            assert [] == mine(widgets, [RaisingModule])
            assert [_, _] = mine(widgets, [OnModule])
          end)

        assert log =~ "RaisingModule.header_widgets/0 raised RuntimeError"
        refute log =~ "boom"

        # Reported once: the layout asks again on every render.
        assert "" == capture_log(fn -> ModuleRegistry.all_header_widgets() end)
      end)
    end

    test "an id declared twice keeps the first widget registered, and says so once" do
      with_registered([OnModule, DuplicateModule], fn ->
        log =
          capture_log(fn ->
            widgets = ModuleRegistry.all_header_widgets()

            assert [] == mine(widgets, [DuplicateModule])
            assert [_, _] = mine(widgets, [OnModule])
            assert 1 == Enum.count(widgets, &(&1.id == "hw-on-plain"))
          end)

        assert 1 == count(log, ~s(declares the header widget "hw-on-plain"))
        assert "" == capture_log(fn -> ModuleRegistry.all_header_widgets() end)
      end)
    end
  end

  describe "header_widgets_for/1" do
    test "hands the layout's assigns to the session function" do
      with_registered([OnModule], fn ->
        widgets = ModuleRegistry.header_widgets_for(%{marker: "u-1"}) |> mine([OnModule])

        assert [%{"label" => "on", "user_uuid" => "u-1"}] =
                 widgets |> Enum.filter(&(&1.id == "hw-on-plain")) |> Enum.map(& &1.session)
      end)
    end

    test "skips a widget whose session is not a map with string keys, or whose function raises" do
      with_registered([SessionModule], fn ->
        log =
          capture_log(fn ->
            widgets = ModuleRegistry.header_widgets_for(%{}) |> mine([SessionModule])

            assert ["hw-s-good"] == ids(widgets)
            assert [%{"label" => "ok"}] = Enum.map(widgets, & &1.session)
          end)

        assert log =~ "skipped: the session function raised RuntimeError"
        refute log =~ "nope"
        assert log =~ ~s("hw-s-atom-keys" skipped: the session has a key that is not a string)

        # Once per widget, not on every render of the layout.
        assert "" == capture_log(fn -> ModuleRegistry.header_widgets_for(%{}) end)
      end)
    end

    test "a failing session function logs the kind of failure, never the assigns or the value" do
      with_registered([LeakyModule], fn ->
        sentinel = "user-secret-#{System.unique_integer([:positive])}@example.com"

        log =
          capture_log(fn ->
            widgets = ModuleRegistry.header_widgets_for(%{marker: sentinel})
            assert [] == mine(widgets, [LeakyModule])
          end)

        assert log =~ ~s("hw-leaky-match" skipped: the session function raised MatchError)
        assert log =~ ~s("hw-leaky-key" skipped: the session function raised KeyError)
        assert log =~ ~s|"hw-leaky-throw" skipped: the session function failed (throw)|
        assert log =~ ~s("hw-leaky-return" skipped: the session is a list, not a map)
        refute log =~ sentinel
      end)
    end

    test "drops the reserved cookie-session keys from the session, keeps the rest, warns once" do
      with_registered([ReservedKeysModule], fn ->
        log =
          capture_log(fn ->
            widgets = ModuleRegistry.header_widgets_for(%{}) |> mine([ReservedKeysModule])
            assert [%{"label" => "kept"} = session] = Enum.map(widgets, & &1.session)
            assert Map.keys(session) == ["label"]
          end)

        assert log =~ ~s("hw-r-reserved" session keys dropped)
        assert log =~ "user_token"
        refute log =~ "forged"

        assert "" == capture_log(fn -> ModuleRegistry.header_widgets_for(%{}) end)
      end)
    end

    test "a session function that returns nil means: no widget for this user, and no warning" do
      with_registered([SessionModule], fn ->
        log =
          capture_log(fn ->
            assert "hw-s-nil" not in ids(
                     ModuleRegistry.header_widgets_for(%{})
                     |> mine([SessionModule])
                   )
          end)

        refute log =~ "hw-s-nil"
      end)
    end
  end

  describe "PhoenixKit.HeaderWidget.impersonating?/1" do
    test "is false without a multi-session stack" do
      refute HeaderWidget.impersonating?(nil)
      refute HeaderWidget.impersonating?(scope_with([]))
    end

    test "is false while the root account of the stack is the active one" do
      refute HeaderWidget.impersonating?(
               scope_with([%{active?: true, root?: true}, %{active?: false, root?: false}])
             )
    end

    test "is true while an account other than the root is the active one" do
      assert HeaderWidget.impersonating?(
               scope_with([%{active?: false, root?: true}, %{active?: true, root?: false}])
             )
    end

    test "an account added with its own credentials is not borrowed" do
      refute HeaderWidget.impersonating?(
               scope_with([
                 %{active?: false, root?: true, own?: true},
                 %{active?: true, root?: false, own?: true}
               ])
             )
    end

    test "organization and support provenance count without a switcher list" do
      assert HeaderWidget.impersonating?(%Scope{impersonated_by_uuid: Ecto.UUID.generate()})

      assert HeaderWidget.impersonating?(%Scope{
               user: %PhoenixKit.Users.Auth.User{acting_user_uuid: Ecto.UUID.generate()}
             })
    end
  end

  describe "PhoenixKit.HeaderWidget.new/1" do
    test "accepts the three- and the four-element form" do
      fun = fn _ -> %{} end

      assert {:ok, %HeaderWidget{id: "a", dock: false, session_fun: ^fun}} =
               HeaderWidget.new({Probe, "a", fun})

      assert {:ok, %HeaderWidget{dock: true}} = HeaderWidget.new({Probe, "a", fun, dock: true})
      assert {:ok, %HeaderWidget{dock: false}} = HeaderWidget.new({Probe, "a", fun, []})
    end

    test "refuses what it cannot render" do
      assert {:error, _} = HeaderWidget.new({Probe, "a"})
      assert {:error, _} = HeaderWidget.new({String, "a", fn _ -> %{} end})
      assert {:error, _} = HeaderWidget.new({Probe, "a", fn -> %{} end})
      assert {:error, _} = HeaderWidget.new({Probe, "a", fn _ -> %{} end, :dock})
    end

    test "refuses an id that is already a DOM id of the admin layout" do
      for id <- HeaderWidget.reserved_ids() do
        assert {:error, reason} = HeaderWidget.new({Probe, id, fn _ -> %{} end})
        assert reason =~ "reserved"
      end

      assert "pk-notifications-bell" in HeaderWidget.reserved_ids()
      assert "pk-dock" in HeaderWidget.reserved_ids()
      assert "admin-drawer" in HeaderWidget.reserved_ids()
    end
  end
end
