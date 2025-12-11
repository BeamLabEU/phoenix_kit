defmodule PhoenixKit.Install.IgniterConfig do
  @moduledoc """
  Helper functions for working with Igniter to read and modify parent project configuration.

  This module provides utilities to read, update, and merge configuration values in the
  parent Phoenix application's config files using Igniter's configuration system.

  All functions are designed to work with Igniter's project modification capabilities
  and provide safe operations that handle missing configs and merge strategies.

  ## Examples

      iex> igniter = Igniter.new()
      iex> {igniter, value} = PhoenixKit.Install.IgniterConfig.read_config(igniter, :my_app, [:key])
      {igniter, nil}

      iex> igniter = PhoenixKit.Install.IgniterConfig.update_config(igniter, :my_app, [:key], :value)
      # Returns updated igniter with the new config
  """

  alias Igniter.Code.Common
  alias Igniter.Project.Config
  alias Sourceror.Zipper

  @doc """
  Reads a configuration value from the parent project's config files.

  ## Parameters

  - `igniter` - The Igniter project struct
  - `app_name` - The application name (atom)
  - `key_path` - List of atoms representing the configuration key path
  - `config_file` - Config file name (default: "config.exs")

  ## Returns

  `{igniter, {:ok, value}}` if the config exists
  `{igniter, {:error, reason}}` if the config doesn't exist or can't be read

  ## Examples

      iex> igniter = Igniter.new()
      iex> {igniter, result} = PhoenixKit.Install.IgniterConfig.read_config(igniter, :my_app, [:my_key])
      {igniter, {:ok, :my_value}}
  """
  @spec read_config(Igniter.t(), atom(), list(atom()), String.t()) ::
          {Igniter.t(), {:ok, any()} | {:error, String.t()}}
  def read_config(igniter, app_name, key_path, config_file \\ "config.exs") do
    igniter
    |> Config.configure(
      config_file,
      app_name,
      key_path,
      nil,
      updater: fn zipper ->
        case extract_current_value(zipper) do
          {:ok, value} ->
            # Store the value in process dictionary for retrieval
            Process.put({__MODULE__, :read_value}, value)
            {:ok, zipper}

          :error ->
            Process.put({__MODULE__, :read_value}, :not_found)
            {:ok, zipper}
        end
      end
    )
    |> then(fn igniter ->
      value = Process.get({__MODULE__, :read_value}, :not_found)
      Process.delete({__MODULE__, :read_value})

      case value do
        :not_found -> {igniter, {:error, "Configuration not found"}}
        value -> {igniter, {:ok, value}}
      end
    end)
  end

  @doc """
  Updates or creates a configuration value in the parent project's config files.

  ## Parameters

  - `igniter` - The Igniter project struct
  - `app_name` - The application name (atom)
  - `key_path` - List of atoms representing the configuration key path
  - `value` - The new value to set
  - `config_file` - Config file name (default: "config.exs")
  - `opts` - Options:
    - `:merge_lists` - If true and both existing and new values are lists, merges them (default: false)

  ## Returns

  The updated `igniter` struct

  ## Examples

      iex> igniter = Igniter.new()
      iex> igniter = PhoenixKit.Install.IgniterConfig.update_config(igniter, :my_app, [:my_key], :new_value)
      # Returns igniter with the updated config
  """
  @spec update_config(Igniter.t(), atom(), list(atom()), any(), String.t(), keyword()) ::
          Igniter.t()
  def update_config(igniter, app_name, key_path, value, config_file \\ "config.exs", opts \\ []) do
    merge_lists = Keyword.get(opts, :merge_lists, false)

    igniter
    |> Config.configure(
      config_file,
      app_name,
      key_path,
      value,
      updater: fn zipper ->
        if merge_lists and should_merge_lists?(zipper, value) do
          case extract_current_value(zipper) do
            {:ok, existing_list} when is_list(existing_list) and is_list(value) ->
              merged = Enum.uniq(existing_list ++ value)
              {:ok, Common.replace_code(zipper, merged)}

            _ ->
              {:ok, Common.replace_code(zipper, value)}
          end
        else
          {:ok, Common.replace_code(zipper, value)}
        end
      end
    )
  end

  @doc """
  Merges a new value into an existing list configuration.

  If the config doesn't exist or is not a list, it will be created with the new value.

  ## Parameters

  - `igniter` - The Igniter project struct
  - `app_name` - The application name (atom)
  - `key_path` - List of atoms representing the configuration key path
  - `items` - List of items to add to the existing configuration
  - `config_file` - Config file name (default: "config.exs")
  - `opts` - Options:
    - `:merge_strategy` - How to merge when items are maps with `:title` keys:
      - `:prepend` - Add new items at the beginning (default)
      - `:append` - Add new items at the end
      - `:replace` - Replace existing items with matching titles

  ## Returns

  The updated `igniter` struct

  ## Examples

      iex> igniter = Igniter.new()
      iex> items = [%{title: "New Item", value: 1}]
      iex> igniter = PhoenixKit.Install.IgniterConfig.merge_into_list_config(
      ...>   igniter, :my_app, [:my_list], items
      ...> )
  """
  @spec merge_into_list_config(
          Igniter.t(),
          atom(),
          list(atom()),
          list(),
          String.t(),
          keyword()
        ) :: Igniter.t()
  def merge_into_list_config(
        igniter,
        app_name,
        key_path,
        items,
        config_file \\ "config.exs",
        opts \\ []
      )

  def merge_into_list_config(igniter, app_name, key_path, items, config_file, opts)
      when is_list(items) do
    merge_strategy = Keyword.get(opts, :merge_strategy, :prepend)

    igniter
    |> Config.configure(
      config_file,
      app_name,
      key_path,
      items,
      updater: fn zipper ->
        case extract_current_value(zipper) do
          {:ok, existing_list} when is_list(existing_list) ->
            updated_list =
              case merge_strategy do
                :replace ->
                  replace_by_title(existing_list, items)

                :append ->
                  existing_list ++ items

                :prepend ->
                  items ++ existing_list
              end

            {:ok, Common.replace_code(zipper, updated_list)}

          _ ->
            # Config doesn't exist or is not a list
            {:ok, Common.replace_code(zipper, items)}
        end
      end
    )
  end

  @doc """
  Reads a PhoenixKit-specific configuration value.

  Shortcut for reading config values from the :phoenix_kit application.

  ## Parameters

  - `igniter` - The Igniter project struct
  - `key_path` - List of atoms representing the configuration key path
  - `config_file` - Config file name (default: "config.exs")

  ## Returns

  `{igniter, {:ok, value}}` if the config exists
  `{igniter, {:error, reason}}` if the config doesn't exist or can't be read
  """
  @spec read_phoenix_kit_config(Igniter.t(), list(atom()), String.t()) ::
          {Igniter.t(), {:ok, any()} | {:error, String.t()}}
  def read_phoenix_kit_config(igniter, key_path, config_file \\ "config.exs") do
    read_config(igniter, :phoenix_kit, key_path, config_file)
  end

  @doc """
  Updates a PhoenixKit-specific configuration value.

  Shortcut for updating config values in the :phoenix_kit application.

  ## Parameters

  - `igniter` - The Igniter project struct
  - `key_path` - List of atoms representing the configuration key path
  - `value` - The new value to set
  - `config_file` - Config file name (default: "config.exs")
  - `opts` - Options passed through to `update_config/5`

  ## Returns

  The updated `igniter` struct
  """
  @spec update_phoenix_kit_config(Igniter.t(), list(atom()), any(), String.t(), keyword()) ::
          Igniter.t()
  def update_phoenix_kit_config(igniter, key_path, value, config_file \\ "config.exs", opts \\ []) do
    update_config(igniter, :phoenix_kit, key_path, value, config_file, opts)
  end

  @doc """
  Adds an item to an admin dashboard category in PhoenixKit configuration.

  Shortcut for `add_to_category/7` with PhoenixKit-specific defaults.

  ## Parameters

  - `igniter` - The Igniter project struct
  - `category_title` - The title of the category to add to
  - `item` - The item to add to the category's subsections
  - `category_opts` - Options for creating a new category if needed

  ## Returns

  The updated `igniter` struct

  ## Examples

      iex> igniter = Igniter.new()
      iex> new_page = %{title: "Reports", url: "/admin/reports", icon: "hero-chart-bar"}
      iex> igniter = PhoenixKit.Install.IgniterConfig.add_to_admin_category(
      ...>   igniter, "Analytics", new_page
      ...> )
  """
  @spec add_to_admin_category(Igniter.t(), String.t(), map(), keyword()) :: Igniter.t()
  def add_to_admin_category(igniter, category_title, item, category_opts \\ []) do
    add_to_category(
      igniter,
      :phoenix_kit,
      [:admin_dashboard_categories],
      category_title,
      item,
      category_opts
    )
  end

  @doc """
  Adds an item to a category within a list configuration, creating the category if needed.

  This function is designed for configurations that contain a list of categories,
  each with a `:title` key and `:subsections` list. It will find an existing category
  by title and add the new item to its subsections, or create a new category if it doesn't exist.

  ## Parameters

  - `igniter` - The Igniter project struct
  - `app_name` - The application name (atom)
  - `key_path` - List of atoms representing the configuration key path
  - `category_title` - The title of the category to add to
  - `item` - The item to add to the category's subsections
  - `category_opts` - Options for creating a new category if needed:
    - `:icon` - Icon for the new category (default: "hero-folder")
  - `config_file` - Config file name (default: "config.exs")

  ## Returns

  The updated `igniter` struct

  ## Examples

      iex> igniter = Igniter.new()
      iex> new_page = %{title: "Reports", url: "/admin/reports"}
      iex> igniter = PhoenixKit.Install.IgniterConfig.add_to_category(
      ...>   igniter, :my_app, [:admin_categories], "Analytics", new_page
      ...> )
  """
  @spec add_to_category(
          Igniter.t(),
          atom(),
          list(atom()),
          String.t(),
          map(),
          keyword(),
          String.t()
        ) :: Igniter.t()
  def add_to_category(
        igniter,
        app_name,
        key_path,
        category_title,
        item,
        category_opts \\ [],
        config_file \\ "config.exs"
      ) do
    default_icon = Keyword.get(category_opts, :icon, "hero-folder")

    igniter
    |> Config.configure(
      config_file,
      app_name,
      key_path,
      # Default value if config doesn't exist
      [
        %{
          title: category_title,
          icon: default_icon,
          subsections: [item]
        }
      ],
      updater: fn zipper ->
        case extract_current_value(zipper) do
          {:ok, existing_categories} when is_list(existing_categories) ->
            # Find if category already exists
            case Enum.find_index(existing_categories, &(&1.title == category_title)) do
              nil ->
                # Category doesn't exist, create new one
                new_category = %{
                  title: category_title,
                  icon: default_icon,
                  subsections: [item]
                }

                updated_categories = existing_categories ++ [new_category]
                {:ok, Common.replace_code(zipper, updated_categories)}

              category_index ->
                # Category exists, add to its subsections
                updated_categories =
                  existing_categories
                  |> List.update_at(category_index, fn category_config ->
                    existing_subsections = Map.get(category_config, :subsections, [])
                    updated_subsections = existing_subsections ++ [item]

                    %{category_config | subsections: updated_subsections}
                  end)

                {:ok, Common.replace_code(zipper, updated_categories)}
            end

          _ ->
            # Config doesn't exist or is not a list, create new
            new_category = %{
              title: category_title,
              icon: default_icon,
              subsections: [item]
            }

            {:ok, Common.replace_code(zipper, [new_category])}
        end
      end
    )
  end

  @doc """
  Checks if a configuration value exists.

  ## Parameters

  - `igniter` - The Igniter project struct
  - `app_name` - The application name (atom)
  - `key_path` - List of atoms representing the configuration key path
  - `config_file` - Config file name (default: "config.exs")

  ## Returns

  `{igniter, true}` if the config exists
  `{igniter, false}` if the config doesn't exist
  """
  @spec config_exists?(Igniter.t(), atom(), list(atom()), String.t()) :: {Igniter.t(), boolean()}
  def config_exists?(igniter, app_name, key_path, config_file \\ "config.exs") do
    {igniter, result} = read_config(igniter, app_name, key_path, config_file)

    case result do
      {:ok, _value} -> {igniter, true}
      {:error, _reason} -> {igniter, false}
    end
  end

  # Private helpers

  # Extracts the current value from a zipper
  defp extract_current_value(zipper) do
    current_node = Zipper.node(zipper)

    case Code.eval_quoted(current_node) do
      {value, _binding} -> {:ok, value}
    end
  rescue
    _ -> :error
  end

  # Checks if we should merge lists based on existing and new values
  defp should_merge_lists?(zipper, new_value) do
    case extract_current_value(zipper) do
      {:ok, existing_value} when is_list(existing_value) and is_list(new_value) ->
        true

      _ ->
        false
    end
  end

  # Replaces items in a list by matching on :title key
  defp replace_by_title(existing_list, new_items) do
    existing_titles = MapSet.new(existing_list, fn item -> Map.get(item, :title) end)

    {to_replace, _to_add} =
      Enum.split_with(new_items, fn item ->
        Map.get(item, :title) in existing_titles
      end)

    # Remove existing items that will be replaced
    replacement_titles = MapSet.new(to_replace, fn item -> Map.get(item, :title) end)

    filtered_existing =
      Enum.reject(existing_list, fn item ->
        Map.get(item, :title) in replacement_titles
      end)

    # Add new items (both replacements and additions)
    filtered_existing ++ new_items
  end
end
