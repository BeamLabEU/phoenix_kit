defmodule PhoenixKit.Dashboard.TabHelpers do
  @moduledoc """
  Shared helper functions for dashboard sidebar navigation.

  Extracted from `AdminSidebar` and `Sidebar` to eliminate duplication.
  Import this module in sidebar components to use these functions in HEEX templates.
  """

  alias PhoenixKit.Dashboard.Tab

  @doc """
  Sets the `:active` key on each tab based on path matching.
  """
  @spec add_active_state([Tab.t()], String.t()) :: [map()]
  def add_active_state(tabs, current_path) do
    Enum.map(tabs, fn tab ->
      Map.put(tab, :active, Tab.matches_path?(tab, current_path))
    end)
  end

  @doc """
  Groups tabs by their `:group` field.
  """
  @spec group_tabs([Tab.t()]) :: %{optional(atom()) => [Tab.t()]}
  def group_tabs(tabs) do
    Enum.group_by(tabs, & &1.group)
  end

  @doc """
  Filters to groups that have tabs and sorts by priority.
  """
  @spec sorted_groups([map()], map()) :: [map()]
  def sorted_groups(groups, grouped_tabs) do
    group_ids_with_tabs = Map.keys(grouped_tabs) |> Enum.reject(&is_nil/1)

    groups
    |> Enum.filter(&(&1.id in group_ids_with_tabs))
    |> Enum.sort_by(& &1.priority)
  end

  @doc """
  Filters to only top-level tabs (no parent).
  """
  @spec filter_top_level([Tab.t()]) :: [Tab.t()]
  def filter_top_level(tabs) do
    Enum.filter(tabs, &Tab.top_level?/1)
  end

  @doc """
  Gets subtabs for a given parent tab ID, sorted by priority.
  """
  @spec get_subtabs_for(atom(), [Tab.t()]) :: [Tab.t()]
  def get_subtabs_for(parent_id, all_tabs) do
    Enum.filter(all_tabs, fn tab ->
      tab.parent == parent_id
    end)
    |> Enum.sort_by(& &1.priority)
  end
end
