defmodule PhoenixKit.Integration.AdminTabOrderRegistryTest do
  @moduledoc """
  `:admin_tab_order` and core's module tab order, end to end through a running
  `PhoenixKit.Dashboard.Registry`: the host's order has to reach every path a
  tab takes into the registry (kit defaults, host `:admin_dashboard_tabs`,
  legacy `:admin_dashboard_categories`, runtime `register/2`) and has to come
  back after a rebuild — that is what a runtime `update_tab/2` cannot do.

  The registry is not part of the test supervision tree, so the suite starts
  its own (sync, shared sandbox: init reads settings from the database).
  """
  use PhoenixKit.DataCase, async: false

  @moduletag :capture_log

  alias PhoenixKit.Dashboard.{Registry, Tab}

  @env_keys [:admin_tab_order, :admin_dashboard_tabs, :admin_dashboard_categories]

  setup do
    previous = Map.new(@env_keys, &{&1, Application.get_env(:phoenix_kit, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:phoenix_kit, key),
          else: Application.put_env(:phoenix_kit, key, value)
      end
    end)

    :ok
  end

  defp start_registry! do
    refute Process.whereis(Registry), "a registry is already running — this suite starts its own"
    start_supervised!(Registry)
    # A call is served only after handle_continue(:initialize_tabs) has run.
    :sys.get_state(Registry)
    :ok
  end

  test "the host order reaches every path into the registry and survives a rebuild" do
    Application.put_env(:phoenix_kit, :admin_dashboard_tabs, [
      %{id: :admin_order_host_tab, label: "Host", path: "/admin/order-host", priority: 700}
    ])

    Application.put_env(:phoenix_kit, :admin_dashboard_categories, [
      %{title: "Legacy", subsections: [%{title: "Legacy page", url: "/admin/order-legacy"}]}
    ])

    Application.put_env(:phoenix_kit, :admin_tab_order, %{
      # a core group is known at boot, before the registry has written its
      # groups to ETS — otherwise this group would be dropped with a warning
      admin_dashboard: %{priority: 999, group: :admin_modules},
      admin_order_host_tab: 124,
      admin_custom_0: 123,
      admin_custom_0_0: 122,
      admin_order_runtime_tab: %{priority: 125, group: :admin_main}
    })

    start_registry!()

    # kit defaults (load_admin_defaults_internal/0)
    dashboard = Registry.get_tab(:admin_dashboard)
    assert {dashboard.priority, dashboard.group} == {999, :admin_modules}
    # host :admin_dashboard_tabs
    assert Registry.get_tab(:admin_order_host_tab).priority == 124
    # legacy :admin_dashboard_categories — the category tab and its subsection
    assert Registry.get_tab(:admin_custom_0).priority == 123
    assert Registry.get_tab(:admin_custom_0_0).priority == 122

    # runtime register/2
    :ok =
      Registry.register(:admin_tab_order_test, [
        Tab.new!(
          id: :admin_order_runtime_tab,
          label: "Runtime",
          path: "order-runtime",
          priority: 800,
          level: :admin,
          group: :admin_modules
        )
      ])

    runtime = Registry.get_tab(:admin_order_runtime_tab)
    assert {runtime.priority, runtime.group} == {125, :admin_main}

    # a rebuild — what a module's enable/disable does — brings the host order back
    :ok = Registry.update_tab(:admin_dashboard, %{priority: 1})
    assert Registry.get_tab(:admin_dashboard).priority == 1
    :ok = Registry.load_defaults()
    assert Registry.get_tab(:admin_dashboard).priority == 999
  end

  test "core's table reaches the registry, and the host order wins over it" do
    start_registry!()
    assert %Tab{priority: 645} = Registry.get_tab(:admin_notifications)
    stop_supervised!(Registry)

    Application.put_env(:phoenix_kit, :admin_tab_order, %{admin_notifications: 101})
    start_registry!()
    assert %Tab{priority: 101} = Registry.get_tab(:admin_notifications)
  end
end
