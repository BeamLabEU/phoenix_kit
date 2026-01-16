defmodule PhoenixKit.Config.AdminDashboardCategories do
  @moduledoc """
  Admin dashboard categories configuration and validation for PhoenixKit.

  This module provides a comprehensive system for configuring custom admin dashboard
  categories with subsections, including validation, type safety, and fallback to
  built-in categories.

  ## Category Structure

  Each category should have the following structure:

      %{
        title: "Category Title",
        icon: "hero-icon-name",          # Optional Heroicon name
        subsections: [
          %{
            title: "Subsection Title",
            url: "/admin/some-path",
            icon: "hero-icon-name",          # Optional Heroicon name
            description: "Brief description" # Optional
          }
        ]
      }

  ## Field Validation

  - **title**: Required string, max 100 characters
  - **icon**: Optional string, validated to be a reasonable Heroicon name
  - **subsections**: Required list, can be empty
  - **subsection.title**: Required string, max 100 characters
  - **subsection.url**: Required string, must start with "/"
  - **subsection.icon**: Optional Heroicon name validation
  - **subsection.description**: Optional string, max 200 characters

  ## Usage

      # Get all configured categories with validation
      categories = PhoenixKit.Config.AdminDashboardCategories.get_categories()

      # Returns validated list like:
      [
        %{
          title: "User Management",
          icon: "hero-users",
          subsections: [
            %{
              title: "All Users",
              url: "/admin/users",
              icon: "hero-user-group",
              description: "Manage user accounts"
            }
          ]
        }
      ]

  """

  alias PhoenixKit.Config

  @doc """
  Gets admin dashboard categories with comprehensive validation and defaults.

  This function provides a fully validated list of admin dashboard categories
  with proper structure validation and fallback to built-in categories.

  ## Examples

      iex> PhoenixKit.Config.AdminDashboardCategories.get_categories()
      [
        %{
          title: "User Management",
          icon: "hero-users",
          subsections: [
            %{
              title: "Users",
              url: "/admin/users",
              icon: "hero-user-group",
              description: "Manage user accounts"
            }
          ]
        }
      ]

  """
  @spec get_categories() :: list()
  def get_categories do
    case Config.get(:admin_dashboard_categories) do
      {:ok, categories} when is_list(categories) ->
        validate_admin_categories(categories)

      _ ->
        []
    end
  end

  @doc """
  Validates admin dashboard categories structure and content.

  This function can be used to validate custom categories before setting them
  in the configuration.

  ## Examples

      iex> categories = [
      ...>   %{
      ...>     title: "My Category",
      ...>     subsections: [
      ...>       %{
      ...>         title: "My Subsection",
      ...>         url: "/admin/my-path"
      ...>       }
      ...>     ]
      ...>   }
      ...> ]
      iex> PhoenixKit.Config.AdminDashboardCategories.validate_categories(categories)
      {:ok, validated_categories}

  """
  @spec validate_categories(list()) :: {:ok, list()} | {:error, String.t()}
  def validate_categories(categories) when is_list(categories) do
    validated_categories = validate_admin_categories(categories)
    {:ok, validated_categories}
  rescue
    _ -> {:error, "Invalid categories structure"}
  end

  def validate_categories(_), do: {:error, "Categories must be a list"}

  # Validates admin dashboard categories structure and content
  defp validate_admin_categories(categories) do
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
         {:ok, subsections} <- validate_subsections(category[:subsections] || []) do
      %{
        title: title,
        icon: icon,
        subsections: subsections
      }
    else
      # Invalid category, filter it out
      _ -> nil
    end
  end

  defp validate_category(_), do: nil

  # Validates subsections list
  defp validate_subsections(subsections) when is_list(subsections) do
    validated_subsections =
      subsections
      |> Enum.filter(&is_map/1)
      |> Enum.map(&validate_subsection/1)
      |> Enum.filter(&(&1 != nil))

    {:ok, validated_subsections}
  end

  defp validate_subsections(_), do: {:ok, []}

  # Validates individual subsection structure
  defp validate_subsection(subsection) when is_map(subsection) do
    with {:ok, title} <- validate_string_field(subsection, :title, 100),
         {:ok, url} <- validate_url_field(subsection, :url),
         {:ok, icon} <- validate_optional_icon_field(subsection, :icon),
         {:ok, description} <- validate_optional_string_field(subsection, :description, 200) do
      %{
        title: title,
        url: url,
        icon: icon,
        description: description
      }
    else
      # Invalid subsection, filter it out
      _ -> nil
    end
  end

  defp validate_subsection(_), do: nil

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

  # Validates optional Heroicon name field for subsections
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
end
