defmodule PhoenixKit.Config.UserDashboardCategories do
  @moduledoc """
  User dashboard categories configuration and validation for PhoenixKit.

  This module provides a comprehensive system for configuring custom user dashboard
  categories with tabs (including subtabs), including validation, type safety, and
  fallback to built-in categories.

  ## Category Structure

  Each category should have the following structure:

      %{
        title: "Category Title",
        icon: "hero-icon-name",          # Optional Heroicon name
        tabs: [
          %{
            title: "Tab Title",
            url: "/dashboard/some-path",
            icon: "hero-icon-name",       # Optional Heroicon name
            description: "Brief description", # Optional
            subtabs: [                    # Optional nested tabs
              %{
                title: "Subtab Title",
                url: "/dashboard/some-path/sub",
                icon: "hero-icon-name"
              }
            ]
          }
        ]
      }

  ## Field Validation

  - **title**: Required string, max 100 characters
  - **icon**: Optional string, validated to be a reasonable Heroicon name
  - **tabs**: Required list, can be empty
  - **tab.title**: Required string, max 100 characters
  - **tab.url**: Required string, must start with "/"
  - **tab.icon**: Optional Heroicon name validation
  - **tab.description**: Optional string, max 200 characters
  - **tab.subtabs**: Optional list of subtab definitions

  ## Usage in config/config.exs

      config :phoenix_kit, :user_dashboard_categories, [
        %{
          title: "Farm Management",
          icon: "hero-cube",
          tabs: [
            %{
              title: "Printers",
              url: "/dashboard/printers",
              icon: "hero-printer",
              description: "Manage your 3D printers"
            },
            %{
              title: "History",
              url: "/dashboard/history",
              icon: "hero-chart-bar",
              description: "View print history"
            }
          ]
        },
        %{
          title: "Account",
          icon: "hero-user",
          tabs: [
            %{
              title: "Settings",
              url: "/dashboard/settings",
              icon: "hero-cog-6-tooth"
            }
          ]
        }
      ]

  ## Usage in Code

      # Get all configured categories with validation
      categories = PhoenixKit.Config.UserDashboardCategories.get_categories()

      # Returns validated list like:
      [
        %{
          title: "Farm Management",
          icon: "hero-cube",
          tabs: [
            %{
              title: "Printers",
              url: "/dashboard/printers",
              icon: "hero-printer",
              description: "Manage your 3D printers",
              subtabs: []
            }
          ]
        }
      ]

  """

  alias PhoenixKit.Config

  @doc """
  Gets user dashboard categories with comprehensive validation and defaults.

  This function provides a fully validated list of user dashboard categories
  with proper structure validation and fallback to built-in categories.

  ## Examples

      iex> PhoenixKit.Config.UserDashboardCategories.get_categories()
      [
        %{
          title: "Farm Management",
          icon: "hero-cube",
          tabs: [
            %{
              title: "Printers",
              url: "/dashboard/printers",
              icon: "hero-printer",
              description: "Manage your 3D printers"
            }
          ]
        }
      ]

  """
  @spec get_categories() :: list()
  def get_categories do
    case Config.get(:user_dashboard_categories) do
      {:ok, categories} when is_list(categories) ->
        validate_user_categories(categories)

      _ ->
        []
    end
  end

  @doc """
  Validates user dashboard categories structure and content.

  This function can be used to validate custom categories before setting them
  in the configuration.

  ## Examples

      iex> categories = [
      ...>   %{
      ...>     title: "My Category",
      ...>     tabs: [
      ...>       %{
      ...>         title: "My Tab",
      ...>         url: "/dashboard/my-path"
      ...>       }
      ...>     ]
      ...>   }
      ...> ]
      iex> PhoenixKit.Config.UserDashboardCategories.validate_categories(categories)
      {:ok, validated_categories}

  """
  @spec validate_categories(list()) :: {:ok, list()} | {:error, String.t()}
  def validate_categories(categories) when is_list(categories) do
    validated_categories = validate_user_categories(categories)
    {:ok, validated_categories}
  rescue
    _ -> {:error, "Invalid categories structure"}
  end

  def validate_categories(_), do: {:error, "Categories must be a list"}

  @doc """
  Converts categories to the Tab struct format used by the Dashboard system.

  This bridges the config-based categories to the Tab registry system.

  ## Examples

      iex> categories = PhoenixKit.Config.UserDashboardCategories.get_categories()
      iex> PhoenixKit.Config.UserDashboardCategories.to_tabs(categories)
      [%PhoenixKit.Dashboard.Tab{...}, ...]

  """
  @spec to_tabs(list()) :: list()
  def to_tabs(categories) do
    categories
    |> Enum.with_index()
    |> Enum.flat_map(fn {category, cat_idx} ->
      group_id = category_to_group_id(category.title)
      base_priority = (cat_idx + 1) * 100

      category.tabs
      |> Enum.with_index()
      |> Enum.flat_map(fn {tab, tab_idx} ->
        tab_id = tab_to_id(tab.title)
        tab_priority = base_priority + tab_idx * 10

        # Create the main tab
        main_tab = %{
          id: tab_id,
          label: tab.title,
          path: tab.url,
          icon: tab.icon,
          group: group_id,
          priority: tab_priority,
          tooltip: tab.description,
          subtab_display: if(tab.subtabs != [], do: :when_active, else: :when_active)
        }

        # Create subtabs if any
        subtabs =
          (tab.subtabs || [])
          |> Enum.with_index()
          |> Enum.map(fn {subtab, sub_idx} ->
            %{
              id: subtab_to_id(tab.title, subtab.title),
              label: subtab.title,
              path: subtab.url,
              icon: subtab.icon,
              group: group_id,
              priority: tab_priority + sub_idx + 1,
              parent: tab_id,
              tooltip: subtab[:description]
            }
          end)

        [main_tab | subtabs]
      end)
    end)
  end

  @doc """
  Converts categories to group definitions for the Dashboard system.

  ## Examples

      iex> categories = PhoenixKit.Config.UserDashboardCategories.get_categories()
      iex> PhoenixKit.Config.UserDashboardCategories.to_groups(categories)
      [%{id: :farm_management, label: "Farm Management", ...}, ...]

  """
  @spec to_groups(list()) :: [PhoenixKit.Dashboard.Group.t()]
  def to_groups(categories) do
    alias PhoenixKit.Dashboard.Group

    categories
    |> Enum.with_index()
    |> Enum.map(fn {category, idx} ->
      %Group{
        id: category_to_group_id(category.title),
        label: category.title,
        icon: category.icon,
        priority: (idx + 1) * 100,
        collapsible: true
      }
    end)
  end

  # Validates user dashboard categories structure and content
  defp validate_user_categories(categories) do
    validated_categories =
      categories
      |> Enum.filter(&is_map/1)
      |> Enum.map(&validate_category/1)
      |> Enum.filter(&(&1 != nil))

    # If validation results in empty list, fall back to built-in
    if validated_categories == [] do
      []
    else
      validated_categories
    end
  end

  # Validates individual category structure
  defp validate_category(category) when is_map(category) do
    with {:ok, title} <- validate_string_field(category, :title, 100),
         {:ok, icon} <- validate_category_icon_field(category, :icon),
         {:ok, tabs} <- validate_tabs(category[:tabs] || []) do
      %{
        title: title,
        icon: icon,
        tabs: tabs
      }
    else
      # Invalid category, filter it out
      _ -> nil
    end
  end

  defp validate_category(_), do: nil

  # Validates tabs list
  defp validate_tabs(tabs) when is_list(tabs) do
    validated_tabs =
      tabs
      |> Enum.filter(&is_map/1)
      |> Enum.map(&validate_tab/1)
      |> Enum.filter(&(&1 != nil))

    {:ok, validated_tabs}
  end

  defp validate_tabs(_), do: {:ok, []}

  # Validates individual tab structure
  defp validate_tab(tab) when is_map(tab) do
    with {:ok, title} <- validate_string_field(tab, :title, 100),
         {:ok, url} <- validate_url_field(tab, :url),
         {:ok, icon} <- validate_optional_icon_field(tab, :icon),
         {:ok, description} <- validate_optional_string_field(tab, :description, 200),
         {:ok, subtabs} <- validate_subtabs(tab[:subtabs] || []) do
      %{
        title: title,
        url: url,
        icon: icon,
        description: description,
        subtabs: subtabs
      }
    else
      # Invalid tab, filter it out
      _ -> nil
    end
  end

  defp validate_tab(_), do: nil

  # Validates subtabs list
  defp validate_subtabs(subtabs) when is_list(subtabs) do
    validated_subtabs =
      subtabs
      |> Enum.filter(&is_map/1)
      |> Enum.map(&validate_subtab/1)
      |> Enum.filter(&(&1 != nil))

    {:ok, validated_subtabs}
  end

  defp validate_subtabs(_), do: {:ok, []}

  # Validates individual subtab structure
  defp validate_subtab(subtab) when is_map(subtab) do
    with {:ok, title} <- validate_string_field(subtab, :title, 100),
         {:ok, url} <- validate_url_field(subtab, :url),
         {:ok, icon} <- validate_optional_icon_field(subtab, :icon),
         {:ok, description} <- validate_optional_string_field(subtab, :description, 200) do
      %{
        title: title,
        url: url,
        icon: icon,
        description: description
      }
    else
      # Invalid subtab, filter it out
      _ -> nil
    end
  end

  defp validate_subtab(_), do: nil

  # Validates required string field with max length
  defp validate_string_field(map, field, max_length) do
    case Map.get(map, field) do
      value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_length ->
        {:ok, String.trim(value)}

      _ ->
        :error
    end
  end

  # Validates optional string field with max length
  defp validate_optional_string_field(map, field, max_length) do
    case Map.get(map, field) do
      nil ->
        {:ok, nil}

      value when is_binary(value) and byte_size(value) <= max_length ->
        {:ok, String.trim(value)}

      _ ->
        # Invalid optional field, default to nil
        {:ok, nil}
    end
  end

  # Validates URL field - must start with "/"
  defp validate_url_field(map, field) do
    case Map.get(map, field) do
      value when is_binary(value) ->
        trimmed_value = String.trim(value)

        if String.starts_with?(trimmed_value, "/") do
          {:ok, trimmed_value}
        else
          :error
        end

      _ ->
        :error
    end
  end

  # Validates optional Heroicon name field for tabs
  defp validate_optional_icon_field(map, field) do
    case Map.get(map, field) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        # Basic Heroicon name validation - allow reasonable patterns
        if String.match?(value, ~r/^hero-[a-z0-9-]+$/i) do
          {:ok, String.trim(value)}
        else
          # Invalid icon name, default to nil
          {:ok, nil}
        end

      _ ->
        # Invalid type, default to nil
        {:ok, nil}
    end
  end

  # Validates Heroicon name field for categories (with default)
  defp validate_category_icon_field(map, field) do
    case Map.get(map, field) do
      nil ->
        # Default icon for categories
        {:ok, "hero-folder"}

      value when is_binary(value) ->
        # Basic Heroicon name validation - allow reasonable patterns
        if String.match?(value, ~r/^hero-[a-z0-9-]+$/i) do
          {:ok, String.trim(value)}
        else
          # Invalid icon name, default to hero-folder
          {:ok, "hero-folder"}
        end

      _ ->
        # Invalid type, default to hero-folder
        {:ok, "hero-folder"}
    end
  end

  # Converts a category title to a group ID atom
  defp category_to_group_id(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.to_atom()
  end

  # Converts a tab title to an ID atom
  defp tab_to_id(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> String.to_atom()
  end

  # Converts a subtab title to an ID atom (prefixed with parent)
  defp subtab_to_id(parent_title, subtab_title) do
    parent_id = tab_to_id(parent_title)
    subtab_id = tab_to_id(subtab_title)
    :"#{parent_id}_#{subtab_id}"
  end
end
