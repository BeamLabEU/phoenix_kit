defmodule PhoenixKit.AdminTabOrderTest do
  @moduledoc """
  Where admin tabs sit in the sidebar.

  The admin sidebar draws group by group (`:admin_main`, `:admin_modules`,
  `:admin_system`) and only then by priority inside a group. Modules used to
  pick their own numbers: the modules people work in every day ended up at the
  bottom, and many tabs shared a priority, so their order depended on an ETS
  set and changed from boot to boot. Core now owns the order of known module
  tabs (`AdminTabs.module_tab_order/0`), a host can override it from config
  (`:admin_tab_order`, applied inside the registry like `:hidden_admin_tabs`,
  so a rebuild cannot undo it), and ties are broken by id.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Dashboard.{AdminTabs, Registry, Tab}

  setup do
    previous = Application.get_env(:phoenix_kit, :admin_tab_order)

    on_exit(fn ->
      if previous do
        Application.put_env(:phoenix_kit, :admin_tab_order, previous)
      else
        Application.delete_env(:phoenix_kit, :admin_tab_order)
      end
    end)

    :ok
  end

  defp tab(id, priority, opts \\ []) do
    %Tab{
      id: id,
      label: to_string(id),
      priority: priority,
      level: Keyword.get(opts, :level, :admin),
      parent: Keyword.get(opts, :parent),
      group: Keyword.get(opts, :group, :admin_modules)
    }
  end

  defp top_level(tabs), do: Enum.filter(tabs, &(&1.level == :admin and is_nil(&1.parent)))

  defp core_priority(id), do: Enum.find(AdminTabs.core_tabs(), &(&1.id == id)).priority

  describe "core's default order for known module tabs" do
    test "no two top-level tabs share a priority — module tabs and core's own" do
      order = AdminTabs.module_tab_order()

      core_own =
        (AdminTabs.core_tabs() ++ AdminTabs.module_tabs() ++ AdminTabs.settings_tabs())
        |> top_level()
        |> Enum.reject(&Map.has_key?(order, &1.id))
        |> Enum.map(&{&1.priority, &1.id})

      listed = Enum.map(order, fn {id, attrs} -> {attrs.priority, id} end)

      shared =
        (core_own ++ listed)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.filter(fn {_priority, ids} -> length(ids) > 1 end)

      assert shared == []
    end

    test "daily work joins :admin_main between the dashboard and Users" do
      order = AdminTabs.module_tab_order()

      for id <- [:admin_catalogue, :admin_projects, :admin_document_creator, :admin_crm] do
        assert order[id].group == :admin_main
        assert order[id].priority > core_priority(:admin_dashboard)
        assert order[id].priority < core_priority(:admin_users)
      end

      assert order[:admin_staff].group == :admin_main
      assert order[:admin_staff].priority > core_priority(:admin_users)
    end

    test "a listed top-level tab takes core's priority and group; subtabs and unknown ids are untouched" do
      tabs = [
        tab(:admin_catalogue, 660),
        tab(:admin_catalogue_items, 10, parent: :admin_catalogue),
        tab(:admin_not_a_known_module, 777)
      ]

      [catalogue, subtab, unknown] = AdminTabs.apply_module_tab_order(tabs)

      assert {catalogue.priority, catalogue.group} == {151, :admin_main}
      assert {subtab.priority, subtab.group} == {10, :admin_modules}
      assert {unknown.priority, unknown.group} == {777, :admin_modules}
    end

    test "an entry without a group keeps the module's own group" do
      [emails] = AdminTabs.apply_module_tab_order([tab(:admin_emails, 510)])

      assert {emails.priority, emails.group} == {600, :admin_modules}
    end
  end

  describe ":admin_tab_order — host overrides" do
    test "an integer is a priority, a map or keyword list may also move the group; unusable entries are ignored" do
      Application.put_env(:phoenix_kit, :admin_tab_order, %{
        :admin_catalogue => 120,
        :admin_crm => [priority: 125, group: :admin_main],
        :admin_bad_value => "first",
        :admin_bad_group => %{group: "main"},
        "admin_string_id" => 130
      })

      assert Registry.admin_tab_order() == %{
               admin_catalogue: %{priority: 120},
               admin_crm: %{priority: 125, group: :admin_main}
             }
    end

    test "a keyword list config works the same" do
      Application.put_env(:phoenix_kit, :admin_tab_order, admin_catalogue: 120)

      assert Registry.admin_tab_order() == %{admin_catalogue: %{priority: 120}}
    end

    test "applied on the rebuild path, on top of core's own order" do
      # The exact composition load_admin_defaults_internal/0 applies on every
      # registry rebuild — a restart or a module's load_defaults/0 cannot undo it.
      Application.put_env(:phoenix_kit, :admin_tab_order, %{admin_dashboard: 999})

      rebuilt =
        AdminTabs.default_tabs()
        |> Registry.apply_hidden_admin_tabs()
        |> Registry.apply_admin_tab_order()

      assert Enum.find(rebuilt, &(&1.id == :admin_dashboard)).priority == 999
    end

    test "a user dashboard tab with the same id is not touched" do
      Application.put_env(:phoenix_kit, :admin_tab_order, %{reports: 1})

      [user_tab] = Registry.apply_admin_tab_order([tab(:reports, 300, level: :user)])

      assert user_tab.priority == 300
    end

    test "an unset config changes nothing" do
      Application.delete_env(:phoenix_kit, :admin_tab_order)
      tabs = [tab(:admin_catalogue, 660)]

      assert Registry.admin_tab_order() == %{}
      assert Registry.apply_admin_tab_order(tabs) == tabs
    end
  end

  describe "sorting" do
    test "equal priorities are ordered by id, whatever order they arrive in" do
      a = tab(:a_tab, 500)
      b = tab(:b_tab, 500)
      first = tab(:z_first, 100)

      assert Enum.map(Registry.sort_tabs([b, a, first]), & &1.id) == [:z_first, :a_tab, :b_tab]
      assert Enum.map(Registry.sort_tabs([a, first, b]), & &1.id) == [:z_first, :a_tab, :b_tab]
    end
  end
end
